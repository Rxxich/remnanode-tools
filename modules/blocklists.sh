# shellcheck shell=bash

BL_CONF="$CONF_DIR/blocklists.conf"
BL_LOCAL="$CONF_DIR/blocklist-local.txt"
BL_EXCL="$CONF_DIR/blocklist-exclude.txt"
BL_EVERY_CHOICES=(1 3 6 12 24)

BL_PRESETS=(
    "spamhaus|on|Spamhaus DROP|https://www.spamhaus.org/drop/drop_v4.json https://www.spamhaus.org/drop/drop_v6.json"
    "firehol|off|FireHOL Level 1|https://iplists.firehol.org/files/firehol_level1.netset"
    "gov|on|Госсети РФ (shadow-netlab)|https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
    "antiscan|on|Сканеры (shadow-netlab)|https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
    "skipa|on|СКИПА (shadow-netlab)|https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list"
    "c24|on|AS blacklist (C24Be)|https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists/blacklist.txt"
    "cyberok|on|СКИПА CyberOK (tread-lightly)|https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_cidr.txt"
)

bl_init_conf() {
    [ -f "$BL_CONF" ] && return 0
    mkdir -p "$CONF_DIR"
    {
        printf '%s\n' "${BL_PRESETS[@]}"
    } >"$BL_CONF"
    chmod 600 "$BL_CONF"
    touch "$BL_LOCAL" "$BL_EXCL"; chmod 600 "$BL_LOCAL" "$BL_EXCL"
}

bl_ids() { { awk -F'|' '!/^#/ && $2=="on" {print $1}' "$BL_CONF" 2>/dev/null; echo local; } | grep -E '^[a-z0-9]{1,10}$'; }
bl_is_preset() { local p; for p in "${BL_PRESETS[@]}"; do [ "${p%%|*}" = "$1" ] && return 0; done; return 1; }

bl_render_sets() {
    local id f v
    for v in 4 6; do
        if [ "$v" = 4 ]; then f=ipv4_addr; else f=ipv6_addr; fi
        echo "    set blx$v { type $f; flags interval; auto-merge; }"
        for id in $(bl_ids); do
            echo "    set bl_${id}_$v { type $f; flags interval; auto-merge; }"
            echo "    set hit_${id}_$v { type $f; size 65536; flags dynamic,timeout; timeout 1d; }"
        done
    done
    for id in $(bl_ids); do echo "    counter c_bl_$id {}"; done
}

bl_render_chain() {
    local id
    echo "    chain blocklists {"
    echo "        ip saddr @blx4 return"
    echo "        ip6 saddr @blx6 return"
    for id in $(bl_ids); do
        echo "        ip saddr @bl_${id}_4 add @hit_${id}_4 { ip saddr }"
        echo "        ip saddr @bl_${id}_4 counter name c_bl_$id drop"
        echo "        ip6 saddr @bl_${id}_6 add @hit_${id}_6 { ip6 saddr }"
        echo "        ip6 saddr @bl_${id}_6 counter name c_bl_$id drop"
    done
    echo "    }"
}

bl_raw_url() {
    local u="$1"
    if [[ "$u" =~ ^https://github\.com/([^/]+)/([^/]+)/(blob|raw)/(.+)$ ]]; then
        u="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[4]}"
    fi
    printf '%s' "$u"
}
valid_bl_url() { [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/+=?\&@:-]*)?$ ]]; }

guard_reapply() {
    local me; me=$(ssh_client_ip)
    if [ -n "$me" ] && ! grep -qxF "$me" "$GUARD_ALLOW" 2>/dev/null; then
        echo "$me" >>"$GUARD_ALLOW"; chmod 600 "$GUARD_ALLOW"
        note "Ваш IP $me добавлен в белый список, чтобы списки его не задели."
    fi
    pb_init 8
    stepf 3 "Пересборка правил (nft -c)" guard_apply_files "$(ssh_ports)"
    stepf 5 "Загрузка таблицы и списков" guard_load
}

bl_status_box() {
    local st id on name n4 n6 hits pk upd stt msg line age
    st=$("$GUARD_BIN" lists 2>/dev/null)
    ui_box_top "Блок-листы"
    if ! guard_has bl; then
        ui_box_line "$(ui_badge_off "выключены")  ${C_DIM}включаются здесь же, пунктом «Включить блок-листы»${C_RST}"
        ui_box_bottom; return 0
    fi
    local h1 h2 h3 c1 c2 c3
    _ui_pad h1 "список" 32; _ui_pad h2 "сетей" 9; _ui_pad h3 "адресов/сутки" 15
    ui_box_line "${C_DIM}${h1}${h2}${h3}пакетов${C_RST}"
    while IFS=$'\t' read -r id on name n4 n6 hits pk upd stt msg; do
        [ -n "$id" ] || continue
        _ui_cut name "$name" 28
        if [ "$on" != "on" ]; then
            _ui_pad c1 "${C_DIM}○ ${name}${C_RST}" 32
            ui_box_line "${c1}${C_DIM}выключен${C_RST}"
            continue
        fi
        case "$stt" in
            fail) line="${C_WARN}▲${C_RST} " ;;
            new)  line="${C_DIM}…${C_RST} " ;;
            *)    line="${C_OK}●${C_RST} " ;;
        esac
        _ui_pad c1 "$line$name" 32
        _ui_pad c2 "$(( n4 + n6 ))" 9
        _ui_pad c3 "${C_B}${hits:-0}${C_RST}" 15
        ui_box_line "${c1}${c2}${c3}${pk:-0}"
        [ "$stt" = "fail" ] && [ "$msg" != "-" ] && ui_box_line "  ${C_WARN}$(ui_cut "$msg" $(( UI_W - 10 )))${C_RST}"
    done <<<"$st"
    upd=$(awk -F'\t' '$8>0{print $8}' <<<"$st" | sort -n | tail -n1)
    if [ -n "$upd" ]; then
        local nx; nx=$(grep -c . "$BL_EXCL" 2>/dev/null)
        age=$(( ( $(date +%s) - upd ) / 60 ))
        ui_box_line "${C_DIM}обновлено $([ "$age" -lt 60 ] && echo "$age мин" || echo "$(( age / 60 )) ч") назад, обновление $(bl_every_label)${C_RST}"
        ui_box_line "${C_DIM}исключений: ${nx:-0} · пакеты считаются с последней загрузки правил${C_RST}"
    fi
    ui_box_bottom
}

bl_every()       { local h="${GUARD_BL_EVERY:-6}"; [[ "$h" =~ ^[0-9]+$ ]] && [ "$h" -ge 1 ] && [ "$h" -le 24 ] || h=6; echo "$h"; }
bl_every_label() { local h; h=$(bl_every); if [ "$h" -eq 24 ]; then echo "раз в сутки"; else echo "каждые $h ч"; fi; }

bl_set_every() {
    local items=() h c lab
    for h in "${BL_EVERY_CHOICES[@]}"; do
        lab="каждые $h ч"; [ "$h" -eq 24 ] && lab="раз в сутки"
        c=""; [ "$h" -eq 6 ] && c="рекомендуется"
        [ "$h" -eq 1 ] && c="списки меняются редко, чаще обычно не нужно"
        items+=("$h|$lab|$c|")
    done
    ui_menu c "Как часто обновлять списки (сейчас $(bl_every_label))" -d "$(bl_every)" "${items[@]}" || return 0
    GUARD_BL_EVERY="$c"
    cfg_save
    if guard_active && guard_has bl; then
        guard_write_units
        systemctl restart "$KIT_NAME-guard-blocklist.timer" >/dev/null 2>&1 || true
    fi
    ok "Списки обновляются $(bl_every_label)"
}

bl_toggle_lists() { bl_toggle_lists_offline && guard_reapply; }

bl_add_list() {
    local url="" name="" id n res
    note "Подойдёт любой текстовый список IP/подсетей по https: строка — адрес, # — комментарий."
    note "Ссылку на файл в GitHub (github.com/…/blob/…) переведу в raw сам."
    echo
    ui_input url "Ссылка на список" "" valid_bl_url "https://raw.githubusercontent.com/owner/repo/main/list.txt" || return 0
    url=$(bl_raw_url "$url")
    if grep -qF "|$url" "$BL_CONF" 2>/dev/null; then warn "Такой список уже есть"; return 0; fi
    info "Проверяю ссылку…"
    if ! res=$("$GUARD_BIN" blocklist test "$url" 2>&1); then
        err "Список не подошёл: $res"; return 0
    fi
    ok "Найдено адресов и подсетей: ${C_B}$res${C_RST}"
    ui_input name "Название (для статистики)" "" valid_nonempty "например: Мой список сканеров" || return 0
    name="${name//|/ }"
    for n in 1 2 3 4 5 6 7 8 9; do
        id="my$n"; grep -q "^$id|" "$BL_CONF" || break
    done
    if grep -q "^$id|" "$BL_CONF"; then err "Свободных мест для своих списков нет (максимум 9)"; return 0; fi
    printf '%s|on|%s|%s\n' "$id" "$name" "$url" >>"$BL_CONF"
    ok "Список «$name» добавлен"
    guard_reapply
}

bl_del_list() {
    local items=() id on name urls c
    while IFS='|' read -r id on name urls; do
        [[ "$id" =~ ^[a-z0-9]{1,10}$ ]] || continue
        bl_is_preset "$id" && continue
        items+=("$id|$name|${urls}|")
    done <"$BL_CONF"
    if [ "${#items[@]}" -eq 0 ]; then info "Своих списков нет. Встроенные можно выключить в «Какие списки блокировать»."; return 0; fi
    ui_menu c "Какой список удалить" "${items[@]}"
    [ -n "$c" ] || return 0
    ui_confirm "Удалить список «$(awk -F'|' -v id="$c" '$1==id{print $3}' "$BL_CONF")»?" n || return 0
    grep -v "^$c|" "$BL_CONF" >"$BL_CONF.tmp" && mv -f "$BL_CONF.tmp" "$BL_CONF"
    chmod 600 "$BL_CONF"
    rm -f "$STATE_DIR/guard/lists/$c".*
    guard_reapply
}

bl_edit_file() {
    local what="$1" file="$2" ttl="$3" hint="$4" c ip=""
    if [ -s "$file" ]; then
        ui_box_top "$ttl ($(grep -c . "$file"))"
        while read -r ip; do [ -n "$ip" ] && ui_box_line "$ip"; done < <(head -n 25 "$file")
        [ "$(grep -c . "$file")" -gt 25 ] && ui_box_line "${C_DIM}… полный список: $file${C_RST}"
        ui_box_bottom
    else
        info "$ttl: пусто"
    fi
    note "$hint"
    echo
    ui_menu c "Действие" "add|Добавить адрес или подсеть||" "del|Убрать адрес или подсеть||" || return 0
    ip=""
    ui_input ip "IP или CIDR" "" valid_ip_or_cidr || return 0
    "$GUARD_BIN" "$what" "$c" "$ip"
}

bl_enable() {
    bl_init_conf
    [[ " $GUARD_FEATURES " == *" bl "* ]] || GUARD_FEATURES="${GUARD_FEATURES:+$GUARD_FEATURES }bl"
    GUARD_FEATURES="${GUARD_FEATURES//none/}"
    cfg_save
    if guard_active; then
        guard_reapply
    else
        info "Защита ещё не установлена — запускаю установку (блок-листы уже отмечены)."
        ui_pause "Enter — продолжить…"
        action_guard_apply
    fi
}

action_blocklists_menu() {
    local c box="" gen=-1 active=0
    guard_defaults
    bl_init_conf
    while true; do
        if [ "$gen" != "$KIT_GEN" ]; then
            box=$(bl_status_box)
            active=0; guard_has bl && guard_active && active=1
            gen=$KIT_GEN
        fi
        ui_screen "Блок-листы"
        printf '%s\n\n' "$box"
        if [ "$active" -eq 0 ]; then
            ui_menu c "Блок-листы" \
                "on|Включить блок-листы|адреса из списков блокируются полностью, обновление $(bl_every_label)|" \
                "toggle|Какие списки блокировать|отметить нужные (можно до включения)|" \
                "every|Как часто обновлять|сейчас $(bl_every_label)|"
            case "$c" in
                on)     bl_enable ;;
                toggle) bl_toggle_lists_offline ;;
                every)  bl_set_every ;;
                *) return 0 ;;
            esac
            ui_done; continue
        fi
        ui_menu c "Блок-листы" -d update \
            "update|Обновить списки сейчас|скачать заново все включённые списки|" \
            "toggle|Какие списки блокировать|включить или выключить встроенные и свои|" \
            "every|Как часто обновлять|сейчас $(bl_every_label)|" \
            "add|Добавить свой список (ссылка)|GitHub или любой https с адресами по строкам|" \
            "del|Удалить свой список||" \
            "-|адреса" \
            "local|Свои адреса|заблокировать IP или подсеть навсегда|" \
            "excl|Исключения|адрес из списков, который блокировать не нужно|" \
            "-|" \
            "off|Выключить блок-листы|правила списков убираются, остальная защита остаётся|"
        case "$c" in
            update) pb_init 10; stepf_try 10 "Загрузка и проверка списков" "$GUARD_BIN" blocklist update || true ;;
            toggle) bl_toggle_lists ;;
            every)  bl_set_every ;;
            add)    bl_add_list ;;
            del)    bl_del_list ;;
            local)  ui_screen "Свои адреса"; bl_edit_file local "$BL_LOCAL" "Свои адреса" \
                        "Блокируются полностью и всегда, как отдельный список «Свои адреса»." ;;
            excl)   ui_screen "Исключения"; bl_edit_file exclude "$BL_EXCL" "Исключения" \
                        "Адрес не блокируется ни одним списком. Остальная защита (анти-скан, SSH) к нему действует." ;;
            off)
                ui_confirm "Выключить блокировку по спискам?" n || continue
                GUARD_FEATURES=$(tr ' ' '\n' <<<"$GUARD_FEATURES" | grep -vx bl | paste -sd' ' -)
                [ -z "$GUARD_FEATURES" ] && GUARD_FEATURES="none"
                cfg_save
                guard_reapply
                systemctl disable --now "$KIT_NAME-guard-blocklist.timer" >/dev/null 2>&1 || true ;;
            *) return 0 ;;
        esac
        ui_done
    done
}

bl_toggle_lists_offline() {
    local items=() id on name urls sel was=""
    while IFS='|' read -r id on name urls; do
        [[ "$id" =~ ^[a-z0-9]{1,10}$ ]] || continue
        items+=("$id|$name|$on|$(ui_cut "${urls%% *}" 60)")
        [ "$on" = "on" ] && was+="$id "
    done <"$BL_CONF"
    ui_checklist sel "Какие списки блокировать" "${items[@]}" || return 1
    if [ "$sel" = "${was% }" ]; then
        info "Ничего не изменилось"
        return 1
    fi
    awk -F'|' -v OFS='|' -v sel=" $sel " '/^#/ {print; next} { $2 = (index(sel, " " $1 " ") ? "on" : "off"); print }' \
        "$BL_CONF" >"$BL_CONF.tmp" && mv -f "$BL_CONF.tmp" "$BL_CONF"
    chmod 600 "$BL_CONF"
    ok "Сохранено"
}
