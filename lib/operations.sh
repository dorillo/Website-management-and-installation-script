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
    systemctl start "$SERVICE_NAME"
    wait_for_local_health 45 || die "Сервис запущен, но не прошёл проверку работоспособности."
    success "Сайт запущен."
}

stop_site() {
    require_installed
    systemctl stop "$SERVICE_NAME"
    success "Сайт остановлен. Nginx продолжает работать."
}

restart_site() {
    require_installed
    systemctl restart "$SERVICE_NAME"
    wait_for_local_health 45 || die "После перезапуска сервис не прошёл проверку работоспособности."
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

create_backup() {
    local timestamp database_backup database_temporary config_backup config_temporary metadata
    require_installed
    validate_integer_range "$BACKUP_RETENTION_DAYS" 1 3650 || \
        die "BACKUP_RETENTION_DAYS должен быть от 1 до 3650."
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -o root -g root -m 0700 "$DB_BACKUP_DIR" "$CONFIG_BACKUP_DIR"
    database_backup="$DB_BACKUP_DIR/vpn-site-$timestamp.dump"
    database_temporary="${database_backup}.partial"
    config_backup="$CONFIG_BACKUP_DIR/vpn-site-$timestamp.tar.gz"
    config_temporary="${config_backup}.partial"
    metadata="$BACKUP_ROOT/vpn-site-$timestamp.txt"
    register_temporary_path "$database_temporary"
    register_temporary_path "$config_temporary"
    info "Создаётся резервная копия PostgreSQL..."
    rm -f -- "$database_temporary" "$config_temporary"
    if ! runuser -u postgres -- pg_dump --format=custom --compress=9 vpn_site \
        >"$database_temporary"; then
        rm -f -- "$database_temporary"
        die "Не удалось создать резервную копию PostgreSQL."
    fi
    pg_restore --list "$database_temporary" >/dev/null || {
        rm -f -- "$database_temporary"
        die "PostgreSQL создал некорректный архив резервной копии."
    }
    if ! tar -czf "$config_temporary" --owner=0 --group=0 \
        -C / etc/vpn-site \
        -C / etc/nginx/sites-available/vpn-site \
        -C / etc/systemd/system/vpn-site.service \
        -C / etc/systemd/system/vpn-site-backup.service \
        -C / etc/systemd/system/vpn-site-backup.timer; then
        rm -f -- "$database_temporary" "$config_temporary"
        die "Не удалось создать резервную копию конфигурации."
    fi
    mv "$database_temporary" "$database_backup"
    chown root:root "$database_backup"
    chmod 0600 "$database_backup"
    mv "$config_temporary" "$config_backup"
    chmod 0600 "$config_backup"
    {
        printf 'created_utc=%s\n' "$timestamp"
        printf 'domain=%s\n' "$DOMAIN"
        printf 'repository=%s\n' "$SITE_REPOSITORY"
        printf 'ref=%s\n' "$SITE_REF"
        printf 'commit=%s\n' "$CURRENT_SHA"
        printf 'database_sha256=%s\n' "$(sha256sum "$database_backup" | awk '{print $1}')"
        printf 'config_sha256=%s\n' "$(sha256sum "$config_backup" | awk '{print $1}')"
    } >"$metadata"
    chmod 0600 "$metadata"
    find "$DB_BACKUP_DIR" -type f -name '*.dump' -mtime "+$BACKUP_RETENTION_DAYS" -delete
    find "$CONFIG_BACKUP_DIR" -type f -name '*.tar.gz' -mtime "+$BACKUP_RETENTION_DAYS" -delete
    find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.txt' -mtime "+$BACKUP_RETENTION_DAYS" -delete
    success "Резервная копия создана: $database_backup"
    printf '%s\n' "$database_backup"
}

restore_database_archive() {
    local backup="$1"
    [[ -f "$backup" ]] || { error "Резервная копия не найдена: $backup"; return 1; }
    pg_restore --list "$backup" >/dev/null || {
        error "Архив резервной копии некорректен: $backup"
        return 1
    }
    systemctl stop "$SERVICE_NAME" || true
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

restore_backup_interactive() {
    local selection confirmation safety_backup selected_backup
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
    safety_backup="$(create_backup | tail -1)"
    if ! restore_database_archive "$selected_backup"; then
        warn "Восстанавливается страховочная копия, созданная непосредственно перед операцией."
        restore_database_archive "$safety_backup" || \
            die "Обе попытки восстановления завершились ошибкой. Сервис оставлен остановленным."
        systemctl start "$SERVICE_NAME"
        die "Выбранную копию восстановить не удалось; production возвращён к прежней базе данных."
    fi
    systemctl start "$SERVICE_NAME"
    wait_for_local_health 60 || die "База восстановлена, но приложение не прошло проверку работоспособности."
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
}

rollback_update_from_trap() {
    (( UPDATE_IN_PROGRESS == 1 )) || return 0
    UPDATE_IN_PROGRESS=0
    warn "Обновление прервано. Восстанавливаются база данных и предыдущая версия..."
    systemctl stop "$SERVICE_NAME" || true
    if ! restore_database_archive "$UPDATE_BACKUP"; then
        error "Автоматический откат базы не удался; сервис оставлен остановленным."
        clear_update_state
        return 1
    fi
    if ! ln -sfn "$UPDATE_OLD_RELEASE" "$CURRENT_LINK"; then
        error "База восстановлена, но вернуть ссылку на предыдущую версию не удалось."
        clear_update_state
        return 1
    fi
    CURRENT_SHA="$UPDATE_OLD_SHA"
    CURRENT_REF="$UPDATE_OLD_REF"
    SITE_REF="$UPDATE_OLD_SITE_REF"
    if ! write_manager_config; then
        error "Версия восстановлена, но записать предыдущее состояние менеджера не удалось."
        clear_update_state
        return 1
    fi
    if (( UPDATE_WAS_ACTIVE == 1 )); then
        if ! systemctl start "$SERVICE_NAME"; then
            error "Предыдущая версия восстановлена, но запустить сервис не удалось."
            clear_update_state
            return 1
        fi
        if ! wait_for_local_health 60; then
            error "Предыдущая версия восстановлена, но не прошла проверку работоспособности."
            clear_update_state
            return 1
        fi
    fi
    success "Выполнен откат к коммиту $CURRENT_SHA."
    clear_update_state
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
    if [[ "$sha" == "$CURRENT_SHA" ]]; then
        clear_github_token
        success "На сайте уже установлен коммит $sha."
        return 0
    fi
    printf 'Текущий коммит: %s\nЦелевой коммит: %s\n' "$CURRENT_SHA" "$sha"
    confirm "Создать резервную копию и установить обновление?" no || {
        clear_github_token
        return 0
    }

    prepare_site_release "$sha"
    new_release="$PREPARED_SITE_RELEASE"
    validate_application_environment "$new_release"
    backup="$(create_backup | tail -1)"
    UPDATE_OLD_RELEASE="$(readlink -f "$CURRENT_LINK")"
    UPDATE_BACKUP="$backup"
    UPDATE_OLD_SHA="$CURRENT_SHA"
    UPDATE_OLD_REF="$CURRENT_REF"
    UPDATE_OLD_SITE_REF="$SITE_REF"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        UPDATE_WAS_ACTIVE=1
    else
        UPDATE_WAS_ACTIVE=0
    fi
    UPDATE_IN_PROGRESS=1
    systemctl stop "$SERVICE_NAME"

    if ! "$(envexec_path)" "$ENV_FILE" "$new_release/.venv/bin/python" \
        -m alembic -c "$new_release/alembic.ini" upgrade head; then
        rollback_update_and_die "Не удалось выполнить миграцию базы данных."
    fi
    ln -sfn "$new_release" "$CURRENT_LINK"
    CURRENT_SHA="$sha"
    CURRENT_REF="$ref"
    SITE_REF="$ref"
    write_manager_config
    systemctl start "$SERVICE_NAME"
    if ! wait_for_local_health 60; then
        rollback_update_and_die "Новая версия не прошла проверку работоспособности."
    fi
    if (( UPDATE_WAS_ACTIVE == 0 )); then
        systemctl stop "$SERVICE_NAME"
    fi
    clear_update_state
    clear_github_token
    prune_releases
    success "Сайт обновлён до коммита $sha."
}

repair_runtime_configuration() {
    local was_active=0
    require_installed
    [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && \
       -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]] || \
        die "Сертификат для $DOMAIN отсутствует. Выпустите его заново в меню сертификатов."
    systemctl is-active --quiet "$SERVICE_NAME" && was_active=1
    install_systemd_units
    install_renewal_hook
    activate_tls_nginx "$DOMAIN" || die "Восстановленная конфигурация Nginx некорректна."
    systemctl enable "$SERVICE_NAME"
    systemctl enable --now vpn-site-backup.timer certbot.timer
    if (( was_active == 1 )); then
        systemctl restart "$SERVICE_NAME"
        wait_for_local_health 60 || die "Системные файлы восстановлены, но сайт не прошёл проверку работоспособности."
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
    "$(envctl_path)" validate "$ENV_FILE" || failed=1
    validate_application_environment || failed=1
    owner="$(stat -c '%U:%G' "$ENV_FILE")"
    mode="$(stat -c '%a' "$ENV_FILE")"
    [[ "$owner" == "root:$APP_GROUP" && "$mode" == "640" ]] || {
        error "Неожиданные владелец или права env-файла: $owner $mode"; failed=1;
    }
    wait_for_local_health 5 || { error "Локальная проверка работоспособности не пройдена."; failed=1; }
    wait_for_public_health 10 || { error "Публичная проверка HTTPS не пройдена."; failed=1; }
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

configure_public_settings() {
    local backup mode value brand site title tagline inn1 inn2 neutral_title neutral_tagline
    require_installed
    mode="$(env_get PUBLIC_COPY_MODE)"
    brand="$(env_get BRAND_NAME)"
    site="$(env_get SITE_NAME)"
    title="$(env_get SITE_TITLE)"
    tagline="$(env_get SITE_TAGLINE)"
    inn1="$(env_get PUBLIC_MODE_1_INN || true)"
    inn2="$(env_get PUBLIC_MODE_2_INN || true)"
    prompt_default "PUBLIC_COPY_MODE (1 или 2)" "$mode" value
    [[ "$value" == "1" || "$value" == "2" ]] || die "Режим должен иметь значение 1 или 2."
    mode="$value"
    prompt_display_value "Название бренда" "$brand" brand 80
    [[ "$mode" != "2" || ! "$brand" =~ [Vv][Pp][Nn] ]] || \
        die "В нейтральном режиме название бренда не должно содержать VPN."
    prompt_display_value "Название сайта" "$site" site 100
    prompt_display_value "Заголовок вкладки браузера" "$title" title 150
    prompt_display_value "Слоган" "$tagline" tagline 300
    prompt_inn_default "ИНН для режима VPN" "$inn1" inn1
    prompt_inn_default "ИНН для нейтрального режима" "$inn2" inn2
    neutral_title="$(env_get PUBLIC_NEUTRAL_SITE_TITLE)"
    neutral_tagline="$(env_get PUBLIC_NEUTRAL_SITE_TAGLINE)"
    prompt_display_value "Нейтральный заголовок" "$neutral_title" neutral_title 150
    prompt_display_value "Нейтральный слоган" "$neutral_tagline" neutral_tagline 300
    backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$backup"
    env_set PUBLIC_COPY_MODE "$mode"
    env_set BRAND_NAME "$brand"
    env_set SITE_NAME "$site"
    env_set SITE_TITLE "$title"
    env_set SITE_TAGLINE "$tagline"
    env_set PUBLIC_MODE_1_INN "$inn1"
    env_set PUBLIC_MODE_2_INN "$inn2"
    env_set PUBLIC_NEUTRAL_SITE_TITLE "$neutral_title"
    env_set PUBLIC_NEUTRAL_SITE_TAGLINE "$neutral_tagline"
    apply_environment_change "$backup"
}

configure_smtp() {
    local backup host port user password from_email
    require_installed
    prompt_default "Хост SMTP" "$(env_get SMTP_HOST)" host
    prompt_default "TLS-порт SMTP" "$(env_get SMTP_PORT)" port
    validate_integer_range "$port" 1 65535 || die "Некорректный порт SMTP."
    prompt_default "Имя пользователя SMTP" "$(env_get SMTP_USER)" user
    prompt_secret "Новый пароль SMTP (не менее 10 символов)" password
    (( ${#password} >= 10 )) || die "Пароль SMTP слишком короткий."
    prompt_default "Email отправителя" "$(env_get FROM_EMAIL)" from_email
    validate_email "$from_email" || die "Некорректный email отправителя."
    backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$backup"
    env_set SMTP_HOST "$host"
    env_set SMTP_PORT "$port"
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
    prompt_default "Cookies Remnawave в формате JSON" "$(env_get REMNAWAVE_COOKIES_JSON)" cookies
    jq -e . >/dev/null <<<"$cookies" || die "Значение cookies должно быть корректным JSON."
    backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$backup"
    env_set REMNAWAVE_API_URL "$url"
    env_set REMNAWAVE_TOKEN "$token"
    env_set REMNAWAVE_COOKIES_JSON "$cookies"
    apply_environment_change "$backup"
}

configure_yookassa() {
    local backup shop_id secret webhook_secret
    require_installed
    if confirm "Включить или заменить интеграцию YooKassa?" yes; then
        prompt "Идентификатор магазина YooKassa" shop_id
        [[ "$shop_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "Некорректный идентификатор магазина."
        prompt_secret "Секретный ключ YooKassa (не менее 32 символов)" secret
        (( ${#secret} >= 32 )) || die "Секретный ключ слишком короткий."
        webhook_secret="$(random_hex 32)"
        backup="$(backup_environment)"
        ACTIVE_ENV_BACKUP="$backup"
        env_set YOOKASSA_SHOP_ID "$shop_id"
        env_set YOOKASSA_SECRET_KEY "$secret"
        env_set YOOKASSA_WEBHOOK_SECRET "$webhook_secret"
        apply_environment_change "$backup"
        printf '\nУкажите этот webhook в личном кабинете YooKassa:\n'
        printf 'https://%s/payments/yookassa/webhook?token=%s\n' "$DOMAIN" "$webhook_secret"
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
    local backup key current value
    require_installed
    printf 'Доступные для изменения лимиты:\n'
    printf '1. CLEANUP_INTERVAL_SECONDS (10..86400)\n'
    printf '2. MAX_REQUEST_BODY_BYTES (1024..10485760)\n'
    printf '3. RATE_LIMIT_REQUESTS (10..10000)\n'
    printf '4. AUTH_RATE_LIMIT_REQUESTS (2..1000)\n'
    printf '5. WEBHOOK_RATE_LIMIT_REQUESTS (2..1000)\n'
    prompt "Номер" value
    case "$value" in
        1) key=CLEANUP_INTERVAL_SECONDS; minimum=10; maximum=86400 ;;
        2) key=MAX_REQUEST_BODY_BYTES; minimum=1024; maximum=10485760 ;;
        3) key=RATE_LIMIT_REQUESTS; minimum=10; maximum=10000 ;;
        4) key=AUTH_RATE_LIMIT_REQUESTS; minimum=2; maximum=1000 ;;
        5) key=WEBHOOK_RATE_LIMIT_REQUESTS; minimum=2; maximum=1000 ;;
        *) die "Некорректный выбор." ;;
    esac
    current="$(env_get "$key")"
    prompt_default "$key" "$current" value
    validate_integer_range "$value" "$minimum" "$maximum" || die "Значение находится вне допустимого диапазона."
    backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$backup"
    env_set "$key" "$value"
    apply_environment_change "$backup"
}

finish_admin_bootstrap() {
    local backup email
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
        printf '1. Публичный текст, бренд, заголовки и ИНН\n'
        printf '2. SMTP\n'
        printf '3. Remnawave\n'
        printf '4. YooKassa\n'
        printf '5. Ограничения запросов и рабочие лимиты\n'
        printf '6. Завершить выдачу прав первого администратора\n'
        printf '7. Безопасная сводка конфигурации\n'
        printf '8. Редактировать полный env-файл\n'
        printf '0. Назад\n\n'
        printf 'Выберите пункт: ' >/dev/tty
        IFS= read -r choice </dev/tty
        case "$choice" in
            1) configure_public_settings; pause ;;
            2) configure_smtp; pause ;;
            3) configure_remnawave; pause ;;
            4) configure_yookassa; pause ;;
            5) configure_limits; pause ;;
            6) finish_admin_bootstrap; pause ;;
            7) show_environment_summary; pause ;;
            8) edit_environment_file; pause ;;
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
