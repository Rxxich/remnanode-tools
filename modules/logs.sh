# shellcheck shell=bash

setup_xray_logs() {
    title "Логи Xray и logrotate"
    pb_init 8
    step 1 "Создание $LOG_DIR" "mkdir -p '$LOG_DIR'"
    has logrotate || step 6 "Установка logrotate" "apt-get ${APT_OPTS[*]} install logrotate"
    cat >"$LOGROTATE_FILE" <<EOF
$LOG_DIR/*.log {
    daily
    rotate 365
    maxsize 500M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
}
EOF
    step 1 "Проверка конфигурации logrotate" "logrotate -d '$LOGROTATE_FILE'"
    XRAY_LOGS="yes"
    cfg_save
    ok "Logrotate настроен: $LOGROTATE_FILE"
}

action_xray_logs() {
    ui_screen "Логи Xray"
    setup_xray_logs
    if [ -f "$NODE_DIR/docker-compose.yml" ]; then
        if [ -z "${SECRET_KEY:-}" ]; then
            warn "SECRET_KEY не найден в конфиге — compose не перегенерирован."
            note "Добавь вручную:  - $LOG_DIR:$CONTAINER_LOG_DIR"
            return 0
        fi
        write_node_compose
        restart_node
        ok "Том логов добавлен в docker-compose, нода перезапущена"
    else
        info "Remnanode ещё не установлен — логи подключатся при установке"
    fi
    echo
    info "Не забудь включить логи в конфиге Xray на панели, например:"
    printf '%s' "$C_DIM"
    cat <<EOF
      "log": { "loglevel": "info",
        "access": "$CONTAINER_LOG_DIR/access.log",
        "error":  "$CONTAINER_LOG_DIR/error.log" }
EOF
    printf '%s' "$C_RST"
    [ "$LOG_DIR" != "$CONTAINER_LOG_DIR" ] && note "На хосте файлы лягут в $LOG_DIR (том проброшен на $CONTAINER_LOG_DIR)."
    return 0
}
