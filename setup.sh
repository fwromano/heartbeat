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
while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker)       FORCE_MODE="docker"; shift ;;
        --native)       FORCE_MODE="native"; shift ;;
        --interactive)  INTERACTIVE=true; shift ;;
        -i)             INTERACTIVE=true; shift ;;
        --team)         ARG_TEAM="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./setup.sh [options]"
            echo ""
            echo "  (no args)        Fully automatic setup (recommended)"
            echo "  --interactive    Ask questions during setup"
            echo "  --docker         Force Docker deployment"
            echo "  --native         Force native pip deployment"
            echo "  --team \"Name\"    Set team/org name"
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
    local cot ssl api dp

    cot=$(find_free_port 8087)
    ssl=$(find_free_port 8089)
    api=$(find_free_port 19023)
    dp=8443
    if ! port_available "$dp"; then
        log_warn "Port 8443 in use, DataPackage service may not be reachable" >&2
    fi

    # Log any ports that shifted (to stderr so they don't mix with output)
    if [[ "$cot" != "8087" ]]; then
        log_warn "Port 8087 in use, CoT port -> ${cot}" >&2
    fi
    if [[ "$ssl" != "8089" ]]; then
        log_warn "Port 8089 in use, SSL CoT port -> ${ssl}" >&2
    fi
    if [[ "$api" != "19023" ]]; then
        log_warn "Port 19023 in use, API port -> ${api}" >&2
    fi
    echo "${cot} ${ssl} ${api} ${dp}"
}

# ---------------------------------------------------------------------------
# Main setup flow
# ---------------------------------------------------------------------------
main() {
    banner

    # Check for existing config
    if [[ -f "$HEARTBEAT_CONF" ]]; then
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
    if [[ -z "$mode" ]]; then
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
    local team_name="${ARG_TEAM:-Volunteer FD}"
    if $INTERACTIVE; then
        echo ""
        team_name=$(prompt_default "Team / organization name" "$team_name")
    fi

    # ---- Server IP (auto-detect) ----
    local server_ip
    server_ip=$(detect_ip)
    log_ok "Server IP: ${server_ip}"

    if $INTERACTIVE; then
        echo ""
        server_ip=$(prompt_default "Server IP (what phones connect to)" "$server_ip")
    fi

    # ---- Ports (auto-detect conflicts) ----
    log_step "Checking ports"
    local ports
    ports=$(auto_ports)
    local cot_port ssl_cot_port api_port dp_port
    read -r cot_port ssl_cot_port api_port dp_port <<< "$ports"
    log_ok "Ports: CoT=${cot_port} SSL=${ssl_cot_port} API=${api_port} DP=${dp_port}"

    if $INTERACTIVE; then
        echo ""
        if ! prompt_yn "Use these ports?" "y"; then
            cot_port=$(prompt_default "CoT port" "$cot_port")
            ssl_cot_port=$(prompt_default "SSL CoT port" "$ssl_cot_port")
            api_port=$(prompt_default "REST API port" "$api_port")
            echo -e "${DIM}DataPackage port stays at 8443 (FreeTAKServer default).${NC}"
        fi
    fi

    # ---- Connection message ----
    local conn_msg="Welcome to ${team_name} TAK"
    if $INTERACTIVE; then
        conn_msg=$(prompt_default "Connection welcome message" "$conn_msg")
    fi

    # ---- Default credentials ----
    local fts_user="team"
    local fts_pass="${fts_user}"
    if $INTERACTIVE; then
        echo ""
        fts_user=$(prompt_default "Default TAK username" "$fts_user")
        fts_pass=$(prompt_default "Default TAK password" "$fts_user")
    fi

    # ---- Write config ----
    log_step "Writing configuration"

    cat > "$HEARTBEAT_CONF" <<EOF
# Heartbeat TAK Configuration
# Generated by setup.sh on $(date -Iseconds)

TEAM_NAME="${team_name}"
SERVER_IP="${server_ip}"
DEPLOY_MODE="${mode}"

COT_PORT=${cot_port}
SSL_COT_PORT=${ssl_cot_port}
API_PORT=${api_port}
DATAPACKAGE_PORT=${dp_port}

FTS_SECRET_KEY=""
FTS_CONNECTION_MSG="${conn_msg}"
FTS_DATA_DIR="${DATA_DIR}/fts"

FTS_USERNAME="${fts_user}"
FTS_PASSWORD="${fts_pass}"
EOF

    log_ok "Config: ${HEARTBEAT_CONF}"

    # ---- Run mode-specific install ----
    source "${LIB_DIR}/install.sh"

    if [[ "$mode" == "docker" ]]; then
        install_docker_mode
    else
        install_native_mode
    fi

    # ---- Generate connection package for current user ----
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

    # ---- Done ----
    echo ""
    echo -e "${DIM}══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Setup complete!${NC}"
    echo -e "${DIM}══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo ""
    echo -e "    ${CYAN}./heartbeat start${NC}       Start the TAK server"
    echo -e "    ${CYAN}./heartbeat serve${NC}        Serve download page (run in 2nd terminal)"
    echo ""
    echo -e "  ${BOLD}Then on your phone:${NC}"
    echo ""
    echo -e "    1. Connect to the same WiFi as this machine"
    echo -e "    2. Scan the QR code with your phone camera"
    echo -e "    3. Download the .zip and open it with iTAK/ATAK"
    echo ""
    echo -e "  ${BOLD}Default credentials:${NC}"
    echo ""
    echo -e "    Username: ${CYAN}${fts_user}${NC}"
    echo -e "    Password: ${CYAN}${fts_pass}${NC}"
    echo ""
    echo -e "  ${BOLD}Or connect manually in iTAK/ATAK:${NC}"
    echo ""
    echo -e "    Server:  ${CYAN}${server_ip}${NC}"
    echo -e "    Port:    ${CYAN}${cot_port}${NC}"
    echo -e "    Proto:   TCP"
    echo ""
}

main
