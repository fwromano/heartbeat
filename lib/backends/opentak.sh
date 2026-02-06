#!/usr/bin/env bash
# OpenTAK Server Backend (Standard tier)
# Built-in WebTAK, SSL support, user management via WebTAK UI

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

OPENTAK_DIR="${DOCKER_DIR}/opentak"
OPENTAK_COMPOSE="${OPENTAK_DIR}/docker-compose.yml"

backend_name() {
    echo "OpenTAK Server"
}

backend_supports() {
    local cap="$1"
    case "$cap" in
        ssl) return 0 ;;           # Yes - SSL supported
        users) return 0 ;;         # Yes - via WebTAK UI
        webmap) return 0 ;;        # Yes - built-in WebTAK
        federation) return 1 ;;    # Limited
        *) return 1 ;;
    esac
}

backend_get_ports() {
    load_config
    echo "COT:${COT_PORT:-8087} SSL:${SSL_COT_PORT:-8089} WebTAK:${WEBTAK_PORT:-8080} API:${API_PORT:-8443}"
}

backend_start() {
    load_config

    if ! has_docker; then
        log_error "OpenTAK backend requires Docker."
        return 1
    fi

    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -z "$compose_cmd" ]]; then
        log_error "Docker Compose not available."
        return 1
    fi

    log_step "Starting TAK server (OpenTAK)"

    # Export config vars for docker-compose
    export COT_PORT SSL_COT_PORT API_PORT SERVER_IP
    export WEBTAK_PORT="${WEBTAK_PORT:-8080}"

    # Ensure data dirs exist
    ensure_dir "${OPENTAK_DIR}/data"
    ensure_dir "${OPENTAK_DIR}/certs"

    (cd "$OPENTAK_DIR" && $compose_cmd up -d)

    log_ok "OpenTAK started"
    log_info "WebTAK available at: http://${SERVER_IP}:${WEBTAK_PORT}/"
}

backend_stop() {
    load_config

    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -z "$compose_cmd" ]]; then
        log_error "Docker Compose not available."
        return 1
    fi

    log_step "Stopping TAK server (OpenTAK)"
    (cd "$OPENTAK_DIR" && $compose_cmd down)
    log_ok "Server stopped"
}

backend_status() {
    load_config

    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    [[ -z "$compose_cmd" ]] && return 1

    local state
    state=$(cd "$OPENTAK_DIR" && $compose_cmd ps --format '{{.State}}' 2>/dev/null | head -1)
    [[ "$state" == "running" ]]
}

backend_logs() {
    load_config
    local follow="${1:-}"

    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -z "$compose_cmd" ]]; then
        log_error "Docker Compose not available."
        return 1
    fi

    if [[ "$follow" == "-f" || "$follow" == "--follow" ]]; then
        (cd "$OPENTAK_DIR" && $compose_cmd logs -f --tail=100)
    else
        (cd "$OPENTAK_DIR" && $compose_cmd logs --tail=50)
    fi
}

backend_update() {
    load_config

    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -z "$compose_cmd" ]]; then
        log_error "Docker Compose not available."
        return 1
    fi

    log_step "Updating OpenTAK image"
    (cd "$OPENTAK_DIR" && $compose_cmd pull)
    log_ok "Image updated. Restart with: ./heartbeat restart"
}

backend_install() {
    # Docker pull happens on first start
    :
}

backend_uninstall() {
    load_config

    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -n "$compose_cmd" ]]; then
        (cd "$OPENTAK_DIR" && $compose_cmd down -v 2>/dev/null) || true
    fi

    if prompt_yn "Remove OpenTAK data?" "n"; then
        rm -rf "${OPENTAK_DIR}/data" "${OPENTAK_DIR}/certs"
        log_ok "Data removed"
    fi
}

backend_get_package() {
    local name="$1"
    # OpenTAK generates packages via WebTAK UI or API
    # For now, generate a basic TCP package like FreeTAK
    source "${LIB_DIR}/package.sh"
    generate_package "$name"
}
