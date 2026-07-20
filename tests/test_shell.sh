#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEFAULT_MANAGER_REPOSITORY=dorillo/Website-management-and-installation-script
DEFAULT_MANAGER_REF=main

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

assert_valid() {
    local function_name="$1" value="$2"
    "$function_name" "$value" || {
        printf 'Expected %s to accept: %s\n' "$function_name" "$value" >&2
        exit 1
    }
}

assert_invalid() {
    local function_name="$1" value="$2"
    if "$function_name" "$value"; then
        printf 'Expected %s to reject: %s\n' "$function_name" "$value" >&2
        exit 1
    fi
}

assert_valid validate_domain vpn.example.com
assert_valid validate_domain a-b.example.co.uk
assert_invalid validate_domain localhost
assert_invalid validate_domain '-bad.example.com'
assert_invalid validate_domain 'bad..example.com'

assert_valid validate_email admin@example.com
assert_invalid validate_email admin@example
assert_invalid validate_email 'admin @example.com'

assert_valid validate_repository dorillo/vpn-site
assert_valid validate_repository dorillo/Website-management-and-installation-script
assert_invalid validate_repository 'https://github.com/dorillo/vpn-site'
assert_invalid validate_repository dorillo/vpn/site

assert_valid validate_ref main
assert_valid validate_ref release/2026.07
assert_invalid validate_ref '../main'
assert_invalid validate_ref 'feature//unsafe'
assert_invalid validate_ref 'feature/'

assert_valid validate_https_url https://panel.example.com/api
assert_invalid validate_https_url http://panel.example.com/api
assert_invalid validate_https_url 'https://panel.example.com/a b'

validate_integer_range 14 1 3650
! validate_integer_range 0 1 3650
! validate_integer_range text 1 3650

assert_valid validate_ascii_graphic 'smtp-user_123'
assert_invalid validate_ascii_graphic 'smtp user'
assert_invalid validate_ascii_graphic 'пароль'
assert_valid validate_ascii_printable 'smtp password !'
assert_invalid validate_ascii_printable 'пароль'

# The prompt helpers must not shadow a caller's commonly named output variable.
! grep -Eq 'local .* variable_name=.* value([[:space:]]|$)' "$ROOT/lib/common.sh"
grep -Fq '(( ${#SMTP_PASSWORD_INPUT} >= 10 ))' "$ROOT/lib/config.sh"
grep -Fq '(( ${#password} >= 10 ))' "$ROOT/lib/operations.sh"
! grep -Rqs 'пароль SMTP (не менее 12 символов)' "$ROOT/lib"
grep -Fq "printf '%s [y/n]: '" "$ROOT/lib/common.sh"
! grep -RqsE 'Y/n|y/N' "$ROOT/lib" "$ROOT/install.sh"
! grep -Fq 'PUBLIC_COPY_MODE=$PUBLIC_COPY_MODE_INPUT' "$ROOT/lib/config.sh"
! grep -Fq 'env_set PUBLIC_COPY_MODE' "$ROOT/lib/operations.sh"
! grep -Fq 'configure_public_settings' "$ROOT/lib/operations.sh"
! grep -Fq 'API_BASE_URL' "$ROOT/lib/deploy.sh"
grep -Fq 'SITE_NAME=$site_name' "$ROOT/lib/config.sh"
grep -Fq 'REMNAWAVE_COOKIES_JSON=$REMNAWAVE_COOKIES_JSON_INPUT' "$ROOT/lib/config.sh"
grep -Fq 'prompt_secret_optional' "$ROOT/lib/config.sh"
grep -Fq 'validate_remnawave_cookies_input' "$ROOT/lib/deploy.sh"
grep -Fq 'env_set ADMIN_BOOTSTRAP_EMAILS ""' "$ROOT/lib/operations.sh"
grep -Fq 'apply_environment_change "$backup" restart' "$ROOT/lib/operations.sh"
grep -Fq 'finish_admin_bootstrap' "$ROOT/lib/deploy.sh"

(
    # This stub verifies that the helper writes its result into the caller's variable.
    # shellcheck source=../lib/config.sh
    source "$ROOT/lib/config.sh"
    jq() { printf '%s\n' '{"XX@2X1XXX":"XXXX4!XX"}'; }
    normalized=""
    normalize_json_object '{ "XX@2X1XXX": "XXXX4!XX" }' normalized
    [[ "$normalized" == '{"XX@2X1XXX":"XXXX4!XX"}' ]]
)

if command -v jq >/dev/null 2>&1; then
    # shellcheck source=../lib/config.sh
    source "$ROOT/lib/config.sh"
    normalized=""
    normalize_json_object '{ "XX@2X1XXX": "XXXX4!XX" }' normalized
    [[ "$normalized" == '{"XX@2X1XXX":"XXXX4!XX"}' ]]
    ! normalize_json_object '["not", "an", "object"]' normalized
    ! normalize_json_object '{"cookie": 42}' normalized
    ! normalize_json_object 'invalid JSON' normalized
fi

(
    # shellcheck source=../lib/config.sh
    source "$ROOT/lib/config.sh"
    sandbox="$(mktemp -d)"
    trap 'rm -rf -- "$sandbox"' EXIT
    mkdir -p "$sandbox/release"
    printf 'SITE_NAME=Батя VPN\n' >"$sandbox/release/.env.example"
    declare -A values=(
        [SITE_NAME]='Legacy backend name'
        [PUBLIC_COPY_MODE]=2
        [BRAND_NAME]=Legacy
        [PUBLIC_NEUTRAL_SITE_TITLE]=Legacy
        [YOOKASSA_RETURN_URL]=https://vpn.example.com
    )
    DOMAIN=vpn.example.com
    env_get() {
        [[ -v "values[$1]" ]] || return 1
        printf '%s\n' "${values[$1]}"
    }
    env_set() { values["$1"]="$2"; }
    env_unset() { unset 'values[$1]'; }
    info() { :; }

    migrate_environment_for_release "$sandbox/release"
    (( ENVIRONMENT_MIGRATED == 1 ))
    [[ ! -v 'values[PUBLIC_COPY_MODE]' ]]
    [[ ! -v 'values[BRAND_NAME]' ]]
    [[ ! -v 'values[PUBLIC_NEUTRAL_SITE_TITLE]' ]]
    [[ "${values[SITE_NAME]}" == 'Батя VPN' ]]
    [[ "${values[SUBSCRIPTION_NOTIFICATION_BATCH_SIZE]}" == 100 ]]
    [[ "${values[SUBSCRIPTION_NOTIFICATION_CONCURRENCY]}" == 5 ]]
    [[ "${values[SUBSCRIPTION_NOTIFICATION_RETRY_MINUTES]}" == 5 ]]
    [[ "${values[SMTP_MAX_CONCURRENCY]}" == 5 ]]
    [[ "${values[YOOKASSA_RETURN_URL]}" == \
        https://vpn.example.com/payment-return ]]
)

(
    # shellcheck source=../lib/config.sh
    source "$ROOT/lib/config.sh"
    restarted=0
    systemctl() {
        [[ "$1" == "restart" ]] && restarted=1
        [[ "$1" != "is-active" ]]
    }
    validate_application_environment() { return 0; }
    wait_for_local_health() { return 0; }
    success() { :; }

    apply_environment_change /unused/backup restart
    (( restarted == 1 ))
)

(
    # shellcheck source=../lib/operations.sh
    source "$ROOT/lib/operations.sh"
    DOMAIN=vpn.example.com
    set_key=unset
    set_value=unset
    applied_backup=unset
    applied_policy=unset
    require_installed() { :; }
    env_get() { printf '%s\n' admin@example.com; }
    confirm() { return 0; }
    runuser() { printf 't\n'; }
    backup_environment() { printf '%s\n' /tmp/env-backup; }
    env_set() { set_key="$1"; set_value="$2"; }
    apply_environment_change() { applied_backup="$1"; applied_policy="$2"; }
    success() { :; }

    finish_admin_bootstrap >/dev/null
    [[ "$set_key" == "ADMIN_BOOTSTRAP_EMAILS" && -z "$set_value" ]]
    [[ "$applied_backup" == "/tmp/env-backup" && "$applied_policy" == "restart" ]]
)

(
    # shellcheck source=../lib/operations.sh
    source "$ROOT/lib/operations.sh"
    DOMAIN=vpn.example.com
    require_installed() { :; }
    env_get() { printf '%s\n' admin@example.com; }
    confirm() { return 1; }
    env_set() { return 1; }
    apply_environment_change() { return 1; }
    warn() { :; }

    finish_admin_bootstrap >/dev/null
)

(
    # shellcheck source=../lib/operations.sh
    source "$ROOT/lib/operations.sh"
    require_installed() { :; }
    env_get() { printf '\n'; }
    confirm() { return 1; }
    env_set() { return 1; }
    success() { :; }

    finish_admin_bootstrap
)

(
    # The installation summary must use the token persisted in env, not a
    # transient wizard variable that can be lost before the final output.
    # shellcheck source=../lib/operations.sh
    source "$ROOT/lib/operations.sh"
    DOMAIN=vpn.example.com
    env_get() {
        [[ "$1" == "YOOKASSA_WEBHOOK_SECRET" ]] || return 1
        printf '%s\n' webhook-token
    }

    webhook_output="$(show_yookassa_webhook)"
    [[ "$webhook_output" == *'https://vpn.example.com/payments/yookassa/webhook?token=webhook-token'* ]]
)

bootstrap_summary_line="$(grep -n '^[[:space:]]*finish_admin_bootstrap$' \
    "$ROOT/lib/deploy.sh" | cut -d: -f1)"
webhook_summary_line="$(grep -n '^[[:space:]]*show_yookassa_webhook$' \
    "$ROOT/lib/deploy.sh" | cut -d: -f1)"
(( bootstrap_summary_line < webhook_summary_line ))

openssl_install_line="$(grep -n 'check_required_commands curl jq openssl' "$ROOT/lib/deploy.sh" | cut -d: -f1)"
yookassa_secret_line="$(grep -n 'YOOKASSA_WEBHOOK_SECRET_INPUT=.*random_hex' "$ROOT/lib/deploy.sh" | cut -d: -f1)"
(( yookassa_secret_line > openssl_install_line ))
update_flag_line="$(grep -n '^[[:space:]]*UPDATE_IN_PROGRESS=1' "$ROOT/lib/operations.sh" | cut -d: -f1)"
update_stop_line="$(awk -v start="$update_flag_line" \
    'NR > start && /systemctl stop "\$SERVICE_NAME"/ {print NR; exit}' \
    "$ROOT/lib/operations.sh")"
(( update_flag_line < update_stop_line ))
update_backup_line="$(awk -v start="$update_stop_line" \
    'NR > start && /if ! create_backup/ {print NR; exit}' \
    "$ROOT/lib/operations.sh")"
(( update_stop_line < update_backup_line ))

install_prepare_line="$(grep -n '^[[:space:]]*prepare_site_release "\$sha"' \
    "$ROOT/lib/deploy.sh" | tail -1 | cut -d: -f1)"
install_env_line="$(grep -n '^[[:space:]]*create_environment_file "\$database_password" "\$release"' \
    "$ROOT/lib/deploy.sh" | cut -d: -f1)"
install_local_tls_line="$(grep -n 'configure_initial_certificate local-validation' \
    "$ROOT/lib/deploy.sh" | cut -d: -f1)"
install_validation_stop_line="$(grep -n 'stop_validation_backend ||' \
    "$ROOT/lib/deploy.sh" | cut -d: -f1)"
install_marker_line="$(grep -n '^[[:space:]]*write_manager_config$' \
    "$ROOT/lib/deploy.sh" | cut -d: -f1)"
install_commit_line="$(grep -n '^[[:space:]]*INSTALLATION_IN_PROGRESS=0' \
    "$ROOT/lib/deploy.sh" | tail -1 | cut -d: -f1)"
install_enable_line="$(grep -n 'systemctl enable "\$SERVICE_NAME" vpn-site-backup.timer' \
    "$ROOT/lib/deploy.sh" | cut -d: -f1)"
install_public_line="$(grep -n '^[[:space:]]*activate_tls_nginx "\$DOMAIN" ||' \
    "$ROOT/lib/deploy.sh" | cut -d: -f1)"
(( install_prepare_line < install_env_line && \
    install_env_line < install_local_tls_line && \
    install_local_tls_line < install_validation_stop_line && \
    install_validation_stop_line < install_marker_line && \
    install_marker_line < install_commit_line && \
    install_commit_line < install_enable_line && \
    install_enable_line < install_public_line ))
grep -Fq 'install_systemd_units defer-enable' "$ROOT/lib/deploy.sh"
grep -Fq 'INSTALLATION_DEFAULT_NGINX_STATE="file"' "$ROOT/lib/deploy.sh"
grep -Fq 'capture_installation_firewall_state' "$ROOT/lib/deploy.sh"
grep -Fq 'restore_installation_firewall_state' "$ROOT/lib/deploy.sh"
grep -Fq -- "--property=ExecStart --value" "$ROOT/lib/operations.sh"
grep -q 'track_initial_tls_state' "$ROOT/lib/tls.sh"
grep -q 'restore_initial_tls_state' "$ROOT/lib/deploy.sh"
grep -q '^readonly DEFAULT_MANAGER_REPOSITORY="dorillo/Website-management-and-installation-script"$' \
    "$ROOT/install.sh"
grep -q '^readonly LEGACY_MANAGER_REPOSITORY="dorillo/vpn-site-manager"$' \
    "$ROOT/install.sh"
grep -q 'MANAGER_REPOSITORY="$DEFAULT_MANAGER_REPOSITORY"' "$ROOT/lib/common.sh"
grep -q 'raw.githubusercontent.com/dorillo/Website-management-and-installation-script/main/install.sh' \
    "$ROOT/README.md"
! grep -Rqs 'dorillo/vpn-site-manager' "$ROOT/lib" "$ROOT/templates" "$ROOT/README.md"
grep -q '^shopt -s inherit_errexit$' "$ROOT/install.sh"
grep -Fq 'log_format vpn_site_access' "$ROOT/templates/nginx.conf"
grep -Fq '"/payments/:reference"' "$ROOT/templates/nginx.conf"
! grep -Fq '$http_referer' "$ROOT/templates/nginx.conf"
grep -Fq 'proxy_read_timeout 60s;' "$ROOT/templates/nginx.conf"
grep -Fq 'ExecStartPre=/opt/vpn-site-manager/current/bin/envexec.py /etc/vpn-site/vpn-site.env /opt/vpn-site/current/.venv/bin/python -m alembic -c /opt/vpn-site/current/alembic.ini check' \
    "$ROOT/templates/vpn-site.service"
grep -Fq -- '--no-server-header --no-access-log' "$ROOT/templates/vpn-site.service"
grep -Fq 'TimeoutStartSec=300' "$ROOT/templates/vpn-site.service"
grep -q -- '--dbname=vpn_site <"\$backup"' "$ROOT/lib/operations.sh"
! grep -q -- '--dbname=vpn_site "\$backup"' "$ROOT/lib/operations.sh"
grep -Fq 'RESTORE_IN_PROGRESS=1' "$ROOT/lib/operations.sh"
grep -Fq 'rollback_restore_from_trap' "$ROOT/lib/common.sh"
grep -Fq 'configure_initial_certificate local-validation' "$ROOT/lib/deploy.sh"
grep -Fq 'install_validation_service_override' "$ROOT/lib/deploy.sh"
grep -Fq 'activate_tls_nginx "$DOMAIN" local-validation' "$ROOT/lib/operations.sh"
! grep -Fq 'systemctl stop "$SERVICE_NAME" || true' "$ROOT/lib/operations.sh"
role_created_line="$(grep -n 'CREATE ROLE vpn_site' "$ROOT/lib/deploy.sh" | cut -d: -f1)"
database_flag_line="$(grep -n '^[[:space:]]*INSTALLATION_DATABASE_CREATED=1' "$ROOT/lib/deploy.sh" | cut -d: -f1)"
createdb_line="$(grep -n 'runuser -u postgres -- createdb --owner=vpn_site' "$ROOT/lib/deploy.sh" | head -1 | cut -d: -f1)"
(( role_created_line < database_flag_line && database_flag_line < createdb_line ))
! grep -Rqs '=.*$(prepare_site_release' "$ROOT/lib"
grep -q 'release="\$PREPARED_SITE_RELEASE"' "$ROOT/lib/deploy.sh"
grep -q 'new_release="\$PREPARED_SITE_RELEASE"' "$ROOT/lib/operations.sh"

(
    SCRIPT_DIR="$ROOT"
    # shellcheck source=../lib/tls.sh
    source "$ROOT/lib/tls.sh"
    rendered="$(mktemp)"
    trap 'rm -f -- "$rendered"' EXIT
    render_nginx_config vpn.example.com "$rendered" "$ROOT"
    ! grep -q '__DOMAIN__' "$rendered"
    grep -q 'server_name vpn.example.com;' "$rendered"
    grep -q '/etc/letsencrypt/live/vpn.example.com/fullchain.pem' "$rendered"
    grep -q 'listen 443 ssl http2;' "$rendered"
    grep -q 'listen \[::\]:443 ssl http2;' "$rendered"
    ! grep -Eq '^[[:space:]]*http2[[:space:]]+on;' "$rendered"
    grep -q 'location = /auth {' "$rendered"
    grep -q 'location /profile/ {' "$rendered"
    grep -q 'location = /payment-return {' "$rendered"
    grep -q 'location /control/ {' "$rendered"
    grep -q 'location = /robots.txt {' "$rendered"
    grep -q 'location = /sitemap.xml {' "$rendered"
    ! grep -q 'location = /env.js {' "$rendered"

    render_nginx_config vpn.example.com "$rendered" "$ROOT" local-validation
    grep -q 'allow 127.0.0.1;' "$rendered"
    grep -q 'allow ::1;' "$rendered"
    grep -q 'deny all;' "$rendered"
)

bash -s -- "$ROOT" <<'BASH'
set -Eeuo pipefail
ROOT="$1"
sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/current/frontend"
printf '<script src="/env.js"></script>\n' >"$sandbox/current/frontend/index.html"
CURRENT_LINK="$sandbox/current"
MANAGER_CURRENT="$sandbox/missing-manager"
SCRIPT_DIR="$ROOT"
validate_domain() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
# shellcheck source=../lib/tls.sh
source "$ROOT/lib/tls.sh"
rendered="$sandbox/nginx.conf"
render_nginx_config legacy.example.com "$rendered"
grep -q 'location = /env.js {' "$rendered"
BASH

(
    SCRIPT_DIR="$ROOT"
    # shellcheck source=../lib/tls.sh
    source "$ROOT/lib/tls.sh"
    sandbox="$(mktemp -d)"
    trap 'rm -rf -- "$sandbox"' EXIT
    hook="$sandbox/hook"
    backup="$sandbox/backup"
    printf 'previous hook\n' >"$backup"
    INSTALLATION_RENEWAL_HOOK_CHANGED=1
    INSTALLATION_RENEWAL_HOOK_BACKUP="$backup"
    INSTALLATION_CERTIFICATE_CREATED=0
    restore_initial_tls_state "$hook"

    cmp -s "$backup" "$hook"
)

printf 'Shell function tests passed.\n'
