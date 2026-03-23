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
            echo "  --backend NAME   TAK backend: opentak (default), freetak"
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
    local backend="${1:-opentak}"
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
        if [[ "$backend" == "opentak" ]]; then
            log_info "Port 8443 is currently in use (expected on OpenTAK reruns/WebTAK)." >&2
        else
            log_warn "Port 8443 in use, data package service may not be reachable" >&2
        fi
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
    local prev_autoserve=""
    local prev_serve_port=""

    # Default backend for fresh installs: OpenTAK (heartbeat fork).
    if [[ -z "$backend" ]]; then
        backend="opentak"
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
        prev_autoserve=$(awk -F'"' '/^HEARTBEAT_AUTOSERVE=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
        prev_serve_port=$(awk -F'[=" ]+' '/^HEARTBEAT_SERVE_PORT=/{print $2; exit}' "$HEARTBEAT_CONF" 2>/dev/null || true)
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
    local ots_git_url="${OTS_GIT_URL:-${prev_ots_git_url:-https://github.com/fwromano/OpenTAKServer.git}}"
    local ots_git_ref="${OTS_GIT_REF:-${prev_ots_git_ref:-heartbeat-fixes}}"
    local heartbeat_autoserve="${prev_autoserve:-true}"
    local heartbeat_serve_port="${prev_serve_port:-9000}"
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
HEARTBEAT_AUTOSERVE="${heartbeat_autoserve}"
HEARTBEAT_SERVE_PORT=${heartbeat_serve_port}

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

    # ---- Generate data package for current user ----
    if [[ "$backend" == "freetak" ]]; then
        local callsign
        callsign="$(whoami)"
        if $INTERACTIVE; then
            echo ""
            if prompt_yn "Generate a data package now?" "y"; then
                callsign=$(prompt_default "Your name / callsign" "$callsign")
            fi
        fi

        source "${LIB_DIR}/package.sh"
        generate_package "$callsign"

        # ---- Generate QR code (uses qrencode inside Docker) ----
        source "${LIB_DIR}/qr.sh"
        local qr_url="http://${server_ip}:${heartbeat_serve_port}"
        local png_path="${PACKAGES_DIR}/heartbeat_qr.png"
        if save_qr_png "$qr_url" "$png_path" 2>/dev/null && [[ -s "$png_path" ]]; then
            log_ok "QR image saved: ${png_path}"
        fi
    fi

    # ---- Done ----
    echo ""
    log_step "Setup complete"
    log_info "Next steps:"
    if [[ "$backend" == "freetak" ]]; then
        echo -e "  ${CYAN}./heartbeat start${NC}      Start the TAK server"
        echo -e "  ${DIM}Package page auto-start:${NC} http://${server_ip}:${heartbeat_serve_port}/"
        echo -e "  ${DIM}Optional manual serve:${NC} ./heartbeat serve ${heartbeat_serve_port}"
        echo ""
        log_info "Then on your device:"
        if is_tailscale_ip "$server_ip"; then
            echo "  1. Connect to Tailscale on your device"
            echo -e "  2. Open ${CYAN}http://${server_ip}:${heartbeat_serve_port}/${NC}"
            echo "  3. Download the .zip and open it with iTAK/ATAK"
        else
            echo "  1. Connect to the same WiFi as this machine"
            echo -e "  2. Open ${CYAN}http://${server_ip}:${heartbeat_serve_port}/${NC}"
            echo "  3. Download the .zip and open it with iTAK/ATAK"
        fi
        echo ""
        log_info "Default credentials:"
        echo -e "  Username: ${CYAN}${fts_user}${NC}"
        echo -e "  Password: ${CYAN}${fts_pass}${NC}"
        echo ""
        log_info "Manual connection (fallback):"
        echo -e "  Server:   ${CYAN}${server_ip}${NC}"
        echo -e "  Port:     ${CYAN}${cot_port}${NC}"
        echo "  Protocol: TCP"
    else
        echo -e "  ${CYAN}./heartbeat start${NC}      Start the TAK server"
        echo -e "  ${DIM}Package page auto-start:${NC} http://${server_ip}:${heartbeat_serve_port}/"
        echo -e "  ${DIM}Optional manual serve:${NC} ./heartbeat serve ${heartbeat_serve_port}"
        echo -e "  ${DIM}Optional:${NC} ./heartbeat package \"name\"  # pre-generate a specific user package"
        echo ""
        log_info "Then on your device:"
        echo -e "  1. Open ${CYAN}http://${server_ip}:${heartbeat_serve_port}/${NC}"
        echo "  2. Tap 'Generate and Download My Device Package' once on that device"
        echo "  3. Import the downloaded .zip into iTAK/ATAK"
        echo "  4. If prompted for credentials, use the package account for that downloaded file"
        echo ""
        log_info "OpenTAK Web UI:"
        echo -e "  URL:      ${CYAN}https://${server_ip}:${webtak_port}/${NC}"
        echo -e "  Username: ${CYAN}${fts_user}${NC}"
        echo -e "  Password: ${CYAN}${fts_pass}${NC}"
        echo -e "  ${DIM}(accept the self-signed certificate on first load)${NC}"
        echo ""
        log_info "Manual iTAK/ATAK connect (advanced):"
        echo -e "  Server:   ${CYAN}${server_ip}${NC}"
        echo -e "  Port:     ${CYAN}${ssl_cot_port}${NC}"
        echo "  Protocol: SSL (client cert package required)"
    fi
    echo ""
}

main
