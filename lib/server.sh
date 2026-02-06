#!/usr/bin/env bash
# Heartbeat - Server management
# Start, stop, status, and log viewing for FreeTAKServer

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Backend loading
# ---------------------------------------------------------------------------
_load_backend() {
    load_config
    local backend="${TAK_BACKEND:-freetak}"
    local backend_file="${LIB_DIR}/backends/${backend}.sh"

    if [[ ! -f "$backend_file" ]]; then
        log_error "Unknown backend: ${backend}"
        log_error "Available: freetak, opentak"
        exit 1
    fi

    if [[ "$backend" == "opentak" ]]; then
        # OpenTAK is managed by native system services even if a stale config says docker.
        DEPLOY_MODE="native"
    fi

    source "$backend_file"
}

_backend_compose_dir() {
    case "${TAK_BACKEND:-freetak}" in
        opentak) echo "${DOCKER_DIR}/opentak" ;;
        *) echo "${DOCKER_DIR}" ;;
    esac
}

_backend_container_name() {
    case "${TAK_BACKEND:-freetak}" in
        opentak) echo "heartbeat-opentak" ;;
        *) echo "heartbeat-fts" ;;
    esac
}

# ---------------------------------------------------------------------------
# Start the server
# ---------------------------------------------------------------------------
server_start() {
    _load_backend
    backend_start
    _wait_for_server
    _show_running_info
}

# ---------------------------------------------------------------------------
# Stop the server
# ---------------------------------------------------------------------------
server_stop() {
    _load_backend
    backend_stop
    # Clean up stale PID file
    rm -f "$PID_FILE" 2>/dev/null

    # Clean Node-RED junk that may have leaked to repo root (pre-cwd-fix runs)
    rm -f "${HEARTBEAT_DIR}/.config.nodes.json" "${HEARTBEAT_DIR}/.config.runtime.json" \
          "${HEARTBEAT_DIR}/package.json" 2>/dev/null
    rm -rf "${HEARTBEAT_DIR}/JsonDB" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
server_restart() {
    server_stop
    sleep 2
    server_start
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
server_status() {
    _load_backend

    echo ""
    echo -e "${BOLD}Heartbeat TAK Server Status${NC}"
    echo -e "${DIM}══════════════════════════════════════════════${NC}"

    local running=false
    local backend_running=false
    if backend_status; then
        backend_running=true
    fi

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        if $backend_running; then
            running=true
            echo -e "  State:     ${GREEN}● running${NC} (Docker)"

            # Container uptime
            local uptime_str
            uptime_str=$(_format_container_uptime)
            if [[ -n "$uptime_str" ]]; then
                echo -e "  Uptime:    ${uptime_str}"
            fi

            # Resource usage
            local stats
            stats=$(docker stats --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}' "$(_backend_container_name)" 2>/dev/null)
            if [[ -n "$stats" ]]; then
                local cpu mem
                cpu=$(echo "$stats" | cut -f1)
                mem=$(echo "$stats" | cut -f2)
                echo -e "  CPU:       ${cpu}"
                echo -e "  Memory:    ${mem}"
            fi

            # Restart count
            local restarts
            restarts=$(docker inspect --format '{{.RestartCount}}' "$(_backend_container_name)" 2>/dev/null)
            if [[ -n "$restarts" && "$restarts" != "0" ]]; then
                echo -e "  Restarts:  ${YELLOW}${restarts}${NC}"
            fi
        else
            echo -e "  State:     ${RED}● stopped${NC}"
        fi
    else
        if $backend_running; then
            running=true
            echo -e "  State:   ${GREEN}● running${NC} (native)"
            if [[ "${TAK_BACKEND:-freetak}" == "freetak" && -f "$PID_FILE" ]]; then
                echo -e "  PID:     $(cat "$PID_FILE")"
            else
                echo -e "  Service: opentakserver.service"
            fi
        else
            echo -e "  State:   ${RED}● stopped${NC}"
        fi
    fi

    echo -e "  Mode:    ${DEPLOY_MODE}"
    echo -e "  Team:    ${TEAM_NAME}"
    echo ""

    # Endpoints
    echo -e "  ${BOLD}Endpoints${NC}"
    echo -e "  ${DIM}──────────────────────────────────${NC}"
    echo -e "  CoT:     ${CYAN}${SERVER_IP}:${COT_PORT}${NC} (TCP)"
    echo -e "  SSL CoT: ${CYAN}${SERVER_IP}:${SSL_COT_PORT}${NC}"
    echo -e "  API:     ${CYAN}${SERVER_IP}:${API_PORT}${NC}"
    echo ""

    if $running; then
        # Port checks
        echo -e "  ${BOLD}Ports${NC}"
        echo -e "  ${DIM}──────────────────────────────────${NC}"
        for p in "$COT_PORT" "$SSL_COT_PORT" "$API_PORT"; do
            if port_listening "$p"; then
                echo -e "    :${p}  ${GREEN}● listening${NC}"
            else
                echo -e "    :${p}  ${YELLOW}○ not detected${NC}"
            fi
        done
        echo ""

        # API health + connected clients
        _show_api_health
    fi

    # Package count
    local pkg_count=0
    if [[ -d "$PACKAGES_DIR" ]]; then
        pkg_count=$(find "$PACKAGES_DIR" -name "*.zip" 2>/dev/null | wc -l)
    fi
    echo -e "  Packages: ${pkg_count} generated"

    if $running; then
        echo ""
        _show_recent_logs
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
server_logs() {
    _load_backend
    backend_logs "${1:-}"
}

# ---------------------------------------------------------------------------
# Helpers - monitoring
# ---------------------------------------------------------------------------
_format_container_uptime() {
    local started_at
    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$(_backend_container_name)" 2>/dev/null) || return
    [[ -z "$started_at" ]] && return

    local start_epoch now_epoch diff
    start_epoch=$(date -d "$started_at" +%s 2>/dev/null) || return
    now_epoch=$(date +%s)
    diff=$((now_epoch - start_epoch))

    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))

    if [[ $days -gt 0 ]]; then
        echo "${days}d ${hours}h ${mins}m"
    elif [[ $hours -gt 0 ]]; then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

_show_api_health() {
    echo -e "  ${BOLD}Server Health${NC}"
    echo -e "  ${DIM}──────────────────────────────────${NC}"

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        if [[ "${TAK_BACKEND:-freetak}" == "freetak" ]]; then
            # Query FTS REST API from inside container
            # Note: 401 means the API is up (requires auth); only connection
            # errors mean the API is truly down.
            local api_result
            api_result=$(docker exec "$(_backend_container_name)" python3 -c "
import urllib.request, urllib.error, json, sys, os
port = os.environ.get('API_PORT', '19023')
result = {}
try:
    r = urllib.request.urlopen('http://127.0.0.1:' + port + '/ManageSystemUser/getSystemUser', timeout=3)
    data = json.loads(r.read().decode())
    users = data.get('json_list', [])
    result['api'] = 'up'
    result['users'] = len(users)
except urllib.error.HTTPError as e:
    # 401/403 = API is running, just needs auth
    result['api'] = 'up'
    result['users'] = -1
except Exception as e:
    result['api'] = 'down'
    result['users'] = -1
print(json.dumps(result))
" 2>/dev/null || true)

            if [[ -n "$api_result" ]]; then
                local api_state user_count
                api_state=$(echo "$api_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api','?'))" 2>/dev/null)
                user_count=$(echo "$api_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('users',-1))" 2>/dev/null)

                if [[ "$api_state" == "up" ]]; then
                    echo -e "    API:     ${GREEN}● healthy${NC}"
                    if [[ "$user_count" -ge 0 ]]; then
                        echo -e "    Users:   ${user_count} registered"
                    fi
                else
                    echo -e "    API:     ${YELLOW}○ starting...${NC}"
                fi
            else
                echo -e "    API:     ${YELLOW}○ not responding${NC}"
            fi
        else
            if port_listening "$API_PORT"; then
                echo -e "    API:     ${GREEN}● healthy${NC}"
            else
                echo -e "    API:     ${YELLOW}○ not detected${NC}"
            fi
        fi
    else
        # Native mode: check if API port is responding
        if port_listening "$API_PORT"; then
            echo -e "    API:     ${GREEN}● healthy${NC}"
        else
            echo -e "    API:     ${YELLOW}○ not detected${NC}"
        fi
    fi
    echo ""
}

_show_recent_logs() {
    echo -e "  ${BOLD}Recent Activity${NC}"
    echo -e "  ${DIM}──────────────────────────────────${NC}"

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        local compose_cmd
        compose_cmd=$(get_compose_cmd)
        if [[ -n "$compose_cmd" ]]; then
            local compose_dir
            compose_dir=$(_backend_compose_dir)
            local logs
            # Filter out health-check noise and empty lines
            logs=$(cd "$compose_dir" && $compose_cmd logs --tail=20 --no-log-prefix 2>/dev/null \
                | grep -v '^\s*$' \
                | grep -v 'empty data$' \
                | grep -v '^\[heartbeat\]' \
                | grep -v '^[0-9]*$' \
                | tail -5 || true)
            if [[ -n "$logs" ]]; then
                while IFS= read -r line; do
                    echo -e "    ${DIM}${line}${NC}"
                done <<< "$logs"
            else
                echo -e "    ${DIM}(server idle, no notable activity)${NC}"
            fi
        fi
    else
        local native_log="$LOG_FILE"
        if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
            native_log="${DATA_DIR}/opentak/logs/opentakserver.log"
        fi
        if [[ -f "$native_log" ]]; then
            tail -5 "$native_log" | while IFS= read -r line; do
                echo -e "    ${DIM}${line}${NC}"
            done
        else
            echo -e "    ${DIM}(no log file)${NC}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Helpers - server lifecycle
# ---------------------------------------------------------------------------
_wait_for_server() {
    local max_wait="${1:-5}"
    log_info "Waiting for server to accept connections..."
    local i=0

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        # Use Docker's in-container healthcheck (bypasses host network binding)
        while [[ $i -lt $max_wait ]]; do
            local health
            health=$(docker inspect --format '{{.State.Health.Status}}' "$(_backend_container_name)" 2>/dev/null || echo "none")
            if [[ "$health" == "healthy" ]]; then
                break
            fi
            sleep 1
            ((i++))
            printf "."
        done
    else
        while ! port_accepting "127.0.0.1" "${COT_PORT}" && [[ $i -lt $max_wait ]]; do
            sleep 1
            ((i++))
            printf "."
        done
    fi
    echo ""

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        local health
        health=$(docker inspect --format '{{.State.Health.Status}}' "$(_backend_container_name)" 2>/dev/null || echo "none")
        if [[ "$health" == "healthy" ]]; then
            log_ok "Server is accepting connections"
        else
            log_warn "Server may still be starting (health: ${health})"
            log_info "Check logs: ./heartbeat logs"
        fi
    else
        if port_accepting "127.0.0.1" "${COT_PORT}"; then
            log_ok "Server is accepting connections"
        else
            log_warn "Server may still be starting (port ${COT_PORT} not accepting yet)"
            log_info "Check logs: ./heartbeat logs"
        fi
    fi
}

_server_ready() {
    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        local health
        health=$(docker inspect --format '{{.State.Health.Status}}' "$(_backend_container_name)" 2>/dev/null || echo "none")
        if [[ "$health" == "healthy" ]]; then
            return 0
        fi
        port_accepting "127.0.0.1" "${COT_PORT}" && return 0
        return 1
    fi

    port_accepting "127.0.0.1" "${COT_PORT}"
}

_create_default_user() {
    load_config
    local username="${FTS_USERNAME:-team}"
    local password="${FTS_PASSWORD:-heartbeat}"

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        # Wait for API to be ready
        local i=0
        while [[ $i -lt 15 ]]; do
            if docker exec heartbeat-fts python3 -c "
import urllib.request, os
port = os.environ.get('API_PORT', '19023')
try:
    urllib.request.urlopen('http://127.0.0.1:' + port + '/AuthenticateUser', timeout=2)
except urllib.error.HTTPError:
    pass  # 401 = API is up
" 2>/dev/null; then
                break
            fi
            sleep 1
            ((i++))
        done

        # Create user via FTS REST API
        if ! docker exec heartbeat-fts python3 -c "
import urllib.request, json, sys, os
port = os.environ.get('API_PORT', '19023')
body = json.dumps({
    'systemUsers': [{
        'Name': '${username}',
        'Token': '${password}',
        'Password': '${password}',
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
    r = urllib.request.urlopen(req, timeout=5)
    if r.status == 201:
        print('ok')
except urllib.error.HTTPError:
    # User may already exist -- that's fine
    print('exists')
except Exception:
    print('fail')
" 2>/dev/null; then
            echo "fail"
        fi
        return
    fi

    # Native mode: call API on localhost
    if ! has_cmd python3; then
        echo "fail"
        return
    fi
    if ! python3 - "$username" "$password" "$API_PORT" <<'PY' 2>/dev/null; then
import urllib.request, urllib.error, json, sys
name, pw, port = sys.argv[1], sys.argv[2], sys.argv[3]
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
    f'http://127.0.0.1:{port}/ManageSystemUser/postSystemUser',
    data=body,
    headers={'Content-Type': 'application/json'}
)
try:
    r = urllib.request.urlopen(req, timeout=5)
    if r.status == 201:
        print('ok')
except urllib.error.HTTPError:
    print('exists')
except Exception:
    print('fail')
PY
        echo "fail"
    fi
}

_show_running_info() {
    local ready="false"
    if _server_ready; then
        ready="true"
    fi

    echo ""
    if [[ "$ready" == "true" ]]; then
        echo -e "${BOLD}TAK Server is running${NC}"
    else
        echo -e "${BOLD}TAK Server is starting${NC}"
    fi
    echo -e "${DIM}──────────────────────────────────${NC}"
    echo -e "  ${BOLD}Connect from iTAK/ATAK:${NC}"
    echo -e "  Server:  ${CYAN}${SERVER_IP}${NC}"
    echo -e "  Port:    ${CYAN}${COT_PORT}${NC}"
    echo -e "  Proto:   TCP"

    if [[ "$ready" == "true" ]]; then
        if [[ "${TAK_BACKEND:-freetak}" == "freetak" ]]; then
            # Create default user and sync certificate package
            local user_result
            user_result=$(_create_default_user)
            if [[ "$user_result" == "ok" ]]; then
                log_ok "Default user created"
            fi

            # Sync FTS-generated package (with SSL certs) to packages dir
            _sync_fts_package
        fi

        # Show QR code
        if source "${LIB_DIR}/qr.sh" 2>/dev/null; then
            show_qr_compact
        fi
    else
        log_info "Server still starting. Run ./heartbeat info or ./heartbeat qr in a moment."
        (
            local i=0
            while ! _server_ready && [[ $i -lt 60 ]]; do
                sleep 2
                ((i++))
            done
            if _server_ready && [[ "${TAK_BACKEND:-freetak}" == "freetak" ]]; then
                _create_default_user >/dev/null 2>&1 || true
                _sync_fts_package >/dev/null 2>&1 || true
            fi
        ) &
    fi

    echo -e "  ${DIM}./heartbeat qr           show QR code again${NC}"
    echo -e "  ${DIM}./heartbeat listen        live server monitor${NC}"
    echo ""
}

# Sync the default user's FTS certificate package to the packages dir
_sync_fts_package() {
    [[ "${TAK_BACKEND:-freetak}" != "freetak" ]] && return 0
    [[ "$DEPLOY_MODE" != "docker" ]] && return 0

    local username="${FTS_USERNAME:-team}"

    # Look up the package name from the FTS database
    local fts_pkg
    fts_pkg=$(docker exec heartbeat-fts python3 -c "
import sqlite3, sys
conn = sqlite3.connect('/opt/fts/FTSDataBase.db')
cur = conn.cursor()
cur.execute('SELECT certificate_package_name FROM SystemUser WHERE name = ?', (sys.argv[1],))
row = cur.fetchone()
print(row[0] if row and row[0] else '')
conn.close()
" "$username" 2>/dev/null)

    [[ -z "$fts_pkg" ]] && return 0

    local container_path="/opt/fts/certs/clientPackages/${fts_pkg}"
    local local_pkg="${PACKAGES_DIR}/${username}_connection.zip"

    if docker exec heartbeat-fts test -f "$container_path" 2>/dev/null; then
        ensure_dir "$PACKAGES_DIR"
        if docker cp "heartbeat-fts:${container_path}" "$local_pkg" 2>/dev/null; then
            # Patch: enable connection by default (FTS sets enabled0=false)
            _patch_package_enabled "$local_pkg"
            log_ok "Connection package synced: ${local_pkg}"
        fi
    fi
}

# Fix up an FTS-generated data package for iTAK/ATAK compatibility:
#   1. Enable connection by default (FTS sets enabled0=false)
#   2. Restructure files to match manifest zipEntry paths (cert/ prefix)
_patch_package_enabled() {
    local pkg="$1"
    [[ -f "$pkg" ]] || return 0
    python3 -c "
import zipfile, os, sys
src = sys.argv[1]
tmp = src + '.tmp'
with zipfile.ZipFile(src, 'r') as zin, zipfile.ZipFile(tmp, 'w') as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        name = item.filename
        # Patch enabled0=true in pref files
        if name.endswith('.pref'):
            text = data.decode('ascii', errors='replace')
            text = text.replace('\"enabled0\" class=\"class java.lang.Boolean\">false',
                                '\"enabled0\" class=\"class java.lang.Boolean\">true')
            data = text.encode('ascii', errors='replace')
        # Restructure: manifest.xml at root, everything else under cert/
        if name == 'manifest.xml' or name.startswith('cert/'):
            zout.writestr(name, data)
        else:
            zout.writestr('cert/' + name, data)
os.replace(tmp, src)
" "$pkg" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Live monitor - follows server activity with highlighted events
# ---------------------------------------------------------------------------
server_listen() {
    _load_backend

    local compose_cmd
    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        compose_cmd=$(get_compose_cmd)
        if [[ -z "$compose_cmd" ]]; then
            log_error "Docker Compose not available."
            return 1
        fi
    fi

    # Print compact header
    echo ""
    echo -e "${BOLD}Heartbeat Live Monitor${NC}"
    echo -e "${DIM}══════════════════════════════════════════════${NC}"
    echo -e "  Team: ${TEAM_NAME}  |  ${CYAN}${SERVER_IP}:${COT_PORT}${NC}  |  Mode: ${DEPLOY_MODE}"

    # Quick status check
    local state="stopped"
    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        state=$(cd "$DOCKER_DIR" && $compose_cmd ps --format '{{.State}}' 2>/dev/null | head -1)
    elif backend_status; then
        state="running"
    fi

    if [[ "$state" == "running" ]]; then
        echo -e "  State: ${GREEN}● running${NC}"
    else
        echo -e "  State: ${RED}● stopped${NC}"
        echo ""
        log_warn "Server is not running. Start with: ./heartbeat start"
        return 1
    fi

    echo -e "${DIM}══════════════════════════════════════════════${NC}"
    echo -e "  ${DIM}Ctrl+C to stop monitoring${NC}"
    echo ""

    # Follow logs with highlighting
    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        (cd "$DOCKER_DIR" && $compose_cmd logs -f --tail=20 --no-log-prefix 2>/dev/null) \
            | _highlight_log_stream
    else
        local native_log="$LOG_FILE"
        if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
            native_log="${DATA_DIR}/opentak/logs/opentakserver.log"
        fi
        if [[ ! -f "$native_log" ]]; then
            log_info "No log file yet."
            return 0
        fi
        tail -f "$native_log" | _highlight_log_stream
    fi
}

# Colorize log stream to highlight important events
_highlight_log_stream() {
    while IFS= read -r line; do
        # Skip blank lines
        [[ -z "$line" ]] && continue

        # Connections
        if [[ "$line" == *"connection"*"data from client"* && "$line" != *"empty data"* ]]; then
            echo -e "${GREEN}[connect]${NC} ${line}"
        elif [[ "$line" == *"Client"*"connected"* || "$line" == *"client connected"* ]]; then
            echo -e "${GREEN}[connect]${NC} ${line}"
        elif [[ "$line" == *"Client"*"disconnected"* || "$line" == *"client disconnected"* ]]; then
            echo -e "${YELLOW}[disconnect]${NC} ${line}"
        # SSL / enrollment
        elif [[ "$line" == *"SSL"* || "$line" == *"ssl"* || "$line" == *"enrollment"* ]]; then
            echo -e "${CYAN}[ssl]${NC}     ${line}"
        # User/auth activity
        elif [[ "$line" == *"SystemUser"* || "$line" == *"systemuser"* || "$line" == *"Authenticate"* ]]; then
            echo -e "${BLUE}[auth]${NC}    ${line}"
        # Errors (real ones, not health check noise)
        elif [[ "$line" == *"error"* || "$line" == *"Error"* || "$line" == *"exception"* ]] \
             && [[ "$line" != *"empty data"* ]]; then
            echo -e "${RED}[error]${NC}   ${line}"
        # Server lifecycle
        elif [[ "$line" == *"started"* || "$line" == *"Starting"* || "$line" == *"starting"* ]]; then
            echo -e "${GREEN}[server]${NC}  ${line}"
        # CoT data
        elif [[ "$line" == *"CoT"* || "$line" == *"cot"* ]]; then
            echo -e "${CYAN}[cot]${NC}     ${line}"
        # Health check noise - suppress
        elif [[ "$line" == *"empty data"* ]] || [[ "$line" =~ ^[0-9]+$ ]]; then
            continue
        # Heartbeat internal messages
        elif [[ "$line" == *"[heartbeat]"* ]]; then
            echo -e "${DIM}${line}${NC}"
        # Everything else
        else
            echo -e "${DIM}          ${line}${NC}"
        fi
    done
}
