#!/usr/bin/env bash
# Heartbeat - Installation logic
# Handles both Docker and native FreeTAKServer installation

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Install system prerequisites
# ---------------------------------------------------------------------------
install_system_deps() {
    log_step "Installing system dependencies"

    if has_cmd apt-get; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq \
            python3 python3-pip python3-venv \
            zip unzip curl net-tools qrencode \
            libxml2-dev libxslt1-dev gcc 2>/dev/null
        log_ok "System dependencies installed"
    elif has_cmd dnf; then
        sudo dnf install -y -q \
            python3 python3-pip \
            zip unzip curl net-tools qrencode \
            libxml2-devel libxslt-devel gcc 2>/dev/null
        log_ok "System dependencies installed"
    elif has_cmd pacman; then
        sudo pacman -Sy --noconfirm --needed \
            python python-pip \
            zip unzip curl net-tools qrencode \
            libxml2 libxslt gcc 2>/dev/null
        log_ok "System dependencies installed"
    else
        log_warn "Could not detect package manager."
        log_warn "Ensure python3, pip, zip, and curl are installed."
    fi
}

# ---------------------------------------------------------------------------
# Docker-based installation
# ---------------------------------------------------------------------------
install_docker_mode() {
    log_step "Setting up Docker deployment"

    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -z "$compose_cmd" ]]; then
        log_error "Docker Compose not found."
        log_error "Install Docker: https://docs.docker.com/engine/install/"
        return 1
    fi

    load_config

    # Generate secret key
    local secret
    secret=$(gen_secret)
    set_config "FTS_SECRET_KEY" "$secret"

    # Always regenerate FTSConfig.yaml from current config values
    # FTS_USER_ADDRESS must be the real server IP (not 0.0.0.0) so that
    # enrollment data packages contain the correct address for clients.
    cat > "${DOCKER_DIR}/FTSConfig.yaml" <<YAML
System:
  FTS_CONNECTION_MESSAGE: "${FTS_CONNECTION_MSG}"
  FTS_OPTIMIZE_API: true
  FTS_SECRET_KEY: "${secret}"

Addresses:
  FTS_COT_PORT: ${COT_PORT}
  FTS_SSLCOT_PORT: ${SSL_COT_PORT}
  FTS_DP_ADDRESS: "${SERVER_IP}"
  FTS_USER_ADDRESS: "${SERVER_IP}"
  FTS_API_PORT: ${API_PORT}
  FTS_FED_PORT: 9000
  FTS_API_ADDRESS: "0.0.0.0"

FileSystem:
  FTS_DB_PATH: "/opt/fts/data"
  FTS_COT_TO_DB: true
  FTS_MAINPATH: "/opt/fts"
  FTS_CERTS_PATH: "/opt/fts/certs"
  FTS_EXCHECK_PATH: "/opt/fts/ExCheck"
  FTS_EXCHECK_TEMPLATE_PATH: "/opt/fts/ExCheck/template"
  FTS_EXCHECK_CHECKLIST_PATH: "/opt/fts/ExCheck/checklist"
  FTS_DATAPACKAGE_PATH: "/opt/fts/FreeTAKServerDataPackages"
  FTS_LOGFILE_PATH: "/opt/fts/logs"
YAML

    # Create data directories
    ensure_dir "${DOCKER_DIR}/data"
    ensure_dir "${DOCKER_DIR}/logs"
    ensure_dir "${DOCKER_DIR}/certs"

    # Build the image
    log_info "Building FreeTAKServer Docker image..."
    (cd "$DOCKER_DIR" && $compose_cmd build --quiet)

    log_ok "Docker deployment ready"
}

# ---------------------------------------------------------------------------
# Native (pip) installation
# ---------------------------------------------------------------------------
install_native_mode() {
    log_step "Setting up native deployment"

    install_system_deps

    local venv_dir="${DATA_DIR}/venv"

    # Create virtualenv
    log_info "Creating Python virtual environment..."
    python3 -m venv "$venv_dir"

    # Install FreeTAKServer in the venv
    log_info "Installing FreeTAKServer (this may take a moment)..."
    "${venv_dir}/bin/pip" install --quiet --upgrade pip
    "${venv_dir}/bin/pip" install --quiet FreeTAKServer

    load_config

    # Generate FTS config
    local secret
    secret=$(gen_secret)
    set_config "FTS_SECRET_KEY" "$secret"

    local fts_dir="${DATA_DIR}/fts"
    ensure_dir "${fts_dir}"
    ensure_dir "${fts_dir}/data"
    ensure_dir "${fts_dir}/certs"
    ensure_dir "${fts_dir}/logs"
    ensure_dir "${fts_dir}/ExCheck/template"
    ensure_dir "${fts_dir}/ExCheck/checklist"
    ensure_dir "${fts_dir}/FreeTAKServerDataPackages"

    set_config "FTS_DATA_DIR" "$fts_dir"

    # Write FTS YAML config
    cat > "${fts_dir}/FTSConfig.yaml" <<YAML
System:
  FTS_CONNECTION_MESSAGE: "${FTS_CONNECTION_MSG}"
  FTS_OPTIMIZE_API: true
  FTS_SECRET_KEY: "${secret}"

Addresses:
  FTS_COT_PORT: ${COT_PORT}
  FTS_SSLCOT_PORT: ${SSL_COT_PORT}
  FTS_DP_ADDRESS: "${SERVER_IP}"
  FTS_USER_ADDRESS: "${SERVER_IP}"
  FTS_API_PORT: ${API_PORT}
  FTS_FED_PORT: 9000
  FTS_API_ADDRESS: "127.0.0.1"

FileSystem:
  FTS_DB_PATH: "${fts_dir}/data"
  FTS_COT_TO_DB: true
  FTS_MAINPATH: "${fts_dir}"
  FTS_CERTS_PATH: "${fts_dir}/certs"
  FTS_EXCHECK_PATH: "${fts_dir}/ExCheck"
  FTS_EXCHECK_TEMPLATE_PATH: "${fts_dir}/ExCheck/template"
  FTS_EXCHECK_CHECKLIST_PATH: "${fts_dir}/ExCheck/checklist"
  FTS_DATAPACKAGE_PATH: "${fts_dir}/FreeTAKServerDataPackages"
  FTS_LOGFILE_PATH: "${fts_dir}/logs"
YAML

    log_ok "Native deployment ready"
    log_info "Start with: ./heartbeat start"
}

# ---------------------------------------------------------------------------
# Install systemd service (native mode only)
# ---------------------------------------------------------------------------
install_systemd_service() {
    load_config
    if [[ "$DEPLOY_MODE" != "native" ]]; then
        log_warn "Systemd service only applies to native mode."
        return 1
    fi

    require_root

    local venv_dir="${DATA_DIR}/venv"
    local fts_dir="${DATA_DIR}/fts"

    cat > /etc/systemd/system/heartbeat-tak.service <<EOF
[Unit]
Description=Heartbeat TAK Server (FreeTAKServer)
After=network.target

[Service]
Type=simple
User=$(whoami)
Environment=FTS_CONFIG_PATH=${fts_dir}/FTSConfig.yaml
ExecStart=${venv_dir}/bin/python3 -m FreeTAKServer.controllers.services.FTS
WorkingDirectory=${fts_dir}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable heartbeat-tak.service

    log_ok "Systemd service installed and enabled"
    log_info "Manage with: sudo systemctl {start|stop|status} heartbeat-tak"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    log_step "Uninstalling Heartbeat TAK"

    load_config

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        local compose_cmd
        compose_cmd=$(get_compose_cmd)
        if [[ -n "$compose_cmd" ]]; then
            (cd "$DOCKER_DIR" && $compose_cmd down -v 2>/dev/null) || true
        fi
        log_ok "Docker containers removed"
    else
        # Stop native service
        if [[ -f "$PID_FILE" ]]; then
            local pid
            pid=$(cat "$PID_FILE")
            kill "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
        fi
        # Remove systemd service if exists
        if [[ -f /etc/systemd/system/heartbeat-tak.service ]]; then
            sudo systemctl stop heartbeat-tak 2>/dev/null || true
            sudo systemctl disable heartbeat-tak 2>/dev/null || true
            sudo rm -f /etc/systemd/system/heartbeat-tak.service
            sudo systemctl daemon-reload
        fi
        # Remove venv
        rm -rf "${DATA_DIR}/venv"
        log_ok "Native installation removed"
    fi

    if prompt_yn "Remove data directory (${DATA_DIR})?" "n"; then
        rm -rf "$DATA_DIR"
        log_ok "Data directory removed"
    fi

    if prompt_yn "Remove generated packages?" "n"; then
        rm -rf "$PACKAGES_DIR"/*.zip
        log_ok "Packages removed"
    fi

    log_ok "Uninstall complete"
}
