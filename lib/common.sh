#!/usr/bin/env bash
# Heartbeat - Shared utilities
# Common functions used across all heartbeat scripts

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & formatting
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()  { echo -e "${BLUE}[info]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
log_error() { echo -e "${RED}[error]${NC} $*" >&2; }
log_step()  { echo -e "\n${CYAN}>>>${NC} ${BOLD}$*${NC}"; }
log_dim()   { echo -e "${DIM}$*${NC}"; }

banner() {
    echo -e "${CYAN}"
    echo '  _  _ ___   _   ___ _____ ___ ___   _ _____'
    echo ' | || | __| /_\ | _ \_   _| _ ) __| /_\_   _|'
    echo ' | __ | _| / _ \|   / | | | _ \ _| / _ \| |'
    echo ' |_||_|___/_/ \_\_|_\ |_| |___/___/_/ \_\_|'
    echo -e "${NC}"
    echo -e " ${DIM}TAK Server Manager for Teams${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Paths - resolved relative to the repo root
# ---------------------------------------------------------------------------
HEARTBEAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${HEARTBEAT_DIR}/config"
TEMPLATES_DIR="${HEARTBEAT_DIR}/templates"
PACKAGES_DIR="${HEARTBEAT_DIR}/packages"
LIB_DIR="${HEARTBEAT_DIR}/lib"
DATA_DIR="${HEARTBEAT_DIR}/data"
DOCKER_DIR="${HEARTBEAT_DIR}/docker"

HEARTBEAT_CONF="${CONFIG_DIR}/heartbeat.conf"
PID_FILE="${DATA_DIR}/fts.pid"
LOG_FILE="${DATA_DIR}/fts.log"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
load_config() {
    if [[ -f "$HEARTBEAT_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$HEARTBEAT_CONF"
        if [[ "${TAILSCALE_MODE:-false}" == "true" ]]; then
            local ts_ip
            ts_ip=$(detect_tailscale_ip || true)
            if [[ -n "$ts_ip" && "$ts_ip" != "$SERVER_IP" ]]; then
                SERVER_IP="$ts_ip"
                set_config "SERVER_IP" "$ts_ip"
            fi
        fi
    else
        log_error "Config not found: $HEARTBEAT_CONF"
        log_error "Run ./setup.sh first."
        exit 1
    fi
}

# Write a config value (KEY=VALUE) to heartbeat.conf, updating if exists
set_config() {
    local key="$1" value="$2"
    if [[ -f "$HEARTBEAT_CONF" ]] && grep -q "^${key}=" "$HEARTBEAT_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$HEARTBEAT_CONF"
    else
        echo "${key}=\"${value}\"" >> "$HEARTBEAT_CONF"
    fi
}

# ---------------------------------------------------------------------------
# System detection
# ---------------------------------------------------------------------------
detect_ip() {
    local ip=""
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}') || true
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    if [[ -z "$ip" ]]; then
        ip="127.0.0.1"
    fi
    echo "$ip"
}

detect_public_ip() {
    curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo ""
}

has_cmd() {
    command -v "$1" &>/dev/null
}

has_docker() {
    has_cmd docker && docker info &>/dev/null 2>&1
}

detect_tailscale_ip() {
    if has_cmd tailscale; then
        tailscale ip -4 2>/dev/null | head -1
    fi
}

is_tailscale_ip() {
    # Tailscale uses CGNAT range 100.64.0.0/10
    [[ "$1" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

get_compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        echo "docker compose"
    elif has_cmd docker-compose; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
gen_uuid() {
    if has_cmd uuidgen; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c "import uuid; print(uuid.uuid4())"
    fi
}

gen_secret() {
    head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32
}

ensure_dir() {
    mkdir -p "$1"
}

# Check if a TCP port is listening
port_listening() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":${port} " || return 1
}

# Check if a port is available (not in use)
port_available() {
    local port="$1"
    ! port_listening "$port"
}

# Find a free port starting from a given port, incrementing until one is found
find_free_port() {
    local port="${1:-8087}"
    local max_tries=20
    local i=0
    while [[ $i -lt $max_tries ]]; do
        if port_available "$port"; then
            echo "$port"
            return 0
        fi
        ((port++))
        ((i++))
    done
    echo "$1"  # fallback to original
}

# Prompt with a default value: prompt_default "Question" "default"
prompt_default() {
    local prompt="$1" default="$2" reply
    read -rp "$(echo -e "${BOLD}${prompt}${NC} [${default}]: ")" reply
    echo "${reply:-$default}"
}

# Prompt yes/no with default: prompt_yn "Question" "y"
prompt_yn() {
    local prompt="$1" default="${2:-y}" reply
    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${BOLD}${prompt}${NC} [Y/n]: ")" reply
        [[ "${reply,,}" != "n" ]]
    else
        read -rp "$(echo -e "${BOLD}${prompt}${NC} [y/N]: ")" reply
        [[ "${reply,,}" == "y" ]]
    fi
}

# Require root or exit
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This command requires root privileges. Run with sudo."
        exit 1
    fi
}
