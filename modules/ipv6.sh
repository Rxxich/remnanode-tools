# shellcheck shell=bash

IPV6_SYSCTL="/etc/sysctl.d/99-disable-ipv6.conf"

ipv6_is_disabled() {
    local v; v=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
    [ "$v" = "1" ]
}

ipv6_show_status() {
    ui_box_top "IPv6"
    if [ ! -f /proc/net/if_inet6 ] || ipv6_is_disabled; then
        ui_kv "Состояние" "$(ui_badge_warn "отключён")"
    else
        ui_kv "Состояние" "$(ui_badge_ok "включён")"
        local a
        while read -r a; do [ -n "$a" ] && ui_kv "" "$a"; done < <(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}')
    fi
    [ -f "$IPV6_SYSCTL" ] && ui_kv "Правило" "${C_DIM}$IPV6_SYSCTL${C_RST}"
    grep -qs 'ipv6\.disable=1' /etc/default/grub && ui_kv "GRUB" "${C_DIM}ipv6.disable=1 (меняется только с перезагрузкой)${C_RST}"
    ui_box_bottom
    return 0
}

ipv6_disable() {
    title "Отключение IPv6"
    cat >"$IPV6_SYSCTL" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    pb_init 3
    step 1 "Запись правила $IPV6_SYSCTL" "test -s '$IPV6_SYSCTL'"
    step 2 "Применение параметров ядра" "sysctl -p '$IPV6_SYSCTL' >/dev/null 2>&1 || true"
    if ipv6_is_disabled; then
        ok "IPv6 отключён, правило применяется при каждой загрузке."
        note "Если у ноды была AAAA-запись — трафик по ней больше не пойдёт."
    else
        warn "Не удалось отключить IPv6 «на лету» (частая ситуация в контейнерах/LXC)."
        note "Правило записано и применится при следующей загрузке."
    fi
    return 0
}

ipv6_enable() {
    title "Включение IPv6"
    pb_init 4
    step 1 "Удаление правила $IPV6_SYSCTL" "rm -f '$IPV6_SYSCTL'"
    step 1 "Снятие disable_ipv6 в sysctl.conf и sysctl.d" \
        "sed -i -E 's|^([[:space:]]*net\.ipv6\.conf\.[^=]*disable_ipv6[[:space:]]*=.*)\$|# \1|' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null || true"
    step 2 "Применение параметров ядра" \
        "sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true; \
         sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true; \
         sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true"
    if ipv6_is_disabled; then warn "IPv6 всё ещё отключён на уровне ядра."; else ok "IPv6 включён."; fi

    if grep -qs 'ipv6\.disable=1' /etc/default/grub; then
        echo
        warn "В /etc/default/grub стоит ipv6.disable=1 — ядро отключает IPv6 ещё до sysctl."
        if ui_confirm "Убрать параметр из GRUB (нужна перезагрузка)?" y; then
            pb_init 6
            step 1 "Правка /etc/default/grub" "sed -i -E 's/ ?ipv6\.disable=1//g' /etc/default/grub"
            step 5 "Обновление загрузчика" "update-grub"
            warn "Перезагрузи сервер, чтобы изменение вступило в силу."
        fi
    fi
    note "Адрес по SLAAC/DHCPv6 может появиться не сразу — при необходимости перезапусти сеть."
    return 0
}

action_ipv6() {
    ui_screen "Управление IPv6"
    ipv6_show_status
    echo
    local c
    ui_menu c "Что сделать" \
        "off|Отключить IPv6|постоянно, сохраняется после перезагрузки|" \
        "on|Включить IPv6|снять все запреты (sysctl и GRUB)|"
    case "$c" in
        off) ipv6_disable ;;
        on)  ipv6_enable ;;
        *)   return 0 ;;
    esac
}
