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
    local pkg_filename="${safe_name}_connection.zip"
    local pkg_path="${PACKAGES_DIR}/${pkg_filename}"

    ensure_dir "$PACKAGES_DIR"

    # Try FTS-generated package with SSL certs (Docker mode, server running)
    if [[ "$DEPLOY_MODE" == "docker" ]] \
       && docker ps -q --filter name=heartbeat-fts 2>/dev/null | grep -q .; then
        if _generate_fts_package "$member_name" "$safe_name" "$pkg_path"; then
            return 0
        fi
        log_warn "FTS package generation failed, falling back to TCP package"
    fi

    # Fallback: TCP-only package (no certs needed)
    _generate_tcp_package "$member_name" "$safe_name" "$pkg_path"
}

# Generate a package via the FTS API (includes SSL certificates)
_generate_fts_package() {
    local member_name="$1"
    local safe_name="$2"
    local pkg_path="$3"
    local password="${safe_name}"

    # Create user via FTS API (generates certs + enrollment package)
    local api_result
    api_result=$(docker exec heartbeat-fts python3 -c "
import urllib.request, urllib.error, json, sys, os
port = os.environ.get('API_PORT', '19023')
name = sys.argv[1]
pw   = sys.argv[2]
body = json.dumps({
    'systemUsers': [{
        'Name': name,
        'Token': pw,
        'Password': pw,
        'Group': '__ANON__',
        'DeviceType': 'mobile',
        'Certs': 'true'
    }]
}).encode()
req = urllib.request.Request(
    'http://127.0.0.1:' + port + '/ManageSystemUser/postSystemUser',
    data=body,
    headers={'Content-Type': 'application/json'}
)
try:
    r = urllib.request.urlopen(req, timeout=10)
    print('ok')
except urllib.error.HTTPError:
    print('exists')
except Exception as e:
    print('fail:' + str(e))
" "$safe_name" "$password" 2>/dev/null)

    if [[ "$api_result" == fail* ]]; then
        return 1
    fi

    # Find the FTS-generated package for this user in the container
    local fts_pkg
    fts_pkg=$(docker exec heartbeat-fts python3 -c "
import sqlite3, sys
name = sys.argv[1]
conn = sqlite3.connect('/opt/fts/FTSDataBase.db')
cur = conn.cursor()
cur.execute('SELECT certificate_package_name FROM SystemUser WHERE name = ?', (name,))
row = cur.fetchone()
if row and row[0]:
    print(row[0])
else:
    print('')
conn.close()
" "$safe_name" 2>/dev/null)

    if [[ -z "$fts_pkg" ]]; then
        return 1
    fi

    local container_path="/opt/fts/certs/clientPackages/${fts_pkg}"

    # Verify the package exists in the container
    if ! docker exec heartbeat-fts test -f "$container_path" 2>/dev/null; then
        return 1
    fi

    # Copy from container
    docker cp "heartbeat-fts:${container_path}" "$pkg_path" 2>/dev/null || return 1

    # Fix up: enable connection + restructure files to match manifest paths
    python3 -c "
import zipfile, os, sys
src = sys.argv[1]
tmp = src + '.tmp'
with zipfile.ZipFile(src, 'r') as zin, zipfile.ZipFile(tmp, 'w') as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        name = item.filename
        if name.endswith('.pref'):
            text = data.decode('ascii', errors='replace')
            text = text.replace('\"enabled0\" class=\"class java.lang.Boolean\">false',
                                '\"enabled0\" class=\"class java.lang.Boolean\">true')
            data = text.encode('ascii', errors='replace')
        if name == 'manifest.xml' or name.startswith('cert/'):
            zout.writestr(name, data)
        else:
            zout.writestr('cert/' + name, data)
os.replace(tmp, src)
" "$pkg_path" 2>/dev/null || true

    log_ok "Package created: ${pkg_path}"
    echo ""
    echo -e "  ${BOLD}Member:${NC}   ${member_name}"
    echo -e "  ${BOLD}Server:${NC}   ${CYAN}${SERVER_IP}:${SSL_COT_PORT}${NC} (SSL)"
    echo -e "  ${BOLD}Login:${NC}    ${safe_name} / ${password}"
    echo -e "  ${BOLD}File:${NC}     ${pkg_path}"
    echo -e "  ${DIM}Includes SSL certificates for secure connection${NC}"
    echo ""
    return 0
}

# Fallback: generate a simple TCP package (no certs)
_generate_tcp_package() {
    local member_name="$1"
    local safe_name="$2"
    local pkg_path="$3"

    local pkg_uid
    pkg_uid=$(gen_uuid)
    local pref_entry="cot_streams/${safe_name}.pref"

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    mkdir -p "${tmpdir}/cot_streams"
    mkdir -p "${tmpdir}/MANIFEST"

    sed -e "s|{{TEAM_NAME}}|${TEAM_NAME}|g" \
        -e "s|{{SERVER_IP}}|${SERVER_IP}|g" \
        -e "s|{{COT_PORT}}|${COT_PORT}|g" \
        "${TEMPLATES_DIR}/server.pref" > "${tmpdir}/cot_streams/${safe_name}.pref"

    local pkg_display_name="${TEAM_NAME} - ${member_name}"
    sed -e "s|{{PACKAGE_UID}}|${pkg_uid}|g" \
        -e "s|{{PACKAGE_NAME}}|${pkg_display_name}|g" \
        -e "s|{{PREF_PATH}}|${pref_entry}|g" \
        -e "s|{{TEAM_NAME}}|${TEAM_NAME}|g" \
        "${TEMPLATES_DIR}/manifest.xml" > "${tmpdir}/MANIFEST/manifest.xml"

    (cd "$tmpdir" && zip -q -r "$pkg_path" MANIFEST cot_streams)

    log_ok "Package created: ${pkg_path}"
    echo ""
    echo -e "  ${BOLD}Member:${NC}  ${member_name}"
    echo -e "  ${BOLD}Server:${NC}  ${SERVER_IP}:${COT_PORT} (TCP)"
    echo -e "  ${BOLD}File:${NC}    ${pkg_path}"
    echo ""

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

    # Prefer a fresh connection package when in Tailscale mode
    local pkg_file=""
    if [[ "${TAILSCALE_MODE:-false}" == "true" ]]; then
        generate_package "Connection"
        pkg_file="Connection_connection.zip"
    else
        # Use the most recently modified package
        pkg_file=$(find "$PACKAGES_DIR" -name "*.zip" -printf '%T@ %f\n' 2>/dev/null \
            | sort -n | tail -1 | cut -d' ' -f2-)
    fi
    if [[ -z "$pkg_file" ]]; then
        log_info "No package found, generating one..."
        generate_package "$(whoami)"
        pkg_file=$(find "$PACKAGES_DIR" -name "*.zip" -printf '%f\n' 2>/dev/null | head -1)
    fi

    # Generate QR code PNGs for the download page
    local qr_section=""
    if source "${LIB_DIR}/qr.sh" 2>/dev/null; then
        local qr_url_png="${PACKAGES_DIR}/heartbeat_qr.png"
        local qr_itak_png="${PACKAGES_DIR}/heartbeat_itak_qr.png"
        local serve_url="http://${SERVER_IP}:${port}"
        local itak_qr_data="${TEAM_NAME},${SERVER_IP},${COT_PORT},TCP"
        local url_img="" itak_img=""
        if save_qr_png "$serve_url" "$qr_url_png" 2>/dev/null && [[ -s "$qr_url_png" ]]; then
            url_img='<div class="qr-item"><img class="qr-img" src="heartbeat_qr.png" alt="URL QR code"><p class="qr-label">Open download page</p><p class="qr-hint">Scan with phone camera</p></div>'
        fi
        if save_qr_png "$itak_qr_data" "$qr_itak_png" 2>/dev/null && [[ -s "$qr_itak_png" ]]; then
            itak_img='<div class="qr-item"><img class="qr-img" src="heartbeat_itak_qr.png" alt="iTAK QR code"><p class="qr-label">Connect in iTAK</p><p class="qr-hint">iTAK &rarr; Add Server &rarr; Scan QR</p></div>'
        fi
        if [[ -n "$url_img" || -n "$itak_img" ]]; then
            qr_section="<div class=\"qr-section\">${url_img}${itak_img}</div>"
        fi
    fi

    # Render download.html into packages dir
    sed -e "s|{{TEAM_NAME}}|${TEAM_NAME}|g" \
        -e "s|{{PACKAGE_FILE}}|${pkg_file}|g" \
        -e "s|{{SERVER_IP}}|${SERVER_IP}|g" \
        -e "s|{{COT_PORT}}|${COT_PORT}|g" \
        -e "s|{{QR_SECTION}}|${qr_section}|g" \
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
    python3 -m http.server "$port" --bind "${SERVER_IP}" 2>/dev/null
}
