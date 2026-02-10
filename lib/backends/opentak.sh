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
    echo "COT:${COT_PORT:-8088} SSL:${SSL_COT_PORT:-8089} WebTAK:${WEBTAK_PORT:-8443} API:${API_PORT:-8443}"
}

backend_start() {
    load_config

    if ! _opentak_preflight; then
        return 1
    fi

    if [[ ! -f /etc/systemd/system/opentakserver.service ]]; then
        log_error "OpenTAK systemd service not found."
        log_error "Run: ./setup.sh --backend opentak"
        return 1
    fi

    if opentak_runtime_patches_enabled; then
        if ! opentak_apply_runtime_patches "${DATA_DIR}/opentak/venv"; then
            log_warn "OpenTAK runtime hotfixes were not applied"
        fi
    fi

    _opentak_ensure_socketio_exchange

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

backend_reset() {
    log_step "Resetting TAK server stack (OpenTAK + dependencies)"

    # Stop OTS workers first so no active consumers hold stale channels.
    backend_stop

    # Restart broker + dependencies to clear stale runtime state.
    sudo systemctl restart rabbitmq-server
    sudo systemctl restart postgresql
    sudo systemctl restart nginx

    # Bring OTS stack back up.
    backend_start
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
    load_config

    local ots_venv="${DATA_DIR}/opentak/venv"
    if [[ ! -x "${ots_venv}/bin/pip" ]]; then
        log_error "OpenTAK venv not found. Run setup first."
        return 1
    fi

    local opentak_spec
    opentak_spec="$(opentak_pip_spec)"

    log_step "Updating OpenTAK package"
    if [[ "$opentak_spec" == "opentakserver" ]]; then
        log_info "Update source: PyPI (opentakserver)"
    else
        log_info "Update source: ${OTS_GIT_URL}${OTS_GIT_REF:+ @ ${OTS_GIT_REF}}"
    fi
    "${ots_venv}/bin/pip" install --quiet --upgrade "$opentak_spec"
    if opentak_runtime_patches_enabled; then
        if opentak_apply_runtime_patches "${ots_venv}"; then
            log_ok "Re-applied OpenTAK runtime hotfixes"
        else
            log_warn "OpenTAK runtime hotfixes were not re-applied"
        fi
    fi
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

backend_health_check() {
    local issues=0
    load_config

    for svc in opentakserver cot_parser eud_handler eud_handler_ssl; do
        if ! systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
            log_warn "Service ${svc} is not running"
            issues=$((issues + 1))
        fi
    done

    if ! port_listening "${COT_PORT:-8088}"; then
        log_warn "TCP CoT port ${COT_PORT:-8088} not listening"
        issues=$((issues + 1))
    fi
    if ! port_listening "${SSL_COT_PORT:-8089}"; then
        log_warn "SSL CoT port ${SSL_COT_PORT:-8089} not listening"
        issues=$((issues + 1))
    fi
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        log_warn "nginx is not running (WebTAK will be unavailable)"
        issues=$((issues + 1))
    fi

    return $((issues > 0 ? 1 : 0))
}

_opentak_preflight() {
    local ots_dir="${DATA_DIR}/opentak"

    if [[ ! -f /etc/systemd/system/opentakserver.service ]]; then
        log_error "OpenTAK not installed. Run: ./setup.sh --backend opentak"
        return 1
    fi

    if [[ ! -x "${ots_dir}/venv/bin/opentakserver" ]]; then
        log_error "OpenTAK venv is missing or broken at ${ots_dir}/venv."
        log_error "Re-run setup: ./setup.sh --backend opentak"
        return 1
    fi

    if [[ ! -f "${ots_dir}/config.yml" ]]; then
        log_error "OpenTAK config is missing at ${ots_dir}/config.yml."
        log_error "Re-run setup: ./setup.sh --backend opentak"
        return 1
    fi

    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        log_warn "PostgreSQL not running, starting..."
        sudo systemctl start postgresql || return 1
    fi
    if ! systemctl is-active --quiet rabbitmq-server 2>/dev/null; then
        log_warn "RabbitMQ not running, starting..."
        sudo systemctl start rabbitmq-server || return 1
    fi
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        log_warn "nginx not running, starting..."
        sudo systemctl start nginx || return 1
    fi

    return 0
}

_opentak_ensure_socketio_exchange() {
    local ots_dir="${DATA_DIR}/opentak"
    local ots_py="${ots_dir}/venv/bin/python3"
    local ots_cfg="${ots_dir}/config.yml"

    if [[ ! -x "$ots_py" || ! -f "$ots_cfg" ]]; then
        return 0
    fi

    if "$ots_py" - "$ots_cfg" <<'PY' >/dev/null 2>&1
import sys
import yaml
import pika

config_path = sys.argv[1]
with open(config_path, "r", encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh) or {}

host = str(cfg.get("OTS_RABBITMQ_SERVER_ADDRESS") or "127.0.0.1")
port = int(cfg.get("OTS_RABBITMQ_PORT") or 5672)
username = str(cfg.get("OTS_RABBITMQ_USERNAME") or "guest")
password = str(cfg.get("OTS_RABBITMQ_PASSWORD") or "guest")
vhost = str(cfg.get("OTS_RABBITMQ_VHOST") or "/")

params = pika.ConnectionParameters(
    host=host,
    port=port,
    virtual_host=vhost,
    credentials=pika.PlainCredentials(username, password),
)
connection = pika.BlockingConnection(params)
try:
    channel = connection.channel()
    channel.exchange_declare(
        exchange="flask-socketio",
        exchange_type="fanout",
        durable=False,
        auto_delete=False,
    )
finally:
    connection.close()
PY
    then
        _opentak_set_socketio_enabled "true"
        log_info "RabbitMQ exchange ready: flask-socketio"
    else
        _opentak_set_socketio_enabled "false"
        log_warn "Could not pre-create RabbitMQ exchange 'flask-socketio'; disabling OTS socketio publish to prevent channel churn"
    fi

    return 0
}

_opentak_set_socketio_enabled() {
    local enabled="${1:-true}"
    local ots_dir="${DATA_DIR}/opentak"
    local ots_py="${ots_dir}/venv/bin/python3"
    local ots_cfg="${ots_dir}/config.yml"

    if [[ ! -x "$ots_py" || ! -f "$ots_cfg" ]]; then
        return 0
    fi

    "$ots_py" - "$ots_cfg" "$enabled" <<'PY' >/dev/null 2>&1 || true
import sys
import yaml

config_path = sys.argv[1]
enabled = str(sys.argv[2]).strip().lower() in {"1", "true", "yes", "on"}

with open(config_path, "r", encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh) or {}

cfg["OTS_ENABLE_SOCKETIO"] = bool(enabled)

with open(config_path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(cfg, fh, sort_keys=False)
PY
}
