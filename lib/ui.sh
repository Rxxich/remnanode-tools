# shellcheck shell=bash

UI_FD=""
UI_W=72
UI_ROWS=24
UI_KEY=""
UI_N=0
UI_LINE=""
UI_LAST="ok"

ui_back() { [ "$UI_LAST" = "back" ]; }

ui_init() {
    if [ -z "$UI_FD" ] && { exec {UI_FD}</dev/tty; } 2>/dev/null; then
        :
    elif [ -z "$UI_FD" ]; then
        UI_FD=0
    fi
    ui_resize
    trap 'ui_resize' WINCH
    return 0
}

ui_resize() {
    local c r
    c=$(tput cols 2>/dev/null || echo 80)
    r=$(tput lines 2>/dev/null || echo 24)
    UI_ROWS="${r:-24}"
    UI_W=$(( ${c:-80} - 2 ))
    [ "$UI_W" -gt 78 ] && UI_W=78
    [ "$UI_W" -lt 50 ] && UI_W=50
    kit_changed
    return 0
}

ui_cleanup() {
    printf '\e[?25h' 2>/dev/null || true
    stty echo icanon <&"${UI_FD:-0}" 2>/dev/null || true
}

ui_has_tty() { [ -t "${UI_FD:-0}" ]; }

ui_keys_on()  { printf '\e[?25l'; stty -echo <&"${UI_FD:-0}" 2>/dev/null || true; }
ui_keys_off() { printf '\e[?25h'; stty echo <&"${UI_FD:-0}" 2>/dev/null || true; }

_ui_vlen() {
    local __vs="$1" __vo=""
    while [[ "$__vs" == *$'\e['* ]]; do
        __vo+="${__vs%%$'\e['*}"
        __vs="${__vs#*$'\e['}"
        __vs="${__vs#*m}"
    done
    UI_N=$(( ${#__vo} + ${#__vs} ))
}

_ui_pad() {
    local __pn
    _ui_vlen "$2"
    __pn=$(( $3 - UI_N )); [ "$__pn" -lt 0 ] && __pn=0
    printf -v "$1" '%s%*s' "$2" "$__pn" ''
}

_ui_cut() {
    if [ "${#2}" -gt "$3" ]; then printf -v "$1" '%s…' "${2:0:$(( $3 - 1 ))}"; else printf -v "$1" '%s' "$2"; fi
}

_ui_rep() {
    local __rs=""
    [ "$3" -gt 0 ] && printf -v __rs '%*s' "$3" ''
    printf -v "$1" '%s' "${__rs// /$2}"
}

ui_vlen()   { _ui_vlen "$1"; echo "$UI_N"; }
ui_pad()    { local r; _ui_pad r "$1" "$2"; printf '%s' "$r"; }
ui_cut()    { local r; _ui_cut r "$1" "$2"; printf '%s' "$r"; }
ui_repeat() { local r; _ui_rep r "$1" "$2"; printf '%s' "$r"; }

_ui_row() {
    local __wv="$1" __ws="$2" __wn
    _ui_vlen "$__ws"
    __wn=$(( UI_W - 4 - UI_N )); [ "$__wn" -lt 0 ] && __wn=0
    printf -v __ws '%s%*s' "$__ws" "$__wn" ''
    if [ "${3:-}" = "sel" ] && [ -n "$C_RST" ]; then
        __ws="${__ws//"$C_RST"/"$C_RST$C_SEL"}"
        printf -v "$__wv" '  %s│%s%s%s%s│%s' "$C_MUTED" "$C_RST" "$C_SEL" "$__ws" "$C_RST$C_MUTED" "$C_RST"
    else
        printf -v "$__wv" '  %s│%s%s%s│%s' "$C_MUTED" "$C_RST" "$__ws" "$C_MUTED" "$C_RST"
    fi
}

_ui_readkey() {
    local k="" r="" m=""
    if ! IFS= read -rsn1 k <&"$UI_FD"; then UI_KEY=eof; return 0; fi
    case "$k" in
        $'\e')
            IFS= read -rsn2 -t 0.05 r <&"$UI_FD" || true
            if [[ "$r" =~ ^\[[0-9]$ ]]; then IFS= read -rsn1 -t 0.05 m <&"$UI_FD" || true; r+="$m"; fi
            case "$r" in
                '[A'|'OA') UI_KEY=up ;;
                '[B'|'OB') UI_KEY=down ;;
                '[C'|'OC') UI_KEY=right ;;
                '[D'|'OD') UI_KEY=left ;;
                '[H'|'OH'|'[1~'|'[7~') UI_KEY=home ;;
                '[F'|'OF'|'[4~'|'[8~') UI_KEY=end ;;
                '[5~') UI_KEY=pgup ;;
                '[6~') UI_KEY=pgdn ;;
                '') UI_KEY=esc ;;
                *) UI_KEY=other ;;
            esac ;;
        '') UI_KEY=enter ;;
        ' ') UI_KEY=space ;;
        $'\t') UI_KEY=tab ;;
        $'\x7f'|$'\b') UI_KEY=bs ;;
        *) UI_KEY="ch:$k" ;;
    esac
}
ui_key() { _ui_readkey; echo "$UI_KEY"; }

ui_logo() {
    local grad=(51 45 39 33 63 99) i=0 line out=$'\e[H\e[2J\n'
    local art=(
        '██████╗ ███████╗███╗   ███╗███╗   ██╗ █████╗ '
        '██╔══██╗██╔════╝████╗ ████║████╗  ██║██╔══██╗'
        '██████╔╝█████╗  ██╔████╔██║██╔██╗ ██║███████║'
        '██╔══██╗██╔══╝  ██║╚██╔╝██║██║╚██╗██║██╔══██║'
        '██║  ██║███████╗██║ ╚═╝ ██║██║ ╚████║██║  ██║'
        '╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝'
    )
    [ "${KIT_TTY:-0}" = "1" ] || out=$'\n'
    for line in "${art[@]}"; do
        if [ -n "$C_RST" ]; then out+="   "$'\e[38;5;'"${grad[$i]}m${line}${C_RST}"$'\n'; else out+="   $line"$'\n'; fi
        i=$(( i + 1 ))
    done
    out+="   ${C_ACC2}node toolkit · v$KIT_VERSION${C_RST}  ${C_DIM}·  Debian 12/13 · Ubuntu 24.04${C_RST}"$'\n\n'
    printf '%s' "$out"
}

_ui_box_top() {
    local __tv="$1" __tt="${2:-}" __tc="${3:-$C_MUTED}" __tn __td
    if [ -n "$__tt" ]; then
        _ui_vlen "$__tt"
        __tn=$(( UI_W - UI_N - 7 )); [ "$__tn" -lt 1 ] && __tn=1
        _ui_rep __td ─ "$__tn"
        printf -v "$__tv" '  %s╭─%s %s%s%s %s%s╮%s' "$__tc" "$C_RST" "$C_B" "$__tt" "$C_RST" "$__tc" "$__td" "$C_RST"
    else
        _ui_rep __td ─ $(( UI_W - 4 ))
        printf -v "$__tv" '  %s╭%s╮%s' "$__tc" "$__td" "$C_RST"
    fi
}
_ui_box_bottom() {
    local __bd; _ui_rep __bd ─ $(( UI_W - 4 ))
    printf -v "$1" '  %s╰%s╯%s' "${2:-$C_MUTED}" "$__bd" "$C_RST"
}
_ui_box_sep() {
    local __sv="$1" __st="${2:-}" __sn __sd
    if [ -n "$__st" ]; then
        __sn=$(( UI_W - 10 - ${#__st} )); [ "$__sn" -lt 1 ] && __sn=1
        _ui_rep __sd ─ "$__sn"
        _ui_row "$__sv" " ${C_MUTED}── ${C_DIM}${__st}${C_MUTED} ${__sd}${C_RST}"
    else
        _ui_rep __sd ─ $(( UI_W - 6 ))
        _ui_row "$__sv" " ${C_MUTED}${__sd}${C_RST}"
    fi
}

ui_box_top()    { local r; UI_LAST=ok; _ui_box_top r "${1:-}"; printf '%s\n' "$r"; }
ui_box_bottom() { local r; _ui_box_bottom r; printf '%s\n' "$r"; }
ui_box_sep()    { local r; _ui_box_sep r "${1:-}"; printf '%s\n' "$r"; }
ui_box_line()   { local r; _ui_row r " ${1:-}"; printf '%s\n' "$r"; }

ui_kv() {
    local k="$1" v="$2" kw=15 n r
    n=$(( kw - ${#k} )); [ "$n" -lt 1 ] && n=1
    printf -v r '%s%s%s%*s%s' "$C_DIM" "$k" "$C_RST" "$n" '' "$v"
    ui_box_line "$r"
}

ui_badge_ok()   { printf '%s● %s%s' "$C_OK" "$1" "$C_RST"; }
ui_badge_warn() { printf '%s● %s%s' "$C_WARN" "$1" "$C_RST"; }
ui_badge_err()  { printf '%s● %s%s' "$C_ERR" "$1" "$C_RST"; }
ui_badge_off()  { printf '%s○ %s%s' "$C_DIM" "$1" "$C_RST"; }

ui_alert() {
    local t="$1" l r cw=$(( UI_W - 4 )) n; shift
    UI_LAST=ok
    _ui_box_top r "${C_WARN}▲ $t${C_RST}" "$C_WARN"; printf '%s\n' "$r"
    for l in "$@"; do
        _ui_vlen " $l"; n=$(( cw - UI_N )); [ "$n" -lt 0 ] && n=0
        printf '  %s│%s %s%*s%s│%s\n' "$C_WARN" "$C_RST" "$l" "$n" '' "$C_WARN" "$C_RST"
    done
    _ui_box_bottom r "$C_WARN"; printf '%s\n' "$r"
}

ui_menu() {
    local __out="$1" ttl="$2"; shift 2
    local def="" foot="↑↓ выбор   Enter открыть   1-9 быстро   Esc назад"
    while [ $# -gt 0 ]; do
        case "$1" in
            -d) def="$2"; shift 2 ;;
            -f) foot="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    local items=("$@") n=$# i
    local keys=() labels=() descs=() badges=() sel_idx=()
    for (( i = 0; i < n; i++ )); do
        IFS='|' read -r "keys[i]" "labels[i]" "descs[i]" "badges[i]" <<<"${items[$i]}"
        [ "${keys[$i]}" != "-" ] && sel_idx+=("$i")
    done
    [ "${#sel_idx[@]}" -eq 0 ] && { printf -v "$__out" '%s' ""; UI_LAST=back; return 1; }

    if ! ui_has_tty; then
        _ui_menu_plain "$__out" "$ttl"
        if [ -n "${!__out}" ]; then UI_LAST=ok; return 0; fi
        UI_LAST=back; return 1
    fi

    local cw=$(( UI_W - 4 )) row_on=() row_off=() dsc=() num=0 lab bad bw lw left pad s
    for (( i = 0; i < n; i++ )); do
        if [ "${keys[$i]}" = "-" ]; then
            _ui_box_sep s "${labels[$i]}"
            row_on[i]="$s"; row_off[i]="$s"
            continue
        fi
        num=$(( num + 1 ))
        bad="${badges[$i]:-}"
        _ui_vlen "$bad"; bw=$UI_N
        lw=$(( cw - 6 - bw - 2 ))
        _ui_cut lab "${labels[$i]}" "$lw"
        pad=$(( cw - 4 - ${#lab} - bw - 2 )); [ "$pad" -lt 1 ] && pad=1
        printf -v left '%s%s ❯ %s%s%s %s%*s%s  ' "$C_ACC" "$C_B" "$C_RST" "$C_B" "$C_TXT" "$lab" "$pad" '' "$C_RST$bad"
        _ui_row s "$left" sel; row_on[i]="$s"
        if [ "$num" -le 9 ]; then
            printf -v left ' %s%s%s  %s%s%*s%s%s  ' "$C_MUTED" "$num" "$C_RST" "$C_TXT" "$lab" "$pad" '' "$C_RST" "$bad"
        else
            printf -v left '    %s%s%*s%s%s  ' "$C_TXT" "$lab" "$pad" '' "$C_RST" "$bad"
        fi
        _ui_row s "$left"; row_off[i]="$s"
        _ui_cut s "${descs[$i]:-}" $(( UI_W - 6 ))
        dsc[i]="$s"
    done
    local top_line bot_line
    _ui_box_top top_line "$ttl"
    _ui_box_bottom bot_line

    local cur=0 j
    if [ -n "$def" ]; then
        for j in "${!sel_idx[@]}"; do [ "${keys[${sel_idx[$j]}]}" = "$def" ] && cur=$j; done
    fi

    local maxv=$(( UI_ROWS - 9 )); [ "$maxv" -lt 5 ] && maxv=5
    local top=0 view=$n
    [ "$view" -gt "$maxv" ] && view=$maxv

    local drawn=0 frame r ci more cnt="${#sel_idx[@]}" EL=$'\r\e[2K'
    ui_keys_on
    while true; do
        ci="${sel_idx[$cur]}"
        if [ "$n" -gt "$view" ]; then
            [ "$ci" -lt "$top" ] && top=$ci
            [ "$ci" -ge $(( top + view )) ] && top=$(( ci - view + 1 ))
        fi
        frame=""
        [ "$drawn" -gt 0 ] && frame+=$'\e['"${drawn}A"
        frame+="$EL$top_line"$'\n'
        drawn=1
        for (( r = top; r < top + view && r < n; r++ )); do
            if [ "$r" -eq "$ci" ]; then frame+="$EL${row_on[$r]}"$'\n'; else frame+="$EL${row_off[$r]}"$'\n'; fi
            drawn=$(( drawn + 1 ))
        done
        more=""
        [ "$n" -gt "$view" ] && more="  ${C_DIM}[$(( top + 1 ))–$(( top + view > n ? n : top + view )) из $n]${C_RST}"
        frame+="$EL$bot_line"$'\n'"$EL    ${C_ACC2}${dsc[$ci]:-}${C_RST}"$'\n'"$EL    ${C_DIM}${foot}${C_RST}${more}"$'\n'
        drawn=$(( drawn + 3 ))
        printf '%s' "$frame"

        _ui_readkey
        case "$UI_KEY" in
            up|ch:k|ch:K)       cur=$(( cur > 0 ? cur - 1 : cnt - 1 )) ;;
            down|ch:j|ch:J|tab) cur=$(( cur < cnt - 1 ? cur + 1 : 0 )) ;;
            home|ch:g)          cur=0 ;;
            end|ch:G)           cur=$(( cnt - 1 )) ;;
            pgup)               cur=$(( cur - view < 0 ? 0 : cur - view )) ;;
            pgdn)               cur=$(( cur + view >= cnt ? cnt - 1 : cur + view )) ;;
            enter|right)        printf -v "$__out" '%s' "${keys[${sel_idx[$cur]}]}"; break ;;
            esc|left|ch:q|ch:Q|eof) printf -v "$__out" '%s' ""; break ;;
            ch:[1-9])
                local d="${UI_KEY#ch:}"
                if [ "$d" -le "$cnt" ]; then
                    cur=$(( d - 1 ))
                    printf -v "$__out" '%s' "${keys[${sel_idx[$cur]}]}"
                    break
                fi ;;
        esac
    done
    ui_keys_off
    if [ -n "${!__out}" ]; then UI_LAST=ok; return 0; fi
    UI_LAST=back
    return 1
}

_ui_menu_plain() {
    local __out="$1" ttl="$2" i c=0 ans
    echo "  $ttl"
    for i in "${sel_idx[@]}"; do c=$(( c + 1 )); echo "   $c) ${labels[$i]}"; done
    read -r -p "  Выбор: " ans || ans=""
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#sel_idx[@]}" ]; then
        printf -v "$__out" '%s' "${keys[${sel_idx[$(( ans - 1 ))]}]}"
    else
        printf -v "$__out" '%s' ""
    fi
}

ui_confirm() {
    local q="$1" def="${2:-y}" v=0 back=0
    [ "$def" = "n" ] && v=1
    if ! ui_has_tty; then
        local a; read -r -p "  $q [y/n]: " a || a=""
        a="${a:-$def}"
        if [[ "$a" =~ ^[YyДд] ]]; then UI_LAST=ok; return 0; fi
        UI_LAST=no; return 1
    fi
    local on_yes="${C_SEL}${C_OK}${C_B} ● Да ${C_RST}  ${C_DIM}○ Нет ${C_RST}"
    local on_no="${C_DIM} ○ Да ${C_RST}  ${C_SEL}${C_ERR}${C_B}● Нет ${C_RST}"
    local head="  ${C_ACC2}?${C_RST} $q   "
    ui_keys_on
    while true; do
        if [ "$v" -eq 0 ]; then printf '\r\e[2K%s%s' "$head" "$on_yes"; else printf '\r\e[2K%s%s' "$head" "$on_no"; fi
        _ui_readkey
        case "$UI_KEY" in
            left|right|tab|ch:h|ch:l|space) v=$(( 1 - v )) ;;
            ch:y|ch:Y|ch:д|ch:Д) v=0; break ;;
            ch:n|ch:N|ch:н|ch:Н) v=1; break ;;
            esc|ch:q|ch:Q|eof) v=1; back=1; break ;;
            enter) break ;;
        esac
    done
    ui_keys_off
    if [ "$back" -eq 1 ]; then
        printf '\r\e[2K  %s← %s — назад%s\n' "$C_DIM" "$q" "$C_RST"
        UI_LAST=back
    elif [ "$v" -eq 0 ]; then
        printf '\r\e[2K  %s✓%s %s %s— да%s\n' "$C_OK" "$C_RST" "$q" "$C_DIM" "$C_RST"
        UI_LAST=ok
    else
        printf '\r\e[2K  %s○%s %s %s— нет%s\n' "$C_DIM" "$C_RST" "$q" "$C_DIM" "$C_RST"
        UI_LAST=no
    fi
    return "$v"
}

ui_confirm_timeout() {
    local q="$1" t="${2:-60}" a=""
    printf '  %s?%s %s %s[y/N, %s с]%s ' "$C_ACC2" "$C_RST" "$q" "$C_DIM" "$t" "$C_RST"
    if IFS= read -r -t "$t" a <&"$UI_FD"; then
        [[ "$a" =~ ^[YyДд] ]] && { printf '  %s✓%s подтверждено\n' "$C_OK" "$C_RST"; return 0; }
    else
        printf '\n'
    fi
    return 1
}

ui_input() {
    local __var="$1" __lab="$2" __def="${3:-}" __check="${4:-}" __hint="${5:-}"
    local __cur="${!__var:-$__def}" __val=""
    printf '  %s◆%s %s%s%s\n' "$C_ACC" "$C_RST" "$C_B" "$__lab" "$C_RST"
    printf '    %s%sEsc — назад%s\n' "$C_DIM" "${__hint:+$__hint  ·  }" "$C_RST"
    while true; do
        if ui_has_tty; then
            if ! _ui_line_edit "$__cur"; then
                printf '\r\e[2K    %s← назад%s\n' "$C_DIM" "$C_RST"
                UI_LAST=back
                return 1
            fi
            __val="$UI_LINE"
        else
            read -r -p "    > " __val || __val="$__cur"
        fi
        __val="${__val#"${__val%%[![:space:]]*}"}"; __val="${__val%"${__val##*[![:space:]]}"}"
        [ -z "$__val" ] && __val="$__def"
        if [ -n "$__check" ] && ! "$__check" "$__val"; then
            printf '    %s✗ некорректное значение, попробуй ещё раз%s\n' "$C_ERR" "$C_RST"
            __cur="$__val"
            continue
        fi
        break
    done
    printf -v "$__var" '%s' "$__val"
    UI_LAST=ok
    return 0
}

_ui_line_edit() {
    local buf="$1" pos=${#1} off=0 w c s vis rc=0
    w=$(( UI_W - 6 )); [ "$w" -lt 20 ] && w=20
    printf '\e[?2004l'
    stty -echo -icanon min 1 time 0 <&"$UI_FD" 2>/dev/null
    while true; do
        if ! read -r -t 0 <&"$UI_FD"; then
            [ "$pos" -lt "$off" ] && off=$pos
            [ "$pos" -gt $(( off + w )) ] && off=$(( pos - w ))
            vis="${buf:off:w}"
            if [ "$off" -gt 0 ]; then s="‹"; else s=" "; fi
            printf '\r\e[2K    %s❯%s%s%s%s' "$C_ACC" "$C_DIM" "$s" "$C_RST" "$vis"
            c=$(( ${#vis} - pos + off ))
            [ "$c" -gt 0 ] && printf '\e[%dD' "$c"
        fi
        IFS= read -r -n1 -d '' c <&"$UI_FD" || { rc=1; break; }
        case "$c" in
            $'\n'|$'\r'|$'\x04') break ;;
            $'\e')
                if ! IFS= read -r -n1 -d '' -t 0.05 c <&"$UI_FD"; then rc=1; break; fi
                s="$c"
                if [ "$c" = "[" ] || [ "$c" = "O" ]; then
                    while IFS= read -r -n1 -d '' -t 0.05 c <&"$UI_FD"; do
                        s+="$c"; [[ "$c" =~ [A-Za-z~] ]] && break
                    done
                fi
                case "$s" in
                    '[D'|'OD') [ "$pos" -gt 0 ] && pos=$(( pos - 1 )) ;;
                    '[C'|'OC') [ "$pos" -lt "${#buf}" ] && pos=$(( pos + 1 )) ;;
                    '[H'|'OH'|'[1~'|'[7~') pos=0 ;;
                    '[F'|'OF'|'[4~'|'[8~') pos=${#buf} ;;
                    '[3~') buf="${buf:0:pos}${buf:pos+1}" ;;
                esac ;;
            $'\x7f'|$'\b')
                if [ "$pos" -gt 0 ]; then buf="${buf:0:pos-1}${buf:pos}"; pos=$(( pos - 1 )); fi ;;
            $'\x01') pos=0 ;;
            $'\x05') pos=${#buf} ;;
            $'\x15') buf="${buf:pos}"; pos=0 ;;
            [[:cntrl:]]) ;;
            *) buf="${buf:0:pos}$c${buf:pos}"; pos=$(( pos + 1 )) ;;
        esac
    done
    stty echo icanon <&"$UI_FD" 2>/dev/null
    if [ "$rc" -eq 0 ]; then
        _ui_cut s "$buf" "$w"
        printf '\r\e[2K    %s❯%s %s\n' "$C_ACC" "$C_RST" "$s"
    fi
    UI_LINE="$buf"
    return "$rc"
}

ui_secret() {
    local __var="$1" __lab="$2" __check="${3:-}"
    local __cur="${!__var:-}" __val=""
    printf '  %s◆%s %s%s%s\n' "$C_ACC" "$C_RST" "$C_B" "$__lab" "$C_RST"
    printf '    %sвставь (правая кнопка мыши или Ctrl+Shift+V) и нажми Enter  ·  Esc — назад%s\n' "$C_DIM" "$C_RST"
    if [ -n "$__cur" ]; then
        printf '    %sсейчас: %s…%s (%d симв.) — пустой Enter, чтобы оставить%s\n' "$C_DIM" "${__cur:0:6}" "${__cur: -6}" "${#__cur}" "$C_RST"
    fi
    if ! ui_has_tty; then
        IFS= read -r __val || __val=""
        [ -z "$__val" ] && __val="$__cur"
        printf -v "$__var" '%s' "$__val"
        UI_LAST=ok
        return 0
    fi
    while true; do
        if ! _ui_secret_read; then
            printf '    %s← назад%s\n' "$C_DIM" "$C_RST"
            UI_LAST=back
            return 1
        fi
        [ -z "$__val" ] && __val="$__cur"
        __val="${__val//[[:space:]]/}"
        [[ "$__val" == *SECRET_KEY=* ]] && __val="${__val#*SECRET_KEY=}"
        __val="${__val#[\"\']}"; __val="${__val%[\"\']}"
        if [ -z "$__val" ] || { [ -n "$__check" ] && ! "$__check" "$__val"; }; then
            printf '    %s✗ пусто или в ключе есть недопустимые символы — вставь ещё раз%s\n' "$C_ERR" "$C_RST"
            continue
        fi
        break
    done
    printf '    %s✓ принято: %s…%s (%d симв.)%s\n' "$C_OK" "${__val:0:6}" "${__val: -6}" "${#__val}" "$C_RST"
    printf -v "$__var" '%s' "$__val"
    UI_LAST=ok
    return 0
}

_ui_secret_read() {
    local c="" pend="" seq="" dots rc=0
    __val=""
    printf '\e[?2004l'
    stty -echo -icanon min 1 time 0 <&"$UI_FD" 2>/dev/null
    _ui_secret_draw() {
        if [ "${#__val}" -eq 0 ]; then dots=""
        elif [ "${#__val}" -le 24 ]; then printf -v dots '%*s' "${#__val}" ''; dots="${dots// /●}"
        else dots="●●●●●●●●●●●●●●●●●●●●●●●●…"
        fi
        printf '\r\e[2K    %s❯%s %s%s%s %s%d симв.%s' "$C_ACC" "$C_RST" "$C_ACC2" "$dots" "$C_RST" "$C_DIM" "${#__val}" "$C_RST"
    }
    _ui_secret_draw
    while true; do
        if [ -n "$pend" ]; then
            c="$pend"; pend=""
        elif ! IFS= read -r -n1 -d '' c <&"$UI_FD"; then
            break
        fi
        case "$c" in
            $'\n'|$'\r')
                [ -z "$__val" ] && break
                if IFS= read -r -n1 -d '' -t 0.25 pend <&"$UI_FD"; then continue; fi
                break ;;
            $'\x04') break ;;
            $'\x7f'|$'\b') __val="${__val%?}" ;;
            $'\x15') __val="" ;;
            $'\e')
                seq=""
                while IFS= read -r -n1 -d '' -t 0.02 c <&"$UI_FD"; do
                    seq+="$c"
                    [[ "$c" =~ [A-Za-z~] ]] && break
                done
                [ -z "$seq" ] && { rc=1; __val=""; break; } ;;
            [[:space:]]|[[:cntrl:]]) ;;
            *) __val+="$c" ;;
        esac
        read -r -t 0 <&"$UI_FD" || _ui_secret_draw
    done
    if [ "$rc" -eq 0 ]; then
        _ui_secret_draw
        while IFS= read -r -n1 -d '' -t 0.4 c <&"$UI_FD"; do :; done
    else
        printf '\r\e[2K'
    fi
    stty echo icanon <&"$UI_FD" 2>/dev/null
    [ "$rc" -eq 0 ] && printf '\n'
    return "$rc"
}

ui_checklist() {
    local __out="$1" ttl="$2"; shift 2
    local n=$# i keys=() labels=() states=() descs=()
    local items=("$@")
    for (( i = 0; i < n; i++ )); do
        IFS='|' read -r "keys[i]" "labels[i]" "states[i]" "descs[i]" <<<"${items[$i]}"
    done
    if ! ui_has_tty; then
        local res=""
        for (( i = 0; i < n; i++ )); do [ "${states[$i]}" = "on" ] && res+="${keys[$i]} "; done
        printf -v "$__out" '%s' "${res% }"
        UI_LAST=ok
        return 0
    fi

    local on_sel=() on_off=() off_sel=() off_off=() dsc=() s lab
    for (( i = 0; i < n; i++ )); do
        lab="${labels[$i]}"
        _ui_row s "${C_ACC}${C_B} ❯ ${C_RST} ${C_OK}■${C_RST} ${C_B}${C_TXT}${lab}${C_RST}" sel; on_sel[i]="$s"
        _ui_row s "${C_ACC}${C_B} ❯ ${C_RST} ${C_MUTED}□${C_RST} ${C_B}${C_TXT}${lab}${C_RST}" sel; off_sel[i]="$s"
        _ui_row s "    ${C_OK}■${C_RST} ${C_TXT}${lab}${C_RST}"; on_off[i]="$s"
        _ui_row s "    ${C_MUTED}□${C_RST} ${C_TXT}${lab}${C_RST}"; off_off[i]="$s"
        _ui_cut s "${descs[$i]:-}" $(( UI_W - 6 )); dsc[i]="$s"
    done
    local top_line bot_line
    _ui_box_top top_line "$ttl"
    _ui_box_bottom bot_line

    local cur=0 drawn=0 frame back=0 EL=$'\r\e[2K'
    ui_keys_on
    while true; do
        frame=""
        [ "$drawn" -gt 0 ] && frame+=$'\e['"${drawn}A"
        frame+="$EL$top_line"$'\n'
        for (( i = 0; i < n; i++ )); do
            if [ "$i" -eq "$cur" ]; then
                if [ "${states[$i]}" = "on" ]; then frame+="$EL${on_sel[$i]}"$'\n'; else frame+="$EL${off_sel[$i]}"$'\n'; fi
            else
                if [ "${states[$i]}" = "on" ]; then frame+="$EL${on_off[$i]}"$'\n'; else frame+="$EL${off_off[$i]}"$'\n'; fi
            fi
        done
        frame+="$EL$bot_line"$'\n'"$EL    ${C_ACC2}${dsc[$cur]:-}${C_RST}"$'\n'"$EL    ${C_DIM}↑↓ выбор   Пробел отметить   Enter сохранить   Esc назад${C_RST}"$'\n'
        drawn=$(( n + 4 ))
        printf '%s' "$frame"
        _ui_readkey
        case "$UI_KEY" in
            up|ch:k)   cur=$(( cur > 0 ? cur - 1 : n - 1 )) ;;
            down|ch:j|tab) cur=$(( cur < n - 1 ? cur + 1 : 0 )) ;;
            space|right|ch:x)
                if [ "${states[$cur]}" = "on" ]; then states[cur]="off"; else states[cur]="on"; fi ;;
            enter) break ;;
            esc|left|ch:q|ch:Q|eof) back=1; break ;;
        esac
    done
    ui_keys_off
    if [ "$back" -eq 1 ]; then UI_LAST=back; return 1; fi
    local res=""
    for (( i = 0; i < n; i++ )); do [ "${states[$i]}" = "on" ] && res+="${keys[$i]} "; done
    printf -v "$__out" '%s' "${res% }"
    UI_LAST=ok
    return 0
}

ui_pause() {
    printf '\n  %s%s%s' "$C_DIM" "${1:-Enter — вернуться в меню…}" "$C_RST"
    if ui_has_tty; then
        ui_keys_on; _ui_readkey; ui_keys_off
    else
        local _k; IFS= read -r _k || true
    fi
    printf '\n'
    UI_LAST=ok
}

ui_done() {
    case "$UI_LAST" in
        back|no) UI_LAST=ok ;;
        *) kit_changed; ui_pause "$@" ;;
    esac
    return 0
}

ui_screen() {
    ui_logo
    [ -n "${1:-}" ] && title "$1"
    return 0
}
