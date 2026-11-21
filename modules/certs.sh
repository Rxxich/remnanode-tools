# shellcheck shell=bash

ACME_SH="$HOME/.acme.sh/acme.sh"
CERT_BIN="/usr/local/sbin/$KIT_NAME-cert"
CERT_CONF="$CONF_DIR/cert.conf"
CERT_CUSTOM_DIR="$CONF_DIR/custom-cert"
CERT_UNIT="/etc/systemd/system/$KIT_NAME-cert-check"
CERT_ENV=()
CERT_PREV=""
CERT_REISSUE=0
TG_TOKEN=""; TG_CHAT=""; TG_THREAD=""; TG_PROXY=""; TG_DAYS=""; CERT_TG_LOADED=0

CERT_DNS_PROVIDERS=(
    "dns_cf|Cloudflare|CF_Token*:API-токен Cloudflare (права Zone → DNS → Edit)|CF_Zone_ID?:Zone ID — если токен выдан только на одну зону"
    "dns_gcore|Gcore|GCORE_Key*:API-ключ Gcore"
    "dns_bunny|Bunny.net|BUNNY_API_KEY*:API-ключ Bunny"
    "dns_selectel|Selectel|SL_Ver=v2|SL_Login_ID:ID аккаунта Selectel|SL_Project_Name:Имя проекта|SL_Login_Name:Имя сервисного пользователя|SL_Pswd*:Пароль сервисного пользователя"
    "dns_timeweb|Timeweb Cloud|TW_Token*:API-токен Timeweb Cloud (JWT)"
    "dns_regru|Reg.ru|REGRU_API_Username:Логин Reg.ru|REGRU_API_Password*:Пароль API (в настройках API Reg.ru разреши IP этого сервера)"
    "dns_beget|Beget|Beget_Username:Логин Beget|Beget_Password*:Пароль API Beget"
    "dns_yc|Yandex Cloud|YC_Zone_ID:ID зоны DNS|YC_Folder_ID:ID каталога|YC_SA_ID:ID сервисного аккаунта|YC_SA_Key_ID:ID авторизованного ключа|YC_SA_Key_File_PEM_b64*:Закрытый ключ в base64 (base64 -w0 key.pem)"
)

valid_cred()     { [ -n "$1" ] && [[ "$1" != *"'"* ]]; }
valid_cred_opt() { [ -z "$1" ] || valid_cred "$1"; }
valid_env_kv()   { [ -z "$1" ] || { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*=.+$ ]] && valid_cred "$1"; }; }
valid_dns_plugin() {
    [[ "$1" =~ ^dns_[a-z0-9_]+$ ]] || return 1
    [ -d "$HOME/.acme.sh/dnsapi" ] || return 0
    [ -f "$HOME/.acme.sh/dnsapi/$1.sh" ]
}
valid_tg_token() { [[ "$1" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]]; }
valid_tg_chat()  { [[ "$1" =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})(:[0-9]+)?$ ]]; }
valid_proxy_opt(){ [ -z "$1" ] || [[ "$1" =~ ^(https?|socks5h?)://[^[:space:]\"\']+$ ]]; }
valid_days()     { [[ "$1" =~ ^[0-9]{1,2}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 60 ]; }

cert_names() {
    { openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^ ,]*' | sed 's/^DNS://'
      openssl x509 -in "$1" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p'
    } | sort -u
}

cert_covers() {
    local d="$1" e
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        [ "$e" = "$d" ] && return 0
        [[ "$e" == \*.* ]] && [ "${d#*.}" = "${e#\*.}" ] && return 0
    done <<<"$2"
    return 1
}

cert_days_left() {
    local end
    end=$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2) || return 1
    [ -n "$end" ] || return 1
    echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

cert_end_date() { date -d "$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2)" +%d.%m.%Y 2>/dev/null; }

cert_issuer() {
    local s o cn
    s=$(openssl x509 -in "$1" -noout -issuer 2>/dev/null)
    o=$(sed -n 's/.*O *= *\([^,]*\).*/\1/p' <<<"$s")
    cn=$(sed -n 's/.*CN *= *\([^,]*\).*/\1/p' <<<"$s")
    echo "${o:-$cn}${o:+${cn:+ ($cn)}}"
}

cert_dns_name() {
    local p
    for p in "${CERT_DNS_PROVIDERS[@]}"; do [ "${p%%|*}" = "$1" ] && { p="${p#*|}"; echo "${p%%|*}"; return 0; }; done
    echo "$1"
}

cert_method_label() {
    local ca="${CA_SERVER:-letsencrypt}"
    case "${VALIDATION_METHOD:-}" in
        dns)        echo "DNS API · $(cert_dns_name "${CERT_DNS:-?}") · $ca$([ "${CERT_WILDCARD:-no}" = yes ] && echo " · *.${CERT_NAME}")" ;;
        http)       echo "HTTP-01, порт 80 · $ca" ;;
        alpn)       echo "TLS-ALPN-01, порт 8443 · $ca" ;;
        cloudflare) echo "Cloudflare DNS · certbot" ;;
        custom)     echo "свой сертификат" ;;
        *)          echo "не выбран" ;;
    esac
}

cert_badge() {
    local d
    [ -s "$CERT_PEM" ] || return 0
    d=$(cert_days_left "$CERT_PEM") || return 0
    if [ "$d" -lt 0 ]; then ui_badge_err "истёк"
    elif [ "$d" -lt 14 ]; then ui_badge_warn "$d дн."
    fi
}

_acme_dir() {
    if [ -d "$HOME/.acme.sh/${1}_ecc" ]; then echo "$HOME/.acme.sh/${1}_ecc"
    elif [ -d "$HOME/.acme.sh/$1" ]; then echo "$HOME/.acme.sh/$1"
    fi
}
_acme_ecc_flag() { [ -d "$HOME/.acme.sh/${1}_ecc" ] && echo "--ecc"; }
_acme_conf_get() {
    local d; d=$(_acme_dir "$1"); [ -n "$d" ] || return 0
    sed -n "s/^$2='\(.*\)'\$/\1/p" "$d/$1.conf" 2>/dev/null | head -n1
}
_acme_has_cron() { crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; }

cert_tg_load() {
    CERT_TG_LOADED=1
    [ -f "$CERT_CONF" ] || return 0
    # shellcheck disable=SC1090
    . <(grep -E '^TG_[A-Z]+=' "$CERT_CONF")
    return 0
}

cert_write_conf() {
    local v
    mkdir -p "$CONF_DIR"
    ( umask 077
      { for v in DOMAIN NGINX_DIR NODE_DIR CERT_PEM ACME_WEBROOT NGINX_NAME BASE_NAME VALIDATION_METHOD \
                 TG_TOKEN TG_CHAT TG_THREAD TG_PROXY TG_DAYS; do
            printf '%s=%q\n' "$v" "${!v:-}"
        done
      } >"$CERT_CONF" )
    chmod 600 "$CERT_CONF"
}

cert_write_helper() {
    [ "$CERT_TG_LOADED" = 1 ] || cert_tg_load
    cert_write_conf
    sed -e "s|__CONF__|$CERT_CONF|g" -e "s|__KIT__|$KIT_NAME|g" >"$CERT_BIN" <<'HELPER'
#!/usr/bin/env bash
set -u
CONF=__CONF__
DOMAIN=""; NGINX_DIR=""; NODE_DIR=""; CERT_PEM=""; ACME_WEBROOT=""; NGINX_NAME=""; BASE_NAME=""
VALIDATION_METHOD=""; TG_TOKEN=""; TG_CHAT=""; TG_THREAD=""; TG_PROXY=""; TG_DAYS=14
[ -f "$CONF" ] && [ "$(stat -c %u "$CONF")" = 0 ] && . "$CONF"
TMP_NAME="${BASE_NAME:-remnanode}-acme"
CHAL="$ACME_WEBROOT/.well-known/acme-challenge"

say() { echo "__KIT__-cert: $*"; logger -t __KIT__-cert "$*" 2>/dev/null || true; }

tg() {
    [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 0
    local a=(--data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=$1")
    [ -n "$TG_THREAD" ] && a+=(--data-urlencode "message_thread_id=$TG_THREAD")
    { printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_TOKEN"
      [ -n "$TG_PROXY" ] && printf 'proxy = "%s"\n' "$TG_PROXY"
    } | curl -sS -m 20 -K - "${a[@]}"
}

days_left() {
    local end; end=$(openssl x509 -in "$CERT_PEM" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$end" ] && echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}
end_date() { date -d "$(openssl x509 -in "$CERT_PEM" -noout -enddate 2>/dev/null | cut -d= -f2)" +%d.%m.%Y 2>/dev/null; }

http_probe() {
    local t="probe-$$-$RANDOM" got
    mkdir -p "$CHAL" && echo "$t" >"$CHAL/$t" || return 1
    got=$(curl -s -m 5 -H "Host: $DOMAIN" "http://127.0.0.1/.well-known/acme-challenge/$t" 2>/dev/null)
    rm -f "$CHAL/$t"
    [ "$got" = "$t" ]
}
port80() { ss -Hltnp 'sport = :80' 2>/dev/null | grep -o 'users:(("[^"]*"' | sed 's/users:(("//; s/"$//' | sort -u | paste -sd, -; }

cmd_http_begin() {
    http_probe && { say "порт 80: проверочные файлы отдаёт nginx"; return 0; }
    local who; who=$(port80)
    if [ -n "$who" ]; then
        say "порт 80 занят ($who), но проверочные файлы не отдаются — HTTP-01 не пройдёт"
        tg "⚠️ $DOMAIN: порт 80 занят процессом «$who» — продление сертификата не пройдёт. Освободите порт или смените способ: rnt → SSL-сертификат." >/dev/null
        return 1
    fi
    say "порт 80 свободен — поднимаю временный nginx $TMP_NAME"
    docker rm -f "$TMP_NAME" >/dev/null 2>&1
    docker run -d --rm --name "$TMP_NAME" --network host \
        -v "$ACME_WEBROOT:/usr/share/nginx/html:ro" nginx:latest >/dev/null || return 1
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do http_probe && return 0; sleep 1; done
    say "временный nginx не отдаёт файлы"
    docker rm -f "$TMP_NAME" >/dev/null 2>&1
    return 1
}
cmd_http_end() { docker rm -f "$TMP_NAME" >/dev/null 2>&1; return 0; }

cmd_http_probe() {
    if http_probe; then echo "ok"; return 0; fi
    local who; who=$(port80)
    if [ -n "$who" ]; then echo "busy $who"; else echo "free"; fi
    return 1
}

cmd_deploy() {
    local f
    for f in "$NGINX_DIR/docker-compose.yml" "$NODE_DIR/docker-compose.yml"; do
        [ -f "$f" ] && docker compose -f "$f" restart >/dev/null 2>&1
    done
    say "сертификат установлен, nginx и нода перезапущены"
    [ -f "$NODE_DIR/docker-compose.yml" ] && tg "✅ $DOMAIN: SSL-сертификат обновлён, действует до $(end_date)" >/dev/null
    return 0
}

cmd_check() {
    local d; d=$(days_left)
    [ -n "$d" ] || { say "не прочитать $CERT_PEM"; return 0; }
    [ "$d" -le "${TG_DAYS:-14}" ] || return 0
    if [ "$VALIDATION_METHOD" = "custom" ]; then
        tg "⚠️ $DOMAIN: свой SSL-сертификат истекает через $d дн. ($(end_date)). Замените его: rnt → SSL-сертификат → Свой сертификат." >/dev/null
    else
        tg "⚠️ $DOMAIN: SSL-сертификат истекает через $d дн. ($(end_date)), автопродление не сработало. Проверьте: rnt → SSL-сертификат." >/dev/null
    fi
}

case "${1:-}" in
    http-begin) cmd_http_begin ;;
    http-end)   cmd_http_end ;;
    http-probe) cmd_http_probe ;;
    deploy)     cmd_deploy ;;
    check)      cmd_check ;;
    test)       tg "🔔 $DOMAIN: уведомления о SSL-сертификате работают. Сейчас осталось $(days_left) дн." ;;
    *) echo "usage: __KIT__-cert http-begin|http-end|http-probe|deploy|check|test" >&2; exit 2 ;;
esac
HELPER
    chmod 700 "$CERT_BIN"
}

cert_timer_set() {
    if [ "${1:-off}" = "on" ]; then
        cat >"$CERT_UNIT.service" <<EOF
[Unit]
Description=$KIT_NAME: проверка срока SSL-сертификата
[Service]
Type=oneshot
ExecStart=$CERT_BIN check
EOF
        cat >"$CERT_UNIT.timer" <<EOF
[Unit]
Description=$KIT_NAME: проверка срока SSL-сертификата раз в сутки
[Timer]
OnCalendar=*-*-* 09:00:00
RandomizedDelaySec=30min
Persistent=true
[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now "$KIT_NAME-cert-check.timer" >/dev/null 2>&1
    else
        systemctl disable --now "$KIT_NAME-cert-check.timer" >/dev/null 2>&1 || true
        rm -f "$CERT_UNIT.service" "$CERT_UNIT.timer"
        systemctl daemon-reload
    fi
}

cert_ask_method() {
    local m
    CERT_PREV="${VALIDATION_METHOD:-}|${CERT_NAME:-${DOMAIN:-}}"
    ui_menu m "Как получить SSL-сертификат" -d "${VALIDATION_METHOD:-http}" \
        "http|HTTP-01 через порт 80 (acme.sh)|без ключей API; A-запись домена — на этот сервер, порт 80 открыт|" \
        "dns|DNS API провайдера (acme.sh)|Cloudflare, Gcore, Bunny, Selectel, Timeweb, Reg.ru, Beget, Yandex Cloud…; можно wildcard|" \
        "alpn|TLS-ALPN-01 на 8443 (acme.sh)|прежний способ; CA проверяет порт 443 — нужен проброс 443 → 8443|" \
        "cloudflare|Cloudflare DNS через certbot|прежний способ: certbot + API-токен Cloudflare|" \
        "custom|Свой сертификат|готовые сертификат и ключ (PEM): проверю и поставлю|" || return 1
    VALIDATION_METHOD="$m"
    CERT_NAME="$DOMAIN"; CERT_WILDCARD="no"; CERT_ENV=()
    case "$m" in
        dns)        cert_ask_dns && cert_ask_ca ;;
        http|alpn)  cert_ask_ca ;;
        cloudflare) ui_secret CF_Token "Cloudflare API Token (Zone:DNS:Edit для $DOMAIN)" ;;
        custom)     cert_custom_get ;;
    esac
}

cert_ask_ca() {
    local m
    ui_menu m "Центр сертификации" -d "${CA_SERVER:-letsencrypt}" \
        "letsencrypt|Let's Encrypt|по умолчанию|" \
        "zerossl|ZeroSSL|запасной вариант, если Let's Encrypt упёрся в лимиты|" || return 1
    CA_SERVER="$m"
}

cert_ask_dns() {
    local items=() p id name c base
    for p in "${CERT_DNS_PROVIDERS[@]}"; do
        IFS='|' read -r id name _ <<<"$p"
        items+=("$id|$name|плагин acme.sh $id|")
    done
    items+=("other|Другой провайдер|любой DNS-плагин acme.sh: имя и переменные вручную|")
    ui_menu c "DNS-провайдер, где обслуживается домен" -d "${CERT_DNS:-dns_cf}" "${items[@]}" || return 1
    if [ "$c" = "other" ]; then
        cert_ask_dns_other || return 1
    else
        CERT_DNS="$c"
        cert_ask_dns_fields "$c" || return 1
    fi
    echo
    while true; do
        if ! ui_confirm "Wildcard-сертификат (*.домен) — один на все поддомены?" n; then
            ui_back && return 1
            break
        fi
        base="${DOMAIN#*.}"
        ui_input base "Основной домен" "$base" valid_domain "сертификат будет на него и на *.$base" || return 1
        if [ "$DOMAIN" = "$base" ] || [ "${DOMAIN#*.}" = "$base" ]; then
            CERT_WILDCARD="yes"; CERT_NAME="$base"
            break
        fi
        err "$DOMAIN не входит в *.$base (wildcard покрывает только один уровень)"
    done
    return 0
}

cert_ask_dns_fields() {
    local spec="" p f var lab flag val parts=() acct="$HOME/.acme.sh/account.conf" saved=1
    for p in "${CERT_DNS_PROVIDERS[@]}"; do [ "${p%%|*}" = "$1" ] && spec="$p"; done
    IFS='|' read -r -a parts <<<"$spec"
    for f in "${parts[@]:2}"; do
        [[ "$f" == *=* && "$f" != *:* ]] && continue
        var="${f%%:*}"; [[ "$var" == *\? ]] && continue
        grep -q "^SAVED_${var%\*}=" "$acct" 2>/dev/null || saved=0
    done
    if [ "$saved" -eq 1 ]; then
        if ui_confirm "Ключи $(cert_dns_name "$1") уже сохранены в acme.sh — использовать их?" y; then return 0; fi
        ui_back && return 1
    fi
    note "Ключи сохранит acme.sh (~/.acme.sh/account.conf, доступ только у root): они нужны для продления."
    for f in "${parts[@]:2}"; do
        if [[ "$f" =~ ^([A-Za-z0-9_]+)=([^:]*)$ ]]; then CERT_ENV+=("$f"); continue; fi
        var="${f%%:*}"; lab="${f#*:}"; flag=""
        case "$var" in
            *\*) flag=secret; var="${var%\*}" ;;
            *\?) flag=opt; var="${var%\?}" ;;
        esac
        val=""
        case "$flag" in
            secret) ui_secret val "$lab" valid_cred || return 1 ;;
            opt)    ui_input val "$lab" "" valid_cred_opt "Enter — пропустить" || return 1 ;;
            *)      ui_input val "$lab" "" valid_cred || return 1 ;;
        esac
        [ -n "$val" ] && CERT_ENV+=("$var=$val")
    done
    return 0
}

cert_ask_dns_other() {
    local p="${CERT_DNS:-}" kv
    note "Плагины и их переменные: github.com/acmesh-official/acme.sh/wiki/dnsapi"
    ui_input p "Имя плагина" "$p" valid_dns_plugin "например dns_hetznercloud, dns_dgon, dns_aws" || return 1
    CERT_DNS="$p"
    note "Переменные плагина по одной: ИМЯ=значение. Пустой Enter — готово."
    while true; do
        kv=""
        ui_input kv "Переменная ($(( ${#CERT_ENV[@]} + 1 )))" "" valid_env_kv "например HETZNER_TOKEN=abc123" || return 1
        [ -z "$kv" ] && break
        CERT_ENV+=("$kv")
    done
    [ "${#CERT_ENV[@]}" -gt 0 ] || warn "Переменные не заданы — acme.sh возьмёт сохранённые раньше, если они есть."
    return 0
}

_cert_acme_issue() {
    local name="$1" force="$2" kv args
    for kv in "${CERT_ENV[@]}"; do export "${kv?}"; done
    args=(--issue -d "$name" --server "${CA_SERVER:-letsencrypt}")
    [ "${CERT_WILDCARD:-no}" = "yes" ] && args+=(-d "*.$name")
    if [ "$VALIDATION_METHOD" = "dns" ]; then
        args+=(--dns "$CERT_DNS")
    else
        args+=(--webroot "$ACME_WEBROOT" --pre-hook "$CERT_BIN http-begin" --post-hook "$CERT_BIN http-end")
    fi
    [ "$force" = "1" ] && args+=(--force)
    "$ACME_SH" "${args[@]}"
    local rc=$?
    [ "$rc" -eq 2 ] && { echo "сертификат ещё свежий — новый не нужен"; rc=0; }
    return "$rc"
}

_cert_acme_install() {
    local name="$1"
    # shellcheck disable=SC2046
    "$ACME_SH" --install-cert -d "$name" $(_acme_ecc_flag "$name") \
        --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" --reloadcmd "$CERT_BIN deploy" || return 1
    chmod 600 "$CERT_KEY"
    [ -s "$CERT_PEM" ]
}

cert_issue_acme() {
    local name="${CERT_NAME:-$DOMAIN}" want saved force=0
    if [ "$VALIDATION_METHOD" = "dns" ]; then want="$CERT_DNS"; else want="$ACME_WEBROOT"; fi
    saved=$(_acme_conf_get "$name" Le_Webroot)
    [ -n "$saved" ] && [ "$saved" != "$want" ] && force=1
    mkdir -p "$NGINX_DIR"
    cert_write_helper
    if [ "$VALIDATION_METHOD" = "http" ]; then
        mkdir -p "$ACME_WEBROOT"
        if [ -f "$NGINX_DIR/nginx.conf" ] && ! grep -q acme-challenge "$NGINX_DIR/nginx.conf" \
           && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NGINX_NAME"; then
            info "Останавливаю старый nginx: он займёт порт 80 снова после установки"
            docker stop "$NGINX_NAME" >>"$LOG_FILE" 2>&1 || true
        fi
        if has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
            ufw allow 80/tcp >>"$LOG_FILE" 2>&1 || true
        fi
    fi
    pb_init 10
    if ! stepf_try 8 "Выпуск сертификата для $name" _cert_acme_issue "$name" "$force"; then
        if [ "$VALIDATION_METHOD" = "dns" ]; then
            note "Проверь ключи/токен и их права на зону $name. Подробности: $LOG_FILE"
        else
            note "A-запись $DOMAIN должна вести на этот сервер, порт 80 — быть открыт снаружи"
            note "(ufw и фаервол хостера), а сам порт — не занят чужим веб-сервером."
        fi
        return 1
    fi
    stepf_try 2 "Установка сертификата в $NGINX_DIR" _cert_acme_install "$name" || return 1
    _acme_has_cron || "$ACME_SH" --install-cronjob >>"$LOG_FILE" 2>&1 || true
    CERT_SOURCE="acme_$VALIDATION_METHOD"
    return 0
}

cert_forget_prev() {
    local pm="${CERT_PREV%%|*}" pn="${CERT_PREV#*|}"
    [ -n "$CERT_PREV" ] || return 0
    CERT_PREV=""
    case "$pm" in
        cloudflare)
            [ "$VALIDATION_METHOD" != "cloudflare" ] && [ -f "$DEPLOY_HOOK" ] && {
                rm -f "$DEPLOY_HOOK"; note "certbot больше не копирует свой сертификат в nginx (deploy-hook убран)"; } ;;
        dns|http|alpn)
            case "$VALIDATION_METHOD" in
                dns|http|alpn) [ "$pn" = "${CERT_NAME:-$DOMAIN}" ] && return 0 ;;
            esac
            if [ -n "$pn" ] && [ -x "$ACME_SH" ] && [ -n "$(_acme_dir "$pn")" ]; then
                # shellcheck disable=SC2046
                "$ACME_SH" --remove -d "$pn" $(_acme_ecc_flag "$pn") >>"$LOG_FILE" 2>&1 || true
                note "acme.sh больше не продлевает прежний сертификат $pn"
            fi ;;
    esac
    return 0
}

cert_verify() {
    local crt="$1" key="$2" dom="$3" names d
    [ -s "$crt" ] || { err "Нет файла $crt"; return 1; }
    [ -s "$key" ] || { err "Нет файла $key"; return 1; }
    openssl x509 -in "$crt" -noout 2>/dev/null || { err "fullchain.pem — не сертификат в формате PEM"; return 1; }
    openssl pkey -in "$key" -noout -passin pass: </dev/null 2>/dev/null \
        || { err "privkey.pem — не закрытый ключ PEM (или ключ защищён паролем)"; return 1; }
    if [ "$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | sha256sum)" != \
         "$(openssl pkey -in "$key" -pubout -passin pass: </dev/null 2>/dev/null | sha256sum)" ]; then
        err "Ключ не подходит к сертификату (это ключ от другого сертификата)"; return 1
    fi
    names=$(cert_names "$crt")
    if ! cert_covers "$dom" "$names"; then
        err "Сертификат выдан на: $(paste -sd' ' - <<<"$names") — домена $dom в нём нет"; return 1
    fi
    d=$(cert_days_left "$crt")
    [ "${d:--1}" -lt 0 ] && { err "Сертификат уже истёк"; return 1; }
    ok "Сертификат подходит: $(paste -sd' ' - <<<"$names"), до $(cert_end_date "$crt") (ещё $d дн.)"
    [ "$d" -le 30 ] && warn "Осталось меньше 30 дней — скоро понадобится новый"
    if ! openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted "$crt" "$crt" >/dev/null 2>&1; then
        warn "Цепочка не сходится к общепризнанным корневым сертификатам"
        note "(самоподписанный, Cloudflare Origin CA или в fullchain нет промежуточного сертификата)."
        note "Клиенты, которые проверяют сертификат, могут его не принять."
    fi
    return 0
}

_cert_paste() {
    local out="$1" what="$2" line data="" n=0 got=0
    printf '  %s◆%s %s%s%s\n' "$C_ACC" "$C_RST" "$C_B" "$what" "$C_RST"
    printf '    %sвставь текст целиком, от -----BEGIN до -----END  ·  q и Enter — назад%s\n' "$C_DIM" "$C_RST"
    stty -echo <&"$UI_FD" 2>/dev/null
    while true; do
        if [ "$got" -eq 1 ]; then IFS= read -r -t 1 line <&"$UI_FD" || break
        else IFS= read -r line <&"$UI_FD" || break
        fi
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        if [ "$n" -eq 0 ]; then
            [ -z "$line" ] && continue
            if [[ "$line" != -----BEGIN* ]]; then
                stty echo <&"$UI_FD" 2>/dev/null
                printf '    %s← назад%s\n' "$C_DIM" "$C_RST"; UI_LAST=back; return 1
            fi
        fi
        [ -z "$line" ] && continue
        data+="$line"$'\n'; n=$(( n + 1 ))
        [[ "$line" == -----END*----- ]] && got=1
        printf '\r\e[2K    %s❯%s %d строк' "$C_ACC" "$C_RST" "$n"
    done
    stty echo <&"$UI_FD" 2>/dev/null
    printf '\n'
    ( umask 077; printf '%s' "$data" >"$out" )
    UI_LAST=ok
    return 0
}

cert_custom_take() {
    local base="$1" names=() e f; shift
    for e in "$@"; do names+=("$base.$e"); done
    f=$(cd "$CERT_CUSTOM_DIR" 2>/dev/null && ls -t "${names[@]}" 2>/dev/null | head -n1)
    [ -n "$f" ] || return 0
    [ "$f" != "$base.$1" ] && mv -f "$CERT_CUSTOM_DIR/$f" "$CERT_CUSTOM_DIR/$base.$1"
    for e in "${@:2}"; do rm -f "$CERT_CUSTOM_DIR/$base.$e"; done
    return 0
}

cert_custom_files() {
    cert_custom_take fullchain pem crt cer
    cert_custom_take privkey pem key
}

cert_custom_get() {
    local how crt="$CERT_CUSTOM_DIR/fullchain.pem" key="$CERT_CUSTOM_DIR/privkey.pem"
    mkdir -p "$CERT_CUSTOM_DIR"; chmod 700 "$CERT_CUSTOM_DIR"
    ui_menu how "Как передать свой сертификат" \
        "upload|Загрузить файлы на сервер|fullchain и privkey через scp или SFTP|" \
        "paste|Вставить текст в терминал|открыть файлы на компьютере, скопировать и вставить|" || return 1
    if [ "$how" = "paste" ]; then
        while true; do
            _cert_paste "$crt" "Сертификат (fullchain: свой сертификат + промежуточные)" || return 1
            _cert_paste "$key" "Закрытый ключ (privkey)" || return 1
            cert_verify "$crt" "$key" "$DOMAIN" && return 0
            echo
            ui_confirm "Вставить ещё раз?" y || return 1
        done
    fi
    srv_detect_ip4
    echo
    ui_box_top "Куда положить файлы"
    ui_kv "Папка" "$CERT_CUSTOM_DIR/"
    ui_kv "Сертификат" "fullchain.pem  ${C_DIM}или fullchain.crt, fullchain.cer${C_RST}"
    ui_kv "Ключ" "privkey.pem  ${C_DIM}или privkey.key${C_RST}"
    ui_box_bottom
    note "С компьютера, например:"
    note "scp fullchain.pem privkey.key root@${SRV_IP4:-IP_СЕРВЕРА}:$CERT_CUSTOM_DIR/"
    note "Формат — текст PEM от -----BEGIN до -----END, расширение не важно."
    note "В fullchain — сам сертификат и за ним промежуточные; ключ без пароля."
    echo
    while true; do
        ui_confirm "Файлы на месте — проверить?" y || return 1
        cert_custom_files
        cert_verify "$crt" "$key" "$DOMAIN" && return 0
        echo
    done
}

cert_install_custom() {
    cert_custom_files
    [ -s "$CERT_CUSTOM_DIR/fullchain.pem" ] && [ -s "$CERT_CUSTOM_DIR/privkey.pem" ] \
        || { err "Своего сертификата нет в $CERT_CUSTOM_DIR"; return 1; }
    mkdir -p "$NGINX_DIR"
    cat "$CERT_CUSTOM_DIR/fullchain.pem" >"$CERT_PEM"
    ( umask 077; cat "$CERT_CUSTOM_DIR/privkey.pem" >"$CERT_KEY" )
    chmod 600 "$CERT_KEY" "$CERT_CUSTOM_DIR/privkey.pem"
    CERT_SOURCE="custom"
    cert_write_helper
    return 0
}

cert_renew_label() {
    local name="${CERT_NAME:-${DOMAIN:-}}" nx
    case "${VALIDATION_METHOD:-}" in
        dns|http|alpn)
            if ! _acme_has_cron; then ui_badge_err "cron acme.sh не найден"; return 0; fi
            nx=$(_acme_conf_get "$name" Le_NextRenewTimeStr)
            [ -n "$nx" ] && nx=$(date -d "$nx" +%d.%m.%Y 2>/dev/null)
            printf '%s  %s%s%s' "$(ui_badge_ok "acme.sh, cron")" "$C_DIM" "${nx:+следующее $nx}" "$C_RST" ;;
        cloudflare)
            if systemctl is-active --quiet certbot.timer 2>/dev/null || crontab -l 2>/dev/null | grep -q 'certbot renew'; then
                printf '%s' "$(ui_badge_ok "certbot")"
            else
                ui_badge_err "таймер certbot не найден"
            fi
            [ -f "$DEPLOY_HOOK" ] || printf '  %s' "$(ui_badge_warn "нет deploy-hook")" ;;
        custom) ui_badge_off "нет — свой сертификат, замена вручную" ;;
        *)      ui_badge_off "неизвестно" ;;
    esac
}

cert_status_box() {
    local d
    cert_tg_load
    ui_box_top "SSL-сертификат"
    if [ -s "$CERT_PEM" ]; then
        d=$(cert_days_left "$CERT_PEM")
        ui_kv "Домены" "${C_B}$(cert_names "$CERT_PEM" | paste -sd' ' -)${C_RST}"
        ui_kv "Выдан" "$(cert_issuer "$CERT_PEM")"
        if [ "${d:--1}" -lt 0 ]; then ui_kv "Действует до" "$(ui_badge_err "истёк")  ${C_DIM}$(cert_end_date "$CERT_PEM")${C_RST}"
        elif [ "$d" -lt 14 ]; then ui_kv "Действует до" "$(cert_end_date "$CERT_PEM")  $(ui_badge_warn "ещё $d дн.")"
        else ui_kv "Действует до" "$(cert_end_date "$CERT_PEM")  $(ui_badge_ok "ещё $d дн.")"
        fi
    else
        ui_kv "Сертификат" "$(ui_badge_off "нет")  ${C_DIM}$CERT_PEM${C_RST}"
    fi
    ui_kv "Способ" "$(cert_method_label)"
    ui_kv "Продление" "$(cert_renew_label)"
    if [ -n "$TG_TOKEN" ]; then
        ui_kv "Telegram" "$(ui_badge_ok "вкл")  ${C_DIM}чат $TG_CHAT, за ${TG_DAYS:-14} дн. до конца${C_RST}"
    else
        ui_kv "Telegram" "$(ui_badge_off "выкл")"
    fi
    ui_box_bottom
}

cert_reissue() {
    [ -n "${DOMAIN:-}" ] || { err "Домен не задан — сначала «Установить Remnanode»"; return 0; }
    ui_screen "SSL-сертификат: выпуск"
    info "Домен: ${C_B}$DOMAIN${C_RST}  ${C_DIM}сейчас: $(cert_method_label)${C_RST}"
    echo
    cert_ask_method || { cfg_revert; return 0; }
    echo
    ui_confirm "Выпустить сертификат: $(cert_method_label)?" y || { cfg_revert; return 0; }
    resolve_layout
    case "$VALIDATION_METHOD" in
        custom|cloudflare) ;;
        *) [ -f "$ACME_SH" ] || setup_acme ;;
    esac
    if [ "$VALIDATION_METHOD" = "http" ] && [ -f "$NGINX_DIR/nginx.conf" ] \
       && ! grep -q 'acme-challenge' "$NGINX_DIR/nginx.conf"; then
        info "Добавляю в nginx отдачу проверочных файлов HTTP-01"
        write_nginx
    fi
    case "$VALIDATION_METHOD" in
        dns|http) cert_issue_acme || { cfg_revert; return 0; } ;;
        custom)   cert_install_custom || { cfg_revert; return 0; }
                  "$CERT_BIN" deploy >>"$LOG_FILE" 2>&1 ;;
        *)
            if ! ( CERT_REISSUE=1; issue_certificate ); then cfg_revert; return 0; fi
            if [ "$VALIDATION_METHOD" = "cloudflare" ]; then CERT_SOURCE="letsencrypt_live"; else CERT_SOURCE="acme_new"; fi ;;
    esac
    cert_forget_prev
    cfg_save
    setup_renewal
    [ "$VALIDATION_METHOD" = "cloudflare" ] && "$CERT_BIN" deploy >>"$LOG_FILE" 2>&1
    ok "Сертификат установлен, nginx и нода перезапущены"
}

cert_renew_now() {
    local name="${CERT_NAME:-${DOMAIN:-}}"
    case "${VALIDATION_METHOD:-}" in
        custom) info "Свой сертификат сам не продлевается: замените его пунктом «Свой сертификат»."; return 0 ;;
        "")     err "Способ выпуска неизвестен — выпусти сертификат пунктом «Сменить способ»"; return 0 ;;
    esac
    note "Let's Encrypt выдаёт не больше 5 одинаковых сертификатов в неделю."
    ui_confirm "Продлить сертификат $name сейчас?" y || return 0
    pb_init 10
    if [ "$VALIDATION_METHOD" = "cloudflare" ]; then
        stepf_try 10 "certbot: продление $DOMAIN" certbot renew --force-renewal --cert-name "$DOMAIN" || return 0
    else
        # shellcheck disable=SC2046
        stepf_try 10 "acme.sh: продление $name" "$ACME_SH" --renew -d "$name" --force $(_acme_ecc_flag "$name") || return 0
    fi
    ok "Готово: действует до $(cert_end_date "$CERT_PEM")"
}

cert_check_renewal() {
    local name="${CERT_NAME:-${DOMAIN:-}}" r who
    ui_screen "Проверка автопродления"
    cert_status_box
    echo
    case "${VALIDATION_METHOD:-}" in
        dns|http|alpn)
            if _acme_has_cron; then ok "Cron acme.sh на месте: $(crontab -l | grep 'acme.sh --cron' | awk '{print $1, $2, $3, $4, $5}')"
            else
                warn "Cron acme.sh не найден — ставлю"
                "$ACME_SH" --install-cronjob >>"$LOG_FILE" 2>&1 && ok "Cron восстановлен"
            fi
            if [ -z "$(_acme_dir "$name")" ]; then err "У acme.sh нет сертификата $name — выпусти его заново"; return 0; fi
            r=$(_acme_conf_get "$name" Le_Webroot)
            case "$r" in
                dns_*) ok "acme.sh продлевает через DNS: $(cert_dns_name "$r")" ;;
                no)    ok "acme.sh продлевает через TLS-ALPN (standalone)" ;;
                /*)    ok "acme.sh продлевает через HTTP-01, webroot $r" ;;
                *)     warn "Способ продления у acme.sh: ${r:-не записан}" ;;
            esac
            [ -n "$(_acme_conf_get "$name" Le_ReloadCmd)" ] || warn "После продления nginx не перезапустится (нет reloadcmd) — выпусти заново"
            if [ "$VALIDATION_METHOD" = "http" ]; then
                [ -x "$CERT_BIN" ] || cert_write_helper
                r=$("$CERT_BIN" http-probe 2>/dev/null)
                case "$r" in
                    ok)     ok "Порт 80: nginx отдаёт проверочные файлы — продление пройдёт без остановок" ;;
                    free)   ok "Порт 80 свободен — на время продления поднимется временный nginx" ;;
                    busy*)  who="${r#busy }"; err "Порт 80 занят ($who) и проверочные файлы не отдаются"
                            note "Освободи порт или переключись на DNS API." ;;
                esac
            fi ;;
        cloudflare)
            [ -f "$DEPLOY_HOOK" ] && ok "Deploy-hook certbot: $DEPLOY_HOOK" || warn "Нет deploy-hook: продлённый сертификат не попадёт в nginx"
            if ui_confirm "Пробный прогон certbot (--dry-run, сертификат не меняется)?" y; then
                pb_init 10
                stepf_try 10 "certbot renew --dry-run" certbot renew --dry-run --cert-name "$DOMAIN" && ok "Пробное продление прошло"
            fi ;;
        custom) info "Свой сертификат не продлевается сам. Напоминание о сроке — «Уведомления в Telegram»." ;;
        *) warn "Способ выпуска неизвестен" ;;
    esac
    return 0
}

cert_notify_menu() {
    local c chat
    cert_tg_load
    ui_screen "Уведомления в Telegram"
    note "Раз в сутки помощник проверяет срок. Если до конца осталось N дней или меньше —"
    note "пишет в Telegram. После каждого продления тоже приходит сообщение."
    echo
    ui_menu c "Уведомления $([ -n "$TG_TOKEN" ] && ui_badge_ok вкл || ui_badge_off выкл)" \
        "set|Настроить|бот, чат, за сколько дней напоминать|" \
        "test|Отправить тестовое сообщение||" \
        "off|Выключить||" || return 0
    case "$c" in
        set)
            ui_secret TG_TOKEN "Токен бота (выдаёт @BotFather)" valid_tg_token || return 0
            chat="${TG_CHAT}${TG_THREAD:+:$TG_THREAD}"
            ui_input chat "ID чата" "$chat" valid_tg_chat "ваш ID (@userinfobot), группа -100…, тема — через двоеточие: -100…:42" || return 0
            TG_CHAT="${chat%%:*}"; TG_THREAD=""; [[ "$chat" == *:* ]] && TG_THREAD="${chat#*:}"
            ui_input TG_PROXY "Прокси для api.telegram.org" "${TG_PROXY:-}" valid_proxy_opt "если Telegram заблокирован: socks5h://user:pass@host:1080 · Enter — без прокси" || return 0
            TG_DAYS="${TG_DAYS:-14}"
            ui_input TG_DAYS "За сколько дней до конца напоминать" "$TG_DAYS" valid_days || return 0
            cert_write_helper
            if cert_notify_test; then cert_timer_set on; ok "Уведомления включены"
            else warn "Настройки сохранены, но уведомления не включены: исправь и выбери «Отправить тестовое»"
            fi ;;
        test) [ -n "$TG_TOKEN" ] || { warn "Сначала «Настроить»"; return 0; }
              cert_write_helper
              cert_notify_test && cert_timer_set on ;;
        off)  TG_TOKEN=""; TG_CHAT=""; TG_THREAD=""; TG_PROXY=""
              cert_write_helper; cert_timer_set off; ok "Уведомления выключены" ;;
    esac
}

cert_notify_test() {
    local r d
    info "Отправляю тестовое сообщение…"
    r=$("$CERT_BIN" test 2>&1)
    if grep -q '"ok":true' <<<"$r"; then ok "Сообщение доставлено"; return 0; fi
    d=$(sed -n 's/.*"description":"\([^"]*\)".*/\1/p' <<<"$r" | head -n1)
    err "Telegram не принял сообщение: ${d:-$(ui_cut "${r:-нет ответа}" $(( UI_W - 40 )))}"
    note "Проверь токен и ID чата; боту нужно сначала написать /start. Если api.telegram.org недоступен — укажи прокси."
    return 1
}

action_cert_menu() {
    local c
    while true; do
        ui_screen "SSL-сертификат"
        cert_status_box
        echo
        ui_menu c "SSL-сертификат" -d renew \
            "renew|Продлить сейчас|выпустить заново тем же способом и перезапустить nginx и ноду|" \
            "issue|Сменить способ / выпустить новый|HTTP-01, DNS API, TLS-ALPN, Cloudflare (certbot), свой|" \
            "custom|Свой сертификат|загрузить или вставить сертификат и ключ, проверка и установка|" \
            "check|Проверить автопродление|cron и способ у acme.sh, порт 80, пробный прогон certbot|" \
            "notify|Уведомления в Telegram|напоминание до конца срока и сообщение о продлении|" || return 0
        case "$c" in
            renew)  cert_renew_now ;;
            issue)  cert_reissue ;;
            custom) cert_custom_action ;;
            check)  cert_check_renewal ;;
            notify) cert_notify_menu ;;
        esac
        ui_done
    done
}

cert_custom_action() {
    [ -n "${DOMAIN:-}" ] || { err "Домен не задан — сначала «Установить Remnanode»"; return 0; }
    ui_screen "Свой сертификат"
    info "Домен: ${C_B}$DOMAIN${C_RST}"
    CERT_PREV="${VALIDATION_METHOD:-}|${CERT_NAME:-$DOMAIN}"
    cert_custom_get || { cfg_revert; return 0; }
    ui_confirm "Поставить этот сертификат вместо текущего?" y || { cfg_revert; return 0; }
    VALIDATION_METHOD="custom"; CERT_NAME="$DOMAIN"; CERT_WILDCARD="no"
    cert_install_custom || return 0
    "$CERT_BIN" deploy >>"$LOG_FILE" 2>&1
    cert_forget_prev
    cfg_save
    ok "Свой сертификат установлен, nginx и нода перезапущены"
    [ -n "$TG_TOKEN" ] || note "Чтобы не пропустить конец срока, включи «Уведомления в Telegram»."
}
