# shellcheck shell=bash

OPT_DIR="$STATE_DIR/optimize"
OPT_SYSCTL="/etc/sysctl.d/99-$KIT_NAME.conf"
OPT_MODLOAD="/etc/modules-load.d/$KIT_NAME.conf"
OPT_MODPROBE="/etc/modprobe.d/$KIT_NAME-conntrack.conf"
OPT_LIMITS="/etc/security/limits.d/99-$KIT_NAME.conf"
OPT_SYSTEMD="/etc/systemd/system.conf.d/99-$KIT_NAME.conf"
OPT_JOURNAL="/etc/systemd/journald.conf.d/99-$KIT_NAME.conf"
OPT_RPS_BIN="/usr/local/sbin/$KIT_NAME-rps"
OPT_RPS_UNIT="/etc/systemd/system/$KIT_NAME-rps.service"
OPT_SWAPFILE="/swapfile"
XANMOD_FP="D38D7D1DA1349567ADED882D86F7D09EE734E623"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod.list"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"

OPT_MEM=0; OPT_TIER=1; OPT_CPU=1; OPT_WAN=""; OPT_RXQ=1; OPT_VIRT=""
OPT_SOCK_MAX=0; OPT_SOCK_DEF=0; OPT_BACKLOG=0; OPT_SYN_BACKLOG=0; OPT_CT_MAX=0; OPT_TW=0

opt_detect() {
    OPT_MEM=$(mem_mb)
    OPT_CPU=$(nproc 2>/dev/null || echo 1)
    OPT_WAN=$(wan_iface)
    OPT_VIRT=$(detect_virt)
    OPT_RXQ=1
    if [ -n "$OPT_WAN" ] && [ -d "/sys/class/net/$OPT_WAN/queues" ]; then
        OPT_RXQ=$(find "/sys/class/net/$OPT_WAN/queues" -maxdepth 1 -name 'rx-*' | wc -l)
        [ "$OPT_RXQ" -lt 1 ] && OPT_RXQ=1
    fi
    if   [ "$OPT_MEM" -le 1200 ]; then OPT_TIER=1; OPT_SOCK_MAX=16777216;  OPT_SOCK_DEF=262144;  OPT_BACKLOG=16384;  OPT_SYN_BACKLOG=8192;  OPT_TW=262144
    elif [ "$OPT_MEM" -le 2500 ]; then OPT_TIER=2; OPT_SOCK_MAX=33554432;  OPT_SOCK_DEF=524288;  OPT_BACKLOG=32768;  OPT_SYN_BACKLOG=16384; OPT_TW=524288
    elif [ "$OPT_MEM" -le 8500 ]; then OPT_TIER=3; OPT_SOCK_MAX=67108864;  OPT_SOCK_DEF=1048576; OPT_BACKLOG=65536;  OPT_SYN_BACKLOG=32768; OPT_TW=1048576
    else                               OPT_TIER=4; OPT_SOCK_MAX=134217728; OPT_SOCK_DEF=2097152; OPT_BACKLOG=131072; OPT_SYN_BACKLOG=65535; OPT_TW=2000000
    fi
    OPT_CT_MAX=$(( OPT_MEM * 1024 * 1024 / 8 / 320 ))
    [ "$OPT_CT_MAX" -gt 2000000 ] && OPT_CT_MAX=2000000
    [ "$OPT_CT_MAX" -lt 65536 ] && OPT_CT_MAX=65536
    return 0
}

opt_tier_name() {
    case "$OPT_TIER" in
        1) echo "до 1 ГБ" ;; 2) echo "1–2.5 ГБ" ;; 3) echo "2.5–8 ГБ" ;; *) echo "больше 8 ГБ" ;;
    esac
}

opt_reserved_ports() {
    local p list=()
    while read -r p; do
        [ "$p" -ge 10000 ] 2>/dev/null && list+=("$p")
    done < <(ss -Hlntu 2>/dev/null | awk '{n=split($5,a,":"); print a[n]}' | grep -E '^[0-9]+$' | sort -un)
    if valid_port "${NODE_PORT:-}" && [ "$NODE_PORT" -ge 10000 ]; then list+=("$NODE_PORT"); fi
    [ "${#list[@]}" -eq 0 ] && return 0
    printf '%s\n' "${list[@]}" | sort -un | paste -sd, -
}

opt_write_sysctl() {
    local f="$1" resv cc="bbr"
    resv=$(opt_reserved_ports)
    modprobe tcp_bbr 2>/dev/null || true
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || cc="cubic"
    cat >"$f" <<EOF

net.core.default_qdisc = fq
net.core.somaxconn = 65535
net.core.netdev_max_backlog = $OPT_BACKLOG
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.rmem_default = $OPT_SOCK_DEF
net.core.wmem_default = $OPT_SOCK_DEF
net.core.rmem_max = $OPT_SOCK_MAX
net.core.wmem_max = $OPT_SOCK_MAX
net.core.optmem_max = 65536

net.ipv4.tcp_congestion_control = $cc
net.ipv4.tcp_rmem = 4096 131072 $OPT_SOCK_MAX
net.ipv4.tcp_wmem = 4096 65536 $OPT_SOCK_MAX
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_min_snd_mss = 512
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_syn_backlog = $OPT_SYN_BACKLOG
net.ipv4.tcp_max_tw_buckets = $OPT_TW
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0

net.netfilter.nf_conntrack_max = $OPT_CT_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.max_map_count = 262144
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

kernel.panic = 10
kernel.panic_on_oops = 1
EOF
    if [ -n "$resv" ]; then
        printf 'net.ipv4.ip_local_reserved_ports = %s\n' "$resv" >>"$f"
    fi
}

opt_keys() { awk -F= '/^[[:space:]]*[a-z]/{gsub(/[[:space:]]/,"",$1); print $1}' "$1"; }

opt_snapshot() {
    local f="$1" k v
    mkdir -p "$OPT_DIR"
    [ -f "$OPT_DIR/sysctl.orig" ] && return 0
    : >"$OPT_DIR/sysctl.orig"
    while read -r k; do
        v=$(sysctl -n "$k" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//') || continue
        [ -n "$v" ] && printf '%s\t%s\n' "$k" "$v" >>"$OPT_DIR/sysctl.orig"
    done < <(opt_keys "$f")
    if [ -n "$OPT_WAN" ]; then
        local q
        for q in /sys/class/net/"$OPT_WAN"/queues/rx-*/rps_cpus; do
            [ -r "$q" ] && printf '%s\t%s\n' "$q" "$(cat "$q")" >>"$OPT_DIR/rps.orig"
        done
    fi
    return 0
}

opt_verify() {
    local f="$1" k want got bad=0 total=0
    OPT_BAD_KEYS=""
    while read -r k; do
        got=$(sysctl -n "$k" 2>/dev/null) || continue
        got=$(tr -s '[:space:]' ' ' <<<"$got" | sed 's/^ //; s/ $//')
        total=$(( total + 1 ))
        want=$(awk -F= -v k="$k" '{g=$1; gsub(/[[:space:]]/,"",g)} g==k {v=$2; sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/,"",v); gsub(/[[:space:]]+/," ",v); print v}' "$f" | tail -n1)
        if [ "$want" != "$got" ]; then
            bad=$(( bad + 1 ))
            OPT_BAD_KEYS+="$k=$got (ждали $want)"$'\n'
        fi
    done < <(opt_keys "$f")
    OPT_OK_COUNT=$(( total - bad ))
    OPT_TOTAL_COUNT=$total
    return 0
}

opt_apply_modules() {
    printf 'tcp_bbr\nnf_conntrack\n' >"$OPT_MODLOAD"
    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    local hs=$(( OPT_CT_MAX / 4 ))
    printf 'options nf_conntrack hashsize=%s\n' "$hs" >"$OPT_MODPROBE"
    [ -w /sys/module/nf_conntrack/parameters/hashsize ] && echo "$hs" >/sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
    return 0
}

opt_apply_sysctl() {
    local tmp; tmp=$(mktemp)
    opt_write_sysctl "$tmp"
    opt_snapshot "$tmp"
    install -m 644 "$tmp" "$OPT_SYSCTL"
    rm -f "$tmp"
    sysctl -e -p "$OPT_SYSCTL" 2>&1 | grep -viE '^[a-z0-9_.]+ = ' || true
    return 0
}

opt_apply_limits() {
    cat >"$OPT_LIMITS" <<'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    mkdir -p "$(dirname "$OPT_SYSTEMD")"
    printf '[Manager]\nDefaultLimitNOFILE=1048576:1048576\n' >"$OPT_SYSTEMD"
    systemctl daemon-reexec 2>/dev/null || true
    return 0
}

opt_apply_journal() {
    mkdir -p "$(dirname "$OPT_JOURNAL")"
    local max=300M
    [ "$OPT_TIER" -ge 3 ] && max=800M
    cat >"$OPT_JOURNAL" <<EOF
[Journal]
SystemMaxUse=$max
SystemMaxFileSize=64M
RuntimeMaxUse=64M
MaxRetentionSec=1month
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    return 0
}

opt_apply_rps() {
    if [ "$OPT_CPU" -le 1 ] || [ "$OPT_RXQ" -ge "$OPT_CPU" ] || [ -z "$OPT_WAN" ]; then
        rm -f "$OPT_RPS_UNIT" "$OPT_RPS_BIN"
        OPT_RPS_STATE="не нужен (ядер $OPT_CPU, очередей $OPT_RXQ)"
        return 0
    fi
    cat >"$OPT_RPS_BIN" <<'EOF'
#!/bin/sh
nic="$1"
[ -n "$nic" ] || nic=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -d "/sys/class/net/$nic/queues" ] || exit 0
n=$(nproc)
mask=$(awk -v n="$n" 'BEGIN{ s=""; while (n > 0) { b = (n >= 32 ? 32 : n); v = (b == 32 ? 4294967295 : 2^b - 1); s = (s == "" ? sprintf("%x", v) : sprintf("%x,%s", v, s)); n -= b } print s }')
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
for q in /sys/class/net/"$nic"/queues/rx-*; do
    echo "$mask" > "$q/rps_cpus" 2>/dev/null
    echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
done
echo "remnanode-tools-rps: $nic mask=$mask"
EOF
    chmod 755 "$OPT_RPS_BIN"
    cat >"$OPT_RPS_UNIT" <<EOF
[Unit]
Description=remnanode-tools: RPS/RFS on $OPT_WAN
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$OPT_RPS_BIN $OPT_WAN

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$KIT_NAME-rps.service" >/dev/null 2>&1 || true
    systemctl restart "$KIT_NAME-rps.service" >/dev/null 2>&1 || true
    OPT_RPS_STATE="включён ($OPT_WAN, $OPT_CPU ядер)"
    return 0
}

opt_apply_qdisc() {
    [ -n "$OPT_WAN" ] && has tc || return 0
    local root txq
    root=$(tc qdisc show dev "$OPT_WAN" root 2>/dev/null | awk 'NR==1{print $2}')
    txq=$(find "/sys/class/net/$OPT_WAN/queues" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l)
    if [ "$root" != "fq" ] && [ "$root" != "mq" ] && [ "${txq:-1}" -le 1 ]; then
        tc qdisc replace dev "$OPT_WAN" root fq 2>/dev/null || true
    fi
    return 0
}

opt_swap_make() {
    local size_mb="$1"
    [ -e "$OPT_SWAPFILE" ] && { echo "$OPT_SWAPFILE уже существует"; return 1; }
    fallocate -l "${size_mb}M" "$OPT_SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$OPT_SWAPFILE" bs=1M count="$size_mb" status=none
    chmod 600 "$OPT_SWAPFILE"
    mkswap "$OPT_SWAPFILE" >/dev/null
    swapon "$OPT_SWAPFILE"
    grep -qE "^${OPT_SWAPFILE}[[:space:]]" /etc/fstab || echo "$OPT_SWAPFILE none swap sw 0 0" >>/etc/fstab
    mkdir -p "$OPT_DIR"; echo "$OPT_SWAPFILE" >"$OPT_DIR/swap.ours"
}

opt_show_plan() {
    ui_box_top "Сервер"
    ui_kv "RAM" "${C_B}${OPT_MEM} МБ${C_RST}  ${C_DIM}уровень $OPT_TIER ($(opt_tier_name))${C_RST}"
    ui_kv "CPU" "$OPT_CPU ядер  ${C_DIM}очередей NIC: $OPT_RXQ${C_RST}"
    ui_kv "Сеть" "${OPT_WAN:-?}  ${C_DIM}виртуализация: $OPT_VIRT${C_RST}"
    ui_kv "Ядро" "$(uname -r)"
    ui_box_sep "что будет сделано"
    ui_kv "TCP" "BBR + fq, буферы до $(( OPT_SOCK_MAX / 1048576 )) МБ, TFO, MTU probing"
    ui_kv "Очереди" "backlog $OPT_BACKLOG, somaxconn 65535, SYN backlog $OPT_SYN_BACKLOG"
    ui_kv "conntrack" "до $OPT_CT_MAX записей, idle established 2 ч"
    ui_kv "Защита ядра" "syncookies, rp_filter=2, без redirect/source-route"
    ui_kv "Лимиты" "nofile 1 048 576 (systemd и limits.conf)"
    ui_kv "Журнал" "systemd-journald не больше $([ "$OPT_TIER" -ge 3 ] && echo 800M || echo 300M)"
    ui_kv "Сбой ядра" "автоперезагрузка через 10 с"
    if [ "$OPT_CPU" -gt 1 ] && [ "$OPT_RXQ" -lt "$OPT_CPU" ]; then
        ui_kv "RPS" "раскидать пакеты по $OPT_CPU ядрам"
    fi
    ui_box_bottom
}

action_optimize_apply() {
    ui_screen "Оптимизация сервера"
    opt_detect
    if is_container; then
        ui_alert "Контейнер ($OPT_VIRT)" \
            "Ядро общее с хостом: часть sysctl не применится, XanMod недоступен." \
            "Применю то, что разрешено, и покажу, что не прошло."
        echo
    fi
    opt_show_plan
    echo
    ui_confirm "Применить оптимизацию?" y || return 0

    local want_swap=0 swap_now
    swap_now=$(awk 'NR>1{s+=$3} END{print int(s/1024)}' /proc/swaps 2>/dev/null || echo 0)
    if [ "${swap_now:-0}" -eq 0 ] && [ "$OPT_MEM" -le 2500 ] && ! is_container; then
        echo
        info "Свопа нет, а RAM всего ${OPT_MEM} МБ — при всплеске нагрузки ядро начнёт убивать процессы."
        if ui_confirm "Создать своп-файл $([ "$OPT_MEM" -le 1200 ] && echo 1 || echo 2) ГБ?" y; then want_swap=1
        elif ui_back; then return 0
        fi
    fi

    echo
    pb_init $(( 15 + want_swap * 3 ))
    stepf 2 "Модули ядра (tcp_bbr, nf_conntrack)" opt_apply_modules
    stepf 6 "Параметры ядра (sysctl)" opt_apply_sysctl
    stepf 2 "Лимиты файловых дескрипторов" opt_apply_limits
    stepf 2 "Ограничение журнала systemd" opt_apply_journal
    stepf 2 "RPS/RFS" opt_apply_rps
    stepf 1 "Очередь fq на ${OPT_WAN:-интерфейсе}" opt_apply_qdisc
    if [ "$want_swap" -eq 1 ]; then
        stepf 3 "Своп-файл $OPT_SWAPFILE" opt_swap_make "$([ "$OPT_MEM" -le 1200 ] && echo 1024 || echo 2048)"
    fi
    opt_report
}

opt_report() {
    [ -f "$OPT_SYSCTL" ] || { warn "Оптимизация не применялась"; return 0; }
    opt_detect
    opt_verify "$OPT_SYSCTL"
    echo
    ui_box_top "Состояние оптимизации"
    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo ?)
    if [ "$cc" = "bbr" ]; then ui_kv "Congestion" "$(ui_badge_ok "$cc")  ${C_DIM}qdisc $qd${C_RST}"; else ui_kv "Congestion" "$(ui_badge_warn "$cc")  ${C_DIM}qdisc $qd${C_RST}"; fi
    if [ "$OPT_OK_COUNT" -eq "$OPT_TOTAL_COUNT" ]; then
        ui_kv "sysctl" "$(ui_badge_ok "$OPT_OK_COUNT из $OPT_TOTAL_COUNT применено")"
    else
        ui_kv "sysctl" "$(ui_badge_warn "$OPT_OK_COUNT из $OPT_TOTAL_COUNT применено")"
    fi
    ui_kv "conntrack" "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo ?) / $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo ?)"
    ui_kv "nofile" "$(ulimit -Hn)  ${C_DIM}(новые службы: $(systemctl show --property DefaultLimitNOFILE --value 2>/dev/null || echo ?))${C_RST}"
    if systemctl is-active --quiet "$KIT_NAME-rps.service" 2>/dev/null; then
        ui_kv "RPS" "$(ui_badge_ok "включён")"
    else
        ui_kv "RPS" "$(ui_badge_off "${OPT_RPS_STATE:-не нужен}")"
    fi
    local sw; sw=$(awk 'NR>1{s+=$3} END{print int(s/1024)}' /proc/swaps 2>/dev/null || echo 0)
    ui_kv "Своп" "$([ "${sw:-0}" -gt 0 ] && echo "${sw} МБ" || echo нет)"
    if uname -r | grep -qi xanmod; then ui_kv "Ядро" "$(ui_badge_ok "$(uname -r)")"; else ui_kv "Ядро" "$(uname -r)"; fi
    ui_box_bottom
    if [ -n "${OPT_BAD_KEYS:-}" ]; then
        echo
        warn "Не применилось или перебито другим файлом в /etc/sysctl.d:"
        printf '%s' "$OPT_BAD_KEYS" | head -n 12 | sed "s/^/    ${C_DIM}/;s/\$/${C_RST}/"
        is_container && note "В контейнере это нормально: ключи принадлежат ядру хоста."
    fi
    return 0
}

opt_rollback() {
    ui_screen "Откат оптимизации"
    if [ ! -f "$OPT_SYSCTL" ] && [ ! -f "$OPT_DIR/sysctl.orig" ]; then
        info "Оптимизация не применялась — откатывать нечего"; return 0
    fi
    ui_confirm "Вернуть исходные параметры ядра и убрать файлы remnanode-tools?" n || return 0
    pb_init 6
    stepf 3 "Исходные значения sysctl" _opt_rollback_sysctl
    stepf 1 "Лимиты, журнал, модули" _opt_rollback_files
    stepf 1 "RPS" _opt_rollback_rps
    stepf 1 "Своп" _opt_rollback_swap
    ok "Оптимизация откачена. Ядро XanMod (если ставилось) убирается отдельным пунктом."
}

_opt_rollback_sysctl() {
    rm -f "$OPT_SYSCTL"
    local k v
    if [ -f "$OPT_DIR/sysctl.orig" ]; then
        while IFS=$'\t' read -r k v; do sysctl -q -w "$k=$v" 2>/dev/null || true; done <"$OPT_DIR/sysctl.orig"
        rm -f "$OPT_DIR/sysctl.orig"
    fi
    return 0
}
_opt_rollback_files() {
    rm -f "$OPT_LIMITS" "$OPT_SYSTEMD" "$OPT_JOURNAL" "$OPT_MODLOAD" "$OPT_MODPROBE"
    systemctl daemon-reexec 2>/dev/null || true
    systemctl restart systemd-journald 2>/dev/null || true
    return 0
}
_opt_rollback_rps() {
    systemctl disable --now "$KIT_NAME-rps.service" >/dev/null 2>&1 || true
    rm -f "$OPT_RPS_UNIT" "$OPT_RPS_BIN"
    systemctl daemon-reload
    local q v
    if [ -f "$OPT_DIR/rps.orig" ]; then
        while IFS=$'\t' read -r q v; do [ -w "$q" ] && echo "$v" >"$q" 2>/dev/null; done <"$OPT_DIR/rps.orig"
        rm -f "$OPT_DIR/rps.orig"
    fi
    return 0
}
_opt_rollback_swap() {
    [ -f "$OPT_DIR/swap.ours" ] || return 0
    swapoff "$OPT_SWAPFILE" 2>/dev/null || true
    sed -i "\#^${OPT_SWAPFILE}[[:space:]]#d" /etc/fstab
    rm -f "$OPT_SWAPFILE" "$OPT_DIR/swap.ours"
    return 0
}

cpu_psabi_level() {
    local flags lvl=1 x
    flags=" $(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2) "
    _hasall() { for x in $1; do [[ "$flags" == *" $x "* ]] || return 1; done; return 0; }
    _hasall "cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3" && lvl=2
    [ "$lvl" -eq 2 ] && _hasall "avx avx2 bmi1 bmi2 f16c fma abm movbe xsave" && lvl=3
    echo "$lvl"
}

secure_boot_on() {
    local st b f=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
    if has mokutil; then
        st=$(mokutil --sb-state 2>/dev/null || true)
        case "$st" in *"SecureBoot enabled"*) return 0 ;; *"SecureBoot disabled"*) return 1 ;; esac
    fi
    [ -r "$f" ] || return 1
    b=$(od -An -t u1 -j4 -N1 "$f" 2>/dev/null | tr -d '[:space:]')
    [ "$b" = "1" ]
}

xanmod_preflight() {
    XM_WHY=""
    [ "$(uname -m)" = "x86_64" ] || XM_WHY="процессор не x86_64"
    is_container && XM_WHY="это контейнер ($(detect_virt)) — ядро общее с хостом"
    secure_boot_on && XM_WHY="включён UEFI Secure Boot: неподписанное ядро не загрузится"
    local fr; fr=$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$fr" =~ ^[0-9]+$ ]] && [ "$fr" -lt 200 ] && XM_WHY="в /boot свободно ${fr} МБ, нужно 200"
    [ -z "$XM_WHY" ]
}

xanmod_repo() {
    local tmp codename="$OS_CODENAME"
    mkdir -p /etc/apt/keyrings
    tmp=$(mktemp)
    if ! curl -fsSL --proto '=https' --max-time 20 https://dl.xanmod.org/archive.key -o "$tmp"; then
        curl -fsSL --proto '=https' --max-time 20 \
            "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${XANMOD_FP: -16}" -o "$tmp" \
            || { rm -f "$tmp"; echo "ключ XanMod недоступен"; return 1; }
    fi
    import_pinned_key "$tmp" "$XANMOD_FP" "$XANMOD_KEYRING" || { rm -f "$tmp"; echo "ключ XanMod не совпал с отпечатком"; return 1; }
    rm -f "$tmp"
    local -a only=(-o "Dir::Etc::sourcelist=$XANMOD_LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
    echo "deb [signed-by=$XANMOD_KEYRING] https://deb.xanmod.org $codename main" >"$XANMOD_LIST"
    if ! apt-get "${APT_OPTS[@]}" update "${only[@]}"; then
        echo "suite $codename не найден — пробую bookworm"
        echo "deb [signed-by=$XANMOD_KEYRING] https://deb.xanmod.org bookworm main" >"$XANMOD_LIST"
        apt-get "${APT_OPTS[@]}" update "${only[@]}" || { rm -f "$XANMOD_LIST"; return 1; }
    fi
    apt_update || true
}

xanmod_install() {
    local lvl pkg="" p
    lvl=$(cpu_psabi_level)
    for p in "linux-xanmod-lts-x64v$lvl" "linux-xanmod-lts-x64v2" "linux-xanmod-lts-x64v1" "linux-xanmod-x64v$lvl"; do
        apt-cache show "$p" >/dev/null 2>&1 && { pkg="$p"; break; }
    done
    [ -n "$pkg" ] || { echo "подходящий пакет XanMod не найден"; return 1; }
    echo "пакет: $pkg"
    apt_install "$pkg" || return 1
    local v drv
    v=$(dpkg-query -W -f='${Depends}' "$pkg" 2>/dev/null | grep -oE 'linux-image-[^ ,()|]+' | head -1); v="${v#linux-image-}"
    [ -n "$v" ] || return 0
    [ -s "/boot/initrd.img-$v" ] || update-initramfs -c -k "$v" || true
    [ -s "/boot/initrd.img-$v" ] || { echo "нет initrd для $v"; return 1; }
    drv=$(basename "$(readlink "/sys/class/net/$(wan_iface)/device/driver" 2>/dev/null)" 2>/dev/null)
    if [ -n "$drv" ] && [ -d "/lib/modules/$v" ]; then
        if [ -z "$(find "/lib/modules/$v" -name "$drv.ko*" -print -quit)" ] && ! grep -q "/$drv.ko" "/lib/modules/$v/modules.builtin" 2>/dev/null; then
            echo "драйвера сети $drv нет в ядре $v"; return 1
        fi
    fi
    echo "$v" >"$STATE_DIR/xanmod.version"
    return 0
}

action_xanmod() {
    ui_screen "Ядро XanMod (BBRv3)"
    opt_detect
    if uname -r | grep -qi xanmod; then
        ok "Уже работает ядро XanMod: ${C_B}$(uname -r)${C_RST}"
        local c
        ui_menu c "Что сделать" \
            "upd|Обновить ядро|apt-get install --only-upgrade linux-xanmod-*|" \
            "rm|Удалить XanMod|вернуться на штатное ядро (после перезагрузки)|" || return 0
        case "$c" in
            upd) pb_init 10; step 10 "Обновление XanMod" "apt-get ${APT_OPTS[*]} update && apt-get ${APT_OPTS[*]} install --only-upgrade \$(dpkg-query -W -f='\${Package}\n' 'linux-xanmod*' 2>/dev/null)"; warn "Если пришло новое ядро — нужна перезагрузка." ;;
            rm)  xanmod_remove ;;
        esac
        return 0
    fi
    ui_box_top "XanMod"
    ui_kv "Что это" "ядро с BBRv3 и настройками под сеть"
    ui_kv "Сборка" "LTS, x86-64-v$(cpu_psabi_level)"
    ui_kv "Риск" "${C_WARN}замена ядра: нужна перезагрузка${C_RST}"
    ui_kv "Запасное" "штатное ядро останется в GRUB"
    ui_box_bottom
    note "На штатном ядре Debian 12/13 и Ubuntu 24.04 BBR уже есть. XanMod даёт BBRv3 —"
    note "заметно только на длинных линиях с потерями. Для большинства нод не обязателен."
    echo
    if ! xanmod_preflight; then err "XanMod ставить нельзя: $XM_WHY"; return 0; fi
    ui_confirm "Установить ядро XanMod?" n || return 0
    pb_init 20
    stepf 5 "Репозиторий XanMod (ключ по отпечатку)" xanmod_repo
    stepf 15 "Установка ядра и проверка initrd/драйвера сети" xanmod_install
    ok "Ядро установлено: ${C_B}$(cat "$STATE_DIR/xanmod.version" 2>/dev/null)${C_RST}"
    warn "Нужна перезагрузка: ${C_B}reboot${C_RST}. После неё проверь: uname -r"
}

xanmod_remove() {
    if ! find /boot -maxdepth 1 -name 'vmlinuz-*' ! -name '*xanmod*' | grep -q .; then
        err "В /boot нет штатного ядра — после удаления XanMod сервер не загрузится."
        note "Сначала поставь штатное: apt-get install linux-image-amd64 (Debian) или linux-image-generic (Ubuntu)"
        return 0
    fi
    ui_confirm "Удалить все пакеты linux-xanmod и репозиторий?" n || return 0
    pb_init 10
    step 8 "Удаление пакетов XanMod" "apt-get ${APT_OPTS[*]} purge \$(dpkg-query -W -f='\${Package}\n' 'linux-*xanmod*' 2>/dev/null) && update-grub"
    step 2 "Удаление репозитория" "rm -f '$XANMOD_LIST' '$XANMOD_KEYRING' '$STATE_DIR/xanmod.version'"
    warn "Перезагрузи сервер, чтобы вернуться на штатное ядро."
}

action_optimize_menu() {
    local c st
    while true; do
        ui_screen "Оптимизация сервера"
        if [ -f "$OPT_SYSCTL" ]; then st="$(ui_badge_ok "применена")"; else st="$(ui_badge_off "не применена")"; fi
        ui_menu c "Оптимизация  $st" -d apply \
            "apply|Применить оптимизацию|BBR, буферы по RAM, conntrack, лимиты, журнал, RPS — рекомендуется|" \
            "status|Проверить состояние|что применилось, что перебито другими файлами|" \
            "xanmod|Ядро XanMod (BBRv3)|по желанию, нужна перезагрузка|$(uname -r | grep -qi xanmod && ui_badge_ok стоит)" \
            "rollback|Откатить оптимизацию|вернуть исходные значения без перезагрузки|"
        case "$c" in
            apply)    action_optimize_apply ;;
            status)   ui_screen "Оптимизация: состояние"; opt_report ;;
            xanmod)   action_xanmod ;;
            rollback) opt_rollback ;;
            *) return 0 ;;
        esac
        ui_done
    done
}
