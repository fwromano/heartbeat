# CoT Recording and GeoPackage Export Specification

> **Branch:** `master`
> **Purpose:** Record CoT events from TAK servers and export to GeoPackage for GIS workflows
> **Created:** 2026-02-06
> **Status:** IN PROGRESS

---

## Executive Summary

Heartbeat must capture CoT (Cursor-on-Target) events from the TAK server and export them to GeoPackage format. This enables GIS consumption of tactical data and demonstrates Heartbeat as more than a TAK installer -- TAK is the UI layer, GeoPackage is the data product.

Two export modes are required:
- **Raw dump**: all CoT events to a 4-layer GeoPackage (positions, markers, routes, areas)
- **GCM export**: Graphic Control Measures only (tactical geometry, no position tracks), using a YAML mapping with hardcoded defaults that can be overridden per-export

Recording is manual (user starts/stops) and captures everything so both export views work from the same recording.

---

## Architecture Overview

```
ATAK/iTAK clients
     |
     | CoT XML over TCP (:8087)
     v
+--------------+      +------------------+
|  TAK Server  |<-----| heartbeat start  |
|  (FTS/OTK)   |      +------------------+
+------+-------+
       |
       | CoT stream (recorder connects as a TAK client)
       v
+----------------+      ./heartbeat record start
|  recorder.py   |----  Python daemon, PID in data/recorder.pid
| (TCP client)   |      Sends SA event to identify, then passively listens
+------+---------+
       |
       | Parsed events (INSERT OR IGNORE for dedup)
       v
+----------------+
| cot_records.db |  SQLite with WAL (export can read while recording)
|   (data/)      |
+------+---------+
       |
   +---+---+
   v       v
 Raw      GCM          ./heartbeat export -o file.gpkg
 Export   Export       ./heartbeat export --gcm -o gcm.gpkg
   |       |
   v       v
 .gpkg   .gpkg          Opens in QGIS, ArcGIS, or ALIAS tools
```

**Why the recorder connects as a TAK client:** Instead of tapping the server's internal database (which differs per backend -- FTS uses SQLite, OpenTAK uses PostgreSQL, TAK Server uses PostgreSQL), the recorder connects to port 8087 like any ATAK would. It receives all CoT events the server broadcasts. This is backend-agnostic by design.

---

## Recorder SA (Self-Identification) Event

When the recorder connects to the TAK server's CoT TCP port, it must send a Situational Awareness event to register as a client. Without this, some TAK servers will drop the connection.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<event version="2.0"
       uid="heartbeat-recorder-{uuid4}"
       type="a-f-G-U-C"
       time="{ISO8601_NOW}"
       start="{ISO8601_NOW}"
       stale="{ISO8601_NOW + 5min}"
       how="m-g">
  <point lat="0.0" lon="0.0" hae="0" ce="9999999" le="9999999"/>
  <detail>
    <contact callsign="HB-RECORDER"/>
    <__group name="Cyan" role="HQ"/>
    <precisionlocation altsrc="DTED0"/>
    <takv version="heartbeat" platform="recorder" device="server" os="linux"/>
  </detail>
</event>
```

| Field | Value | Reason |
|-------|-------|--------|
| `uid` | `heartbeat-recorder-{uuid4}` | Unique per session, avoids collision |
| `type` | `a-f-G-U-C` | Friendly ground unit - identifies as a valid client |
| `lat/lon` | `0.0, 0.0` | Null Island - recorder has no physical position |
| `ce/le` | `9999999` | Maximum uncertainty (position meaningless) |
| `callsign` | `HB-RECORDER` | Visible in TAK clients connected to same server |
| `stale` | `now + 5min` | Recorder should re-send SA every ~4min to stay active |

The recorder must re-send this SA event periodically (every 4 minutes) to prevent the server from marking it as stale and dropping the connection.

---

## Files to Create

| File | Purpose |
|------|---------|
| `tools/recorder.py` | CoT TCP listener daemon that records all events |
| `tools/cot_parser.py` | XML stream splitter and CoT event parser |
| `tools/gpkg_writer.py` | GeoPackage writer using sqlite3 + shapely (no GDAL) |
| `tools/exporter.py` | Raw and GCM export logic, CLI entry point |
| `tools/gcm_mapper.py` | YAML-based GCM mapping and filtering |
| `tools/requirements.txt` | Python dependencies: `shapely`, `pyyaml` |
| `lib/record.sh` | Bash wrapper for `record start/stop/status` |
| `lib/export.sh` | Bash wrapper for `export` command |
| `config/gcm-mapping.yml` | Default GCM layer mapping and exclusions |

---

## Files to Modify

### 1. `heartbeat` (Main CLI Entry Point)

**A. Add to COMMANDS array (line 108):**

```bash
# BEFORE:
COMMANDS=(start stop restart status listen logs qr tailscale package packages serve clean info update systemd uninstall help)

# AFTER:
COMMANDS=(start stop restart status listen logs qr tailscale package packages serve clean info update systemd uninstall record export help)
```

**B. Add aliases in `resolve_cmd()` (after line 118):**

```bash
rec) echo "record"; return ;;
exp) echo "export"; return ;;
```

**C. Add help text (after line 51, new section before System):**

```bash
echo -e "${BOLD}Recording & Export:${NC}"
echo "  record start         Start recording CoT events from the server"
echo "  record stop          Stop the CoT recorder"
echo "  record status        Check recorder status and event count"
echo "  export [-o file]     Export recorded events to GeoPackage (.gpkg)"
echo "  export --gcm [-o f]  Export GCM (tactical geometry) only"
echo ""
```

**D. Add case blocks (before the `help)` case, ~line 245):**

```bash
record)
    source "${LIB_DIR}/record.sh"
    cmd_record "$@"
    ;;
export)
    source "${LIB_DIR}/export.sh"
    cmd_export "$@"
    ;;
```

**E. Add to clean command (after line 215):**

```bash
rm -f "${DATA_DIR}"/cot_records.db "${DATA_DIR}"/recorder.pid "${DATA_DIR}"/recorder.log 2>/dev/null
```

---

## SQLite Schema (`data/cot_records.db`)

All CoT events are stored in a single database. **Must use WAL mode** for concurrent reads during export.

```sql
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
```

### `recording_sessions`

Tracks recording session lifecycle. New row on each connect/reconnect.

```sql
CREATE TABLE IF NOT EXISTS recording_sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at   TEXT NOT NULL,
    stopped_at   TEXT,
    server_host  TEXT NOT NULL,
    server_port  INTEGER NOT NULL,
    events_count INTEGER NOT NULL DEFAULT 0
);
```

### `cot_events`

All CoT events, one row per event. Deduplicates via `UNIQUE(uid, time)`.

```sql
CREATE TABLE IF NOT EXISTS cot_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  INTEGER REFERENCES recording_sessions(id),
    uid         TEXT NOT NULL,             -- event/@uid
    event_type  TEXT NOT NULL,             -- event/@type (e.g. "a-f-G-U-C")
    callsign    TEXT,                      -- detail/contact/@callsign
    time        TEXT NOT NULL,             -- event/@time (ISO 8601)
    start       TEXT NOT NULL,             -- event/@start
    stale       TEXT NOT NULL,             -- event/@stale
    how         TEXT,                      -- event/@how
    lat         REAL,                      -- point/@lat
    lon         REAL,                      -- point/@lon
    hae         REAL,                      -- point/@hae (height above ellipsoid)
    ce          REAL,                      -- point/@ce (circular error)
    le          REAL,                      -- point/@le (linear error)
    detail_xml  TEXT,                      -- full <detail>...</detail> as string
    raw_xml     TEXT NOT NULL,             -- complete original XML event
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(uid, time)
);

CREATE INDEX IF NOT EXISTS idx_cot_type     ON cot_events(event_type);
CREATE INDEX IF NOT EXISTS idx_cot_time     ON cot_events(time);
CREATE INDEX IF NOT EXISTS idx_cot_uid      ON cot_events(uid);
CREATE INDEX IF NOT EXISTS idx_cot_callsign ON cot_events(callsign);
```

**Dedup strategy:** Use `INSERT OR IGNORE`. CoT servers may re-broadcast events. Same UID + same timestamp = same event, silently skip.

### `cot_geometry_points`

Ordered geometry vertices for routes and polygons. Points extracted from `<link point="lat,lon,hae">` elements.

```sql
CREATE TABLE IF NOT EXISTS cot_geometry_points (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id    INTEGER NOT NULL REFERENCES cot_events(id) ON DELETE CASCADE,
    point_order INTEGER NOT NULL,          -- vertex sequence (0, 1, 2, ...)
    lat         REAL NOT NULL,
    lon         REAL NOT NULL,
    hae         REAL,
    UNIQUE(event_id, point_order)
);

CREATE INDEX IF NOT EXISTS idx_geom_event ON cot_geometry_points(event_id);
```

---

## CoT XML Parsing Strategy

### Stream Framing (`CotStreamParser`)

CoT over TCP has **no framing protocol**. Events are concatenated XML documents on a raw TCP stream with no delimiter.

**Why NOT `iterparse`:** Python's `xml.etree.ElementTree.iterparse()` requires a well-formed XML stream. A network disconnect mid-element raises an uncatchable `ParseError` and the entire parser must be rebuilt. The buffer approach recovers gracefully.

```python
class CotStreamParser:
    """
    Buffer incoming TCP data and extract complete <event>...</event> documents.
    Discards noise/garbage between events. Keeps partial events in buffer.
    """
    def __init__(self):
        self.buffer = ""

    def feed(self, data: str) -> list[str]:
        """Feed raw TCP data, return list of complete event XML strings."""
        self.buffer += data
        events = []
        while True:
            start = self.buffer.find("<event")
            if start == -1:
                self.buffer = ""       # No event start, discard noise
                break
            end = self.buffer.find("</event>", start)
            if end == -1:
                self.buffer = self.buffer[start:]  # Keep partial event
                break
            end += len("</event>")
            events.append(self.buffer[start:end])
            self.buffer = self.buffer[end:]
        return events
```

### Event Parsing (`parse_cot_event`)

Parses a complete `<event>...</event>` XML string into a structured dict:

```python
def parse_cot_event(xml_str: str) -> dict | None:
    """Returns dict with keys: uid, type, how, time, start, stale,
    callsign, lat, lon, hae, ce, le, detail_xml, geometry_points.
    Returns None on parse failure."""
```

Key extraction points:
- `uid` ← `event/@uid`
- `type` ← `event/@type`
- `callsign` ← `detail/contact/@callsign`
- `lat, lon, hae, ce, le` ← `point/@lat`, `point/@lon`, etc.
- `detail_xml` ← serialized `<detail>` element (for later re-parsing in export)
- `geometry_points` ← extracted from `<link>` elements (see below)

### Multi-Point Geometry Extraction

CoT encodes route waypoints and polygon vertices as `<link>` elements inside `<detail>`:

**Route example (`b-m-r`):**
```xml
<event uid="route-123" type="b-m-r">
  <point lat="38.0" lon="-77.0" hae="0" ce="9999999" le="9999999"/>
  <detail>
    <link uid="wp-1" type="b-m-p-w" point="38.01,-77.01,0" relation="c"/>
    <link uid="wp-2" type="b-m-p-w" point="38.02,-77.02,0" relation="c"/>
    <link uid="wp-3" type="b-m-p-w" point="38.03,-77.03,0" relation="c"/>
    <contact callsign="Route Alpha"/>
  </detail>
</event>
```

**Polygon example (`u-d-f`):**
```xml
<event uid="shape-456" type="u-d-f">
  <point lat="38.0" lon="-77.0" hae="0" ce="9999999" le="9999999"/>
  <detail>
    <link point="38.01,-77.01,0" type="b-m-p-w" relation="c"/>
    <link point="38.02,-77.02,0" type="b-m-p-w" relation="c"/>
    <link point="38.03,-77.03,0" type="b-m-p-w" relation="c"/>
    <link point="38.01,-77.01,0" type="b-m-p-w" relation="c"/>
    <contact callsign="Search Area 1"/>
    <shape><polyline closed="true"/></shape>
  </detail>
</event>
```

**Parsing logic:**

```python
def extract_geometry_points(detail: ET.Element) -> list[tuple[float, float, float]]:
    """Extract ordered (lat, lon, hae) tuples from <link point="..."> elements."""
    points = []
    for link in detail.findall("link"):
        point_str = link.get("point", "")
        if not point_str:
            continue
        parts = point_str.split(",")
        if len(parts) >= 2:
            lat, lon = float(parts[0]), float(parts[1])
            hae = float(parts[2]) if len(parts) > 2 else 0.0
            points.append((lat, lon, hae))
    return points
```

**Important:** The `<link point="...">` attribute is `"lat,lon,hae"` (latitude first). But shapely/GeoPackage uses `(x=lon, y=lat)` order. The exporter must swap when building geometries.

**Important:** The main `<point>` element in a route/polygon event is the anchor point (first vertex or centroid), NOT the geometry. Use the `<link>` elements for the actual line/polygon.

**Important:** For polygons, if the first and last point differ, the ring must be closed by appending the first point at the end.

### Type Classification (`classify_event`)

```python
def classify_event(event_type: str) -> str:
    """Classify a CoT event type into a layer name by prefix matching."""
    if event_type.startswith("a-"):       return "positions"
    if event_type.startswith("b-m-p"):    return "markers"
    if event_type.startswith("b-m-r"):    return "routes"
    if event_type.startswith("u-d-r"):    return "routes"
    if event_type.startswith("u-d-f"):    return "areas"
    return "other"
```

### CoT Type Reference

| CoT Prefix | Meaning | Layer | Geometry |
|------------|---------|-------|----------|
| `a-f-G-*` | Friendly ground (SA positions) | positions | Point |
| `a-h-G-*` | Hostile ground | positions | Point |
| `a-n-G-*` | Neutral ground | positions | Point |
| `a-u-G-*` | Unknown ground | positions | Point |
| `b-m-p-w` | Waypoint marker | markers | Point |
| `b-m-p-s-p-i` | Point of interest / spot report | markers | Point |
| `b-m-p-c` | Contact point | markers | Point |
| `b-m-r` | Route | routes | LineString |
| `u-d-r` | User-drawn route | routes | LineString |
| `u-d-f` | User-drawn freeform shape | areas | Polygon |

---

## GeoPackage Schema (No GDAL)

GeoPackage is an OGC standard built on SQLite. We write it directly using Python's `sqlite3` module -- no GDAL, no fiona. Only `shapely` is needed for WKB geometry encoding.

### Initialization SQL

```sql
-- GeoPackage magic: identifies file as GPKG to any reader
PRAGMA application_id = 0x47504B47;   -- 'GPKG' in hex
PRAGMA user_version = 10300;           -- GeoPackage 1.3

-- Required table: Spatial Reference Systems
CREATE TABLE IF NOT EXISTS gpkg_spatial_ref_sys (
    srs_name                 TEXT NOT NULL,
    srs_id                   INTEGER NOT NULL PRIMARY KEY,
    organization             TEXT NOT NULL,
    organization_coordsys_id INTEGER NOT NULL,
    definition               TEXT NOT NULL,
    description              TEXT
);

-- Insert WGS 84 (EPSG:4326) -- the CRS used by all CoT data
INSERT OR IGNORE INTO gpkg_spatial_ref_sys VALUES (
    'WGS 84 geodetic',
    4326,
    'EPSG',
    4326,
    'GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],AUTHORITY["EPSG","4326"]]',
    'WGS 84'
);

-- Required by spec: undefined SRS entries
INSERT OR IGNORE INTO gpkg_spatial_ref_sys VALUES (
    'Undefined cartesian SRS', -1, 'NONE', -1,
    'undefined', 'undefined cartesian coordinate reference system'
);
INSERT OR IGNORE INTO gpkg_spatial_ref_sys VALUES (
    'Undefined geographic SRS', 0, 'NONE', 0,
    'undefined', 'undefined geographic coordinate reference system'
);

-- Required table: Contents (lists all feature tables)
CREATE TABLE IF NOT EXISTS gpkg_contents (
    table_name  TEXT NOT NULL PRIMARY KEY,
    data_type   TEXT NOT NULL DEFAULT 'features',
    identifier  TEXT UNIQUE,
    description TEXT DEFAULT '',
    last_change TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    min_x       REAL,
    min_y       REAL,
    max_x       REAL,
    max_y       REAL,
    srs_id      INTEGER REFERENCES gpkg_spatial_ref_sys(srs_id)
);

-- Required table: Geometry Columns (maps tables to geometry columns)
CREATE TABLE IF NOT EXISTS gpkg_geometry_columns (
    table_name         TEXT NOT NULL REFERENCES gpkg_contents(table_name),
    column_name        TEXT NOT NULL,
    geometry_type_name TEXT NOT NULL,
    srs_id             INTEGER NOT NULL REFERENCES gpkg_spatial_ref_sys(srs_id),
    z                  INTEGER NOT NULL DEFAULT 0,
    m                  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (table_name, column_name)
);
```

### Feature Table Creation

Each layer gets its own table. Example for `positions`:

```sql
CREATE TABLE IF NOT EXISTS positions (
    fid       INTEGER PRIMARY KEY AUTOINCREMENT,
    geom      BLOB,            -- GeoPackage binary (GP header + WKB)
    uid       TEXT,
    callsign  TEXT,
    cot_type  TEXT,
    time      TEXT,
    hae       REAL,
    ce        REAL,
    le        REAL
);

-- Register in gpkg_contents
INSERT INTO gpkg_contents (table_name, data_type, identifier, srs_id)
VALUES ('positions', 'features', 'positions', 4326);

-- Register geometry column
INSERT INTO gpkg_geometry_columns (table_name, column_name, geometry_type_name, srs_id, z, m)
VALUES ('positions', 'geom', 'POINT', 4326, 1, 0);
```

### Raw Export Layers

| Layer | Geometry Type | CoT Prefix | Attributes |
|-------|--------------|------------|------------|
| `positions` | POINT | `a-` | uid, callsign, cot_type, time, hae, ce, le |
| `markers` | POINT | `b-m-p` | uid, callsign, cot_type, time, remarks |
| `routes` | LINESTRING | `b-m-r`, `u-d-r` | uid, callsign, cot_type, time |
| `areas` | POLYGON | `u-d-f` | uid, callsign, cot_type, time, remarks |

### GeoPackage Binary Geometry Format

GeoPackage stores geometry as a binary blob: a GP header followed by standard WKB.

```
Byte layout:
  [0-1]   Magic: 0x47, 0x50  ('GP')
  [2]     Version: 0x00
  [3]     Flags: 0b_EEETBO00
            E = empty geometry flag
            T = envelope type (001 = [minx, maxx, miny, maxy])
            B = byte order (1 = little-endian)
            O = GeoPackageBinary type (0 = standard)
  [4-7]   SRS ID: int32 (little-endian) = 4326
  [8-39]  Envelope: 4x float64 (minx, maxx, miny, maxy) -- 32 bytes
  [40+]   WKB geometry (from shapely.wkb)
```

**Python implementation:**

```python
import struct
from shapely.geometry import Point, LineString, Polygon

def to_gpkg_geom(shapely_geom, srs_id=4326) -> bytes:
    """Convert a shapely geometry to GeoPackage standard binary format."""
    # Flags: little-endian (bit 0 = 1), envelope type xy (bits 1-3 = 001)
    flags = 0b00000011
    bounds = shapely_geom.bounds  # (minx, miny, maxx, maxy)

    header = b'GP'                                    # magic
    header += struct.pack('<B', 0)                     # version
    header += struct.pack('<B', flags)                 # flags
    header += struct.pack('<i', srs_id)                # SRS ID
    header += struct.pack('<dddd',                     # envelope
                          bounds[0], bounds[2],        # minx, maxx
                          bounds[1], bounds[3])        # miny, maxy

    return header + shapely_geom.wkb
```

After all features are inserted, update `gpkg_contents` with bounding box:

```sql
UPDATE gpkg_contents
SET min_x = ?, min_y = ?, max_x = ?, max_y = ?,
    last_change = strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE table_name = ?;
```

---

## Recorder Daemon (`tools/recorder.py`)

### Arguments

```
python3 tools/recorder.py --host HOST --port PORT --db DB_PATH --log LOG_PATH
```

| Arg | Default | Description |
|-----|---------|-------------|
| `--host` | `127.0.0.1` | TAK server host |
| `--port` | `8087` | CoT TCP port |
| `--db` | `data/cot_records.db` | SQLite database path |
| `--log` | `data/recorder.log` | Log file path |

### Main Loop (pseudocode)

```
initialize database (create tables if not exist)
running = True

while running:
    try:
        connect TCP socket to host:port (timeout 5s)
        switch socket to blocking mode
        send SA identification event
        create new recording_session row
        start SA keepalive timer (4 min interval)

        while running:
            data = socket.recv(65536)
            if empty: break  (server closed connection)

            events = stream_parser.feed(data.decode())
            for each event_xml:
                parsed = parse_cot_event(event_xml)
                INSERT OR IGNORE into cot_events
                if multi-point type:
                    INSERT geometry_points
                UPDATE recording_sessions events_count += 1
                commit

            if SA keepalive timer expired:
                re-send SA event
                reset timer

    except socket.error:
        if running: log warning, sleep 5s, retry
    except Exception:
        if running: log error, sleep 10s, retry
    finally:
        close socket
        set recording_session.stopped_at
```

### Signal Handling

```python
def handle_signal(signum, frame):
    recorder.running = False
    if recorder.sock:
        recorder.sock.shutdown(socket.SHUT_RDWR)

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)
```

`SIGTERM` (sent by `record_stop()`) sets `running = False` and shuts down the socket. `recv()` raises an error, inner loop breaks, outer loop exits because `running` is False. Graceful.

### Auto-Reconnect

When the TAK server restarts or the network drops:
1. `recv()` returns empty bytes or raises `ConnectionError`
2. Current `recording_session` is closed with `stopped_at`
3. Outer loop sleeps 5 seconds, then reconnects
4. New SA event sent, new `recording_session` created
5. Events already in SQLite are safe -- no data loss

---

## GCM Mapping YAML (`config/gcm-mapping.yml`)

YAML config defines which CoT types map to GCM layers. **Matching is prefix-based, not glob** -- `b-m-p` matches `b-m-p-w`, `b-m-p-s-p-i`, etc.

```yaml
# Heartbeat GCM (Graphic Control Measures) Export Mapping
#
# Defines how CoT event types are sorted into tactical GIS layers.
# Matching is PREFIX-BASED: "b-m-p" matches any type starting with "b-m-p".
#
# Override with: ./heartbeat export --gcm --mapping custom.yml -o out.gpkg

layers:
  control_points:
    description: "Named control points, markers, waypoints, POIs"
    geometry: Point
    cot_types:
      - "b-m-p"            # All point markers (waypoints, POIs, contacts, etc.)
    attributes:
      - uid
      - callsign
      - cot_type
      - time
      - remarks

  boundaries:
    description: "Area boundaries, search areas, hazard zones"
    geometry: Polygon
    cot_types:
      - "u-d-f"            # Freeform drawn shapes (polygons)
    attributes:
      - uid
      - callsign
      - cot_type
      - time
      - remarks

  routes:
    description: "Routes, axes of advance, patrol routes"
    geometry: LineString
    cot_types:
      - "b-m-r"            # Routes
      - "u-d-r"            # User-drawn routes/lines
    attributes:
      - uid
      - callsign
      - cot_type
      - time

settings:
  # CoT type prefixes to ALWAYS exclude from GCM export
  exclude_types:
    - "a-"                  # Position tracks (SA atoms) -- NOT tactical geometry
    - "t-"                  # Tasking

  # Keep only the latest event per UID (dedup moving/updated objects)
  deduplicate_by_uid: true
```

---

## Bash Wrapper: `lib/record.sh`

Follow existing patterns from `lib/common.sh` (logging, path constants) and `lib/backends/freetak.sh` (PID file daemon management).

### Constants

```bash
RECORDER_PID="${DATA_DIR}/recorder.pid"
RECORDER_LOG="${DATA_DIR}/recorder.log"
RECORDER_DB="${DATA_DIR}/cot_records.db"
RECORDER_SCRIPT="${HEARTBEAT_DIR}/tools/recorder.py"
```

### `cmd_record()`

```bash
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
```

### `record_start()`

1. Check if already running: `kill -0 $(cat $RECORDER_PID)`
2. Verify `python3` exists: `has_cmd python3`
3. Verify `shapely` installed: `python3 -c "import shapely"`
4. `ensure_dir "$DATA_DIR"`
5. Read `COT_PORT` from config (default 8087)
6. Launch daemon:
   ```bash
   nohup python3 "$RECORDER_SCRIPT" \
       --host 127.0.0.1 \
       --port "${COT_PORT:-8087}" \
       --db "$RECORDER_DB" \
       --log "$RECORDER_LOG" \
       >> "$RECORDER_LOG" 2>&1 &
   echo $! > "$RECORDER_PID"
   ```
7. Sleep 1s, verify PID still alive
8. Log success with PID, DB path, log path

### `record_stop()`

1. Read PID from `$RECORDER_PID`
2. Send `SIGTERM`: `kill "$pid"`
3. Wait up to 10 seconds for exit: `while kill -0 "$pid" && i < 10; do sleep 1; done`
4. If still alive after 10s: `kill -9 "$pid"`
5. Remove PID file

### `record_status()`

1. Check PID file and process alive → show "recording" or "stopped"
2. If DB exists, query event count:
   ```bash
   python3 -c "
   import sqlite3, sys
   conn = sqlite3.connect(sys.argv[1])
   try:
       c = conn.execute('SELECT COUNT(*) FROM cot_events').fetchone()[0]
       print(c)
   except:
       print(0)
   conn.close()
   " "$RECORDER_DB"
   ```
3. Show DB size via `du -h`

---

## Bash Wrapper: `lib/export.sh`

### `cmd_export()`

1. Parse args: `--output/-o`, `--gcm`, `--mapping`, `--help/-h`
2. If no `--output`, generate default name: `cot_export_YYYYMMDD_HHMMSS.gpkg` or `gcm_export_...`
3. Verify `$RECORDER_DB` exists
4. Verify `shapely` installed
5. If `--gcm`: also verify `pyyaml`, verify mapping file exists
6. Set `PYTHONPATH="${HEARTBEAT_DIR}/tools"` and invoke:
   ```bash
   # Raw export
   python3 "$EXPORTER_SCRIPT" --db "$RECORDER_DB" --output "$output"

   # GCM export
   python3 "$EXPORTER_SCRIPT" --db "$RECORDER_DB" --output "$output" \
       --gcm --mapping "$map_file"
   ```
7. Verify output file exists, show size, log success

---

## Python Module Structure

### `tools/cot_parser.py` (stdlib only)

| Component | Purpose |
|-----------|---------|
| `CotStreamParser` | Buffer TCP data → extract complete event XMLs |
| `parse_cot_event(xml_str)` | XML string → structured dict |
| `extract_geometry_points(detail)` | `<link point="...">` → `[(lat,lon,hae), ...]` |
| `classify_event(event_type)` | CoT type prefix → layer name string |
| `is_multi_point_type(event_type)` | Returns True for route/polygon types |

### `tools/gpkg_writer.py` (requires shapely)

| Component | Purpose |
|-----------|---------|
| `GeoPackageWriter(path)` | Create GPKG file with core tables |
| `.add_point_layer(name, columns)` | Create Point feature table + register |
| `.add_linestring_layer(name, columns)` | Create LineString feature table + register |
| `.add_polygon_layer(name, columns)` | Create Polygon feature table + register |
| `.insert_feature(layer, geom, attrs)` | Write geometry + attributes to layer |
| `.update_bounds()` | Compute and set bounding box per layer |
| `.close()` | Commit and close SQLite connection |
| `to_gpkg_geom(shapely_geom)` | Shapely geometry → GPKG binary blob |

### `tools/recorder.py` (stdlib only, imports cot_parser)

| Component | Purpose |
|-----------|---------|
| `CotRecorder(host, port, db, log)` | Main daemon class |
| `.init_db()` | Create schema if not exists |
| `.make_sa_event()` | Build self-identification XML |
| `.connect()` | TCP connect + send SA |
| `.record_event(conn, xml)` | Parse + INSERT OR IGNORE |
| `.run()` | Main loop with auto-reconnect |
| `.stop()` | Signal handler sets running=False |
| `main()` | argparse + signal setup + run |

### `tools/exporter.py` (requires shapely, imports gpkg_writer + cot_parser + gcm_mapper)

| Component | Purpose |
|-----------|---------|
| `export_raw(db, output)` | All events → 4-layer GPKG |
| `export_gcm(db, output, mapping)` | Filtered events → GCM GPKG |
| `main()` | argparse CLI: `--db`, `--output`, `--gcm`, `--mapping` |

### `tools/gcm_mapper.py` (requires pyyaml)

| Component | Purpose |
|-----------|---------|
| `GcmMapper(mapping_path)` | Load YAML, build prefix index |
| `.classify(event_type)` | CoT type → layer name or None (excluded) |
| `.extract_attributes(row, layer_config)` | DB row → attribute dict |
| `.build_geometry(row, layer_config)` | DB row → shapely geometry |

### `tools/requirements.txt`

```
shapely>=2.0
pyyaml>=6.0
```

---

## Dependencies

| Package | Required For | Install |
|---------|-------------|---------|
| `shapely` | Geometry objects + WKB serialization | `pip install shapely` |
| `pyyaml` | GCM mapping YAML parsing | `pip install pyyaml` |
| Python stdlib | Everything else: socket, sqlite3, xml.etree, struct, json, signal, argparse | (built-in) |

The bash wrappers check for dependencies before invoking Python and print clear error messages:

```bash
if ! python3 -c "import shapely" 2>/dev/null; then
    log_error "shapely is required: pip install shapely"
    exit 1
fi
```

---

## Verification Checklist

- [ ] `pip install shapely pyyaml` succeeds
- [ ] `./heartbeat start` launches TAK server
- [ ] `./heartbeat record start` starts recorder daemon, PID file created
- [ ] `./heartbeat record status` shows "recording" with event count
- [ ] Connect ATAK/iTAK → drop markers, draw a route, draw a polygon
- [ ] `./heartbeat record status` shows increasing event count
- [ ] `./heartbeat record stop` stops daemon cleanly
- [ ] `./heartbeat export -o test.gpkg` creates file
- [ ] `./heartbeat export --gcm -o gcm.gpkg` creates file
- [ ] Open `test.gpkg` in QGIS: see 4 layers (positions, markers, routes, areas)
- [ ] Open `gcm.gpkg` in QGIS: see 3 layers (control_points, boundaries, routes), NO position tracks
- [ ] Markers appear at correct lat/lon
- [ ] Routes render as connected lines (not individual points)
- [ ] Polygons render as closed shapes
- [ ] `./heartbeat clean` removes `cot_records.db`

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Server restarts during recording | Auto-reconnect after 5s, new session row, no data loss |
| Duplicate CoT events (re-broadcast) | `UNIQUE(uid, time)` + `INSERT OR IGNORE` silently skips |
| Partial XML in TCP buffer | `CotStreamParser` keeps fragment, waits for more data |
| Noise/garbage before first `<event>` | Discarded by parser (searches for `<event` start tag) |
| Polygon not closed (first != last point) | Exporter appends first point to close ring |
| Export while recording | SQLite WAL mode allows concurrent reads, consistent snapshot |
| Missing coordinates on event | Skip event (don't create geometry with null lat/lon) |
| Empty recording database | Export creates valid GPKG with empty layers |
| `</event>` in an XML attribute value | Extremely unlikely in CoT; acceptable risk for v1 |
| Recorder SA goes stale | Re-send SA event every 4 minutes to prevent server drop |

---

## Implementation Order

| Step | Files | Dependencies |
|------|-------|-------------|
| 1 | `tools/cot_parser.py` | None (stdlib only) |
| 2 | `tools/gpkg_writer.py` | shapely |
| 3 | `tools/recorder.py` | cot_parser |
| 4 | `lib/record.sh` | recorder.py |
| 5 | `tools/exporter.py` | gpkg_writer, cot_parser |
| 6 | `tools/gcm_mapper.py` | pyyaml |
| 7 | `config/gcm-mapping.yml` | None |
| 8 | `lib/export.sh` | exporter.py |
| 9 | `heartbeat` (modifications) | record.sh, export.sh |
| 10 | `tools/requirements.txt` | None |
| 11 | Verification | All of the above |
