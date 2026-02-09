#!/usr/bin/env bash
# Heartbeat - Installation logic
# Handles FreeTAKServer and OpenTAK backend installation

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
            libxml2-dev libxslt1-dev libgeos-dev gcc 2>/dev/null
        log_ok "System dependencies installed"
    elif has_cmd dnf; then
        sudo dnf install -y -q \
            python3 python3-pip \
            zip unzip curl net-tools qrencode \
            libxml2-devel libxslt-devel geos-devel gcc 2>/dev/null
        log_ok "System dependencies installed"
    elif has_cmd pacman; then
        sudo pacman -Sy --noconfirm --needed \
            python python-pip \
            zip unzip curl net-tools qrencode \
            libxml2 libxslt geos gcc 2>/dev/null
        log_ok "System dependencies installed"
    else
        log_warn "Could not detect package manager."
        log_warn "Ensure python3, pip, zip, and curl are installed."
    fi

    # Install Python packages needed for recording and export tools
    install_python_deps
}

# ---------------------------------------------------------------------------
# Ensure host has python3 + pip (needed for recording/export even in Docker mode)
# ---------------------------------------------------------------------------
ensure_host_python() {
    if has_cmd python3 && has_cmd pip3; then
        return 0
    fi

    log_step "Installing Python3 and pip (needed for CoT tools)"
    if has_cmd apt-get; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq python3 python3-pip libgeos-dev 2>/dev/null
    elif has_cmd dnf; then
        sudo dnf install -y -q python3 python3-pip geos-devel 2>/dev/null
    elif has_cmd pacman; then
        sudo pacman -Sy --noconfirm --needed python python-pip geos 2>/dev/null
    else
        log_warn "Could not install python3/pip automatically."
        log_warn "Install python3 and pip manually, then re-run setup."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Install Python packages for recording & export tools
# ---------------------------------------------------------------------------
install_python_deps() {
    local req="${HEARTBEAT_DIR}/tools/requirements.txt"
    if [[ ! -f "$req" ]]; then
        return 0
    fi

    ensure_host_python || return 0

    log_step "Installing Python dependencies for CoT tools"
    if pip3 install --quiet -r "$req" 2>/dev/null || \
       python3 -m pip install --quiet -r "$req" 2>/dev/null; then
        log_ok "Python dependencies installed (shapely, pyyaml)"
    else
        log_warn "Could not install Python dependencies automatically."
        log_warn "Install manually: pip install -r tools/requirements.txt"
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

    # Install Python deps for recording/export (runs on host, not in container)
    install_python_deps

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
# OpenTAK native installation (contained in data/opentak)
# ---------------------------------------------------------------------------
install_opentak() {
    load_config

    log_step "Installing OpenTAK Server (Standard tier)"

    local ots_dir="${DATA_DIR}/opentak"
    local ots_venv="${ots_dir}/venv"

    install_opentak_system_deps

    ensure_dir "${ots_dir}"
    ensure_dir "${ots_dir}/logs"
    ensure_dir "${ots_dir}/ca"

    log_info "Creating OpenTAK virtual environment..."
    rm -rf "${ots_venv}"
    python3 -m venv "${ots_venv}"
    "${ots_venv}/bin/pip" install --quiet --upgrade pip setuptools wheel
    "${ots_venv}/bin/pip" install --quiet opentakserver
    log_ok "OpenTAK package installed"

    # Setup re-runs should regenerate config instead of reusing stale credentials.
    rm -f "${ots_dir}/config.yml"

    log_info "Generating OpenTAK config"
    (
        cd "${ots_dir}"
        OTS_DATA_FOLDER="${ots_dir}" \
        OTS_CONFIG_PATH="${ots_dir}/config.yml" \
        OTS_CONFIG_FILE="${ots_dir}/config.yml" \
        FLASK_APP=opentakserver.app \
        "${ots_venv}/bin/flask" ots generate-config
    )

    setup_opentak_postgres "${ots_dir}"
    patch_opentak_config "${ots_dir}" "${ots_venv}"

    log_info "Running OpenTAK database migrations"
    local pkg_dir migrations_dir
    pkg_dir=$(_opentak_package_dir "${ots_venv}")
    migrations_dir="${pkg_dir}/migrations"
    if [[ -z "$pkg_dir" || ! -d "$migrations_dir" ]]; then
        log_error "Could not locate OpenTAK migrations directory in venv"
        return 1
    fi
    (
        cd "${ots_dir}"
        OTS_DATA_FOLDER="${ots_dir}" \
        OTS_CONFIG_PATH="${ots_dir}/config.yml" \
        OTS_CONFIG_FILE="${ots_dir}/config.yml" \
        FLASK_APP=opentakserver.app \
        "${ots_venv}/bin/flask" db upgrade -d "${migrations_dir}"
    )

    log_info "Generating OpenTAK CA certificates"
    (
        cd "${ots_dir}"
        OTS_DATA_FOLDER="${ots_dir}" \
        OTS_CONFIG_PATH="${ots_dir}/config.yml" \
        OTS_CONFIG_FILE="${ots_dir}/config.yml" \
        FLASK_APP=opentakserver.app \
        "${ots_venv}/bin/flask" ots create-ca
    )

    setup_opentak_default_user "${ots_dir}" "${ots_venv}"
    setup_opentak_nginx "${ots_dir}"
    setup_opentak_rabbitmq
    create_opentak_services "${ots_dir}" "${ots_venv}"
    install_webtak_ui

    # Recording/export tooling still runs on host python.
    install_python_deps

    log_ok "OpenTAK Server installed and ready"
}

install_opentak_system_deps() {
    if ! has_cmd apt-get; then
        log_error "OpenTAK backend currently supports apt-based systems only."
        return 1
    fi

    log_step "Installing OpenTAK system dependencies"
    sudo apt-get update -qq
    sudo NEEDRESTART_MODE=a apt-get install -y -qq \
        python3 python3-pip python3-venv python3-dev \
        postgresql postgresql-postgis \
        rabbitmq-server \
        nginx libnginx-mod-stream \
        openssl curl unzip 2>/dev/null

    sudo systemctl enable --now postgresql 2>/dev/null || true
    sudo systemctl enable --now rabbitmq-server 2>/dev/null || true
    sudo systemctl enable --now nginx 2>/dev/null || true
    log_ok "OpenTAK dependencies installed"
}

_opentak_package_dir() {
    local ots_venv="$1"
    "${ots_venv}/bin/python3" -c "import os, opentakserver; print(os.path.dirname(opentakserver.__file__))" 2>/dev/null || true
}

setup_opentak_postgres() {
    local ots_dir="$1"
    local db_pass
    db_pass=$(gen_password)

    echo "$db_pass" > "${ots_dir}/db_password"
    chmod 600 "${ots_dir}/db_password"

    local user_exists
    user_exists=$(sudo -u postgres psql -tXAc "SELECT 1 FROM pg_roles WHERE rolname='ots'" 2>/dev/null || true)
    if [[ "$user_exists" != "1" ]]; then
        sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE ots WITH LOGIN PASSWORD '${db_pass}';"
    else
        sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE ots WITH PASSWORD '${db_pass}';"
    fi

    local db_exists
    db_exists=$(sudo -u postgres psql -tXAc "SELECT 1 FROM pg_database WHERE datname='ots'" 2>/dev/null || true)
    if [[ "$db_exists" != "1" ]]; then
        sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ots OWNER ots;"
    fi

    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE ots TO ots;"
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d ots -c "GRANT ALL ON SCHEMA public TO ots;"
    log_ok "PostgreSQL configured for OpenTAK"
}

patch_opentak_config() {
    local ots_dir="$1"
    local ots_venv="$2"
    local config="${ots_dir}/config.yml"

    if [[ ! -f "$config" ]]; then
        log_error "OpenTAK config not found: ${config}"
        return 1
    fi

    local db_pass
    db_pass=$(cat "${ots_dir}/db_password")

    # Replace installer placeholder in generated config.
    sed -i "s/POSTGRESQL_PASSWORD/${db_pass}/g" "$config"

    "${ots_venv}/bin/python3" - "$config" "$ots_dir" "${SERVER_IP}" "${COT_PORT}" "${SSL_COT_PORT}" "$db_pass" <<'PY'
import yaml
import sys

config_path, ots_dir, server_ip, cot_port, ssl_port, db_pass = sys.argv[1:]

with open(config_path, "r", encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh) or {}

def deep_set(obj, key, value):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                obj[k] = value
            else:
                deep_set(v, key, value)
    elif isinstance(obj, list):
        for item in obj:
            deep_set(item, key, value)

cfg["OTS_DATA_FOLDER"] = ots_dir
cfg["OTS_CA_FOLDER"] = f"{ots_dir}/ca"
db_uri = f"postgresql+psycopg://ots:{db_pass}@127.0.0.1/ots"
cfg["SQLALCHEMY_DATABASE_URI"] = db_uri

# Update known keys if present in this OpenTAK release.
for key, value in {
    "OTS_SERVER_ADDRESS": server_ip,
    "OTS_WEBSERVER_PORT": 8081,
    "OTS_COT_PORT": int(cot_port),
    "OTS_SSL_COT_PORT": int(ssl_port),
    "OTS_MEDIAMTX_ENABLE": False,
    "SECURITY_TWO_FACTOR": False,
    "SQLALCHEMY_DATABASE_URI": db_uri,
}.items():
    if key in cfg:
        cfg[key] = value
    deep_set(cfg, key, value)

with open(config_path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(cfg, fh, sort_keys=False)
PY

    log_ok "OpenTAK config patched"
}

_ensure_nginx_stream_include() {
    if sudo grep -q "include /etc/nginx/streams-enabled/\\*;" /etc/nginx/nginx.conf 2>/dev/null; then
        return 0
    fi

    sudo sed -i '/^http {/i stream {\n    include \/etc\/nginx\/streams-enabled\/*;\n}\n' /etc/nginx/nginx.conf
}

setup_opentak_nginx() {
    local ots_dir="$1"
    local ots_cert="${ots_dir}/ca/certs/opentakserver/opentakserver.pem"
    local ots_key="${ots_dir}/ca/certs/opentakserver/opentakserver.nopass.key"

    _ensure_nginx_stream_include

    # Remove stale OTS installer artifacts that can break nginx -t.
    sudo rm -f /etc/nginx/sites-enabled/ots_certificate_enrollment
    sudo rm -f /etc/nginx/sites-available/ots_certificate_enrollment
    sudo rm -f /etc/nginx/streams-enabled/mediamtx
    sudo rm -f /etc/nginx/streams-available/mediamtx

    sudo tee /etc/nginx/sites-available/ots_http >/dev/null <<EOF
server {
    listen 8080;
    server_name _;
    root /var/www/html/opentakserver;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8081/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /Marti/ {
        proxy_pass http://127.0.0.1:8081/Marti/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /SocketIO/ {
        proxy_pass http://127.0.0.1:8081/SocketIO/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

    sudo tee /etc/nginx/sites-available/ots_https >/dev/null <<EOF
server {
    listen 8443 ssl;
    server_name _;
    root /var/www/html/opentakserver;
    index index.html;

    ssl_certificate ${ots_cert};
    ssl_certificate_key ${ots_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8081/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /Marti/ {
        proxy_pass http://127.0.0.1:8081/Marti/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /SocketIO/ {
        proxy_pass http://127.0.0.1:8081/SocketIO/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

    sudo mkdir -p /etc/nginx/streams-available /etc/nginx/streams-enabled
    sudo tee /etc/nginx/streams-available/rabbitmq >/dev/null <<EOF
server {
    listen 8883 ssl;
    proxy_pass 127.0.0.1:1883;
    ssl_certificate ${ots_cert};
    ssl_certificate_key ${ots_key};
}
EOF

    sudo ln -sf /etc/nginx/sites-available/ots_http /etc/nginx/sites-enabled/ots_http
    sudo ln -sf /etc/nginx/sites-available/ots_https /etc/nginx/sites-enabled/ots_https
    sudo ln -sf /etc/nginx/streams-available/rabbitmq /etc/nginx/streams-enabled/rabbitmq

    sudo nginx -t
    if sudo systemctl is-active --quiet nginx; then
        sudo systemctl reload nginx
    else
        sudo systemctl start nginx
    fi
    log_ok "Nginx configured for OpenTAK"
}

setup_opentak_rabbitmq() {
    sudo curl -fsSL \
        https://raw.githubusercontent.com/brian7704/OpenTAKServer-Installer/master/rabbitmq.conf \
        -o /etc/rabbitmq/rabbitmq.conf

    sudo rabbitmq-plugins enable rabbitmq_mqtt rabbitmq_auth_backend_http >/dev/null 2>&1 || true
    sudo systemctl restart rabbitmq-server
    log_ok "RabbitMQ configured"
}

create_opentak_services() {
    local ots_dir="$1"
    local ots_venv="$2"
    local user
    user=$(whoami)

    sudo tee /etc/systemd/system/opentakserver.service >/dev/null <<EOF
[Unit]
Description=OpenTAK Server
Wants=network.target rabbitmq-server.service postgresql.service
After=network.target rabbitmq-server.service postgresql.service
Requires=cot_parser.service eud_handler.service eud_handler_ssl.service

[Service]
Type=simple
User=${user}
WorkingDirectory=${ots_dir}
Environment=OTS_DATA_FOLDER=${ots_dir}
Environment=OTS_CONFIG_PATH=${ots_dir}/config.yml
Environment=OTS_CONFIG_FILE=${ots_dir}/config.yml
ExecStart=${ots_venv}/bin/opentakserver
Restart=on-failure
RestartSec=5s
StandardOutput=append:${ots_dir}/logs/opentakserver.log
StandardError=append:${ots_dir}/logs/opentakserver.log

[Install]
WantedBy=multi-user.target
EOF

    sudo tee /etc/systemd/system/cot_parser.service >/dev/null <<EOF
[Unit]
Description=OpenTAK CoT Parser
Wants=network.target rabbitmq-server.service
After=network.target rabbitmq-server.service
PartOf=opentakserver.service

[Service]
Type=simple
User=${user}
WorkingDirectory=${ots_dir}
Environment=OTS_DATA_FOLDER=${ots_dir}
Environment=OTS_CONFIG_PATH=${ots_dir}/config.yml
Environment=OTS_CONFIG_FILE=${ots_dir}/config.yml
ExecStart=${ots_venv}/bin/cot_parser
Restart=on-failure
RestartSec=5s
StandardOutput=append:${ots_dir}/logs/opentakserver.log
StandardError=append:${ots_dir}/logs/opentakserver.log

[Install]
WantedBy=multi-user.target
EOF

    sudo tee /etc/systemd/system/eud_handler.service >/dev/null <<EOF
[Unit]
Description=OpenTAK EUD Handler (TCP)
Wants=network.target rabbitmq-server.service
After=network.target rabbitmq-server.service
PartOf=opentakserver.service

[Service]
Type=simple
User=${user}
WorkingDirectory=${ots_dir}
Environment=OTS_DATA_FOLDER=${ots_dir}
Environment=OTS_CONFIG_PATH=${ots_dir}/config.yml
Environment=OTS_CONFIG_FILE=${ots_dir}/config.yml
ExecStart=${ots_venv}/bin/eud_handler
Restart=on-failure
RestartSec=5s
StandardOutput=append:${ots_dir}/logs/opentakserver.log
StandardError=append:${ots_dir}/logs/opentakserver.log

[Install]
WantedBy=multi-user.target
EOF

    sudo tee /etc/systemd/system/eud_handler_ssl.service >/dev/null <<EOF
[Unit]
Description=OpenTAK EUD Handler (SSL)
Wants=network.target rabbitmq-server.service
After=network.target rabbitmq-server.service
PartOf=opentakserver.service

[Service]
Type=simple
User=${user}
WorkingDirectory=${ots_dir}
Environment=OTS_DATA_FOLDER=${ots_dir}
Environment=OTS_CONFIG_PATH=${ots_dir}/config.yml
Environment=OTS_CONFIG_FILE=${ots_dir}/config.yml
ExecStart=${ots_venv}/bin/eud_handler --ssl
Restart=on-failure
RestartSec=5s
StandardOutput=append:${ots_dir}/logs/opentakserver.log
StandardError=append:${ots_dir}/logs/opentakserver.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable opentakserver.service cot_parser.service eud_handler.service eud_handler_ssl.service
    log_ok "OpenTAK systemd services installed"
}

install_webtak_ui() {
    local ui_dir="/var/www/html/opentakserver"
    local ui_url
    ui_url=$(curl -fsSL https://api.github.com/repos/brian7704/OpenTAKServer-UI/releases/latest \
        | python3 -c "import json,sys; d=json.load(sys.stdin); a=d.get('assets', []); print(a[0]['browser_download_url'] if a else '')" \
        2>/dev/null || true)

    if [[ -z "$ui_url" ]]; then
        log_warn "Could not determine latest OpenTAK UI release URL"
        return 0
    fi

    local tmp="/tmp/opentak-ui.zip"
    curl -fsSL "$ui_url" -o "$tmp"
    sudo mkdir -p "$ui_dir"
    sudo unzip -qo "$tmp" -d "$ui_dir"
    rm -f "$tmp"
    log_ok "WebTAK UI installed to ${ui_dir}"
}

setup_opentak_default_user() {
    local ots_dir="$1"
    local ots_venv="$2"
    local username="${FTS_USERNAME:-administrator}"
    local password="${FTS_PASSWORD:-password}"

    if [[ ${#password} -lt 8 ]]; then
        log_error "OpenTAK user password for '${username}' must be at least 8 characters."
        return 1
    fi

    log_info "Ensuring OpenTAK admin user exists (${username})"
    if ! (
        cd "${ots_dir}"
        export OTS_DATA_FOLDER="${ots_dir}"
        export OTS_CONFIG_PATH="${ots_dir}/config.yml"
        export OTS_CONFIG_FILE="${ots_dir}/config.yml"
        export FLASK_APP=opentakserver.app

        "${ots_venv}/bin/flask" roles create administrator >/dev/null 2>&1 || true

        if ! "${ots_venv}/bin/flask" users create --username "${username}" --password "${password}" --active >/dev/null 2>&1; then
            "${ots_venv}/bin/flask" users activate "${username}" >/dev/null 2>&1 || true
            if ! "${ots_venv}/bin/flask" users change_password "${username}" --password "${password}" >/dev/null 2>&1; then
                exit 1
            fi
        fi
        "${ots_venv}/bin/flask" roles add "${username}" administrator >/dev/null 2>&1 || true
    ); then
        log_warn "Could not provision OpenTAK user '${username}' during setup."
        log_warn "Setup will continue. Use OpenTAK default login: administrator / password"
        return 0
    fi

    log_ok "OpenTAK web login ready: ${username}"
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
