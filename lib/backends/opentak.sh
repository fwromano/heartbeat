#!/usr/bin/env bash
# OpenTAK Server Backend (Standard tier)
# Native systemd + nginx + rabbitmq + postgres install

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

backend_name() {
    echo "OpenTAK Server"
}

backend_supports() {
    local cap="$1"
    case "$cap" in
        ssl|users|webmap) return 0 ;;
        federation) return 1 ;;
        *) return 1 ;;
    esac
}

backend_get_ports() {
    load_config
    echo "COT:${COT_PORT:-8087} SSL:${SSL_COT_PORT:-8089} WebTAK:${WEBTAK_PORT:-8443} API:${API_PORT:-8443}"
}

backend_start() {
    load_config

    if [[ ! -f /etc/systemd/system/opentakserver.service ]]; then
        log_error "OpenTAK systemd service not found."
        log_error "Run: ./setup.sh --backend opentak"
        return 1
    fi

    log_step "Starting TAK server (OpenTAK)"
    sudo systemctl start opentakserver.service
    log_ok "OpenTAK started"
    log_info "WebTAK: https://${SERVER_IP}:${WEBTAK_PORT:-8443}/"
}

backend_stop() {
    log_step "Stopping TAK server (OpenTAK)"
    sudo systemctl stop opentakserver.service cot_parser.service eud_handler.service eud_handler_ssl.service 2>/dev/null || true
    log_ok "Server stopped"
}

backend_status() {
    systemctl is-active --quiet opentakserver.service
}

backend_logs() {
    local follow="${1:-}"
    local ots_log="${DATA_DIR}/opentak/logs/opentakserver.log"

    if [[ -f "$ots_log" ]]; then
        if [[ "$follow" == "-f" || "$follow" == "--follow" ]]; then
            tail -f "$ots_log"
        else
            tail -50 "$ots_log"
        fi
        return 0
    fi

    if [[ "$follow" == "-f" || "$follow" == "--follow" ]]; then
        sudo journalctl -u opentakserver.service -f -n 100
    else
        sudo journalctl -u opentakserver.service -n 50 --no-pager
    fi
}

backend_update() {
    local ots_venv="${DATA_DIR}/opentak/venv"
    if [[ ! -x "${ots_venv}/bin/pip" ]]; then
        log_error "OpenTAK venv not found. Run setup first."
        return 1
    fi

    log_step "Updating OpenTAK package"
    "${ots_venv}/bin/pip" install --quiet --upgrade opentakserver
    log_ok "OpenTAK updated. Restart with: ./heartbeat restart"
}

backend_install() {
    :
}

backend_uninstall() {
    local ots_dir="${DATA_DIR}/opentak"

    sudo systemctl stop opentakserver.service cot_parser.service eud_handler.service eud_handler_ssl.service 2>/dev/null || true
    sudo systemctl disable opentakserver.service cot_parser.service eud_handler.service eud_handler_ssl.service 2>/dev/null || true

    sudo rm -f /etc/systemd/system/opentakserver.service
    sudo rm -f /etc/systemd/system/cot_parser.service
    sudo rm -f /etc/systemd/system/eud_handler.service
    sudo rm -f /etc/systemd/system/eud_handler_ssl.service
    sudo systemctl daemon-reload

    sudo rm -f /etc/nginx/sites-enabled/ots_http
    sudo rm -f /etc/nginx/sites-enabled/ots_https
    sudo rm -f /etc/nginx/sites-enabled/ots_certificate_enrollment
    sudo rm -f /etc/nginx/sites-available/ots_http
    sudo rm -f /etc/nginx/sites-available/ots_https
    sudo rm -f /etc/nginx/sites-available/ots_certificate_enrollment
    sudo rm -f /etc/nginx/streams-enabled/rabbitmq
    sudo rm -f /etc/nginx/streams-available/rabbitmq
    sudo nginx -s reload 2>/dev/null || true

    if prompt_yn "Remove OpenTAK data (venv, certs, config)?" "y"; then
        rm -rf "${ots_dir}"
        log_ok "OpenTAK data removed"
    fi

    if prompt_yn "Drop PostgreSQL database 'ots'?" "n"; then
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS ots;"
        sudo -u postgres psql -c "DROP ROLE IF EXISTS ots;"
        log_ok "PostgreSQL database and role removed"
    fi
}

backend_get_package() {
    local name="$1"
    source "${LIB_DIR}/package.sh"
    generate_package "$name"
}
