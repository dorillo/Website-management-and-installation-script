#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

readonly MANAGER_VERSION="1.2.0"
readonly DEFAULT_MANAGER_REPOSITORY="dorillo/vpn-site-manager"
readonly DEFAULT_MANAGER_REF="main"

bootstrap_manager() {
    local repository="${MANAGER_REPOSITORY:-$DEFAULT_MANAGER_REPOSITORY}"
    local ref="${MANAGER_REF:-$DEFAULT_MANAGER_REF}"
    local temporary_directory archive

    if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        printf 'Некорректное значение MANAGER_REPOSITORY: %s\n' "$repository" >&2
        exit 2
    fi
    if [[ ! "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$ ]] || \
       [[ "$ref" == *..* || "$ref" == */ || "$ref" == *//* ]]; then
        printf 'Некорректное значение MANAGER_REF: %s\n' "$ref" >&2
        exit 2
    fi

    temporary_directory="$(mktemp -d)"
    archive="$temporary_directory/manager.tar.gz"
    trap 'rm -rf -- "$temporary_directory"' EXIT

    printf 'Загрузка менеджера VPN Site из %s (%s)...\n' "$repository" "$ref"
    curl --fail --location --silent --show-error --retry 3 \
        --output "$archive" \
        "https://api.github.com/repos/${repository}/tarball/${ref}"
    mkdir "$temporary_directory/source"
    tar --extract --gzip --file "$archive" \
        --directory "$temporary_directory/source" --strip-components=1 \
        --no-same-owner --no-same-permissions

    if [[ ! -f "$temporary_directory/source/lib/common.sh" ]]; then
        printf 'Загруженный архив менеджера неполон.\n' >&2
        exit 1
    fi

    local status=0
    bash "$temporary_directory/source/install.sh" \
        --bootstrap-repository "$repository" "$@" || status=$?
    rm -rf -- "$temporary_directory"
    trap - EXIT
    exit "$status"
}

SCRIPT_PATH=""
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
    SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
fi

if [[ -z "$SCRIPT_DIR" || ! -f "$SCRIPT_DIR/lib/common.sh" ]]; then
    command -v curl >/dev/null 2>&1 || {
        printf 'Для первоначальной загрузки менеджера требуется curl.\n' >&2
        exit 1
    }
    bootstrap_manager "$@"
fi

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/github.sh
source "$SCRIPT_DIR/lib/github.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/deploy.sh
source "$SCRIPT_DIR/lib/deploy.sh"
# shellcheck source=lib/tls.sh
source "$SCRIPT_DIR/lib/tls.sh"
# shellcheck source=lib/operations.sh
source "$SCRIPT_DIR/lib/operations.sh"

main "$@"
