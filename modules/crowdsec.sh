# shellcheck shell=bash

CROWDSEC_FP="6A89E3C2303A901A889971D3376ED5326E93CD0C"
CS_LIST="/etc/apt/sources.list.d/crowdsec.list"
CS_KEYRING="/etc/apt/keyrings/crowdsec-archive-keyring.gpg"
CS_BOUNCER_YAML="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
CS_SCOPE_NFT="$CONF_DIR/crowdsec-scope.nft"
CS_SCOPE_UNIT="/etc/systemd/system/$KIT_NAME-crowdsec-scope.service"
CS_ACQ_SSH="/etc/crowdsec/acquis.d/$KIT_NAME-sshd.yaml"
CS_WL="/etc/crowdsec/parsers/s02-enrich/$KIT_NAME-whitelist.yaml"

cs_repo() {
    local tmp cand path suite ok=0
    mkdir -p /etc/apt/keyrings
    tmp=$(mktemp)
    curl -fsSL --proto '=https' --max-time 20 https://packagecloud.io/crowdsec/crowdsec/gpgkey -o "$tmp" \
        || { rm -f "$tmp"; echo "ключ CrowdSec недоступен"; return 1; }
    import_pinned_key "$tmp" "$CROWDSEC_FP" "$CS_KEYRING" || { rm -f "$tmp"; echo "ключ CrowdSec не совпал с отпечатком"; return 1; }
    rm -f "$tmp"
    local -a only=(-o "Dir::Etc::sourcelist=$CS_LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
    for cand in "any any" "$OS_ID $OS_CODENAME"; do
        path="${cand% *}"; suite="${cand#* }"
        echo "deb [signed-by=$CS_KEYRING] https://packagecloud.io/crowdsec/crowdsec/$path $suite main" >"$CS_LIST"
        if apt-get "${APT_OPTS[@]}" update "${only[@]}"; then ok=1; break; fi
    done
    [ "$ok" -eq 1 ] || { rm -f "$CS_LIST"; return 1; }
    apt_update || true
}

cs_install_pkgs() {
    apt_install crowdsec || return 1
    apt_install crowdsec-firewall-bouncer-nftables || return 1
    cscli hub update || true
    cscli collections install crowdsecurity/linux crowdsecurity/sshd || true
    if [ ! -s /var/log/auth.log ]; then
        mkdir -p /etc/crowdsec/acquis.d
        cat >"$CS_ACQ_SSH" <<'EOF'
source: journalctl
journalctl_filter:
  - "_SYSTEMD_UNIT=ssh.service"
labels:
  type: syslog
EOF
    fi
    return 0
}

cs_write_whitelist() {
    local ips=() e
    for e in ${GUARD_WHITELIST//,/ } ${PANEL_IP//,/ } $(ssh_client_ip); do
        valid_ip_or_cidr "$e" && ips+=("$e")
    done
    [ "${#ips[@]}" -eq 0 ] && { rm -f "$CS_WL"; return 0; }
    mkdir -p "$(dirname "$CS_WL")"
    {
        echo "name: local/$KIT_NAME-whitelist"
        echo "description: \"Адреса панели и администратора\""
        echo "whitelist:"
        echo "  reason: \"$KIT_NAME allowlist\""
        local ip=() cidr=()
        for e in $(printf '%s\n' "${ips[@]}" | sort -u); do
            if [[ "$e" == */* ]]; then cidr+=("$e"); else ip+=("$e"); fi
        done
        if [ "${#ip[@]}" -gt 0 ]; then echo "  ip:"; printf '    - "%s"\n' "${ip[@]}"; fi
        if [ "${#cidr[@]}" -gt 0 ]; then echo "  cidr:"; printf '    - "%s"\n' "${cidr[@]}"; fi
    } >"$CS_WL"
}

cs_yaml_get() {
    if [ $# -eq 1 ]; then
        awk -F': *' -v k="$1" '$1==k{gsub(/["[:space:]]/,"",$2); print $2; exit}' "$CS_BOUNCER_YAML" 2>/dev/null
    else
        awk -v fam="$1" -v k="$2" '
            /^nftables:/ {n=1; next}
            n && /^[^[:space:]]/ {n=0}
            n && $1==fam":" {f=1; next}
            n && f && $1 ~ /^ipv[46]:$/ {f=0}
            n && f && $1==k":" {v=$2; gsub(/"/,"",v); print v; exit}' "$CS_BOUNCER_YAML" 2>/dev/null
    fi
}

cs_scope_current() {
    if grep -qE '^[[:space:]]+set-only:[[:space:]]*true' "$CS_BOUNCER_YAML" 2>/dev/null; then echo "только SSH"; else echo "все порты"; fi
}

cs_bouncer_up() {
    local n=0
    until systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null; do
        n=$(( n + 1 )); [ "$n" -gt 10 ] && return 1
        sleep 1
    done
    [ -z "${1:-}" ] || nft list set ip "$1" "$2" >/dev/null 2>&1
}

cs_scope_all() {
    local t4 t6
    t4=$(cs_yaml_get ipv4 table); t6=$(cs_yaml_get ipv6 table)
    systemctl stop crowdsec-firewall-bouncer >/dev/null 2>&1 || true
    sed -i -E 's/^([[:space:]]+set-only:)[[:space:]]*true[[:space:]]*$/\1 false/' "$CS_BOUNCER_YAML"
    systemctl disable "$KIT_NAME-crowdsec-scope.service" >/dev/null 2>&1 || true
    rm -f "$CS_SCOPE_UNIT" "$CS_SCOPE_NFT"
    systemctl daemon-reload
    nft delete table ip "${t4:-crowdsec}" 2>/dev/null || true
    nft delete table ip6 "${t6:-crowdsec6}" 2>/dev/null || true
    systemctl start crowdsec-firewall-bouncer >/dev/null 2>&1 || true
    cs_bouncer_up
}

cs_scope_ssh() {
    grep -qE '^[[:space:]]+set-only:' "$CS_BOUNCER_YAML" 2>/dev/null || { echo "bouncer без set-only (старая версия)"; return 1; }
    local t4 t6 s4 s6 sshp wl4="" wl6="" e
    t4=$(cs_yaml_get ipv4 table); t6=$(cs_yaml_get ipv6 table)
    s4=$(cs_yaml_get blacklists_ipv4); s6=$(cs_yaml_get blacklists_ipv6)
    t4=${t4:-crowdsec}; t6=${t6:-crowdsec6}; s4=${s4:-crowdsec-blacklists}; s6=${s6:-crowdsec6-blacklists}
    sshp=$(nft_list "$(ssh_ports)")
    for e in $(cat "$GUARD_ALLOW" 2>/dev/null) ${GUARD_WHITELIST//,/ } ${PANEL_IP//,/ }; do
        if valid_ipv4 "${e%%/*}"; then wl4="${wl4:+$wl4, }$e"; elif valid_ipv6 "${e%%/*}"; then wl6="${wl6:+$wl6, }$e"; fi
    done
    local el4="" el6=""
    [ -n "$wl4" ] && el4="elements = { $wl4 }"
    [ -n "$wl6" ] && el6="elements = { $wl6 }"
    cat >"$CS_SCOPE_NFT.new" <<EOF
#!/usr/sbin/nft -f
table ip $t4 {}
delete table ip $t4
table ip $t4 {
    set $s4 { type ipv4_addr; flags timeout; }
    set rnt_wl { type ipv4_addr; flags interval; auto-merge; $el4 }
    chain rnt-scope {
        type filter hook input priority -10; policy accept;
        ip saddr @rnt_wl return
        tcp dport { $sshp } ip saddr @$s4 counter drop
    }
}
table ip6 $t6 {}
delete table ip6 $t6
table ip6 $t6 {
    set $s6 { type ipv6_addr; flags timeout; }
    set rnt_wl { type ipv6_addr; flags interval; auto-merge; $el6 }
    chain rnt-scope {
        type filter hook input priority -10; policy accept;
        ip6 saddr @rnt_wl return
        tcp dport { $sshp } ip6 saddr @$s6 counter drop
    }
}
EOF
    nft -c -f "$CS_SCOPE_NFT.new" || { rm -f "$CS_SCOPE_NFT.new"; return 1; }
    systemctl stop crowdsec-firewall-bouncer >/dev/null 2>&1 || true
    mv -f "$CS_SCOPE_NFT.new" "$CS_SCOPE_NFT"
    sed -i -E 's/^([[:space:]]+set-only:)[[:space:]]*false[[:space:]]*$/\1 true/' "$CS_BOUNCER_YAML"
    cat >"$CS_SCOPE_UNIT" <<EOF
[Unit]
Description=$KIT_NAME: CrowdSec только на SSH (таблицы для set-only bouncer)
DefaultDependencies=no
After=local-fs.target nftables.service
Before=crowdsec-firewall-bouncer.service network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $CS_SCOPE_NFT
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$KIT_NAME-crowdsec-scope.service" >/dev/null 2>&1 || true
    nft -f "$CS_SCOPE_NFT"
    systemctl start crowdsec-firewall-bouncer >/dev/null 2>&1 || true
    if ! cs_bouncer_up "$t4" "$s4"; then
        echo "bouncer не поднялся в set-only — возвращаю «все порты»"
        cs_scope_all
        return 1
    fi
    return 0
}

cs_reload() {
    if crowdsec -t >>"$LOG_FILE" 2>&1; then
        systemctl reload crowdsec >/dev/null 2>&1 || systemctl restart crowdsec >/dev/null 2>&1
    else
        echo "crowdsec -t: ошибка конфигурации"; return 1
    fi
}

setup_crowdsec_nginx() {
    has cscli || return 0
    docker inspect "$NGINX_NAME" >/dev/null 2>&1 || return 0
    title "CrowdSec: логи nginx"
    local acq="/etc/crowdsec/acquis.d/nginx-docker.yaml"
    local wl_dir="/etc/crowdsec/parsers/s02-enrich"
    local wl="$wl_dir/local-app-paths-whitelist.yaml"
    if ! cscli collections install crowdsecurity/nginx >>"$LOG_FILE" 2>&1; then
        warn "Не удалось поставить коллекцию crowdsecurity/nginx — пропускаю"; return 0
    fi
    mkdir -p /etc/crowdsec/acquis.d "$wl_dir"
    cat >"$acq" <<EOF
source: docker
container_name:
  - $NGINX_NAME
labels:
  type: nginx
EOF
    rm -f "$wl_dir/local-vpn-paths-whitelist.yaml"
    cat >"$wl" <<EOF
name: local/app-paths-whitelist
description: "Не считать запросы транспортных путей приложения"
whitelist:
  reason: "app transport path"
  expression:
    - evt.Meta.http_path startsWith '${XHTTP_PATH:-/xhttppath/}'
    - evt.Meta.http_path startsWith '${GRPC_PATH:-/grpcpath}'
EOF
    if ! crowdsec -t >>"$LOG_FILE" 2>&1; then
        warn "Конфиг CrowdSec не прошёл проверку — убираю свои файлы"
        rm -f "$acq" "$wl"; return 0
    fi
    systemctl reload crowdsec >/dev/null 2>&1 || systemctl restart crowdsec >/dev/null 2>&1 || true
    ok "CrowdSec читает логи $NGINX_NAME"
    return 0
}

cs_counts() {
    cscli metrics show decisions -o json 2>/dev/null | jq -r '
        [.decisions // {} | .[] | to_entries[] | {o: .key, n: ([.value[]] | add)}] as $d
        | def total(f): [$d[] | select(f) | .n] | add // 0;
        "\(total(.o == "crowdsec" or .o == "cscli")) \(total(.o == "CAPI")) \(total(.o == "lists"))"' 2>/dev/null
}

cs_counts_label() {
    local own capi lists
    read -r own capi lists <<<"$(cs_counts)"
    [ -n "$own" ] || { echo "?"; return 0; }
    printf '%s%s%s своих  %s·  общий список сообщества: %s' "$C_B" "$own" "$C_RST" "$C_DIM" "$capi"
    [ "${lists:-0}" -gt 0 ] && printf '  ·  списки консоли: %s' "$lists"
    printf '%s' "$C_RST"
}

cs_reason() {
    case "${1#*/}" in
        manual*)                  echo "вручную" ;;
        ssh-bf*|ssh-slow-bf*)     echo "перебор пароля SSH" ;;
        ssh-refused-conn)         echo "сканирование SSH" ;;
        ssh-*)                    echo "атака на SSH" ;;
        http-probing)             echo "сканирование сайта" ;;
        http-crawl-non_statics)   echo "агрессивный обход сайта" ;;
        http-bad-user-agent)      echo "сканер (User-Agent)" ;;
        http-*bf*)                echo "перебор пароля на сайте" ;;
        http-sensitive-files|http-backdoors-attempts|http-admin-interface-probing|http-wordpress*)
                                  echo "поиск уязвимых файлов" ;;
        http-path-traversal-probing|http-sqli-probing|http-xss-probing)
                                  echo "попытка взлома сайта" ;;
        *cve*|*CVE*)              echo "эксплойт CVE" ;;
        *)                        ui_cut "${1#*/}" 25 ;;
    esac
}

cs_left() {
    local h=0 m=0
    [[ "$1" =~ ([0-9]+)h ]] && h=${BASH_REMATCH[1]}
    [[ "$1" =~ ([0-9]+)m([0-9]|$) ]] && m=${BASH_REMATCH[1]}
    if [ "$h" -ge 48 ]; then echo "$(( h / 24 )) дн."
    elif [ "$h" -gt 0 ]; then echo "$h ч $m мин"
    elif [ "$m" -gt 0 ]; then echo "$m мин"
    else echo "< 1 мин"
    fi
}

cs_cols() {
    local out="" s
    while [ $# -gt 1 ]; do
        _ui_pad s "$2" "$1"
        [ "$UI_N" -ge "$1" ] && s+=" "
        out+="$s"; shift 2
    done
    out+="$1"
    _ui_cut s "$out" $(( UI_W - 6 ))
    printf '%s' "$s"
}

action_cs_decisions() {
    ui_screen "CrowdSec: решения"
    local rows n ip cn sc left t res c own capi lists
    rows=$(cscli decisions list -o json 2>/dev/null | jq -r '
        .[]? | (.source.cn // "") as $cn | .decisions[]? | [.value, $cn, .scenario, .duration] | join("|")' 2>/dev/null)
    n=$(grep -c . <<<"$rows")
    if [ "$n" -gt 0 ]; then
        ui_box_top "Сейчас забанены ($n)"
        ui_box_line "${C_DIM}$(cs_cols 17 IP 7 страна 12 осталось причина)${C_RST}"
        while IFS='|' read -r ip cn sc left; do
            ui_box_line "$(cs_cols 17 "$ip" 7 "${cn:--}" 12 "$(cs_left "$left")" "$(cs_reason "$sc")")"
        done < <(head -n 20 <<<"$rows")
        [ "$n" -gt 20 ] && ui_box_line "${C_DIM}… и ещё $(( n - 20 )): cscli decisions list${C_RST}"
        ui_box_bottom
    else
        ok "Сейчас CrowdSec никого не банит сам"
    fi
    echo
    rows=$(cscli alerts list -l 15 -o json 2>/dev/null | jq -r '
        .[]? | [.created_at, (.source.value // .source.ip // ""), (.source.cn // ""), .scenario,
                (if .remediation then "бан" else "без бана" end)] | join("|")' 2>/dev/null)
    if [ -n "$rows" ]; then
        ui_box_top "Последние срабатывания"
        ui_box_line "${C_DIM}$(cs_cols 13 когда 17 IP 7 страна 10 итог причина)${C_RST}"
        while IFS='|' read -r t ip cn sc res; do
            ui_box_line "$(cs_cols 13 "$(date -d "$t" '+%d.%m %H:%M' 2>/dev/null)" 17 "$ip" 7 "${cn:--}" 10 "$res" "$(cs_reason "$sc")")"
        done <<<"$rows"
        ui_box_bottom
        echo
    fi
    read -r own capi lists <<<"$(cs_counts)"
    note "Общий список сообщества: ${capi:-?} адр. (банит bouncer, здесь не показан)."
    note "Полные списки: cscli decisions list, cscli alerts list."
    [ "$n" -gt 0 ] || return 0
    echo
    ui_menu c "Действие" \
        "unban|Разбанить IP|снять бан CrowdSec$(guard_active && echo " и защиты nftables")|" || return 0
    ip=""
    ui_input ip "IP" "" valid_ip_or_cidr || return 0
    if guard_active && [[ "$ip" != */* ]]; then
        "$GUARD_BIN" unban "$ip"
    elif [[ "$ip" == */* ]]; then
        cscli decisions delete --range "$ip" >/dev/null 2>&1; ok "Бан CrowdSec снят: $ip"
    else
        cscli decisions delete --ip "$ip" >/dev/null 2>&1; ok "Бан CrowdSec снят: $ip"
    fi
}

cs_menu() {
    local c=""
    while true; do
        ui_screen "CrowdSec"
        ui_box_top "CrowdSec"
        ui_kv "Агент" "$(systemctl is-active --quiet crowdsec && ui_badge_ok работает || ui_badge_err остановлен)  ${C_DIM}$(cscli version 2>/dev/null | awk -F': *' '/version/{print $2; exit}')${C_RST}"
        ui_kv "Bouncer" "$(systemctl is-active --quiet crowdsec-firewall-bouncer && ui_badge_ok работает || ui_badge_warn "не работает")"
        ui_kv "Область" "$(cs_scope_current)"
        ui_kv "Баны" "$(cs_counts_label)"
        ui_box_bottom
        echo
        ui_menu c "CrowdSec" -d "$c" \
            "ssh|Область: только SSH|рекомендуется — не банит мобильных абонентов за CGNAT|" \
            "all|Область: все порты|баны и общий список на всех портах, включая 443|" \
            "nginx|Подключить логи nginx-прокси|сканеры сайта-заглушки → бан|" \
            "wl|Обновить whitelist CrowdSec|панель, админ, белый список защиты|" \
            "decisions|Решения|кого забанил CrowdSec, за что и на сколько, разбанить|" || return 0
        case "$c" in
            ssh)       pb_init 4; stepf_try 4 "Область CrowdSec: только SSH" cs_scope_ssh && CS_SCOPE=ssh; cfg_save ;;
            all)       pb_init 3; stepf_try 3 "Область CrowdSec: все порты" cs_scope_all; CS_SCOPE=all; cfg_save ;;
            nginx)     setup_crowdsec_nginx ;;
            wl)        cs_write_whitelist; cs_reload >/dev/null && ok "Whitelist обновлён" ;;
            decisions) action_cs_decisions ;;
        esac
        ui_done
    done
}

action_crowdsec() {
    if has cscli; then
        cs_menu
        return 0
    fi
    ui_screen "CrowdSec"
    note "CrowdSec разбирает логи sshd (и nginx), банит атакующих и получает общий"
    note "список вредоносных адресов от сообщества. Ставится из репозитория CrowdSec,"
    note "ключ проверяется по полному отпечатку."
    echo
    local sc
    ui_menu sc "Где блокировать адреса из CrowdSec" -d "${CS_SCOPE:-ssh}" \
        "ssh|Только SSH|рекомендуется: мобильные операторы держат тысячи абонентов за одним IP|" \
        "all|Все порты|строже, но возможны ложные баны клиентов|" || return 0
    CS_SCOPE="$sc"
    ui_confirm "Установить CrowdSec?" y || return 0
    pb_init 24
    stepf 4 "Репозиторий CrowdSec (ключ по отпечатку)" cs_repo
    stepf 14 "Установка crowdsec и bouncer nftables" cs_install_pkgs
    stepf 2 "Whitelist панели и админа" cs_write_whitelist
    stepf_try 1 "Перезагрузка конфигурации" cs_reload
    if [ "$CS_SCOPE" = "ssh" ]; then
        stepf_try 3 "Область: только SSH" cs_scope_ssh || warn "Область «только SSH» не включилась — CrowdSec работает на всех портах"
    else
        PB_DONE=$(( PB_DONE + 3 ))
        pb_end
    fi
    cfg_save
    setup_crowdsec_nginx
    ok "CrowdSec установлен. Общий список подтянется в течение пары часов."
}

cs_remove() {
    has cscli || { info "CrowdSec не установлен"; return 0; }
    pb_init 6
    stepf_try 1 "Таблицы области SSH" cs_scope_all
    step 5 "Удаление пакетов CrowdSec" \
        "apt-get ${APT_OPTS[*]} purge crowdsec crowdsec-firewall-bouncer-nftables; rm -f '$CS_LIST' '$CS_KEYRING' '$CS_SCOPE_NFT' '$CS_SCOPE_UNIT'; systemctl daemon-reload"
    ok "CrowdSec удалён"
}
