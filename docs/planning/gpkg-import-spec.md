# GPKG Import Pipeline - High Level Plan

> **Status:** DESIGNED — NOT YET IMPLEMENTED
> **Created:** 2026-02-05
> **Updated:** 2026-02-10
>
> Zero implementation code exists. No `tools/importer.py`, no `lib/import.sh`, no `import` CLI command.
> This spec is retained as a design reference for post-demo development.

## Context

Heartbeat currently has a one-way pipeline: TAK devices send CoT events, the recorder captures them, and the exporter writes them to OGC GeoPackage files for GIS analysis. This plan designs the **reverse flow**: read features from a GPKG file, generate CoT XML events, and inject them into a running TAK server so they appear on connected devices.

Use case: a GIS analyst prepares search areas, routes, or waypoints in QGIS, exports a GPKG, and a field coordinator imports it into the TAK network so every phone sees the plan immediately.

## Architecture

```
QGIS / ArcGIS / any GIS tool
        |
        v
   file.gpkg
        |
        v
  tools/importer.py        <-- NEW: reads GPKG, generates CoT XML per feature
        |
        v
  TCP/SSL socket to TAK server (same as recorder)
        |
        v
  OTS / FTS relays CoT to all connected devices
```

## GPKG Read Side

Read features from any GPKG, not just Heartbeat-exported ones. Detect geometry type per layer:

| Geometry | CoT type | CoT structure |
|----------|----------|---------------|
| Point | `b-m-p-w` (waypoint) | `<point lat="" lon="" hae=""/>` |
| LineString | `u-d-r` (user-drawn route) | `<point>` anchor + `<link point="lat,lon,hae"/>` per vertex |
| Polygon | `u-d-f` (user-drawn freeform) | `<point>` anchor + `<link point="lat,lon,hae"/>` per vertex + `<polyline closed="true"/>` |

Critical coordinate swap: GPKG stores (lon, lat), CoT `<link point="">` expects "lat,lon,hae".

## CoT Generation

For each feature, build an `<event>` XML string:

```xml
<event version="2.0"
       uid="{generated or from attribute}"
       type="{mapped from geometry + attributes}"
       time="{now}" start="{now}" stale="{now + stale_minutes}"
       how="h-g-i-g-o">
  <point lat="..." lon="..." hae="..." ce="9999999" le="9999999"/>
  <detail>
    <contact callsign="{from attribute or filename}"/>
    <remarks>{from attribute if present}</remarks>
    <strokeColor value="{from attribute if present}"/>
    <fillColor value="{from attribute if present}"/>
    <link point="lat,lon,hae" type="b-m-p-w" relation="c"/>
    ...
  </detail>
</event>
```

### Attribute mapping (flexible, best-effort)

The importer should look for common column names and use them if present:

| GPKG column (case-insensitive) | Maps to |
|-------------------------------|---------|
| `uid` | event/@uid |
| `callsign`, `name`, `label` | contact/@callsign |
| `cot_type`, `type` | event/@type (override auto-detect) |
| `remarks`, `description`, `notes` | detail/remarks |
| `stroke_color`, `color` | detail/strokeColor |
| `fill_color` | detail/fillColor |
| `time`, `event_time`, `datetime` | event/@time |
| `raw_xml` | skip generation, send as-is (round-trip) |

If `raw_xml` column exists (Heartbeat-exported GPKG), just re-send the original CoT verbatim. This is the cleanest round-trip path.

### UID generation

- If GPKG has `uid` column, use it (preserves identity for updates)
- Otherwise generate: `hb-import-{sha256(layer+fid)[:12]}` (deterministic, re-importable)

### Stale time

Default 30 minutes. Configurable via `--stale-minutes`. Shapes/annotations typically use longer stale (hours/days). Positions use shorter.

## Injection Side

Reuse the same TCP/SSL socket approach as recorder.py:

1. Connect to TAK server (TCP or SSL with cert)
2. Send SA event to register as a client (callsign: `HB-IMPORT-{hash}`)
3. For each feature: send generated CoT XML via `sock.sendall(xml.encode("utf-8"))`
4. Optional: pace sends with small delay to avoid flooding (--delay-ms, default 50ms)
5. Disconnect when done (no keepalive needed for one-shot import)

## CLI Interface

```bash
# Basic import
./heartbeat import file.gpkg

# With options
./heartbeat import fire_plan.gpkg --stale-minutes 120 --delay-ms 100

# Import specific layers only
./heartbeat import file.gpkg --layers "search_areas,routes"

# Dry run - print CoT XML without sending
./heartbeat import file.gpkg --dry-run

# Import to specific server (override config)
./heartbeat import file.gpkg --host 10.0.0.1 --port 8089 --ssl
```

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `tools/importer.py` | CREATE | Core logic: read GPKG, generate CoT, send to server |
| `lib/import.sh` | CREATE | Bash wrapper with config loading, SSL cert discovery |
| `heartbeat` | MODIFY | Add `import` command to CLI dispatch |

## Reusable Components

- `tools/recorder.py` -- TCP/SSL connection setup, SA event format (reuse pattern, not import directly)
- `tools/cot_parser.py` -- `classify_event()` for type mapping reference
- `tools/exporter.py` -- `extract_style_fields()`, `extract_remarks()` show what attributes to look for
- `lib/record.sh` -- `_opentak_pick_recorder_cert_user()` for SSL cert discovery pattern
- `tools/gpkg_writer.py` -- `to_gpkg_geom()` shows the binary format (we need the inverse: read it)

For reading GPKG geometry, use shapely + sqlite3 (same deps as export). Parse the GP binary header, extract WKB, load with `shapely.wkb.loads()`.

## Edge Cases

- **Empty geometry**: skip feature, log warning
- **3D coordinates**: preserve HAE if present, default 0
- **Multi-geometries** (MultiPoint, MultiLineString, MultiPolygon): explode into separate CoT events
- **Coordinate validation**: reject lat outside [-90,90], lon outside [-180,180]
- **Large files**: stream features, don't load entire GPKG into memory
- **Non-WGS84 GPKG**: check SRS, warn if not EPSG:4326 (TAK assumes WGS84)

## Verification

1. Export a GPKG with known features using `./heartbeat export`
2. Import it back with `./heartbeat import --dry-run` and verify CoT XML looks correct
3. Import into running server, verify features appear on connected iTAK/ATAK device
4. Test with a QGIS-created GPKG (not Heartbeat-exported) to verify generic import works
5. Test round-trip: export -> import -> verify devices see the original annotations

## Future Extensions (not in v1)

- **Watch mode**: `./heartbeat import --watch file.gpkg` -- re-import on file change (live sync from QGIS)
- **Shapefile/GeoJSON input**: convert to GPKG internally, or support directly
- **Batch import from directory**: `./heartbeat import data/plans/*.gpkg`
- **Mission sync**: use OTS Marti API to create a mission and attach imported features
- **Two-way sync**: combine recorder + importer for bidirectional GPKG <-> TAK
