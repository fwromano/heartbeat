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
        sed -i.bak "s|^${key}=.*|${key}=\"${value}\"|" "$HEARTBEAT_CONF"
        rm -f "${HEARTBEAT_CONF}.bak"
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

gen_password() {
    head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 12
}

# Resolve the OpenTAK pip install target from config.
# Default is PyPI package "opentakserver"; optional fork install uses:
#   OTS_GIT_URL="https://github.com/<user>/OpenTAKServer.git"
#   OTS_GIT_REF="branch-or-tag"
opentak_pip_spec() {
    local git_url="${OTS_GIT_URL:-}"
    local git_ref="${OTS_GIT_REF:-}"

    if [[ -z "$git_url" ]]; then
        echo "opentakserver"
        return 0
    fi

    local spec="$git_url"
    if [[ "$spec" != git+* ]]; then
        spec="git+${spec}"
    fi
    if [[ -n "$git_ref" && "$spec" != *"@"* ]]; then
        spec="${spec}@${git_ref}"
    fi
    echo "$spec"
}

# Runtime patching is an opt-in fallback for legacy OpenTAK builds.
opentak_runtime_patches_enabled() {
    local value="${OTS_RUNTIME_PATCHES:-false}"
    value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        1|true|yes|on) return 0 ;;
    esac
    return 1
}

# Apply Heartbeat runtime patches to OpenTAK's eud_handler in its venv.
opentak_apply_runtime_patches() {
    local ots_venv="${1:?missing OpenTAK venv path}"
    local patcher="${HEARTBEAT_DIR}/tools/patch_opentak_client_controller.py"

    if [[ ! -x "${ots_venv}/bin/python3" ]]; then
        log_warn "OpenTAK Python runtime not found at ${ots_venv}/bin/python3"
        return 1
    fi
    if [[ ! -f "$patcher" ]]; then
        log_warn "OpenTAK patcher not found: ${patcher}"
        return 1
    fi

    if "${ots_venv}/bin/python3" "$patcher" --venv "$ots_venv" >/dev/null; then
        return 0
    fi

    return 1
}

# Upsert an OpenTAK user using the app datastore directly (no Flask CLI user commands).
opentak_upsert_user_local() {
    local ots_dir="${1:?missing ots_dir}"
    local ots_venv="${2:?missing ots_venv}"
    local username="${3:?missing username}"
    local password="${4:?missing password}"
    local role="${5:-administrator}"
    local retries="${6:-5}"

    if [[ ! -x "${ots_venv}/bin/python3" ]]; then
        log_error "OpenTAK Python runtime not found at ${ots_venv}/bin/python3"
        return 1
    fi

    if [[ ${#password} -lt 8 ]]; then
        log_error "OpenTAK password for '${username}' must be at least 8 characters."
        return 1
    fi

    local attempt=1
    local output=""
    while [[ $attempt -le $retries ]]; do
        if output=$(
            cd "${ots_dir}" && \
            OTS_DATA_FOLDER="${ots_dir}" \
            OTS_CONFIG_PATH="${ots_dir}/config.yml" \
            OTS_CONFIG_FILE="${ots_dir}/config.yml" \
            "${ots_venv}/bin/python3" - "${username}" "${password}" "${role}" 2>&1 <<'PY'
import sys

from flask_security import hash_password

from opentakserver.app import create_app
from opentakserver.extensions import db

username, password, role = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    app = create_app(cli=True)
    with app.app_context():
        datastore = app.security.datastore

        datastore.find_or_create_role(name="user", permissions={"user-read", "user-write"})
        datastore.find_or_create_role(name="administrator", permissions={"administrator"})

        user = datastore.find_user(username=username)
        if user is None:
            user = datastore.create_user(
                username=username,
                password=hash_password(password),
                active=True,
            )
        else:
            user.password = hash_password(password)
            user.active = True
            db.session.add(user)

        datastore.add_role_to_user(user, "user")
        if role and role != "user":
            datastore.add_role_to_user(user, role)

        db.session.commit()
except Exception as exc:
    print(f"{exc.__class__.__name__}: {exc}", file=sys.stderr)
    sys.exit(1)
PY
        ); then
            return 0
        fi

        if [[ $attempt -lt $retries ]]; then
            sleep "$attempt"
        fi
        attempt=$((attempt + 1))
    done

    log_warn "OpenTAK datastore user bootstrap failed for '${username}' after ${retries} attempts."
    output="$(printf '%s\n' "$output" | sed '/^Mumble auth not supported on this platform$/d')"
    if [[ -n "$output" ]]; then
        log_warn "${output}"
    fi
    return 1
}

ensure_dir() {
    mkdir -p "$1"
}

# Check if a TCP port is listening
port_listening() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":${port} " || return 1
}

# Check if a TCP port is accepting connections
port_accepting() {
    local host="${1:-127.0.0.1}" port="$2" rc
    if has_cmd python3; then
        set +e
        python3 - "$host" "$port" <<'PY'
import socket, sys
host = sys.argv[1]
port = int(sys.argv[2])
s = socket.socket()
s.settimeout(1)
try:
    s.connect((host, port))
except Exception:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
        rc=$?
        set -e
        return $rc
    fi
    set +e
    bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
    rc=$?
    set -e
    return $rc
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
        port=$((port + 1))
        i=$((i + 1))
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
