#!/usr/bin/env bash
# Heartbeat - Fire Feed Integration
# Start, stop, and check status of the wildfire feed daemon.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

FIRE_PID="${DATA_DIR}/fire_feed.pid"
FIRE_LOG="${DATA_DIR}/fire_feed.log"
FIRE_SCRIPT="${HEARTBEAT_DIR}/tools/fire_feed.py"


cmd_fire() {
    local subcmd="${1:-status}"
    shift || true
    case "$subcmd" in
        start)  fire_start ;;
        stop)   fire_stop ;;
        status) fire_status ;;
        *)
            log_error "Usage: ./heartbeat fire {start|stop|status}"
            exit 1
            ;;
    esac
}


fire_start() {
    load_config

    if [[ "${FIRE_FEED_ENABLED:-false}" != "true" ]]; then
        log_info "Fire feed disabled (FIRE_FEED_ENABLED=false)"
        return 0
    fi

    if [[ -f "$FIRE_PID" ]]; then
        local pid
        pid=$(cat "$FIRE_PID")
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Fire feed already running (PID $pid)"
            return 0
        fi
        rm -f "$FIRE_PID"
    fi

    ensure_dir "$DATA_DIR"

    local python_bin="python3"
    local fire_args=()
    local cot_host="${SERVER_IP:-127.0.0.1}"
    local cot_port="${COT_PORT:-8087}"
    local target_label="${cot_host}:${cot_port}"

    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        cot_host="127.0.0.1"
        cot_port="${SSL_COT_PORT:-8089}"
        target_label="${cot_host}:${cot_port}"

        local ots_dir="${DATA_DIR}/opentak"
        local cert_user=""
        local preferred_cert_user="${OTS_RECORDER_CERT_USER:-administrator}"
        local fallback_cert_user="${FTS_USERNAME:-}"
        if [[ "$preferred_cert_user" == "administrator" && -n "$fallback_cert_user" ]]; then
            preferred_cert_user="$fallback_cert_user"
            fallback_cert_user="administrator"
        fi

        cert_user=$(_opentak_pick_fire_cert_user "$ots_dir" "$preferred_cert_user" "$fallback_cert_user")
        if [[ -z "$cert_user" ]]; then
            log_error "OpenTAK fire feed cert/key not found."
            log_error "Expected under: ${ots_dir}/ca/certs/<user>/<user>.pem and .key/.nopass.key"
            return 1
        fi

        local cert_dir="${ots_dir}/ca/certs/${cert_user}"
        local cert_file="${cert_dir}/${cert_user}.pem"
        local key_file="${cert_dir}/${cert_user}.nopass.key"
        local ca_file="${ots_dir}/ca/ca.pem"

        if [[ ! -f "$key_file" ]]; then
            key_file="${cert_dir}/${cert_user}.key"
        fi

        if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
            log_error "OpenTAK fire feed cert/key not found for '${cert_user}'."
            log_error "Expected: ${cert_file} and ${key_file}"
            return 1
        fi

        fire_args+=(--ssl --cert "$cert_file" --key "$key_file")
        if [[ -f "$ca_file" ]]; then
            fire_args+=(--ca "$ca_file")
        fi
        log_info "Mode: OpenTAK SSL client (${cert_user})"
    fi

    if ! has_cmd python3; then
        log_error "python3 is required but not found"
        exit 1
    fi

    if [[ ! -f "$FIRE_SCRIPT" ]]; then
        log_error "Fire feed script not found: ${FIRE_SCRIPT}"
        exit 1
    fi

    local interval="${FIRE_FEED_INTERVAL:-900}"
    local bbox="${FIRE_FEED_BBOX:-}"
    fire_args+=(--interval "$interval")
    if [[ -n "$bbox" ]]; then
        fire_args+=(--bbox "$bbox")
    fi

    log_step "Starting fire feed"
    log_info "Server: ${target_label}"
    log_info "Interval: ${interval}s"
    if [[ -n "$bbox" ]]; then
        log_info "BBOX: ${bbox}"
    else
        log_info "BBOX: none (nationwide feed)"
    fi

    nohup "$python_bin" "$FIRE_SCRIPT" \
        --host "${cot_host}" \
        --port "${cot_port}" \
        "${fire_args[@]}" \
        --log "$FIRE_LOG" \
        >> "$FIRE_LOG" 2>&1 &
    echo $! > "$FIRE_PID"

    sleep 1
    local pid
    pid=$(cat "$FIRE_PID")
    if kill -0 "$pid" 2>/dev/null; then
        log_ok "Fire feed started (PID $pid)"
        log_info "Log: ${FIRE_LOG}"
    else
        log_error "Fire feed failed to start. Check ${FIRE_LOG}"
        rm -f "$FIRE_PID"
        exit 1
    fi
}


_opentak_pick_fire_cert_user() {
    local ots_dir="${1:?missing ots_dir}"
    local preferred_user="${2:-administrator}"
    local fallback_user="${3:-}"

    _opentak_user_has_cert() {
        local base="${ots_dir}/ca/certs/$1/$1"
        [[ -f "${base}.pem" && ( -f "${base}.nopass.key" || -f "${base}.key" ) ]]
    }

    if [[ -n "$preferred_user" ]] && _opentak_user_has_cert "$preferred_user"; then
        echo "$preferred_user"
        return 0
    fi
    if [[ -n "$fallback_user" ]] && _opentak_user_has_cert "$fallback_user"; then
        echo "$fallback_user"
        return 0
    fi

    local pem_file user
    shopt -s nullglob
    for pem_file in "${ots_dir}"/ca/certs/*/*.pem; do
        user="$(basename "${pem_file%.pem}")"
        if [[ "$user" == "opentakserver" ]]; then
            continue
        fi
        if _opentak_user_has_cert "$user"; then
            echo "$user"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    echo ""
}


fire_stop() {
    if [[ ! -f "$FIRE_PID" ]]; then
        log_warn "Fire feed is not running (no PID file)"
        return 0
    fi

    local pid
    pid=$(cat "$FIRE_PID")

    if ! kill -0 "$pid" 2>/dev/null; then
        log_warn "Fire feed process not found (stale PID $pid)"
        rm -f "$FIRE_PID"
        return 0
    fi

    log_step "Stopping fire feed (PID $pid)"
    kill "$pid" 2>/dev/null || true

    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 15 ]]; do
        sleep 1
        i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Fire feed did not stop gracefully, forcing..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$FIRE_PID"
    log_ok "Fire feed stopped"
}


fire_status() {
    echo ""
    echo -e "${BOLD}Fire Feed Status${NC}"
    echo -e "${DIM}══════════════════════════════════════════════${NC}"

    load_config
    if [[ "${FIRE_FEED_ENABLED:-false}" != "true" ]]; then
        echo -e "  Enabled:   ${YELLOW}no${NC} (FIRE_FEED_ENABLED=false)"
        return 0
    fi

    echo -e "  Enabled:   ${GREEN}yes${NC}"
    echo -e "  Interval:  ${FIRE_FEED_INTERVAL:-900}s"
    if [[ -n "${FIRE_FEED_BBOX:-}" ]]; then
        echo -e "  BBOX:      ${FIRE_FEED_BBOX}"
    else
        echo -e "  BBOX:      nationwide (no filter)"
    fi

    if [[ -f "$FIRE_PID" ]]; then
        local pid
        pid=$(cat "$FIRE_PID")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  State:     ${GREEN}● running${NC} (PID $pid)"
        else
            echo -e "  State:     ${RED}● stopped${NC} (stale PID)"
            rm -f "$FIRE_PID"
        fi
    else
        echo -e "  State:     ${RED}● stopped${NC}"
    fi

    if [[ -f "$FIRE_LOG" ]]; then
        echo -e "  Log:       ${FIRE_LOG}"
    fi
}
