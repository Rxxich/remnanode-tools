# shellcheck shell=bash

CORE_REPO="Jolymmiles/Xray-core"
CORE_ASSET="Xray-linux-64.zip"
CORE_LATEST_TAG=""; CORE_LATEST_DONE=0

case "$(uname -m)" in
    aarch64|arm64) CORE_ASSET="Xray-linux-arm64-v8a.zip" ;;
esac

fetch_core_latest_tag() {
    local tag="" t="${1:-15}"
    tag=$(curl -fsSL --max-time "$t" "https://api.github.com/repos/$CORE_REPO/releases/latest" 2>/dev/null \
          | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -n1) || true
    if [ -z "$tag" ]; then
        tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time "$t" \
              "https://github.com/$CORE_REPO/releases/latest" 2>/dev/null | sed 's#.*/tag/##') || true
    fi
    case "$tag" in */*|"") tag="" ;; esac
    [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || tag=""
    echo "$tag"
}

core_version_of() {
    [ -x "$1" ] || return 0
    "$1" version 2>/dev/null | awk 'NR==1{print $2}' || true
}

core_fetch_release() {
    local tag="$1" dir="$2"
    local base="https://github.com/$CORE_REPO/releases/download/$tag"
    has unzip || { pb_init 5; step 5 "Установка unzip" "apt-get ${APT_OPTS[*]} install unzip"; }

    pb_init 10
    step 8 "Загрузка $CORE_ASSET ($tag)" \
        "curl -fsSL --proto '=https' -o '$dir/$CORE_ASSET' '$base/$CORE_ASSET' && \
         { curl -fsSL --proto '=https' -o '$dir/$CORE_ASSET.dgst' '$base/$CORE_ASSET.dgst' || true; }"

    local want got
    want=$(grep -i 'SHA2-256' "$dir/$CORE_ASSET.dgst" 2>/dev/null | awk -F'= *' 'NR==1{print $2}' | tr -d ' \r' || true)
    got=$(sha256sum "$dir/$CORE_ASSET" | awk '{print $1}')
    if [ -z "$want" ]; then
        warn "В релизе нет контрольной суммы — проверка SHA-256 пропущена"
    elif [ "${want,,}" != "${got,,}" ]; then
        err "Контрольная сумма архива не совпала с релизом — файл повреждён или подменён"
        return 1
    else
        ok "Контрольная сумма SHA-256 совпала"
    fi
    step 2 "Распаковка ядра" "unzip -o -q '$dir/$CORE_ASSET' xray -d '$dir' && chmod 755 '$dir/xray'"
    if [ -z "$(core_version_of "$dir/xray")" ]; then
        err "Скачанный бинарник не запускается на этом сервере"
        return 1
    fi
    return 0
}

install_custom_core() {
    title "Кастомное ядро Xray (Jolymmiles)"
    info "Определяю последнюю версию ${C_DIM}github.com/$CORE_REPO${C_RST}…"
    local TAG
    TAG=$(fetch_core_latest_tag)
    if [ -z "$TAG" ]; then
        warn "Не удалось определить версию автоматически."
        TAG=""
        ui_input TAG "Тег релиза вручную" "" "" "например v26.7.29" || return 1
        [ -z "$TAG" ] && { err "Версия не указана — ядро не установлено"; return 1; }
    else
        ok "Последняя версия: ${C_B}$TAG${C_RST}"
        if [ "${CORE_AUTO:-0}" != "1" ] && ! ui_confirm "Использовать её?" y; then
            ui_back && return 1
            ui_input TAG "Нужный тег" "$TAG" || return 1
        fi
    fi
    mkdir -p "$CORE_DIR"
    local tmp; tmp=$(mktemp -d)
    if ! core_fetch_release "$TAG" "$tmp"; then
        rm -rf "$tmp"; err "Ядро не установлено"; return 1
    fi
    install -m 755 "$tmp/xray" "$CORE_BIN"
    rm -rf "$tmp"
    CUSTOM_CORE="yes"
    cfg_save
    local ver; ver=$(core_version_of "$CORE_BIN")
    [ -n "$ver" ] && ok "Установлено ядро: ${C_B}$ver${C_RST}"
    return 0
}

find_core_bin() {
    local cn src=""
    cn=$(find_node_container)
    if [ -n "$cn" ]; then
        src=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/usr/local/bin/xray"}}{{.Source}}{{end}}{{end}}' "$cn" 2>/dev/null || true)
    fi
    if [ -z "$src" ] && [ "${CUSTOM_CORE:-no}" = "yes" ] && [ -f "$CORE_BIN" ]; then src="$CORE_BIN"; fi
    echo "$src"
}

container_core_version() {
    [ -n "$1" ] || return 0
    docker exec "$1" xray version 2>/dev/null | awk 'NR==1{print $2}' || true
}

core_rollback() {
    local cn="$1" bin="$2"
    [ -f "$bin.prev" ] || { err "Нет резервной копии $bin.prev — откатывать нечего"; return 1; }
    mv -f "$bin.prev" "$bin"
    pb_init 4
    step 4 "Перезапуск $cn со старым ядром" "docker restart '$cn'"
    ok "Откат выполнен: $(container_core_version "$cn")"
}

update_core() {
    title "Обновление ядра Jolymmiles"
    local bin cn cur tag
    bin=$(find_core_bin); cn=$(find_node_container)
    if [ -z "$bin" ] || [ -z "$cn" ]; then
        warn "Кастомное ядро не найдено: в контейнере ноды не подменён /usr/local/bin/xray."
        return 0
    fi
    cur=$(core_version_of "$bin")
    ui_box_top "Ядро"
    ui_kv "Бинарник" "$bin"
    ui_kv "Версия" "${C_B}${cur:-неизвестна}${C_RST}  ${C_DIM}контейнер $cn${C_RST}"
    ui_box_bottom
    info "Проверяю последний релиз ${C_DIM}github.com/$CORE_REPO${C_RST}…"
    tag=$(fetch_core_latest_tag)
    [ -z "$tag" ] && { err "Не удалось узнать последнюю версию — GitHub недоступен?"; return 1; }
    CORE_LATEST_TAG="$tag"; CORE_LATEST_DONE=1

    if [ "${tag#v}" = "$cur" ]; then
        ok "Уже стоит последняя версия ($tag)"
        ui_confirm "Переустановить её всё равно?" n || return 0
    else
        ok "Доступна новая версия: ${C_B}$tag${C_RST}"
        ui_confirm "Обновить ${cur:-?} → ${tag#v}?" y || return 0
    fi

    local tmp new; tmp=$(mktemp -d)
    if ! core_fetch_release "$tag" "$tmp"; then
        rm -rf "$tmp"; err "Обновление отменено, текущее ядро не тронуто"; return 1
    fi
    new=$(core_version_of "$tmp/xray")
    cp -f "$bin" "$bin.prev"
    install -m 755 "$tmp/xray" "$bin.new"
    mv -f "$bin.new" "$bin"
    rm -rf "$tmp"
    ok "Бинарник заменён, предыдущая версия — $bin.prev"

    local since; since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    pb_init 4
    step 4 "Перезапуск $cn" "docker restart '$cn'"
    local got; got=$(container_core_version "$cn")
    if [ "$got" != "$new" ]; then
        err "В контейнере версия «${got:-?}», ожидалась $new — откатываю"
        core_rollback "$cn" "$bin" || true
        return 1
    fi

    info "Жду, пока панель передаст конфиг и ядро поднимется (до 60 с)…"
    local i logs up=0
    for (( i = 0; i < 30; i++ )); do
        logs=$(docker logs --since "$since" "$cn" 2>&1 || true)
        if grep -aq "is up and running" <<<"$logs"; then up=1; break; fi
        sleep 2
    done
    if [ "$up" -eq 1 ]; then
        ok "Ядро ${C_B}$new${C_RST} запущено, нода приняла конфиг"
        note "Откат вручную:  mv -f $bin.prev $bin && docker restart $cn"
    else
        warn "За 60 с ядро не сообщило о запуске. Логи: docker logs --tail 50 $cn"
        if ui_confirm "Откатить на предыдущую версию (${cur:-?})?" y; then core_rollback "$cn" "$bin" || true; fi
    fi
    return 0
}

action_custom_core() {
    install_custom_core || return 0
    if [ -f "$NODE_DIR/docker-compose.yml" ]; then
        if [ -z "${SECRET_KEY:-}" ]; then
            warn "SECRET_KEY не найден в конфиге — compose не перегенерирован."
            note "Добавь вручную:  - $CORE_BIN:/usr/local/bin/xray"
            return 0
        fi
        write_node_compose
        restart_node
        ok "Том ядра добавлен в docker-compose, нода перезапущена"
    else
        info "Remnanode ещё не установлен — ядро подключится при установке"
    fi
}

action_core_menu() {
    ui_screen "Ядро Xray (Jolymmiles)"
    if [ -n "$(find_core_bin)" ]; then update_core || true; else action_custom_core; fi
}
