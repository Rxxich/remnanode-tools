# shellcheck shell=bash

SRV_IP4=""; SRV_IP4_DONE=0
INFO_CORE_BIN=""; INFO_CORE_UPDATE=""; INFO_NODE=""

srv_detect_ip4() {
    [ "$SRV_IP4_DONE" -eq 1 ] && return 0
    SRV_IP4_DONE=1
    local u ip=""
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip=$(curl -4 -fsS --max-time 3 "$u" 2>/dev/null | tr -d '[:space:]' || true)
        valid_ipv4 "$ip" && break
        ip=""
    done
    [ -z "$ip" ] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
    SRV_IP4="$ip"
}

srv_ip6() { ip -6 addr show scope global 2>/dev/null | awk '/inet6/{sub(/\/.*/,"",$2); print $2; exit}'; }

srv_domain() {
    local d="${DOMAIN:-}" f
    if [ -z "$d" ] && [ -f "$CERT_PEM" ] && has openssl; then
        d=$(openssl x509 -in "$CERT_PEM" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')
    fi
    if [ -z "$d" ] && [ -d /etc/letsencrypt/live ]; then
        for f in /etc/letsencrypt/live/*/; do [ -f "${f}fullchain.pem" ] && { d=$(basename "$f"); break; }; done
    fi
    echo "$d"
}

srv_cert_file() {
    if [ -f "$CERT_PEM" ]; then echo "$CERT_PEM"
    elif [ -n "$1" ] && [ -f "/etc/letsencrypt/live/$1/fullchain.pem" ]; then echo "/etc/letsencrypt/live/$1/fullchain.pem"
    fi
}

human_since() {
    local s now d
    s=$(date -d "$1" +%s 2>/dev/null) || return 0
    now=$(date +%s); d=$(( now - s )); [ "$d" -lt 0 ] && d=0
    if   [ "$d" -ge 86400 ]; then echo "$(( d / 86400 ))д $(( d % 86400 / 3600 ))ч"
    elif [ "$d" -ge 3600 ];  then echo "$(( d / 3600 ))ч $(( d % 3600 / 60 ))м"
    else echo "$(( d / 60 ))м"
    fi
}

show_server_info() {
    srv_detect_ip4
    local up mem disk ip6 load
    up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    [ -n "$up" ] && up=$(human_since "@$(( $(date +%s) - up ))")
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d/%d МБ", $3, $2}')
    disk=$(df -Ph / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')
    load=$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null)
    ip6=$(srv_ip6)

    ui_box_top "Сервер  ${C_DIM}$(hostname 2>/dev/null)${C_RST}"
    ui_kv "IPv4" "${C_B}${SRV_IP4:-не определён}${C_RST}${ip6:+   ${C_DIM}IPv6${C_RST} $ip6}"
    ui_kv "ОС" "${OS_PRETTY:-?}  ${C_DIM}$(uname -r)${C_RST}"
    ui_kv "Ресурсы" "RAM $mem  ${C_DIM}диск${C_RST} $disk"
    ui_kv "Нагрузка" "$load  ${C_DIM}аптайм${C_RST} ${up:-?}"

    local dom cert end days a dns
    dom=$(srv_domain)
    if [ -n "$dom" ]; then
        a=$(getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)
        if [ -z "$a" ]; then dns="${C_WARN}нет A-записи${C_RST}"
        elif [ -n "$SRV_IP4" ] && [[ ",$a," == *",$SRV_IP4,"* ]]; then dns="${C_OK}→ этот сервер${C_RST}"
        else dns="${C_WARN}→ $a${C_RST}"
        fi
        ui_kv "Домен" "${C_B}$dom${C_RST}  $dns"
        cert=$(srv_cert_file "$dom")
        if [ -n "$cert" ] && has openssl; then
            end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
            if [ -n "$end" ]; then
                days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
                if   [ "$days" -lt 0 ];  then ui_kv "Сертификат" "$(ui_badge_err "истёк $(( -days )) дн. назад")"
                elif [ "$days" -lt 14 ]; then ui_kv "Сертификат" "$(ui_badge_warn "ещё $days дн.")"
                else ui_kv "Сертификат" "$(ui_badge_ok "ещё $days дн.")  ${C_DIM}до $(date -d "$end" +%d.%m.%Y)${C_RST}"
                fi
            fi
        fi
    fi

    ui_box_sep "нода"
    INFO_CORE_BIN=""; INFO_CORE_UPDATE=""
    local cn st img started state
    cn=$(find_node_container); INFO_NODE="$cn"
    if [ -z "$cn" ]; then
        ui_kv "Статус" "$(ui_badge_off "не установлена")"
    else
        st=$(docker inspect -f '{{.State.Status}}|{{.Config.Image}}|{{.State.StartedAt}}' "$cn" 2>/dev/null)
        IFS='|' read -r state img started <<<"$st"
        if [ "$state" = "running" ]; then
            ui_kv "Статус" "$(ui_badge_ok "работает") $(human_since "$started")  ${C_DIM}$cn · $img${C_RST}"
        else
            ui_kv "Статус" "$(ui_badge_err "${state:-неизвестно}")  ${C_DIM}$cn${C_RST}"
        fi
        local ver bin label
        bin=$(find_core_bin); INFO_CORE_BIN="$bin"
        [ "$state" = "running" ] && ver=$(container_core_version "$cn")
        [ -z "$ver" ] && [ -n "$bin" ] && ver=$(core_version_of "$bin")
        if [ -n "$bin" ]; then
            if [ "$CORE_LATEST_DONE" -eq 0 ]; then CORE_LATEST_DONE=1; CORE_LATEST_TAG=$(fetch_core_latest_tag 5); fi
            label="${C_B}${ver:-?}${C_RST} ${C_ACC2}Jolymmiles${C_RST}"
            if [ -z "$CORE_LATEST_TAG" ]; then label+="  ${C_DIM}(обновления не проверены)${C_RST}"
            elif [ -n "$ver" ] && [ "${CORE_LATEST_TAG#v}" != "$ver" ]; then
                INFO_CORE_UPDATE="$CORE_LATEST_TAG"; label+="  ${C_WARN}↑ есть $CORE_LATEST_TAG${C_RST}"
            else label+="  ${C_OK}✓ последняя${C_RST}"
            fi
        else
            label="${C_B}${ver:-?}${C_RST}  ${C_DIM}штатное из образа${C_RST}"
        fi
        ui_kv "Ядро Xray" "$label"
        if [ "$state" = "running" ]; then
            local inb
            inb=$(docker logs --tail 500 "$cn" 2>&1 | tr -d '\000' | sed 's/\x1b\[[0-9;]*m//g' | awk -F' · ' '
                /Starting user extraction/ { n = 0 }
                / users · / { t = $1; sub(/.*▸ /, "", t); split($2, u, " "); n++; a[n] = t " (" u[1] ")" }
                END { for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? ", " : ""), a[i] }')
            [ -n "$inb" ] && ui_kv "Инбаунды" "$(ui_cut "$inb" $(( UI_W - 22 )))"
        fi
    fi

    ui_box_sep "система"
    local fw opt prot
    if has ufw && ufw status 2>/dev/null | grep -q "Status: active"; then fw=$(ui_badge_ok "ufw"); else fw=$(ui_badge_off "ufw"); fi
    if [ -f "$OPT_SYSCTL" ]; then opt=$(ui_badge_ok "оптимизация"); else opt=$(ui_badge_off "оптимизация"); fi
    if guard_active; then prot=$(ui_badge_ok "защита"); else prot=$(ui_badge_off "защита"); fi
    local cs=""
    has cscli && { systemctl is-active --quiet crowdsec && cs="  $(ui_badge_ok CrowdSec)" || cs="  $(ui_badge_warn CrowdSec)"; }
    ui_kv "Состояние" "$fw  $opt  $prot$cs"
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    ui_kv "TCP" "$cc$(uname -r | grep -qi xanmod && echo "  ${C_ACC2}XanMod${C_RST}")"
    ui_box_bottom
    show_stealth_panel
    return 0
}
