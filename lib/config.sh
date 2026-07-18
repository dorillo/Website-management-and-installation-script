#!/usr/bin/env bash

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

create_environment_file() {
    local database_password="$1" temporary
    temporary="$(mktemp "$CONFIG_DIR/vpn-site.env.XXXXXX")"
    cat >"$temporary" <<EOF
# Managed by VPN Site Manager. Values are literal; do not add shell syntax.
SITE_NAME=$SITE_NAME_INPUT
PUBLIC_COPY_MODE=$PUBLIC_COPY_MODE_INPUT
PUBLIC_MODE_1_INN=$PUBLIC_MODE_1_INN_INPUT
PUBLIC_MODE_2_INN=$PUBLIC_MODE_2_INN_INPUT
BRAND_NAME=$BRAND_NAME_INPUT
SITE_TITLE=$SITE_TITLE_INPUT
SITE_TAGLINE=$SITE_TAGLINE_INPUT
LOGO_PATH=assets/Logo1.png
FAVICON_PATH=assets/icon.png
PUBLIC_NEUTRAL_SITE_TITLE=$PUBLIC_NEUTRAL_SITE_TITLE_INPUT
PUBLIC_NEUTRAL_SITE_TAGLINE=$PUBLIC_NEUTRAL_SITE_TAGLINE_INPUT
PUBLIC_NEUTRAL_LOGO_PATH=assets/Logo2.png
PUBLIC_NEUTRAL_FAVICON_PATH=assets/icon.png

ENVIRONMENT=production
DATABASE_URL=postgresql+asyncpg://vpn_site:${database_password}@127.0.0.1:5432/vpn_site
ADMIN_BOOTSTRAP_EMAILS=$ADMIN_EMAIL_INPUT
CORS_ALLOWED_ORIGINS=https://$DOMAIN
TRUSTED_HOSTS=$DOMAIN
CLEANUP_INTERVAL_SECONDS=60
MAX_REQUEST_BODY_BYTES=1048576
RATE_LIMIT_WINDOW_SECONDS=60
RATE_LIMIT_REQUESTS=120
AUTH_RATE_LIMIT_REQUESTS=10
WEBHOOK_RATE_LIMIT_REQUESTS=30
ENABLE_API_DOCS=false

SMTP_HOST=$SMTP_HOST_INPUT
SMTP_PORT=$SMTP_PORT_INPUT
SMTP_TIMEOUT_SECONDS=15
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
REMNAWAVE_COOKIES_JSON={}

YOOKASSA_API_URL=https://api.yookassa.ru/v3
YOOKASSA_CONFIRMATION_HOSTS=yoomoney.ru,*.yoomoney.ru,yookassa.ru,*.yookassa.ru
YOOKASSA_SHOP_ID=$YOOKASSA_SHOP_ID_INPUT
YOOKASSA_SECRET_KEY=$YOOKASSA_SECRET_KEY_INPUT
YOOKASSA_WEBHOOK_SECRET=$YOOKASSA_WEBHOOK_SECRET_INPUT
YOOKASSA_RETURN_URL=https://$DOMAIN
PAYMENT_CURRENCY=RUB
UNPAID_PAYMENT_LIFETIME_HOURS=24
PAYMENT_PROCESSING_RETRY_AFTER_MINUTES=15
EOF
    chown root:"$APP_GROUP" "$temporary"
    chmod 0640 "$temporary"
    mv -f "$temporary" "$ENV_FILE"
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

prompt_display_value() {
    local message="$1" default_value="$2" variable_name="$3" maximum="$4" value
    while true; do
        prompt_default "$message" "$default_value" value
        validate_no_control_characters "$message" "$value"
        if (( ${#value} >= 1 && ${#value} <= maximum )); then
            printf -v "$variable_name" '%s' "$value"
            return 0
        fi
        warn "Допустимая длина: от 1 до $maximum символов."
    done
}

prompt_inn() {
    local message="$1" variable_name="$2" value
    while true; do
        prompt_optional "$message" value
        if [[ -z "$value" || "$value" =~ ^[0-9]{12}$ ]]; then
            printf -v "$variable_name" '%s' "$value"
            return 0
        fi
        warn "ИНН должен быть пустым или содержать ровно 12 цифр."
    done
}

prompt_inn_default() {
    local message="$1" default_value="$2" variable_name="$3" value
    while true; do
        prompt_optional_default "$message" "$default_value" value
        if [[ -z "$value" || "$value" =~ ^[0-9]{12}$ ]]; then
            printf -v "$variable_name" '%s' "$value"
            return 0
        fi
        warn "ИНН должен быть пустым или содержать ровно 12 цифр."
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

    prompt_display_value "Название бренда (без VPN)" "Батя" BRAND_NAME_INPUT 80
    prompt_display_value "Название сайта" "$BRAND_NAME_INPUT VPN" SITE_NAME_INPUT 100
    prompt_display_value "Заголовок вкладки браузера" "$SITE_NAME_INPUT" SITE_TITLE_INPUT 150
    prompt_display_value "Слоган сайта" "Надёжный VPN под контролем Бати" SITE_TAGLINE_INPUT 300
    prompt_default "Режим публичного текста (1 = VPN, 2 = нейтральный)" "1" PUBLIC_COPY_MODE_INPUT
    [[ "$PUBLIC_COPY_MODE_INPUT" == "1" || "$PUBLIC_COPY_MODE_INPUT" == "2" ]] || \
        die "PUBLIC_COPY_MODE должен иметь значение 1 или 2."
    if [[ "$PUBLIC_COPY_MODE_INPUT" == "2" && "$BRAND_NAME_INPUT" =~ [Vv][Pp][Nn] ]]; then
        die "В нейтральном режиме название бренда не должно содержать VPN."
    fi
    prompt_inn "ИНН для режима VPN" PUBLIC_MODE_1_INN_INPUT
    prompt_inn "ИНН для нейтрального режима" PUBLIC_MODE_2_INN_INPUT
    PUBLIC_NEUTRAL_SITE_TITLE_INPUT="$BRAND_NAME_INPUT — Ускоритель интернета"
    PUBLIC_NEUTRAL_SITE_TAGLINE_INPUT="Стабильное подключение и понятное управление доступом"

    prompt_validated_email "Email, которому разрешено стать первым администратором" ADMIN_EMAIL_INPUT

    printf '\nНастройка SMTP (требуется для отправки кодов входа)\n'
    prompt "Хост SMTP" SMTP_HOST_INPUT
    prompt_default "TLS-порт SMTP" "465" SMTP_PORT_INPUT
    validate_integer_range "$SMTP_PORT_INPUT" 1 65535 || die "Некорректный порт SMTP."
    prompt "Имя пользователя SMTP" SMTP_USER_INPUT
    prompt_secret "Пароль SMTP (не менее 12 символов)" SMTP_PASSWORD_INPUT
    (( ${#SMTP_PASSWORD_INPUT} >= 12 )) || die "Пароль SMTP слишком короткий для production."
    prompt_validated_email "Email отправителя" FROM_EMAIL_INPUT

    printf '\nНастройка Remnawave\n'
    prompt "URL API Remnawave (например https://panel.example.com/api)" REMNAWAVE_API_URL_INPUT
    validate_https_url "$REMNAWAVE_API_URL_INPUT" || die "URL API Remnawave должен использовать HTTPS."
    prompt_secret "Токен Remnawave (не менее 32 символов)" REMNAWAVE_TOKEN_INPUT
    (( ${#REMNAWAVE_TOKEN_INPUT} >= 32 )) || die "Токен Remnawave слишком короткий для production."

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
}

validate_application_environment() {
    local release="${1:-$CURRENT_LINK}"
    [[ -x "$release/.venv/bin/python" ]] || die "В $release отсутствует окружение Python."
    (
        cd "$release/backend"
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
    printf 'Режим публичного текста: %s\n' "$(env_get PUBLIC_COPY_MODE)"
    printf 'Бренд: %s\n' "$(env_get BRAND_NAME)"
    printf 'Хост SMTP: %s:%s\n' "$(env_get SMTP_HOST)" "$(env_get SMTP_PORT)"
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
    local backup="$1" was_active=0
    systemctl is-active --quiet "$SERVICE_NAME" && was_active=1
    if ! validate_application_environment; then
        install -o root -g "$APP_GROUP" -m 0640 "$backup" "$ENV_FILE"
        die "Проверка конфигурации не пройдена; предыдущий файл восстановлен."
    fi
    if (( was_active == 0 )); then
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
