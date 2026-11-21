# shellcheck shell=bash

KIT_NAME="remnanode-tools"
KIT_CMD="rnt"
KIT_NFT="remnanode_tools"
KIT_VERSION="2.2.2"
KIT_REPO="${KIT_REPO:-Rxxich/remnanode-tools}"
KIT_REF="${KIT_REF:-main}"

CONF_DIR="/etc/$KIT_NAME"
CONF_FILE="$CONF_DIR/config.env"
STATE_DIR="/var/lib/$KIT_NAME"
LOG_FILE="/var/log/$KIT_NAME.log"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -qq -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

kit_locale() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*|*UTF8*|*utf-8*) return 0 ;;
    esac
    if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then
        export LC_ALL=C.UTF-8
    elif locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
        export LC_ALL=en_US.UTF-8
    fi
    return 0
}

kit_colors() {
    C_RST=""; C_B=""; C_DIM=""; C_IT=""
    C_ACC=""; C_ACC2=""; C_OK=""; C_WARN=""; C_ERR=""; C_TXT=""; C_MUTED=""; C_SEL=""
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYA=""; C_MAG=""
    KIT_TTY=0
    [ -t 1 ] || return 0
    KIT_TTY=1
    local n
    n=$(tput colors 2>/dev/null || echo 8)
    C_RST=$'\e[0m'; C_B=$'\e[1m'; C_DIM=$'\e[2m'; C_IT=$'\e[3m'
    if [ "${n:-8}" -ge 256 ] 2>/dev/null; then
        C_ACC=$'\e[38;5;45m'
        C_ACC2=$'\e[38;5;141m'
        C_OK=$'\e[38;5;114m'
        C_WARN=$'\e[38;5;221m'
        C_ERR=$'\e[38;5;203m'
        C_TXT=$'\e[38;5;253m'
        C_MUTED=$'\e[38;5;240m'
        C_DIM=$'\e[38;5;245m'
        C_SEL=$'\e[48;5;236m'
    else
        C_ACC=$'\e[36m'; C_ACC2=$'\e[35m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'
        C_ERR=$'\e[31m'; C_TXT=$'\e[37m'; C_MUTED=$'\e[2m'; C_SEL=$'\e[7m'
    fi
    C_RED="$C_ERR"; C_GRN="$C_OK"; C_YEL="$C_WARN"; C_BLU="$C_ACC"; C_CYA="$C_ACC"; C_MAG="$C_ACC2"
    return 0
}

PB_ACTIVE=0

_line_reset() {
    if [ "${PB_ACTIVE:-0}" = "1" ]; then
        printf '\r\e[2K'
        PB_ACTIVE=0
    fi
    return 0
}

KIT_GEN=0
kit_changed() { KIT_GEN=$(( KIT_GEN + 1 )); }

info()  { _line_reset; UI_LAST=ok; printf '  %s•%s %b\n' "$C_ACC" "$C_RST" "$*"; }
ok()    { _line_reset; UI_LAST=ok; printf '  %s✓%s %b\n' "$C_OK" "$C_RST" "$*"; }
warn()  { _line_reset; UI_LAST=ok; printf '  %s▲%s %b\n' "$C_WARN" "$C_RST" "$*"; }
err()   { _line_reset; UI_LAST=ok; printf '  %s✗%s %b\n' "$C_ERR" "$C_RST" "$*" >&2; }
note()  { _line_reset; UI_LAST=ok; printf '    %s%b%s\n' "$C_DIM" "$*" "$C_RST"; }
logf()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

hr() {
    _line_reset
    local w="${UI_W:-64}" line
    printf -v line '%*s' "$(( w - 2 ))" ''
    printf '  %s%s%s\n' "$C_MUTED" "${line// /─}" "$C_RST"
}

title() {
    _line_reset
    local t="$*" w="${UI_W:-64}" n line
    UI_LAST=ok
    n=$(( w - ${#t} - 6 )); [ "$n" -lt 3 ] && n=3
    printf -v line '%*s' "$n" ''
    printf '\n  %s◆%s %s%s%s %s%s%s\n' "$C_ACC" "$C_RST" "$C_B" "$t" "$C_RST" "$C_MUTED" "${line// /─}" "$C_RST"
}

die() {
    err "$*"
    printf '    %sПодробности: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RST" >&2
    exit 1
}

PB_TOTAL=1; PB_DONE=0; PB_CUR=1; PB_LOCKED=0; PB_WIDTH=28

pb_init() {
    [ "$PB_LOCKED" -eq 1 ] && return 0
    PB_TOTAL=$(( $1 > 0 ? $1 : 1 ))
    PB_DONE=0
    PB_CUR=1
    _line_reset
    return 0
}

pb_begin() { PB_LOCKED=0; pb_init "$1"; PB_LOCKED=1; }

pb_end() {
    PB_LOCKED=0
    PB_DONE="$PB_TOTAL"
    if [ "$KIT_TTY" -eq 1 ]; then
        pb_draw "" "" 0
        printf '\n'
    fi
    PB_ACTIVE=0
}

pb_draw() {
    [ "$KIT_TTY" -eq 1 ] || return 0
    local msg="$1" mark="$2" ticks="${3:-0}"
    local total=$(( PB_TOTAL > 0 ? PB_TOTAL : 1 ))
    local base=$(( PB_DONE * 1000 / total ))
    local span=$(( PB_CUR * 1000 / total ))
    local creep=0
    if [ -n "$msg" ] && [ "$PB_DONE" -lt "$total" ]; then
        creep=$(( span * ( ticks * 95 / ( ticks + 80 ) ) / 100 ))
    fi
    local pm=$(( base + creep ))
    [ "$pm" -gt 1000 ] && pm=1000
    local pct=$(( pm / 10 ))
    local filled=$(( pm * PB_WIDTH / 1000 ))
    local empty=$(( PB_WIDTH - filled ))
    local a b
    printf -v a '%*s' "$filled" ''
    printf -v b '%*s' "$empty" ''
    local sec=$(( ticks / 10 )) t=""
    [ -n "$msg" ] && [ "$sec" -ge 3 ] && t=" ${C_DIM}${sec}s${C_RST}"
    local w="${UI_W:-64}" maxmsg
    maxmsg=$(( w - PB_WIDTH - 16 )); [ "$maxmsg" -lt 10 ] && maxmsg=10
    [ "${#msg}" -gt "$maxmsg" ] && msg="${msg:0:$(( maxmsg - 1 ))}…"
    printf '\r\e[2K  %s%s%s%s%s %3d%%  %s %s%s' \
        "$C_ACC" "${a// /━}" "$C_MUTED" "${b// /─}" "$C_RST" "$pct" "$mark" "$msg" "$t"
    PB_ACTIVE=1
}

_step_wait() {
    local pid="$1" msg="$2" weight="$3"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0 rc=0 t0 dt
    STEP_PID="$pid"
    UI_LAST=ok
    kit_changed
    t0=$(date +%s)
    if [ "$KIT_TTY" -eq 1 ]; then
        printf '\e[?25l'
        while kill -0 "$pid" 2>/dev/null; do
            pb_draw "$msg" "${C_ACC2}${frames[$(( i % 10 ))]}${C_RST}" "$i"
            i=$(( i + 1 ))
            sleep 0.1
        done
    else
        printf '  · %s\n' "$msg"
    fi
    if wait "$pid"; then rc=0; else rc=$?; fi
    STEP_PID=""
    [ "$KIT_TTY" -eq 1 ] && printf '\e[?25h'
    dt=$(( $(date +%s) - t0 ))

    if [ "$rc" -ne 0 ]; then
        _line_reset
        printf '  %s✗%s %s\n' "$C_ERR" "$C_RST" "$msg"
        tail -n 15 "$LOG_FILE" 2>/dev/null | sed "s/^/    ${C_DIM}│${C_RST} /" >&2
        if [ "${STEP_SOFT:-0}" = "1" ]; then
            PB_DONE=$(( PB_DONE + weight ))
            return "$rc"
        fi
        die "Шаг «$msg» завершился с кодом $rc"
    fi

    PB_DONE=$(( PB_DONE + weight ))
    [ "$PB_DONE" -gt "$PB_TOTAL" ] && PB_DONE="$PB_TOTAL"
    _line_reset
    if [ "$dt" -ge 2 ]; then
        printf '  %s✓%s %s %s%ss%s\n' "$C_OK" "$C_RST" "$msg" "$C_DIM" "$dt" "$C_RST"
    else
        printf '  %s✓%s %s\n' "$C_OK" "$C_RST" "$msg"
    fi
    if [ "$PB_LOCKED" -eq 1 ] || [ "$PB_DONE" -lt "$PB_TOTAL" ]; then
        pb_draw "" "" 0
    else
        pb_draw "" "" 0
        [ "$KIT_TTY" -eq 1 ] && printf '\n'
        PB_ACTIVE=0
    fi
    return 0
}

step() {
    local weight=1
    if [[ "$1" =~ ^[0-9]+$ ]]; then weight="$1"; shift; fi
    PB_CUR="$weight"
    local msg="$1"; shift
    local cmd="$*"
    printf '=== %s ===\n' "$msg" >>"$LOG_FILE"
    bash -c "$cmd" >>"$LOG_FILE" 2>&1 &
    _step_wait "$!" "$msg" "$weight"
}

stepf() {
    local weight=1
    if [[ "$1" =~ ^[0-9]+$ ]]; then weight="$1"; shift; fi
    PB_CUR="$weight"
    local msg="$1"; shift
    printf '=== %s ===\n' "$msg" >>"$LOG_FILE"
    ( trap - ERR; set +e; "$@" ) >>"$LOG_FILE" 2>&1 &
    _step_wait "$!" "$msg" "$weight"
}

stepf_try() { local STEP_SOFT=1; stepf "$@"; }
step_try()  { local STEP_SOFT=1; step "$@"; }

need_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    if command -v sudo >/dev/null 2>&1 && [ -f "${KIT_ENTRY:-}" ]; then
        exec sudo -E bash "$KIT_ENTRY" "$@"
    fi
    die "Нужны права root: запусти через sudo."
}

log_init() {
    umask 077
    if ! { : >>"$LOG_FILE"; } 2>/dev/null || [ -L "$LOG_FILE" ]; then
        LOG_FILE="$STATE_DIR/$KIT_NAME.log"
        mkdir -p "$STATE_DIR"
        : >>"$LOG_FILE"
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    umask 022
    printf '\n######## %s  %s v%s ########\n' "$(date '+%F %T')" "$KIT_NAME" "$KIT_VERSION" >>"$LOG_FILE"
}

has() { command -v "$1" >/dev/null 2>&1; }

CFG_VARS=(
    EMAIL DOMAIN SECRET_KEY NODE_VERSION NODE_PORT PANEL_IP
    STUB_MODE SERVICE_NAME SERVICE_IMAGE SERVICE_PORT TEMPLATE_NAME APP_PORT
    XHTTP_PATH GRPC_PATH CUSTOM_CORE XRAY_LOGS
    VALIDATION_METHOD CA_SERVER CF_Token CERT_SOURCE CERT_DNS CERT_NAME CERT_WILDCARD
    STEALTH BASE_NAME IMAGE_ALIAS
    GUARD_WHITELIST GUARD_FEATURES GUARD_BAN_TIME GUARD_SSH_RATE GUARD_SCAN_RATE
    GUARD_SYN_RATE GUARD_CONNLIMIT GUARD_EXTRA_TCP GUARD_BL_EVERY
    CS_SCOPE
)

cfg_load() {
    local f="${1:-$CONF_FILE}"
    [ -f "$f" ] || return 0
    local own perm
    own=$(stat -c %u "$f" 2>/dev/null || echo 1)
    perm=$(stat -c %a "$f" 2>/dev/null || echo 777)
    if [ "$own" != "0" ] || [ $(( 8#$perm & 8#022 )) -ne 0 ]; then
        warn "$f: владелец не root или файл доступен на запись другим — не читаю"
        return 0
    fi
    # shellcheck disable=SC1090
    . "$f"
    return 0
}

cfg_save() {
    local v tmp
    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    tmp=$(mktemp "$CONF_DIR/.config.XXXXXX")
    {
        for v in "${CFG_VARS[@]}"; do
            printf '%s=%q\n' "$v" "${!v:-}"
        done
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONF_FILE"
    kit_changed
}

cfg_revert() {
    local v
    for v in "${CFG_VARS[@]}"; do unset "$v"; done
    cfg_load
    resolve_layout
    return 0
}

draft_file() { printf '%s/draft-%s.env' "$CONF_DIR" "$1"; }

draft_load() { cfg_load "$(draft_file "$1")"; }

draft_drop() { rm -f "$(draft_file "$1")"; }

draft_keep() {
    local name="$1" f v
    f=$(draft_file "$name"); shift
    local -A was=()
    for v in "$@"; do was[$v]="${!v-}"; unset "$v"; done
    cfg_revert
    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    (
        umask 077
        for v in "$@"; do
            [ "${was[$v]}" = "${!v-}" ] || printf '%s=%q\n' "$v" "${was[$v]}"
        done >"$f"
    )
    [ -s "$f" ] || draft_drop "$name"
    return 0
}

valid_ipv4() {
    local ip="$1" o x
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a o <<<"$ip"
    for x in "${o[@]}"; do [ "$((10#$x))" -le 255 ] || return 1; done
    return 0
}

valid_ipv6() { [[ "$1" =~ ^[0-9a-fA-F:]+$ && "$1" == *:*:* ]]; }

valid_ip_or_cidr() {
    local val="$1" ip mask
    ip="${val%%/*}"
    if [[ "$val" == */* ]]; then
        mask="${val#*/}"
        [[ "$mask" =~ ^[0-9]{1,3}$ ]] || return 1
        if valid_ipv4 "$ip"; then [ "$mask" -le 32 ]; return; fi
        if valid_ipv6 "$ip"; then [ "$mask" -le 128 ]; return; fi
        return 1
    fi
    valid_ipv4 "$ip" || valid_ipv6 "$ip"
}

valid_ip_list() {
    local e
    [ -z "$1" ] && return 0
    for e in ${1//,/ }; do valid_ip_or_cidr "$e" || return 1; done
    return 0
}

valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_email()  { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; }
valid_port()   { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_urlpath(){ [[ "$1" =~ ^/?[A-Za-z0-9._~/-]{1,128}$ ]]; }
valid_base_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; }
valid_secret() { [ "${#1}" -ge 16 ] && [[ "$1" =~ ^[A-Za-z0-9+/=._-]+$ ]]; }
valid_nonempty() { [ -n "$1" ]; }

OS_ID=""; OS_VER=""; OS_CODENAME=""; OS_PRETTY=""; OS_SUPPORTED=0

os_detect() {
    [ -r /etc/os-release ] || return 0
    # shellcheck disable=SC1091
    OS_ID=$(. /etc/os-release; echo "${ID:-}")
    OS_VER=$(. /etc/os-release; echo "${VERSION_ID:-}")
    OS_CODENAME=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
    OS_PRETTY=$(. /etc/os-release; echo "${PRETTY_NAME:-}")
    case "$OS_ID:$OS_VER" in
        debian:12*|debian:13*|ubuntu:24.04) OS_SUPPORTED=1 ;;
        *) OS_SUPPORTED=0 ;;
    esac
}

os_check() {
    os_detect
    [ "$OS_SUPPORTED" -eq 1 ] && return 0
    warn "ОС ${C_B}${OS_PRETTY:-неизвестна}${C_RST} официально не поддерживается."
    note "Проверено на Debian 12 / 13 и Ubuntu 24.04."
    if [[ "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" ]]; then
        die "Нужен Debian или Ubuntu (apt, systemd)."
    fi
    ui_confirm "Продолжить на свой риск?" n || exit 0
}

detect_virt() {
    local v=""
    has systemd-detect-virt && v=$(systemd-detect-virt 2>/dev/null || true)
    echo "${v:-none}"
}

is_container() {
    case "$(detect_virt)" in
        openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|wsl|rkt) return 0 ;;
    esac
    return 1
}

mem_mb() { awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024; }

wan_iface() {
    ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

ssh_client_ip() {
    local ip="" pid="$$" envf n=0
    ip="${SSH_CONNECTION:-${SSH_CLIENT:-}}"
    while [ -z "$ip" ] && [ "$pid" -gt 1 ] && [ "$n" -lt 15 ]; do
        envf="/proc/$pid/environ"
        if [ -r "$envf" ]; then
            ip=$(tr '\0' '\n' <"$envf" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n1)
        fi
        pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 1)
        n=$(( n + 1 ))
    done
    ip="${ip%% *}"
    ip="${ip#::ffff:}"
    if valid_ipv4 "$ip" || valid_ipv6 "$ip"; then
        [ "$ip" != "127.0.0.1" ] && [ "$ip" != "::1" ] && echo "$ip"
    fi
    return 0
}

ssh_session_port() {
    local c="${SSH_CONNECTION:-}" pid="$$" n=0
    while [ -z "$c" ] && [ "$pid" -gt 1 ] && [ "$n" -lt 15 ]; do
        [ -r "/proc/$pid/environ" ] && c=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n1)
        pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 1)
        n=$(( n + 1 ))
    done
    c=$(awk '{print $4}' <<<"$c")
    valid_port "$c" && echo "$c"
    return 0
}

ssh_ports() {
    local p=() x
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        while read -r x; do p+=("$x"); done < <(systemctl show ssh.socket -p Listen --value 2>/dev/null \
            | grep -oE '[0-9]+ \(Stream\)' | awk '{print $1}')
    fi
    if has sshd; then
        while read -r x; do p+=("$x"); done < <(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')
    fi
    while read -r x; do p+=("$x"); done < <(ss -Hltnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}')
    x=$(ssh_session_port); [ -n "$x" ] && p+=("$x")
    [ "${#p[@]}" -eq 0 ] && p+=(22)
    printf '%s\n' "${p[@]}" | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -
}

apt_update()  { apt-get "${APT_OPTS[@]}" update; }
apt_install() { apt-get "${APT_OPTS[@]}" install --no-install-recommends "$@"; }

import_pinned_key() {
    local src="$1" fp="$2" out="$3" home rc=1 got
    has gpg || apt_install gnupg >>"$LOG_FILE" 2>&1 || return 1
    home=$(mktemp -d); chmod 700 "$home"
    if GNUPGHOME="$home" gpg --batch --quiet --import "$src" >/dev/null 2>&1; then
        if GNUPGHOME="$home" gpg --batch --yes --export "$fp" >"$out.tmp" 2>/dev/null && [ -s "$out.tmp" ]; then
            got=$(gpg --show-keys --with-colons "$out.tmp" 2>/dev/null \
                  | awk -F: '$1=="pub"{p=1;next} $1=="fpr"&&p{print $10;p=0}')
            [ "$got" = "$fp" ] && rc=0
        fi
    fi
    gpgconf --homedir "$home" --kill all >/dev/null 2>&1 || true
    rm -rf "$home"
    if [ "$rc" -eq 0 ]; then
        mv -f "$out.tmp" "$out"; chmod 644 "$out"
    else
        rm -f "$out.tmp"
    fi
    return "$rc"
}

svc_restart() { systemctl restart "$1" >/dev/null 2>&1 || true; }

nft_list() { echo "$*" | tr -s ' ,' '\n' | grep -v '^$' | sort -u | paste -sd, - | sed 's/,/, /g'; }
