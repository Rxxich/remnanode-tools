# shellcheck shell=bash

CONTAINER_LOG_DIR="/var/log/remnanode"
DEFAULT_APP_PORT="9977"
NODE_VERSIONS=("latest" "dev" "2.8.0" "2.7.0")
DOCKER_FP="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

NODE_DIR=""; NGINX_DIR=""; SITE_DIR=""; CORE_DIR=""; LOG_DIR=""; CORE_BIN=""
CERT_KEY=""; CERT_PEM=""; NODE_NAME=""; NGINX_NAME=""; NODE_HOSTNAME=""
LOGROTATE_FILE=""; DEPLOY_HOOK=""; NODE_IMAGE_REF=""; ACME_WEBROOT=""

resolve_layout() {
    BASE_NAME="${BASE_NAME:-remnanode}"
    NODE_DIR="/opt/$BASE_NAME"
    NGINX_DIR="$NODE_DIR/nginx"
    SITE_DIR="$NODE_DIR/site"
    CORE_DIR="/var/lib/$BASE_NAME"
    LOG_DIR="/var/log/$BASE_NAME"
    CERT_KEY="$NGINX_DIR/privkey.key"
    CERT_PEM="$NGINX_DIR/fullchain.pem"
    ACME_WEBROOT="$NODE_DIR/acme"
    if [ "${STEALTH:-no}" = "yes" ]; then CORE_BIN="$CORE_DIR/$BASE_NAME"; else CORE_BIN="$CORE_DIR/xray"; fi
    NODE_NAME="$BASE_NAME"
    NGINX_NAME="${BASE_NAME}-proxy"
    NODE_HOSTNAME="$BASE_NAME"
    LOGROTATE_FILE="/etc/logrotate.d/$BASE_NAME"
    DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/${BASE_NAME}-sync.sh"
    if [ "${STEALTH:-no}" = "yes" ] && [ -n "${IMAGE_ALIAS:-}" ]; then
        NODE_IMAGE_REF="$IMAGE_ALIAS"
    else
        NODE_IMAGE_REF="remnawave/node:${NODE_VERSION:-latest}"
    fi
    return 0
}

docker_repo_setup() {
    local keyring=/etc/apt/keyrings/docker.gpg list=/etc/apt/sources.list.d/docker.list tmp
    mkdir -p /etc/apt/keyrings
    tmp=$(mktemp)
    if ! curl -fsSL --proto '=https' --max-time 30 "https://download.docker.com/linux/$OS_ID/gpg" -o "$tmp"; then
        rm -f "$tmp"; echo "ключ Docker недоступен"; return 1
    fi
    if ! import_pinned_key "$tmp" "$DOCKER_FP" "$keyring"; then
        rm -f "$tmp"; echo "ключ Docker не совпал с отпечатком $DOCKER_FP"; return 1
    fi
    rm -f "$tmp"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable" >"$list"
    apt_update
}

docker_install() {
    if docker_repo_setup && apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        systemctl enable --now docker
        return 0
    fi
    echo "apt-репозиторий Docker не сработал — запасной вариант get.docker.com"
    rm -f /etc/apt/sources.list.d/docker.list
    local tmp; tmp=$(mktemp)
    curl -fsSL --proto '=https' https://get.docker.com -o "$tmp" && sh "$tmp"
    local rc=$?; rm -f "$tmp"; return "$rc"
}

compose_install() {
    apt_install docker-compose-plugin && return 0
    docker_repo_setup && apt_install docker-compose-plugin && return 0
    apt_install docker-compose
}

install_dependencies() {
    title "Установка зависимостей"
    local need_docker=0 need_compose=0
    has docker || need_docker=1
    docker compose version >/dev/null 2>&1 || need_compose=1
    pb_init $(( 12 + need_docker * 25 + need_compose * 8 ))

    step 3 "Обновление списка пакетов" "apt-get ${APT_OPTS[*]} update"
    step 8 "Базовые утилиты (curl, cron, socat, unzip, jq…)" \
        "apt-get ${APT_OPTS[*]} install ca-certificates curl cron socat unzip wget jq gnupg openssl iproute2 logrotate"

    if [ "$need_docker" -eq 1 ]; then
        stepf 25 "Установка Docker Engine" docker_install
    else
        info "Docker уже установлен ${C_DIM}($(docker --version 2>/dev/null | head -n1))${C_RST}"
    fi
    if ! docker compose version >/dev/null 2>&1; then
        stepf 8 "Установка плагина docker compose" compose_install
    else
        [ "$need_compose" -eq 0 ] && info "Плагин docker compose уже есть"
    fi
    step 1 "Подготовка каталогов" "mkdir -p '$NGINX_DIR' '$CORE_DIR'"
    ok "Зависимости готовы"
}

setup_acme() {
    title "acme.sh и центр сертификации"
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        pb_init 4
        step 4 "Установка acme.sh" \
            "t=\$(mktemp) && curl -fsSL --proto '=https' https://get.acme.sh -o \"\$t\" && sh \"\$t\" email='$EMAIL'; rc=\$?; rm -f \"\$t\"; exit \$rc"
    else
        info "acme.sh уже установлен"
    fi
    export LE_WORKING_DIR="$HOME/.acme.sh"
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server "${CA_SERVER:-letsencrypt}" >>"$LOG_FILE" 2>&1 || true
    ok "Центр сертификации: ${C_B}${CA_SERVER:-letsencrypt}${C_RST}"
}

_acme_issue_alpn() {
    local extra=()
    has ufw && extra+=(--pre-hook "ufw allow 8443/tcp" --post-hook "ufw delete allow 8443/tcp")
    [ "${CERT_REISSUE:-0}" = "1" ] && extra+=(--force)
    "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN" \
        --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" --alpn --tlsport 8443 "${extra[@]}"
    return 0
}

issue_certificate() {
    title "SSL-сертификат"
    local ACME_ECC_DIR="$HOME/.acme.sh/${DOMAIN}_ecc"
    local ACME_RSA_DIR="$HOME/.acme.sh/${DOMAIN}"
    local LE_LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
    mkdir -p "$NGINX_DIR"

    case "${VALIDATION_METHOD:-alpn}" in
        dns|http)
            cert_issue_acme || die "Не удалось выпустить сертификат. Подробности: $LOG_FILE"
            ok "Сертификат готов ${C_DIM}($(cert_method_label))${C_RST}"
            return 0 ;;
        custom)
            cert_install_custom || die "Свой сертификат не установлен"
            ok "Свой сертификат установлен"
            return 0 ;;
    esac

    local reused=0
    if [ "${CERT_REISSUE:-0}" != "1" ]; then
        reused=1
        if [ -f "$LE_LIVE_DIR/fullchain.pem" ] && [ -f "$LE_LIVE_DIR/privkey.pem" ]; then
            info "Найден сертификат certbot в $LE_LIVE_DIR — использую его"
            cp -L "$LE_LIVE_DIR/fullchain.pem" "$CERT_PEM"
            cp -L "$LE_LIVE_DIR/privkey.pem" "$CERT_KEY"
            chmod 600 "$CERT_KEY"
            CERT_SOURCE="letsencrypt_live"

        elif [ -f "$CERT_PEM" ] && [ -f "$CERT_KEY" ]; then
            info "Сертификаты уже лежат в $NGINX_DIR — выпуск пропускаю"
            CERT_SOURCE="nginx_existing"

        elif [ -f "$ACME_ECC_DIR/fullchain.cer" ] && [ -f "$ACME_ECC_DIR/${DOMAIN}.key" ]; then
            info "Сертификат найден в кэше acme.sh (ECC) — устанавливаю"
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
                --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" --ecc >>"$LOG_FILE" 2>&1
            CERT_SOURCE="acme_ecc"

        elif [ -f "$ACME_RSA_DIR/fullchain.cer" ] && [ -f "$ACME_RSA_DIR/${DOMAIN}.key" ]; then
            info "Сертификат найден в кэше acme.sh (RSA) — устанавливаю"
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
                --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" >>"$LOG_FILE" 2>&1
            CERT_SOURCE="acme_rsa"
        else
            reused=0
        fi
    fi

    if [ "$reused" = "1" ]; then
        :
    elif [ "${VALIDATION_METHOD:-alpn}" = "cloudflare" ]; then
        info "Выпуск через Cloudflare DNS-01 (certbot)"
        pb_init 22
        step 10 "Установка certbot + dns-cloudflare" \
            "apt-get ${APT_OPTS[*]} install certbot python3-certbot-dns-cloudflare"
        local CF_INI="$NODE_DIR/cloudflare.ini"
        mkdir -p "$NODE_DIR"
        ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CF_Token" >"$CF_INI" )
        step 12 "Выпуск сертификата для $DOMAIN" \
            "certbot certonly --dns-cloudflare --dns-cloudflare-credentials '$CF_INI' \
                --dns-cloudflare-propagation-seconds 60 \
                -d '$DOMAIN' --non-interactive --agree-tos -m '$EMAIL'"
        cp -L "$LE_LIVE_DIR/fullchain.pem" "$CERT_PEM"
        cp -L "$LE_LIVE_DIR/privkey.pem" "$CERT_KEY"
        chmod 600 "$CERT_KEY"
        CERT_SOURCE="letsencrypt_live"

    else
        info "Выпуск через standalone TLS-ALPN (порт 8443)"
        has ufw && { ufw allow 8443/tcp >>"$LOG_FILE" 2>&1 || true; }
        pb_init 6
        stepf 6 "Выпуск сертификата для $DOMAIN" _acme_issue_alpn
        if [ ! -s "$CERT_PEM" ]; then
            if [ -f "$ACME_ECC_DIR/fullchain.cer" ]; then
                warn "acme.sh вернул ошибку, но файлы сертификата есть — копирую"
                "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
                    --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" --ecc >>"$LOG_FILE" 2>&1
            else
                has ufw && { ufw delete allow 8443/tcp >>"$LOG_FILE" 2>&1 || true; }
                die "Не удалось выпустить сертификат. Проверь, что порт 8443 доступен извне."
            fi
        fi
        has ufw && { ufw delete allow 8443/tcp >>"$LOG_FILE" 2>&1 || true; }
        CERT_SOURCE="acme_new"
    fi
    ok "Сертификат готов ${C_DIM}(источник: $CERT_SOURCE)${C_RST}"
}

setup_renewal() {
    title "Автопродление сертификата"
    local ACME_ECC_DIR="$HOME/.acme.sh/${DOMAIN}_ecc"
    local ACME_RSA_DIR="$HOME/.acme.sh/${DOMAIN}"
    local LE_LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
    local ACME_CERT_FLAG=""

    cert_write_helper
    case "${VALIDATION_METHOD:-alpn}" in
        dns|http)
            _acme_has_cron || "$ACME_SH" --install-cronjob >>"$LOG_FILE" 2>&1 || true
            if _acme_has_cron; then ok "acme.sh продлит сертификат сам (cron), после продления — перезапуск nginx и ноды"
            else warn "Cron acme.sh не установился — проверь: crontab -l"
            fi
            return 0 ;;
        custom)
            info "Свой сертификат сам не продлевается."
            note "Срок виден в «SSL-сертификат», напоминание можно включить там же (Telegram)."
            return 0 ;;
    esac

    if [ "$CERT_SOURCE" != "letsencrypt_live" ]; then
        if [ -d "$ACME_ECC_DIR" ]; then ACME_CERT_FLAG="--ecc"
        elif [ -d "$ACME_RSA_DIR" ]; then ACME_CERT_FLAG=""
        else CERT_SOURCE="unmanaged"
        fi
    fi

    if [ "$CERT_SOURCE" = "letsencrypt_live" ]; then
        info "Сертификатом управляет certbot — ставлю deploy-hook"
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat >"$DEPLOY_HOOK" <<HOOKEOF
#!/bin/bash
case ",\${RENEWED_DOMAINS// /,}," in
  *",$DOMAIN,"*)
    cp -L "$LE_LIVE_DIR/fullchain.pem" "$CERT_PEM"
    cp -L "$LE_LIVE_DIR/privkey.pem" "$CERT_KEY"
    chmod 600 "$CERT_KEY"
    docker compose -f $NGINX_DIR/docker-compose.yml restart
    docker compose -f $NODE_DIR/docker-compose.yml restart
    ;;
esac
HOOKEOF
        chmod +x "$DEPLOY_HOOK"
        if ! crontab -l 2>/dev/null | grep -qF "certbot renew"; then
            (crontab -l 2>/dev/null || true; echo "0 3 * * * certbot renew --quiet") | crontab -
        fi
        ok "Deploy-hook и cron certbot настроены"

    elif [ "$CERT_SOURCE" = "unmanaged" ]; then
        warn "Файлы сертификата есть, но acme.sh их не выпускал — автопродление пропущено."
        note "Настрой продление вручную."
    else
        local PRE_HOOK="true" POST_HOOK="true"
        if has ufw; then
            PRE_HOOK="ufw allow 8443/tcp && ufw reload"
            POST_HOOK="ufw delete allow 8443/tcp && ufw reload"
        fi
        # shellcheck disable=SC2086
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" $ACME_CERT_FLAG \
            --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" \
            --pre-hook "$PRE_HOOK" --post-hook "$POST_HOOK" \
            --reloadcmd "docker compose -f $NGINX_DIR/docker-compose.yml restart && docker compose -f $NODE_DIR/docker-compose.yml restart" \
            >>"$LOG_FILE" 2>&1
        local CRON_JOB="0 0 * * * \"$HOME/.acme.sh\"/acme.sh --cron --home \"$HOME/.acme.sh\" > /dev/null"
        if ! crontab -l 2>/dev/null | grep -qF "acme.sh --cron"; then
            (crontab -l 2>/dev/null || true; echo "$CRON_JOB") | crontab -
        fi
        ok "Cron-задача acme.sh настроена"
    fi
}

write_nginx() {
    title "Конфигурация Nginx"
    local root_location
    case "${STUB_MODE:-none}" in
        service)
            root_location="    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }" ;;
        static)
            root_location="    root /var/www/site;
    index index.html;

    location / {
        try_files \$uri \$uri/ \$uri.html /index.html;
    }

    location = /robots.txt {
        try_files \$uri =404;
        access_log off;
    }

    location ~* \.(?:css|js|mjs|png|jpe?g|gif|svg|webp|avif|ico|woff2?|ttf|eot|mp4|webm)\$ {
        expires 7d;
        add_header Cache-Control \"public, max-age=604800\";
        try_files \$uri =404;
    }" ;;
        *)
            root_location="    location / {
        return 401;
    }" ;;
    esac

    mkdir -p "$NGINX_DIR" "$SITE_DIR" "$ACME_WEBROOT"
    cat >"$NGINX_DIR/nginx.conf" <<EOF
map \$proxy_protocol_addr \$client_addr {
    ""      \$remote_addr;
    default \$proxy_protocol_addr;
}
log_format main_real '\$client_addr - \$remote_user [\$time_local] "\$request" '
                     '\$status \$body_bytes_sent "\$http_referer" '
                     '"\$http_user_agent" "\$http_x_forwarded_for"';

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type text/plain;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    set_real_ip_from unix:;
    real_ip_header proxy_protocol;
    access_log /var/log/nginx/access.log main_real;
    server_name $DOMAIN;
    http2 on;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.key;

    location ^~ $XHTTP_PATH {
        client_max_body_size 0;

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_set_header Host \$host;
        proxy_http_version 1.1;
        proxy_set_header Connection "keep-alive";

        client_body_timeout 5m;
        proxy_read_timeout 315s;
        proxy_send_timeout 5m;
        proxy_pass http://unix:/dev/shm/xrxh.socket;
    }

    location ^~ $GRPC_PATH {
        client_max_body_size 0;

        client_body_timeout 5m;
        grpc_set_header X-Real-IP \$proxy_protocol_addr;
        grpc_set_header X-Forwarded-For \$proxy_protocol_addr;
        grpc_set_header Host \$host;
        grpc_socket_keepalive on;
        grpc_read_timeout 315s;
        grpc_send_timeout 5m;

        grpc_pass grpc://unix:/dev/shm/grpc.socket;
    }

$root_location
}
EOF

    cat >"$NGINX_DIR/docker-compose.yml" <<EOF
services:
  nginx:
    image: nginx:latest
    container_name: $NGINX_NAME
    restart: always
    network_mode: host
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "5"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/certs/privkey.key:ro
      - $SITE_DIR:/var/www/site:ro
      - $ACME_WEBROOT:/var/www/acme:ro
      - /dev/shm:/dev/shm:rw
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
EOF

    pb_init 12
    step 10 "Запуск nginx-прокси" "docker compose -f '$NGINX_DIR/docker-compose.yml' up -d --force-recreate"
    step 2 "Проверка конфигурации nginx" "sleep 2 && docker exec '$NGINX_NAME' nginx -t"
}

write_node_compose() {
    local volumes=""
    volumes+="      - $NGINX_DIR/fullchain.pem:/etc/nginx/certs/fullchain.pem:ro"$'\n'
    volumes+="      - $NGINX_DIR/privkey.key:/etc/nginx/certs/privkey.key:ro"$'\n'
    volumes+="      - /dev/shm:/dev/shm:rw"$'\n'
    if [ "${XRAY_LOGS:-no}" = "yes" ]; then
        volumes+="      - $LOG_DIR:$CONTAINER_LOG_DIR"$'\n'
    fi
    if [ "${CUSTOM_CORE:-no}" = "yes" ]; then
        volumes+="      - $CORE_BIN:/usr/local/bin/xray"$'\n'
    fi
    mkdir -p "$NODE_DIR"
    ( umask 077; cat >"$NODE_DIR/docker-compose.yml" <<EOF
services:
  $NODE_NAME:
    container_name: $NODE_NAME
    hostname: $NODE_HOSTNAME
    image: ${NODE_IMAGE_REF}
    network_mode: host
    restart: always
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "5"
    cap_add:
      - NET_ADMIN
    volumes:
${volumes}    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT:-2222}
      - SECRET_KEY=$SECRET_KEY
EOF
    )
}

deploy_node() {
    title "Установка Remnanode ($NODE_VERSION)"
    write_node_compose
    pb_init 12
    if [ "$STEALTH" = "yes" ] && [ -n "$IMAGE_ALIAS" ]; then
        step 12 "Подготовка образа приложения" \
            "docker pull remnawave/node:$NODE_VERSION && \
             docker tag remnawave/node:$NODE_VERSION $IMAGE_ALIAS && \
             (docker rmi remnawave/node:$NODE_VERSION 2>/dev/null || true) && \
             docker compose -f '$NODE_DIR/docker-compose.yml' up -d"
    else
        step 12 "Запуск контейнера remnanode" "docker compose -f '$NODE_DIR/docker-compose.yml' up -d"
    fi
}

restart_node() {
    if [ -f "$NODE_DIR/docker-compose.yml" ]; then
        pb_init 8
        step 8 "Перезапуск ноды" "docker compose -f '$NODE_DIR/docker-compose.yml' up -d --force-recreate"
    fi
}

find_node_container() {
    has docker || return 0
    if docker inspect "$NODE_NAME" >/dev/null 2>&1; then echo "$NODE_NAME"; return 0; fi
    docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null \
        | awk -v alias="${IMAGE_ALIAS:-}" '$2 ~ /remnawave\/node/ || (alias != "" && $2 == alias) {print $1; exit}' || true
}

compose_image() { sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$1" 2>/dev/null | head -n1 | tr -d "\"'"; }

node_is_alias() { [ -n "${IMAGE_ALIAS:-}" ] && [ "$(compose_image "$NODE_DIR/docker-compose.yml")" = "$IMAGE_ALIAS" ]; }

node_image_tag() {
    local img
    if node_is_alias; then echo "${NODE_VERSION:-latest}"; return 0; fi
    img=$(compose_image "$NODE_DIR/docker-compose.yml"); img="${img##*/}"
    if [[ "$img" == *:* ]]; then echo "${img##*:}"; else echo "latest"; fi
}

container_image_id() { docker inspect -f '{{.Image}}' "$1" 2>/dev/null; }
image_date() { date -d "$(docker image inspect -f '{{.Created}}' "$1" 2>/dev/null)" +%d.%m.%Y 2>/dev/null; }

_pull_nginx() { docker compose -f "$NGINX_DIR/docker-compose.yml" pull; }

_pull_node() {
    if node_is_alias; then
        docker pull "remnawave/node:$1" && docker tag "remnawave/node:$1" "$IMAGE_ALIAS" || return 1
        docker rmi "remnawave/node:$1" >/dev/null 2>&1
        return 0
    fi
    docker compose -f "$NODE_DIR/docker-compose.yml" pull
}

_update_report() {
    if [ "$4" = "fail" ]; then
        err "$1: не обновлён — образ не скачался или контейнер не запустился. Подробности: $LOG_FILE"
    elif [ -z "$3" ]; then
        warn "$1: контейнер не запущен — проверь: docker ps -a"
    elif [ "$2" = "$3" ]; then
        ok "$1: уже последняя версия ${C_DIM}(образ от $(image_date "$3"))${C_RST}"
    else
        ok "$1: обновлён ${C_DIM}(образ от $(image_date "$3"))${C_RST}"
        [ -n "$2" ] && docker rmi "$2" >/dev/null 2>&1 && note "старый образ $1 удалён"
    fi
    return 0
}

action_update_containers() {
    ui_screen "Обновление Remnanode и nginx"
    has docker || { err "Docker не установлен"; return 0; }
    local ng=0 nd=0 tag="" img="" ng_img old_ng old_nd ng_rc=ok nd_rc=ok
    [ -f "$NGINX_DIR/docker-compose.yml" ] && ng=1
    if [ -f "$NODE_DIR/docker-compose.yml" ]; then
        img=$(compose_image "$NODE_DIR/docker-compose.yml")
        tag=$(node_image_tag)
        case "$tag" in latest|dev) nd=1 ;; esac
    fi
    if [ "$ng" = 0 ] && [ -z "$img" ]; then
        warn "Нода не установлена: нет $NODE_DIR/docker-compose.yml"
        return 0
    fi
    ng_img=$(compose_image "$NGINX_DIR/docker-compose.yml")

    ui_box_top "Что будет обновлено"
    if [ "$ng" = 1 ]; then ui_kv "nginx" "$(ui_badge_ok "обновится")  ${C_DIM}${ng_img:-nginx}${C_RST}"
    else ui_kv "nginx" "$(ui_badge_off "не найден")"
    fi
    if [ "$nd" = 1 ]; then
        ui_kv "Remnanode" "$(ui_badge_ok "обновится")  ${C_DIM}remnawave/node:$tag${C_RST}"
    elif [ -n "$img" ]; then
        ui_kv "Remnanode" "$(ui_badge_off "не обновляется")  ${C_DIM}remnawave/node:$tag — закреплена${C_RST}"
    else
        ui_kv "Remnanode" "$(ui_badge_off "не найдена")"
    fi
    ui_box_bottom
    [ "$nd" = 1 ] && note "Если выйдет новый образ ноды, контейнер перезапустится: клиенты переподключатся за несколько секунд."
    [ "$nd" = 0 ] && [ -n "$img" ] && note "Нода обновляется, только если в docker-compose у неё тег latest или dev."
    echo
    ui_confirm "Скачать свежие образы и перезапустить обновлённые контейнеры? Старые образы удалятся." y || return 0

    old_ng=$(container_image_id "$NGINX_NAME")
    old_nd=$(container_image_id "$NODE_NAME")
    pb_init $(( ng * 8 + nd * 14 ))
    if [ "$ng" = 1 ]; then
        { stepf_try 5 "Загрузка образа nginx" _pull_nginx \
          && step_try 3 "Запуск nginx на новом образе" "docker compose -f '$NGINX_DIR/docker-compose.yml' up -d"; } || ng_rc=fail
    fi
    if [ "$nd" = 1 ]; then
        { stepf_try 10 "Загрузка образа remnawave/node:$tag" _pull_node "$tag" \
          && step_try 4 "Запуск ноды на новом образе" "docker compose -f '$NODE_DIR/docker-compose.yml' up -d"; } || nd_rc=fail
    fi
    echo
    [ "$ng" = 1 ] && _update_report "nginx" "$old_ng" "$(container_image_id "$NGINX_NAME")" "$ng_rc"
    if [ "$nd" = 1 ]; then
        sleep 3
        _update_report "Remnanode" "$old_nd" "$(container_image_id "$NODE_NAME")" "$nd_rc"
        [ "$(docker inspect -f '{{.State.Running}}' "$NODE_NAME" 2>/dev/null)" = "true" ] \
            || warn "Нода не работает после обновления. Логи: docker logs --tail 50 $NODE_NAME"
    fi
    return 0
}

plan_install_weight() {
    local w=12
    has docker || w=$(( w + 25 ))
    docker compose version >/dev/null 2>&1 || w=$(( w + 8 ))
    [ "${VALIDATION_METHOD:-alpn}" != "custom" ] && [ ! -f "$HOME/.acme.sh/acme.sh" ] && w=$(( w + 4 ))
    case "${VALIDATION_METHOD:-alpn}" in
        cloudflare) w=$(( w + 22 )) ;;
        alpn)       w=$(( w + 6 )) ;;
        dns|http)   w=$(( w + 10 )) ;;
    esac
    [ "${WANT_CORE:-no}" = "yes" ] && w=$(( w + 12 ))
    [ "${WANT_LOGS:-no}" = "yes" ] && w=$(( w + 8 ))
    case "${STUB_MODE:-none}" in
        service) w=$(( w + 10 )) ;;
        static)  w=$(( w + 14 )) ;;
    esac
    w=$(( w + 24 ))
    if [ "${WANT_FW:-no}" = "yes" ]; then
        local n=1
        [ -n "${PANEL_IP:-}" ] && n=$(echo "${PANEL_IP//,/ }" | wc -w)
        w=$(( w + 6 + n + 3 ))
        has ufw || w=$(( w + 6 ))
    fi
    echo "$w"
}

ask_node_version() {
    local items=() v c
    for v in "${NODE_VERSIONS[@]}"; do
        c=""
        [ "$v" = "latest" ] && c="стабильная, рекомендуется"
        [ "$v" = "dev" ] && c="тестовая ветка"
        items+=("$v|remnawave/node:$v|$c|")
    done
    ui_menu c "Версия образа ноды" -d "${NODE_VERSION:-latest}" "${items[@]}" || return 1
    NODE_VERSION="$c"
    ok "Версия: ${C_B}remnawave/node:$NODE_VERSION${C_RST}"
}

INSTALL_VARS=(
    EMAIL DOMAIN SECRET_KEY NODE_VERSION NODE_PORT PANEL_IP STEALTH BASE_NAME IMAGE_ALIAS
    STUB_MODE SERVICE_NAME SERVICE_IMAGE SERVICE_PORT TEMPLATE_NAME APP_PORT XHTTP_PATH GRPC_PATH
    VALIDATION_METHOD CA_SERVER CF_Token CERT_DNS CERT_NAME CERT_WILDCARD
    WANT_CORE WANT_LOGS WANT_FW
)

install_back() { draft_keep install "${INSTALL_VARS[@]}"; }

onoff() { if [ "${1:-yes}" = yes ]; then echo on; else echo off; fi; }

action_install_node() {
    FW_PARAMS_ASKED=0
    draft_load install
    resolve_layout
    ui_screen "Установка Remnanode"
    note "Ответы сохраняются в $CONF_FILE — при повторном запуске они подставятся."
    note "Esc на любом вопросе — назад в меню; уже введённое тоже запомнится."
    echo
    ui_input EMAIL "Email для SSL" "${EMAIL:-}" valid_email "на него придут письма от центра сертификации" || { install_back; return 0; }
    ui_input DOMAIN "Домен ноды" "${DOMAIN:-}" valid_domain "например node.example.com" || { install_back; return 0; }
    ui_secret SECRET_KEY "SECRET_KEY из панели (Nodes → Add node)" valid_secret || { install_back; return 0; }
    echo
    ask_node_version || { install_back; return 0; }
    echo
    ask_stealth || { install_back; return 0; }
    choose_stub || { install_back; return 0; }
    APP_PORT="${APP_PORT:-$DEFAULT_APP_PORT}"

    title "Транспорт"
    ui_input XHTTP_PATH "XHTTP location path" "${XHTTP_PATH:-/xhttppath/}" valid_urlpath || { install_back; return 0; }
    ui_input GRPC_PATH "gRPC service name / path" "${GRPC_PATH:-/grpcpath}" valid_urlpath || { install_back; return 0; }
    [[ "$XHTTP_PATH" != /* ]] && XHTTP_PATH="/$XHTTP_PATH"
    [[ "$XHTTP_PATH" != */ ]] && XHTTP_PATH="$XHTTP_PATH/"
    [[ "$GRPC_PATH" != /* ]] && GRPC_PATH="/$GRPC_PATH"

    title "Дополнительно"
    local opts
    ui_checklist opts "Что ещё сделать" \
        "core|Кастомное ядро Xray (Jolymmiles)|$(onoff "${WANT_CORE:-${CUSTOM_CORE:-}}")|бинарник подменяется томом, обновляется из меню" \
        "logs|Логи Xray + logrotate|$(onoff "${WANT_LOGS:-${XRAY_LOGS:-}}")|access/error-логи на хосте с ротацией" \
        "fw|Firewall (ufw)|$(onoff "${WANT_FW:-}")|SSH, 80, 443 и порт ноды только для IP панели" || { install_back; return 0; }
    WANT_CORE="no"; WANT_LOGS="no"; WANT_FW="no"
    [[ " $opts " == *" core "* ]] && WANT_CORE="yes"
    [[ " $opts " == *" logs "* ]] && WANT_LOGS="yes"
    [[ " $opts " == *" fw "* ]] && WANT_FW="yes"
    echo
    if [ "$WANT_FW" = "yes" ]; then
        ask_firewall_params || { install_back; return 0; }
    else
        ui_input NODE_PORT "Порт Remnanode" "${NODE_PORT:-2222}" valid_port || { install_back; return 0; }
    fi

    title "SSL"
    cert_ask_method || { install_back; return 0; }

    CUSTOM_CORE="$WANT_CORE"
    XRAY_LOGS="$WANT_LOGS"
    resolve_layout

    ui_screen "Проверь параметры"
    ui_box_top "Установка"
    ui_kv "Домен" "${C_B}$DOMAIN${C_RST}"
    ui_kv "Email" "$EMAIL"
    ui_kv "Нода" "remnawave/node:$NODE_VERSION  ${C_DIM}порт${C_RST} ${NODE_PORT:-2222}"
    ui_kv "Скрытный режим" "$([ "${STEALTH:-no}" = yes ] && echo "${C_ACC2}да${C_RST} ($BASE_NAME)" || echo нет)"
    case "${STUB_MODE:-none}" in
        service) ui_kv "Заглушка" "docker: $SERVICE_NAME" ;;
        static)  ui_kv "Заглушка" "шаблон: $TEMPLATE_NAME" ;;
        *)       ui_kv "Заглушка" "нет (401)" ;;
    esac
    ui_kv "XHTTP / gRPC" "$XHTTP_PATH  $GRPC_PATH"
    ui_kv "SSL" "$(cert_method_label)"
    ui_kv "Ядро / логи" "$WANT_CORE / $WANT_LOGS"
    ui_kv "Firewall" "$([ "$WANT_FW" = yes ] && echo "ufw, панель: ${PANEL_IP:-все}" || echo нет)"
    ui_box_bottom
    echo
    ui_confirm "Начать установку?" y || { install_back; return 0; }
    cfg_save
    draft_drop install

    echo
    printf '  %sНачинаю установку%s   %sлог: %s%s\n' "$C_B" "$C_RST" "$C_DIM" "$LOG_FILE" "$C_RST"
    pb_begin "$(plan_install_weight)"

    install_dependencies
    [ "$VALIDATION_METHOD" != "custom" ] && setup_acme
    issue_certificate
    cert_forget_prev
    if [ "$WANT_CORE" = "yes" ]; then
        CORE_AUTO=1 install_custom_core || warn "Кастомное ядро не установлено — продолжаю без него."
    fi
    if [ "$WANT_LOGS" = "yes" ]; then
        setup_xray_logs || warn "Логи Xray не настроены — продолжаю."
    fi
    deploy_stub
    write_nginx
    deploy_node
    [ "$WANT_FW" = "yes" ] && setup_firewall
    pb_end

    setup_crowdsec_nginx || warn "Интеграция с CrowdSec не настроена — продолжаю."
    setup_renewal
    cfg_save
    summary
}

summary() {
    echo
    ui_box_top "${C_OK}Установка завершена${C_RST}"
    ui_kv "Домен" "${C_B}$DOMAIN${C_RST}"
    ui_kv "Нода" "remnawave/node:$NODE_VERSION  ${C_DIM}порт${C_RST} ${NODE_PORT:-2222}"
    [ "${STEALTH:-no}" = "yes" ] && ui_kv "Скрытный режим" "включён (базовое имя: $BASE_NAME)"
    if [ "${WANT_FW:-no}" = "yes" ]; then
        ui_kv "Firewall" "$([ -n "${PANEL_IP:-}" ] && echo "порт ${NODE_PORT:-2222} только с ${PANEL_IP}" || echo "порт ${NODE_PORT:-2222} открыт всем")"
    fi
    case "${STUB_MODE:-none}" in
        service) ui_kv "Заглушка" "docker: $SERVICE_NAME (127.0.0.1:$APP_PORT)" ;;
        static)  ui_kv "Заглушка" "шаблон $TEMPLATE_NAME" ;;
        *)       ui_kv "Заглушка" "нет, location / → 401" ;;
    esac
    ui_kv "XHTTP путь" "$XHTTP_PATH"
    ui_kv "gRPC путь" "$GRPC_PATH"
    ui_kv "Кастомное ядро" "$([ "$CUSTOM_CORE" = yes ] && echo "да ($CORE_BIN)" || echo нет)"
    ui_kv "Логи Xray" "$([ "$XRAY_LOGS" = yes ] && echo "да ($LOG_DIR)" || echo нет)"
    ui_kv "Сертификат" "$(cert_method_label)"
    ui_box_bottom
    show_stealth_panel
    echo
    printf '  %sКонтейнеры:%s\n' "$C_DIM" "$C_RST"
    docker ps --format '    {{.Names}}\t{{.Status}}' 2>/dev/null || true
    echo
    note "Дальше рекомендую: «Оптимизация сервера» и «Защита сервера» в главном меню."
}
