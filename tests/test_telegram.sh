#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# All files and service operations use a disposable sandbox, never production.
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
mkdir -p "$CURRENT_LINK/frontend" "$CONFIG_DIR"
printf 'SITE_NAME=Test\nPUBLIC_SITE_URL=https://vpn.example.test\n' >"$CURRENT_LINK/.env.example"
printf '<script defer src="/js/vendor/telegram-web-app.js?v=pinned"></script>\n' \
    >"$CURRENT_LINK/frontend/index.html"

info() { :; }
warn() { :; }
error() { :; }
success() { :; }
die() { exit 1; }
require_installed() { :; }
register_temporary_path() { :; }
validate_no_control_characters() { :; }
chown() { :; }
prompt() { exit 1; }
prompt_default() { exit 1; }

# The real envctl atomic writer, strict parser and file modes have Python tests.
# These literal helpers let the shell workflows also run in Git Bash on Windows.
env_get() {
    awk -v key="$1" 'index($0, key "=") == 1 {
        print substr($0, length(key) + 2); found=1; exit
    } END { if (!found) exit 1 }' "$ENV_FILE"
}
env_unset() {
    awk -v key="$1" 'index($0, key "=") != 1' "$ENV_FILE" >"$ENV_FILE.new"
    mv "$ENV_FILE.new" "$ENV_FILE"
}
env_set() {
    env_unset "$1"
    printf '%s=%s\n' "$1" "$2" >>"$ENV_FILE"
}
backup_environment() {
    cp "$ENV_FILE" "$sandbox/env.backup"
    printf '%s\n' "$sandbox/env.backup"
}

# A fresh installation never reads an input variable or generates the old key.
ADMIN_EMAIL_INPUT=admin@example.test
DOMAIN=vpn.example.test
PUBLIC_SITE_URL_INPUT=https://vpn.example.test
SUBSCRIPTION_GRACE_PERIOD_DAYS_INPUT=7
SMTP_HOST_INPUT=smtp.example.test
SMTP_HELO_NAME_INPUT=mail.example.test
SMTP_PORT_INPUT=465
SMTP_USER_INPUT=test-user
SMTP_PASSWORD_INPUT='test-password$literal;value'
FROM_EMAIL_INPUT=noreply@example.test
MAIL_FROM_NAME_INPUT=Test
SECRET_KEY_INPUT=test-secret
REMNAWAVE_API_URL_INPUT=https://panel.example.test/api
REMNAWAVE_TOKEN_INPUT=test-token
REMNAWAVE_COOKIES_JSON_INPUT='{}'
YOOKASSA_SHOP_ID_INPUT=''
YOOKASSA_SECRET_KEY_INPUT=''
YOOKASSA_WEBHOOK_SECRET_INPUT=''
create_environment_file test-db-password "$CURRENT_LINK"
! env_get TELEGRAM_MINI_APP_URL >/dev/null
[[ "$(env_get SMTP_PASSWORD)" == "$SMTP_PASSWORD_INPUT" ]]
cp "$ENV_FILE" "$sandbox/expected.env"

# Missing, empty, configured and obsolete invalid URLs need no questions.
for value in '' 'https://t.me/batya_vpn_robot?startapp' 'invalid-old-url' \
    'https://t.me/batya_vpn_robot?startapp=$(id)'; do
    env_set TELEGRAM_MINI_APP_URL "$value"
    migrate_environment_for_release "$CURRENT_LINK"
    (( ENVIRONMENT_MIGRATED == 1 ))
    ! env_get TELEGRAM_MINI_APP_URL >/dev/null
    cmp -s "$ENV_FILE" "$sandbox/expected.env"
    validate_environment_schema_for_release "$CURRENT_LINK"

    # A same-commit update or repeated repair is idempotent.
    migrate_environment_for_release "$CURRENT_LINK"
    (( ENVIRONMENT_MIGRATED == 0 ))
    cmp -s "$ENV_FILE" "$sandbox/expected.env"
done

# Preserve a setting still consumed by an explicitly selected historical ref.
printf 'TELEGRAM_MINI_APP_URL=\n' >>"$CURRENT_LINK/.env.example"
env_set TELEGRAM_MINI_APP_URL 'https://t.me/old_robot?startapp'
migrate_environment_for_release "$CURRENT_LINK"
(( ENVIRONMENT_MIGRATED == 0 ))
[[ "$(env_get TELEGRAM_MINI_APP_URL)" == 'https://t.me/old_robot?startapp' ]]
printf 'SITE_NAME=Test\nPUBLIC_SITE_URL=https://vpn.example.test\n' >"$CURRENT_LINK/.env.example"

# Corrupt/unreadable env and failed atomic deletion must stop without rewrites.
cp "$ENV_FILE" "$sandbox/before-failure.env"
if (env_get() { return 2; }; migrate_environment_for_release "$CURRENT_LINK"); then
    printf 'Unreadable env was treated as an absent key.\n' >&2
    exit 1
fi
if (env_unset() { return 1; }; migrate_environment_for_release "$CURRENT_LINK"); then
    printf 'Failed deletion was ignored.\n' >&2
    exit 1
fi
cmp -s "$ENV_FILE" "$sandbox/before-failure.env"

# Use the actual update rollback handler after migration: previous env and the
# original running/stopped service state must both be restored before commit.
for was_active in 0 1; do
    (
        clear_update_state
        UPDATE_ENV_BACKUP="$(backup_environment)"
        UPDATE_IN_PROGRESS=1
        UPDATE_OLD_RELEASE="$CURRENT_LINK"
        UPDATE_OLD_SHA=previous-commit
        UPDATE_OLD_REF=previous-ref
        UPDATE_OLD_SITE_REF=previous-ref
        UPDATE_WAS_ACTIVE="$was_active"
        migrate_environment_for_release "$CURRENT_LINK"
        ! env_get TELEGRAM_MINI_APP_URL >/dev/null
        grep -Fqx 'TELEGRAM_MINI_APP_URL=https://t.me/old_robot?startapp' "$UPDATE_ENV_BACKUP"
        service_active=0
        systemctl() {
            case "$1" in
                stop) service_active=0 ;;
                start) service_active=1 ;;
                *) return 1 ;;
            esac
        }
        remove_validation_service_override() { :; }
        wait_for_local_health() { (( service_active == 1 )); }
        ln() { [[ "${*: -2:1}" == "$CURRENT_LINK" ]]; }
        install() { cp "${@: -2:1}" "${@: -1}"; }
        write_manager_config() { [[ "$CURRENT_SHA" == previous-commit ]]; }
        rollback_update_from_trap
        (( service_active == was_active && UPDATE_IN_PROGRESS == 0 ))
        cmp -s "$ENV_FILE" "$sandbox/before-failure.env"
    )
done

# Mini App routes are detected through index.html, even without the env key.
# Missing assets must fail the probe instead of disabling its whole checklist.
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
migrate_environment_for_release "$CURRENT_LINK"
missing_route=unused
verify_local_https_routes
for route in '/profile' '/profile/subscription' '/profile/settings/payments' \
    '/payment-return' '/payment-return?payment_id=manager-probe&payment_origin=telegram' \
    '/payments/telegram-return-config' '/js/vendor/telegram-web-app.js' \
    '/js/core/telegram.js' '/js/core/miniAppPayment.js' \
    '/js/core/paymentReturn.js' '/js/core/toast.js' \
    '/js/pages/account/paymentReturn/miniAppPaymentPage.js' \
    '/js/pages/account/paymentReturn/telegramPaymentHandoff.js' \
    '/js/templates/account/paymentReturnTemplates.js' \
    '/css/telegram.css' '/css/payment-return.css'; do
    grep -Fxq "https://$DOMAIN$route" "$sandbox/routes"
    missing_route="$route"
    ! verify_local_https_routes
done

# An old env declaration alone must not activate nonexistent Mini App routes.
printf '<html>Legacy site</html>\n' >"$CURRENT_LINK/frontend/index.html"
printf 'TELEGRAM_MINI_APP_URL=\n' >>"$CURRENT_LINK/.env.example"
: >"$sandbox/routes"
verify_local_https_routes
! grep -Fq '/payments/telegram-return-config' "$sandbox/routes"
! grep -Fq '/js/vendor/telegram-web-app.js' "$sandbox/routes"

printf 'Telegram Mini App manager tests passed.\n'
