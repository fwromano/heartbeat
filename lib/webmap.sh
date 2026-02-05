#!/usr/bin/env bash
# Heartbeat - Web map helper (CoTView)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_cotview_launch() {
    local host="${COTVIEW_FTS_HOST:-127.0.0.1}"
    local port="${COTVIEW_FTS_PORT:-${COT_PORT:-8087}}"
    local http_port="${WEBMAP_PORT:-8000}"
    local center_lat="${WEBMAP_VIEW_LAT:-${BEACON_LAT:-0}}"
    local center_lon="${WEBMAP_VIEW_LON:-${BEACON_LON:-0}}"
    local center_zoom="${WEBMAP_VIEW_ZOOM:-15}"
    local stale_seconds="${COTVIEW_STALE_SECONDS:-300}"

    local verbose_flag=()
    if [[ "${COTVIEW_VERBOSE:-false}" == "true" ]]; then
        verbose_flag+=(--verbose)
    fi

    (cd "$LIB_DIR" && nohup python3 cotview.py \
        --host "$host" \
        --port "$port" \
        --http-port "$http_port" \
        --center-lat "$center_lat" \
        --center-lon "$center_lon" \
        --center-zoom "$center_zoom" \
        --stale-seconds "$stale_seconds" \
        "${verbose_flag[@]}" \
        >> "$WEBMAP_LOG_FILE" 2>&1) &
    echo $! > "$WEBMAP_PID_FILE"
}

_webmap_port_pids() {
    local port="$1"
    if ! has_cmd ss; then
        return 0
    fi
    ss -tlnp 2>/dev/null | grep -E "LISTEN\\s+.*:${port}\\b" | grep -o 'pid=[0-9]\+' | cut -d= -f2 | sort -u
}

_webmap_open_browser() {
    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && has_cmd xdg-open; then
        local map_url="http://localhost:${WEBMAP_PORT:-8000}/"
        if [[ -n "${SUDO_USER:-}" ]]; then
            local xauth="${XAUTHORITY:-/home/${SUDO_USER}/.Xauthority}"
            (sleep 3 && sudo -u "$SUDO_USER" DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
                XAUTHORITY="$xauth" xdg-open "$map_url" >/dev/null 2>&1) &
        else
            (sleep 3 && xdg-open "$map_url" >/dev/null 2>&1) &
        fi
    fi
}

webmap_install() {
    load_config

    if [[ "${WEBMAP_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    if ! has_cmd python3; then
        log_error "CoTView requires python3."
        return 1
    fi

    if ! python3 -c "import websockets" 2>/dev/null; then
        log_info "Installing websockets for CoTView..."
        if has_cmd pip3; then
            pip3 install --quiet websockets
        elif python3 -m pip --version >/dev/null 2>&1; then
            python3 -m pip install --quiet websockets
        else
            log_error "pip3 is required to install websockets."
            return 1
        fi
    fi
}

webmap_start() {
    load_config

    if [[ "${WEBMAP_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    if ! webmap_install; then
        return 1
    fi

    local port="${WEBMAP_PORT:-8000}"
    local running_pids=()
    while read -r pid; do
        [[ -n "$pid" ]] && running_pids+=("$pid")
    done < <(_webmap_port_pids "$port")

    if [[ ${#running_pids[@]} -gt 0 ]]; then
        echo "${running_pids[0]}" > "$WEBMAP_PID_FILE"
        log_ok "WebMap already running (port ${port})"
        _webmap_open_browser
        return 0
    fi

    if [[ -f "$WEBMAP_PID_FILE" ]] && kill -0 "$(cat "$WEBMAP_PID_FILE")" 2>/dev/null; then
        log_ok "WebMap already running (port ${port})"
        _webmap_open_browser
        return 0
    fi

    if ! _cotview_launch; then
        return 1
    fi
    log_ok "WebMap started (port ${port})"
    _webmap_open_browser
}

webmap_stop() {
    local port="${WEBMAP_PORT:-8000}"
    local -a pids=()
    local -A seen=()
    if [[ -f "$WEBMAP_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WEBMAP_PID_FILE")
        [[ -n "$pid" ]] && pids+=("$pid")
    fi
    while read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
    done < <(_webmap_port_pids "$port")

    if [[ ${#pids[@]} -gt 0 ]]; then
        for pid in "${pids[@]}"; do
            if [[ -n "${seen[$pid]:-}" ]]; then
                continue
            fi
            seen[$pid]=1
            if kill "$pid" 2>/dev/null; then
                log_ok "WebMap stopped"
            fi
        done
    fi
    rm -f "$WEBMAP_PID_FILE"
    rm -f "${WEBMAP_DIR}/.config.nodes.json" "${WEBMAP_DIR}/.config.runtime.json" \
          "${WEBMAP_DIR}/package.json" 2>/dev/null
    rm -rf "${WEBMAP_DIR}/JsonDB" 2>/dev/null
}
