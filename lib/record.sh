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
RECORDER_SCRIPT="${HEARTBEAT_DIR}/tools/recorder.py"

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

    # Check dependencies
    if ! has_cmd python3; then
        log_error "python3 is required but not found"
        exit 1
    fi

    if ! python3 -c "import xml.etree.ElementTree" 2>/dev/null; then
        log_error "Python XML support missing"
        exit 1
    fi

    if [[ ! -f "$RECORDER_SCRIPT" ]]; then
        log_error "Recorder script not found: $RECORDER_SCRIPT"
        exit 1
    fi

    ensure_dir "$DATA_DIR"

    local cot_port="${COT_PORT:-8087}"

    log_step "Starting CoT recorder"
    log_info "Server: 127.0.0.1:${cot_port}"
    log_info "Database: ${RECORDER_DB}"

    nohup python3 "$RECORDER_SCRIPT" \
        --host 127.0.0.1 \
        --port "${cot_port}" \
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
        ((i++))
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
        local event_count
        event_count=$(python3 -c "
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
try:
    c = conn.execute('SELECT COUNT(*) FROM cot_events').fetchone()[0]
    print(c)
except:
    print(0)
conn.close()
" "$RECORDER_DB" 2>/dev/null || echo "0")

        local db_size
        db_size=$(du -h "$RECORDER_DB" 2>/dev/null | cut -f1)

        echo -e "  Events:    ${event_count}"
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
