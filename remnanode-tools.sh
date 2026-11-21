#!/usr/bin/env bash
set -o pipefail

KIT_ENTRY="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
KIT_HOME="$(cd "$(dirname "$KIT_ENTRY")" && pwd)"

for _f in lib/core.sh lib/ui.sh \
          modules/node.sh modules/certs.sh modules/stub.sh modules/xcore.sh modules/firewall.sh \
          modules/logs.sh modules/ipv6.sh modules/stealth.sh \
          modules/optimize.sh modules/protect.sh modules/blocklists.sh modules/crowdsec.sh \
          modules/info.sh; do
    if [ ! -f "$KIT_HOME/$_f" ]; then
        echo "remnanode-tools: не найден $KIT_HOME/$_f — переустанови: bash <(curl -fsSL https://raw.githubusercontent.com/${KIT_REPO:-Rxxich/remnanode-tools}/main/install.sh)" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$KIT_HOME/$_f"
done
unset _f

STEP_PID=""
MENU_CACHE=""
on_exit() { ui_cleanup; [ -n "$MENU_CACHE" ] && rm -f "$MENU_CACHE"; }
on_int()  { [ -n "${STEP_PID:-}" ] && kill "$STEP_PID" 2>/dev/null; ui_cleanup; printf '\n'; exit 130; }

kit_link_commands() {
    local n l
    for n in "$KIT_CMD" "$KIT_NAME"; do
        l="/usr/local/bin/$n"
        if [ ! -e "$l" ] || { [ -L "$l" ] && [ ! -e "$(readlink -f "$l")" ]; }; then
            ln -sfn "$KIT_ENTRY" "$l" 2>/dev/null || true
        fi
    done
    return 0
}

kit_version_of() { sed -n 's/^KIT_VERSION="\([0-9.]*\)".*/\1/p' | head -n1; }

kit_remote_version() {
    curl -fsSL --proto '=https' --max-time 15 \
        "https://raw.githubusercontent.com/$KIT_REPO/$1/lib/core.sh?t=$(date +%s)" 2>/dev/null | kit_version_of
}

kit_update() {
    ui_screen "Обновление remnanode-tools"
    if [ -d "$KIT_HOME/.git" ]; then
        warn "$KIT_HOME — git-репозиторий: обнови его через git pull."
        return 0
    fi
    local ref="${KIT_REF:-main}" tmp new rc
    [ -f "$KIT_HOME/.ref" ] && ref=$(cat "$KIT_HOME/.ref")
    info "Проверяю ${C_B}$KIT_REPO${C_RST} @ ${C_B}$ref${C_RST}…"
    new=$(kit_remote_version "$ref")
    if [ -z "$new" ]; then
        warn "Не удалось узнать версию на GitHub"
        ui_confirm "Всё равно скачать и установить?" n || return 0
    elif [ "$new" = "$KIT_VERSION" ]; then
        ok "Уже стоит последняя версия ${C_B}$KIT_VERSION${C_RST}"
        ui_confirm "Переустановить её?" n || return 0
    else
        ok "На GitHub версия ${C_B}$new${C_RST}, установлена $KIT_VERSION"
        ui_confirm "Обновить $KIT_VERSION → $new?" y || return 0
    fi
    tmp=$(mktemp)
    if ! curl -fsSL --proto '=https' --max-time 30 "https://raw.githubusercontent.com/$KIT_REPO/$ref/install.sh?t=$(date +%s)" -o "$tmp"; then
        rm -f "$tmp"; err "Не удалось скачать install.sh"; return 0
    fi
    KIT_REF="$ref" KIT_REPO="$KIT_REPO" KIT_DIR="$KIT_HOME" KIT_NO_RUN=1 bash "$tmp"
    rc=$?; rm -f "$tmp"
    if [ "$rc" -ne 0 ]; then err "Обновление не удалось (код $rc)"; return 0; fi
    new=$(kit_version_of <"$KIT_HOME/lib/core.sh")
    ok "Установлена версия ${C_B}${new:-?}${C_RST}"
    [ "${1:-}" = "menu" ] || return 0
    note "Перезапускаю меню…"
    sleep 1
    ui_cleanup
    [ -n "$MENU_CACHE" ] && rm -f "$MENU_CACHE"
    exec bash "$KIT_HOME/remnanode-tools.sh"
}

main_menu() {
    local c core_label core_badge opt_badge prot_badge cert_b last="install" gen=-1
    MENU_CACHE=$(mktemp)
    while true; do
        if [ "$gen" != "$KIT_GEN" ]; then
            { ui_logo; show_server_info; echo; } >"$MENU_CACHE"
            if [ -n "$INFO_CORE_BIN" ]; then
                core_label="Обновить ядро Xray (Jolymmiles)"
                core_badge=""; [ -n "$INFO_CORE_UPDATE" ] && core_badge="$(ui_badge_warn "$INFO_CORE_UPDATE")"
            else
                core_label="Добавить ядро Xray (Jolymmiles)"; core_badge=""
            fi
            if [ -f "$OPT_SYSCTL" ]; then opt_badge="$(ui_badge_ok вкл)"; else opt_badge="$(ui_badge_off выкл)"; fi
            if guard_active; then prot_badge="$(ui_badge_ok вкл)"; else prot_badge="$(ui_badge_off выкл)"; fi
            cert_b=$(cert_badge)
            gen=$KIT_GEN
        fi
        cat "$MENU_CACHE"

        ui_menu c "Главное меню" -d "$last" \
            "-|нода" \
            "install|Установить Remnanode|nginx + SSL + маскировка + нода, полная установка|$([ -n "$INFO_NODE" ] && ui_badge_ok стоит)" \
            "cert|SSL-сертификат|срок, продление, смена способа, свой сертификат, Telegram|$cert_b" \
            "core|$core_label|бинарник подменяется томом, проверка SHA-256, откат|$core_badge" \
            "fw|Firewall (ufw)|SSH, 80, 443 и порт ноды только для IP панели|" \
            "logs|Логи Xray + logrotate|access/error-логи ноды на хосте с ротацией|" \
            "stub|Заглушка сайта|статический шаблон или docker-сервис за nginx|" \
            "ipv6|IPv6: включить / отключить|сохраняется после перезагрузки|" \
            "-|сервер" \
            "opt|Оптимизация сервера|BBR, буферы по RAM, conntrack, лимиты, XanMod|$opt_badge" \
            "prot|Защита сервера|nftables, блок-листы, SSH, CrowdSec, автообновления|$prot_badge" \
            "-|remnanode-tools" \
            "update|Обновить remnanode-tools|скачать свежую версию с GitHub|" \
            "quit|Выход||"
        [ -n "$c" ] && last="$c"
        case "$c" in
            install) action_install_node ;;
            cert)    action_cert_menu; continue ;;
            core)    action_core_menu ;;
            fw)      action_firewall ;;
            logs)    action_xray_logs ;;
            stub)    action_stub ;;
            ipv6)    action_ipv6 ;;
            opt)     action_optimize_menu; continue ;;
            prot)    action_protect_menu; continue ;;
            update)  kit_update menu ;;
            quit|"") echo; ok "Пока! Меню снова: ${C_B}$KIT_CMD${C_RST}"; exit 0 ;;
        esac
        ui_done
    done
}

usage() {
    cat <<EOF
$KIT_NAME $KIT_VERSION — установка и обслуживание ноды Remnawave
Debian 12 / 13 · Ubuntu 24.04

  $KIT_CMD                          меню (стрелки ↑↓, Enter, Esc — назад)
  $KIT_CMD install                  мастер установки ноды
  $KIT_CMD cert     [status|renew|check]
  $KIT_CMD optimize [apply|status|rollback|xanmod]
  $KIT_CMD protect  [apply|status|rollback|ssh|updates|crowdsec|lists]
  $KIT_CMD guard    allow|unallow|ban|unban|bans|status|lists IP…
  $KIT_CMD status                   сводка без меню
  $KIT_CMD update                   обновить с GitHub
  $KIT_CMD version
EOF
}

main() {
    kit_locale
    kit_colors
    ui_init
    case "${1:-}" in -h|--help|help) usage; exit 0 ;; version|--version) echo "$KIT_NAME $KIT_VERSION"; exit 0 ;; esac
    need_root "$@"
    trap on_exit EXIT
    trap on_int INT TERM
    mkdir -p "$CONF_DIR" "$STATE_DIR"; chmod 700 "$CONF_DIR" "$STATE_DIR"
    log_init
    kit_link_commands
    os_detect
    cfg_load
    resolve_layout

    case "${1:-}" in
        "")
            ui_has_tty || die "Меню требует терминал. Команды без меню: $KIT_CMD --help"
            os_check
            main_menu ;;
        install)  os_check; action_install_node ;;
        cert)
            case "${2:-}" in
                status) cert_status_box ;;
                renew)  cert_renew_now ;;
                check)  cert_check_renewal ;;
                *) action_cert_menu ;;
            esac ;;
        optimize)
            case "${2:-}" in
                apply) action_optimize_apply ;;
                status) opt_report ;;
                rollback) opt_rollback ;;
                xanmod) action_xanmod ;;
                *) action_optimize_menu ;;
            esac ;;
        protect)
            case "${2:-}" in
                apply) action_guard_apply ;;
                status) guard_status ;;
                rollback) action_protect_rollback ;;
                ssh) action_ssh_harden ;;
                updates) action_auto_updates ;;
                crowdsec) action_crowdsec ;;
                lists) action_blocklists_menu ;;
                *) action_protect_menu ;;
            esac ;;
        guard)
            shift
            [ -x "$GUARD_BIN" ] || die "Защита не установлена: $KIT_CMD protect apply"
            exec "$GUARD_BIN" "$@" ;;
        status)   show_server_info; guard_status ;;
        update)   kit_update ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
