# Heartbeat Architecture & Topology

> **Document:** System Architecture Reference
> **Updated:** 2026-02-17
> **Status:** Current (master branch)

---

## 1. Ecosystem Topology

How Heartbeat ties together the field deployment stack — TAK servers, phones, VPN, recording, and GIS analysis.

```
                        ┌─────────────────────┐
                        │     FIELD LAPTOP     │
                        │   (Heartbeat host)   │
                        └──────────┬──────────┘
                                   │
         ┌─────────────────────────┼─────────────────────────┐
         │                         │                         │
         ▼                         ▼                         ▼
  ┌──────────────┐    ┌────────────────────┐    ┌────────────────────┐
  │  TAK Server  │    │   CoT Recorder     │    │  Package Server    │
  │              │    │   (SSL or TCP)     │    │  (HTTP :9000)      │
  │  FreeTAK     │    │                    │    │                    │
  │    or        │◄───┤  FTS: TCP :8087    │    │  Serves .zip       │
  │  OpenTAK     │    │  OTS: SSL :8089    │    │  connection pkgs   │
  │              │    │  (mTLS w/ certs)   │    │  to phones         │
  │  :8087 TCP   │    └────────┬───────────┘    └─────────┬──────────┘
  │  :8089 SSL   │             │                          │
  │  :8443 Web   │             ▼                          │
  └──────┬───────┘    ┌────────────────────┐              │
         │            │  SQLite DB         │              │
         │            │  (cot_records.db)  │              │
         │            └────────┬───────────┘              │
         │                     │                          │
         │                     ▼                          │
         │            ┌────────────────────┐              │
         │            │  GeoPackage Export  │              │
         │            │  (.gpkg files)     │              │
         │            └────────┬───────────┘              │
         │                     │                          │
         │                     ▼                          │
         │            ┌────────────────────┐              │
         │            │  GIS / Analysis    │              │
         │            │                    │              │
         │            │  QGIS / ArcGIS    │              │
         │            │  Python/GeoPandas  │              │
         │            │  ALIAS pipeline    │              │
         │            └────────────────────┘              │
         │                                                │
    ─────┼────────────── Tailscale VPN ───────────────────┼─────
         │              (100.x.x.x mesh)                  │
         │                                                │
    ┌────┴─────────────────────────────────────────────────┴────┐
    │                                                           │
    ▼              ▼              ▼              ▼               ▼
┌────────┐   ┌────────┐   ┌────────┐   ┌────────┐       ┌────────┐
│  iTAK  │   │  ATAK  │   │  ATAK  │   │ WinTAK │       │ WebTAK │
│ iPhone │   │ Android│   │ Android│   │ laptop │       │browser │
│        │   │        │   │        │   │        │       │ :8443  │
│ Chief  │   │ Squad1 │   │ Squad2 │   │  TOC   │       │  Map   │
└────────┘   └────────┘   └────────┘   └────────┘       └────────┘
    positions    positions    routes      polygons
    markers      markers      drawings    boundaries
```

### What Heartbeat ties together

| Layer | What | How |
|-------|------|-----|
| **Network** | Tailscale VPN | Auto-detects TS IP, sets SERVER_IP, all devices on same mesh |
| **TAK Server** | FTS or OTS | Backend abstraction — same CLI, different engine underneath |
| **Phones** | ATAK/iTAK | Connection packages (.zip) served over HTTP, phones import and connect |
| **WebTAK** | Browser map | OpenTAK only — nginx serves UI on :8443 with live CoT overlay |
| **Recording** | CoT capture | FreeTAK: TCP client on :8087. OpenTAK: SSL mTLS client on 127.0.0.1:8089 (with cert/key for full annotation ingest) |
| **External Feed** | Wildfire incidents | `fire_feed.py` polls ArcGIS incidents and injects CoT points (`a-h-G`) into TAK |
| **GIS Export** | GeoPackage | Standard OGC format — opens in QGIS, ArcGIS, or any spatial tool |
| **ALIAS** | Downstream | GPKG feeds into the broader DARPA autonomous firefighting pipeline |

### End-to-end data flow

```
Firefighter moves       TAK server          Heartbeat           QGIS / ALIAS
with phone in pocket ─► broadcasts to  ──► records all    ──► spatial analysis
                        all devices        CoT events         after-action review
                                                              autonomous planning

ArcGIS wildfire feed ──► fire_feed.py ──► injects incidents ─► visible in ATAK/iTAK/WebTAK
```

---

## 2. Backend Abstraction Layer

Heartbeat decouples the CLI from any specific TAK server through a pluggable backend architecture.

```
┌─────────────────────────────────────────────────────────────┐
│                     HEARTBEAT CLI                            │
│         (Unified interface for all TAK servers)              │
├─────────────────────────────────────────────────────────────┤
│                   ABSTRACTION LAYER                          │
│        (Common API for lifecycle, users, packages)           │
│                                                              │
│   lib/backends/interface.sh defines the contract:            │
│     backend_start/stop/reset/status/logs/update/uninstall    │
│     backend_get_ports/get_package/health_check/supports      │
├───────────────┬───────────────────┬──────────────────────────┤
│   FreeTAK     │     OpenTAK       │      TAK Server          │
│   Backend     │     Backend       │      Backend             │
│  (Lite tier)  │  (Standard tier)  │   (Enterprise tier)      │
│               │                   │                          │
│  TCP only     │  SSL + WebTAK     │   Full mil-spec          │
│  No auth      │  User mgmt        │   Federation             │
│  Docker/venv  │  Native systemd   │   tak.gov (future)       │
└───────────────┴───────────────────┴──────────────────────────┘
```

### Capability Matrix

| Capability | FreeTAK (Lite) | OpenTAK (Standard) | TAK Server (Enterprise) |
|------------|:--------------:|:------------------:|:-----------------------:|
| SSL/TLS | - | yes | yes |
| User management | - | yes | yes |
| Built-in WebTAK | - | yes | yes |
| Federation | - | limited | yes |
| Docker support | yes | - | yes |
| Native install | yes (venv) | yes (systemd) | yes (RPM/DEB) |

---

## 3. Internal Component Map

How the Heartbeat codebase is wired together.

```
heartbeat (CLI entry point)
  │
  │  Server lifecycle
  │  ──────────────────────────────────────────────
  ├─ start ────► server.sh ──► _load_backend()
  │                  │              ├── freetak.sh ──► Docker / venv
  │                  │              └── opentak.sh ──► systemd services
  │                  │         backend_health_check()
  │                  ├──► record.sh ──► recorder.py (auto-start daemon)
  │                  └──► fire.sh ────► fire_feed.py (auto-start if enabled)
  │
  ├─ stop ─────► record.sh ──► kill recorder
  │              fire.sh ────► kill fire feed
  │              export.sh ──► auto-export → .gpkg (if DB exists)
  │              server.sh ──► backend_stop()
  │
  ├─ restart ──► record.sh ──► kill recorder
  │              fire.sh ────► kill fire feed
  │              server.sh ──► server_restart() or server_reset()
  │              record.sh ──► recorder.py (restart)
  │              fire.sh ────► fire_feed.py (restart if enabled)
  │              (OpenTAK uses reset to clear stale broker channels)
  │
  ├─ reset ────► record.sh ──► kill recorder
  │              fire.sh ────► kill fire feed
  │              server.sh ──► backend_reset() (restart deps + server)
  │              record.sh ──► recorder.py (restart)
  │              fire.sh ────► fire_feed.py (restart if enabled)
  │
  ├─ status ───► server.sh ──► backend_status() + port checks
  │              record.sh ──► recorder status + event count
  │              fire.sh ────► fire feed status
  │
  ├─ listen ───► server.sh ──► server_listen() (live CoT log stream)
  ├─ logs ─────► server.sh ──► backend_logs() (-f to follow)
  │
  │  Team / onboarding
  │  ──────────────────────────────────────────────
  ├─ qr ───────► qr.sh ──────► qrencode (terminal + PNG)
  ├─ tailscale ► common.sh ──► detect_tailscale_ip() → set SERVER_IP
  ├─ package ──► package.sh ──► generate .zip (certs or TCP template)
  ├─ packages ─► package.sh ──► list_packages()
  ├─ serve ────► package.sh ──► python http.server on :9000
  │
  │  Recording & export
  │  ──────────────────────────────────────────────
  ├─ record ───► record.sh ──► recorder.py
  │                                │
  │                                ├─ tak_client.py (shared socket + SA keepalive)
  │                                │
  │                                ├─ cot_parser.py (XML framing)
  │                                └─ SQLite DB (cot_records.db)
  │
  ├─ fire ─────► fire.sh ─────► fire_feed.py
  │                                │
  │                                ├─ ArcGIS REST poll (USA_Wildfires_v1)
  │                                └─ tak_client.py ──► TAK CoT inject
  │
  ├─ export ───► export.sh ──► exporter.py
  │                                ├─ raw mode: 4 layers (positions/markers/routes/areas)
  │                                └─ gcm mode: gcm_mapper.py + gcm-mapping.yml
  │                                      └─► gpkg_writer.py ──► .gpkg
  │
  │  System administration
  │  ──────────────────────────────────────────────
  ├─ info ─────► cmd_info() ──► display connection details
  ├─ update ───► server.sh ──► backend_update()
  ├─ systemd ──► install.sh ─► install_systemd_service()
  ├─ clean ────► remove packages, logs, PIDs, certs, Docker volumes
  ├─ uninstall ► server.sh ──► backend_uninstall()
  ├─ help ─────► show_help()
  │
  └─ setup.sh (one-time install)
       ├─ detect IP / Tailscale
       ├─ find free ports
       ├─ write config/heartbeat.conf
       ├─ install system deps (apt/dnf/pacman)
       └─ backend-specific:
            ├─ freetak + docker: build container image
            ├─ freetak + native: venv + pip install FreeTAKServer
            └─ opentak + native: postgres + rabbitmq + nginx + systemd
```

---

## 4. Data Pipeline Detail

### Recording

```
TAK Server
       │
       │  FreeTAK: TCP :8087 (raw CoT XML, no framing delimiter)
       │  OpenTAK: SSL :8089 via 127.0.0.1 (mTLS with cert/key from ca/certs/<user>/)
       │           SSL mode required for full annotation ingest (routes, polygons, markers)
       ▼
recorder.py (tools/recorder.py)
       │
       │  CotStreamParser.feed(data)
       │  ├─ buffers partial TCP reads
       │  └─ yields complete <event>...</event> XML docs
       │
       │  parse_cot_event(xml)
       │  ├─ uid, type, callsign, lat, lon, hae
       │  ├─ detail XML (raw)
       │  └─ geometry points from <link point="lat,lon,hae">
       │
       │  SA keepalive every 240s
       │  (re-sends self-identification or server drops connection)
       │
       ▼
data/cot_records.db (SQLite, WAL mode)
       │
       ├── recording_sessions
       │     session_id, start_time, end_time, event_count
       │
       ├── cot_events
       │     uid, type, how, time, start, stale
       │     lat, lon, hae, ce, le
       │     callsign, detail_xml, session_id
       │     UNIQUE(uid, time) + INSERT OR IGNORE
       │
       └── cot_geometry_points
             event_id, seq, lat, lon, hae
             (for routes and polygons — multi-point types)
```

### Export

```
data/cot_records.db
       │
       ▼
exporter.py (tools/exporter.py)
       │
       ├── Raw mode (default)
       │     Query all events, classify by CoT type prefix:
       │       a-f-*, a-n-*     → positions (Point)
       │       b-m-p-*          → markers   (Point)
       │       b-m-r-*, u-d-r-* → routes    (LineString)
       │       u-d-f-*          → areas     (Polygon)
       │
       │     Coordinate swap: CoT=(lat,lon) → Shapely=(lon,lat)
       │     Polygon ring closure: append first point if not closed
       │
       └── GCM mode (--gcm flag)
             gcm_mapper.py loads config/gcm-mapping.yml
               ├─ exclude_types: a-* (positions), t-* (tasking)
               ├─ deduplicate_by_uid: true (keep latest)
               └─ prefix-match → layer name → geometry type
       │
       ▼
gpkg_writer.py (tools/gpkg_writer.py)
       │
       │  Creates OGC-compliant GeoPackage (no GDAL):
       │    GP binary header (40 bytes) + WKB geometry
       │    gpkg_spatial_ref_sys  (EPSG:4326 WGS84)
       │    gpkg_contents         (layer registry)
       │    gpkg_geometry_columns (schema registry)
       │
       ▼
output.gpkg
       ├── positions  (Point)       — where people were
       ├── markers    (Point)       — POIs, waypoints
       ├── routes     (LineString)  — planned/traveled routes
       └── areas      (Polygon)    — boundaries, fire perimeters
```

---

## 5. OpenTAK Native Stack

When `TAK_BACKEND=opentak`, the server runs as native host services (no Docker).

```
                      ┌──────────────────────────┐
                      │       Nginx              │
                      │   reverse proxy          │
                      │                          │
                      │  :8080 HTTP  ──► :8081   │
                      │  :8443 HTTPS ──► :8081   │
                      │  :8883 MQTTS ──► :1883   │
                      └──────────┬───────────────┘
                                 │
                    ┌────────────┼────────────────┐
                    │            │                │
                    ▼            ▼                ▼
  ┌──────────────────┐ ┌─────────────┐ ┌──────────────────┐
  │  opentakserver   │ │  RabbitMQ   │ │   PostgreSQL     │
  │  (Flask :8081)   │ │  (:5672)    │ │   (:5432)        │
  │                  │ │             │ │                   │
  │  WebTAK UI       │ │  MQTT       │ │   DB: ots        │
  │  Marti API       │ │  message    │ │   User: ots      │
  │  cert enrollment │ │  broker     │ │                   │
  └──────────────────┘ └─────────────┘ └───────────────────┘

  ┌──────────────────┐ ┌──────────────────┐
  │  eud_handler     │ │ eud_handler_ssl  │
  │  (:8088 TCP)     │ │ (:8089 SSL)      │
  │                  │ │                  │
  │  phones connect  │ │  phones connect  │
  │  here (CoT)      │ │  here (CoT+TLS) │
  └──────────────────┘ └──────────────────┘

  ┌──────────────────┐
  │  cot_parser      │
  │                  │
  │  parses CoT from │
  │  RabbitMQ queue   │
  └──────────────────┘

  Systemd service management:

    OTS application services (managed as a unit):
      sudo systemctl start opentakserver   ← starts all 4 OTS services
      sudo systemctl stop opentakserver    ← stops all 4 OTS services
      Services: opentakserver, cot_parser, eud_handler, eud_handler_ssl

    System infrastructure (independent, managed separately):
      sudo systemctl restart rabbitmq-server
      sudo systemctl restart postgresql
      sudo systemctl restart nginx

    Note: `./heartbeat reset` restarts infrastructure services first,
    then brings OTS services back up. `./heartbeat start` only starts
    the 4 OTS services — it assumes postgres/rabbitmq/nginx are already
    running (started at boot or by setup.sh).

  All data contained under:
    data/opentak/
      ├── venv/        Python virtualenv
      ├── config.yml   OTS configuration
      ├── ca/          Certificate authority
      ├── logs/        Service logs
      └── db_password  PostgreSQL credentials
```

---

## 6. Port Allocation

### FreeTAK (Lite)

| Port | Protocol | Binding | Purpose |
|------|----------|---------|---------|
| 8087 | TCP | SERVER_IP | CoT data (unencrypted) |
| 8089 | TCP | SERVER_IP | CoT data (SSL — unused in Lite) |
| 19023 | HTTP | 127.0.0.1 | REST API (local only) |
| 8443 | HTTPS | SERVER_IP | DataPackage server |
| 9000 | HTTP | SERVER_IP | Package download server |

### OpenTAK (Standard)

| Port | Protocol | Binding | Service |
|------|----------|---------|---------|
| 8088 | TCP | 0.0.0.0 | eud_handler (CoT TCP) |
| 8089 | TCP | 0.0.0.0 | eud_handler_ssl (CoT SSL) |
| 8080 | HTTP | 0.0.0.0 | Nginx — WebTAK UI (HTTP) |
| 8443 | HTTPS | 0.0.0.0 | Nginx — WebTAK UI + Marti API |
| 8081 | HTTP | 127.0.0.1 | Flask app (internal only) |
| 5432 | TCP | 127.0.0.1 | PostgreSQL (internal only) |
| 5672 | TCP | 127.0.0.1 | RabbitMQ (internal only) |
| 8883 | TCP | 0.0.0.0 | Nginx stream — MQTTS proxy |
| 9000 | HTTP | SERVER_IP | Package download server |

---

## 7. Auto-Lifecycle Sequence

```
./heartbeat start                    ./heartbeat stop
  │                                    │
  ├─ backend_start()                   ├─ record_stop()
  │    TAK server comes up             │    SIGTERM → recorder daemon
  │                                    │
  ├─ backend_health_check()            ├─ cmd_export()  (auto)
  │    verify services + ports         │    export → data/exports/*.gpkg
  │                                    │    (only if cot_records.db exists)
  └─ record_start()                    │
       recorder.py spawned as daemon   └─ backend_stop()
       FTS: connects TCP :8087              TAK server goes down
       OTS: connects SSL :8089 (mTLS)
       begins recording

./heartbeat restart                  ./heartbeat reset
  │                                    │
  ├─ record_stop()                     ├─ record_stop()
  │    SIGTERM → recorder daemon       │    SIGTERM → recorder daemon
  │                                    │
  ├─ if OpenTAK:                       ├─ backend_reset()
  │    server_reset()                  │    OpenTAK: stop all →
  │    (same as reset — clears         │      restart rabbitmq/postgres/nginx →
  │     stale broker channels)         │      start all
  │  else:                             │    FreeTAK: stop → sleep → start
  │    server_restart()                │
  │    (stop → sleep 2s → start)       ├─ backend_health_check()
  │                                    │
  ├─ backend_health_check()            └─ record_start()
  │                                         recorder restarts
  └─ record_start()
       recorder restarts
```

---

## 8. v2 Diagram Legend

`architecture-v2.drawio` uses explicit state/data labels so implementation and operations map to the same model:

- `S0..S8` (FSA states): `Unconfigured -> Configured -> Installed -> Starting -> Running (healthy/degraded) -> Stopping -> Stopped`, with `Error` as failure sink/recovery target.
- `D1` Control: `setup/start/stop/reset/update` through Heartbeat CLI + backend adapter.
- `D2` Package onboarding: `./heartbeat package` + `./heartbeat serve` to deliver per-device zip.
- `D3` Identity/auth: OpenTAK SSL/mTLS cert/user identity.
- `D4` CoT routing: positions + markers + lines/polygons/circles between clients.
- `D5` Web map: `/api/map_state` + socket updates to WebTAK.
- `D6` Recorder ingest: SSL recorder client subscribed to OpenTAK stream.
- `D7` Persistence: SQLite session/event storage in `data/cot_records.db`.
- `D8` Export: `exporter.py` writes GeoPackage outputs.
- `D9` Downstream analytics: QGIS/ArcGIS/ALIAS consume `.gpkg`.

OpenTAK patch visibility in v2 diagram is source-level (fork install), not runtime monkey-patching:
- `fwromano/OpenTAKServer@heartbeat-fixes`
- exchange declaration + channel-recovery ordering fixes
- map-state `last_point` payload fix for WebTAK marker placement

`architecture-v2.drawio` now has two pages:
- `Page-1` (`architecture-v2-current`): deployment/runtime architecture
- `Ontology-v2` (`ontology-v2`): clean ontology map (classed lanes + typed edge vocabulary)

## 9. File Structure

```
heartbeat/
├── heartbeat              CLI entry point (bash)
├── setup.sh               One-time installer
├── config/
│   ├── heartbeat.conf     Runtime config (generated by setup.sh)
│   └── gcm-mapping.yml    GCM export classification rules
├── lib/
│   ├── common.sh          Logging, config, IP detection, utilities
│   ├── server.sh          Server lifecycle (delegates to backends)
│   ├── record.sh          Recorder daemon management
│   ├── export.sh          GeoPackage export wrapper
│   ├── package.sh         Connection package generation + HTTP serving
│   ├── qr.sh              QR code generation
│   ├── install.sh         System deps + backend-specific installers
│   └── backends/
│       ├── interface.sh   Backend contract (abstract interface)
│       ├── freetak.sh     FreeTAK implementation (Docker or venv)
│       └── opentak.sh     OpenTAK implementation (native systemd)
├── tools/
│   ├── recorder.py        CoT client daemon (TCP or SSL mTLS)
│   ├── cot_parser.py      CoT XML stream parser
│   ├── exporter.py        SQLite → GeoPackage converter
│   ├── gpkg_writer.py     OGC GeoPackage writer (no GDAL)
│   ├── gcm_mapper.py      YAML-based GCM classification
│   └── requirements.txt   Python deps (shapely, pyyaml)
├── docker/
│   ├── docker-compose.yml FreeTAK Docker config
│   ├── Dockerfile         FreeTAK container image
│   └── opentak/           OpenTAK Docker config (dev only)
├── data/                  Runtime artifacts (gitignored)
│   ├── cot_records.db     Recorded CoT events
│   ├── recorder.pid       Recorder daemon PID
│   ├── recorder.log       Recorder daemon log
│   ├── exports/           Auto-exported GeoPackages (.gpkg)
│   └── opentak/           Contained OTS install (venv, config, certs)
├── packages/              Generated connection packages (.zip)
└── docs/
    ├── architecture/      Diagrams (this file, drawio files)
    ├── specs/             Active specifications
    ├── planning/          Future roadmaps and design docs
    ├── guides/            User-facing field deployment docs
    ├── notes/             Working notes and task tracking
    └── archive/           Completed specs and historical documents
```

---

## Related Diagrams

- [Architecture v2 (current)](architecture-v2.drawio) — current draw.io source (FreeTAK default, OpenTAK supported + recorder/export flow)
- [Backend Abstraction (v1.5)](architecture-v1.5-abstraction.drawio.png) — abstraction layer snapshot
- [Architecture v1 (legacy)](architecture-v1.drawio.svg) — earlier architecture before abstraction
