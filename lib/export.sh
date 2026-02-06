#!/usr/bin/env bash
# Heartbeat - CoT Export
# Export recorded CoT events to GeoPackage format

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

EXPORTER_SCRIPT="${HEARTBEAT_DIR}/tools/exporter.py"
RECORDER_DB="${DATA_DIR}/cot_records.db"
DEFAULT_MAPPING="${CONFIG_DIR}/gcm-mapping.yml"

usage() {
    echo "Usage: ./heartbeat export [-o file.gpkg] [--gcm] [--mapping file.yml]"
    echo ""
    echo "Options:"
    echo "  -o, --output   Output GeoPackage file"
    echo "  --gcm          Export Graphic Control Measures only"
    echo "  --mapping      GCM mapping YAML file (default: config/gcm-mapping.yml)"
    echo "  -h, --help     Show this help"
}

cmd_export() {
    local output=""
    local gcm=false
    local mapping=""

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
        if [[ "$gcm" == "true" ]]; then
            output="gcm_export_${ts}.gpkg"
        else
            output="cot_export_${ts}.gpkg"
        fi
    fi

    if [[ ! -f "$RECORDER_DB" ]]; then
        log_error "Recording database not found: ${RECORDER_DB}"
        log_info "Run: ./heartbeat record start"
        return 1
    fi

    if ! has_cmd python3; then
        log_error "python3 is required but not found"
        return 1
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

    local cmd=(python3 "$EXPORTER_SCRIPT" --db "$RECORDER_DB" --output "$output")
    if [[ "$gcm" == "true" ]]; then
        cmd+=(--gcm --mapping "$mapping")
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
}
