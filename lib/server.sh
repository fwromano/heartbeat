#!/usr/bin/env bash
# Heartbeat - Server management
# Start, stop, status, and log viewing for FreeTAKServer

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Start the server
# ---------------------------------------------------------------------------
server_start() {
    load_config

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        _docker_start
    else
        _native_start
    fi

    source "${LIB_DIR}/beacon.sh"
    beacon_start || true

    if [[ "${WEBMAP_ENABLED:-false}" == "true" ]]; then
        source "${LIB_DIR}/webmap.sh"
        webmap_start || true
    fi
}

_docker_start() {
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -z "$compose_cmd" ]]; then
        log_error "Docker Compose not available."
        return 1
    fi

    log_step "Starting TAK server (Docker)"

    # Export all config vars for docker-compose env substitution
    export COT_PORT SSL_COT_PORT API_PORT DATAPACKAGE_PORT
    export FTS_CONNECTION_MSG SERVER_IP

    # Add localhost CoT binding for host-side services (WebMap, Beacon)
    local override="${DOCKER_DIR}/docker-compose.override.yml"
    if [[ "$SERVER_IP" != "127.0.0.1" ]]; then
        cat > "$override" <<OVERRIDE
services:
  fts:
    ports:
      - "127.0.0.1:${COT_PORT:-8087}:${COT_PORT:-8087}"
OVERRIDE
    else
        rm -f "$override"
    fi

    (cd "$DOCKER_DIR" && $compose_cmd up -d --build)

    # Wait for server to be ready
    _wait_for_server

    _show_running_info
}

_native_start() {
    local venv_dir="${DATA_DIR}/venv"
    local fts_dir="${DATA_DIR}/fts"

    if [[ ! -d "$venv_dir" ]]; then
        log_error "FreeTAKServer not installed. Run ./setup.sh first."
        return 1
    fi

    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log_warn "Server already running (PID $(cat "$PID_FILE"))"
        return 0
    fi

    log_step "Starting TAK server (native)"

    ensure_dir "$(dirname "$LOG_FILE")"

    export FTS_CONFIG_PATH="${fts_dir}/FTSConfig.yaml"

    nohup "${venv_dir}/bin/python3" -m FreeTAKServer.controllers.services.FTS \
        >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    log_info "PID: $(cat "$PID_FILE")"

    _wait_for_server

    _show_running_info
}

# ---------------------------------------------------------------------------
# Stop the server
# ---------------------------------------------------------------------------
server_stop() {
    load_config

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        _docker_stop
    else
        _native_stop
    fi

    source "${LIB_DIR}/beacon.sh"
    beacon_stop || true

    if [[ "${WEBMAP_ENABLED:-false}" == "true" ]]; then
        source "${LIB_DIR}/webmap.sh"
        webmap_stop || true
    fi

    # Clean up stale PID files
    rm -f "$BEACON_PID_FILE" "$WEBMAP_PID_FILE" "$PID_FILE" 2>/dev/null
}

_docker_stop() {
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    if [[ -z "$compose_cmd" ]]; then
        log_error "Docker Compose not available."
        return 1
    fi

    log_step "Stopping TAK server"
    (cd "$DOCKER_DIR" && $compose_cmd down)
    rm -f "${DOCKER_DIR}/docker-compose.override.yml" 2>/dev/null
    log_ok "Server stopped"
}

_native_stop() {
    if [[ ! -f "$PID_FILE" ]]; then
        log_warn "No PID file found. Server may not be running."
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")

    log_step "Stopping TAK server (PID ${pid})"

    if kill "$pid" 2>/dev/null; then
        # Wait for graceful shutdown
        local i=0
        while kill -0 "$pid" 2>/dev/null && [[ $i -lt 10 ]]; do
            sleep 1
            ((i++))
        done
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Graceful shutdown timed out, forcing..."
            kill -9 "$pid" 2>/dev/null || true
        fi
        log_ok "Server stopped"
    else
        log_warn "Process $pid not found (already stopped?)"
    fi

    rm -f "$PID_FILE"
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
    load_config

    echo ""
    echo -e "${BOLD}Heartbeat TAK Server Status${NC}"
    echo -e "${DIM}══════════════════════════════════════════════${NC}"

    local running=false

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        local compose_cmd
        compose_cmd=$(get_compose_cmd)
        if [[ -n "$compose_cmd" ]]; then
            local state
            state=$(cd "$DOCKER_DIR" && $compose_cmd ps --format '{{.State}}' 2>/dev/null | head -1)
            if [[ "$state" == "running" ]]; then
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
                stats=$(docker stats --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}' heartbeat-fts 2>/dev/null)
                if [[ -n "$stats" ]]; then
                    local cpu mem
                    cpu=$(echo "$stats" | cut -f1)
                    mem=$(echo "$stats" | cut -f2)
                    echo -e "  CPU:       ${cpu}"
                    echo -e "  Memory:    ${mem}"
                fi

                # Restart count
                local restarts
                restarts=$(docker inspect --format '{{.RestartCount}}' heartbeat-fts 2>/dev/null)
                if [[ -n "$restarts" && "$restarts" != "0" ]]; then
                    echo -e "  Restarts:  ${YELLOW}${restarts}${NC}"
                fi
            else
                echo -e "  State:     ${RED}● stopped${NC}"
            fi
        fi
    else
        if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            running=true
            echo -e "  State:   ${GREEN}● running${NC} (native)"
            echo -e "  PID:     $(cat "$PID_FILE")"
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

    source "${LIB_DIR}/beacon.sh"
    beacon_status
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
    load_config

    local follow="${1:-}"

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        local compose_cmd
        compose_cmd=$(get_compose_cmd)
        if [[ -z "$compose_cmd" ]]; then
            log_error "Docker Compose not available."
            return 1
        fi
        if [[ "$follow" == "-f" || "$follow" == "--follow" ]]; then
            (cd "$DOCKER_DIR" && $compose_cmd logs -f --tail=100)
        else
            (cd "$DOCKER_DIR" && $compose_cmd logs --tail=50)
        fi
    else
        if [[ ! -f "$LOG_FILE" ]]; then
            log_info "No log file yet. Start the server first."
            return 0
        fi
        if [[ "$follow" == "-f" || "$follow" == "--follow" ]]; then
            tail -f "$LOG_FILE"
        else
            tail -50 "$LOG_FILE"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Helpers - monitoring
# ---------------------------------------------------------------------------
_format_container_uptime() {
    local started_at
    started_at=$(docker inspect --format '{{.State.StartedAt}}' heartbeat-fts 2>/dev/null) || return
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
        # Query FTS REST API from inside container
        # Note: 401 means the API is up (requires auth); only connection
        # errors mean the API is truly down.
        local api_result
        api_result=$(docker exec heartbeat-fts python3 -c "
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
" 2>/dev/null)

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
            local logs
            # Filter out health-check noise and empty lines
            logs=$(cd "$DOCKER_DIR" && $compose_cmd logs --tail=20 --no-log-prefix 2>/dev/null \
                | grep -v '^\s*$' \
                | grep -v 'empty data$' \
                | grep -v '^\[heartbeat\]' \
                | grep -v '^[0-9]*$' \
                | tail -5)
            if [[ -n "$logs" ]]; then
                while IFS= read -r line; do
                    echo -e "    ${DIM}${line}${NC}"
                done <<< "$logs"
            else
                echo -e "    ${DIM}(server idle, no notable activity)${NC}"
            fi
        fi
    else
        if [[ -f "$LOG_FILE" ]]; then
            tail -5 "$LOG_FILE" | while IFS= read -r line; do
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
    log_info "Waiting for server to accept connections..."
    local i=0

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        # Use Docker's in-container healthcheck (bypasses host network binding)
        while [[ $i -lt 30 ]]; do
            local health
            health=$(docker inspect --format '{{.State.Health.Status}}' heartbeat-fts 2>/dev/null || echo "none")
            if [[ "$health" == "healthy" ]]; then
                break
            fi
            sleep 1
            ((i++))
            printf "."
        done
    else
        while ! port_accepting "127.0.0.1" "${COT_PORT}" && [[ $i -lt 30 ]]; do
            sleep 1
            ((i++))
            printf "."
        done
    fi
    echo ""

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        local health
        health=$(docker inspect --format '{{.State.Health.Status}}' heartbeat-fts 2>/dev/null || echo "none")
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
    echo ""
    echo -e "${BOLD}TAK Server is running${NC}"
    echo -e "${DIM}──────────────────────────────────${NC}"
    echo -e "  ${BOLD}Connect from iTAK/ATAK:${NC}"
    echo -e "  Server:  ${CYAN}${SERVER_IP}${NC}"
    echo -e "  Port:    ${CYAN}${COT_PORT}${NC}"
    echo -e "  Proto:   TCP"

    # Create default user and sync certificate package
    local user_result
    user_result=$(_create_default_user)
    if [[ "$user_result" == "ok" ]]; then
        log_ok "Default user created"
    fi

    # Sync FTS-generated package (with SSL certs) to packages dir
    _sync_fts_package

    # Show QR code
    if source "${LIB_DIR}/qr.sh" 2>/dev/null; then
        show_qr_compact
    fi

    echo -e "  ${DIM}./heartbeat qr           show QR code again${NC}"
    echo -e "  ${DIM}./heartbeat adduser NAME  add another team member${NC}"
    echo -e "  ${DIM}./heartbeat listen        live server monitor${NC}"
    echo ""
}

# Sync the default user's FTS certificate package to the packages dir
_sync_fts_package() {
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
    load_config

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
    elif [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
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
        if [[ ! -f "$LOG_FILE" ]]; then
            log_info "No log file yet."
            return 0
        fi
        tail -f "$LOG_FILE" | _highlight_log_stream
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
