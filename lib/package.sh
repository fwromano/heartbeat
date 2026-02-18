#!/usr/bin/env bash
# Heartbeat - Data package generation
# Creates TAK data packages (.zip) importable by iTAK and ATAK

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Serve daemon state
# ---------------------------------------------------------------------------
SERVE_PID="${DATA_DIR}/serve.pid"
SERVE_LOG="${DATA_DIR}/serve.log"

# ---------------------------------------------------------------------------
# Auto-generate the next device name (device-1, device-2, ...)
#
# Counts existing packages in the packages/ dir, skipping system artifacts,
# and returns the next sequential name.
# ---------------------------------------------------------------------------
next_device_name() {
    load_config
    local max=0

    if [[ -d "$PACKAGES_DIR" ]]; then
        local n
        for f in "$PACKAGES_DIR"/device-*.zip; do
            [[ -e "$f" ]] || continue
            n="${f##*/device-}"          # strip path + "device-"
            n="${n%%.zip}"              # strip suffix
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n > max )); then
                max=$n
            fi
        done
    fi

    echo "device-$((max + 1))"
}

# ---------------------------------------------------------------------------
# Generate a connection data package for a team member
#
# Usage: generate_package "Member Name"
# Output: packages/<sanitized_name>.zip
# ---------------------------------------------------------------------------
generate_package() {
    local member_name="${1:?Usage: generate_package <member_name>}"
    load_config

    local safe_name
    safe_name=$(echo "$member_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    local pkg_filename="${safe_name}.zip"
    local pkg_path="${PACKAGES_DIR}/${pkg_filename}"

    ensure_dir "$PACKAGES_DIR"

    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        _generate_opentak_package "$member_name" "$safe_name" "$pkg_path"
        return $?
    fi

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

# Generate an SSL certificate package via local OpenTAK datastore + CA.
_generate_opentak_package() {
    local member_name="$1"
    local safe_name="$2"
    local pkg_path="$3"
    local ots_dir="${DATA_DIR}/opentak"
    local ots_venv="${ots_dir}/venv"
    local webtak_port="${WEBTAK_PORT:-8443}"
    local user_password="$safe_name"
    local cert_user="$safe_name"

    if [[ "$safe_name" == "${FTS_USERNAME:-}" && -n "${FTS_PASSWORD:-}" ]]; then
        user_password="${FTS_PASSWORD}"
    fi

    if [[ "$safe_name" == "${FTS_USERNAME:-}" && -z "${FTS_PASSWORD:-}" ]]; then
        log_error "Configured OpenTAK password for '${safe_name}' is empty."
        log_error "Re-run setup to regenerate credentials, then retry package generation."
        return 1
    fi

    if [[ ${#user_password} -lt 8 ]]; then
        user_password="${safe_name}1234"
    fi

    if [[ ! -x "${ots_venv}/bin/python3" ]]; then
        log_error "OpenTAK venv not found. Run ./setup.sh --backend opentak first."
        return 1
    fi

    # Ensure credentials exist in datastore. If this fails due transient DB startup,
    # continue and attempt cert generation anyway.
    if ! opentak_upsert_user_local "${ots_dir}" "${ots_venv}" "${safe_name}" "${user_password}" "user" 3; then
        log_warn "Could not confirm OpenTAK user '${safe_name}' in datastore; continuing with certificate generation."
    fi

    if ! (
        cd "${ots_dir}"
        OTS_DATA_FOLDER="${ots_dir}" \
        OTS_CONFIG_PATH="${ots_dir}/config.yml" \
        OTS_CONFIG_FILE="${ots_dir}/config.yml" \
        "${ots_venv}/bin/python3" - "${cert_user}" "${SERVER_IP}" "${webtak_port}" <<'PY'
import logging
import sys
import yaml
from flask import Flask
from opentakserver.certificate_authority import CertificateAuthority

username, server_ip, webtak_port = sys.argv[1:]
cfg = yaml.safe_load(open("config.yml", "r", encoding="utf-8")) or {}
app = Flask(__name__)
app.config.update(cfg)
logger = logging.getLogger("heartbeat-opentak-ca")
logger.addHandler(logging.NullHandler())
ca = CertificateAuthority(logger, app)
with app.test_request_context("/", base_url=f"https://{server_ip}:{webtak_port}/"):
    ca.issue_certificate(username, False)
PY
    ); then
        log_error "OpenTAK certificate package request failed for '${safe_name}'."
        return 1
    fi

    local src_pkg="${ots_dir}/ca/certs/${cert_user}/${cert_user}_CONFIG_iTAK.zip"
    if [[ ! -f "$src_pkg" ]]; then
        src_pkg="${ots_dir}/ca/certs/${cert_user}/${cert_user}_CONFIG.zip"
    fi
    if [[ ! -f "$src_pkg" ]]; then
        log_error "OpenTAK generated no package file for '${cert_user}'."
        return 1
    fi

    cp -f "$src_pkg" "$pkg_path"

    log_ok "Package created: ${pkg_path}"
    echo ""
    echo -e "  ${BOLD}Member:${NC}   ${member_name}"
    echo -e "  ${BOLD}Server:${NC}   ${CYAN}${SERVER_IP}:${SSL_COT_PORT}${NC} (SSL)"
    echo -e "  ${BOLD}Login:${NC}    ${safe_name} / ${user_password}"
    echo -e "  ${BOLD}File:${NC}     ${pkg_path}"
    echo -e "  ${DIM}OpenTAK iTAK/ATAK SSL package${NC}"
    echo ""

    return 0
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

    echo -e "${BOLD}Generated data packages:${NC}"
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
    local bind_host="${HEARTBEAT_SERVE_HOST:-0.0.0.0}"
    local preferred_member=""
    local use_opentak_auto="false"

    ensure_dir "$PACKAGES_DIR"

    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        preferred_member="$(next_device_name)"
    else
        preferred_member="$(whoami)"
    fi

    # Ensure at least one package exists
    local pkg_file=""
    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        use_opentak_auto="true"
        log_info "OpenTAK auto package mode: each download gets a unique device package."
        log_info "Fallback manual generation: ./heartbeat package \"name\""
    else
        if [[ "${TAILSCALE_MODE:-false}" == "true" ]]; then
            generate_package "Connection" || true
        fi
        pkg_file=$(find "$PACKAGES_DIR" -name "*.zip" -printf '%T@ %f\n' 2>/dev/null \
            | sort -n | tail -1 | cut -d' ' -f2-)
        if [[ -z "$pkg_file" ]]; then
            log_info "No package found, generating one..."
            if ! generate_package "${preferred_member}"; then
                log_error "Could not generate a package automatically."
                return 1
            fi
            pkg_file=$(find "$PACKAGES_DIR" -name "*.zip" -printf '%f\n' 2>/dev/null | head -1)
        fi
    fi

    # Keep template placeholder empty by default (direct URL flow).
    local qr_section=""

    # Build download section: package list (OpenTAK) or single button (FreeTAK)
    local download_section=""
    local cot_port="${COT_PORT}"
    local protocol="TCP"

    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        cot_port="${SSL_COT_PORT:-8089}"
        protocol="SSL"
        download_section='<a class="download-btn" href="/next-package">Generate and Download My Device Package</a><p class="note">Each tap creates one unique package/certificate for one device.</p>'
    else
        download_section="<a class=\"download-btn\" href=\"${pkg_file}\" download>Download Data Package</a>"
    fi

    # Render unified template
    sed -e "s|{{SERVER_IP}}|${SERVER_IP}|g" \
        -e "s|{{COT_PORT}}|${cot_port}|g" \
        -e "s|{{PROTOCOL}}|${protocol}|g" \
        -e "s|{{QR_SECTION}}|${qr_section}|g" \
        -e "s|{{DOWNLOAD_SECTION}}|${download_section}|g" \
        "${TEMPLATES_DIR}/download.html" > "${PACKAGES_DIR}/index.html"

    echo ""
    echo -e "${BOLD}Serving data packages:${NC}"
    echo ""
    echo -e "  ${CYAN}http://${SERVER_IP}:${port}/${NC}"
    echo -e "  ${DIM}(bind ${bind_host})${NC}"
    echo ""
    echo -e "  Open this URL on each device to download its package."
    echo -e "  ${DIM}Press Ctrl+C to stop.${NC}"
    echo ""

    if [[ "$use_opentak_auto" == "true" ]]; then
        python3 "${HEARTBEAT_DIR}/tools/package_server.py" \
            --port "$port" \
            --bind "${bind_host}" \
            --packages-dir "${PACKAGES_DIR}" \
            --heartbeat-dir "${HEARTBEAT_DIR}" \
            --opentak-auto
    else
        cd "$PACKAGES_DIR"
        python3 -m http.server "$port" --bind "${bind_host}" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# Serve daemon lifecycle
# ---------------------------------------------------------------------------
serve_start() {
    load_config
    local port="${1:-${HEARTBEAT_SERVE_PORT:-9000}}"

    if [[ -f "$SERVE_PID" ]]; then
        local pid
        pid=$(cat "$SERVE_PID")
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Package server already running (PID $pid)"
            return 0
        fi
        rm -f "$SERVE_PID"
    fi

    ensure_dir "$DATA_DIR"
    ensure_dir "$PACKAGES_DIR"

    nohup "${HEARTBEAT_DIR}/heartbeat" serve "$port" >> "$SERVE_LOG" 2>&1 &
    echo $! > "$SERVE_PID"

    sleep 1
    local pid
    pid=$(cat "$SERVE_PID")
    if kill -0 "$pid" 2>/dev/null; then
        log_ok "Package server started (PID $pid)"
        log_info "Packages URL: http://${SERVER_IP}:${port}/"
        log_info "Log: ${SERVE_LOG}"
    else
        log_error "Package server failed to start. Check ${SERVE_LOG}"
        rm -f "$SERVE_PID"
        return 1
    fi
}

serve_stop() {
    if [[ ! -f "$SERVE_PID" ]]; then
        return 0
    fi

    local pid
    pid=$(cat "$SERVE_PID")
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$SERVE_PID"
        return 0
    fi

    log_step "Stopping package server (PID $pid)"
    kill "$pid" 2>/dev/null || true

    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 10 ]]; do
        sleep 1
        i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Package server did not stop gracefully, forcing..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$SERVE_PID"
    log_ok "Package server stopped"
}

serve_status() {
    load_config
    local port="${HEARTBEAT_SERVE_PORT:-9000}"

    echo ""
    echo -e "${BOLD}Package Server Status${NC}"
    echo -e "${DIM}══════════════════════════════════════════════${NC}"
    echo -e "  URL:       http://${SERVER_IP}:${port}/"

    if [[ -f "$SERVE_PID" ]]; then
        local pid
        pid=$(cat "$SERVE_PID")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  State:     ${GREEN}● running${NC} (PID $pid)"
        else
            echo -e "  State:     ${RED}● stopped${NC} (stale PID)"
            rm -f "$SERVE_PID"
        fi
    else
        echo -e "  State:     ${RED}● stopped${NC}"
    fi

    if [[ -f "$SERVE_LOG" ]]; then
        echo -e "  Log:       ${SERVE_LOG}"
    fi
}
