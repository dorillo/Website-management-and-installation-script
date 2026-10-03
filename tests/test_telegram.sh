#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Load only the function modules: all files and service operations below use
# a disposable sandbox, never the manager's production paths.
# shellcheck source=../lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=../lib/operations.sh
source "$ROOT/lib/operations.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT
CURRENT_LINK="$sandbox/release"
CONFIG_DIR="$sandbox/config"
ENV_FILE="$CONFIG_DIR/site.env"
APP_GROUP=unused-test-group
SERVICE_NAME=unused-test.service
mkdir -p "$CURRENT_LINK" "$CONFIG_DIR"
printf 'SITE_NAME=Test\nTELEGRAM_MINI_APP_URL=\n' >"$CURRENT_LINK/.env.example"

info() { :; }
warn() { :; }
error() { :; }
success() { :; }
die() { exit 1; }
require_installed() { :; }
register_temporary_path() { :; }
validate_no_control_characters() { :; }
chown() { :; }

# Literal env access without invoking OS ownership APIs on Windows. The real
# envctl atomic writer and parser are covered by test_env_tools.py.
env_get() {
    awk -v key="$1" 'index($0, key "=") == 1 {
        print substr($0, length(key) + 2); found=1; exit
    } END { if (!found) exit 1 }' "$ENV_FILE"
}
env_set() {
    awk -v key="$1" 'index($0, key "=") != 1' "$ENV_FILE" >"$ENV_FILE.new"
    printf '%s=%s\n' "$1" "$2" >>"$ENV_FILE.new"
    mv "$ENV_FILE.new" "$ENV_FILE"
}
backup_environment() {
    cp "$ENV_FILE" "$sandbox/env.backup"
    printf '%s\n' "$sandbox/env.backup"
}

for value in '' 'https://t.me/batya_vpn_robot' \
    'https://t.me/batya_vpn_robot?startapp' \
    'https://t.me/batya_vpn_robot?startapp=' \
    'https://t.me/batya_vpn_robot/app' \
    'https://t.me/batya_vpn_robot/app?startapp' \
    'HTTPS://T.ME/batya_vpn_robot/' ; do
    validate_telegram_mini_app_url "$value"
done
for value in '/' ' ' '@batya_vpn_robot' \
    'http://t.me/batya_vpn_robot' 'https://evil.test/batya_vpn_robot' \
    'https://t.me.evil.test/batya_vpn_robot' 'https://user@t.me/batya_vpn_robot' \
    'https://t.me:443/batya_vpn_robot' 'https://t.me/abcd' \
    'https://t.me/batya_vpn_robot?startapp=payment_123' \
    'https://t.me/batya_vpn_robot?startapp&extra=1' \
    'https://t.me/batya_vpn_robot/app/extra' \
    'https://t.me/batya_vpn_robot#fragment' \
    'https://t.me/batya_vpn_robot/$(id)' \
    $'https://t.me/batya_vpn_robot\nINJECTED=1'; do
    if validate_telegram_mini_app_url "$value"; then
        printf 'Unexpectedly accepted URL: %q\n' "$value" >&2
        exit 1
    fi
done

attempts=0
prompt_default() {
    (( attempts += 1 ))
    if (( attempts == 1 )); then
        printf -v "$3" '%s' 'https://evil.test/bot'
    else
        printf -v "$3" '%s' 'https://t.me/batya_vpn_robot?startapp'
    fi
}
prompt_telegram_mini_app_url selected
(( attempts == 2 ))
[[ "$selected" == 'https://t.me/batya_vpn_robot?startapp' ]]

# Missing means ask; an explicitly empty answer must still be marked selected.
for answer in '' 'https://t.me/batya_vpn_robot?startapp'; do
    printf 'UNRELATED=preserve\n' >"$ENV_FILE"
    attempts=0
    prompt_default() { (( attempts += 1 )); printf -v "$3" '%s' "$answer"; }
    select_update_telegram_mini_app_url "$CURRENT_LINK" selected changed
    (( attempts == 1 && changed == 1 ))
    [[ "$selected" == "$answer" ]]
    ! env_get TELEGRAM_MINI_APP_URL >/dev/null
    env_set TELEGRAM_MINI_APP_URL "$selected"

    # On the next update neither an empty value nor a URL prompts again.
    select_update_telegram_mini_app_url "$CURRENT_LINK" selected changed
    (( attempts == 1 && changed == 0 ))
    [[ "$(env_get TELEGRAM_MINI_APP_URL)" == "$answer" ]]
    [[ "$(env_get UNRELATED)" == preserve ]]
done

env_set TELEGRAM_MINI_APP_URL 'https://evil.test/bot'
if (select_update_telegram_mini_app_url "$CURRENT_LINK" selected changed); then
    printf 'Invalid existing URL did not stop update.\n' >&2
    exit 1
fi
if (env_get() { return 2; }; select_update_telegram_mini_app_url "$CURRENT_LINK" selected changed); then
    printf 'Unreadable env was treated as a missing variable.\n' >&2
    exit 1
fi

# Legacy releases neither prompt nor write the optional setting.
printf 'SITE_NAME=Test\n' >"$CURRENT_LINK/.env.example"
prompt_default() { exit 1; }
select_update_telegram_mini_app_url "$CURRENT_LINK" selected changed
(( changed == 0 ))
configure_telegram_mini_app
printf 'SITE_NAME=Test\nTELEGRAM_MINI_APP_URL=\n' >"$CURRENT_LINK/.env.example"

# Fresh installation writes the URL and an explicit empty value alike.
ADMIN_EMAIL_INPUT=admin@example.test
DOMAIN=vpn.example.test
PUBLIC_SITE_URL_INPUT=https://vpn.example.test
SUBSCRIPTION_GRACE_PERIOD_DAYS_INPUT=7
SMTP_HOST_INPUT=smtp.example.test
SMTP_HELO_NAME_INPUT=mail.example.test
SMTP_PORT_INPUT=465
SMTP_USER_INPUT=test-user
SMTP_PASSWORD_INPUT=test-password
FROM_EMAIL_INPUT=noreply@example.test
MAIL_FROM_NAME_INPUT=Test
SECRET_KEY_INPUT=test-secret
REMNAWAVE_API_URL_INPUT=https://panel.example.test/api
REMNAWAVE_TOKEN_INPUT=test-token
REMNAWAVE_COOKIES_JSON_INPUT='{}'
YOOKASSA_SHOP_ID_INPUT=''
YOOKASSA_SECRET_KEY_INPUT=''
YOOKASSA_WEBHOOK_SECRET_INPUT=''
for answer in '' 'https://t.me/batya_vpn_robot/app'; do
    TELEGRAM_MINI_APP_URL_INPUT="$answer"
    create_environment_file test-db-password "$CURRENT_LINK"
    [[ "$(env_get TELEGRAM_MINI_APP_URL)" == "$answer" ]]
    [[ "$(env_get SMTP_PASSWORD)" == test-password ]]
done

# The menu uses the existing backup/validation/apply transaction, and Enter
# actually clears an earlier URL instead of silently retaining it.
(
for answer in 'https://t.me/another_robot/app' ''; do
    prompt_default() { printf -v "$3" '%s' "$answer"; }
    apply_environment_change() { [[ "$1" == "$sandbox/env.backup" ]]; }
    configure_telegram_mini_app >/dev/null
    [[ "$(env_get TELEGRAM_MINI_APP_URL)" == "$answer" ]]
    [[ "$(env_get SMTP_PASSWORD)" == test-password ]]
done
)

# Exercise actual apply rollback on config validation and health failure.
install() { cp "${@: -2:1}" "${@: -1}"; }
remnawave_environment_changed() { return 1; }
for failure in validation health; do
    env_set TELEGRAM_MINI_APP_URL 'https://t.me/original_robot?startapp'
    if (
        prompt_default() { printf -v "$3" '%s' 'https://t.me/new_robot?startapp'; }
        validate_application_environment() { [[ "$failure" != validation ]]; }
        systemctl() { return 0; }
        wait_for_local_health() { return 1; }
        configure_telegram_mini_app >/dev/null
    ); then
        printf 'Expected configuration rollback for %s.\n' "$failure" >&2
        exit 1
    fi
    [[ "$(env_get TELEGRAM_MINI_APP_URL)" == 'https://t.me/original_robot?startapp' ]]
done

# New HTTPS probes include locally served SDK/CSS and the public return API;
# legacy releases must not require endpoints that did not exist yet.
curl() {
    local url="${@: -1}"
    printf '%s\n' "$url" >>"$sandbox/routes"
    case "$url" in
        */index.html) printf 301 ;;
        */public/app-config|*/admin/routing-probe-not-found) printf 404 ;;
        *"$missing_route") printf 404 ;;
        *) printf 200 ;;
    esac
}
missing_route=unused
verify_local_https_routes
grep -Fq '/payments/telegram-return-config' "$sandbox/routes"
grep -Fq '/js/vendor/telegram-web-app.js' "$sandbox/routes"
missing_route='/js/vendor/telegram-web-app.js'
! verify_local_https_routes
printf 'SITE_NAME=Test\n' >"$CURRENT_LINK/.env.example"
: >"$sandbox/routes"
verify_local_https_routes
! grep -Fq '/payments/telegram-return-config' "$sandbox/routes"

printf 'Telegram Mini App manager tests passed.\n'
