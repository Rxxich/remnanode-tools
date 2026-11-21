# shellcheck shell=bash

ask_firewall_params() {
    [ "${FW_PARAMS_ASKED:-0}" = "1" ] && return 0
    ui_input NODE_PORT "Порт Remnanode (API ноды)" "${NODE_PORT:-2222}" valid_port || return 1
    echo
    note "Порт ноды будет открыт только для IP панели."
    note "Несколько адресов — через запятую, можно CIDR (1.2.3.0/24)."
    while true; do
        ui_input PANEL_IP "IP-адрес панели (пусто — открыть порт всем)" "${PANEL_IP:-}" valid_ip_list || return 1
        PANEL_IP="${PANEL_IP// /}"
        if [ -z "${PANEL_IP:-}" ]; then
            warn "IP не указан — порт $NODE_PORT будет открыт для всего интернета."
            ui_confirm "Точно продолжить?" n && break
            ui_back && return 1
            continue
        fi
        break
    done
    FW_PARAMS_ASKED=1
    return 0
}

setup_firewall() {
    title "Firewall (ufw)"
    ask_firewall_params || return 0
    NODE_PORT="${NODE_PORT:-2222}"

    if ! has ufw; then
        pb_init 6
        step 6 "Установка ufw" "apt-get ${APT_OPTS[*]} install ufw"
    fi

    local ips=() entry sshp p
    if [ -n "${PANEL_IP:-}" ]; then
        for entry in ${PANEL_IP//,/ }; do ips+=("$entry"); done
    fi
    sshp=$(ssh_ports)

    local n_ssh; n_ssh=$(wc -w <<<"$sshp")
    local rule_steps=${#ips[@]}; [ "$rule_steps" -eq 0 ] && rule_steps=1
    pb_init $(( 6 + n_ssh + rule_steps ))

    for p in $sshp; do
        step 1 "Разрешить SSH ($p/tcp)" "ufw allow $p/tcp"
    done
    step 1 "Разрешить HTTP (80/tcp)" "ufw allow 80/tcp"
    step 1 "Разрешить HTTPS (443/tcp)" "ufw allow 443/tcp"
    step 1 "Очистка старого правила для порта $NODE_PORT" "ufw delete allow $NODE_PORT/tcp || true"

    if [ "${#ips[@]}" -gt 0 ]; then
        for entry in "${ips[@]}"; do
            step 1 "Remnanode $NODE_PORT/tcp только с $entry" "ufw allow from $entry to any port $NODE_PORT proto tcp"
        done
    else
        step 1 "Remnanode ($NODE_PORT/tcp) для всех" "ufw allow $NODE_PORT/tcp"
    fi
    step 2 "Включение ufw" "ufw --force enable"
    cfg_save
    ok "Firewall активен ${C_DIM}(SSH: $sshp)${C_RST}"
    [ "${#ips[@]}" -gt 0 ] && ok "Порт $NODE_PORT доступен только с: ${ips[*]}"
    if [ -x "$GUARD_BIN" ] && guard_active; then
        "$GUARD_BIN" sync >/dev/null 2>&1 || true
    fi
    echo
    ufw status numbered 2>/dev/null | sed 's/^/    /'
}

action_firewall() {
    ui_screen "Firewall (ufw)"
    FW_PARAMS_ASKED=0
    ask_firewall_params || { cfg_revert; return 0; }
    setup_firewall
}
