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
# Recorder process discovery helpers
# ---------------------------------------------------------------------------
_recorder_find_pids() {
    # Match recorder instances bound to this workspace DB.
    pgrep -f "tools/recorder.py.*--db ${RECORDER_DB}" 2>/dev/null || true
}

record_is_running() {
    if [[ -f "$RECORDER_PID" ]]; then
        local pid
        pid=$(cat "$RECORDER_PID")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    [[ -n "$(_recorder_find_pids)" ]]
}

record_latest_session_id() {
    if [[ ! -f "$RECORDER_DB" ]] || ! has_cmd python3; then
        echo ""
        return 0
    fi
    python3 - "$RECORDER_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
row = conn.execute("SELECT id FROM recording_sessions ORDER BY id DESC LIMIT 1").fetchone()
conn.close()
if row:
    print(int(row[0]))
PY
}

_record_stop_pid() {
    local pid="${1:?missing pid}"
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    kill "$pid" 2>/dev/null || true

    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 10 ]]; do
        sleep 1
        i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Recorder PID ${pid} did not stop gracefully, forcing..."
        kill -9 "$pid" 2>/dev/null || true
    fi
}

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

    local existing_pids existing_pid_count primary_pid
    existing_pids="$(_recorder_find_pids)"
    if [[ -n "$existing_pids" ]]; then
        primary_pid=$(echo "$existing_pids" | head -n1)
        existing_pid_count=$(echo "$existing_pids" | wc -l | tr -d ' ')
        if [[ ! -f "$RECORDER_PID" ]]; then
            echo "$primary_pid" > "$RECORDER_PID"
        fi
        if [[ "$existing_pid_count" -gt 1 ]]; then
            log_warn "Multiple recorder processes detected (${existing_pid_count}); keeping PID ${primary_pid}, stopping extras."
            while IFS= read -r pid; do
                [[ -n "$pid" ]] || continue
                [[ "$pid" == "$primary_pid" ]] && continue
                _record_stop_pid "$pid"
            done <<< "$existing_pids"
        fi
        log_warn "Recorder already running (PID ${primary_pid})"
        return 0
    fi

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
            # No cert exists yet (fresh install). Auto-generate one for the recorder.
            cert_user="$preferred_cert_user"
            log_info "No recorder cert found — generating one for '${cert_user}'"
            source "${LIB_DIR}/package.sh"
            ensure_dir "$PACKAGES_DIR"
            local _pkg_path="${PACKAGES_DIR}/${cert_user}.zip"
            if ! _generate_opentak_package "$cert_user" "$cert_user" "$_pkg_path"; then
                log_error "Failed to auto-generate recorder cert for '${cert_user}'."
                log_error "Try manually: ./heartbeat package \"${cert_user}\""
                return 1
            fi
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
        local recorder_group="${OTS_RECORDER_GROUP:-Cyan}"
        local recorder_role="${OTS_RECORDER_ROLE:-Team Member}"
        recorder_args+=(--group "$recorder_group" --role "$recorder_role")
        log_info "Mode: OpenTAK SSL client (${cert_user})"
        log_info "Group: ${recorder_group} (${recorder_role})"
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
        local orphan_pids
        orphan_pids="$(_recorder_find_pids)"
        if [[ -z "$orphan_pids" ]]; then
            log_warn "Recorder is not running (no PID file)"
            return 0
        fi

        log_warn "Recorder PID file missing; stopping detected recorder process(es)."
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            log_step "Stopping CoT recorder (PID $pid)"
            _record_stop_pid "$pid"
        done <<< "$orphan_pids"
        log_ok "Recorder stopped"
        return 0
    fi

    local pid
    pid=$(cat "$RECORDER_PID")

    if ! kill -0 "$pid" 2>/dev/null; then
        log_warn "Recorder process not found (stale PID $pid)"
        rm -f "$RECORDER_PID"
        local orphan_pids
        orphan_pids="$(_recorder_find_pids)"
        if [[ -n "$orphan_pids" ]]; then
            log_warn "Found untracked recorder process(es); stopping them."
            while IFS= read -r opid; do
                [[ -n "$opid" ]] || continue
                log_step "Stopping CoT recorder (PID $opid)"
                _record_stop_pid "$opid"
            done <<< "$orphan_pids"
            log_ok "Recorder stopped"
        fi
        return 0
    fi

    log_step "Stopping CoT recorder (PID $pid)"
    _record_stop_pid "$pid"

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
    local state_printed="false"
    if [[ -f "$RECORDER_PID" ]]; then
        local pid
        pid=$(cat "$RECORDER_PID")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  State:     ${GREEN}● recording${NC} (PID $pid)"
            state_printed="true"
        else
            rm -f "$RECORDER_PID"
        fi
    fi

    if [[ "$state_printed" == "false" ]]; then
        local orphan_pids orphan_count orphan_pid
        orphan_pids="$(_recorder_find_pids)"
        if [[ -n "$orphan_pids" ]]; then
            orphan_pid=$(echo "$orphan_pids" | head -n1)
            orphan_count=$(echo "$orphan_pids" | wc -l | tr -d ' ')
            echo -e "  State:     ${YELLOW}● recording${NC} (PID ${orphan_pid}, untracked)"
            if [[ "$orphan_count" -gt 1 ]]; then
                echo -e "  Note:      ${YELLOW}${orphan_count} recorder processes detected${NC}"
            fi
        else
            echo -e "  State:     ${RED}● stopped${NC}"
        fi
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
