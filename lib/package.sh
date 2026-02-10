#!/usr/bin/env bash
# Heartbeat - Data package generation
# Creates TAK connection packages (.zip) importable by iTAK and ATAK

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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
        for f in "$PACKAGES_DIR"/device-*_connection.zip; do
            [[ -e "$f" ]] || continue
            n="${f##*/device-}"          # strip path + "device-"
            n="${n%%_connection.zip}"    # strip suffix
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
    local bind_host="${HEARTBEAT_SERVE_HOST:-0.0.0.0}"
    local preferred_member=""

    ensure_dir "$PACKAGES_DIR"

    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        preferred_member="${FTS_USERNAME:-admin}"
    else
        preferred_member="$(whoami)"
    fi

    # Prefer a fresh connection package when in Tailscale mode
    local pkg_file=""
    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        # OpenTAK packages are certificate identities. Reusing one package across
        # devices causes identity collisions and RabbitMQ routing conflicts.
        log_warn "OpenTAK packages are device-specific (one per device)."
        log_warn "  ./heartbeat package           # auto: device-1, device-2, ..."
        log_warn "  ./heartbeat package \"name\"    # or pick a name"

        pkg_file=$(find "$PACKAGES_DIR" -name "*.zip" -printf '%T@ %f\n' 2>/dev/null \
            | sort -n | tail -1 | cut -d' ' -f2-)
        if [[ -z "$pkg_file" ]]; then
            log_info "No OpenTAK package found, generating one for '${preferred_member}'..."
            if generate_package "${preferred_member}"; then
                pkg_file="${preferred_member// /_}_connection.zip"
            else
                log_error "Could not generate initial OpenTAK package."
                return 1
            fi
        fi
    elif [[ "${TAILSCALE_MODE:-false}" == "true" ]]; then
        if generate_package "Connection"; then
            pkg_file="Connection_connection.zip"
        else
            log_warn "Could not generate a fresh package; using latest existing package."
        fi
    else
        # Use the most recently modified package
        pkg_file=$(find "$PACKAGES_DIR" -name "*.zip" -printf '%T@ %f\n' 2>/dev/null \
            | sort -n | tail -1 | cut -d' ' -f2-)
    fi
    if [[ -z "$pkg_file" ]]; then
        log_info "No package found, generating one..."
        if ! generate_package "${preferred_member}"; then
            log_error "Could not generate a package automatically."
            log_error "Try: ./heartbeat package \"${preferred_member}\""
            return 1
        fi
        pkg_file=$(find "$PACKAGES_DIR" -name "*.zip" -printf '%f\n' 2>/dev/null | head -1)
    fi

    # Generate QR code PNGs for the download page
    local qr_section=""
    if source "${LIB_DIR}/qr.sh" 2>/dev/null; then
        local qr_url_png="${PACKAGES_DIR}/heartbeat_qr.png"
        local serve_url="http://${SERVER_IP}:${port}"
        local url_img=""
        if save_qr_png "$serve_url" "$qr_url_png" 2>/dev/null && [[ -s "$qr_url_png" ]]; then
            url_img='<div class="qr-item"><img class="qr-img" src="heartbeat_qr.png" alt="URL QR code"><p class="qr-label">Open download page</p><p class="qr-hint">Scan with phone camera</p></div>'
        fi
        if [[ -n "$url_img" ]]; then
            qr_section="<div class=\"qr-section\">${url_img}</div>"
        fi
    fi

    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        local package_links=""
        local f=""
        while IFS= read -r f; do
            package_links="${package_links}<li><a href=\"${f}\">${f}</a></li>"
        done < <(find "$PACKAGES_DIR" -maxdepth 1 -name "*.zip" -printf '%f\n' | sort)
        if [[ -z "$package_links" ]]; then
            package_links="<li>${pkg_file}</li>"
        fi

        cat > "${PACKAGES_DIR}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${TEAM_NAME} OpenTAK Packages</title>
  <style>
    body { font-family: Arial, sans-serif; max-width: 760px; margin: 2rem auto; padding: 0 1rem; }
    .warn { background: #fff3cd; border: 1px solid #ffe69c; padding: 1rem; border-radius: 8px; margin-bottom: 1rem; }
    code { background: #f1f3f5; padding: 0.15rem 0.3rem; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>${TEAM_NAME} OpenTAK Packages</h1>
  <div class="warn">
    <strong>Important:</strong> Each device must import a different package. Do not share one package across phone/tablet.
    <br>Generate more with <code>./heartbeat package "&lt;device-name&gt;"</code>.
  </div>
  ${qr_section}
  <h2>Available Packages</h2>
  <ul>${package_links}</ul>
  <p>Server: <code>${SERVER_IP}:${SSL_COT_PORT}</code> (SSL)</p>
</body>
</html>
EOF
    else
        # Render download.html into packages dir
        sed -e "s|{{TEAM_NAME}}|${TEAM_NAME}|g" \
            -e "s|{{PACKAGE_FILE}}|${pkg_file}|g" \
            -e "s|{{SERVER_IP}}|${SERVER_IP}|g" \
            -e "s|{{COT_PORT}}|${COT_PORT}|g" \
            -e "s|{{QR_SECTION}}|${qr_section}|g" \
            "${TEMPLATES_DIR}/download.html" > "${PACKAGES_DIR}/index.html"
    fi

    echo ""
    echo -e "${BOLD}Serving connection packages:${NC}"
    echo ""
    echo -e "  ${CYAN}http://${SERVER_IP}:${port}/${NC}"
    echo -e "  ${DIM}(bind ${bind_host})${NC}"
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
    python3 -m http.server "$port" --bind "${bind_host}" 2>/dev/null
}
