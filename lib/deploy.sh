#!/usr/bin/env bash

INSTALLATION_IN_PROGRESS=0
INSTALLATION_DATABASE_CREATED=0
PREPARED_SITE_RELEASE=""

install_manager_from_source() {
    local source_directory="$1" digest release staging
    [[ -f "$source_directory/install.sh" && -d "$source_directory/lib" ]] || \
        die "Исходное дерево менеджера неполно."
    digest="$(tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 \
        --numeric-owner --exclude=.git -cf - -C "$source_directory" . | \
        sha256sum | cut -c1-16)"
    release="$MANAGER_RELEASES/v${MANAGER_VERSION}-${digest}"

    install -d -o root -g root -m 0755 "$MANAGER_RELEASES"
    if [[ ! -d "$release" ]]; then
        staging="$(mktemp -d "$MANAGER_RELEASES/.staging.XXXXXX")"
        cp -a "$source_directory/." "$staging/"
        rm -rf "$staging/.git"
        find "$staging" -type d -exec chmod 0755 {} +
        find "$staging" -type f -name '*.sh' -exec chmod 0755 {} +
        chmod 0755 "$staging/bin/"*.py
        chown -R root:root "$staging"
        mv "$staging" "$release"
    fi
    ln -sfn "$release" "$MANAGER_CURRENT"
    ln -sfn "$MANAGER_CURRENT/install.sh" "$MANAGER_COMMAND"
    prune_manager_releases
}

prune_manager_releases() {
    local current_target release
    local -a manager_releases=()
    current_target="$(readlink -f "$MANAGER_CURRENT" 2>/dev/null || true)"
    mapfile -t manager_releases < <(find "$MANAGER_RELEASES" -mindepth 1 -maxdepth 1 \
        -type d ! -name '.staging.*' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
    for release in "${manager_releases[@]:3}"; do
        [[ "$release" == "$current_target" ]] || \
            rm -rf --one-file-system -- "$release"
    done
}

preflight_host() {
    local available_kb memory_kb listeners
    available_kb="$(df --output=avail / | tail -1 | tr -d ' ')"
    memory_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    (( available_kb >= 4 * 1024 * 1024 )) || die "Требуется не менее 4 ГиБ свободного места на диске."
    (( memory_kb >= 900 * 1024 )) || die "Требуется не менее 1 ГиБ оперативной памяти."
    if systemctl is-active --quiet apache2 2>/dev/null; then
        die "Apache использует веб-порты. Перед установкой остановите или удалите его."
    fi
    listeners="$(ss -H -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null || true)"
    if [[ -n "$listeners" ]] && grep -qv 'nginx' <<<"$listeners"; then
        die "Порты 80 или 443 уже заняты другим сервисом:\n$listeners"
    fi
}

update_operating_system() {
    info "Обновляются пакеты Ubuntu. Это может занять несколько минут..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y full-upgrade
    apt-get install -y --no-install-recommends \
        build-essential ca-certificates certbot curl dnsutils jq nginx openssl \
        nano postgresql postgresql-client python3-minimal rsync tar ufw \
        unattended-upgrades xz-utils \
        libbz2-dev libdb-dev libexpat1-dev libffi-dev libgdbm-dev liblzma-dev \
        libncurses-dev libreadline-dev libsqlite3-dev libssl-dev libzstd-dev \
        tk-dev uuid-dev zlib1g-dev
    dpkg-reconfigure -f noninteractive unattended-upgrades || \
        warn "Не удалось автоматически включить автоматические обновления безопасности."
    systemctl enable --now postgresql nginx certbot.timer
    if [[ -f /var/run/reboot-required ]]; then
        warn "Ubuntu сообщает, что после установки требуется перезагрузка сервера."
    fi
}

capture_installation_firewall_state() {
    INSTALLATION_UFW_BACKUP="$(mktemp -d)"
    register_temporary_path "$INSTALLATION_UFW_BACKUP"
    rsync -a /etc/ufw/ "$INSTALLATION_UFW_BACKUP/" || return 1
    if grep -Eq '^ENABLED=yes$' /etc/ufw/ufw.conf; then
        INSTALLATION_UFW_WAS_ENABLED=1
    else
        INSTALLATION_UFW_WAS_ENABLED=0
    fi
    INSTALLATION_UFW_CHANGED=1
}

restore_installation_firewall_state() {
    local failed=0
    (( INSTALLATION_UFW_CHANGED == 1 )) || return 0
    ufw --force disable || failed=1
    rsync -a --delete "$INSTALLATION_UFW_BACKUP/" /etc/ufw/ || failed=1
    if (( INSTALLATION_UFW_WAS_ENABLED == 1 )); then
        ufw --force enable || failed=1
    else
        ufw --force disable || failed=1
    fi
    INSTALLATION_UFW_CHANGED=0
    INSTALLATION_UFW_WAS_ENABLED=0
    INSTALLATION_UFW_BACKUP=""
    (( failed == 0 ))
}

configure_firewall() {
    [[ "$FIREWALL_MANAGED" == "true" ]] || return 0
    validate_integer_range "$SSH_PORT" 1 65535 || die "Некорректный порт SSH: $SSH_PORT"
    capture_installation_firewall_state || \
        die "Не удалось сохранить исходное состояние UFW."
    info "Настраивается UFW для SSH на порту $SSH_PORT, а также для HTTP и HTTPS..."
    ufw allow "${SSH_PORT}/tcp" comment 'SSH managed by vpn-site'
    ufw allow 'Nginx Full'
    ufw --force enable
    ufw status verbose
}

install_python_314() {
    local json tag_object tag_name tag_sha object_type commit_sha archive source jobs
    if command -v python3.14 >/dev/null 2>&1; then
        success "Используется $(python3.14 --version)."
        return 0
    fi

    info "Определяется последняя стабильная версия Python 3.14..."
    json="$(mktemp)"
    register_temporary_path "$json"
    github_public_download \
        "https://api.github.com/repos/python/cpython/git/matching-refs/tags/v3.14." "$json"
    tag_object="$(jq -cer '
        map(select(.ref | test("refs/tags/v3\\.14\\.[0-9]+$")))
        | sort_by(.ref | capture("v3\\.14\\.(?<patch>[0-9]+)$").patch | tonumber)
        | last // empty
    ' "$json")"
    [[ -n "$tag_object" ]] || die "Не удалось определить стабильную версию Python 3.14."
    tag_name="$(jq -r '.ref | sub("refs/tags/"; "")' <<<"$tag_object")"
    tag_sha="$(jq -r '.object.sha' <<<"$tag_object")"

    github_public_json "https://api.github.com/repos/python/cpython/git/tags/$tag_sha"
    object_type="$(jq -r '.object.type' "$GITHUB_RESULT")"
    commit_sha="$(jq -r '.object.sha' "$GITHUB_RESULT")"
    # CPython release tags are not consistently represented as verified
    # signatures in the GitHub API. Pinning the download to the immutable
    # commit resolved from the official tag still prevents a moving branch or
    # arbitrary ref from being installed.
    [[ "$object_type" == "commit" && "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || \
        die "GitHub не вернул корректный commit для тега выпуска Python."

    archive="$(mktemp --suffix=.tar.gz)"
    register_temporary_path "$archive"
    source="$(mktemp -d)"
    register_temporary_path "$source"
    info "Загружаются исходники $tag_name из зафиксированного коммита $commit_sha..."
    github_public_download \
        "https://api.github.com/repos/python/cpython/tarball/$commit_sha" "$archive"
    tar -xzf "$archive" -C "$source" --strip-components=1

    jobs="$(nproc)"
    (( jobs > 4 )) && jobs=4
    (
        cd "$source" || exit 1
        ./configure --prefix=/usr/local --with-ensurepip=install
        make -j "$jobs"
        make altinstall
    )
    command -v python3.14 >/dev/null 2>&1 || die "Не удалось установить Python 3.14."
    python3.14 -m ensurepip --upgrade >/dev/null
    python3.14 -c 'import bz2, ctypes, hashlib, lzma, ssl, sqlite3, zlib'
    success "Установлен $(python3.14 --version)."
}

create_service_account_and_directories() {
    if ! getent group "$APP_GROUP" >/dev/null; then
        groupadd --system "$APP_GROUP"
    fi
    if ! id "$APP_USER" >/dev/null 2>&1; then
        useradd --system --gid "$APP_GROUP" --home-dir /nonexistent \
            --no-create-home --shell /usr/sbin/nologin "$APP_USER"
    fi
    install -d -o root -g root -m 0755 "$APP_ROOT" "$RELEASES_DIR"
    install -d -o root -g "$APP_GROUP" -m 0750 "$CONFIG_DIR"
    install -d -o root -g root -m 0700 "$STATE_DIR" "$BACKUP_ROOT" \
        "$DB_BACKUP_DIR" "$CONFIG_BACKUP_DIR"
    install -d -o www-data -g www-data -m 0755 /var/www/letsencrypt
}

create_database() {
    local database_password="$1" role_exists database_exists
    role_exists="$(runuser -u postgres -- psql -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='vpn_site'")"
    database_exists="$(runuser -u postgres -- psql -tAc \
        "SELECT 1 FROM pg_database WHERE datname='vpn_site'")"
    [[ -z "$role_exists" && -z "$database_exists" ]] || \
        die "Роль или база PostgreSQL vpn_site уже существует. Перезапись запрещена."
    runuser -u postgres -- psql --set=ON_ERROR_STOP=1 \
        --set=database_password="$database_password" <<'SQL'
CREATE ROLE vpn_site LOGIN PASSWORD :'database_password';
SQL
    INSTALLATION_DATABASE_CREATED=1
    runuser -u postgres -- createdb --owner=vpn_site --encoding=UTF8 vpn_site
}

validate_release_contract() {
    local release="$1" required
    for required in .env.example alembic.ini requirements.txt backend/main.py \
        backend/config.py frontend/index.html deploy; do
        [[ -e "$release/$required" ]] || die "В архиве сайта отсутствует $required."
    done
    if ! grep -q '^PUBLIC_COPY_MODE=' "$release/.env.example"; then
        for required in frontend/robots.txt frontend/sitemap.xml \
            frontend/js/app/main.js deploy/systemd/vpn-site.service \
            deploy/nginx/vpn-site.conf.example; do
            [[ -f "$release/$required" ]] || \
                die "В новой версии сайта отсутствует $required."
        done
        [[ ! -e "$release/frontend/env.js" ]] || \
            die "Новая версия сайта не должна содержать frontend/env.js."
        ! grep -Fq '/env.js' "$release/frontend/index.html" || \
            die "Новая версия сайта всё ещё подключает удалённый frontend/env.js."
    fi
}

validate_release_tree() {
    local release="$1"
    validate_release_contract "$release"
    ! find "$release" -type l -print -quit | grep -q . || \
        die "Архивы сайта с символьными ссылками не принимаются."
}

validate_release_public_domain() {
    local release="$1" domain="$2" canonical expected
    expected="https://$domain/"
    grep -q '^PUBLIC_COPY_MODE=' "$release/.env.example" && return 0
    canonical="$(sed -nE \
        's#.*<link rel="canonical" href="(https://[^"]+/)".*#\1#p' \
        "$release/frontend/index.html" | head -1)"
    [[ "$canonical" == "$expected" ]] || {
        error "Статический canonical release ($canonical) не совпадает с $expected."
        return 1
    }
    grep -Fqx "Sitemap: https://$domain/sitemap.xml" \
        "$release/frontend/robots.txt" || {
        error "robots.txt release не соответствует домену $domain."
        return 1
    }
    grep -Fq "<loc>$expected</loc>" "$release/frontend/sitemap.xml" || {
        error "sitemap.xml release не соответствует домену $domain."
        return 1
    }
}

prepare_site_release() {
    local sha="$1" archive release staging
    PREPARED_SITE_RELEASE=""
    release="$RELEASES_DIR/$sha"
    if [[ -d "$release" && -x "$release/.venv/bin/python" ]]; then
        # Manager 1.x generated env.js even for releases that no longer use it.
        if [[ -f "$release/.env.example" ]] && \
           ! grep -q '^PUBLIC_COPY_MODE=' "$release/.env.example"; then
            rm -f -- "$release/frontend/env.js"
        fi
        validate_release_contract "$release"
        PREPARED_SITE_RELEASE="$release"
        return 0
    fi
    archive="$(mktemp --suffix=.tar.gz)"
    register_temporary_path "$archive"
    download_private_archive "$SITE_REPOSITORY" "$sha" "$archive"
    staging="$(mktemp -d "$RELEASES_DIR/.staging.XXXXXX")"
    register_temporary_path "$staging"
    tar -xzf "$archive" -C "$staging" --strip-components=1 \
        --no-same-owner --no-same-permissions
    validate_release_tree "$staging"

    python3.14 -m venv "$staging/.venv"
    "$staging/.venv/bin/python" -m pip install --disable-pip-version-check \
        --require-hashes --requirement "$staging/requirements.txt"
    "$staging/.venv/bin/python" -m pip check
    "$staging/.venv/bin/python" -m compileall -q "$staging/backend"
    find "$staging" -type d -exec chmod u=rwx,go=rx {} +
    find "$staging" -type f -exec chmod u=rw,go=r {} +
    find "$staging/.venv/bin" -type f -exec chmod u=rwx,go=rx {} +
    chown -R root:root "$staging"
    mv "$staging" "$release"
    PREPARED_SITE_RELEASE="$release"
}

install_systemd_units() {
    local timer_policy="${1:-enable-timer}"
    [[ "$timer_policy" == "enable-timer" || "$timer_policy" == "defer-enable" ]] || \
        die "Некорректный режим установки systemd units."
    install -o root -g root -m 0644 \
        "$MANAGER_CURRENT/templates/vpn-site.service" \
        "/etc/systemd/system/$SERVICE_NAME"
    install -o root -g root -m 0644 \
        "$MANAGER_CURRENT/templates/vpn-site-backup.service" \
        /etc/systemd/system/vpn-site-backup.service
    install -o root -g root -m 0644 \
        "$MANAGER_CURRENT/templates/vpn-site-backup.timer" \
        /etc/systemd/system/vpn-site-backup.timer
    systemd-analyze verify "/etc/systemd/system/$SERVICE_NAME" \
        /etc/systemd/system/vpn-site-backup.service \
        /etc/systemd/system/vpn-site-backup.timer
    systemctl daemon-reload
    if [[ "$timer_policy" == "enable-timer" ]]; then
        systemctl enable vpn-site-backup.timer
    fi
}

prune_releases() {
    local current_target release
    local -a releases=()
    current_target="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
    mapfile -t releases < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d \
        ! -name '.staging.*' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
    for release in "${releases[@]:3}"; do
        [[ "$release" == "$current_target" ]] || rm -rf --one-file-system -- "$release"
    done
}

rollback_incomplete_install() {
    local default_path=/etc/nginx/sites-enabled/default
    (( INSTALLATION_IN_PROGRESS == 1 )) || return 0
    INSTALLATION_IN_PROGRESS=0
    warn "Удаляется незавершённое состояние приложения. Установленные пакеты Ubuntu сохраняются."
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        error "Backend не удалось остановить; validation override, локальный Nginx и данные оставлены без изменений."
        return 1
    fi
    systemctl disable --now vpn-site-backup.timer 2>/dev/null || true
    if declare -F remove_validation_service_override >/dev/null 2>&1; then
        remove_validation_service_override || true
    fi
    rm -f "/etc/systemd/system/$SERVICE_NAME" \
        /etc/systemd/system/vpn-site-backup.service \
        /etc/systemd/system/vpn-site-backup.timer \
        "$NGINX_SITE_LINK" "$NGINX_SITE"
    restore_initial_tls_state
    case "$INSTALLATION_DEFAULT_NGINX_STATE" in
        symlink)
            rm -f -- "$default_path"
            ln -sfn "$INSTALLATION_DEFAULT_NGINX_TARGET" "$default_path"
            ;;
        file)
            rm -f -- "$default_path"
            cp -a -- "$INSTALLATION_DEFAULT_NGINX_BACKUP" "$default_path"
            ;;
        absent) rm -f -- "$default_path" ;;
        "") ;;
    esac
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx || true
    fi
    if (( INSTALLATION_DATABASE_CREATED == 1 )); then
        runuser -u postgres -- dropdb --if-exists --force vpn_site || true
        runuser -u postgres -- psql -c 'DROP ROLE IF EXISTS vpn_site' || true
    fi
    rm -rf --one-file-system -- "$APP_ROOT"
    rm -f "$ENV_FILE" "$MANAGER_CONFIG"
    restore_installation_firewall_state || \
        warn "Не удалось полностью восстановить исходное состояние UFW."
    systemctl daemon-reload || true
}

initial_install() {
    local database_password sha release default_backup default_target
    local default_path=/etc/nginx/sites-enabled/default
    is_installed && die "Сайт уже установлен. Используйте раздел обновления."
    [[ ! -e "$ENV_FILE" && ! -e "$CURRENT_LINK" && ! -e "$APP_ROOT" && \
       ! -e "$NGINX_SITE" && ! -e "$NGINX_SITE_LINK" ]] || \
        die "Обнаружена незавершённая установка. Сначала проверьте /etc/vpn-site и /opt/vpn-site."
    preflight_host
    collect_installation_settings
    read_github_token
    update_operating_system
    check_required_commands curl jq openssl rsync tar flock
    validate_remnawave_cookies_input
    SECRET_KEY_INPUT="$(random_hex 48)"
    if [[ -n "$YOOKASSA_SHOP_ID_INPUT" ]]; then
        YOOKASSA_WEBHOOK_SECRET_INPUT="$(random_hex 32)"
    fi
    verify_private_repository_access "$SITE_REPOSITORY"
    sha="$(resolve_private_commit "$SITE_REPOSITORY" "$SITE_REF")"
    install_python_314
    INSTALLATION_IN_PROGRESS=1
    create_service_account_and_directories
    configure_firewall

    database_password="$(random_hex 32)"
    create_database "$database_password"
    prepare_site_release "$sha"
    release="$PREPARED_SITE_RELEASE"
    validate_release_public_domain "$release" "$DOMAIN" || \
        die "Выбранный release подготовлен для другого публичного домена."
    create_environment_file "$database_password" "$release"
    validate_environment_schema_for_release "$release"
    validate_application_environment "$release"
    ln -sfn "$release" "$CURRENT_LINK"

    CURRENT_SHA="$sha"
    CURRENT_REF="$SITE_REF"
    install_systemd_units defer-enable
    if [[ -L "$default_path" ]]; then
        default_target="$(readlink "$default_path")"
        INSTALLATION_DEFAULT_NGINX_STATE="symlink"
        INSTALLATION_DEFAULT_NGINX_TARGET="$default_target"
    elif [[ -e "$default_path" ]]; then
        default_backup="$(mktemp)"
        register_temporary_path "$default_backup"
        cp -a -- "$default_path" "$default_backup"
        INSTALLATION_DEFAULT_NGINX_STATE="file"
        INSTALLATION_DEFAULT_NGINX_BACKUP="$default_backup"
    else
        INSTALLATION_DEFAULT_NGINX_STATE="absent"
    fi
    configure_initial_certificate local-validation
    if ! install_validation_service_override || \
       ! systemctl start "$SERVICE_NAME" || \
       ! wait_for_local_health 60 || \
       ! validate_startup_prerequisites || \
       ! verify_local_https_routes; then
        die "Приложение не прошло изолированную проверку установки."
    fi
    stop_validation_backend || die "Validation backend не удалось безопасно остановить."

    # The fresh database has no provider work to reconcile. Exercise the real
    # lifespan while the service is disabled and Nginx is still local-only.
    if ! systemctl start "$SERVICE_NAME" || ! wait_for_local_health 60; then
        die "Production-start не удался; незавершённая установка будет удалена."
    fi
    # manager.conf is the durable commit marker. Public Nginx and boot-time
    # enablement happen only after it exists and rollback has been disarmed.
    write_manager_config
    INSTALLATION_IN_PROGRESS=0
    INSTALLATION_DEFAULT_NGINX_TARGET=""
    INSTALLATION_DEFAULT_NGINX_STATE=""
    INSTALLATION_DEFAULT_NGINX_BACKUP=""
    INSTALLATION_CERTIFICATE_CREATED=0
    INSTALLATION_RENEWAL_HOOK_CHANGED=0
    INSTALLATION_RENEWAL_HOOK_BACKUP=""
    INSTALLATION_UFW_CHANGED=0
    INSTALLATION_UFW_WAS_ENABLED=0
    INSTALLATION_UFW_BACKUP=""
    systemctl enable "$SERVICE_NAME" vpn-site-backup.timer || \
        die "Сайт работает, но не удалось включить автозапуск; выполните sudo vpn-site repair."
    activate_tls_nginx "$DOMAIN" || \
        die "Установка сохранена, но Nginx не открыл публичный доступ; выполните sudo vpn-site start."
    wait_for_public_health 30 || warn "Публичная проверка HTTPS не пройдена; локально приложение работает."
    systemctl start vpn-site-backup.timer
    clear_github_token
    prune_releases
    success "Сайт установлен: https://$DOMAIN"
    printf 'Email первого администратора: %s\n' "$ADMIN_EMAIL_INPUT"
    if [[ -n "$YOOKASSA_WEBHOOK_SECRET_INPUT" ]]; then
        printf 'URL webhook YooKassa: https://%s/payments/yookassa/webhook?token=%s\n' \
            "$DOMAIN" "$YOOKASSA_WEBHOOK_SECRET_INPUT"
    fi
    printf 'Команда управления: sudo vpn-site\n'
    finish_admin_bootstrap
}
