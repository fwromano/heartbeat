#!/usr/bin/env bash
# Heartbeat - Web map helper (FreeTAKHub WebMap)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_webmap_supported() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        return 1
    fi
    case "$(uname -m)" in
        x86_64|amd64) return 0 ;;
        *) return 1 ;;
    esac
}

_webmap_bin_path() {
    find "$WEBMAP_DIR" -maxdepth 1 -type f -name 'FTH-webmap-*' ! -name '*.json' 2>/dev/null | head -1
}

_webmap_fts_url() {
    if [[ -n "${WEBMAP_FTS_URL:-}" ]]; then
        echo "$WEBMAP_FTS_URL"
    else
        echo "${SERVER_IP:-127.0.0.1}"
    fi
}

_webmap_write_config() {
    cat > "${WEBMAP_DIR}/webMAP_config.json" <<EOF
{
  "FTH_FTS_URL": "$(_webmap_fts_url)",
  "FTH_FTS_TCP_Port": ${COT_PORT},
  "FTH_FTS_UDP_Port": ${COT_PORT}
}
EOF
}

webmap_install() {
    load_config

    if [[ "${WEBMAP_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    if ! _webmap_supported; then
        log_warn "WebMap supported on Linux x86_64 only. Skipping."
        return 1
    fi

    if [[ -z "${WEBMAP_URL:-}" ]]; then
        log_error "WEBMAP_URL is not set."
        return 1
    fi

    if ! has_cmd curl || ! has_cmd unzip; then
        log_error "WebMap requires curl and unzip."
        return 1
    fi

    ensure_dir "$WEBMAP_DIR"

    local zip_path="${WEBMAP_DIR}/webmap.zip"
    if [[ ! -f "$zip_path" ]]; then
        log_info "Downloading WebMap..."
        if ! curl -fsSL "$WEBMAP_URL" -o "$zip_path"; then
            log_error "Failed to download WebMap."
            return 1
        fi
    fi

    if [[ -z "$(_webmap_bin_path)" ]]; then
        log_info "Extracting WebMap..."
        if ! unzip -o -q "$zip_path" -d "$WEBMAP_DIR"; then
            log_error "Failed to extract WebMap."
            return 1
        fi
    fi

    local bin
    bin="$(_webmap_bin_path)"
    if [[ -z "$bin" ]]; then
        log_error "WebMap binary not found after extract."
        return 1
    fi
    chmod +x "$bin" 2>/dev/null || true

    _webmap_write_config
}

webmap_start() {
    load_config

    if [[ "${WEBMAP_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    if ! webmap_install; then
        return 1
    fi

    if [[ -f "$WEBMAP_PID_FILE" ]] && kill -0 "$(cat "$WEBMAP_PID_FILE")" 2>/dev/null; then
        return 0
    fi

    local i=0
    while ! port_accepting "127.0.0.1" "${COT_PORT}" && [[ $i -lt 15 ]]; do
        sleep 1
        ((i++))
    done

    _webmap_write_config

    local bin
    bin="$(_webmap_bin_path)"
    if [[ -z "$bin" ]]; then
        log_error "WebMap binary not found."
        return 1
    fi

    nohup "$bin" "${WEBMAP_DIR}/webMAP_config.json" >> "$WEBMAP_LOG_FILE" 2>&1 &
    echo $! > "$WEBMAP_PID_FILE"
    log_ok "WebMap started (port ${WEBMAP_PORT:-8000})"
}

webmap_stop() {
    if [[ -f "$WEBMAP_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WEBMAP_PID_FILE")
        if kill "$pid" 2>/dev/null; then
            log_ok "WebMap stopped"
        fi
        rm -f "$WEBMAP_PID_FILE"
    fi
}
