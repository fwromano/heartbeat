#!/usr/bin/env bash
# Heartbeat - Data package generation
# Creates TAK connection packages (.zip) importable by iTAK and ATAK

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Generate a connection data package for a team member
#
# Usage: generate_package "Member Name"
# Output: packages/<sanitized_name>_connection.zip
# ---------------------------------------------------------------------------
generate_package() {
    local member_name="${1:?Usage: generate_package <member_name>}"
    load_config

    local safe_name
    safe_name=$(echo "$member_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    local pkg_uid
    pkg_uid=$(gen_uuid)
    local pref_entry="cot_streams/${safe_name}.pref"
    local pkg_filename="${safe_name}_connection.zip"
    local pkg_path="${PACKAGES_DIR}/${pkg_filename}"

    ensure_dir "$PACKAGES_DIR"

    # Build in a temp directory
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    mkdir -p "${tmpdir}/cot_streams"
    mkdir -p "${tmpdir}/MANIFEST"

    # Render server.pref from template
    sed -e "s|{{TEAM_NAME}}|${TEAM_NAME}|g" \
        -e "s|{{SERVER_IP}}|${SERVER_IP}|g" \
        -e "s|{{COT_PORT}}|${COT_PORT}|g" \
        "${TEMPLATES_DIR}/server.pref" > "${tmpdir}/cot_streams/${safe_name}.pref"

    # Render manifest.xml from template
    local pkg_display_name="${TEAM_NAME} - ${member_name}"
    sed -e "s|{{PACKAGE_UID}}|${pkg_uid}|g" \
        -e "s|{{PACKAGE_NAME}}|${pkg_display_name}|g" \
        -e "s|{{PREF_PATH}}|${pref_entry}|g" \
        -e "s|{{TEAM_NAME}}|${TEAM_NAME}|g" \
        "${TEMPLATES_DIR}/manifest.xml" > "${tmpdir}/MANIFEST/manifest.xml"

    # Create the zip
    (cd "$tmpdir" && zip -q -r "$pkg_path" MANIFEST cot_streams)

    log_ok "Package created: ${pkg_path}"
    echo ""
    echo -e "  ${BOLD}Member:${NC}  ${member_name}"
    echo -e "  ${BOLD}Server:${NC}  ${SERVER_IP}:${COT_PORT} (TCP)"
    echo -e "  ${BOLD}File:${NC}    ${pkg_path}"
    echo ""

    # Clean up trap - reset since we're done
    trap - EXIT
    rm -rf "$tmpdir"

    return 0
}

# ---------------------------------------------------------------------------
# List all generated packages
# ---------------------------------------------------------------------------
list_packages() {
    ensure_dir "$PACKAGES_DIR"
    local count
    count=$(find "$PACKAGES_DIR" -name "*.zip" 2>/dev/null | wc -l)

    if [[ "$count" -eq 0 ]]; then
        log_info "No packages generated yet."
        log_info "Run: ./heartbeat package \"Member Name\""
        return
    fi

    echo -e "${BOLD}Generated connection packages:${NC}"
    echo ""
    for f in "$PACKAGES_DIR"/*.zip; do
        local fname size
        fname=$(basename "$f" .zip)
        size=$(du -h "$f" | cut -f1)
        echo -e "  ${GREEN}*${NC} ${fname}  ${DIM}(${size})${NC}"
    done
    echo ""
    echo -e "  ${DIM}Total: ${count} package(s) in ${PACKAGES_DIR}${NC}"
}

# ---------------------------------------------------------------------------
# Serve packages over HTTP with a mobile-friendly download page.
# Renders the download.html template and serves everything via Python.
# ---------------------------------------------------------------------------
serve_packages() {
    load_config
    local port="${1:-9000}"

    ensure_dir "$PACKAGES_DIR"

    # Find the first .zip package (generate one if none exist)
    local pkg_file
    pkg_file=$(find "$PACKAGES_DIR" -name "*.zip" -printf '%f\n' 2>/dev/null | head -1)
    if [[ -z "$pkg_file" ]]; then
        log_info "No package found, generating one..."
        generate_package "$(whoami)"
        pkg_file=$(find "$PACKAGES_DIR" -name "*.zip" -printf '%f\n' 2>/dev/null | head -1)
    fi

    # Render download.html into packages dir
    sed -e "s|{{TEAM_NAME}}|${TEAM_NAME}|g" \
        -e "s|{{PACKAGE_FILE}}|${pkg_file}|g" \
        -e "s|{{SERVER_IP}}|${SERVER_IP}|g" \
        -e "s|{{COT_PORT}}|${COT_PORT}|g" \
        "${TEMPLATES_DIR}/download.html" > "${PACKAGES_DIR}/index.html"

    echo ""
    echo -e "${BOLD}Serving connection packages:${NC}"
    echo ""
    echo -e "  ${CYAN}http://${SERVER_IP}:${port}/${NC}"
    echo ""
    echo -e "  Scan the QR code or open this URL on any phone."
    echo -e "  ${DIM}Press Ctrl+C to stop.${NC}"
    echo ""

    # Show QR if available
    if source "${LIB_DIR}/qr.sh" 2>/dev/null; then
        HEARTBEAT_SERVE_PORT="$port" print_qr_terminal "http://${SERVER_IP}:${port}" || true
        echo ""
    fi

    cd "$PACKAGES_DIR"
    python3 -m http.server "$port" --bind 0.0.0.0 2>/dev/null
}
