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

# Generate an SSL certificate package via OpenTAK API.
_generate_opentak_package() {
    local member_name="$1"
    local safe_name="$2"
    local pkg_path="$3"
    local ots_dir="${DATA_DIR}/opentak"
    local ots_venv="${ots_dir}/venv"
    local webtak_port="${WEBTAK_PORT:-8443}"
    local local_api_port=8081
    local user_password="$safe_name"
    local admin_user="administrator"
    local admin_password="password"
    local cert_user="$safe_name"
    local auth_user="$safe_name"
    local auth_password="$user_password"
    local api_resp=""

    if [[ "$safe_name" == "${FTS_USERNAME:-}" && -n "${FTS_PASSWORD:-}" ]]; then
        user_password="${FTS_PASSWORD}"
    fi
    if [[ ${#user_password} -lt 8 ]]; then
        if [[ "$safe_name" == "${FTS_USERNAME:-}" ]]; then
            log_error "Configured OpenTAK password for '${safe_name}' is shorter than 8 characters."
            log_error "Re-run setup with a longer password, then retry package generation."
            return 1
        fi
        user_password="${safe_name}1234"
    fi
    auth_password="${user_password}"

    if [[ ! -x "${ots_venv}/bin/flask" ]]; then
        log_error "OpenTAK venv not found. Run ./setup.sh --backend opentak first."
        return 1
    fi

    if ! port_listening "${webtak_port}" && ! port_listening "${local_api_port}"; then
        log_error "OpenTAK API is not reachable on :${webtak_port} or :${local_api_port}. Start server first: ./heartbeat start"
        return 1
    fi

    if ! (
        cd "${ots_dir}"
        export OTS_DATA_FOLDER="${ots_dir}"
        export OTS_CONFIG_PATH="${ots_dir}/config.yml"
        export OTS_CONFIG_FILE="${ots_dir}/config.yml"
        export FLASK_APP=opentakserver.app

        if ! "${ots_venv}/bin/flask" users create --username "${safe_name}" --password "${user_password}" --active >/dev/null 2>&1; then
            "${ots_venv}/bin/flask" users activate "${safe_name}" >/dev/null 2>&1 || true
            "${ots_venv}/bin/flask" users change_password "${safe_name}" --password "${user_password}" >/dev/null 2>&1 || exit 1
        fi
    ); then
        log_warn "Could not provision OpenTAK user '${safe_name}' via local CLI; trying API fallback."
    fi

    local uid payload api_url user_add_payload activate_payload pw_reset_payload
    uid=$(gen_uuid)
    payload="{\"username\":\"${cert_user}\",\"uid\":\"${uid}\"}"
    for api_url in \
        "https://127.0.0.1:${webtak_port}/api/certificate" \
        "http://127.0.0.1:${local_api_port}/api/certificate"
    do
        api_resp=$(curl -ksS \
            -u "${auth_user}:${auth_password}" \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "${api_url}" 2>/dev/null || true)
        if [[ "$api_resp" == *"\"success\":true"* || "$api_resp" == *"\"success\": true"* ]]; then
            break
        fi
    done

    if [[ "$api_resp" != *"\"success\":true"* && "$api_resp" != *"\"success\": true"* ]]; then
        # Try creating/updating the requested user via administrator API.
        user_add_payload="{\"username\":\"${safe_name}\",\"password\":\"${user_password}\",\"confirm_password\":\"${user_password}\",\"roles\":[\"user\"]}"
        activate_payload="{\"username\":\"${safe_name}\"}"
        pw_reset_payload="{\"username\":\"${safe_name}\",\"new_password\":\"${user_password}\"}"

        for api_url in \
            "https://127.0.0.1:${webtak_port}" \
            "http://127.0.0.1:${local_api_port}"
        do
            curl -ksS -u "${admin_user}:${admin_password}" -H "Content-Type: application/json" \
                -d "${user_add_payload}" "${api_url}/api/user/add" >/dev/null 2>&1 || true
            curl -ksS -u "${admin_user}:${admin_password}" -H "Content-Type: application/json" \
                -d "${activate_payload}" "${api_url}/api/user/activate" >/dev/null 2>&1 || true
            curl -ksS -u "${admin_user}:${admin_password}" -H "Content-Type: application/json" \
                -d "${pw_reset_payload}" "${api_url}/api/user/password/reset" >/dev/null 2>&1 || true
        done

        # Retry certificate request as requested user after admin-side create/reset.
        cert_user="${safe_name}"
        auth_user="${safe_name}"
        auth_password="${user_password}"
        uid=$(gen_uuid)
        payload="{\"username\":\"${cert_user}\",\"uid\":\"${uid}\"}"
        for api_url in \
            "https://127.0.0.1:${webtak_port}/api/certificate" \
            "http://127.0.0.1:${local_api_port}/api/certificate"
        do
            api_resp=$(curl -ksS \
                -u "${auth_user}:${auth_password}" \
                -H "Content-Type: application/json" \
                -d "${payload}" \
                "${api_url}" 2>/dev/null || true)
            if [[ "$api_resp" == *"\"success\":true"* || "$api_resp" == *"\"success\": true"* ]]; then
                break
            fi
        done
    fi

    if [[ "$api_resp" != *"\"success\":true"* && "$api_resp" != *"\"success\": true"* ]]; then
        # Final fallback: use built-in OpenTAK admin user.
        cert_user="${admin_user}"
        auth_user="${admin_user}"
        auth_password="${admin_password}"
        uid=$(gen_uuid)
        payload="{\"username\":\"${cert_user}\",\"uid\":\"${uid}\"}"
        for api_url in \
            "https://127.0.0.1:${webtak_port}/api/certificate" \
            "http://127.0.0.1:${local_api_port}/api/certificate"
        do
            api_resp=$(curl -ksS \
                -u "${auth_user}:${auth_password}" \
                -H "Content-Type: application/json" \
                -d "${payload}" \
                "${api_url}" 2>/dev/null || true)
            if [[ "$api_resp" == *"\"success\":true"* || "$api_resp" == *"\"success\": true"* ]]; then
                log_warn "Falling back to OpenTAK default user '${admin_user}' for package generation."
                break
            fi
        done
    fi

    if [[ "$api_resp" != *"\"success\":true"* && "$api_resp" != *"\"success\": true"* ]]; then
        # Last resort: issue cert/package directly from local CA without API.
        # Use the built-in OpenTAK admin account because it is always present.
        cert_user="${admin_user}"
        auth_user="${admin_user}"
        auth_password="${admin_password}"
        if (
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
            api_resp='{"success": true, "fallback": "local_ca"}'
            log_warn "Used local OpenTAK CA fallback with '${admin_user}' credentials."
        fi
    fi

    if [[ "$api_resp" != *"\"success\":true"* && "$api_resp" != *"\"success\": true"* ]]; then
        log_error "OpenTAK certificate package request failed for '${safe_name}'."
        [[ -n "$api_resp" ]] && log_error "API response: ${api_resp}"
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
    echo -e "  ${BOLD}Login:${NC}    ${auth_user} / ${auth_password}"
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
        preferred_member="${FTS_USERNAME:-administrator}"
    else
        preferred_member="$(whoami)"
    fi

    # Prefer a fresh connection package when in Tailscale mode
    local pkg_file=""
    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        if generate_package "${preferred_member}"; then
            pkg_file="${preferred_member// /_}_connection.zip"
        else
            log_warn "Could not generate a fresh OpenTAK package; using latest existing package."
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
