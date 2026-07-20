#!/usr/bin/env bash

wait_for_local_health() {
    local timeout_seconds="${1:-45}" deadline response
    deadline=$((SECONDS + timeout_seconds))
    while (( SECONDS < deadline )); do
        response="$(curl --silent --show-error --max-time 4 \
            --header "Host: ${DOMAIN:-localhost}" \
            http://127.0.0.1:8000/health 2>/dev/null || true)"
        [[ "$response" == '{"status":"ok"}' ]] && return 0
        sleep 2
    done
    return 1
}

wait_for_public_health() {
    local timeout_seconds="${1:-30}" deadline response
    deadline=$((SECONDS + timeout_seconds))
    while (( SECONDS < deadline )); do
        response="$(curl --silent --show-error --max-time 7 \
            "https://$DOMAIN/health" 2>/dev/null || true)"
        [[ "$response" == '{"status":"ok"}' ]] && return 0
        sleep 2
    done
    return 1
}

verify_local_https_routes() {
    local check path expected status failed=0
    local -a checks
    if grep -q '^PUBLIC_COPY_MODE=' "$CURRENT_LINK/.env.example"; then
        checks=(
            "/ 200"
            "/profile/settings 200"
            "/info/legal 200"
            "/robots.txt 404"
            "/sitemap.xml 404"
            "/index.html 301"
            "/public/app-config 200"
            "/admin/routing-probe-not-found 404"
        )
    else
        checks=(
            "/ 200"
            "/profile/settings 200"
            "/info/legal 200"
            "/robots.txt 200"
            "/sitemap.xml 200"
            "/index.html 301"
            "/public/app-config 404"
            "/admin/routing-probe-not-found 404"
        )
    fi
    for check in "${checks[@]}"; do
        read -r path expected <<<"$check"
        status="$(curl --silent --show-error --max-time 7 --output /dev/null \
            --write-out '%{http_code}' --noproxy '*' \
            --resolve "$DOMAIN:443:127.0.0.1" \
            "https://$DOMAIN$path" 2>/dev/null || true)"
        if [[ "$status" != "$expected" ]]; then
            error "HTTPS-маршрут $path вернул ${status:-ошибку} вместо $expected."
            failed=1
        fi
    done
    (( failed == 0 ))
}

validation_override_path() {
    printf '/run/systemd/system/%s.d/manager-validation.conf\n' "$SERVICE_NAME"
}

install_validation_service_override() {
    local directory temporary destination
    destination="$(validation_override_path)"
    directory="$(dirname "$destination")"
    install -d -o root -g root -m 0755 "$directory" || return 1
    temporary="$(mktemp "$directory/.manager-validation.XXXXXX")" || return 1
    if ! cat >"$temporary" <<'EOF'
[Service]
ExecStart=
ExecStart=/opt/vpn-site-manager/current/bin/envexec.py /etc/vpn-site/vpn-site.env /opt/vpn-site/current/.venv/bin/python -m uvicorn main:app --host 127.0.0.1 --port 8000 --workers 1 --lifespan off --proxy-headers --forwarded-allow-ips=127.0.0.1 --no-server-header --no-access-log
EOF
    then
        rm -f -- "$temporary"
        return 1
    fi
    chmod 0644 "$temporary" || { rm -f -- "$temporary"; return 1; }
    mv -f "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    systemctl daemon-reload
}

remove_validation_service_override() {
    local destination directory
    destination="$(validation_override_path)"
    directory="$(dirname "$destination")"
    rm -f -- "$destination" || return 1
    rmdir "$directory" 2>/dev/null || true
    systemctl daemon-reload
}

stop_validation_backend() {
    if ! systemctl stop "$SERVICE_NAME"; then
        error "Validation backend не удалось остановить; override и локальный Nginx сохранены."
        return 1
    fi
    remove_validation_service_override
}

remove_stale_validation_override() {
    local destination cached_exec_start
    destination="$(validation_override_path)"
    cached_exec_start="$(systemctl show "$SERVICE_NAME" \
        --property=ExecStart --value 2>/dev/null || true)"
    if [[ ! -f "$destination" && "$cached_exec_start" != *'--lifespan off'* ]]; then
        systemctl daemon-reload
        return
    fi
    warn "Удаляется validation override от прерванной операции."
    systemctl stop "$SERVICE_NAME" || return 1
    remove_validation_service_override
}

validate_startup_prerequisites() {
    local release="${1:-$CURRENT_LINK}" code
    code=$'import asyncio\nimport database.schema as schema\n\nasync def main():\n    await schema.require_current_schema()\n    check = getattr(schema, "require_admin_bootstrap_ready", None)\n    if check is not None:\n        await check()\n\nasyncio.run(main())'
    (
        cd "$release/backend" || exit 1
        "$(envexec_path)" "$ENV_FILE" "$release/.venv/bin/python" -c "$code"
    )
}

unit_state_ru() {
    local state
    state="$(systemctl is-active "$1" 2>/dev/null || true)"
    case "$state" in
        active) printf 'работает' ;;
        inactive) printf 'остановлен' ;;
        failed) printf 'ошибка' ;;
        activating) printf 'запускается' ;;
        deactivating) printf 'останавливается' ;;
        *) printf '%s' "${state:-неизвестно}" ;;
    esac
}

start_site() {
    require_installed
    remove_stale_validation_override || \
        die "Не удалось очистить validation override прерванной операции."
    systemctl enable "$SERVICE_NAME" vpn-site-backup.timer
    systemctl start "$SERVICE_NAME"
    wait_for_local_health 45 || die "Сервис запущен, но не прошёл проверку работоспособности."
    activate_tls_nginx "$DOMAIN" || \
        die "Backend запущен, но публичную конфигурацию Nginx применить не удалось."
    verify_local_https_routes || die "Публичные маршруты сайта не прошли проверку."
    systemctl start vpn-site-backup.timer
    success "Сайт запущен."
}

stop_site() {
    require_installed
    systemctl stop "$SERVICE_NAME"
    success "Сайт остановлен. Nginx продолжает работать."
}

restart_site() {
    require_installed
    remove_stale_validation_override || \
        die "Не удалось очистить validation override прерванной операции."
    systemctl enable "$SERVICE_NAME" vpn-site-backup.timer
    systemctl restart "$SERVICE_NAME"
    wait_for_local_health 45 || die "После перезапуска сервис не прошёл проверку работоспособности."
    activate_tls_nginx "$DOMAIN" || \
        die "Backend перезапущен, но публичную конфигурацию Nginx применить не удалось."
    verify_local_https_routes || die "Публичные маршруты сайта не прошли проверку."
    systemctl start vpn-site-backup.timer
    success "Сайт перезапущен."
}

show_status() {
    if ! is_installed; then
        printf 'Сайт: не установлен\n'
        return 0
    fi
    printf 'Сайт: установлен\n'
    printf 'Домен: https://%s\n' "$DOMAIN"
    printf 'Репозиторий: %s\n' "$SITE_REPOSITORY"
    printf 'Настроенная Git-ссылка: %s\n' "$SITE_REF"
    printf 'Текущий коммит: %s\n' "$CURRENT_SHA"
    printf 'Сервис: %s\n' "$(unit_state_ru "$SERVICE_NAME")"
    printf 'Nginx: %s\n' "$(unit_state_ru nginx)"
    printf 'PostgreSQL: %s\n' "$(unit_state_ru postgresql)"
    printf 'Таймер Certbot: %s\n' "$(unit_state_ru certbot.timer)"
    if wait_for_local_health 3; then
        printf 'Локальная проверка: работает\n'
    else
        printf 'Локальная проверка: ОШИБКА\n'
    fi
}

show_logs() {
    require_installed
    printf '\nЖурнал приложения\n\n'
    journalctl -u "$SERVICE_NAME" -n 200 --no-pager
    printf '\nОшибки Nginx\n\n'
    if [[ -r /var/log/nginx/error.log ]]; then
        tail -n 100 /var/log/nginx/error.log
    else
        warn "Журнал ошибок Nginx недоступен для чтения."
    fi
}

require_manager_owned_database() {
    local database_url
    database_url="$(env_get DATABASE_URL)"
    [[ "$database_url" =~ ^postgresql\+asyncpg://vpn_site:[^@/]+@(127\.0\.0\.1|localhost):5432/vpn_site$ ]] || \
        die "Бэкап и восстановление менеджера поддерживают только созданную им локальную БД vpn_site."
}

create_backup() {
    local timestamp database_backup database_temporary config_backup config_temporary
    local metadata database_checksum config_checksum retention_policy="${1:-apply-retention}"
    CREATED_DATABASE_BACKUP=""
    require_installed
    require_manager_owned_database
    [[ "$retention_policy" == "apply-retention" || \
       "$retention_policy" == "skip-retention" ]] || {
        error "Некорректный режим retention резервной копии."
        return 1
    }
    validate_integer_range "$BACKUP_RETENTION_DAYS" 1 3650 || {
        error "BACKUP_RETENTION_DAYS должен быть от 1 до 3650."
        return 1
    }
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
    install -d -o root -g root -m 0700 "$DB_BACKUP_DIR" \
        "$CONFIG_BACKUP_DIR" || return 1
    database_backup="$DB_BACKUP_DIR/vpn-site-$timestamp.dump"
    database_temporary="${database_backup}.partial"
    config_backup="$CONFIG_BACKUP_DIR/vpn-site-$timestamp.tar.gz"
    config_temporary="${config_backup}.partial"
    metadata="$BACKUP_ROOT/vpn-site-$timestamp.txt"
    register_temporary_path "$database_temporary"
    register_temporary_path "$config_temporary"
    info "Создаётся резервная копия PostgreSQL..."
    rm -f -- "$database_temporary" "$config_temporary" || return 1
    if ! runuser -u postgres -- pg_dump --format=custom --compress=9 vpn_site \
        >"$database_temporary"; then
        rm -f -- "$database_temporary"
        error "Не удалось создать резервную копию PostgreSQL."
        return 1
    fi
    if ! pg_restore --list "$database_temporary" >/dev/null; then
        rm -f -- "$database_temporary"
        error "PostgreSQL создал некорректный архив резервной копии."
        return 1
    fi
    if ! tar -czf "$config_temporary" --owner=0 --group=0 \
        -C / etc/vpn-site \
        -C / etc/nginx/sites-available/vpn-site \
        -C / etc/systemd/system/vpn-site.service \
        -C / etc/systemd/system/vpn-site-backup.service \
        -C / etc/systemd/system/vpn-site-backup.timer; then
        rm -f -- "$database_temporary" "$config_temporary"
        error "Не удалось создать резервную копию конфигурации."
        return 1
    fi
    if ! mv "$database_temporary" "$database_backup" || \
       ! chown root:root "$database_backup" || \
       ! chmod 0600 "$database_backup" || \
       ! mv "$config_temporary" "$config_backup" || \
       ! chmod 0600 "$config_backup"; then
        rm -f -- "$database_temporary" "$config_temporary" \
            "$database_backup" "$config_backup"
        error "Не удалось зафиксировать файлы резервной копии."
        return 1
    fi
    if ! database_checksum="$(sha256sum "$database_backup" | awk '{print $1}')" || \
       ! config_checksum="$(sha256sum "$config_backup" | awk '{print $1}')"; then
        rm -f -- "$database_backup" "$config_backup"
        error "Не удалось вычислить контрольные суммы резервной копии."
        return 1
    fi
    if ! {
        printf 'created_utc=%s\n' "$timestamp"
        printf 'domain=%s\n' "$DOMAIN"
        printf 'repository=%s\n' "$SITE_REPOSITORY"
        printf 'ref=%s\n' "$SITE_REF"
        printf 'commit=%s\n' "$CURRENT_SHA"
        printf 'database_sha256=%s\n' "$database_checksum"
        printf 'config_sha256=%s\n' "$config_checksum"
    } >"$metadata" || ! chmod 0600 "$metadata"; then
        rm -f -- "$database_backup" "$config_backup" "$metadata"
        error "Не удалось записать метаданные резервной копии."
        return 1
    fi
    if [[ "$retention_policy" == "apply-retention" ]]; then
        find "$DB_BACKUP_DIR" -type f -name '*.dump' \
            -mtime "+$BACKUP_RETENTION_DAYS" -delete || \
            warn "Не удалось удалить часть устаревших дампов."
        find "$CONFIG_BACKUP_DIR" -type f -name '*.tar.gz' \
            -mtime "+$BACKUP_RETENTION_DAYS" -delete || \
            warn "Не удалось удалить часть устаревших архивов конфигурации."
        find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.txt' \
            -mtime "+$BACKUP_RETENTION_DAYS" -delete || \
            warn "Не удалось удалить часть устаревших метаданных."
    fi
    CREATED_DATABASE_BACKUP="$database_backup"
    success "Резервная копия создана: $database_backup"
    printf '%s\n' "$database_backup"
}

restore_database_archive() {
    local backup="$1" metadata expected_checksum actual_checksum
    require_manager_owned_database
    [[ -f "$backup" ]] || { error "Резервная копия не найдена: $backup"; return 1; }
    metadata="$BACKUP_ROOT/$(basename "$backup" .dump).txt"
    if [[ -f "$metadata" ]]; then
        expected_checksum="$(awk -F= '$1 == "database_sha256" {print $2}' "$metadata")"
        actual_checksum="$(sha256sum "$backup" | awk '{print $1}')"
        [[ -n "$expected_checksum" && "$actual_checksum" == "$expected_checksum" ]] || {
            error "Контрольная сумма резервной копии не совпадает: $backup"
            return 1
        }
    fi
    pg_restore --list "$backup" >/dev/null || {
        error "Архив резервной копии некорректен: $backup"
        return 1
    }
    if ! systemctl stop "$SERVICE_NAME"; then
        error "Backend не удалось остановить; разрушительное восстановление БД отменено."
        return 1
    fi
    if (( ${RESTORE_IN_PROGRESS:-0} == 1 )); then
        RESTORE_DATABASE_DIRTY=1
    fi
    runuser -u postgres -- dropdb --if-exists --force vpn_site || return 1
    runuser -u postgres -- createdb --owner=vpn_site --encoding=UTF8 vpn_site || return 1
    # Backups deliberately remain root-only. The root shell opens the archive
    # and pg_restore, running as postgres, consumes it from standard input.
    if ! runuser -u postgres -- pg_restore --exit-on-error --no-owner \
        --role=vpn_site --dbname=vpn_site <"$backup"; then
        error "Не удалось восстановить базу данных. Сервис оставлен остановленным."
        return 1
    fi
}

restore_database_backup() {
    restore_database_archive "$1" || \
        die "Не удалось восстановить базу данных. Сервис оставлен остановленным."
}

clear_restore_state() {
    RESTORE_IN_PROGRESS=0
    RESTORE_SAFETY_BACKUP=""
    RESTORE_WAS_ACTIVE=0
    RESTORE_NGINX_BACKUP=""
    RESTORE_DATABASE_DIRTY=0
}

rollback_restore_from_trap() {
    local failed=0
    (( RESTORE_IN_PROGRESS == 1 )) || return 0
    RESTORE_IN_PROGRESS=0
    warn "Восстановление прервано. Возвращается страховочная база и прежний runtime."

    if ! systemctl stop "$SERVICE_NAME"; then
        error "Backend не удалось остановить; БД и runtime оставлены в текущем состоянии за локальным Nginx."
        clear_restore_state
        return 1
    fi
    if ! remove_validation_service_override; then
        error "Validation override не удалось снять; БД и runtime оставлены в текущем состоянии."
        clear_restore_state
        return 1
    fi
    if (( RESTORE_DATABASE_DIRTY == 1 )) && \
       [[ -n "$RESTORE_SAFETY_BACKUP" ]] && \
       ! restore_database_archive "$RESTORE_SAFETY_BACKUP"; then
        error "Не удалось вернуть страховочную базу."
        failed=1
    fi
    if [[ -n "$RESTORE_NGINX_BACKUP" && -f "$RESTORE_NGINX_BACKUP" ]] && \
       ! restore_nginx_site "$RESTORE_NGINX_BACKUP"; then
        error "Не удалось вернуть прежнюю конфигурацию Nginx."
        failed=1
    fi
    if (( failed == 0 && RESTORE_WAS_ACTIVE == 1 )); then
        if ! systemctl start "$SERVICE_NAME" || ! wait_for_local_health 60; then
            error "Страховочная база возвращена, но прежний сайт не запускается."
            failed=1
        fi
    fi
    clear_restore_state
    if (( failed != 0 )); then
        error "Автоматический откат восстановления выполнен не полностью; требуется ручная проверка."
        return 1
    fi
    success "Production возвращён к состоянию до восстановления."
}

restore_backup_interactive() {
    local selection confirmation safety_backup selected_backup nginx_backup
    local was_active=0
    require_installed
    mapfile -t backups < <(find "$DB_BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' \
        -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
    (( ${#backups[@]} > 0 )) || die "Нет доступных резервных копий базы данных."
    printf '\nДоступные резервные копии базы данных:\n'
    local index
    for index in "${!backups[@]}"; do
        printf '%d. %s\n' "$((index + 1))" "${backups[$index]}"
    done
    prompt "Номер резервной копии" selection
    validate_integer_range "$selection" 1 "${#backups[@]}" || die "Некорректный номер резервной копии."
    printf 'Введите ВОССТАНОВИТЬ, чтобы заменить текущую production-базу: ' >/dev/tty
    IFS= read -r confirmation </dev/tty
    [[ "$confirmation" == "ВОССТАНОВИТЬ" || "$confirmation" == "RESTORE" ]] || \
        die "Восстановление отменено."
    selected_backup="${backups[$((selection - 1))]}"
    require_manager_owned_database
    systemctl is-active --quiet "$SERVICE_NAME" && was_active=1
    RESTORE_WAS_ACTIVE="$was_active"
    RESTORE_IN_PROGRESS=1
    systemctl stop "$SERVICE_NAME" || \
        die "Backend не удалось остановить; восстановление отменено без изменения БД."
    if ! create_backup skip-retention >/dev/null; then
        die "Не удалось создать страховочную копию; восстановление отменено."
    fi
    safety_backup="$CREATED_DATABASE_BACKUP"
    RESTORE_SAFETY_BACKUP="$safety_backup"
    nginx_backup="$(mktemp)" || {
        die "Не удалось подготовить runtime-снимок; восстановление отменено."
    }
    register_temporary_path "$nginx_backup"
    if ! cp -a "$NGINX_SITE" "$nginx_backup"; then
        die "Не удалось сохранить Nginx; восстановление отменено."
    fi
    RESTORE_NGINX_BACKUP="$nginx_backup"

    if ! activate_tls_nginx "$DOMAIN" local-validation || \
       ! restore_database_archive "$selected_backup" || \
       ! install_validation_service_override || \
       ! systemctl start "$SERVICE_NAME" || \
       ! wait_for_local_health 60 || \
       ! validate_startup_prerequisites; then
        rollback_restore_from_trap || \
            die "Выбранная копия несовместима, а страховочный откат выполнен не полностью."
        die "Выбранная копия несовместима; production возвращён к состоянию до восстановления."
    fi
    if ! stop_validation_backend; then
        rollback_restore_from_trap || \
            die "Validation backend не удалось остановить, а страховочный откат выполнен не полностью."
        die "Validation backend не удалось безопасно остановить; восстановление отменено."
    fi

    if (( was_active == 1 )); then
        # Starting the real lifespan may perform external reconciliation. From
        # this point the selected DB is authoritative and must not be replaced.
        clear_restore_state
        if ! systemctl start "$SERVICE_NAME" || ! wait_for_local_health 60; then
            systemctl stop "$SERVICE_NAME" || \
                warn "Не удалось остановить не прошедший health-check backend."
            die "База проверена и сохранена, но production-start не удался; публичный доступ оставлен закрытым."
        fi
        restore_nginx_site "$nginx_backup" || \
            die "База и backend работают, но вернуть публичную конфигурацию Nginx не удалось."
    else
        if ! restore_nginx_site "$nginx_backup"; then
            rollback_restore_from_trap || \
                die "Nginx не удалось восстановить, а страховочный откат выполнен не полностью."
            die "Nginx не удалось восстановить; выбранная база отменена."
        fi
        clear_restore_state
    fi
    success "База данных успешно восстановлена."
}

clear_update_state() {
    UPDATE_IN_PROGRESS=0
    UPDATE_OLD_RELEASE=""
    UPDATE_BACKUP=""
    UPDATE_OLD_SHA=""
    UPDATE_OLD_REF=""
    UPDATE_OLD_SITE_REF=""
    UPDATE_WAS_ACTIVE=0
    UPDATE_ENV_BACKUP=""
    UPDATE_RUNTIME_BACKUP=""
    UPDATE_DATABASE_DIRTY=0
    UPDATE_BACKUP_TIMER_WAS_ENABLED=0
    UPDATE_DEFAULT_NGINX_STATE=""
}

capture_update_runtime_state() {
    local source default_path=/etc/nginx/sites-enabled/default
    UPDATE_RUNTIME_BACKUP="$(mktemp -d)"
    register_temporary_path "$UPDATE_RUNTIME_BACKUP"
    for source in \
        "/etc/systemd/system/$SERVICE_NAME" \
        /etc/systemd/system/vpn-site-backup.service \
        /etc/systemd/system/vpn-site-backup.timer \
        "$NGINX_SITE"; do
        [[ -f "$source" ]] || die "Не найден управляемый runtime-файл: $source"
        cp -a -- "$source" "$UPDATE_RUNTIME_BACKUP/$(basename "$source")"
    done
    if systemctl is-enabled --quiet vpn-site-backup.timer; then
        UPDATE_BACKUP_TIMER_WAS_ENABLED=1
    else
        UPDATE_BACKUP_TIMER_WAS_ENABLED=0
    fi
    if [[ -L "$default_path" ]]; then
        UPDATE_DEFAULT_NGINX_STATE="symlink"
        readlink "$default_path" >"$UPDATE_RUNTIME_BACKUP/nginx-default.target"
    elif [[ -e "$default_path" ]]; then
        UPDATE_DEFAULT_NGINX_STATE="file"
        cp -a -- "$default_path" "$UPDATE_RUNTIME_BACKUP/nginx-default"
    else
        UPDATE_DEFAULT_NGINX_STATE="absent"
    fi
}

restore_update_runtime_state() {
    local backup="$UPDATE_RUNTIME_BACKUP"
    local default_path=/etc/nginx/sites-enabled/default default_target
    [[ -d "$backup" ]] || return 1
    install -o root -g root -m 0644 "$backup/$SERVICE_NAME" \
        "/etc/systemd/system/$SERVICE_NAME" || return 1
    install -o root -g root -m 0644 "$backup/vpn-site-backup.service" \
        /etc/systemd/system/vpn-site-backup.service || return 1
    install -o root -g root -m 0644 "$backup/vpn-site-backup.timer" \
        /etc/systemd/system/vpn-site-backup.timer || return 1
    systemctl daemon-reload || return 1
    if (( UPDATE_BACKUP_TIMER_WAS_ENABLED == 1 )); then
        systemctl enable vpn-site-backup.timer || return 1
    else
        systemctl disable vpn-site-backup.timer || return 1
    fi
    rm -f -- "$default_path" || return 1
    case "$UPDATE_DEFAULT_NGINX_STATE" in
        symlink)
            default_target="$(<"$backup/nginx-default.target")"
            ln -sfn "$default_target" "$default_path" || return 1
            ;;
        file)
            install -o root -g root -m 0644 "$backup/nginx-default" \
                "$default_path" || return 1
            ;;
        absent) ;;
        *) return 1 ;;
    esac
    restore_nginx_site "$backup/vpn-site" || return 1
}

preflight_legacy_payment_migration() {
    local release="$1" revision payment_count=0 legacy_count=0
    grep -Rqs 'revision.*20260720_0006' \
        "$release/backend/database/alembic/versions" || return 0

    revision="$(runuser -u postgres -- psql --dbname=vpn_site \
        --tuples-only --no-align --set=ON_ERROR_STOP=1 \
        --command 'SELECT version_num FROM alembic_version LIMIT 1')"
    case "$revision" in
        20260713_0001|20260713_0002|20260718_0003)
            payment_count="$(runuser -u postgres -- psql --dbname=vpn_site \
                --tuples-only --no-align --set=ON_ERROR_STOP=1 \
                --command 'SELECT count(*) FROM user_payments')"
            (( payment_count == 0 )) || die \
                "Обновление остановлено до изменения БД: migration 0006 нового сайта не умеет безопасно переносить историю отложенных платежей ($payment_count строк). Нужен совместимый bridge-release vpn-site; удалять историю или подменять auto_capture запрещено."
            ;;
        20260719_0004|20260720_0005)
            legacy_count="$(runuser -u postgres -- psql --dbname=vpn_site \
                --tuples-only --no-align --set=ON_ERROR_STOP=1 \
                --command 'SELECT count(*) FROM user_payments WHERE auto_capture IS DISTINCT FROM TRUE')"
            (( legacy_count == 0 )) || die \
                "Обновление остановлено до изменения БД: остаются неразрешённые legacy-платежи ($legacy_count строк), которые migration 0006 обоснованно отклоняет. Завершите их через совместимый bridge-release vpn-site."
            ;;
    esac
}

rollback_update_from_trap() {
    local failed=0
    (( UPDATE_IN_PROGRESS == 1 )) || return 0
    UPDATE_IN_PROGRESS=0
    warn "Обновление прервано. Восстанавливаются база, env, runtime и предыдущая версия..."
    if ! systemctl stop "$SERVICE_NAME"; then
        error "Backend не удалось остановить; код, БД и runtime оставлены в текущем состоянии за локальным Nginx."
        clear_update_state
        return 1
    fi
    if ! remove_validation_service_override; then
        error "Validation override не удалось снять; код, БД и runtime оставлены в текущем состоянии."
        clear_update_state
        return 1
    fi
    if (( UPDATE_DATABASE_DIRTY == 1 )) && \
       [[ -n "$UPDATE_BACKUP" ]] && \
       ! restore_database_archive "$UPDATE_BACKUP"; then
        error "Автоматический откат базы не удался."
        failed=1
    fi
    if ! ln -sfn "$UPDATE_OLD_RELEASE" "$CURRENT_LINK"; then
        error "Не удалось вернуть ссылку на предыдущую версию."
        failed=1
    fi
    if [[ -n "$UPDATE_ENV_BACKUP" && -f "$UPDATE_ENV_BACKUP" ]] && \
       ! install -o root -g "$APP_GROUP" -m 0640 "$UPDATE_ENV_BACKUP" "$ENV_FILE"; then
        error "Не удалось восстановить прежний env-файл."
        failed=1
    fi
    if [[ -n "$UPDATE_RUNTIME_BACKUP" ]] && ! restore_update_runtime_state; then
        error "Не удалось полностью восстановить systemd или Nginx."
        failed=1
    fi
    CURRENT_SHA="$UPDATE_OLD_SHA"
    CURRENT_REF="$UPDATE_OLD_REF"
    SITE_REF="$UPDATE_OLD_SITE_REF"
    if ! write_manager_config; then
        error "Не удалось записать предыдущее состояние менеджера."
        failed=1
    fi
    if (( failed == 0 && UPDATE_WAS_ACTIVE == 1 )); then
        if ! systemctl start "$SERVICE_NAME"; then
            error "Предыдущая версия восстановлена, но запустить сервис не удалось."
            failed=1
        elif ! wait_for_local_health 60; then
            error "Предыдущая версия восстановлена, но не прошла проверку работоспособности."
            failed=1
        fi
    fi
    clear_update_state
    if (( failed != 0 )); then
        error "Автоматический откат выполнен не полностью; требуется ручная проверка сервиса и БД."
        return 1
    fi
    success "Выполнен откат к коммиту $CURRENT_SHA."
}

rollback_update_and_die() {
    local message="$1"
    rollback_update_from_trap || \
        die "$message Автоматический откат также не удался; проверьте сервис и базу данных."
    die "$message Обновление отменено с восстановлением предыдущей версии."
}

update_site() {
    local ref sha new_release backup
    require_installed
    prompt_default "Ветка, тег или коммит для развёртывания" "$SITE_REF" ref
    validate_ref "$ref" || die "Некорректная Git-ссылка."
    read_github_token
    verify_private_repository_access "$SITE_REPOSITORY"
    sha="$(resolve_private_commit "$SITE_REPOSITORY" "$ref")"
    printf 'Текущий коммит: %s\nЦелевой коммит: %s\n' "$CURRENT_SHA" "$sha"
    if [[ "$sha" == "$CURRENT_SHA" ]]; then
        warn "Код уже актуален; будут проверены env и runtime-файлы новой версии."
    fi
    confirm "Создать непротиворечивую резервную копию и применить release?" no || {
        clear_github_token
        return 0
    }

    prepare_site_release "$sha"
    new_release="$PREPARED_SITE_RELEASE"
    validate_release_public_domain "$new_release" "$DOMAIN" || \
        die "Обычное обновление не активирует release с SEO-метаданными другого домена."
    preflight_legacy_payment_migration "$new_release"
    require_manager_owned_database
    UPDATE_OLD_RELEASE="$(readlink -f "$CURRENT_LINK")"
    UPDATE_OLD_SHA="$CURRENT_SHA"
    UPDATE_OLD_REF="$CURRENT_REF"
    UPDATE_OLD_SITE_REF="$SITE_REF"
    UPDATE_ENV_BACKUP="$(backup_environment)"
    capture_update_runtime_state
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        UPDATE_WAS_ACTIVE=1
    else
        UPDATE_WAS_ACTIVE=0
    fi
    UPDATE_IN_PROGRESS=1
    systemctl stop "$SERVICE_NAME"
    if ! create_backup >/dev/null; then
        rollback_update_and_die "Не удалось создать резервную копию остановленного сайта."
    fi
    backup="$CREATED_DATABASE_BACKUP"
    UPDATE_BACKUP="$backup"

    migrate_environment_for_release "$new_release"
    if ! validate_environment_schema_for_release "$new_release" || \
       ! validate_application_environment "$new_release"; then
        rollback_update_and_die "Новая версия отклонила конфигурацию окружения."
    fi

    UPDATE_DATABASE_DIRTY=1
    if ! "$(envexec_path)" "$ENV_FILE" "$new_release/.venv/bin/python" \
        -m alembic -c "$new_release/alembic.ini" upgrade head; then
        rollback_update_and_die "Не удалось выполнить миграцию базы данных."
    fi
    if ! "$(envexec_path)" "$ENV_FILE" "$new_release/.venv/bin/python" \
        -m alembic -c "$new_release/alembic.ini" check; then
        rollback_update_and_die "Схема БД расходится с моделями новой версии."
    fi
    if ! activate_tls_nginx "$DOMAIN" local-validation "$new_release"; then
        rollback_update_and_die "Не удалось закрыть Nginx для локальной проверки."
    fi
    ln -sfn "$new_release" "$CURRENT_LINK"
    CURRENT_SHA="$sha"
    CURRENT_REF="$ref"
    SITE_REF="$ref"
    write_manager_config
    install_systemd_units
    if ! install_validation_service_override || \
       ! systemctl start "$SERVICE_NAME" || \
       ! wait_for_local_health 60 || \
       ! validate_startup_prerequisites || \
       ! verify_local_https_routes; then
        rollback_update_and_die "Новая версия не прошла изолированную runtime-проверку."
    fi
    if ! stop_validation_backend; then
        rollback_update_and_die "Validation backend не удалось безопасно остановить."
    fi

    if (( UPDATE_WAS_ACTIVE == 1 )); then
        # The real lifespan starts provider reconciliation. Committing first
        # keeps its external effects consistent with the authoritative DB.
        clear_update_state
        if ! systemctl start "$SERVICE_NAME" || ! wait_for_local_health 60; then
            systemctl stop "$SERVICE_NAME" || \
                warn "Не удалось остановить не прошедший health-check backend."
            die "Release проверен и сохранён, но production-start не удался; публичный доступ оставлен закрытым."
        fi
        activate_tls_nginx "$DOMAIN" || \
            die "Новый backend работает, но открыть публичный доступ через Nginx не удалось."
    else
        if ! activate_tls_nginx "$DOMAIN"; then
            rollback_update_and_die "Не удалось применить публичные Nginx-маршруты новой версии."
        fi
        clear_update_state
    fi
    clear_github_token
    prune_releases
    success "Сайт обновлён до коммита $sha."
}

repair_runtime_configuration() {
    local was_active=0 env_backup
    require_installed
    [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && \
       -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]] || \
        die "Сертификат для $DOMAIN отсутствует. Выпустите его заново в меню сертификатов."
    systemctl is-active --quiet "$SERVICE_NAME" && was_active=1
    remove_stale_validation_override || \
        die "Не удалось очистить validation override прерванной операции."
    env_backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$env_backup"
    migrate_environment_for_release "$CURRENT_LINK"
    validate_environment_schema_for_release "$CURRENT_LINK"
    validate_application_environment
    # From here env matches the current release and must not be rolled back
    # independently if a later runtime repair needs to be retried.
    ACTIVE_ENV_BACKUP=""
    install_systemd_units
    install_renewal_hook
    activate_tls_nginx "$DOMAIN" || die "Восстановленная конфигурация Nginx некорректна."
    systemctl enable "$SERVICE_NAME"
    systemctl enable --now vpn-site-backup.timer certbot.timer
    if (( was_active == 1 )); then
        systemctl restart "$SERVICE_NAME"
        wait_for_local_health 60 || die "Системные файлы восстановлены, но сайт не прошёл проверку работоспособности."
        verify_local_https_routes || die "Восстановленные Nginx-маршруты не прошли проверку."
    fi
    success "Файлы интеграции systemd, Nginx и Certbot восстановлены."
}

update_manager() {
    local sha archive staging
    validate_repository "$MANAGER_REPOSITORY" || die "Некорректный репозиторий менеджера."
    validate_ref "$MANAGER_REF" || die "Некорректная Git-ссылка менеджера."
    info "Проверяется публичный репозиторий менеджера..."
    sha="$(resolve_public_commit "$MANAGER_REPOSITORY" "$MANAGER_REF")"
    archive="$(mktemp --suffix=.tar.gz)"
    staging="$(mktemp -d)"
    register_temporary_path "$archive"
    register_temporary_path "$staging"
    download_public_archive "$MANAGER_REPOSITORY" "$sha" "$archive"
    tar -xzf "$archive" -C "$staging" --strip-components=1 \
        --no-same-owner --no-same-permissions
    [[ -f "$staging/install.sh" && -f "$staging/lib/common.sh" ]] || \
        die "Загруженный архив менеджера неполон."
    bash -n "$staging/install.sh" "$staging/lib/"*.sh
    install_manager_from_source "$staging"
    if is_installed; then
        repair_runtime_configuration
    fi
    success "Менеджер обновлён из коммита $sha. Перезапустите меню для работы с новой версией."
}

run_diagnostics() {
    local failed=0 owner mode
    require_installed
    printf '\nДиагностика VPN Site\n\n'
    systemctl is-active --quiet postgresql || { error "PostgreSQL не работает."; failed=1; }
    systemctl is-active --quiet nginx || { error "Nginx не работает."; failed=1; }
    systemctl is-active --quiet "$SERVICE_NAME" || { error "Сервис сайта не работает."; failed=1; }
    nginx -t || failed=1
    systemd-analyze verify "/etc/systemd/system/$SERVICE_NAME" \
        /etc/systemd/system/vpn-site-backup.service \
        /etc/systemd/system/vpn-site-backup.timer || failed=1
    "$(envctl_path)" validate "$ENV_FILE" || failed=1
    validate_application_environment || failed=1
    validate_environment_schema_for_release "$CURRENT_LINK" || failed=1
    "$CURRENT_LINK/.venv/bin/python" -m pip check || failed=1
    (
        cd "$CURRENT_LINK/backend"
        "$(envexec_path)" "$ENV_FILE" "$CURRENT_LINK/.venv/bin/python" \
            -m alembic -c "$CURRENT_LINK/alembic.ini" check
    ) || failed=1
    validate_release_public_domain "$CURRENT_LINK" "$DOMAIN" || failed=1
    owner="$(stat -c '%U:%G' "$ENV_FILE")"
    mode="$(stat -c '%a' "$ENV_FILE")"
    [[ "$owner" == "root:$APP_GROUP" && "$mode" == "640" ]] || {
        error "Неожиданные владелец или права env-файла: $owner $mode"; failed=1;
    }
    wait_for_local_health 5 || { error "Локальная проверка работоспособности не пройдена."; failed=1; }
    verify_local_https_routes || failed=1
    wait_for_public_health 10 || { error "Публичная проверка HTTPS не пройдена."; failed=1; }
    [[ "$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)" == "yes" ]] || {
        error "Системное время не синхронизировано через NTP."; failed=1;
    }
    openssl x509 -checkend $((21 * 86400)) -noout \
        -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" || {
        error "Срок сертификата истекает менее чем через 21 день."; failed=1;
    }
    systemctl is-enabled --quiet vpn-site-backup.timer || {
        error "Таймер резервного копирования не включён."; failed=1;
    }
    df -h / "$BACKUP_ROOT"
    if (( failed == 0 )); then
        success "Все production-проверки пройдены."
    else
        die "Одна или несколько диагностических проверок завершились ошибкой."
    fi
}

configure_smtp() {
    local backup host port timeout concurrency user password from_email
    require_installed
    prompt_default "Хост SMTP" "$(env_get SMTP_HOST)" host
    prompt_default "TLS-порт SMTP" "$(env_get SMTP_PORT)" port
    validate_integer_range "$port" 1 65535 || die "Некорректный порт SMTP."
    prompt_default "Тайм-аут SMTP в секундах" \
        "$(env_get SMTP_TIMEOUT_SECONDS 2>/dev/null || printf 15)" timeout
    validate_integer_range "$timeout" 1 60 || die "Тайм-аут SMTP должен быть от 1 до 60 секунд."
    prompt_default "Максимум параллельных SMTP-отправок" \
        "$(env_get SMTP_MAX_CONCURRENCY 2>/dev/null || printf 5)" concurrency
    validate_integer_range "$concurrency" 1 20 || \
        die "Число параллельных SMTP-отправок должно быть от 1 до 20."
    prompt_default "Имя пользователя SMTP" "$(env_get SMTP_USER)" user
    validate_ascii_graphic "$user" || \
        die "Имя пользователя SMTP должно состоять из печатных ASCII-символов без пробелов."
    prompt_secret "Новый пароль SMTP (не менее 10 символов)" password
    (( ${#password} >= 10 )) || die "Пароль SMTP слишком короткий."
    validate_no_control_characters "Пароль SMTP" "$password"
    validate_ascii_printable "$password" || \
        die "Пароль SMTP должен состоять из печатных ASCII-символов."
    prompt_default "Email отправителя" "$(env_get FROM_EMAIL)" from_email
    validate_email "$from_email" || die "Некорректный email отправителя."
    backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$backup"
    env_set SMTP_HOST "$host"
    env_set SMTP_PORT "$port"
    env_set SMTP_TIMEOUT_SECONDS "$timeout"
    env_set SMTP_MAX_CONCURRENCY "$concurrency"
    env_set SMTP_USER "$user"
    env_set SMTP_PASSWORD "$password"
    env_set FROM_EMAIL "$from_email"
    apply_environment_change "$backup"
}

configure_remnawave() {
    local backup url token cookies
    require_installed
    prompt_default "URL API Remnawave" "$(env_get REMNAWAVE_API_URL)" url
    validate_https_url "$url" || die "URL должен использовать HTTPS."
    prompt_secret "Новый токен Remnawave (не менее 32 символов)" token
    (( ${#token} >= 32 )) || die "Токен слишком короткий."
    validate_ascii_graphic "$token" || \
        die "Токен Remnawave должен состоять из печатных ASCII-символов без пробелов."
    prompt_secret_optional \
        "Новые cookies Remnawave в формате JSON (Enter — оставить текущие)" cookies
    [[ -n "$cookies" ]] || cookies="$(env_get REMNAWAVE_COOKIES_JSON)"
    normalize_json_object "$cookies" cookies || \
        die "Значение cookies должно быть корректным JSON-объектом."
    backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$backup"
    env_set REMNAWAVE_API_URL "$url"
    env_set REMNAWAVE_TOKEN "$token"
    env_set REMNAWAVE_COOKIES_JSON "$cookies"
    apply_environment_change "$backup"
}

show_yookassa_webhook() {
    local webhook_secret
    webhook_secret="$(env_get YOOKASSA_WEBHOOK_SECRET 2>/dev/null || true)"
    [[ -n "$webhook_secret" ]] || return 0
    printf '\nУкажите этот webhook в личном кабинете YooKassa:\n'
    printf 'https://%s/payments/yookassa/webhook?token=%s\n' \
        "$DOMAIN" "$webhook_secret"
}

configure_yookassa() {
    local backup shop_id secret webhook_secret
    require_installed
    if confirm "Включить или заменить интеграцию YooKassa?" yes; then
        prompt "Идентификатор магазина YooKassa" shop_id
        [[ "$shop_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "Некорректный идентификатор магазина."
        prompt_secret "Секретный ключ YooKassa (не менее 32 символов)" secret
        (( ${#secret} >= 32 )) || die "Секретный ключ слишком короткий."
        validate_ascii_graphic "$secret" || \
            die "Секретный ключ должен состоять из печатных ASCII-символов без пробелов."
        webhook_secret="$(random_hex 32)"
        backup="$(backup_environment)"
        ACTIVE_ENV_BACKUP="$backup"
        env_set YOOKASSA_SHOP_ID "$shop_id"
        env_set YOOKASSA_SECRET_KEY "$secret"
        env_set YOOKASSA_WEBHOOK_SECRET "$webhook_secret"
        apply_environment_change "$backup"
        show_yookassa_webhook
    else
        confirm "Отключить платежи YooKassa?" no || return 0
        backup="$(backup_environment)"
        ACTIVE_ENV_BACKUP="$backup"
        env_set YOOKASSA_SHOP_ID ""
        env_set YOOKASSA_SECRET_KEY ""
        env_set YOOKASSA_WEBHOOK_SECRET ""
        apply_environment_change "$backup"
    fi
}

configure_limits() {
    local backup key current value minimum maximum
    require_installed
    printf 'Доступные для изменения лимиты:\n'
    printf '1. CLEANUP_INTERVAL_SECONDS (10..86400)\n'
    printf '2. SUBSCRIPTION_NOTIFICATION_BATCH_SIZE (1..1000)\n'
    printf '3. SUBSCRIPTION_NOTIFICATION_CONCURRENCY (1..20)\n'
    printf '4. SUBSCRIPTION_NOTIFICATION_RETRY_MINUTES (1..1440)\n'
    printf '5. MAX_REQUEST_BODY_BYTES (1024..10485760)\n'
    printf '6. RATE_LIMIT_WINDOW_SECONDS (1..3600)\n'
    printf '7. RATE_LIMIT_REQUESTS (10..10000)\n'
    printf '8. AUTH_RATE_LIMIT_REQUESTS (2..1000)\n'
    printf '9. WEBHOOK_RATE_LIMIT_REQUESTS (2..1000)\n'
    prompt "Номер" value
    case "$value" in
        1) key=CLEANUP_INTERVAL_SECONDS; minimum=10; maximum=86400 ;;
        2) key=SUBSCRIPTION_NOTIFICATION_BATCH_SIZE; minimum=1; maximum=1000 ;;
        3) key=SUBSCRIPTION_NOTIFICATION_CONCURRENCY; minimum=1; maximum=20 ;;
        4) key=SUBSCRIPTION_NOTIFICATION_RETRY_MINUTES; minimum=1; maximum=1440 ;;
        5) key=MAX_REQUEST_BODY_BYTES; minimum=1024; maximum=10485760 ;;
        6) key=RATE_LIMIT_WINDOW_SECONDS; minimum=1; maximum=3600 ;;
        7) key=RATE_LIMIT_REQUESTS; minimum=10; maximum=10000 ;;
        8) key=AUTH_RATE_LIMIT_REQUESTS; minimum=2; maximum=1000 ;;
        9) key=WEBHOOK_RATE_LIMIT_REQUESTS; minimum=2; maximum=1000 ;;
        *) die "Некорректный выбор." ;;
    esac
    if ! current="$(env_get "$key" 2>/dev/null)"; then
        case "$key" in
            SUBSCRIPTION_NOTIFICATION_BATCH_SIZE) current=100 ;;
            SUBSCRIPTION_NOTIFICATION_CONCURRENCY) current=5 ;;
            SUBSCRIPTION_NOTIFICATION_RETRY_MINUTES) current=5 ;;
            *) die "В env-файле отсутствует обязательная настройка $key." ;;
        esac
    fi
    prompt_default "$key" "$current" value
    validate_integer_range "$value" "$minimum" "$maximum" || die "Значение находится вне допустимого диапазона."
    backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$backup"
    env_set "$key" "$value"
    apply_environment_change "$backup"
}

finish_admin_bootstrap() {
    local backup email completed
    require_installed
    email="$(env_get ADMIN_BOOTSTRAP_EMAILS || true)"
    if [[ -z "$email" ]]; then
        success "Выдача прав первого администратора уже завершена; ADMIN_BOOTSTRAP_EMAILS пуст."
        return 0
    fi

    printf '\nЗавершение выдачи прав первого администратора\n\n'
    printf '1. Откройте https://%s и войдите с email %s.\n' "$DOMAIN" "$email"
    printf '2. Убедитесь, что учётная запись получила права администратора.\n\n'
    if ! confirm "Вход выполнен и права администратора получены?" no; then
        warn "ADMIN_BOOTSTRAP_EMAILS оставлен без изменений. Завершить процедуру можно позже в настройках окружения."
        return 0
    fi
    if ! completed="$(runuser -u postgres -- psql --dbname=vpn_site \
        --tuples-only --no-align --set=ON_ERROR_STOP=1 \
        --command 'SELECT completed FROM admin_bootstrap_state WHERE singleton_id = 1')"; then
        warn "Не удалось проверить bootstrap в PostgreSQL; env-файл не изменён."
        return 0
    fi
    if [[ "$completed" != "t" ]]; then
        warn "PostgreSQL ещё не подтверждает завершение bootstrap; ADMIN_BOOTSTRAP_EMAILS оставлен без изменений."
        return 0
    fi

    backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$backup"
    env_set ADMIN_BOOTSTRAP_EMAILS ""
    apply_environment_change "$backup" restart
    success "ADMIN_BOOTSTRAP_EMAILS очищен, сайт перезапущен."
}

configure_backup_retention() {
    local value
    require_installed
    prompt_default "Срок хранения резервных копий в днях" "$BACKUP_RETENTION_DAYS" value
    validate_integer_range "$value" 1 3650 || die "Укажите значение от 1 до 3650 дней."
    BACKUP_RETENTION_DAYS="$value"
    write_manager_config
    success "Срок хранения резервных копий изменён: $BACKUP_RETENTION_DAYS дней."
}

environment_menu() {
    local choice
    while true; do
        clear
        printf 'Менеджер VPN Site - настройки окружения\n\n'
        printf '1. SMTP\n'
        printf '2. Remnawave\n'
        printf '3. YooKassa\n'
        printf '4. Ограничения запросов и рабочие лимиты\n'
        printf '5. Завершить выдачу прав первого администратора\n'
        printf '6. Безопасная сводка конфигурации\n'
        printf '7. Редактировать полный env-файл\n'
        printf '0. Назад\n\n'
        printf 'Выберите пункт: ' >/dev/tty
        IFS= read -r choice </dev/tty
        case "$choice" in
            1) configure_smtp; pause ;;
            2) configure_remnawave; pause ;;
            3) configure_yookassa; pause ;;
            4) configure_limits; pause ;;
            5) finish_admin_bootstrap; pause ;;
            6) show_environment_summary; pause ;;
            7) edit_environment_file; pause ;;
            0) return 0 ;;
            *) warn "Неизвестный пункт меню."; pause ;;
        esac
    done
}

backup_menu() {
    local choice
    while true; do
        clear
        printf 'Менеджер VPN Site - резервные копии\n\n'
        printf '1. Создать резервную копию сейчас\n'
        printf '2. Показать резервные копии\n'
        printf '3. Восстановить базу данных\n'
        printf '4. Изменить срок хранения\n'
        printf '0. Назад\n\n'
        printf 'Выберите пункт: ' >/dev/tty
        IFS= read -r choice </dev/tty
        case "$choice" in
            1) create_backup; pause ;;
            2) find "$BACKUP_ROOT" -maxdepth 2 -type f -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n' | sort -r; pause ;;
            3) restore_backup_interactive; pause ;;
            4) configure_backup_retention; pause ;;
            0) return 0 ;;
            *) warn "Неизвестный пункт меню."; pause ;;
        esac
    done
}

show_help() {
    cat <<EOF
Менеджер VPN Site $MANAGER_VERSION

Использование: sudo vpn-site [команда]

Команды:
  install          Запустить мастер первоначальной установки
  status           Показать состояние сервисов и сайта
  start|stop       Запустить или остановить backend сайта
  restart          Перезапустить сайт и проверить его работу
  update           Обновить сайт из приватного репозитория GitHub
  backup           Создать production-бэкап без интерактивного ввода
  diagnose         Выполнить production-диагностику
  logs             Показать последние журналы приложения
  update-manager   Обновить менеджер из публичного репозитория
  os-update        Установить обновления безопасности и пакетов Ubuntu
  repair           Переустановить управляемые файлы systemd, Nginx и Certbot
  menu             Открыть интерактивное меню (по умолчанию)
EOF
}

main_menu() {
    local choice
    while true; do
        clear
        printf 'Менеджер VPN Site %s\n\n' "$MANAGER_VERSION"
        if is_installed; then
            printf 'Домен: https://%s\n' "$DOMAIN"
            printf 'Сервис: %s\n\n' "$(unit_state_ru "$SERVICE_NAME")"
            printf '1. Состояние\n'
            printf '2. Запустить сайт\n'
            printf '3. Остановить сайт\n'
            printf '4. Перезапустить сайт\n'
            printf '5. Обновить сайт\n'
            printf '6. Настройки окружения\n'
            printf '7. Сертификаты и домен\n'
            printf '8. Резервные копии и восстановление\n'
            printf '9. Диагностика\n'
            printf '10. Журналы приложения\n'
            printf '11. Обновить менеджер\n'
            printf '12. Обновить пакеты Ubuntu\n'
            printf '13. Восстановить системную интеграцию\n'
            printf '0. Выход\n\n'
            printf 'Выберите пункт: ' >/dev/tty
            IFS= read -r choice </dev/tty
            case "$choice" in
                1) show_status; pause ;;
                2) start_site; pause ;;
                3) stop_site; pause ;;
                4) restart_site; pause ;;
                5) update_site; pause ;;
                6) environment_menu ;;
                7) certificate_menu ;;
                8) backup_menu ;;
                9) run_diagnostics; pause ;;
                10) show_logs; pause ;;
                11) update_manager; pause; return 0 ;;
                12) update_operating_system; pause ;;
                13) repair_runtime_configuration; pause ;;
                0) return 0 ;;
                *) warn "Неизвестный пункт меню."; pause ;;
            esac
        else
            printf 'Сайт не установлен.\n\n'
            printf '1. Установить сайт\n'
            printf '2. Обновить менеджер\n'
            printf '0. Выход\n\n'
            printf 'Выберите пункт: ' >/dev/tty
            IFS= read -r choice </dev/tty
            case "$choice" in
                1) initial_install; pause ;;
                2) update_manager; pause; return 0 ;;
                0) return 0 ;;
                *) warn "Неизвестный пункт меню."; pause ;;
            esac
        fi
    done
}
