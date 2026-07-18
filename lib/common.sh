#!/usr/bin/env bash

readonly APP_ID="vpn-site"
readonly APP_USER="vpn-site"
readonly APP_GROUP="vpn-site"
readonly APP_ROOT="/opt/vpn-site"
readonly RELEASES_DIR="$APP_ROOT/releases"
readonly CURRENT_LINK="$APP_ROOT/current"
readonly CONFIG_DIR="/etc/vpn-site"
readonly ENV_FILE="$CONFIG_DIR/vpn-site.env"
readonly MANAGER_CONFIG="$CONFIG_DIR/manager.conf"
readonly STATE_DIR="/var/lib/vpn-site"
readonly BACKUP_ROOT="/var/backups/vpn-site"
readonly DB_BACKUP_DIR="$BACKUP_ROOT/database"
readonly CONFIG_BACKUP_DIR="$BACKUP_ROOT/config"
readonly SERVICE_NAME="vpn-site.service"
readonly NGINX_SITE="/etc/nginx/sites-available/vpn-site"
readonly NGINX_SITE_LINK="/etc/nginx/sites-enabled/vpn-site"
readonly MANAGER_ROOT="/opt/vpn-site-manager"
readonly MANAGER_RELEASES="$MANAGER_ROOT/releases"
readonly MANAGER_CURRENT="$MANAGER_ROOT/current"
readonly MANAGER_COMMAND="/usr/local/sbin/vpn-site"
readonly LOCK_FILE="/run/lock/vpn-site-manager.lock"

SITE_REPOSITORY="${SITE_REPOSITORY:-dorillo/vpn-site}"
SITE_REF="${SITE_REF:-main}"
MANAGER_REPOSITORY="${MANAGER_REPOSITORY:-$DEFAULT_MANAGER_REPOSITORY}"
MANAGER_REF="${MANAGER_REF:-$DEFAULT_MANAGER_REF}"
DOMAIN="${DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
CURRENT_SHA="${CURRENT_SHA:-}"
CURRENT_REF="${CURRENT_REF:-}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
FIREWALL_MANAGED="${FIREWALL_MANAGED:-false}"
SSH_PORT="${SSH_PORT:-22}"
BOOTSTRAP_REPOSITORY=""
ACTIVE_ENV_BACKUP=""
UPDATE_IN_PROGRESS=0
UPDATE_OLD_RELEASE=""
UPDATE_BACKUP=""
UPDATE_OLD_SHA=""
UPDATE_OLD_REF=""
UPDATE_OLD_SITE_REF=""
UPDATE_WAS_ACTIVE=0
DOMAIN_CHANGE_IN_PROGRESS=0
DOMAIN_CHANGE_ENV_BACKUP=""
DOMAIN_CHANGE_NGINX_BACKUP=""
DOMAIN_CHANGE_MANAGER_BACKUP=""
DOMAIN_CHANGE_OLD_DOMAIN=""
DOMAIN_CHANGE_OLD_EMAIL=""
DOMAIN_CHANGE_WAS_ACTIVE=0
INSTALLATION_DEFAULT_NGINX_TARGET=""
INSTALLATION_CERTIFICATE_CREATED=0
INSTALLATION_RENEWAL_HOOK_CHANGED=0
INSTALLATION_RENEWAL_HOOK_BACKUP=""

declare -a TEMPORARY_PATHS=()

cleanup() {
    local path
    if (( ${DOMAIN_CHANGE_IN_PROGRESS:-0} == 1 )) && \
       declare -F rollback_domain_change_from_trap >/dev/null 2>&1; then
        rollback_domain_change_from_trap || true
    fi
    if [[ -n "${ACTIVE_ENV_BACKUP:-}" && -f "$ACTIVE_ENV_BACKUP" && -d "$CONFIG_DIR" ]]; then
        warn "Изменение прервано. Восстанавливается предыдущий env-файл."
        install -o root -g "$APP_GROUP" -m 0640 "$ACTIVE_ENV_BACKUP" "$ENV_FILE" || true
        ACTIVE_ENV_BACKUP=""
    fi
    if (( ${UPDATE_IN_PROGRESS:-0} == 1 )); then
        rollback_update_from_trap || true
    fi
    if (( ${INSTALLATION_IN_PROGRESS:-0} == 1 )); then
        rollback_incomplete_install || true
    fi
    for path in "${TEMPORARY_PATHS[@]:-}"; do
        [[ -n "$path" && -e "$path" ]] && rm -rf -- "$path"
    done
    if declare -F clear_github_token >/dev/null 2>&1; then
        clear_github_token
    fi
}

on_error() {
    local line="$1"
    printf '\n\033[31mОперация завершилась ошибкой около строки %s. Секретные значения в журнал не записывались.\033[0m\n' \
        "$line" >&2
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

info() { printf '\033[36m[ИНФО]\033[0m %s\n' "$*" >&2; }
success() { printf '\033[32m[ГОТОВО]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[ВНИМАНИЕ]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[31m[ОШИБКА]\033[0m %s\n' "$*" >&2; }
die() { error "$*"; exit 1; }

register_temporary_path() {
    TEMPORARY_PATHS+=("$1")
}

require_root() {
    if (( EUID != 0 )); then
        die "Запустите команду от root, например: sudo ./install.sh"
    fi
}

require_tty() {
    if ! { : </dev/tty; } 2>/dev/null; then
        die "Для этой операции необходим интерактивный терминал."
    fi
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Уже выполняется другая операция менеджера VPN Site."
}

pause() {
    printf '\nНажмите Enter, чтобы продолжить...' >/dev/tty
    IFS= read -r _ </dev/tty || true
}

prompt() {
    local message="$1" variable_name="$2" value
    while true; do
        printf '%s: ' "$message" >/dev/tty
        IFS= read -r value </dev/tty || die "Ввод отменён."
        if [[ -n "$value" ]]; then
            printf -v "$variable_name" '%s' "$value"
            return 0
        fi
        warn "Необходимо ввести значение."
    done
}

prompt_default() {
    local message="$1" default_value="$2" variable_name="$3" value
    printf '%s [%s]: ' "$message" "$default_value" >/dev/tty
    IFS= read -r value </dev/tty || die "Ввод отменён."
    printf -v "$variable_name" '%s' "${value:-$default_value}"
}

prompt_optional() {
    local message="$1" variable_name="$2" value
    printf '%s (необязательно): ' "$message" >/dev/tty
    IFS= read -r value </dev/tty || die "Ввод отменён."
    printf -v "$variable_name" '%s' "$value"
}

prompt_optional_default() {
    local message="$1" default_value="$2" variable_name="$3" value
    if [[ -n "$default_value" ]]; then
        printf '%s [%s]: ' "$message" "$default_value" >/dev/tty
    else
        printf '%s (необязательно): ' "$message" >/dev/tty
    fi
    IFS= read -r value </dev/tty || die "Ввод отменён."
    printf -v "$variable_name" '%s' "${value:-$default_value}"
}

prompt_secret() {
    local message="$1" variable_name="$2" value
    while true; do
        printf '%s: ' "$message" >/dev/tty
        IFS= read -r -s value </dev/tty || die "Ввод отменён."
        printf '\n' >/dev/tty
        if [[ -n "$value" ]]; then
            printf -v "$variable_name" '%s' "$value"
            return 0
        fi
        warn "Необходимо ввести значение."
    done
}

prompt_secret_confirm() {
    local message="$1" variable_name="$2" first second
    while true; do
        prompt_secret "$message" first
        prompt_secret "Повторите значение" second
        if [[ "$first" == "$second" ]]; then
            printf -v "$variable_name" '%s' "$first"
            return 0
        fi
        warn "Введённые значения не совпадают."
    done
}

confirm() {
    local message="$1" default_answer="${2:-no}" answer hint
    [[ "$default_answer" == "yes" ]] && hint="Y/n" || hint="y/N"
    printf '%s [%s]: ' "$message" "$hint" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    answer="${answer,,}"
    [[ -z "$answer" ]] && answer="$default_answer"
    [[ "$answer" == "y" || "$answer" == "yes" || "$answer" == "д" || "$answer" == "да" ]]
}

validate_no_control_characters() {
    local name="$1" value="$2"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || \
        die "$name не должно содержать переносы строк."
    [[ "$value" == "${value# }" && "$value" == "${value% }" ]] || \
        die "$name не должно начинаться или заканчиваться пробелом."
}

validate_domain() {
    local value="${1,,}"
    [[ ${#value} -le 253 ]] || return 1
    [[ "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

validate_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_repository() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

validate_ref() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$ ]] && \
        [[ "$1" != *..* && "$1" != */./* && "$1" != */../* && \
           "$1" != */ && "$1" != *//* ]]
}

validate_https_url() {
    [[ "$1" =~ ^https://[^[:space:]/]+(/[^[:space:]]*)?$ ]]
}

validate_integer_range() {
    local value="$1" minimum="$2" maximum="$3"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= minimum && value <= maximum ))
}

shell_quote() {
    printf '%q' "$1"
}

load_manager_config() {
    if [[ -f "$MANAGER_CONFIG" ]]; then
        local owner mode mode_value
        owner="$(stat -c '%u' "$MANAGER_CONFIG")"
        mode="$(stat -c '%a' "$MANAGER_CONFIG")"
        [[ "$owner" == "0" ]] || die "Владельцем $MANAGER_CONFIG должен быть root."
        mode_value=$((8#$mode))
        (( (mode_value & 0137) == 0 )) || \
            die "Права доступа к $MANAGER_CONFIG слишком широкие."
        # The file is generated by this manager and is root-owned.
        # shellcheck disable=SC1090
        source "$MANAGER_CONFIG"
    fi
}

validate_manager_config() {
    validate_repository "$SITE_REPOSITORY" || die "Некорректный репозиторий сайта в $MANAGER_CONFIG."
    validate_ref "$SITE_REF" || die "Некорректная Git-ссылка сайта в $MANAGER_CONFIG."
    validate_repository "$MANAGER_REPOSITORY" || die "Некорректный репозиторий менеджера в $MANAGER_CONFIG."
    validate_ref "$MANAGER_REF" || die "Некорректная Git-ссылка менеджера в $MANAGER_CONFIG."
    validate_integer_range "$BACKUP_RETENTION_DAYS" 1 3650 || \
        die "BACKUP_RETENTION_DAYS должен быть от 1 до 3650."
    [[ "$FIREWALL_MANAGED" == "true" || "$FIREWALL_MANAGED" == "false" ]] || \
        die "FIREWALL_MANAGED должен иметь значение true или false."
    validate_integer_range "$SSH_PORT" 1 65535 || die "Некорректный SSH_PORT."
    if [[ -n "$DOMAIN" ]]; then
        validate_domain "$DOMAIN" || die "Некорректный домен в $MANAGER_CONFIG."
    fi
    if [[ -n "$LETSENCRYPT_EMAIL" ]]; then
        validate_email "$LETSENCRYPT_EMAIL" || die "Некорректный email Let's Encrypt в $MANAGER_CONFIG."
    fi
    if [[ -n "$CURRENT_SHA" && ! "$CURRENT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        die "Некорректный текущий коммит в $MANAGER_CONFIG."
    fi
    if [[ -n "$CURRENT_REF" ]]; then
        validate_ref "$CURRENT_REF" || die "Некорректная текущая Git-ссылка в $MANAGER_CONFIG."
    fi
}

write_manager_config() {
    local temporary
    install -d -o root -g "$APP_GROUP" -m 0750 "$CONFIG_DIR"
    temporary="$(mktemp "$CONFIG_DIR/manager.conf.XXXXXX")"
    {
        printf 'SITE_REPOSITORY=%s\n' "$(shell_quote "$SITE_REPOSITORY")"
        printf 'SITE_REF=%s\n' "$(shell_quote "$SITE_REF")"
        printf 'MANAGER_REPOSITORY=%s\n' "$(shell_quote "$MANAGER_REPOSITORY")"
        printf 'MANAGER_REF=%s\n' "$(shell_quote "$MANAGER_REF")"
        printf 'DOMAIN=%s\n' "$(shell_quote "$DOMAIN")"
        printf 'LETSENCRYPT_EMAIL=%s\n' "$(shell_quote "$LETSENCRYPT_EMAIL")"
        printf 'CURRENT_SHA=%s\n' "$(shell_quote "$CURRENT_SHA")"
        printf 'CURRENT_REF=%s\n' "$(shell_quote "$CURRENT_REF")"
        printf 'BACKUP_RETENTION_DAYS=%s\n' "$(shell_quote "$BACKUP_RETENTION_DAYS")"
        printf 'FIREWALL_MANAGED=%s\n' "$(shell_quote "$FIREWALL_MANAGED")"
        printf 'SSH_PORT=%s\n' "$(shell_quote "$SSH_PORT")"
    } >"$temporary"
    chown root:"$APP_GROUP" "$temporary"
    chmod 0640 "$temporary"
    mv -f "$temporary" "$MANAGER_CONFIG"
}

is_installed() {
    [[ -L "$CURRENT_LINK" && -f "$ENV_FILE" && -f "$MANAGER_CONFIG" && \
       -f "/etc/systemd/system/$SERVICE_NAME" ]]
}

require_installed() {
    is_installed || die "Сайт ещё не установлен."
}

random_hex() {
    openssl rand -hex "$1"
}

check_ubuntu() {
    [[ -r /etc/os-release ]] || die "Не удалось определить операционную систему."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || \
        die "Поддерживается только Ubuntu 24.04 (обнаружено: ${PRETTY_NAME:-неизвестно})."
    [[ "$(dpkg --print-architecture)" == "amd64" || \
       "$(dpkg --print-architecture)" == "arm64" ]] || \
        die "Поддерживаются только архитектуры amd64 и arm64."
}

check_required_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "Не найдена обязательная команда: $command_name"
    done
}

main() {
    local command="menu" manager_repository_migrated=0

    while (( $# )); do
        case "$1" in
            --bootstrap-repository)
                [[ $# -ge 2 ]] || die "Для --bootstrap-repository требуется значение."
                BOOTSTRAP_REPOSITORY="$2"
                shift 2
                ;;
            install|menu|status|start|stop|restart|update|backup|diagnose|logs|update-manager|os-update|repair)
                command="$1"
                shift
                ;;
            --help|-h|help)
                show_help
                return 0
                ;;
            *) die "Неизвестный аргумент: $1" ;;
        esac
    done

    require_root
    acquire_lock
    check_ubuntu
    load_manager_config
    if [[ "$MANAGER_REPOSITORY" == "$LEGACY_MANAGER_REPOSITORY" ]]; then
        MANAGER_REPOSITORY="$DEFAULT_MANAGER_REPOSITORY"
        manager_repository_migrated=1
    fi
    validate_manager_config
    if (( manager_repository_migrated == 1 )); then
        warn "Обновляется устаревший адрес репозитория менеджера."
        write_manager_config
    fi
    if [[ "$command" == "install" || "$command" == "menu" || "$command" == "update" ]]; then
        require_tty
    fi
    [[ -n "$BOOTSTRAP_REPOSITORY" ]] && MANAGER_REPOSITORY="$BOOTSTRAP_REPOSITORY"
    install_manager_from_source "$SCRIPT_DIR"

    case "$command" in
        install) initial_install ;;
        status) show_status ;;
        start) start_site ;;
        stop) stop_site ;;
        restart) restart_site ;;
        update) update_site ;;
        backup) create_backup ;;
        diagnose) run_diagnostics ;;
        logs) show_logs ;;
        update-manager) update_manager ;;
        os-update) update_operating_system ;;
        repair) repair_runtime_configuration ;;
        menu) main_menu ;;
    esac
}
