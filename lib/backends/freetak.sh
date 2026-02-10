#!/usr/bin/env bash
# FreeTAKServer Backend (Lite tier)
# TCP-only, no auth, zero friction

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

backend_name() {
    echo "FreeTAKServer"
}

backend_supports() {
    local cap="$1"
    case "$cap" in
        ssl|users|webmap|federation) return 1 ;;  # Lite tier: none
        *) return 1 ;;
    esac
}

backend_get_ports() {
    load_config
    echo "COT:${COT_PORT:-8087} SSL:${SSL_COT_PORT:-8089} API:${API_PORT:-19023}"
}

backend_start() {
    load_config
    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        _freetak_docker_start
    else
        _freetak_native_start
    fi
}

backend_stop() {
    load_config
    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        _freetak_docker_stop
    else
        _freetak_native_stop
    fi
}

backend_status() {
    load_config
    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        local compose_cmd
        compose_cmd=$(get_compose_cmd)
        if [[ -z "$compose_cmd" ]]; then
            return 1
        fi
        local state
        state=$(cd "$DOCKER_DIR" && $compose_cmd ps --format '{{.State}}' 2>/dev/null | head -1)
        [[ "$state" == "running" ]]
    else
        [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
    fi
}

backend_logs() {
    load_config

    local follow="${1:-}"

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        local compose_cmd
        compose_cmd=$(get_compose_cmd)
        if [[ -z "$compose_cmd" ]]; then
            log_error "Docker Compose not available."
            return 1
        fi
        if [[ "$follow" == "-f" || "$follow" == "--follow" ]]; then
            (cd "$DOCKER_DIR" && $compose_cmd logs -f --tail=100)
        else
            (cd "$DOCKER_DIR" && $compose_cmd logs --tail=50)
        fi
    else
        if [[ ! -f "$LOG_FILE" ]]; then
            log_info "No log file yet. Start the server first."
            return 0
        fi
        if [[ "$follow" == "-f" || "$follow" == "--follow" ]]; then
            tail -f "$LOG_FILE"
        else
            tail -50 "$LOG_FILE"
        fi
    fi
}

backend_update() {
    load_config

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        log_step "Updating Docker image"
        local compose_cmd
        compose_cmd=$(get_compose_cmd)
        if [[ -z "$compose_cmd" ]]; then
            log_error "Docker Compose not available."
            return 1
        fi
        (cd "$DOCKER_DIR" && $compose_cmd build --no-cache --quiet)
        log_ok "Image rebuilt. Restart with: ./heartbeat restart"
    else
        log_step "Updating FreeTAKServer"
        local venv_dir="${DATA_DIR}/venv"
        if [[ ! -d "$venv_dir" ]]; then
            log_error "Virtualenv not found. Run ./setup.sh first."
            return 1
        fi
        "${venv_dir}/bin/pip" install --quiet --upgrade FreeTAKServer
        log_ok "Updated. Restart with: ./heartbeat restart"
    fi
}

backend_install() {
    # setup.sh handles install for FreeTAKServer
    :
}

backend_uninstall() {
    source "${LIB_DIR}/install.sh"
    uninstall
}

backend_get_package() {
    local name="$1"
    source "${LIB_DIR}/package.sh"
    generate_package "$name"
}

backend_health_check() {
    load_config
    local issues=0

    if ! port_listening "${COT_PORT:-8087}"; then
        log_warn "TCP CoT port ${COT_PORT:-8087} not listening"
        issues=$((issues + 1))
    fi

    if [[ "$DEPLOY_MODE" == "native" && -f "$PID_FILE" ]] && ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log_warn "Stale PID file detected at ${PID_FILE}; removing it."
        rm -f "$PID_FILE"
    fi

    return $((issues > 0 ? 1 : 0))
}

# --- Private FreeTAK functions ---

_freetak_docker_start() {
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -z "$compose_cmd" ]]; then
        log_error "Docker Compose not available."
        return 1
    fi

    log_step "Starting TAK server (Docker)"

    # Export all config vars for docker-compose env substitution
    export COT_PORT SSL_COT_PORT API_PORT DATAPACKAGE_PORT
    export FTS_CONNECTION_MSG SERVER_IP

    (cd "$DOCKER_DIR" && $compose_cmd up -d --build)
}

_freetak_native_start() {
    local venv_dir="${DATA_DIR}/venv"
    local fts_dir="${DATA_DIR}/fts"

    if [[ ! -d "$venv_dir" ]]; then
        log_error "FreeTAKServer not installed. Run ./setup.sh first."
        return 1
    fi

    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log_warn "Server already running (PID $(cat "$PID_FILE"))"
        return 0
    fi

    log_step "Starting TAK server (native)"

    ensure_dir "$(dirname "$LOG_FILE")"

    export FTS_CONFIG_PATH="${fts_dir}/FTSConfig.yaml"

    nohup "${venv_dir}/bin/python3" -m FreeTAKServer.controllers.services.FTS \
        >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    log_info "PID: $(cat "$PID_FILE")"

}

_freetak_docker_stop() {
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -z "$compose_cmd" ]]; then
        log_error "Docker Compose not available."
        return 1
    fi

    log_step "Stopping TAK server"
    (cd "$DOCKER_DIR" && $compose_cmd down)
    rm -f "${DOCKER_DIR}/docker-compose.override.yml" 2>/dev/null
    log_ok "Server stopped"
}

_freetak_native_stop() {
    if [[ ! -f "$PID_FILE" ]]; then
        log_warn "No PID file found. Server may not be running."
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")

    log_step "Stopping TAK server (PID ${pid})"

    if kill "$pid" 2>/dev/null; then
        # Wait for graceful shutdown
        local i=0
        while kill -0 "$pid" 2>/dev/null && [[ $i -lt 10 ]]; do
            sleep 1
            i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Graceful shutdown timed out, forcing..."
            kill -9 "$pid" 2>/dev/null || true
        fi
        log_ok "Server stopped"
    else
        log_warn "Process $pid not found (already stopped?)"
    fi

    rm -f "$PID_FILE"
}
