# shellcheck shell=bash

TPL_REPO="${TPL_REPO:-Mrvibecodic/node-templates}"
TPL_BRANCH="${TPL_BRANCH:-main}"
TPL_FALLBACK=("screenwire-digest" "vibrai-photo-editor" "esports-stream-template")

SERVICES=(
    "filebrowser|filebrowser/filebrowser|80|веб-файловый менеджер"
    "memos|neosmemo/memos:stable|5230|заметки"
    "pingvin-share|stonith404/pingvin-share|3000|обмен файлами"
    "excalidraw|excalidraw/excalidraw|80|доска для схем"
    "searxng|searxng/searxng|8080|метапоисковик"
    "sharry|jlesage/sharry|9090|обмен файлами"
    "audiobookshelf|advplyr/audiobookshelf|80|аудиокниги"
    "kavita|jvmilazz0/kavita|5000|читалка"
    "kodbox|kodcloud/kodbox|80|облачный диск"
    "navidrome|deluan/navidrome|4533|музыкальный сервер"
    "gitea|gitea/gitea|3000|git-хостинг"
    "fluffy-web|aceberg/fluffychat|80|matrix-клиент"
)

select_service() {
    local items=("random|Случайный сервис|выберу сам|") s name img port desc c
    for s in "${SERVICES[@]}"; do
        IFS='|' read -r name img port desc <<<"$s"
        items+=("$name|$name|$desc · $img|")
    done
    ui_menu c "Docker-сервис для заглушки" -d "${SERVICE_NAME:-random}" "${items[@]}" || return 1
    local sel=""
    if [ "$c" = "random" ]; then
        sel="${SERVICES[$(( RANDOM % ${#SERVICES[@]} ))]}"
    else
        for s in "${SERVICES[@]}"; do [ "${s%%|*}" = "$c" ] && sel="$s"; done
    fi
    IFS='|' read -r SERVICE_NAME SERVICE_IMAGE SERVICE_PORT _ <<<"$sel"
    ok "Сервис: ${C_B}$SERVICE_NAME${C_RST} ${C_DIM}($SERVICE_IMAGE)${C_RST}"
}

TEMPLATES=()

fetch_template_list() {
    TEMPLATES=()
    local json names n
    json=$(curl -fsSL --max-time 20 "https://api.github.com/repos/$TPL_REPO/contents/?ref=$TPL_BRANCH" 2>/dev/null) || json=""
    if [ -n "$json" ] && has jq; then
        names=$(jq -r '.[] | select(.type=="dir") | .name' <<<"$json" 2>/dev/null || true)
        for n in $names; do
            case "$n" in previews|.github|assets|docs) continue ;; esac
            [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]] && TEMPLATES+=("$n")
        done
    fi
    if [ "${#TEMPLATES[@]}" -eq 0 ]; then
        warn "Не удалось получить список шаблонов с GitHub — использую встроенный"
        TEMPLATES=("${TPL_FALLBACK[@]}")
    fi
}

select_template() {
    info "Загружаю список шаблонов из ${C_B}$TPL_REPO${C_RST}…"
    fetch_template_list
    local items=("random|Случайный шаблон||") t c
    for t in "${TEMPLATES[@]}"; do items+=("$t|$t||"); done
    ui_menu c "Статический шаблон ($TPL_REPO)" -d "${TEMPLATE_NAME:-random}" "${items[@]}" || return 1
    if [ "$c" = "random" ]; then
        TEMPLATE_NAME="${TEMPLATES[$(( RANDOM % ${#TEMPLATES[@]} ))]}"
    else
        TEMPLATE_NAME="$c"
    fi
    ok "Шаблон: ${C_B}$TEMPLATE_NAME${C_RST}"
    if ui_confirm "Уникализировать шаблон (классы, id, css-переменные)?" y; then UNIQUIFY="yes"
    elif ui_back; then return 1
    else UNIQUIFY="no"
    fi
    return 0
}

deploy_template() {
    title "Статическая заглушка: $TEMPLATE_NAME"
    local tmp; tmp=$(mktemp -d)
    local tarball="https://codeload.github.com/$TPL_REPO/tar.gz/refs/heads/$TPL_BRANCH"

    pb_init 14
    step 8 "Загрузка репозитория шаблонов" "curl -fsSL --proto '=https' --max-time 60 '$tarball' -o '$tmp/tpl.tar.gz'"
    step 3 "Распаковка" "tar -tzf '$tmp/tpl.tar.gz' | grep -qE '(^/|(^|/)\\.\\.(/|\$))' && exit 1; tar -xzf '$tmp/tpl.tar.gz' -C '$tmp' --no-same-owner"

    local src
    src=$(find "$tmp" -mindepth 2 -maxdepth 2 -type d -name "$TEMPLATE_NAME" | head -n1)
    [ -z "$src" ] && { rm -rf "$tmp"; die "Шаблон $TEMPLATE_NAME не найден в репозитории"; }

    if [ "${UNIQUIFY:-no}" = "yes" ]; then
        local uniq_script
        uniq_script=$(find "$tmp" -maxdepth 2 -type f -name "uniquify-theme.sh" | head -n1)
        if [ -n "$uniq_script" ]; then
            cp "$uniq_script" "$src/uniquify-theme.sh"
            chmod +x "$src/uniquify-theme.sh"
            local seed out="$tmp/uniq"
            seed=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
            info "Уникализация ${C_DIM}(seed: $seed)${C_RST}…"
            if ( cd "$src" && ./uniquify-theme.sh --no-zip -o "$out" --seed "$seed" ) >>"$LOG_FILE" 2>&1 \
               && [ -f "$out/index.html" ]; then
                src="$out"
                ok "Шаблон уникализирован"
            else
                warn "Уникализация не удалась — ставлю оригинальный шаблон (детали в логе)"
            fi
        else
            warn "uniquify-theme.sh не найден в репозитории — пропускаю"
        fi
    fi
    rm -f "$src/uniquify-theme.sh"

    step 3 "Установка файлов в $SITE_DIR" \
        "rm -rf '$SITE_DIR' && mkdir -p '$SITE_DIR' && cp -a '$src'/. '$SITE_DIR'/ && chown -R root:root '$SITE_DIR' && chmod -R a+rX,go-w '$SITE_DIR'"
    rm -rf "$tmp"
    [ -f "$SITE_DIR/robots.txt" ] || printf 'User-agent: *\nDisallow: /\n' >"$SITE_DIR/robots.txt"
    ok "Заглушка развёрнута ${C_DIM}($(find "$SITE_DIR" -type f | wc -l) файлов)${C_RST}"
}

deploy_service() {
    title "Маскировочный сервис: $SERVICE_NAME"
    mkdir -p "/opt/$SERVICE_NAME"
    cat >"/opt/$SERVICE_NAME/docker-compose.yml" <<EOF
services:
  $SERVICE_NAME:
    container_name: $SERVICE_NAME
    image: $SERVICE_IMAGE
    restart: unless-stopped
    ports:
      - "127.0.0.1:$APP_PORT:$SERVICE_PORT"
EOF
    pb_init 10
    step 10 "Запуск контейнера $SERVICE_NAME" "docker compose -f '/opt/$SERVICE_NAME/docker-compose.yml' up -d"
}

choose_stub() {
    title "Заглушка сайта"
    note "Это увидит случайный посетитель, открывший домен в браузере."
    local c
    ui_menu c "Тип заглушки" -d "${STUB_MODE:-static}" \
        "static|Статический шаблон с GitHub|$TPL_REPO, можно уникализировать|" \
        "service|Docker-сервис из списка|filebrowser, memos, gitea… за nginx|" \
        "none|Без заглушки|location / отдаёт 401|" || return 1
    case "$c" in
        service)
            STUB_MODE="service"
            select_service || return 1
            ui_input APP_PORT "Локальный порт для сервиса" "${APP_PORT:-$DEFAULT_APP_PORT}" valid_port || return 1
            ;;
        none)
            STUB_MODE="none"; SERVICE_NAME=""; TEMPLATE_NAME=""
            info "location / в nginx будет отдавать 401"
            ;;
        *)
            STUB_MODE="static"; SERVICE_NAME=""
            select_template || return 1
            ;;
    esac
    return 0
}

deploy_stub() {
    case "${STUB_MODE:-none}" in
        service) deploy_service ;;
        static)  deploy_template ;;
    esac
    return 0
}

action_stub() {
    ui_screen "Заглушка сайта"
    choose_stub || { cfg_revert; return 0; }
    deploy_stub
    if [ -z "${DOMAIN:-}" ] || [ ! -f "$CERT_PEM" ]; then
        warn "Домен или сертификат не найдены — конфиг nginx не перегенерирован."
        note "Запусти «Установить Remnanode», чтобы собрать конфигурацию целиком."
        cfg_save
        return 0
    fi
    XHTTP_PATH="${XHTTP_PATH:-/xhttppath/}"
    GRPC_PATH="${GRPC_PATH:-/grpcpath}"
    write_nginx
    cfg_save
    ok "Nginx обновлён под выбранную заглушку"
}
