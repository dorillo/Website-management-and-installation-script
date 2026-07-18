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

configure_firewall() {
    [[ "$FIREWALL_MANAGED" == "true" ]] || return 0
    validate_integer_range "$SSH_PORT" 1 65535 || die "Некорректный порт SSH: $SSH_PORT"
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
        cd "$source"
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

validate_release_tree() {
    local release="$1" required
    for required in alembic.ini requirements.txt backend/main.py backend/config.py \
        frontend/index.html deploy; do
        [[ -e "$release/$required" ]] || die "В архиве сайта отсутствует $required."
    done
    ! find "$release" -type l -print -quit | grep -q . || \
        die "Архивы сайта с символьными ссылками не принимаются."
}

prepare_site_release() {
    local sha="$1" archive release staging
    PREPARED_SITE_RELEASE=""
    release="$RELEASES_DIR/$sha"
    if [[ -d "$release" && -x "$release/.venv/bin/python" ]]; then
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

    # Production is same-origin. Never ship a developer localhost API URL.
    printf 'window.APP_ENV = {\n    API_BASE_URL: ""\n};\n' >"$staging/frontend/env.js"
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
    systemctl enable vpn-site-backup.timer
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
    (( INSTALLATION_IN_PROGRESS == 1 )) || return 0
    INSTALLATION_IN_PROGRESS=0
    warn "Удаляется незавершённое состояние приложения. Установленные пакеты Ubuntu сохраняются."
    systemctl disable --now "$SERVICE_NAME" vpn-site-backup.timer 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME" \
        /etc/systemd/system/vpn-site-backup.service \
        /etc/systemd/system/vpn-site-backup.timer \
        "$NGINX_SITE_LINK" "$NGINX_SITE"
    restore_initial_tls_state
    if [[ -n "$INSTALLATION_DEFAULT_NGINX_TARGET" ]]; then
        ln -sfn "$INSTALLATION_DEFAULT_NGINX_TARGET" /etc/nginx/sites-enabled/default
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    if (( INSTALLATION_DATABASE_CREATED == 1 )); then
        runuser -u postgres -- dropdb --if-exists --force vpn_site || true
        runuser -u postgres -- psql -c 'DROP ROLE IF EXISTS vpn_site' || true
    fi
    rm -rf --one-file-system -- "$APP_ROOT"
    rm -f "$ENV_FILE" "$MANAGER_CONFIG"
    systemctl daemon-reload || true
}

initial_install() {
    local database_password sha release
    is_installed && die "Сайт уже установлен. Используйте раздел обновления."
    [[ ! -e "$ENV_FILE" && ! -e "$CURRENT_LINK" && ! -e "$APP_ROOT" && \
       ! -e "$NGINX_SITE" && ! -e "$NGINX_SITE_LINK" ]] || \
        die "Обнаружена незавершённая установка. Сначала проверьте /etc/vpn-site и /opt/vpn-site."
    preflight_host
    collect_installation_settings
    read_github_token
    update_operating_system
    check_required_commands curl jq openssl tar flock
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
    create_environment_file "$database_password"
    prepare_site_release "$sha"
    release="$PREPARED_SITE_RELEASE"
    validate_application_environment "$release"
    ln -sfn "$release" "$CURRENT_LINK"

    CURRENT_SHA="$sha"
    CURRENT_REF="$SITE_REF"
    write_manager_config
    install_systemd_units
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        INSTALLATION_DEFAULT_NGINX_TARGET="$(readlink /etc/nginx/sites-enabled/default)"
    fi
    configure_initial_certificate
    systemctl enable --now "$SERVICE_NAME"
    wait_for_local_health 60 || die "Приложение не прошло локальную проверку работоспособности."
    wait_for_public_health 30 || warn "Публичная проверка HTTPS не пройдена; локально приложение работает."
    systemctl start vpn-site-backup.timer
    clear_github_token
    INSTALLATION_IN_PROGRESS=0
    INSTALLATION_DEFAULT_NGINX_TARGET=""
    INSTALLATION_CERTIFICATE_CREATED=0
    INSTALLATION_RENEWAL_HOOK_CHANGED=0
    INSTALLATION_RENEWAL_HOOK_BACKUP=""
    prune_releases
    success "Сайт установлен: https://$DOMAIN"
    printf 'Email первого администратора: %s\n' "$ADMIN_EMAIL_INPUT"
    if [[ -n "$YOOKASSA_WEBHOOK_SECRET_INPUT" ]]; then
        printf 'URL webhook YooKassa: https://%s/payments/yookassa/webhook?token=%s\n' \
            "$DOMAIN" "$YOOKASSA_WEBHOOK_SECRET_INPUT"
    fi
    printf 'Команда управления: sudo vpn-site\n'
}
