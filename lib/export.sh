#!/usr/bin/env bash
# Heartbeat - CoT Export
# Export recorded CoT events to GeoPackage format

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

EXPORTER_SCRIPT="${HEARTBEAT_DIR}/tools/exporter.py"
RECORDER_DB="${DATA_DIR}/cot_records.db"
DEFAULT_MAPPING="${CONFIG_DIR}/gcm-mapping.yml"
EXPORTS_DIR="${DATA_DIR}/exports"

usage() {
    echo "Usage: ./heartbeat export [-o file.gpkg] [--gcm] [--mapping file.yml] [--all|--session-id N]"
    echo ""
    echo "Options:"
    echo "  -o, --output   Output GeoPackage file (default: data/exports/*_export_YYYYmmdd_HHMMSS.gpkg)"
    echo "  --gcm          Export Graphic Control Measures only"
    echo "  --mapping      GCM mapping YAML file (default: config/gcm-mapping.yml)"
    echo "  --all          Export all sessions (default: latest session)"
    echo "  --session-id   Export only a specific recording session ID"
    echo "  -h, --help     Show this help"
}

cmd_export() {
    local output=""
    local gcm=false
    local mapping=""
    local export_all=false
    local session_id=""
    local explicit_session=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                output="$2"
                shift 2
                ;;
            --gcm)
                gcm=true
                shift
                ;;
            --mapping)
                mapping="$2"
                shift 2
                ;;
            --all)
                export_all=true
                shift
                ;;
            --session-id)
                session_id="$2"
                explicit_session=true
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                return 1
                ;;
        esac
    done

    if [[ -z "$output" ]]; then
        local ts
        ts=$(date +"%Y%m%d_%H%M%S")
        ensure_dir "$EXPORTS_DIR"
        if [[ "$gcm" == "true" ]]; then
            output="${EXPORTS_DIR}/gcm_export_${ts}.gpkg"
        else
            output="${EXPORTS_DIR}/cot_export_${ts}.gpkg"
        fi
    fi

    local output_dir
    output_dir="$(dirname "$output")"
    ensure_dir "$output_dir"

    if [[ ! -f "$RECORDER_DB" ]]; then
        log_error "Recording database not found: ${RECORDER_DB}"
        log_info "Run: ./heartbeat record start"
        return 1
    fi

    local selected_session_events=""
    local latest_nonempty_session=""

    if ! has_cmd python3; then
        log_error "python3 is required but not found"
        return 1
    fi

    if [[ -n "$session_id" ]]; then
        if [[ ! "$session_id" =~ ^[0-9]+$ ]]; then
            log_error "--session-id must be a positive integer"
            return 1
        fi
    elif [[ "$export_all" != "true" ]]; then
        # Default to the latest recording session so exports always reflect the most
        # recent run, even when that run captured 0 events.
        session_id=$(python3 - "$RECORDER_DB" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
row = db.execute(
    "SELECT id FROM recording_sessions ORDER BY id DESC LIMIT 1"
).fetchone()
db.close()
if row:
    print(int(row[0]))
PY
)
    fi

    if [[ -n "$session_id" ]]; then
        selected_session_events=$(python3 - "$RECORDER_DB" "$session_id" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
row = db.execute(
    "SELECT events_count FROM recording_sessions WHERE id = ?",
    (int(sys.argv[2]),),
).fetchone()
db.close()
if row is not None:
    print(int(row[0] or 0))
PY
)
        if [[ "$explicit_session" != "true" && -n "$selected_session_events" && "$selected_session_events" -eq 0 ]]; then
            latest_nonempty_session=$(python3 - "$RECORDER_DB" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
row = db.execute(
    "SELECT id FROM recording_sessions WHERE events_count > 0 ORDER BY id DESC LIMIT 1"
).fetchone()
db.close()
if row:
    print(int(row[0]))
PY
)
        fi
    fi

    if ! python3 -c "import shapely" 2>/dev/null; then
        log_error "shapely is required: pip install shapely"
        return 1
    fi

    if [[ ! -f "$EXPORTER_SCRIPT" ]]; then
        log_error "Exporter script not found: ${EXPORTER_SCRIPT}"
        return 1
    fi

    if [[ "$gcm" == "true" ]]; then
        if [[ -z "$mapping" ]]; then
            mapping="$DEFAULT_MAPPING"
        fi

        if ! python3 -c "import yaml" 2>/dev/null; then
            log_error "pyyaml is required for GCM export: pip install pyyaml"
            return 1
        fi

        if [[ ! -f "$mapping" ]]; then
            log_error "Mapping file not found: ${mapping}"
            return 1
        fi
    fi

    log_step "Exporting CoT events"
    log_info "Database: ${RECORDER_DB}"
    log_info "Output:   ${output}"
    if [[ "$gcm" == "true" ]]; then
        log_info "Mode:     GCM"
        log_info "Mapping:  ${mapping}"
    else
        log_info "Mode:     Raw"
    fi
    if [[ -n "$session_id" ]]; then
        log_info "Session:  ${session_id}"
        if [[ -n "$selected_session_events" && "$selected_session_events" -eq 0 ]]; then
            log_warn "Selected session has 0 ingested events (recorder saw no CoT data)."
            if [[ -n "$latest_nonempty_session" && "$latest_nonempty_session" != "$session_id" ]]; then
                log_warn "Last non-empty session: ${latest_nonempty_session} (run: ./heartbeat export --session-id ${latest_nonempty_session})"
            fi
        fi
    else
        log_info "Session:  all"
    fi

    local cmd=(python3 "$EXPORTER_SCRIPT" --db "$RECORDER_DB" --output "$output")
    if [[ "$gcm" == "true" ]]; then
        cmd+=(--gcm --mapping "$mapping")
    fi
    if [[ -n "$session_id" ]]; then
        cmd+=(--session-id "$session_id")
    fi

    PYTHONPATH="${HEARTBEAT_DIR}/tools${PYTHONPATH:+:$PYTHONPATH}" "${cmd[@]}"

    if [[ ! -f "$output" ]]; then
        log_error "Export failed: output file not created"
        return 1
    fi

    local size
    size=$(du -h "$output" 2>/dev/null | cut -f1)
    log_ok "Export complete"
    log_info "File: ${output} (${size})"

    if _write_export_summary "$output" "$RECORDER_DB" "$gcm" "$session_id"; then
        :
    else
        log_warn "Could not write export summary for ${output}"
    fi
}

_write_export_summary() {
    local gpkg="$1"
    local db_path="$2"
    local gcm="$3"
    local session_id="${4:-}"
    local summary_path="${gpkg%.gpkg}_summary.txt"

    local summary_written
    summary_written=$(python3 - "$gpkg" "$db_path" "$gcm" "$summary_path" "$session_id" <<'PY'
import datetime
import sqlite3
import sys

gpkg_path, db_path, gcm_mode, summary_path, session_id_arg = sys.argv[1:]


def safe_count(conn, query):
    try:
        row = conn.execute(query).fetchone()
        if not row:
            return 0
        value = row[0]
        return int(value or 0)
    except Exception:
        return 0


gpkg = sqlite3.connect(gpkg_path)
gpkg.row_factory = sqlite3.Row
db = sqlite3.connect(db_path)
db.row_factory = sqlite3.Row
session_id = int(session_id_arg) if session_id_arg else None

mode = "GCM" if gcm_mode == "true" else "RAW"
generated = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

lines = []
lines.append("Heartbeat Export Summary")
lines.append("========================")
lines.append(f"Generated: {generated}")
lines.append(f"Mode: {mode}")
lines.append(f"GeoPackage: {gpkg_path}")
lines.append(f"Source DB: {db_path}")
if session_id is None:
    lines.append("Scope: all sessions")
else:
    lines.append(f"Scope: session {session_id}")
lines.append("")

if session_id is None:
    source_events = safe_count(db, "SELECT COUNT(*) FROM cot_events")
    source_vertices = safe_count(db, "SELECT COUNT(*) FROM cot_geometry_points")
else:
    source_events = safe_count(
        db, f"SELECT COUNT(*) FROM cot_events WHERE session_id = {session_id}"
    )
    source_vertices = safe_count(
        db,
        "SELECT COUNT(*) FROM cot_geometry_points WHERE event_id IN "
        f"(SELECT id FROM cot_events WHERE session_id = {session_id})",
    )
lines.append("Source Snapshot")
lines.append(f"- CoT events: {source_events}")
lines.append(f"- Geometry vertices: {source_vertices}")
if session_id is not None:
    row = db.execute(
        "SELECT started_at, stopped_at, events_count FROM recording_sessions WHERE id = ?",
        (session_id,),
    ).fetchone()
    if row:
        lines.append(f"- Session started: {row['started_at'] or ''}")
        lines.append(f"- Session stopped: {row['stopped_at'] or ''}")
        lines.append(f"- Session events_count: {row['events_count'] or 0}")
lines.append("")

tables = gpkg.execute(
    """
    SELECT c.table_name, COALESCE(gc.geometry_type_name, 'UNKNOWN') AS geometry_type
    FROM gpkg_contents c
    LEFT JOIN gpkg_geometry_columns gc ON gc.table_name = c.table_name
    WHERE c.data_type = 'features'
    ORDER BY c.table_name
    """
).fetchall()

total_features = 0
point_count = 0
line_count = 0
polygon_count = 0

lines.append("Export Layers")
if not tables:
    lines.append("- No feature layers found")
else:
    for table in tables:
        table_name = table["table_name"]
        geometry_type = (table["geometry_type"] or "UNKNOWN").upper()
        feature_count = safe_count(gpkg, f'SELECT COUNT(*) FROM "{table_name}"')
        total_features += feature_count
        if "POINT" in geometry_type:
            point_count += feature_count
        elif "LINE" in geometry_type:
            line_count += feature_count
        elif "POLYGON" in geometry_type:
            polygon_count += feature_count
        lines.append(f"- {table_name} ({geometry_type}): {feature_count}")

lines.append("")
lines.append("Geometry Totals")
lines.append(f"- Points: {point_count}")
lines.append(f"- Lines: {line_count}")
lines.append(f"- Polygons: {polygon_count}")
lines.append(f"- Total features: {total_features}")
lines.append("")
if total_features == 0:
    lines.append("Summary: Export contains 0 map features. Recorder may not have ingested new CoT data.")
else:
    lines.append(
        f"Summary: Export contains {total_features} features "
        f"({point_count} points, {line_count} lines, {polygon_count} polygons)."
    )

with open(summary_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

gpkg.close()
db.close()
print(summary_path)
PY
)

    if [[ -z "$summary_written" || ! -f "$summary_written" ]]; then
        return 1
    fi

    log_info "Summary: ${summary_written}"
    return 0
}
