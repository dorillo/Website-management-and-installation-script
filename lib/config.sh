#!/usr/bin/env bash

LEGACY_APPEARANCE_ENV_KEYS=(
    PUBLIC_COPY_MODE
    PUBLIC_MODE_1_INN
    PUBLIC_MODE_2_INN
    BRAND_NAME
    SITE_TITLE
    SITE_TAGLINE
    LOGO_PATH
    FAVICON_PATH
    PUBLIC_NEUTRAL_SITE_TITLE
    PUBLIC_NEUTRAL_SITE_TAGLINE
    PUBLIC_NEUTRAL_LOGO_PATH
    PUBLIC_NEUTRAL_FAVICON_PATH
)

ENVIRONMENT_MIGRATED=0

envctl_path() {
    if [[ -x "$MANAGER_CURRENT/bin/envctl.py" ]]; then
        printf '%s\n' "$MANAGER_CURRENT/bin/envctl.py"
    else
        printf '%s\n' "$SCRIPT_DIR/bin/envctl.py"
    fi
}

envexec_path() {
    if [[ -x "$MANAGER_CURRENT/bin/envexec.py" ]]; then
        printf '%s\n' "$MANAGER_CURRENT/bin/envexec.py"
    else
        printf '%s\n' "$SCRIPT_DIR/bin/envexec.py"
    fi
}

env_get() {
    "$(envctl_path)" get "$ENV_FILE" "$1"
}

env_set() {
    local key="$1" value="$2"
    validate_no_control_characters "$key" "$value"
    printf '%s' "$value" | "$(envctl_path)" set "$ENV_FILE" "$key"
}

env_unset() {
    "$(envctl_path)" unset "$ENV_FILE" "$1"
}

env_set_default() {
    local key="$1" value="$2"
    if ! env_get "$key" >/dev/null 2>&1; then
        env_set "$key" "$value"
        ENVIRONMENT_MIGRATED=1
    fi
}

release_site_name() {
    local release="$1" value
    value="$(awk -F= '$1 == "SITE_NAME" {print substr($0, index($0, "=") + 1)}' \
        "$release/.env.example")" || return 1
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    printf '%s\n' "$value"
}

migrate_environment_for_release() {
    local release="$1" key return_url site_name current_site_name
    ENVIRONMENT_MIGRATED=0
    [[ -f "$release/.env.example" ]] || \
        die "В release отсутствует .env.example; безопасная миграция окружения невозможна."

    # Older releases still consume runtime branding. Keep their values when an
    # operator deliberately deploys an old ref.
    if grep -q '^PUBLIC_COPY_MODE=' "$release/.env.example"; then
        return 0
    fi

    for key in "${LEGACY_APPEARANCE_ENV_KEYS[@]}"; do
        if env_get "$key" >/dev/null 2>&1; then
            env_unset "$key"
            ENVIRONMENT_MIGRATED=1
        fi
    done

    site_name="$(release_site_name "$release")" || \
        die "В .env.example release отсутствует однозначный SITE_NAME."
    current_site_name="$(env_get SITE_NAME 2>/dev/null || true)"
    if [[ "$current_site_name" != "$site_name" ]]; then
        env_set SITE_NAME "$site_name"
        ENVIRONMENT_MIGRATED=1
    fi
    env_set_default SUBSCRIPTION_NOTIFICATION_BATCH_SIZE 100
    env_set_default SUBSCRIPTION_NOTIFICATION_CONCURRENCY 5
    env_set_default SUBSCRIPTION_NOTIFICATION_RETRY_MINUTES 5
    env_set_default SMTP_MAX_CONCURRENCY 5

    if ! return_url="$(env_get YOOKASSA_RETURN_URL 2>/dev/null)" || \
       [[ "$return_url" != "https://$DOMAIN/payment-return" ]]; then
        env_set YOOKASSA_RETURN_URL "https://$DOMAIN/payment-return"
        ENVIRONMENT_MIGRATED=1
    fi

    if (( ENVIRONMENT_MIGRATED == 1 )); then
        info "Env-файл приведён к схеме выбранной версии сайта."
    fi
}

validate_environment_schema_for_release() {
    local release="$1" key failed=0 return_url site_name
    grep -q '^PUBLIC_COPY_MODE=' "$release/.env.example" && return 0
    for key in "${LEGACY_APPEARANCE_ENV_KEYS[@]}"; do
        if env_get "$key" >/dev/null 2>&1; then
            error "Env-файл содержит удалённую настройку внешнего вида: $key"
            failed=1
        fi
    done
    for key in SITE_NAME SUBSCRIPTION_NOTIFICATION_BATCH_SIZE \
        SUBSCRIPTION_NOTIFICATION_CONCURRENCY \
        SUBSCRIPTION_NOTIFICATION_RETRY_MINUTES SMTP_MAX_CONCURRENCY; do
        if ! env_get "$key" >/dev/null 2>&1; then
            error "В env-файле отсутствует настройка новой версии: $key"
            failed=1
        fi
    done
    site_name="$(release_site_name "$release" 2>/dev/null || true)"
    if [[ "$(env_get SITE_NAME 2>/dev/null || true)" != "$site_name" ]]; then
        error "SITE_NAME не совпадает со статическим брендом выбранного release."
        failed=1
    fi
    return_url="$(env_get YOOKASSA_RETURN_URL 2>/dev/null || true)"
    if [[ "$return_url" != "https://$DOMAIN/payment-return" ]]; then
        error "YOOKASSA_RETURN_URL должен указывать на https://$DOMAIN/payment-return"
        failed=1
    fi
    (( failed == 0 ))
}

create_environment_file() {
    local database_password="$1" release="$2" temporary site_name
    site_name="$(release_site_name "$release")" || \
        die "В .env.example release отсутствует однозначный SITE_NAME."
    validate_no_control_characters "SITE_NAME release" "$site_name"
    temporary="$(mktemp "$CONFIG_DIR/vpn-site.env.XXXXXX")" || return 1
    register_temporary_path "$temporary"
    if ! cat >"$temporary" <<EOF
# Managed by VPN Site Manager. Values are literal; do not add shell syntax.
SITE_NAME=$site_name

ENVIRONMENT=production
DATABASE_URL=postgresql+asyncpg://vpn_site:${database_password}@127.0.0.1:5432/vpn_site
ADMIN_BOOTSTRAP_EMAILS=$ADMIN_EMAIL_INPUT
CORS_ALLOWED_ORIGINS=https://$DOMAIN
TRUSTED_HOSTS=$DOMAIN
CLEANUP_INTERVAL_SECONDS=60
SUBSCRIPTION_NOTIFICATION_BATCH_SIZE=100
SUBSCRIPTION_NOTIFICATION_CONCURRENCY=5
SUBSCRIPTION_NOTIFICATION_RETRY_MINUTES=5
MAX_REQUEST_BODY_BYTES=1048576
RATE_LIMIT_WINDOW_SECONDS=60
RATE_LIMIT_REQUESTS=120
AUTH_RATE_LIMIT_REQUESTS=10
WEBHOOK_RATE_LIMIT_REQUESTS=30
ENABLE_API_DOCS=false

SMTP_HOST=$SMTP_HOST_INPUT
SMTP_PORT=$SMTP_PORT_INPUT
SMTP_TIMEOUT_SECONDS=15
SMTP_MAX_CONCURRENCY=5
SMTP_USER=$SMTP_USER_INPUT
SMTP_PASSWORD=$SMTP_PASSWORD_INPUT
FROM_EMAIL=$FROM_EMAIL_INPUT

SECRET_KEY=$SECRET_KEY_INPUT
ACCESS_TOKEN_EXPIRE_DAYS=7
AUTH_COOKIE_NAME=vpn_access_token
AUTH_COOKIE_SECURE=true
AUTH_COOKIE_SAMESITE=lax

REMNAWAVE_API_URL=$REMNAWAVE_API_URL_INPUT
REMNAWAVE_TOKEN=$REMNAWAVE_TOKEN_INPUT
REMNAWAVE_COOKIES_JSON=$REMNAWAVE_COOKIES_JSON_INPUT

YOOKASSA_API_URL=https://api.yookassa.ru/v3
YOOKASSA_CONFIRMATION_HOSTS=yoomoney.ru,*.yoomoney.ru,yookassa.ru,*.yookassa.ru
YOOKASSA_SHOP_ID=$YOOKASSA_SHOP_ID_INPUT
YOOKASSA_SECRET_KEY=$YOOKASSA_SECRET_KEY_INPUT
YOOKASSA_WEBHOOK_SECRET=$YOOKASSA_WEBHOOK_SECRET_INPUT
YOOKASSA_RETURN_URL=https://$DOMAIN/payment-return
PAYMENT_CURRENCY=RUB
UNPAID_PAYMENT_LIFETIME_HOURS=24
PAYMENT_PROCESSING_RETRY_AFTER_MINUTES=15
EOF
    then
        rm -f -- "$temporary"
        return 1
    fi
    if ! chown root:"$APP_GROUP" "$temporary" || \
       ! chmod 0640 "$temporary" || ! mv -f "$temporary" "$ENV_FILE"; then
        rm -f -- "$temporary"
        return 1
    fi
}

prompt_validated_domain() {
    local value
    while true; do
        prompt "Публичный домен (без https://)" value
        value="${value,,}"
        if validate_domain "$value"; then
            DOMAIN="$value"
            return 0
        fi
        warn "Введите имя хоста, например vpn.example.com."
    done
}

prompt_validated_email() {
    local message="$1" variable_name="$2" value
    while true; do
        prompt "$message" value
        if validate_email "$value"; then
            printf -v "$variable_name" '%s' "$value"
            return 0
        fi
        warn "Введите корректный адрес электронной почты."
    done
}

normalize_remnawave_cookies() {
    local value="$1" variable_name="$2" json_output name cookie_value

    # Keep the original JSON-object format backwards compatible.
    if json_output="$(jq -cer '
        if type == "object" and all(to_entries[];
            (.key | length > 0) and
            (.value | type == "string") and
            ((.key + .value) | test("[\\u0000-\\u001f\\u007f]") | not)
        )
        then .
        else error("expected an object with string values")
        end
    ' <<<"$value" 2>/dev/null)"; then
        printf -v "$variable_name" '%s' "$json_output"
        return 0
    fi

    # The Remnawave reverse-proxy exposes the Nginx matcher as
    # "~*name=value".  ~* is an Nginx regex modifier, not part of the cookie.
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \{*\} ]]; then
        value="${value:1:${#value}-2}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
    fi
    if [[ "$value" == \"*\" ]]; then
        value="$(jq -er 'if type == "string" then . else error("expected a string") end' \
            <<<"$value" 2>/dev/null)" || return 1
    fi
    [[ "$value" == '~*'* ]] && value="${value:2}"
    [[ "$value" == *=* ]] || return 1
    name="${value%%=*}"
    cookie_value="${value#*=}"

    json_output="$(jq -ncer --arg name "$name" --arg value "$cookie_value" '
        if ($name | length > 0) and
           (($name + $value) | test("[\\u0000-\\u001f\\u007f]") | not)
        then {($name): $value}
        else error("invalid cookie")
        end
    ' 2>/dev/null)" || return 1
    printf -v "$variable_name" '%s' "$json_output"
}

validate_remnawave_cookies_input() {
    local normalized
    while true; do
        if normalize_remnawave_cookies "$REMNAWAVE_COOKIES_JSON_INPUT" normalized; then
            REMNAWAVE_COOKIES_JSON_INPUT="$normalized"
            return 0
        fi
        warn 'Введите cookie как name=value (без ~*, кавычек и фигурных скобок) либо как JSON {"name":"value"}.'
        prompt_secret_optional "Cookie Remnawave: name=value или JSON" REMNAWAVE_COOKIES_JSON_INPUT
        [[ -n "$REMNAWAVE_COOKIES_JSON_INPUT" ]] || REMNAWAVE_COOKIES_JSON_INPUT="{}"
    done
}

collect_firewall_settings() {
    local value
    FIREWALL_MANAGED=false
    SSH_PORT=22
    if confirm "Настроить и включить межсетевой экран UFW?" yes; then
        prompt_default "Текущий TCP-порт SSH" "22" value
        validate_integer_range "$value" 1 65535 || die "Некорректный порт SSH."
        SSH_PORT="$value"
        FIREWALL_MANAGED=true
        warn "UFW разрешит SSH только на TCP-порту $SSH_PORT, а также HTTP и HTTPS."
        confirm "Я проверил, что sshd слушает порт $SSH_PORT" no || \
            die "Настройка UFW отменена, чтобы не потерять доступ к серверу."
    fi
}

collect_installation_settings() {
    local value

    printf '\nПервоначальная настройка сайта\n\n'
    prompt_validated_domain
    prompt_validated_email "Email для Let's Encrypt" LETSENCRYPT_EMAIL

    prompt_default "Приватный репозиторий GitHub" "$SITE_REPOSITORY" value
    validate_repository "$value" || die "Репозиторий должен быть указан в формате владелец/имя."
    SITE_REPOSITORY="$value"
    prompt_default "Ветка, тег или коммит для развёртывания" "$SITE_REF" value
    validate_ref "$value" || die "Некорректная Git-ссылка."
    SITE_REF="$value"

    prompt_validated_email "Email, которому разрешено стать первым администратором" ADMIN_EMAIL_INPUT

    printf '\nНастройка SMTP (требуется для отправки кодов входа)\n'
    prompt "Хост SMTP" SMTP_HOST_INPUT
    prompt_default "TLS-порт SMTP" "465" SMTP_PORT_INPUT
    validate_integer_range "$SMTP_PORT_INPUT" 1 65535 || die "Некорректный порт SMTP."
    prompt "Имя пользователя SMTP" SMTP_USER_INPUT
    validate_ascii_graphic "$SMTP_USER_INPUT" || \
        die "Имя пользователя SMTP должно состоять из печатных ASCII-символов без пробелов."
    prompt_secret "Пароль SMTP (не менее 10 символов)" SMTP_PASSWORD_INPUT
    (( ${#SMTP_PASSWORD_INPUT} >= 10 )) || die "Пароль SMTP слишком короткий для production."
    validate_no_control_characters "Пароль SMTP" "$SMTP_PASSWORD_INPUT"
    validate_ascii_printable "$SMTP_PASSWORD_INPUT" || \
        die "Пароль SMTP должен состоять из печатных ASCII-символов."
    prompt_validated_email "Email отправителя" FROM_EMAIL_INPUT

    printf '\nНастройка Remnawave\n'
    prompt "URL API Remnawave (например https://panel.example.com/api)" REMNAWAVE_API_URL_INPUT
    validate_https_url "$REMNAWAVE_API_URL_INPUT" || die "URL API Remnawave должен использовать HTTPS."
    prompt_secret "Токен Remnawave (не менее 32 символов)" REMNAWAVE_TOKEN_INPUT
    (( ${#REMNAWAVE_TOKEN_INPUT} >= 32 )) || die "Токен Remnawave слишком короткий для production."
    validate_ascii_graphic "$REMNAWAVE_TOKEN_INPUT" || \
        die "Токен Remnawave должен состоять из печатных ASCII-символов без пробелов."
    prompt_secret_optional \
        'Cookie Remnawave: name=value (можно вставить строку Nginx "~*name=value")' \
        REMNAWAVE_COOKIES_JSON_INPUT
    if [[ -z "$REMNAWAVE_COOKIES_JSON_INPUT" ]]; then
        REMNAWAVE_COOKIES_JSON_INPUT="{}"
    fi

    YOOKASSA_SHOP_ID_INPUT=""
    YOOKASSA_SECRET_KEY_INPUT=""
    YOOKASSA_WEBHOOK_SECRET_INPUT=""
    if confirm "Настроить YooKassa сейчас?" no; then
        collect_yookassa_settings
    fi

    printf '\nНастройка межсетевого экрана\n'
    collect_firewall_settings

}

collect_yookassa_settings() {
    prompt "Идентификатор магазина YooKassa" YOOKASSA_SHOP_ID_INPUT
    [[ "$YOOKASSA_SHOP_ID_INPUT" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || \
        die "Некорректный идентификатор магазина YooKassa."
    prompt_secret "Секретный ключ YooKassa (не менее 32 символов)" YOOKASSA_SECRET_KEY_INPUT
    (( ${#YOOKASSA_SECRET_KEY_INPUT} >= 32 )) || die "Секретный ключ YooKassa слишком короткий."
    validate_ascii_graphic "$YOOKASSA_SECRET_KEY_INPUT" || \
        die "Секретный ключ YooKassa должен состоять из печатных ASCII-символов без пробелов."
}

validate_application_environment() {
    local release="${1:-$CURRENT_LINK}"
    [[ -x "$release/.venv/bin/python" ]] || die "В $release отсутствует окружение Python."
    (
        cd "$release/backend" || exit 1
        "$(envexec_path)" "$ENV_FILE" "$release/.venv/bin/python" \
            -c 'import config; print("configuration is valid")'
    )
}

backup_environment() {
    local timestamp destination
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -o root -g root -m 0700 "$CONFIG_BACKUP_DIR"
    destination="$CONFIG_BACKUP_DIR/vpn-site-env-$timestamp"
    install -o root -g root -m 0600 "$ENV_FILE" "$destination"
    printf '%s\n' "$destination"
}

show_environment_summary() {
    require_installed
    printf 'Название backend: %s\n' "$(env_get SITE_NAME)"
    printf 'Хост SMTP: %s:%s\n' "$(env_get SMTP_HOST)" "$(env_get SMTP_PORT)"
    printf 'Параллельные SMTP-отправки: %s\n' \
        "$(env_get SMTP_MAX_CONCURRENCY 2>/dev/null || printf 5)"
    printf 'URL Remnawave: %s\n' "$(env_get REMNAWAVE_API_URL)"
    if [[ -n "$(env_get YOOKASSA_SHOP_ID || true)" ]]; then
        printf 'YooKassa: настроена\n'
    else
        printf 'YooKassa: отключена\n'
    fi
    printf 'Секретные значения намеренно скрыты.\n'
}

edit_environment_file() {
    local backup editor
    local -a editor_command
    require_installed
    editor="${SUDO_EDITOR:-${EDITOR:-nano}}"
    read -r -a editor_command <<<"$editor"
    (( ${#editor_command[@]} > 0 )) || die "Команда редактора пуста."
    command -v "${editor_command[0]}" >/dev/null 2>&1 || \
        die "Редактор не установлен: ${editor_command[0]}"
    backup="$(backup_environment)"
    ACTIVE_ENV_BACKUP="$backup"
    "${editor_command[@]}" "$ENV_FILE"
    "$(envctl_path)" validate "$ENV_FILE"
    apply_environment_change "$backup"
    ACTIVE_ENV_BACKUP=""
}

apply_environment_change() {
    local backup="$1" start_policy="${2:-preserve}" was_active=0
    systemctl is-active --quiet "$SERVICE_NAME" && was_active=1
    if ! validate_application_environment; then
        install -o root -g "$APP_GROUP" -m 0640 "$backup" "$ENV_FILE"
        die "Проверка конфигурации не пройдена; предыдущий файл восстановлен."
    fi
    if (( was_active == 0 )) && [[ "$start_policy" != "restart" ]]; then
        ACTIVE_ENV_BACKUP=""
        success "Конфигурация проверена и сохранена. Остановленный сайт не запускался."
        return 0
    fi
    if systemctl restart "$SERVICE_NAME" && wait_for_local_health 45; then
        ACTIVE_ENV_BACKUP=""
        success "Конфигурация применена."
        return 0
    fi
    warn "Сервис не прошёл проверку работоспособности; восстанавливается предыдущая конфигурация."
    install -o root -g "$APP_GROUP" -m 0640 "$backup" "$ENV_FILE"
    ACTIVE_ENV_BACKUP=""
    systemctl restart "$SERVICE_NAME" || true
    die "Изменение конфигурации отменено с восстановлением предыдущей версии."
}
