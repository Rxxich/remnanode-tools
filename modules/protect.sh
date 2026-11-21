# shellcheck shell=bash

GUARD_TABLE="inet $KIT_NFT"
GUARD_NFT="$CONF_DIR/guard.nft"
GUARD_CONF="$CONF_DIR/guard.conf"
GUARD_ALLOW="$CONF_DIR/guard-allow.txt"
GUARD_BIN="/usr/local/sbin/$KIT_NAME-guard"
GUARD_UNIT="/etc/systemd/system/$KIT_NAME-guard.service"
GUARD_SYNC_UNIT="/etc/systemd/system/$KIT_NAME-guard-sync"
GUARD_BL_UNIT="/etc/systemd/system/$KIT_NAME-guard-blocklist"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-$KIT_NAME.conf"
UU_CONF="/etc/apt/apt.conf.d/52$KIT_NAME-unattended"
NR_CONF="/etc/needrestart/conf.d/50-$KIT_NAME.conf"

guard_defaults() {
    GUARD_FEATURES="${GUARD_FEATURES:-scan ssh syn icmp bl}"
    GUARD_BAN_TIME="${GUARD_BAN_TIME:-1d}"
    GUARD_SSH_RATE="${GUARD_SSH_RATE:-10}"
    GUARD_SCAN_RATE="${GUARD_SCAN_RATE:-20}"
    GUARD_SYN_RATE="${GUARD_SYN_RATE:-200}"
    GUARD_CONNLIMIT="${GUARD_CONNLIMIT:-0}"
    return 0
}

guard_has() { [[ " ${GUARD_FEATURES:-} " == *" $1 "* ]]; }
guard_active() { nft list table $GUARD_TABLE >/dev/null 2>&1; }

guard_render() {
    local out="$1" sshp="$2"
    local ban="$GUARD_BAN_TIME" sr="$GUARD_SSH_RATE" sb=$(( GUARD_SSH_RATE + 4 ))
    local scr="$GUARD_SCAN_RATE" syr="$GUARD_SYN_RATE" syb=$(( GUARD_SYN_RATE * 2 ))
    local f v
    {
        echo "#!/usr/sbin/nft -f"
        echo "table $GUARD_TABLE {}"
        echo "delete table $GUARD_TABLE"
        echo "table $GUARD_TABLE {"
        for v in 4 6; do
            if [ "$v" = 4 ]; then f=ipv4_addr; else f=ipv6_addr; fi
            cat <<EOF
    set wl$v { type $f; flags interval; auto-merge; }
    set ban$v { type $f; size 65536; flags dynamic,timeout; timeout $ban; }
    set sus$v { type $f; size 65536; flags dynamic,timeout; timeout 1h; }
    set m_ssh$v { type $f; size 65536; flags dynamic,timeout; timeout 10m; }
    set m_sshx$v { type $f; size 65536; flags dynamic,timeout; timeout 10m; }
    set m_scan$v { type $f; size 65536; flags dynamic,timeout; timeout 10m; }
    set m_scanx$v { type $f; size 65536; flags dynamic,timeout; timeout 10m; }
    set m_syn$v { type $f; size 65536; flags dynamic,timeout; timeout 1m; }
    set m_icmp$v { type $f; size 65536; flags dynamic,timeout; timeout 1m; }
EOF
            guard_has conn && echo "    set m_conn$v { type $f; size 65536; flags dynamic; }"
        done
        guard_has bl && bl_render_sets
        cat <<EOF
    set open_tcp { type inet_service; flags interval; auto-merge; }
    set ssh_tcp { type inet_service; flags interval; auto-merge; elements = { $(nft_list "$sshp") } }

    counter c_badflags {}
    counter c_invalid {}
    counter c_ban {}
    counter c_scan {}
    counter c_ssh {}
    counter c_synflood {}
    counter c_icmp {}
    counter c_connlimit {}

    chain input {
        type filter hook input priority -5; policy accept;
        iif "lo" accept
        iifname "docker*" accept
        iifname "br-*" accept
        iifname "veth*" accept

        tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 counter name c_badflags drop
        tcp flags & (fin|psh|urg) == fin|psh|urg counter name c_badflags drop
        tcp flags & (syn|fin) == syn|fin counter name c_badflags drop
        tcp flags & (syn|rst) == syn|rst counter name c_badflags drop
        tcp flags & (fin|rst) == fin|rst counter name c_badflags drop
EOF
        if guard_has icmp; then
            cat <<EOF

        icmp type echo-request ip saddr != @wl4 update @m_icmp4 { ip saddr limit rate over 10/second burst 20 packets } counter name c_icmp drop
        icmpv6 type echo-request ip6 saddr != @wl6 update @m_icmp6 { ip6 saddr limit rate over 10/second burst 20 packets } counter name c_icmp drop
EOF
        fi
        cat <<EOF

        ct state established,related accept
        ct state invalid counter name c_invalid drop

        ip saddr @wl4 accept
        ip6 saddr @wl6 accept
        ip saddr @ban4 counter name c_ban drop
        ip6 saddr @ban6 counter name c_ban drop
EOF
        guard_has bl && printf '        jump blocklists\n'
        if guard_has ssh; then
            cat <<EOF

        tcp dport @ssh_tcp ct state new update @m_ssh4 { ip saddr limit rate over $sr/minute burst $sb packets } jump ssh_over
        tcp dport @ssh_tcp ct state new update @m_ssh6 { ip6 saddr limit rate over $sr/minute burst $sb packets } jump ssh_over
EOF
        fi
        if guard_has scan; then
            cat <<EOF

        tcp flags & (fin|syn|rst|ack) == syn tcp dport != @open_tcp tcp dport != @ssh_tcp update @m_scan4 { ip saddr limit rate over $scr/minute burst $scr packets } jump scan_over
        tcp flags & (fin|syn|rst|ack) == syn tcp dport != @open_tcp tcp dport != @ssh_tcp update @m_scan6 { ip6 saddr limit rate over $scr/minute burst $scr packets } jump scan_over
EOF
        fi
        if guard_has syn; then
            cat <<EOF

        tcp flags & (fin|syn|rst|ack) == syn tcp dport @open_tcp update @m_syn4 { ip saddr limit rate over $syr/second burst $syb packets } counter name c_synflood drop
        tcp flags & (fin|syn|rst|ack) == syn tcp dport @open_tcp update @m_syn6 { ip6 saddr limit rate over $syr/second burst $syb packets } counter name c_synflood drop
EOF
        fi
        if guard_has conn && [ "${GUARD_CONNLIMIT:-0}" -gt 0 ]; then
            cat <<EOF

        tcp dport @open_tcp ct state new add @m_conn4 { ip saddr ct count over $GUARD_CONNLIMIT } counter name c_connlimit drop
        tcp dport @open_tcp ct state new add @m_conn6 { ip6 saddr ct count over $GUARD_CONNLIMIT } counter name c_connlimit drop
EOF
        fi
        cat <<EOF
    }

    chain ssh_over {
        ip saddr @sus4 update @m_sshx4 { ip saddr limit rate over $sr/minute burst $(( sb * 3 )) packets } add @ban4 { ip saddr } counter name c_ssh drop
        ip6 saddr @sus6 update @m_sshx6 { ip6 saddr limit rate over $sr/minute burst $(( sb * 3 )) packets } add @ban6 { ip6 saddr } counter name c_ssh drop
        meta nfproto ipv4 add @sus4 { ip saddr } counter name c_ssh drop
        meta nfproto ipv6 add @sus6 { ip6 saddr } counter name c_ssh drop
    }

    chain scan_over {
        ip saddr @sus4 update @m_scanx4 { ip saddr limit rate over $scr/minute burst $(( scr * 2 )) packets } add @ban4 { ip saddr } counter name c_scan drop
        ip6 saddr @sus6 update @m_scanx6 { ip6 saddr limit rate over $scr/minute burst $(( scr * 2 )) packets } add @ban6 { ip6 saddr } counter name c_scan drop
        meta nfproto ipv4 add @sus4 { ip saddr } counter name c_scan
        meta nfproto ipv6 add @sus6 { ip6 saddr } counter name c_scan
    }
EOF
        guard_has bl && bl_render_chain
        echo "}"
    } >"$out"
}

guard_write_helper() {
    sed -e "s|__TABLE__|$GUARD_TABLE|g" -e "s|__CONFDIR__|$CONF_DIR|g" \
        -e "s|__STATE__|$STATE_DIR/guard|g" -e "s|__KIT__|$KIT_NAME|g" >"$GUARD_BIN" <<'HELPER'
#!/usr/bin/env bash
set -uo pipefail
T="__TABLE__"
CONF=__CONFDIR__/guard.conf
ALLOW=__CONFDIR__/guard-allow.txt
LISTS=__CONFDIR__/blocklists.conf
LOCAL=__CONFDIR__/blocklist-local.txt
EXCL=__CONFDIR__/blocklist-exclude.txt
STATE=__STATE__
LDIR="$STATE/lists"
PORTS_RUN=/run/__KIT__-guard.ports
GUARD_EXTRA_TCP=""; GUARD_BL=0
mkdir -p "$STATE" "$LDIR"
[ -f "$CONF" ] && [ "$(stat -c %u "$CONF")" = 0 ] && . "$CONF"

die() { echo "__KIT__-guard: $*" >&2; exit 1; }
have() { nft list table $T >/dev/null 2>&1; }
is4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; }
is6() { [[ "$1" =~ ^[0-9a-fA-F:]*:[0-9a-fA-F:]*(/[0-9]{1,3})?$ ]] && [[ "$1" == *:*:* ]]; }
fam() { if is4 "$1"; then echo 4; elif is6 "$1"; then echo 6; fi; }

ssh_ports() {
    {
        systemctl is-active --quiet ssh.socket 2>/dev/null && \
            systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE '[0-9]+ \(Stream\)' | awk '{print $1}'
        command -v sshd >/dev/null && sshd -T 2>/dev/null | awk '$1=="port"{print $2}'
        ss -Hltnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}'
    } | grep -E '^[0-9]+$' | sort -un
}

open_ports() {
    {
        ss -Hltn 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|\[::ffff:127\.)' | awk -F: '{print $NF}'
        ssh_ports
        for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
            [ -r "$f" ] && awk '/^### tuple ### (allow|limit) (tcp|any) /{print $6}' "$f"
        done
        nft list set $T ssh_tcp 2>/dev/null | grep -oE 'elements = \{[^}]*' | grep -oE '[0-9]+(-[0-9]+)?'
        printf '%s\n' ${GUARD_EXTRA_TCP//,/ }
    } | tr ',' '\n' | tr ':' '-' | grep -E '^[0-9]{1,5}(-[0-9]{1,5})?$' | sort -u
}

sticky_ports() {
    local seen="$STATE/ports.seen" now
    now=$(date +%s)
    {
        [ -f "$seen" ] && awk -v now="$now" '$2 > now - 86400' "$seen"
        open_ports | awk -v now="$now" '{print $1, now}'
    } | sort -k1,1 -k2,2nr | awk '!s[$1]++' >"$seen.tmp" && mv -f "$seen.tmp" "$seen"
    awk '{print $1}' "$seen" | sort -u
}

cmd_sync() {
    have || return 0
    local o s key
    o=$(sticky_ports | paste -sd, -)
    s=$( { ssh_ports; nft list set $T ssh_tcp 2>/dev/null | grep -oE 'elements = \{[^}]*' | grep -oE '[0-9]+'; } | sort -un | paste -sd, -)
    [ -n "$s" ] || s=22
    key="$o|$s"
    [ "${1:-}" != "-f" ] && [ "$key" = "$(cat "$PORTS_RUN" 2>/dev/null)" ] && return 0
    {
        echo "flush set $T open_tcp"
        [ -n "$o" ] && echo "add element $T open_tcp { $o }"
        echo "flush set $T ssh_tcp"
        echo "add element $T ssh_tcp { $s }"
    } | nft -f - && echo "$key" >"$PORTS_RUN"
}

cmd_allow() {
    local ip="${1:-}" f; f=$(fam "$ip"); [ -n "$f" ] || die "не IP/CIDR: $ip"
    touch "$ALLOW"; chmod 600 "$ALLOW"
    grep -qxF "$ip" "$ALLOW" || echo "$ip" >>"$ALLOW"
    have && nft add element $T "wl$f" "{ $ip }"
    nft delete element $T "ban$f" "{ $ip }" 2>/dev/null
    nft delete element $T "sus$f" "{ $ip }" 2>/dev/null
    if [ "$f" = 4 ]; then nft add element ip crowdsec rnt_wl "{ $ip }" 2>/dev/null
    else nft add element ip6 crowdsec6 rnt_wl "{ $ip }" 2>/dev/null; fi
    echo "в белом списке: $ip"
}

cmd_unallow() {
    local ip="${1:-}" f; f=$(fam "$ip"); [ -n "$f" ] || die "не IP/CIDR: $ip"
    [ -f "$ALLOW" ] && { grep -vxF "$ip" "$ALLOW" >"$ALLOW.tmp"; mv -f "$ALLOW.tmp" "$ALLOW"; chmod 600 "$ALLOW"; }
    nft delete element $T "wl$f" "{ $ip }" 2>/dev/null
    if [ "$f" = 4 ]; then nft delete element ip crowdsec rnt_wl "{ $ip }" 2>/dev/null
    else nft delete element ip6 crowdsec6 rnt_wl "{ $ip }" 2>/dev/null; fi
    echo "убран из белого списка: $ip"
}

cmd_ban() {
    local ip="${1:-}" t="${2:-}" f; f=$(fam "$ip"); [ -n "$f" ] || die "не IP: $ip"
    [[ "$ip" == */* ]] && die "бан — только для одного адреса (подсеть — в «Свои адреса» блок-листов)"
    have || die "защита не установлена"
    [[ -z "$t" || "$t" =~ ^[0-9]+[smhd]$ ]] || die "время: 30m, 12h, 7d"
    nft add element $T "ban$f" "{ $ip${t:+ timeout $t} }" && echo "забанен: $ip${t:+ на $t}"
}

cmd_unban() {
    local ip="${1:-}" f; f=$(fam "$ip"); [ -n "$f" ] || die "не IP: $ip"
    nft delete element $T "ban$f" "{ $ip }" 2>/dev/null
    nft delete element $T "sus$f" "{ $ip }" 2>/dev/null
    command -v cscli >/dev/null && cscli decisions delete --ip "$ip" >/dev/null 2>&1
    echo "разбанен: $ip"
}

set_elems() {
    if command -v jq >/dev/null; then
        nft -j list set $T "$1" 2>/dev/null | jq -r '.nftables[] | select(.set) | .set.elem[]? |
            if type == "object" then "\(.elem.val) \(.elem.expires // 0)" else "\(.) 0" end' 2>/dev/null
    else
        nft list set $T "$1" 2>/dev/null | tr ',{}' '\n\n\n' | awk '/expires/{print $1, $5}'
    fi
}

set_count() {
    nft -j list set $T "$1" 2>/dev/null | jq '[.nftables[] | select(.set) | .set.elem[]?] | length' 2>/dev/null || echo 0
}

cmd_bans() {
    have || die "защита не установлена"
    local s ip left
    for s in ban4 ban6; do
        set_elems "$s" | while read -r ip left; do
            [ -n "$ip" ] && printf '%-40s %s\n' "$ip" "$( [ "${left:-0}" -gt 0 ] 2>/dev/null && printf 'ещё %dч %02dм' $((left/3600)) $((left%3600/60)) || echo "$left")"
        done
    done
}

cmd_save_bans() {
    have || return 0
    local s ip left
    rm -rf "$STATE/saved"; mkdir -p "$STATE/saved"
    for s in ban4 ban6 $(nft list sets table $T 2>/dev/null | awk '$1=="set" && $2 ~ /^hit_/ {print $2}'); do
        set_elems "$s" | while read -r ip left; do
            [[ "$left" =~ ^[0-9]+$ ]] && [ "$left" -gt 60 ] && echo "add element $T $s { $ip timeout ${left}s }"
        done >"$STATE/saved/$s.nft"
        [ -s "$STATE/saved/$s.nft" ] || rm -f "$STATE/saved/$s.nft"
    done
    chmod -R go-rwx "$STATE/saved"
}

cmd_load_saved() {
    local f s
    for f in "$STATE"/saved/*.nft; do
        [ -f "$f" ] || continue
        s=$(basename "$f" .nft)
        nft list set $T "$s" >/dev/null 2>&1 && nft -f "$f" 2>/dev/null
    done
    rm -rf "$STATE/saved"
}

bl_ids()  { { awk -F'|' '!/^#/ && $2=="on" {print $1}' "$LISTS" 2>/dev/null; echo local; } | grep -E '^[a-z0-9]{1,10}$'; }
bl_urls() { awk -F'|' -v id="$1" '$1==id {print $4}' "$LISTS" 2>/dev/null; }
bl_fetch() { curl -fsSL --proto '=https' --proto-redir '=https' --max-time 90 --max-filesize 52428800 "$1"; }

meta_get() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$LDIR/$1.meta" 2>/dev/null; }
meta_set() {
    local id="$1" st="$2" msg="$3" up tot
    up=$(meta_get "$id" updated); tot=$(meta_get "$id" total)
    if [ "$st" = ok ]; then up=$(date +%s); tot=$(cat "$LDIR/$id.v4" "$LDIR/$id.v6" 2>/dev/null | grep -c .); fi
    printf 'updated=%s\nstatus=%s\ntotal=%s\nmsg=%s\n' "${up:-0}" "$st" "${tot:-0}" "$msg" >"$LDIR/$id.meta"
}

bl_parse() {
    awk -v v4="$2.raw" -v v6="$3.raw" '
    function ip2n(s,  a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
    function bad(lo, hi) {
        return (lo <= 16777215) || (lo <= 184549375 && hi >= 167772160) || (lo <= 1686110207 && hi >= 1681915904) ||
               (lo <= 2147483647 && hi >= 2130706432) || (lo <= 2852061183 && hi >= 2851995648) ||
               (lo <= 2887778303 && hi >= 2886729728) || (lo <= 3232301055 && hi >= 3232235520) || (hi >= 3758096384)
    }
    BEGIN { printf "" > v4; printf "" > v6 }
    {
        line = $0; t = ""
        if (match(line, /"cidr"[ ]*:[ ]*"[^"]+"/)) {
            t = substr(line, RSTART, RLENGTH); sub(/^"cidr"[ ]*:[ ]*"/, "", t); sub(/"$/, "", t)
        } else {
            sub(/[#;].*/, "", line); gsub(/^[ \t\r]+/, "", line); split(line, f, /[ \t\r,]+/); t = f[1]
        }
        if (t ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) {
            n = split(t, p, "/"); m = (n == 2 ? p[2] + 0 : 32)
            split(p[1], o, ".")
            if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255 || m < 8 || m > 32) next
            s = 2 ^ (32 - m); lo = ip2n(p[1]); lo = lo - (lo % s); hi = lo + s - 1
            if (!bad(lo, hi)) printf("%.0f %.0f %d\n", lo, hi, m) > v4
        } else if (t ~ /^[0-9a-fA-F:]+(\/[0-9]+)?$/ && t ~ /:.*:/) {
            n = split(t, p, "/"); m = (n == 2 ? p[2] + 0 : 128); t = tolower(t)
            if (m < 19 || m > 128 || t ~ /^(fe[89ab]|f[cd]|ff|::)/) next
            print t > v6
        }
    }' "$1"
    sort -n -k1,1 -k2,2nr "$2.raw" | awk '
        function n2ip(n) { return int(n / 16777216) "." int(n / 65536) % 256 "." int(n / 256) % 256 "." n % 256 }
        NR == 1 || $1 > end { print ($3 == 32 ? n2ip($1) : n2ip($1) "/" $3); end = $2 }' >"$2"
    sort -u "$3.raw" >"$3"
    rm -f "$2.raw" "$3.raw"
}

bl_load_one() {
    local id="$1" v f e
    have || return 0
    nft list set $T "bl_${id}_4" >/dev/null 2>&1 || { echo "$id: в таблице нет набора — примени защиту заново" >&2; return 1; }
    for v in 4 6; do
        f="$LDIR/$id.v$v"
        {
            echo "flush set $T bl_${id}_$v"
            [ -s "$f" ] && awk -v p="add element $T bl_${id}_$v" '
                NR % 1000 == 1 { if (NR > 1) print " }"; printf "%s { %s", p, $0; next }
                { printf ", %s", $0 } END { if (NR) print " }" }' "$f"
        } >"$STATE/load.nft"
        if ! nft -f "$STATE/load.nft" 2>/dev/null; then
            nft flush set $T "bl_${id}_$v" 2>/dev/null
            while read -r e; do nft add element $T "bl_${id}_$v" "{ $e }" 2>/dev/null; done <"$f"
        fi
    done
    rm -f "$STATE/load.nft"
}

bl_local_build() {
    touch "$LOCAL"; chmod 600 "$LOCAL"
    bl_parse "$LOCAL" "$LDIR/local.v4" "$LDIR/local.v6"
    meta_set local ok ""
    bl_load_one local
}

bl_excl_load() {
    have || return 0
    nft list set $T blx4 >/dev/null 2>&1 || return 0
    local e f
    { echo "flush set $T blx4"; echo "flush set $T blx6"; } | nft -f -
    [ -f "$EXCL" ] || return 0
    while read -r e; do
        f=$(fam "$e"); [ -n "$f" ] && nft add element $T "blx$f" "{ $e }" 2>/dev/null
    done <"$EXCL"
}

bl_update_one() {
    local id="$1" urls u tmp n4 n6 old msg=""
    [ "$id" = local ] && { bl_local_build; return 0; }
    urls=$(bl_urls "$id"); [ -n "$urls" ] || return 0
    tmp=$(mktemp -d)
    for u in $urls; do
        if ! bl_fetch "$u" >>"$tmp/raw"; then msg="не скачался: $u"; break; fi
        echo >>"$tmp/raw"
    done
    if [ -z "$msg" ]; then
        bl_parse "$tmp/raw" "$tmp/v4" "$tmp/v6"
        n4=$(grep -c . "$tmp/v4"); n6=$(grep -c . "$tmp/v6")
        old=$(meta_get "$id" total)
        if [ $(( n4 + n6 )) -eq 0 ]; then
            msg="в ответе нет ни одного адреса — оставлен прежний"
        elif [ "${old:-0}" -ge 50 ] && [ $(( (n4 + n6) * 10 )) -lt "${old:-0}" ]; then
            msg="список сократился с $old до $(( n4 + n6 )) — оставлен прежний"
        fi
    fi
    if [ -n "$msg" ]; then
        rm -rf "$tmp"; meta_set "$id" fail "$msg"; echo "$id: $msg" >&2
        [ -s "$LDIR/$id.v4" ] || [ -s "$LDIR/$id.v6" ] && bl_load_one "$id"
        return 1
    fi
    install -m 600 "$tmp/v4" "$LDIR/$id.v4"
    install -m 600 "$tmp/v6" "$LDIR/$id.v6"
    rm -rf "$tmp"
    meta_set "$id" ok ""
    bl_load_one "$id"
}

cmd_bl_update() {
    local id ok=0 bad=0 ids
    case "${1:-}" in
        "") ids=$(bl_ids) ;;
        missing) ids=$(for id in $(bl_ids); do [ -f "$LDIR/$id.meta" ] || echo "$id"; done) ;;
        *) ids="$1" ;;
    esac
    for id in $ids; do
        if bl_update_one "$id"; then ok=$(( ok + 1 )); else bad=$(( bad + 1 )); fi
    done
    bl_excl_load
    echo "списков обновлено: $ok, с ошибкой: $bad"
    [ "$bad" -eq 0 ]
}

cmd_bl_load() {
    local id
    for id in $(bl_ids); do
        if [ "$id" = local ]; then bl_local_build; else bl_load_one "$id"; fi
    done
    bl_excl_load
}

cmd_bl_test() {
    local u="${1:-}" tmp n4 n6
    [[ "$u" =~ ^https:// ]] || die "нужна ссылка https://"
    tmp=$(mktemp -d)
    if ! bl_fetch "$u" >"$tmp/raw" 2>/dev/null; then rm -rf "$tmp"; echo "не скачивается (проверь ссылку)"; exit 1; fi
    bl_parse "$tmp/raw" "$tmp/v4" "$tmp/v6"
    n4=$(grep -c . "$tmp/v4"); n6=$(grep -c . "$tmp/v6"); rm -rf "$tmp"
    [ $(( n4 + n6 )) -gt 0 ] || { echo "в файле нет IP-адресов или подсетей"; exit 1; }
    echo "$n4 IPv4, $n6 IPv6"
}

cmd_listfile() {
    local which="$1" act="${2:-}" ip="${3:-}" file
    [ -n "$(fam "$ip")" ] || die "не IP/CIDR: $ip"
    if [ "$which" = local ]; then file="$LOCAL"; else file="$EXCL"; fi
    touch "$file"; chmod 600 "$file"
    case "$act" in
        add) grep -qxF "$ip" "$file" || echo "$ip" >>"$file" ;;
        del) grep -vxF "$ip" "$file" >"$file.tmp"; mv -f "$file.tmp" "$file"; chmod 600 "$file" ;;
        *) die "add или del" ;;
    esac
    if [ "$which" = local ]; then bl_local_build; else bl_excl_load; fi
    if [ "$which" = local ]; then
        [ "$act" = add ] && echo "заблокирован: $ip" || echo "убран из своих адресов: $ip"
    else
        [ "$act" = add ] && echo "в исключениях: $ip" || echo "убран из исключений: $ip"
    fi
}

cmd_lists() {
    local id on name urls n4 n6 hits pk counters upd st msg
    counters=$(nft list counters table $T 2>/dev/null | awk '/counter/{n=$2} /packets/{print n, $2}')
    {
        grep -vE '^\s*(#|$)' "$LISTS" 2>/dev/null
        echo "local|on|Свои адреса|"
    } | while IFS='|' read -r id on name urls; do
        [[ "$id" =~ ^[a-z0-9]{1,10}$ ]] || continue
        n4=$(grep -c . "$LDIR/$id.v4" 2>/dev/null); n6=$(grep -c . "$LDIR/$id.v6" 2>/dev/null)
        hits=0; pk=0
        if [ "$on" = on ] && nft list set $T "hit_${id}_4" >/dev/null 2>&1; then
            hits=$(( $(set_count "hit_${id}_4") + $(set_count "hit_${id}_6") ))
            pk=$(awk -v k="c_bl_$id" '$1==k{print $2}' <<<"$counters")
        fi
        upd=$(meta_get "$id" updated); st=$(meta_get "$id" status); msg=$(meta_get "$id" msg)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$on" "${name:-$id}" "${n4:-0}" "${n6:-0}" "${hits:-0}" "${pk:-0}" \
            "${upd:-0}" "${st:-new}" "${msg:--}"
    done
}

cmd_restore() {
    have || return 0
    local ip f
    if [ -f "$ALLOW" ]; then
        while read -r ip; do
            f=$(fam "$ip"); [ -n "$f" ] && nft add element $T "wl$f" "{ $ip }" 2>/dev/null
        done <"$ALLOW"
    fi
    cmd_sync -f
    cmd_load_saved
    [ "${GUARD_BL:-0}" = 1 ] && cmd_bl_load
    return 0
}

cmd_status() {
    have || { echo "защита не активна"; return 1; }
    nft list counters table $T 2>/dev/null | awk '/counter/{n=$2} /packets/{print n, $2}'
    printf 'bans %s\n' "$(cmd_bans 2>/dev/null | wc -l)"
    printf 'suspects %s\n' "$( { set_elems sus4; set_elems sus6; } | grep -c .)"
    local n; n=$(grep -c . "$ALLOW" 2>/dev/null); printf 'allow %s\n' "${n:-0}"
}

case "${1:-}" in
    sync)       cmd_sync "${2:-}" ;;
    restore)    cmd_restore ;;
    allow)      cmd_allow "${2:-}" ;;
    unallow)    cmd_unallow "${2:-}" ;;
    ban)        cmd_ban "${2:-}" "${3:-}" ;;
    unban)      cmd_unban "${2:-}" ;;
    bans)       cmd_bans ;;
    allowlist)  cat "$ALLOW" 2>/dev/null ;;
    save-bans)  cmd_save_bans ;;
    status)     cmd_status ;;
    lists)      cmd_lists ;;
    local|exclude) cmd_listfile "$1" "${2:-}" "${3:-}" ;;
    blocklist)
        case "${2:-load}" in
            update) cmd_bl_update "${3:-}" ;;
            test)   cmd_bl_test "${3:-}" ;;
            *)      cmd_bl_load ;;
        esac ;;
    *) sed -n '2,5p' "$0"; exit 2 ;;
esac
HELPER
    chmod 755 "$GUARD_BIN"
}

guard_write_units() {
    cat >"$GUARD_UNIT" <<EOF
[Unit]
Description=$KIT_NAME: nftables-защита (таблица $GUARD_TABLE)
DefaultDependencies=no
After=local-fs.target nftables.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $GUARD_NFT
ExecStartPost=$GUARD_BIN restore
ExecStop=$GUARD_BIN save-bans
ExecStop=/bin/sh -c '/usr/sbin/nft delete table $GUARD_TABLE 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    cat >"$GUARD_SYNC_UNIT.service" <<EOF
[Unit]
Description=$KIT_NAME: синхронизация открытых портов (новые инбаунды)
[Service]
Type=oneshot
ExecStart=$GUARD_BIN sync
EOF
    cat >"$GUARD_SYNC_UNIT.timer" <<EOF
[Unit]
Description=$KIT_NAME: синхронизация открытых портов раз в минуту
[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=10s
[Install]
WantedBy=timers.target
EOF
    if guard_has bl; then
        cat >"$GUARD_BL_UNIT.service" <<EOF
[Unit]
Description=$KIT_NAME: обновление блок-листов
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$GUARD_BIN blocklist update
EOF
        cat >"$GUARD_BL_UNIT.timer" <<EOF
[Unit]
Description=$KIT_NAME: обновление блок-листов ($(bl_every_label))
[Timer]
OnBootSec=5min
OnUnitActiveSec=$(bl_every)h
RandomizedDelaySec=5min
[Install]
WantedBy=timers.target
EOF
    else
        systemctl disable --now "$KIT_NAME-guard-blocklist.timer" >/dev/null 2>&1 || true
        rm -f "$GUARD_BL_UNIT.service" "$GUARD_BL_UNIT.timer"
    fi
    systemctl daemon-reload
}

guard_write_conf() {
    {
        printf 'GUARD_EXTRA_TCP=%q\n' "${GUARD_EXTRA_TCP:-}"
        printf 'GUARD_BL=%q\n' "$(guard_has bl && echo 1 || echo 0)"
    } >"$GUARD_CONF"
    chmod 600 "$GUARD_CONF"
}

guard_arm_safety() {
    systemctl stop "$KIT_NAME-guard-safety.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "$KIT_NAME-guard-safety.service" >/dev/null 2>&1 || true
    systemd-run --quiet --unit="$KIT_NAME-guard-safety" --on-active="${1:-120}s" \
        /bin/sh -c "/usr/sbin/nft delete table $GUARD_TABLE 2>/dev/null; systemctl disable $KIT_NAME-guard.service; logger -t $KIT_NAME 'safety: защита снята, доступ не подтверждён'" \
        >/dev/null 2>&1
}
guard_disarm_safety() { systemctl stop "$KIT_NAME-guard-safety.timer" >/dev/null 2>&1 || true; }

guard_apply_files() {
    local sshp="$1" tmp
    guard_has bl && bl_init_conf
    tmp=$(mktemp)
    guard_render "$tmp" "$sshp"
    if ! nft -c -f "$tmp" >>"$LOG_FILE" 2>&1; then
        cp "$tmp" "$STATE_DIR/guard.nft.failed" 2>/dev/null || true
        rm -f "$tmp"
        echo "nft -c не прошёл, правила не применены (копия: $STATE_DIR/guard.nft.failed)"
        return 1
    fi
    mkdir -p "$CONF_DIR"
    install -m 600 "$tmp" "$GUARD_NFT"
    rm -f "$tmp"
    guard_write_conf
    guard_write_helper
    guard_write_units
}

guard_load() {
    guard_active && "$GUARD_BIN" save-bans
    nft -f "$GUARD_NFT" || return 1
    "$GUARD_BIN" restore
    systemctl enable "$KIT_NAME-guard.service" >/dev/null 2>&1
    systemctl enable --now "$KIT_NAME-guard-sync.timer" >/dev/null 2>&1
    if guard_has bl; then
        systemctl enable --now "$KIT_NAME-guard-blocklist.timer" >/dev/null 2>&1
        "$GUARD_BIN" blocklist update missing || true
    fi
    return 0
}

action_guard_apply() {
    ui_screen "Защита сервера (nftables)"
    guard_defaults
    local me sshp wan
    me=$(ssh_client_ip); sshp=$(ssh_ports); wan=$(wan_iface)

    ui_box_top "Сервер"
    ui_kv "Интерфейс" "${wan:-?}"
    ui_kv "SSH-порты" "${C_B}$sshp${C_RST}"
    ui_kv "Ваш IP" "${me:-не определён (консоль?)}"
    ui_kv "Панель" "${PANEL_IP:-не задана}"
    ui_kv "ufw" "$(has ufw && ufw status 2>/dev/null | grep -q 'Status: active' && ui_badge_ok активен || ui_badge_warn "выключен — порты не закрыты")"
    ui_box_bottom
    note "Эта защита не закрывает порты (это делает ufw), а режет атаки на открытые."
    echo

    local wl="${GUARD_WHITELIST:-}" e
    for e in ${PANEL_IP//,/ } $me; do
        [[ ",$wl," == *",$e,"* ]] || wl="${wl:+$wl,}$e"
    done
    GUARD_WHITELIST="$wl"
    ui_input GUARD_WHITELIST "Белый список (IP/CIDR через запятую)" "$GUARD_WHITELIST" valid_ip_list \
        "адреса панели, мониторинга и ваш — они обходят все лимиты, баны и блок-листы" || { cfg_revert; return 0; }
    GUARD_WHITELIST="${GUARD_WHITELIST// /}"
    echo

    local feats
    ui_checklist feats "Что включить" \
        "scan|Анти-скан портов|$(guard_has scan && echo on || echo off)|SYN на закрытые порты: подозрение, при продолжении — бан" \
        "ssh|Защита SSH от перебора|$(guard_has ssh && echo on || echo off)|больше $GUARD_SSH_RATE подключений в минуту с IP — сначала drop, потом бан" \
        "syn|Лимит SYN-флуда с одного IP|$(guard_has syn && echo on || echo off)|$GUARD_SYN_RATE новых соединений/с с адреса, лишнее отбрасывается без бана" \
        "icmp|Лимит пинга|$(guard_has icmp && echo on || echo off)|не больше 10 ICMP echo в секунду с адреса" \
        "bl|Блок-листы IP|$(guard_has bl && echo on || echo off)|адреса из списков (госсети, СКИПА, сканеры, Spamhaus…) блокируются полностью" \
        "conn|Лимит соединений с одного IP|$(guard_has conn && echo on || echo off)|осторожно: мобильные операторы держат тысячи абонентов за одним IP" \
        || { cfg_revert; return 0; }
    GUARD_FEATURES="${feats:-none}"
    if guard_has conn; then
        [ "${GUARD_CONNLIMIT:-0}" -gt 0 ] || GUARD_CONNLIMIT=1000
        ui_input GUARD_CONNLIMIT "Максимум соединений с одного IP" "$GUARD_CONNLIMIT" valid_port || { cfg_revert; return 0; }
    fi
    local bt
    ui_menu bt "Срок бана" -d "$GUARD_BAN_TIME" \
        "1h|1 час||" "1d|1 сутки|рекомендуется|" "7d|7 дней||" || { cfg_revert; return 0; }
    GUARD_BAN_TIME="$bt"
    guard_has bl && note "Какие именно списки блокировать — пункт «Блок-листы» в меню защиты."

    echo
    ui_confirm "Применить защиту?" y || { cfg_revert; UI_LAST=no; return 0; }
    cfg_save
    echo
    pb_init $(( 12 + $(guard_has bl && echo 10 || echo 0) ))
    has nft || step 4 "Установка nftables" "apt-get ${APT_OPTS[*]} install nftables"
    has jq || step 2 "Установка jq" "apt-get ${APT_OPTS[*]} install jq"
    stepf 3 "Генерация и проверка правил (nft -c)" guard_apply_files "$sshp"

    ( umask 077; tr ',' '\n' <<<"$GUARD_WHITELIST" | grep -v '^$' | sort -u >"$GUARD_ALLOW" )

    local safe=0
    if has systemd-run && [ -n "$me" ]; then
        guard_arm_safety 120 && safe=1
    fi
    stepf "$(guard_has bl && echo 13 || echo 3)" "Загрузка таблицы$(guard_has bl && echo " и блок-листов")" guard_load
    pb_end 2>/dev/null || true

    if [ "$safe" -eq 1 ]; then
        echo
        ui_alert "Проверь доступ" \
            "Открой НОВОЕ SSH-подключение к серверу (текущее не рвётся)." \
            "Если войти не получится — через 2 минуты защита снимется сама."
        if ui_confirm_timeout "Новое подключение работает?" 110; then
            guard_disarm_safety
            ok "Защита активна и закреплена (переживёт перезагрузку)"
        else
            warn "Подтверждения нет — снимаю защиту."
            systemctl start "$KIT_NAME-guard-safety.service" >/dev/null 2>&1 || nft delete table $GUARD_TABLE 2>/dev/null || true
            systemctl disable "$KIT_NAME-guard.service" >/dev/null 2>&1 || true
            return 0
        fi
    else
        ok "Защита активна (переживёт перезагрузку)"
    fi
    guard_status
}

guard_status() {
    echo
    ui_box_top "Защита"
    if ! guard_active; then
        ui_kv "nftables" "$(ui_badge_off "не активна")"
    else
        local st c n lists bl_pk bl_hits bl_n
        st=$("$GUARD_BIN" status 2>/dev/null || true)
        ui_kv "nftables" "$(ui_badge_ok "активна")  ${C_DIM}таблица $GUARD_TABLE${C_RST}"
        ui_kv "Функции" "${GUARD_FEATURES:-?}"
        ui_kv "Баны" "${C_B}$(awk '$1=="bans"{print $2}' <<<"$st")${C_RST}  ${C_DIM}подозреваемых $(awk '$1=="suspects"{print $2}' <<<"$st"), в белом списке $(awk '$1=="allow"{print $2}' <<<"$st")${C_RST}"
        if guard_has bl; then
            lists=$("$GUARD_BIN" lists 2>/dev/null)
            bl_n=$(awk -F'\t' '$2=="on"' <<<"$lists" | wc -l)
            bl_hits=$(awk -F'\t' '{s+=$6} END{print s+0}' <<<"$lists")
            bl_pk=$(awk -F'\t' '{s+=$7} END{print s+0}' <<<"$lists")
            ui_kv "Блок-листы" "${C_B}$bl_hits${C_RST} адр. за сутки, $bl_pk пакетов  ${C_DIM}списков: $bl_n${C_RST}"
        fi
        ui_box_sep "отброшено пакетов"
        for c in c_scan:Скан c_ssh:"Перебор SSH" c_synflood:SYN-флуд c_icmp:"ICMP-флуд" c_badflags:"Мусорные флаги" c_invalid:Invalid c_ban:"От забаненных" c_connlimit:"Лимит соединений"; do
            n=$(awk -v k="${c%%:*}" '$1==k{print $2}' <<<"$st")
            ui_kv "${c#*:}" "${n:-0}"
        done
    fi
    if has cscli; then
        ui_box_sep "CrowdSec"
        ui_kv "Агент" "$(systemctl is-active --quiet crowdsec && ui_badge_ok работает || ui_badge_err остановлен)"
        ui_kv "Bouncer" "$(systemctl is-active --quiet crowdsec-firewall-bouncer && ui_badge_ok работает || ui_badge_warn "не работает")  ${C_DIM}область: $(cs_scope_current)${C_RST}"
        ui_kv "Решений" "$(cscli decisions list -a -o json 2>/dev/null | jq 'length' 2>/dev/null || echo ?)"
    fi
    [ -f "$SSHD_DROPIN" ] && { ui_box_sep "SSH"; ui_kv "sshd" "$(ui_badge_ok "укреплён")  ${C_DIM}$SSHD_DROPIN${C_RST}"; }
    ui_box_bottom
    if guard_active && guard_has bl; then echo; bl_status_box; fi
}

action_guard_allow() {
    ui_screen "Белый список"
    if [ -s "$GUARD_ALLOW" ]; then
        ui_box_top "Сейчас в белом списке"
        local ip; while read -r ip; do ui_box_line "$ip"; done <"$GUARD_ALLOW"
        ui_box_bottom
    else
        info "Белый список пуст"
    fi
    echo
    local c ip=""
    ui_menu c "Действие" "add|Добавить адрес||" "del|Убрать адрес||" || return 0
    ui_input ip "IP или CIDR" "" valid_ip_or_cidr || return 0
    case "$c" in
        add) "$GUARD_BIN" allow "$ip" ;;
        del) "$GUARD_BIN" unallow "$ip" ;;
    esac
    GUARD_WHITELIST=$(paste -sd, "$GUARD_ALLOW" 2>/dev/null || true)
    cfg_save
}

action_guard_bans() {
    ui_screen "Баны"
    guard_active || { warn "Защита не установлена"; return 0; }
    local list l; list=$("$GUARD_BIN" bans 2>/dev/null || true)
    if [ -n "$list" ]; then
        ui_box_top "Забанены ($(wc -l <<<"$list"))"
        while read -r l; do ui_box_line "$l"; done < <(head -n 30 <<<"$list")
        [ "$(wc -l <<<"$list")" -gt 30 ] && ui_box_line "${C_DIM}… полный список: $KIT_CMD guard bans${C_RST}"
        ui_box_bottom
    else
        ok "Сейчас никто не забанен"
    fi
    echo
    local c ip=""
    ui_menu c "Действие" "unban|Разбанить IP|снимает бан и в CrowdSec|" "ban|Забанить IP вручную|на срок бана; подсеть навсегда — в «Блок-листы → Свои адреса»|" || return 0
    ui_input ip "IP" "" valid_ip_or_cidr || return 0
    case "$c" in
        unban) "$GUARD_BIN" unban "$ip" ;;
        ban)   "$GUARD_BIN" ban "$ip" "${GUARD_BAN_TIME:-1d}" ;;
    esac
}

guard_rollback() {
    systemctl disable --now "$KIT_NAME-guard-sync.timer" "$KIT_NAME-guard-blocklist.timer" >/dev/null 2>&1 || true
    systemctl disable "$KIT_NAME-guard.service" >/dev/null 2>&1 || true
    nft delete table $GUARD_TABLE 2>/dev/null || true
    rm -f "$GUARD_UNIT" "$GUARD_SYNC_UNIT".{service,timer} "$GUARD_BL_UNIT".{service,timer} \
          "$GUARD_NFT" "$GUARD_CONF" "$GUARD_BIN" "/run/$KIT_NAME-guard.ports"
    rm -rf "$STATE_DIR/guard"
    systemctl daemon-reload
    return 0
}

ssh_has_keys() {
    local u="${SUDO_USER:-root}" home f
    home=$(getent passwd "$u" | cut -d: -f6)
    for f in "$home/.ssh/authorized_keys" /root/.ssh/authorized_keys; do
        [ -f "$f" ] && grep -qE '^[^#]*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) AAAA' "$f" && return 0
    done
    return 1
}

action_ssh_harden() {
    ui_screen "Укрепление SSH"
    if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        err "/etc/ssh/sshd_config не подключает sshd_config.d — правка невозможна без изменения основного файла."
        return 0
    fi
    ui_box_top "Что будет в $SSHD_DROPIN"
    ui_kv "LoginGraceTime" "30 с на вход (было 120)"
    ui_kv "MaxStartups" "10:30:60 — нельзя забить вход пустыми подключениями"
    ui_kv "MaxAuthTries" "4 попытки за подключение"
    ui_kv "Прочее" "без пустых паролей и X11, keepalive 5 мин"
    ui_box_bottom
    echo
    local keyonly=0
    if ssh_has_keys; then
        note "У пользователя есть SSH-ключ — можно запретить вход по паролю."
        if ui_confirm "Вход только по ключу (пароль выключить)?" n; then keyonly=1; fi
    else
        warn "SSH-ключей не найдено — вход по паролю оставляю включённым."
    fi
    ui_confirm "Применить настройки sshd?" y || return 0
    {
        echo "LoginGraceTime 30"
        echo "MaxStartups 10:30:60"
        echo "MaxAuthTries 4"
        echo "PermitEmptyPasswords no"
        echo "X11Forwarding no"
        echo "ClientAliveInterval 300"
        echo "ClientAliveCountMax 3"
        if [ "$keyonly" -eq 1 ]; then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
            echo "PermitRootLogin prohibit-password"
        fi
    } >"$SSHD_DROPIN"
    chmod 644 "$SSHD_DROPIN"
    if ! sshd -t >>"$LOG_FILE" 2>&1; then
        rm -f "$SSHD_DROPIN"
        err "sshd -t нашёл ошибку — файл удалён, ничего не изменилось"
        return 0
    fi
    systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
    ok "sshd укреплён"
    [ "$keyonly" -eq 1 ] && warn "Проверь вход по ключу в НОВОМ окне, пока это не закрыто."
    return 0
}

action_auto_updates() {
    ui_screen "Автообновления безопасности"
    note "Сервер сам ставит патчи безопасности (CVE). Docker и containerd исключены,"
    note "чтобы нода не перезапускалась сама; перезагрузки — только вручную."
    echo
    ui_confirm "Включить автообновления безопасности?" y || return 0
    pb_init 6
    step 4 "Установка unattended-upgrades" "apt-get ${APT_OPTS[*]} install unattended-upgrades"
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    cat >"$UU_CONF" <<'EOF'
// remnanode-tools: обновления безопасности без перезапуска VPN
Unattended-Upgrade::Package-Blacklist {
    "^docker-";
    "^docker\.io$";
    "^containerd";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    if [ -d /etc/needrestart ]; then
        mkdir -p "$(dirname "$NR_CONF")"
        cat >"$NR_CONF" <<'EOF'
$nrconf{override_rc}{qr(^docker)} = 0;
$nrconf{override_rc}{qr(^containerd)} = 0;
EOF
    fi
    step 2 "Включение таймеров apt" \
        "rm -f /etc/apt/apt.conf.d/99-node-no-unattended; systemctl unmask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1; systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service"
    ok "Автообновления безопасности включены"
}

action_protect_rollback() {
    ui_screen "Снять защиту"
    local what
    ui_checklist what "Что убрать" \
        "guard|Таблица nftables и блок-листы|on|правила, таймеры, помощник $KIT_NAME-guard (настройки списков останутся)" \
        "ssh|Настройки sshd|off|удалить $SSHD_DROPIN" \
        "cs|CrowdSec|off|удалить crowdsec и bouncer полностью" || return 0
    [ -n "$what" ] || { info "Ничего не выбрано"; return 0; }
    ui_confirm "Точно убрать: $what?" n || return 0
    [[ " $what " == *" guard "* ]] && { guard_rollback; ok "Таблица nftables и таймеры убраны"; }
    if [[ " $what " == *" ssh "* ]] && [ -f "$SSHD_DROPIN" ]; then
        rm -f "$SSHD_DROPIN"
        systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
        ok "Настройки sshd убраны"
    fi
    [[ " $what " == *" cs "* ]] && cs_remove
    return 0
}

action_protect_menu() {
    local c st bl_badge
    while true; do
        ui_screen "Защита сервера"
        guard_defaults
        if guard_active; then st="$(ui_badge_ok "активна")"; else st="$(ui_badge_off "не установлена")"; fi
        bl_badge=""; guard_active && guard_has bl && bl_badge="$(ui_badge_ok вкл)"
        ui_menu c "Защита  $st" -d apply \
            "apply|Установить / обновить защиту|nftables: анти-скан, перебор SSH, SYN-флуд, ICMP, мусорные пакеты|" \
            "lists|Блок-листы|госсети, СКИПА, сканеры, свои списки по ссылке, свои адреса|$bl_badge" \
            "crowdsec|CrowdSec|поведенческий IPS + общий список атакующих|$(has cscli && ui_badge_ok стоит)" \
            "ssh|Укрепить SSH|лимиты sshd, по желанию вход только по ключу|$([ -f "$SSHD_DROPIN" ] && ui_badge_ok да)" \
            "updates|Автообновления безопасности|патчи CVE сами, docker не трогаем|$(systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null && ui_badge_ok вкл)" \
            "-|управление" \
            "status|Состояние защиты|счётчики, баны, статистика блок-листов|" \
            "allow|Белый список|адреса, которые никогда не банятся и не блокируются|" \
            "bans|Баны|посмотреть, разбанить, забанить|" \
            "rollback|Снять защиту|убрать правила / sshd / CrowdSec|"
        case "$c" in
            apply)    action_guard_apply ;;
            lists)    action_blocklists_menu; continue ;;
            crowdsec) action_crowdsec ;;
            ssh)      action_ssh_harden ;;
            updates)  action_auto_updates ;;
            status)   ui_screen "Защита: состояние"; guard_status ;;
            allow)    action_guard_allow ;;
            bans)     action_guard_bans ;;
            rollback) action_protect_rollback ;;
            *) return 0 ;;
        esac
        ui_done
    done
}
