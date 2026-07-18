#!/usr/bin/env bash

GITHUB_TOKEN=""
GITHUB_RESULT=""

read_github_token() {
    local token
    while true; do
        prompt_secret "Fine-grained токен GitHub (Contents: Read-only)" token
        if [[ "$token" =~ ^[A-Za-z0-9_]+$ && ${#token} -ge 20 ]]; then
            GITHUB_TOKEN="$token"
            return 0
        fi
        warn "Формат токена некорректен. Токен не был сохранён."
    done
}

clear_github_token() {
    GITHUB_TOKEN=""
    unset GITHUB_TOKEN
}

github_private_download() {
    local url="$1" output="$2" config
    [[ -n "${GITHUB_TOKEN:-}" ]] || die "Токен GitHub не загружен."
    printf -v config '%s\n' \
        'silent' \
        'show-error' \
        'fail-with-body' \
        'location' \
        'retry = 3' \
        'connect-timeout = 15' \
        'header = "Accept: application/vnd.github+json"' \
        'header = "X-GitHub-Api-Version: 2022-11-28"' \
        "header = \"Authorization: Bearer ${GITHUB_TOKEN}\"" \
        "output = \"${output}\""
    curl --config - "$url" <<<"$config"
}

github_private_json() {
    local url="$1" temporary
    temporary="$(mktemp)"
    register_temporary_path "$temporary"
    github_private_download "$url" "$temporary"
    jq -e . "$temporary" >/dev/null || die "GitHub вернул некорректный JSON."
    GITHUB_RESULT="$temporary"
}

github_public_download() {
    local url="$1" output="$2"
    curl --fail --location --silent --show-error --retry 3 \
        --connect-timeout 15 \
        --header "Accept: application/vnd.github+json" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$output" "$url"
}

github_public_json() {
    local url="$1" temporary
    temporary="$(mktemp)"
    register_temporary_path "$temporary"
    github_public_download "$url" "$temporary"
    jq -e . "$temporary" >/dev/null || die "GitHub вернул некорректный JSON."
    GITHUB_RESULT="$temporary"
}

github_encoded_ref() {
    jq -nr --arg value "$1" '$value | @uri'
}

resolve_private_commit() {
    local repository="$1" ref="$2" encoded
    encoded="$(github_encoded_ref "$ref")"
    github_private_json \
        "https://api.github.com/repos/${repository}/commits/${encoded}"
    jq -er '.sha | select(test("^[0-9a-f]{40}$"))' "$GITHUB_RESULT"
}

resolve_public_commit() {
    local repository="$1" ref="$2" encoded
    encoded="$(github_encoded_ref "$ref")"
    github_public_json \
        "https://api.github.com/repos/${repository}/commits/${encoded}"
    jq -er '.sha | select(test("^[0-9a-f]{40}$"))' "$GITHUB_RESULT"
}

verify_private_repository_access() {
    local repository="$1"
    info "Проверяется доступ только для чтения к $repository..."
    github_private_json "https://api.github.com/repos/${repository}"
    [[ "$(jq -r .full_name "$GITHUB_RESULT")" == "$repository" ]] || \
        die "Токен не предоставляет доступ к $repository."
    success "Доступ к приватному репозиторию подтверждён."
}

download_private_archive() {
    local repository="$1" sha="$2" output="$3"
    github_private_download \
        "https://api.github.com/repos/${repository}/tarball/${sha}" "$output"
}

download_public_archive() {
    local repository="$1" sha="$2" output="$3"
    github_public_download \
        "https://api.github.com/repos/${repository}/tarball/${sha}" "$output"
}
