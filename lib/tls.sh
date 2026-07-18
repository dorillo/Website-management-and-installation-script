#!/usr/bin/env bash

render_nginx_config() {
    local domain="$1" destination="$2" template
    validate_domain "$domain" || die "Отказ от создания конфигурации для некорректного домена."
    template="$MANAGER_CURRENT/templates/nginx.conf"
    [[ -f "$template" ]] || template="$SCRIPT_DIR/templates/nginx.conf"
    [[ -f "$template" ]] || die "Шаблон Nginx отсутствует."
    sed "s/__DOMAIN__/$domain/g" "$template" >"$destination"
}

restore_nginx_site() {
    local backup="$1" default_target="${2:-}"
    if [[ -n "$backup" && -f "$backup" ]]; then
        install -o root -g root -m 0644 "$backup" "$NGINX_SITE"
        ln -sfn "$NGINX_SITE" "$NGINX_SITE_LINK"
    else
        rm -f "$NGINX_SITE_LINK" "$NGINX_SITE"
    fi
    if [[ -n "$default_target" ]]; then
        ln -sfn "$default_target" /etc/nginx/sites-enabled/default
    fi
    if ! nginx -t; then
        error "Предыдущая конфигурация Nginx также не проходит проверку."
        return 1
    fi
    systemctl reload nginx || {
        error "Предыдущая конфигурация Nginx восстановлена, но перезагрузить Nginx не удалось."
        return 1
    }
}

write_http_challenge_config() {
    local domain="$1" temporary backup=""
    validate_domain "$domain" || die "Некорректный домен сертификата."
    temporary="$(mktemp /etc/nginx/sites-available/vpn-site.XXXXXX)"
    cat >"$temporary" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location / {
        return 200 'Certificate setup in progress\n';
        add_header Content-Type text/plain;
    }
}
EOF
    chmod 0644 "$temporary"
    if [[ -f "$NGINX_SITE" ]]; then
        backup="$(mktemp)"
        cp -a "$NGINX_SITE" "$backup"
    fi
    mv -f "$temporary" "$NGINX_SITE"
    ln -sfn "$NGINX_SITE" "$NGINX_SITE_LINK"
    if ! nginx -t; then
        restore_nginx_site "$backup" || true
        rm -f -- "$backup"
        return 1
    fi
    if ! systemctl reload nginx; then
        restore_nginx_site "$backup" || true
        rm -f -- "$backup"
        return 1
    fi
    rm -f -- "$backup"
}

check_domain_dns() {
    local domain="$1" addresses
    addresses="$(dig +short A "$domain"; dig +short AAAA "$domain")"
    if [[ -z "$addresses" ]]; then
        error "Для $domain не найдена публичная DNS-запись A или AAAA."
        return 1
    fi
    info "$domain разрешается в: $(tr '\n' ' ' <<<"$addresses")"
    warn "DNS-запись должна указывать на этот сервер, а порты 80 и 443 должны быть доступны извне."
    confirm "Продолжить выпуск сертификата?" yes || return 1
}

issue_certificate() {
    local domain="$1" email="$2" backup=""
    check_domain_dns "$domain" || return 1
    if [[ -f "$NGINX_SITE" ]]; then
        backup="$(mktemp)"
        register_temporary_path "$backup"
        cp -a "$NGINX_SITE" "$backup"
    fi
    if ! write_http_challenge_config "$domain"; then
        rm -f -- "$backup"
        return 1
    fi
    if ! certbot certonly --non-interactive --agree-tos --no-eff-email \
        --email "$email" --webroot --webroot-path /var/www/letsencrypt \
        --cert-name "$domain" --domain "$domain" --keep-until-expiring; then
        restore_nginx_site "$backup" || true
        rm -f -- "$backup"
        return 1
    fi
    if [[ ! -s "/etc/letsencrypt/live/$domain/fullchain.pem" || \
          ! -s "/etc/letsencrypt/live/$domain/privkey.pem" ]]; then
        restore_nginx_site "$backup" || true
        rm -f -- "$backup"
        return 1
    fi
    rm -f -- "$backup"
}

install_renewal_hook() {
    install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat >/etc/letsencrypt/renewal-hooks/deploy/vpn-site-nginx <<'EOF'
#!/usr/bin/env bash
set -eu
/usr/sbin/nginx -t
/usr/bin/systemctl reload nginx
EOF
    chown root:root /etc/letsencrypt/renewal-hooks/deploy/vpn-site-nginx
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/vpn-site-nginx
}

track_initial_tls_state() {
    local hook=/etc/letsencrypt/renewal-hooks/deploy/vpn-site-nginx
    if [[ ! -e "/etc/letsencrypt/renewal/$DOMAIN.conf" && \
          ! -e "/etc/letsencrypt/live/$DOMAIN" ]]; then
        INSTALLATION_CERTIFICATE_CREATED=1
    fi
    if [[ -e "$hook" || -L "$hook" ]]; then
        INSTALLATION_RENEWAL_HOOK_BACKUP="$(mktemp)"
        register_temporary_path "$INSTALLATION_RENEWAL_HOOK_BACKUP"
        cp -a -- "$hook" "$INSTALLATION_RENEWAL_HOOK_BACKUP"
    fi
    INSTALLATION_RENEWAL_HOOK_CHANGED=1
}

restore_initial_tls_state() {
    local hook="${1:-/etc/letsencrypt/renewal-hooks/deploy/vpn-site-nginx}"
    if (( INSTALLATION_RENEWAL_HOOK_CHANGED == 1 )); then
        if [[ -n "$INSTALLATION_RENEWAL_HOOK_BACKUP" && \
              ( -e "$INSTALLATION_RENEWAL_HOOK_BACKUP" || \
                -L "$INSTALLATION_RENEWAL_HOOK_BACKUP" ) ]]; then
            rm -f -- "$hook"
            cp -a -- "$INSTALLATION_RENEWAL_HOOK_BACKUP" "$hook" || true
        else
            rm -f -- "$hook"
        fi
    fi
    if (( INSTALLATION_CERTIFICATE_CREATED == 1 )); then
        certbot delete --non-interactive --cert-name "$DOMAIN" >/dev/null 2>&1 || \
            warn "Не удалось удалить незавершённую цепочку сертификата для $DOMAIN."
    fi
    INSTALLATION_CERTIFICATE_CREATED=0
    INSTALLATION_RENEWAL_HOOK_CHANGED=0
    INSTALLATION_RENEWAL_HOOK_BACKUP=""
}

activate_tls_nginx() {
    local domain="$1" temporary backup="" default_target=""
    temporary="$(mktemp /etc/nginx/sites-available/vpn-site.XXXXXX)"
    render_nginx_config "$domain" "$temporary"
    chmod 0644 "$temporary"
    if [[ -f "$NGINX_SITE" ]]; then
        backup="$(mktemp)"
        cp -a "$NGINX_SITE" "$backup"
    fi
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        default_target="$(readlink /etc/nginx/sites-enabled/default)"
    fi
    mv -f "$temporary" "$NGINX_SITE"
    ln -sfn "$NGINX_SITE" "$NGINX_SITE_LINK"
    rm -f /etc/nginx/sites-enabled/default
    if ! nginx -t; then
        restore_nginx_site "$backup" "$default_target" || true
        rm -f -- "$backup"
        return 1
    fi
    if ! systemctl reload nginx; then
        restore_nginx_site "$backup" "$default_target" || true
        rm -f -- "$backup"
        return 1
    fi
    rm -f -- "$backup"
}

clear_domain_change_state() {
    DOMAIN_CHANGE_IN_PROGRESS=0
    DOMAIN_CHANGE_ENV_BACKUP=""
    DOMAIN_CHANGE_NGINX_BACKUP=""
    DOMAIN_CHANGE_MANAGER_BACKUP=""
    DOMAIN_CHANGE_OLD_DOMAIN=""
    DOMAIN_CHANGE_OLD_EMAIL=""
    DOMAIN_CHANGE_WAS_ACTIVE=0
}

rollback_domain_change_from_trap() {
    local failed=0
    (( DOMAIN_CHANGE_IN_PROGRESS == 1 )) || return 0
    DOMAIN_CHANGE_IN_PROGRESS=0
    warn "Смена домена прервана. Восстанавливается предыдущая конфигурация..."
    systemctl stop "$SERVICE_NAME" || true
    if [[ -f "$DOMAIN_CHANGE_ENV_BACKUP" ]]; then
        install -o root -g "$APP_GROUP" -m 0640 \
            "$DOMAIN_CHANGE_ENV_BACKUP" "$ENV_FILE" || failed=1
    fi
    if [[ -f "$DOMAIN_CHANGE_MANAGER_BACKUP" ]]; then
        install -o root -g "$APP_GROUP" -m 0640 \
            "$DOMAIN_CHANGE_MANAGER_BACKUP" "$MANAGER_CONFIG" || failed=1
    fi
    DOMAIN="$DOMAIN_CHANGE_OLD_DOMAIN"
    LETSENCRYPT_EMAIL="$DOMAIN_CHANGE_OLD_EMAIL"
    if [[ -f "$DOMAIN_CHANGE_NGINX_BACKUP" ]]; then
        restore_nginx_site "$DOMAIN_CHANGE_NGINX_BACKUP" || failed=1
    fi
    if (( DOMAIN_CHANGE_WAS_ACTIVE == 1 )); then
        systemctl start "$SERVICE_NAME" || failed=1
        wait_for_local_health 60 || failed=1
    fi
    clear_domain_change_state
    if (( failed != 0 )); then
        error "Автоматический откат домена выполнен не полностью; проверьте Nginx и сервис приложения."
        return 1
    fi
    success "Предыдущая конфигурация домена восстановлена."
}

configure_initial_certificate() {
    track_initial_tls_state
    issue_certificate "$DOMAIN" "$LETSENCRYPT_EMAIL" || \
        die "Не удалось выпустить сертификат Let's Encrypt. Проверьте DNS и порты 80/443."
    install_renewal_hook
    activate_tls_nginx "$DOMAIN" || die "Созданная TLS-конфигурация Nginx некорректна."
    systemctl enable --now certbot.timer
    success "Сертификат Let's Encrypt установлен; автоматическое продление включено."
}

show_certificate_status() {
    require_installed
    printf '\nСертификат для %s\n' "$DOMAIN"
    if [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" \
            -noout -subject -issuer -dates -fingerprint -sha256
        printf '\nТаймер Certbot: '
        systemctl is-active certbot.timer || true
        systemctl list-timers certbot.timer --no-pager || true
    else
        warn "Файлы сертификата отсутствуют."
    fi
}

renew_certificate_now() {
    require_installed
    info "Запрашивается продление сертификата..."
    certbot renew --cert-name "$DOMAIN" --force-renewal --no-random-sleep-on-renew
    nginx -t
    systemctl reload nginx
    show_certificate_status
}

test_certificate_renewal() {
    require_installed
    certbot renew --cert-name "$DOMAIN" --dry-run --no-random-sleep-on-renew
    success "Тестовое продление Let's Encrypt прошло успешно."
}

change_domain() {
    local old_domain="$DOMAIN" old_email="$LETSENCRYPT_EMAIL"
    local new_domain new_email env_backup nginx_backup manager_backup was_active=0
    require_installed
    prompt_validated_domain
    new_domain="$DOMAIN"
    DOMAIN="$old_domain"
    [[ "$new_domain" != "$old_domain" ]] || die "Домен не изменился."
    prompt_default "Email для Let's Encrypt" "$old_email" new_email
    validate_email "$new_email" || die "Некорректный адрес электронной почты."
    printf '\nВо время выпуска нового сертификата сайт будет кратковременно недоступен.\n'
    confirm "Перенести сайт с $old_domain на $new_domain?" no || return 0

    env_backup="$(backup_environment)"
    nginx_backup="$(mktemp)"
    manager_backup="$(mktemp)"
    register_temporary_path "$nginx_backup"
    register_temporary_path "$manager_backup"
    cp -a "$NGINX_SITE" "$nginx_backup"
    cp -a "$MANAGER_CONFIG" "$manager_backup"
    systemctl is-active --quiet "$SERVICE_NAME" && was_active=1
    DOMAIN_CHANGE_ENV_BACKUP="$env_backup"
    DOMAIN_CHANGE_NGINX_BACKUP="$nginx_backup"
    DOMAIN_CHANGE_MANAGER_BACKUP="$manager_backup"
    DOMAIN_CHANGE_OLD_DOMAIN="$old_domain"
    DOMAIN_CHANGE_OLD_EMAIL="$old_email"
    DOMAIN_CHANGE_WAS_ACTIVE="$was_active"
    DOMAIN_CHANGE_IN_PROGRESS=1

    if ! issue_certificate "$new_domain" "$new_email"; then
        rollback_domain_change_from_trap || true
        die "Не удалось выпустить новый сертификат; прежний домен остался настроен."
    fi

    env_set CORS_ALLOWED_ORIGINS "https://$new_domain"
    env_set TRUSTED_HOSTS "$new_domain"
    env_set YOOKASSA_RETURN_URL "https://$new_domain"
    DOMAIN="$new_domain"
    LETSENCRYPT_EMAIL="$new_email"
    write_manager_config
    if ! activate_tls_nginx "$new_domain"; then
        rollback_domain_change_from_trap || true
        die "Новая конфигурация Nginx не прошла проверку; прежний домен остался настроен."
    fi

    if ! validate_application_environment || \
       { (( was_active == 1 )) && \
         { ! systemctl restart "$SERVICE_NAME" || ! wait_for_local_health 45; }; }; then
        warn "Новая конфигурация домена не заработала; выполняется откат."
        rollback_domain_change_from_trap || true
        die "Смена домена отменена с восстановлением предыдущей конфигурации."
    fi
    clear_domain_change_state
    success "Домен сайта изменён на https://$new_domain"
    warn "Старый сертификат сохранён. Отзывайте или удаляйте его только после проверки переноса DNS."
}

certificate_menu() {
    local choice
    while true; do
        clear
        printf 'Менеджер VPN Site - сертификаты\n\n'
        printf '1. Состояние сертификата\n'
        printf '2. Тестовое продление\n'
        printf '3. Продлить сейчас\n'
        printf '4. Изменить домен сайта\n'
        printf '0. Назад\n\n'
        printf 'Выберите пункт: ' >/dev/tty
        IFS= read -r choice </dev/tty
        case "$choice" in
            1) show_certificate_status; pause ;;
            2) test_certificate_renewal; pause ;;
            3) renew_certificate_now; pause ;;
            4) change_domain; pause ;;
            0) return 0 ;;
            *) warn "Неизвестный пункт меню."; pause ;;
        esac
    done
}
