# shellcheck shell=bash

STEALTH_POOL=(
    "webcache" "edge-cache" "app-worker" "media-cache" "site-proxy"
    "data-sync" "cache-node" "static-edge" "web-app" "content-cdn"
)

ask_stealth() {
    title "Скрытный режим (маскировка от хостера)"
    note "Обычно нода видна как контейнеры remnanode / remnanode-proxy, образ remnawave/node"
    note "и каталоги /opt/remnanode, /var/lib/remnanode. Скрытный режим заменяет имена и пути"
    note "на нейтральные, а образ переклеивает на локальный тег."
    echo
    ui_alert "Это обфускация, а не невидимость" \
        "Провайдер с доступом к диску, трафику или гипервизору всё равно поймёт." \
        "docker inspect покажет сокеты и внутренние пути, порты и трафик видны." \
        "Конфиг $CONF_FILE хранит домен и SECRET_KEY (права 600)." \
        "Где что лежит — покажу на главном экране."
    echo
    if ! ui_confirm "Включить скрытный режим?" "$([ "${STEALTH:-no}" = yes ] && echo y || echo n)"; then
        ui_back && return 1
        STEALTH="no"; BASE_NAME="remnanode"; IMAGE_ALIAS=""
        resolve_layout
        return 0
    fi
    STEALTH="yes"
    local suggested="${STEALTH_POOL[$(( RANDOM % ${#STEALTH_POOL[@]} ))]}"
    [ -n "${BASE_NAME:-}" ] && [ "$BASE_NAME" != "remnanode" ] && suggested="$BASE_NAME"
    local name="$suggested"
    ui_input name "Базовое имя" "$suggested" valid_base_name "строчные латинские буквы, цифры и дефис; от него образуются контейнеры и пути" || return 1
    BASE_NAME="$name"
    IMAGE_ALIAS="${BASE_NAME}:stable"
    resolve_layout
    echo
    ui_box_top "Будущие имена"
    ui_kv "Контейнер ноды" "$NODE_NAME"
    ui_kv "Прокси" "$NGINX_NAME"
    ui_kv "Образ" "$NODE_IMAGE_REF"
    ui_kv "Каталог ноды" "$NODE_DIR"
    ui_kv "Ядро" "$CORE_DIR"
    ui_kv "Логи" "$LOG_DIR"
    ui_box_bottom
    return 0
}

show_stealth_panel() {
    [ "${STEALTH:-no}" = "yes" ] || return 0
    [ -n "${BASE_NAME:-}" ] || return 0
    ui_box_top "${C_ACC2}Скрытая установка${C_RST}"
    ui_kv "Контейнер ноды" "$NODE_NAME"
    ui_kv "Прокси" "$NGINX_NAME"
    ui_kv "Образ" "$NODE_IMAGE_REF"
    ui_kv "Каталог" "$NODE_DIR"
    [ "${CUSTOM_CORE:-no}" = "yes" ] && ui_kv "Ядро" "$CORE_BIN"
    [ "${XRAY_LOGS:-no}" = "yes" ] && ui_kv "Логи" "$LOG_DIR"
    ui_box_bottom
    return 0
}
