#!/usr/bin/env bash
# Heartbeat - Beacon helper
# Sends a periodic CoT "beacon" so the server itself appears on the map.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_beacon_usage() {
    echo "Usage:"
    echo "  ./heartbeat beacon status"
    echo "  ./heartbeat beacon start|stop|restart"
    echo "  ./heartbeat beacon on|off"
    echo "  ./heartbeat beacon set --lat <lat> --lon <lon> [--alt <meters>]"
    echo "  ./heartbeat beacon set --name <callsign> [--interval <sec>]"
    echo ""
}

_beacon_enabled() {
    [[ "${BEACON_ENABLED:-true}" == "true" ]]
}

_beacon_running() {
    [[ -f "$BEACON_PID_FILE" ]] && kill -0 "$(cat "$BEACON_PID_FILE")" 2>/dev/null
}

beacon_start() {
    load_config

    if ! _beacon_enabled; then
        return 0
    fi

    if _beacon_running; then
        return 0
    fi

    if [[ -z "${BEACON_LAT:-}" || -z "${BEACON_LON:-}" ]]; then
        log_warn "Beacon has no coordinates set. Skipping."
        log_info "Set with: ./heartbeat beacon set --lat <lat> --lon <lon>"
        return 0
    fi

    if ! has_cmd python3; then
        log_error "python3 is required for the beacon."
        return 1
    fi

    local uid="${BEACON_UID:-}"
    if [[ -z "$uid" ]]; then
        uid="beacon-$(gen_uuid)"
        set_config "BEACON_UID" "$uid"
    fi

    local name="${BEACON_NAME:-Heartbeat Beacon}"
    local interval="${BEACON_INTERVAL:-10}"
    local alt="${BEACON_ALT:-0}"
    local host="${BEACON_HOST:-$([ "${DEPLOY_MODE:-}" = "docker" ] && echo "127.0.0.1" || echo "$SERVER_IP")}"
    local port="${BEACON_PORT:-$COT_PORT}"
    local type="${BEACON_TYPE:-a-f-G-U-C}"
    local ce="${BEACON_CE:-5.0}"
    local le="${BEACON_LE:-5.0}"

    nohup python3 - "$uid" "$name" "$BEACON_LAT" "$BEACON_LON" "$alt" "$interval" \
        "$host" "$port" "$type" "$ce" "$le" >> "$BEACON_LOG_FILE" 2>&1 <<'PY' &
import datetime as dt
import socket
import sys
import time
import signal

uid, name, lat, lon, alt, interval, host, port, cot_type, ce, le = sys.argv[1:]
lat = float(lat)
lon = float(lon)
alt = float(alt)
interval = float(interval)
port = int(port)
ce = float(ce)
le = float(le)

running = True
sock = None

def _stop(*_args):
    global running
    running = False

signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)

def _connect():
    global sock
    try:
        sock = socket.create_connection((host, port), timeout=3)
        sock.settimeout(3)
    except Exception as e:
        sock = None
        print(f"[beacon] connect failed: {e}")

def _send(msg):
    global sock
    if sock is None:
        _connect()
    if sock is None:
        return
    try:
        sock.sendall(msg.encode("utf-8"))
    except Exception as e:
        print(f"[beacon] send failed: {e}")
        try:
            sock.close()
        except Exception:
            pass
        sock = None

while running:
    now = dt.datetime.utcnow()
    stale = now + dt.timedelta(seconds=interval * 3)
    ts = now.replace(microsecond=0).isoformat() + "Z"
    stale_ts = stale.replace(microsecond=0).isoformat() + "Z"
    msg = (
        f'<event version="2.0" uid="{uid}" type="{cot_type}" how="m-p" '
        f'time="{ts}" start="{ts}" stale="{stale_ts}">'
        f'<point lat="{lat}" lon="{lon}" hae="{alt}" ce="{ce}" le="{le}"/>'
        f'<detail><contact callsign="{name}"/></detail>'
        f'</event>\n'
    )
    _send(msg)
    time.sleep(interval)

if sock is not None:
    try:
        sock.close()
    except Exception:
        pass
PY
    echo $! > "$BEACON_PID_FILE"
    log_ok "Beacon started (${name} @ ${BEACON_LAT}, ${BEACON_LON})"
}

beacon_stop() {
    if _beacon_running; then
        local pid
        pid=$(cat "$BEACON_PID_FILE")
        if kill "$pid" 2>/dev/null; then
            log_ok "Beacon stopped"
        fi
        rm -f "$BEACON_PID_FILE"
    fi
}

beacon_status() {
    load_config
    if _beacon_running; then
        echo -e "  Beacon:  ${GREEN}● running${NC} (${BEACON_NAME:-Heartbeat Beacon})"
    else
        if _beacon_enabled; then
            echo -e "  Beacon:  ${YELLOW}○ enabled${NC} (not running)"
        else
            echo -e "  Beacon:  ${DIM}disabled${NC}"
        fi
    fi
}

beacon_cmd() {
    load_config
    local action="${1:-status}"
    shift || true

    case "$action" in
        start)
            beacon_start
            ;;
        stop)
            beacon_stop
            ;;
        restart)
            beacon_stop
            beacon_start
            ;;
        status)
            beacon_status
            ;;
        on|enable)
            set_config "BEACON_ENABLED" "true"
            log_ok "Beacon enabled"
            if port_listening "${COT_PORT}"; then
                beacon_start || true
            fi
            ;;
        off|disable)
            set_config "BEACON_ENABLED" "false"
            beacon_stop || true
            log_ok "Beacon disabled"
            ;;
        set)
            local lat="" lon="" alt="" name="" interval=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --lat) lat="$2"; shift 2 ;;
                    --lon) lon="$2"; shift 2 ;;
                    --alt) alt="$2"; shift 2 ;;
                    --name) name="$2"; shift 2 ;;
                    --interval) interval="$2"; shift 2 ;;
                    *) log_error "Unknown option: $1"; _beacon_usage; return 1 ;;
                esac
            done
            if [[ -n "$lat" ]]; then set_config "BEACON_LAT" "$lat"; fi
            if [[ -n "$lon" ]]; then set_config "BEACON_LON" "$lon"; fi
            if [[ -n "$alt" ]]; then set_config "BEACON_ALT" "$alt"; fi
            if [[ -n "$name" ]]; then set_config "BEACON_NAME" "$name"; fi
            if [[ -n "$interval" ]]; then set_config "BEACON_INTERVAL" "$interval"; fi
            set_config "BEACON_ENABLED" "true"
            log_ok "Beacon updated"
            if port_listening "${COT_PORT}"; then
                beacon_stop || true
                beacon_start || true
            else
                log_info "Beacon will start on next ./heartbeat start"
            fi
            ;;
        *)
            _beacon_usage
            return 1
            ;;
    esac
}
