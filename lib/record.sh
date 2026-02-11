#!/usr/bin/env bash
# Heartbeat - CoT Recording
# Start, stop, and check status of the CoT recorder daemon

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
RECORDER_PID="${DATA_DIR}/recorder.pid"
RECORDER_LOG="${DATA_DIR}/recorder.log"
RECORDER_DB="${DATA_DIR}/cot_records.db"
RECORDER_SCRIPT_TCP="${HEARTBEAT_DIR}/tools/recorder.py"

# ---------------------------------------------------------------------------
# Command dispatcher
# ---------------------------------------------------------------------------
cmd_record() {
    local subcmd="${1:-status}"
    shift || true
    case "$subcmd" in
        start)  record_start ;;
        stop)   record_stop ;;
        status) record_status ;;
        *)
            log_error "Usage: ./heartbeat record {start|stop|status}"
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Start recorder daemon
# ---------------------------------------------------------------------------
record_start() {
    load_config

    # Check if already running
    if [[ -f "$RECORDER_PID" ]]; then
        local pid
        pid=$(cat "$RECORDER_PID")
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Recorder already running (PID $pid)"
            return 0
        fi
        # Stale PID file
        rm -f "$RECORDER_PID"
    fi

    ensure_dir "$DATA_DIR"

    local python_bin="python3"
    local recorder_script="$RECORDER_SCRIPT_TCP"
    local cot_port="${COT_PORT:-8087}"
    local cot_host="${SERVER_IP:-127.0.0.1}"
    local target_label="${cot_host}:${cot_port}"
    local recorder_args=()

    if [[ "${TAK_BACKEND:-freetak}" == "opentak" ]]; then
        # OpenTAK recorder path is SSL-only (mTLS) to capture all routed CoT types.
        local transport="${OTS_RECORDER_TRANSPORT:-ssl}"
        transport=$(echo "$transport" | tr '[:upper:]' '[:lower:]')
        if [[ "$transport" != "ssl" ]]; then
            log_warn "OTS_RECORDER_TRANSPORT='${transport}' is deprecated; using ssl"
        fi

        cot_host="127.0.0.1"
        cot_port="${SSL_COT_PORT:-8089}"
        target_label="${cot_host}:${cot_port}"

        local ots_dir="${DATA_DIR}/opentak"
        local cert_user=""
        local preferred_cert_user="${OTS_RECORDER_CERT_USER:-administrator}"
        local fallback_cert_user="${FTS_USERNAME:-}"
        # Favor the configured TAK username when recorder user is left on the
        # historical "administrator" default and a user cert exists.
        if [[ "$preferred_cert_user" == "administrator" && -n "$fallback_cert_user" ]]; then
            preferred_cert_user="$fallback_cert_user"
            fallback_cert_user="administrator"
        fi
        cert_user=$(_opentak_pick_recorder_cert_user "$ots_dir" "$preferred_cert_user" "$fallback_cert_user")
        if [[ -z "$cert_user" ]]; then
            log_error "OpenTAK recorder cert/key not found."
            log_error "Expected under: ${ots_dir}/ca/certs/<user>/<user>.pem and .key/.nopass.key"
            log_error "Generate at least one user package/cert first, then retry."
            return 1
        fi
        if [[ "$cert_user" != "$preferred_cert_user" ]]; then
            log_warn "Recorder cert user '${preferred_cert_user}' not found, using '${cert_user}'"
            set_config "OTS_RECORDER_CERT_USER" "$cert_user"
        fi
        local cert_dir="${ots_dir}/ca/certs/${cert_user}"
        local cert_file="${cert_dir}/${cert_user}.pem"
        local key_file="${cert_dir}/${cert_user}.nopass.key"
        local ca_file="${ots_dir}/ca/ca.pem"

        if [[ ! -f "$key_file" ]]; then
            key_file="${cert_dir}/${cert_user}.key"
        fi

        if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
            log_error "OpenTAK recorder cert/key not found for '${cert_user}'."
            log_error "Expected: ${cert_file} and ${key_file}"
            log_error "Generate a package/cert first, then retry."
            return 1
        fi

        recorder_args+=(--ssl --cert "$cert_file" --key "$key_file")
        if [[ -f "$ca_file" ]]; then
            recorder_args+=(--ca "$ca_file")
        fi
        log_info "Mode: OpenTAK SSL client (${cert_user})"
    fi

    if [[ "$python_bin" == "python3" ]]; then
        if ! has_cmd python3; then
            log_error "python3 is required but not found"
            exit 1
        fi
    elif [[ ! -x "$python_bin" ]]; then
        log_error "Python runtime not executable: ${python_bin}"
        exit 1
    fi

    if [[ ! -f "$recorder_script" ]]; then
        log_error "Recorder script not found: ${recorder_script}"
        exit 1
    fi

    log_step "Starting CoT recorder"
    log_info "Server: ${target_label}"
    log_info "Database: ${RECORDER_DB}"

    nohup "$python_bin" "$recorder_script" \
        --host "${cot_host}" \
        --port "${cot_port}" \
        "${recorder_args[@]}" \
        --db "$RECORDER_DB" \
        --log "$RECORDER_LOG" \
        >> "$RECORDER_LOG" 2>&1 &
    echo $! > "$RECORDER_PID"

    # Brief wait then verify
    sleep 1
    local pid
    pid=$(cat "$RECORDER_PID")
    if kill -0 "$pid" 2>/dev/null; then
        log_ok "Recorder started (PID $pid)"
        log_info "Log: ${RECORDER_LOG}"
    else
        log_error "Recorder failed to start. Check ${RECORDER_LOG}"
        rm -f "$RECORDER_PID"
        exit 1
    fi
}

_opentak_pick_recorder_cert_user() {
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

# ---------------------------------------------------------------------------
# Stop recorder daemon
# ---------------------------------------------------------------------------
record_stop() {
    if [[ ! -f "$RECORDER_PID" ]]; then
        log_warn "Recorder is not running (no PID file)"
        return 0
    fi

    local pid
    pid=$(cat "$RECORDER_PID")

    if ! kill -0 "$pid" 2>/dev/null; then
        log_warn "Recorder process not found (stale PID $pid)"
        rm -f "$RECORDER_PID"
        return 0
    fi

    log_step "Stopping CoT recorder (PID $pid)"

    # Send SIGTERM for graceful shutdown
    kill "$pid" 2>/dev/null || true

    # Wait up to 10 seconds
    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 10 ]]; do
        sleep 1
        i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Recorder did not stop gracefully, forcing..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$RECORDER_PID"
    log_ok "Recorder stopped"
}

# ---------------------------------------------------------------------------
# Recorder status
# ---------------------------------------------------------------------------
record_status() {
    echo ""
    echo -e "${BOLD}CoT Recorder Status${NC}"
    echo -e "${DIM}══════════════════════════════════════════════${NC}"

    # Process status
    if [[ -f "$RECORDER_PID" ]]; then
        local pid
        pid=$(cat "$RECORDER_PID")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  State:     ${GREEN}● recording${NC} (PID $pid)"
        else
            echo -e "  State:     ${RED}● stopped${NC} (stale PID)"
            rm -f "$RECORDER_PID"
        fi
    else
        echo -e "  State:     ${RED}● stopped${NC}"
    fi

    # Database stats
    if [[ -f "$RECORDER_DB" ]]; then
        local stats event_count last_event latest_session latest_session_events latest_started latest_stopped
        stats=$(python3 -c "
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
try:
    c = conn.execute('SELECT COUNT(*) FROM cot_events').fetchone()[0]
    last = conn.execute('SELECT MAX(time) FROM cot_events').fetchone()[0] or ''
    session = conn.execute('SELECT id, events_count, started_at, stopped_at FROM recording_sessions ORDER BY id DESC LIMIT 1').fetchone()
    if session:
        sid = session[0] or ''
        sev = session[1] or 0
        sstart = session[2] or ''
        sstop = session[3] or ''
    else:
        sid = ''
        sev = 0
        sstart = ''
        sstop = ''
    print(f'{c}|{last}|{sid}|{sev}|{sstart}|{sstop}')
except:
    print('0|||||')
conn.close()
" "$RECORDER_DB" 2>/dev/null || echo "0")
        event_count="${stats%%|*}"
        local rest
        rest="${stats#*|}"
        last_event="${rest%%|*}"
        rest="${rest#*|}"
        latest_session="${rest%%|*}"
        rest="${rest#*|}"
        latest_session_events="${rest%%|*}"
        rest="${rest#*|}"
        latest_started="${rest%%|*}"
        latest_stopped="${rest#*|}"

        local db_size
        db_size=$(du -h "$RECORDER_DB" 2>/dev/null | cut -f1)

        echo -e "  Events:    ${event_count} ${DIM}(lifetime)${NC}"
        if [[ -n "$last_event" ]]; then
            echo -e "  Last:      ${last_event} ${DIM}(lifetime)${NC}"
        fi
        if [[ -n "$latest_session" ]]; then
            echo -e "  Session:   ${latest_session} ${DIM}(${latest_session_events} events${latest_started:+, started ${latest_started}}${latest_stopped:+, stopped ${latest_stopped}})${NC}"
        fi
        echo -e "  DB size:   ${db_size}"
        echo -e "  DB path:   ${RECORDER_DB}"
    else
        echo -e "  Database:  ${DIM}(no recordings yet)${NC}"
    fi

    # Log file
    if [[ -f "$RECORDER_LOG" ]]; then
        echo -e "  Log:       ${RECORDER_LOG}"
    fi

    echo ""
}
