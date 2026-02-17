#!/usr/bin/env bash
# ==========================================================================
# Heartbeat - TAK Server Setup
# ==========================================================================
# One-shot installer for FreeTAKServer.
# Supports Docker (recommended) and native pip installation.
#
# Usage:
#   ./setup.sh              Fully automatic setup (zero prompts)
#   ./setup.sh --interactive   Ask questions during setup
#   ./setup.sh --docker     Force Docker mode
#   ./setup.sh --native     Force native mode
#   ./setup.sh --backend opentak   Select OpenTAK backend
#   ./setup.sh --username team --password secret
#   ./setup.sh --team "My Team"   Set team name
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
FORCE_MODE=""
INTERACTIVE=false
ARG_TEAM=""
ARG_SERVER_IP=""
ARG_BACKEND=""
ARG_USERNAME=""
ARG_PASSWORD=""
FORCE_TAILSCALE=false
DISABLE_TAILSCALE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker)       FORCE_MODE="docker"; shift ;;
        --native)       FORCE_MODE="native"; shift ;;
        --interactive)  INTERACTIVE=true; shift ;;
        -i)             INTERACTIVE=true; shift ;;
        --team)         ARG_TEAM="$2"; shift 2 ;;
        --server-ip)    ARG_SERVER_IP="$2"; shift 2 ;;
        --backend)      ARG_BACKEND="$2"; shift 2 ;;
        --username)     ARG_USERNAME="$2"; shift 2 ;;
        --password)     ARG_PASSWORD="$2"; shift 2 ;;
        --tailscale)    FORCE_TAILSCALE=true; shift ;;
        --no-tailscale) DISABLE_TAILSCALE=true; shift ;;
        --help|-h)
            echo "Usage: ./setup.sh [options]"
            echo ""
            echo "  (no args)        Fully automatic setup (recommended)"
            echo "  --interactive    Ask questions during setup"
            echo "  --docker         Force Docker deployment"
            echo "  --native         Force native pip deployment"
            echo "  --backend NAME   TAK backend: freetak (default), opentak"
            echo "  --team \"Name\"    Set team/org name"
            echo "  --server-ip IP   Set server IP/hostname for clients"
            echo "  --username NAME  Default TAK/WebTAK username"
            echo "  --password PASS  Default TAK/WebTAK password"
            echo "  --tailscale      Force Tailscale IP for clients"
            echo "  --no-tailscale   Do not use Tailscale (LAN IP only)"
            echo "  --help           Show this help"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Auto-detect safe ports (skip ports already in use)
# ---------------------------------------------------------------------------
auto_ports() {
    local backend="${1:-freetak}"
    local cot ssl api dp

    case "$backend" in
        opentak)
            cot=$(find_free_port 8088)
            ssl=$(find_free_port 8089)
            api=8443
            dp=8443
            ;;
        *)
            cot=$(find_free_port 8087)
            ssl=$(find_free_port 8089)
            api=$(find_free_port 19023)
            dp=8443
            ;;
    esac

    if ! port_available "$dp"; then
        log_warn "Port 8443 in use, DataPackage service may not be reachable" >&2
    fi

    # Log any ports that shifted (to stderr so they don't mix with output)
    if [[ "$backend" == "opentak" ]]; then
        if [[ "$cot" != "8088" ]]; then
            log_warn "Port 8088 in use, CoT port -> ${cot}" >&2
        fi
    else
        if [[ "$cot" != "8087" ]]; then
            log_warn "Port 8087 in use, CoT port -> ${cot}" >&2
        fi
    fi
    if [[ "$ssl" != "8089" ]]; then
        log_warn "Port 8089 in use, SSL CoT port -> ${ssl}" >&2
    fi
    if [[ "$backend" != "opentak" && "$api" != "19023" ]]; then
        log_warn "Port 19023 in use, API port -> ${api}" >&2
    fi
    echo "${cot} ${ssl} ${api} ${dp}"
}

# ---------------------------------------------------------------------------
# Main setup flow
# ---------------------------------------------------------------------------
main() {
    banner
    local backend="${ARG_BACKEND:-}"
    local webtak_port=8080
    local prev_user=""
    local prev_pass=""
    local prev_backend=""
    local prev_ots_cert_user=""
    local prev_ots_git_url=""
    local prev_ots_git_ref=""
    local prev_fire_enabled=""
    local prev_fire_interval=""
    local prev_fire_bbox=""
    local prev_fire_range_km=""
    local prev_fire_ots_api_url=""
    local prev_fire_perimeters_enabled=""
    local prev_fire_perimeter_simplify=""
    local prev_fire_perimeter_max_vertices=""

    # Default backend for fresh installs: FreeTAK.
    if [[ -z "$backend" ]]; then
        backend="freetak"
    fi

    case "$backend" in
        freetak|opentak) ;;
        *)
            log_error "Unknown backend: ${backend}"
            log_error "Supported backends: freetak, opentak"
            exit 1
            ;;
    esac

    # Check for existing config
    if [[ -f "$HEARTBEAT_CONF" ]]; then
        prev_backend=$(awk -F'"' '/^TAK_BACKEND=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_user=$(awk -F'"' '/^FTS_USERNAME=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_pass=$(awk -F'"' '/^FTS_PASSWORD=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_ots_cert_user=$(awk -F'"' '/^OTS_RECORDER_CERT_USER=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_ots_git_url=$(awk -F'"' '/^OTS_GIT_URL=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_ots_git_ref=$(awk -F'"' '/^OTS_GIT_REF=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_fire_enabled=$(awk -F'"' '/^FIRE_FEED_ENABLED=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_fire_interval=$(awk -F'[=" ]+' '/^FIRE_FEED_INTERVAL=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_fire_bbox=$(awk -F'"' '/^FIRE_FEED_BBOX=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_fire_range_km=$(awk -F'[=" ]+' '/^FIRE_FEED_RANGE_KM=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_fire_ots_api_url=$(awk -F'"' '/^FIRE_FEED_OTS_API_URL=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_fire_perimeters_enabled=$(awk -F'"' '/^FIRE_FEED_PERIMETERS_ENABLED=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_fire_perimeter_simplify=$(awk -F'[=" ]+' '/^FIRE_FEED_PERIMETER_SIMPLIFY=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_fire_perimeter_max_vertices=$(awk -F'[=" ]+' '/^FIRE_FEED_PERIMETER_MAX_VERTICES=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        if [[ -z "${ARG_BACKEND:-}" && -n "$prev_backend" ]]; then
            backend="$prev_backend"
        fi

        if $INTERACTIVE; then
            log_warn "Existing configuration found: $HEARTBEAT_CONF"
            if ! prompt_yn "Overwrite and re-run setup?" "n"; then
                log_info "Setup cancelled."
                exit 0
            fi
        else
            log_info "Re-running setup (overwriting existing config)"
        fi
    fi

    # Validate again in case backend came from existing config.
    case "$backend" in
        freetak|opentak) ;;
        *)
            log_error "Unknown backend in config: ${backend}"
            log_error "Supported backends: freetak, opentak"
            exit 1
            ;;
    esac

    # backend may have changed after reading existing config
    if [[ "$backend" == "opentak" ]]; then
        webtak_port=8443
    else
        webtak_port=8080
    fi

    # ---- Clean previous installation artifacts ----
    if [[ -f "$HEARTBEAT_CONF" ]]; then
        log_step "Cleaning previous installation artifacts"

        # Stop running services
        source "${LIB_DIR}/server.sh"
        server_stop 2>/dev/null || true

        # Remove stale packages (certs will change on fresh setup)
        rm -f "${PACKAGES_DIR}"/*.zip "${PACKAGES_DIR}"/*.png "${PACKAGES_DIR}"/index.html 2>/dev/null

        # Remove Docker volumes (may be root-owned from container)
        if has_docker; then
            local compose_cmd
            compose_cmd=$(get_compose_cmd)
            if [[ -n "$compose_cmd" ]]; then
                (cd "$DOCKER_DIR" && $compose_cmd down -v 2>/dev/null) || true
            fi
        fi
        sudo rm -rf "${DOCKER_DIR}/certs" "${DOCKER_DIR}/data" "${DOCKER_DIR}/logs" 2>/dev/null || true
        ensure_dir "${DOCKER_DIR}/data"
        ensure_dir "${DOCKER_DIR}/logs"
        ensure_dir "${DOCKER_DIR}/certs"

        # Remove stale logs and runtime data
        rm -f "${DATA_DIR}"/*.log "${DATA_DIR}"/*.pid 2>/dev/null
        rm -f "${HEARTBEAT_DIR}/.config.nodes.json" "${HEARTBEAT_DIR}/.config.runtime.json" \
              "${HEARTBEAT_DIR}/package.json" 2>/dev/null
        rm -rf "${HEARTBEAT_DIR}/JsonDB" 2>/dev/null

        log_ok "Previous artifacts cleaned"
    fi

    ensure_dir "$CONFIG_DIR"
    ensure_dir "$DATA_DIR"
    ensure_dir "$PACKAGES_DIR"

    # ---- Stop any existing heartbeat container before port scan ----
    if has_docker; then
        local compose_cmd
        compose_cmd=$(get_compose_cmd)
        if [[ -n "$compose_cmd" ]] && docker ps -q --filter name=heartbeat-fts 2>/dev/null | grep -q .; then
            log_info "Stopping existing heartbeat container before port check..."
            (cd "$DOCKER_DIR" && $compose_cmd down 2>/dev/null) || true
        fi
    fi

    # QR code generation uses qrencode inside the Docker container
    # (no host system packages needed)

    # ---- Deployment mode ----
    local mode="$FORCE_MODE"
    if [[ "$backend" == "opentak" ]]; then
        # OpenTAK uses native host services (systemd/nginx/rabbitmq/postgres)
        mode="native"
        log_info "Backend '${backend}' selected -- forcing native deployment mode"
    elif [[ -z "$mode" ]]; then
        if has_docker; then
            mode="docker"
            log_ok "Docker detected -- using Docker deployment"
        else
            mode="native"
            log_ok "Docker not found -- using native pip deployment"
        fi

        if $INTERACTIVE; then
            echo ""
            echo -e "${BOLD}Deployment mode:${NC}"
            echo -e "  ${GREEN}1)${NC} Docker  ${DIM}(recommended)${NC}"
            echo -e "  ${GREEN}2)${NC} Native  ${DIM}(pip install into virtualenv)${NC}"
            echo ""
            local choice
            choice=$(prompt_default "Choose" "$([ "$mode" = "docker" ] && echo 1 || echo 2)")
            case "$choice" in
                1|docker) mode="docker" ;;
                2|native) mode="native" ;;
            esac
        fi
    fi

    # ---- Team name ----
    local team_name="${ARG_TEAM:-Test VFD}"
    if $INTERACTIVE; then
        echo ""
        team_name=$(prompt_default "Team / organization name" "$team_name")
    fi

    # ---- Server IP (auto-detect) ----
    local server_ip
    local tailscale_mode="false"
    local ts_ip
    ts_ip=$(detect_tailscale_ip || true)
    if $FORCE_TAILSCALE; then
        if [[ -z "$ts_ip" ]]; then
            log_error "Tailscale IP not found. Is Tailscale running?"
            exit 1
        fi
        server_ip="$ts_ip"
        tailscale_mode="true"
    elif $DISABLE_TAILSCALE; then
        if [[ -n "$ARG_SERVER_IP" ]]; then
            server_ip="$ARG_SERVER_IP"
        else
            server_ip=$(detect_ip)
        fi
    elif [[ -n "$ARG_SERVER_IP" ]]; then
        server_ip="$ARG_SERVER_IP"
    elif [[ -n "$ts_ip" ]]; then
        server_ip="$ts_ip"
        tailscale_mode="true"
    else
        server_ip=$(detect_ip)
    fi
    if [[ "$tailscale_mode" == "false" ]] && is_tailscale_ip "$server_ip"; then
        tailscale_mode="true"
    fi
    log_ok "Server IP: ${server_ip}"

    if $INTERACTIVE; then
        echo ""
        server_ip=$(prompt_default "Server IP (what phones connect to)" "$server_ip")
    fi

    # ---- Ports (auto-detect conflicts) ----
    log_step "Checking ports"
    local ports
    ports=$(auto_ports "$backend")
    local cot_port ssl_cot_port api_port dp_port
    read -r cot_port ssl_cot_port api_port dp_port <<< "$ports"

    if [[ "$backend" == "opentak" ]]; then
        # OpenTAK exposes WebTAK/Marti on 8443.
        api_port=8443
        dp_port=8443
    fi

    log_ok "Ports: CoT=${cot_port} SSL=${ssl_cot_port} API=${api_port} DP=${dp_port}"

    if $INTERACTIVE; then
        echo ""
        if ! prompt_yn "Use these ports?" "y"; then
            cot_port=$(prompt_default "CoT port" "$cot_port")
            ssl_cot_port=$(prompt_default "SSL CoT port" "$ssl_cot_port")
            api_port=$(prompt_default "REST API port" "$api_port")
            if [[ "$backend" == "opentak" ]]; then
                echo -e "${DIM}OpenTAK keeps WebTAK/Marti on 8443 by default.${NC}"
            else
                echo -e "${DIM}DataPackage port stays at 8443 (FreeTAKServer default).${NC}"
            fi
        fi
    fi

    if [[ "$backend" == "opentak" ]]; then
        api_port=8443
        dp_port=8443
    fi

    # ---- Connection message ----
    local conn_msg="Welcome to ${team_name} TAK"
    if $INTERACTIVE; then
        conn_msg=$(prompt_default "Connection welcome message" "$conn_msg")
    fi

    # ---- Default credentials ----
    local default_user="admin"
    local default_pass=""

    local fts_user="${ARG_USERNAME:-${prev_user:-$default_user}}"
    local fts_pass
    if [[ -n "${ARG_PASSWORD:-}" ]]; then
        fts_pass="${ARG_PASSWORD}"
    elif [[ -n "${prev_pass:-}" ]]; then
        fts_pass="${prev_pass}"
    else
        if [[ -n "$default_pass" ]]; then
            fts_pass="$default_pass"
        else
            fts_pass=$(gen_password)
        fi
    fi
    if $INTERACTIVE; then
        echo ""
        fts_user=$(prompt_default "Default TAK username" "$fts_user")
        fts_pass=$(prompt_default "Default TAK password" "$fts_pass")
    fi
    if [[ "$backend" == "opentak" && ${#fts_pass} -lt 8 ]]; then
        log_error "OpenTAK password must be at least 8 characters."
        log_error "Re-run with a longer password via --password."
        exit 1
    fi

    local ots_recorder_cert_user="${prev_ots_cert_user:-$fts_user}"
    local ots_git_url="${OTS_GIT_URL:-${prev_ots_git_url:-}}"
    local ots_git_ref="${OTS_GIT_REF:-${prev_ots_git_ref:-}}"
    local fire_feed_enabled="${prev_fire_enabled:-true}"
    local fire_feed_interval="${prev_fire_interval:-900}"
    local fire_feed_bbox="${prev_fire_bbox:-}"
    local fire_feed_range_km="${prev_fire_range_km:-100}"
    local fire_feed_ots_api_url="${prev_fire_ots_api_url:-http://127.0.0.1:8081/api}"
    local fire_feed_perimeters_enabled="${prev_fire_perimeters_enabled:-false}"
    local fire_feed_perimeter_simplify="${prev_fire_perimeter_simplify:-0.001}"
    local fire_feed_perimeter_max_vertices="${prev_fire_perimeter_max_vertices:-250}"
    if [[ -n "$ots_git_url" && -z "$ots_git_ref" ]]; then
        ots_git_ref="main"
    fi

    # ---- Write config ----
    log_step "Writing configuration"

    cat > "$HEARTBEAT_CONF" <<EOF
# Heartbeat TAK Configuration
# Generated by setup.sh on $(date -Iseconds)

TEAM_NAME="${team_name}"
SERVER_IP="${server_ip}"
DEPLOY_MODE="${mode}"
TAILSCALE_MODE="${tailscale_mode}"

COT_PORT=${cot_port}
SSL_COT_PORT=${ssl_cot_port}
API_PORT=${api_port}
DATAPACKAGE_PORT=${dp_port}

FTS_SECRET_KEY=""
FTS_CONNECTION_MSG="${conn_msg}"
FTS_DATA_DIR="${DATA_DIR}/fts"
TAK_BACKEND="${backend}"
WEBTAK_PORT=${webtak_port}

FTS_USERNAME="${fts_user}"
FTS_PASSWORD="${fts_pass}"

FIRE_FEED_ENABLED="${fire_feed_enabled}"
FIRE_FEED_INTERVAL=${fire_feed_interval}
FIRE_FEED_BBOX="${fire_feed_bbox}"
FIRE_FEED_RANGE_KM=${fire_feed_range_km}
FIRE_FEED_OTS_API_URL="${fire_feed_ots_api_url}"
FIRE_FEED_PERIMETERS_ENABLED="${fire_feed_perimeters_enabled}"
FIRE_FEED_PERIMETER_SIMPLIFY=${fire_feed_perimeter_simplify}
FIRE_FEED_PERIMETER_MAX_VERTICES=${fire_feed_perimeter_max_vertices}
EOF

    if [[ "$backend" == "opentak" ]]; then
        cat >> "$HEARTBEAT_CONF" <<EOF
OTS_RECORDER_CERT_USER="${ots_recorder_cert_user}"
OTS_GIT_URL="${ots_git_url}"
OTS_GIT_REF="${ots_git_ref}"

EOF
    fi

    log_ok "Config: ${HEARTBEAT_CONF}"

    # ---- Run mode-specific install ----
    source "${LIB_DIR}/install.sh"

    if [[ "$backend" == "freetak" ]]; then
        if [[ "$mode" == "docker" ]]; then
            install_docker_mode
        else
            install_native_mode
        fi
    fi

    # ---- Run backend-specific install ----
    if [[ "$backend" == "opentak" ]]; then
        install_opentak
    fi

    # ---- Generate connection package for current user ----
    if [[ "$backend" == "freetak" ]]; then
        local callsign
        callsign="$(whoami)"
        if $INTERACTIVE; then
            echo ""
            if prompt_yn "Generate a connection package now?" "y"; then
                callsign=$(prompt_default "Your name / callsign" "$callsign")
            fi
        fi

        source "${LIB_DIR}/package.sh"
        generate_package "$callsign"

        # ---- Generate QR code (uses qrencode inside Docker) ----
        source "${LIB_DIR}/qr.sh"
        local qr_url="http://${server_ip}:9000"
        local png_path="${PACKAGES_DIR}/heartbeat_qr.png"
        if save_qr_png "$qr_url" "$png_path" 2>/dev/null && [[ -s "$png_path" ]]; then
            log_ok "QR image saved: ${png_path}"
        fi
    fi

    # ---- Done ----
    echo ""
    echo -e "${DIM}==============================================${NC}"
    echo -e "${GREEN}${BOLD}  Setup complete!${NC}"
    echo -e "${DIM}==============================================${NC}"
    echo ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo ""
    echo -e "    ${CYAN}./heartbeat start${NC}       Start the TAK server"
    if [[ "$backend" == "freetak" ]]; then
        echo -e "    ${CYAN}./heartbeat serve${NC}        Serve download page (run in 2nd terminal)"
        echo ""
        echo -e "  ${BOLD}Then on your phone:${NC}"
        echo ""
        if is_tailscale_ip "$server_ip"; then
            echo -e "    1. Connect to Tailscale on your phone"
            echo -e "    2. Scan the QR code with your phone camera"
            echo -e "    3. Download the .zip and open it with iTAK/ATAK"
        else
            echo -e "    1. Connect to the same WiFi as this machine"
            echo -e "    2. Scan the QR code with your phone camera"
            echo -e "    3. Download the .zip and open it with iTAK/ATAK"
        fi
    else
        echo -e "    ${CYAN}./heartbeat package \"${fts_user}\"${NC}    Generate SSL package for iTAK/ATAK"
        echo -e "    ${CYAN}./heartbeat serve${NC}                  Serve package download page"
        echo ""
        echo -e "  ${BOLD}Then on your phone:${NC}"
        echo ""
        echo -e "    1. Download and import the generated _connection.zip"
        echo -e "    2. Use WebTAK credentials when prompted: ${CYAN}${fts_user}${NC} / ${CYAN}${fts_pass}${NC}"
    fi
    echo ""
    if [[ "$backend" == "freetak" ]]; then
        echo -e "  ${BOLD}Default credentials:${NC}"
        echo ""
        echo -e "    Username: ${CYAN}${fts_user}${NC}"
        echo -e "    Password: ${CYAN}${fts_pass}${NC}"
        echo ""
    else
        echo -e "  ${BOLD}OpenTAK Web UI:${NC}"
        echo ""
        echo -e "    URL:      ${CYAN}https://${server_ip}:${webtak_port}/${NC}"
        echo -e "    Username: ${CYAN}${fts_user}${NC}"
        echo -e "    Password: ${CYAN}${fts_pass}${NC}"
        echo -e "    ${DIM}(accept the self-signed certificate on first load)${NC}"
        echo ""
    fi
    echo -e "  ${BOLD}Or connect manually in iTAK/ATAK:${NC}"
    echo ""
    echo -e "    Server:  ${CYAN}${server_ip}${NC}"
    echo -e "    Port:    ${CYAN}${cot_port}${NC}"
    echo -e "    Proto:   TCP"
    echo ""
}

main
