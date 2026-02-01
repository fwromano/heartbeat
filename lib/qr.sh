#!/usr/bin/env bash
# Heartbeat - QR code generation for iTAK/ATAK connection
#
# iTAK QR format: Description,Address,Port,Protocol
# Example:        "My Team,192.168.1.100,8087,TCP"
#
# QR generation runs inside the Docker container (qrencode installed there).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Build the iTAK QR connection string from config
# ---------------------------------------------------------------------------
get_qr_string() {
    load_config
    echo "${TEAM_NAME},${SERVER_IP},${COT_PORT},TCP"
}

# ---------------------------------------------------------------------------
# Run qrencode via Docker (no host deps needed)
# ---------------------------------------------------------------------------
_qrencode() {
    if has_cmd qrencode; then
        qrencode "$@"
        return
    fi
    if docker ps --filter name=heartbeat-fts --format '{{.Names}}' 2>/dev/null | grep -q heartbeat-fts; then
        docker exec heartbeat-fts qrencode "$@"
        return
    fi
    docker run --rm "$(docker images -q docker-fts 2>/dev/null | head -1)" qrencode "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Print QR code to terminal
# ---------------------------------------------------------------------------
print_qr_terminal() {
    local data="$1"
    if ! _qrencode -t ANSIUTF8 -m 2 "$data" 2>/dev/null; then
        echo -e "  ${DIM}(QR unavailable -- connect manually)${NC}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Save QR code as PNG image
# ---------------------------------------------------------------------------
save_qr_png() {
    local data="$1"
    local output_path="$2"
    _qrencode -t PNG -o - -s 10 -m 4 "$data" > "$output_path" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main QR command: show terminal QR + save PNG
# ---------------------------------------------------------------------------
show_qr() {
    load_config

    local qr_string
    qr_string=$(get_qr_string)
    local png_path="${PACKAGES_DIR}/heartbeat_qr.png"
    ensure_dir "$PACKAGES_DIR"

    echo ""
    echo -e "${BOLD}iTAK Connection QR Code${NC}"
    echo -e "${DIM}──────────────────────────────────────────${NC}"
    echo ""

    print_qr_terminal "$qr_string"

    echo ""
    echo -e "  ${BOLD}Scan in iTAK:${NC}  Add Server > Scan QR"
    echo -e "  ${BOLD}QR data:${NC}       ${qr_string}"
    echo ""
    echo -e "  ${BOLD}Credentials:${NC}"
    echo -e "    Username:  ${CYAN}${FTS_USERNAME:-team}${NC}"
    echo -e "    Password:  ${CYAN}${FTS_PASSWORD:-heartbeat}${NC}"
    echo ""

    if save_qr_png "$qr_string" "$png_path" 2>/dev/null && [[ -s "$png_path" ]]; then
        log_ok "QR image saved: ${png_path}"
        echo -e "  ${DIM}Print and post at the station for easy onboarding.${NC}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Compact QR display (for use after server start)
# ---------------------------------------------------------------------------
show_qr_compact() {
    load_config
    local qr_string
    qr_string=$(get_qr_string)

    echo ""
    echo -e "  ${BOLD}Scan in iTAK (Add Server > Scan QR):${NC}"
    echo ""
    print_qr_terminal "$qr_string"
    echo ""
    echo -e "  ${BOLD}Credentials:${NC}  ${CYAN}${FTS_USERNAME:-team}${NC} / ${CYAN}${FTS_PASSWORD:-heartbeat}${NC}"
    echo ""
}
