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

openssl_install_line="$(grep -n 'check_required_commands curl jq openssl' "$ROOT/lib/deploy.sh" | cut -d: -f1)"
yookassa_secret_line="$(grep -n 'YOOKASSA_WEBHOOK_SECRET_INPUT=.*random_hex' "$ROOT/lib/deploy.sh" | cut -d: -f1)"
(( yookassa_secret_line > openssl_install_line ))
update_flag_line="$(grep -n '^[[:space:]]*UPDATE_IN_PROGRESS=1' "$ROOT/lib/operations.sh" | cut -d: -f1)"
update_stop_line="$(grep -n '^[[:space:]]*systemctl stop \"\$SERVICE_NAME\"' "$ROOT/lib/operations.sh" | tail -1 | cut -d: -f1)"
(( update_flag_line < update_stop_line ))
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
grep -q '/payments/yookassa/webhook 0;' "$ROOT/templates/nginx.conf"
grep -q 'access_log .* if=\$vpn_site_access_log;' "$ROOT/templates/nginx.conf"
grep -q -- '--dbname=vpn_site <"\$backup"' "$ROOT/lib/operations.sh"
! grep -q -- '--dbname=vpn_site "\$backup"' "$ROOT/lib/operations.sh"
role_created_line="$(grep -n 'CREATE ROLE vpn_site' "$ROOT/lib/deploy.sh" | cut -d: -f1)"
database_flag_line="$(grep -n '^[[:space:]]*INSTALLATION_DATABASE_CREATED=1' "$ROOT/lib/deploy.sh" | cut -d: -f1)"
createdb_line="$(grep -n 'runuser -u postgres -- createdb --owner=vpn_site' "$ROOT/lib/deploy.sh" | head -1 | cut -d: -f1)"
(( role_created_line < database_flag_line && database_flag_line < createdb_line ))

(
    SCRIPT_DIR="$ROOT"
    # shellcheck source=../lib/tls.sh
    source "$ROOT/lib/tls.sh"
    rendered="$(mktemp)"
    trap 'rm -f -- "$rendered"' EXIT
    render_nginx_config vpn.example.com "$rendered"
    ! grep -q '__DOMAIN__' "$rendered"
    grep -q 'server_name vpn.example.com;' "$rendered"
    grep -q '/etc/letsencrypt/live/vpn.example.com/fullchain.pem' "$rendered"
    grep -q 'listen 443 ssl http2;' "$rendered"
    grep -q 'listen \[::\]:443 ssl http2;' "$rendered"
    ! grep -Eq '^[[:space:]]*http2[[:space:]]+on;' "$rendered"
)

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
