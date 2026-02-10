# Heartbeat Platform Vision

> **Document:** Strategic Vision & Platform Architecture
> **Project:** ALIAS / Heartbeat
> **Created:** 2026-02-05
> **Status:** Vision Draft
> **Target Demo:** March 25-26, 2026 (ready by ~March 11)

**Priority:** Real-world firefighter deployment is FIRST CLASS. Simulation/training supports this but is secondary.

---

## What Heartbeat Is

**Heartbeat is the heart that keeps the TAK server beating.** It's not the whole system - it's the reliable core that manages the TAK server lifecycle. Everything else in the ALIAS ecosystem sits on top of or alongside Heartbeat.

```
┌─────────────────────────────────────────────────────┐
│                  ALIAS ECOSYSTEM                    │
├─────────────────────────────────────────────────────┤
│                                                     │
│   Simulation ─────► Heartbeat ─────► Export        │
│   (data in)         (TAK core)       (data out)    │
│                         │                           │
│                         ▼                           │
│                  ┌─────────────┐                   │
│                  │ TAK Server  │                   │
│                  └──────┬──────┘                   │
│                         │                           │
│         ┌───────────────┼───────────────┐          │
│         ▼               ▼               ▼          │
│      iTAK            ATAK           WebTAK         │
│     (iOS)          (Android)       (Browser)       │
│                                                     │
│         TAK = The Human UI Layer                   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## Executive Summary

Heartbeat evolves from a single-server TAK deployment tool into a **robust TAK server management core** with:

1. **Tiered TAK Server Support** - Choose the right server for your mission
2. **Federation** - Connect multiple Heartbeat instances across organizations
3. **Data Export** - Extract geospatial data (points, lines, polygons) to GeoPackage for GIS analysis

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         HEARTBEAT PLATFORM                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌─────────────┐      FEDERATION       ┌─────────────┐                │
│   │ Heartbeat A │◄────────────────────►│ Heartbeat B │                │
│   │  (Team 1)   │                       │  (Team 2)   │                │
│   └──────┬──────┘                       └──────┬──────┘                │
│          │                                     │                        │
│          ▼                                     ▼                        │
│   ┌─────────────┐                       ┌─────────────┐                │
│   │ TAK Server  │                       │ TAK Server  │                │
│   │  Backend    │                       │  Backend    │                │
│   └──────┬──────┘                       └──────┬──────┘                │
│          │                                     │                        │
│          ▼                                     ▼                        │
│   ┌─────────────┐                       ┌─────────────┐                │
│   │   Export    │                       │   Export    │                │
│   │   (GPKG)    │                       │   (GPKG)    │                │
│   └─────────────┘                       └─────────────┘                │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Platform Pillars

### Pillar 1: Tiered TAK Server Support

Different missions need different capabilities. Heartbeat provides a unified interface across three TAK server tiers:

**Feature Pyramid:**
```
                    ┌─────────────────────┐
                    │     ENTERPRISE      │  TAK Server (tak.gov)
                    │  Federation, certs, │  Full admin UI
                    │  data sync, groups  │
                    ├─────────────────────┤
                    │      STANDARD       │  OpenTAK
                    │  WebTAK, SSL/certs, │  User mgmt via WebUI
                    │  user management    │
                    ├─────────────────────┤
                    │        LITE         │  FreeTAKServer
                    │   TCP only, no auth │  Zero friction
                    │   start/stop/qr     │  March demo target
                    └─────────────────────┘
```

| Tier | Backend | Target User | Key Traits |
|------|---------|-------------|------------|
| **Lite** | FreeTAKServer | Field teams, training, demos | TCP only, no auth, zero friction, 5-min setup |
| **Standard** | OpenTAK Server | Sustained ops, built-in viz | WebTAK map, SSL/certs, user mgmt (via WebUI) |
| **Enterprise** | TAK Server (tak.gov) | Govt, military, large orgs | Federation, data sync, full admin, certified |

**User Experience:**
```bash
# Choose your tier at setup
./setup.sh --tier lite        # FreeTAKServer
./setup.sh --tier standard    # OpenTAK (recommended)
./setup.sh --tier enterprise  # TAK Server from tak.gov
```

**See:** `docs/roadmap-tak-abstraction.md` for implementation details

---

### Pillar 2: Federation

Connect multiple Heartbeat instances to share situational awareness across:
- Multiple teams in the same organization
- Partner organizations during joint operations
- Hierarchical command structures (local → regional → state)

#### Federation Architecture

```
                    ┌──────────────────┐
                    │   State EOC      │
                    │  (Heartbeat)     │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
       ┌──────────┐   ┌──────────┐   ┌──────────┐
       │ County A │   │ County B │   │ County C │
       │Heartbeat │   │Heartbeat │   │Heartbeat │
       └────┬─────┘   └────┬─────┘   └────┬─────┘
            │              │              │
      ┌─────┴─────┐  ┌─────┴─────┐  ┌─────┴─────┐
      │           │  │           │  │           │
      ▼           ▼  ▼           ▼  ▼           ▼
   [Team 1]  [Team 2] ...      ...           ...
```

#### Federation Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| **Hub-Spoke** | Central server aggregates all data | EOC monitoring multiple field teams |
| **Peer-to-Peer** | Direct connection between two servers | Two agencies sharing during incident |
| **Mesh** | All servers interconnected | Regional mutual aid network |

#### Federation Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    FEDERATION CHANNEL                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Outbound (what we share):                                  │
│  ├─ Unit positions (configurable: all, none, filtered)      │
│  ├─ Markers/POIs (user-created points)                      │
│  ├─ Drawings (lines, polygons, routes)                      │
│  └─ Chat messages (optional)                                │
│                                                              │
│  Inbound (what we receive):                                 │
│  ├─ Federated unit positions (appear as external)           │
│  ├─ Shared markers from partner orgs                        │
│  └─ Situational data from upstream                          │
│                                                              │
│  Filtering:                                                  │
│  ├─ By callsign pattern (e.g., share only "MEDIC-*")        │
│  ├─ By group membership                                      │
│  ├─ By geographic bounding box                              │
│  └─ By data type (positions only, markers only, etc.)       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

#### Federation Commands

```bash
# List federation status
./heartbeat federation status

# Add a federation partner
./heartbeat federation add \
  --name "County EOC" \
  --host eoc.county.gov \
  --port 8089 \
  --cert ./partner-cert.pem

# Configure what we share
./heartbeat federation outbound \
  --share positions \
  --share markers \
  --filter-callsign "HEARTBEAT-*"

# Temporarily disconnect
./heartbeat federation disconnect "County EOC"

# List active federations
./heartbeat federation list
```

#### Federation Backend Support

| Feature | FreeTAK | OpenTAK | TAK Server |
|---------|---------|---------|------------|
| Federation Support | Limited* | Partial | Full |
| SSL Mutual Auth | Basic | Yes | Yes |
| Data Filtering | No | Basic | Advanced |
| Group-based Sharing | No | Yes | Yes |
| Protocol Version | v1 | v1/v2 | v1/v2/v3 |

*FreeTAK federation may require custom implementation or proxy

---

### Pillar 3: Data Export (GeoPackage)

Extract tactical data from the TAK server into **GeoPackage (.gpkg)** format for:
- Post-incident analysis in GIS software (QGIS, ArcGIS)
- Archival and compliance requirements
- Sharing with non-TAK stakeholders
- Generating reports and maps

#### What Gets Exported

| Data Type | CoT Type | GeoPackage Layer | Geometry |
|-----------|----------|------------------|----------|
| **Points** | `a-*` (atoms) | `positions` | Point |
| **Markers/POIs** | `b-m-p-*` | `markers` | Point |
| **Lines/Routes** | `b-m-r-*`, `u-d-r-*` | `routes` | LineString |
| **Polygons/Areas** | `u-d-f-*` | `areas` | Polygon |
| **Drawings** | `u-d-*` | `drawings` | Mixed |

#### GeoPackage Schema

```sql
-- Layer: positions (unit tracks)
CREATE TABLE positions (
    id INTEGER PRIMARY KEY,
    uid TEXT,                    -- CoT UID
    callsign TEXT,               -- Display name
    affiliation TEXT,            -- friendly/hostile/neutral/unknown
    timestamp DATETIME,          -- Event time
    stale DATETIME,              -- Stale time
    course REAL,                 -- Heading in degrees
    speed REAL,                  -- Speed in m/s
    altitude REAL,               -- Height above ellipsoid
    geometry POINT               -- WGS84 coordinates
);

-- Layer: markers (user-created POIs)
CREATE TABLE markers (
    id INTEGER PRIMARY KEY,
    uid TEXT,
    name TEXT,
    remarks TEXT,
    icon_type TEXT,              -- CoT type for iconography
    created_by TEXT,             -- Creator callsign
    timestamp DATETIME,
    geometry POINT
);

-- Layer: routes (lines and paths)
CREATE TABLE routes (
    id INTEGER PRIMARY KEY,
    uid TEXT,
    name TEXT,
    remarks TEXT,
    stroke_color TEXT,
    stroke_width REAL,
    timestamp DATETIME,
    geometry LINESTRING
);

-- Layer: areas (polygons and zones)
CREATE TABLE areas (
    id INTEGER PRIMARY KEY,
    uid TEXT,
    name TEXT,
    remarks TEXT,
    fill_color TEXT,
    stroke_color TEXT,
    area_type TEXT,              -- hazard, objective, boundary, etc.
    timestamp DATETIME,
    geometry POLYGON
);
```

#### Export Commands

```bash
# Export all data from the last 24 hours
./heartbeat export --output incident-2026-02-05.gpkg

# Export specific time range
./heartbeat export \
  --from "2026-02-05T08:00:00Z" \
  --to "2026-02-05T18:00:00Z" \
  --output shift-report.gpkg

# Export only specific data types
./heartbeat export \
  --layers markers,areas \
  --output poi-export.gpkg

# Export with callsign filter
./heartbeat export \
  --filter-callsign "ENGINE-*,MEDIC-*" \
  --output apparatus-tracks.gpkg

# Live export (continuously append new data)
./heartbeat export \
  --live \
  --output ongoing-incident.gpkg

# Export to other formats (via ogr2ogr wrapper)
./heartbeat export \
  --format geojson \
  --output data.geojson

./heartbeat export \
  --format shapefile \
  --output ./shapefiles/
```

#### Export Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      TAK SERVER                             │
│                                                             │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │
│   │ CoT Stream  │    │  Database   │    │  REST API   │   │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘   │
│          │                  │                   │          │
└──────────┼──────────────────┼───────────────────┼──────────┘
           │                  │                   │
           ▼                  ▼                   ▼
┌─────────────────────────────────────────────────────────────┐
│                    EXPORT ENGINE                            │
│                                                             │
│   ┌─────────────────────────────────────────────────────┐  │
│   │              CoT Parser / Normalizer                 │  │
│   │  (XML → Python objects → GeoPackage features)        │  │
│   └─────────────────────────────────────────────────────┘  │
│                           │                                 │
│                           ▼                                 │
│   ┌─────────────────────────────────────────────────────┐  │
│   │              GeoPackage Writer                       │  │
│   │  (OGR/Fiona → SQLite with spatial extensions)        │  │
│   └─────────────────────────────────────────────────────┘  │
│                           │                                 │
└───────────────────────────┼─────────────────────────────────┘
                            ▼
                    ┌───────────────┐
                    │  output.gpkg  │
                    │  (GeoPackage) │
                    └───────────────┘
                            │
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
         ┌────────┐   ┌──────────┐   ┌─────────┐
         │  QGIS  │   │  ArcGIS  │   │ Reports │
         └────────┘   └──────────┘   └─────────┘
```

#### Implementation Dependencies

```bash
# Python packages for export engine (implemented -- no GDAL needed)
pip install \
  shapely         # Geometry objects + WKB serialization
  pyyaml          # GCM mapping YAML parsing
# Everything else is Python stdlib: sqlite3, xml.etree, struct, socket
```

> **Note (2026-02-10):** The export engine was implemented without GDAL/fiona/pyproj.
> GeoPackage is written directly via sqlite3 + shapely WKB. This keeps the dependency
> footprint minimal for field laptops.

---

## Complete Platform Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│                         HEARTBEAT PLATFORM                              │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐ │
│  │                        CLI LAYER                                   │ │
│  │  heartbeat [start|stop|status|federation|export|...]              │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                    │                                    │
│  ┌─────────────────────────────────┼─────────────────────────────────┐ │
│  │                         CORE SERVICES                              │ │
│  │                                 │                                  │ │
│  │  ┌──────────────┐  ┌───────────┴───────────┐  ┌────────────────┐ │ │
│  │  │  Lifecycle   │  │     Federation        │  │     Export     │ │ │
│  │  │  Manager     │  │     Manager           │  │     Engine     │ │ │
│  │  │              │  │                       │  │                │ │ │
│  │  │ start/stop   │  │ connect/disconnect    │  │ CoT → GPKG    │ │ │
│  │  │ status/logs  │  │ filter/route          │  │ live/batch    │ │ │
│  │  │ users/pkgs   │  │ auth/certs            │  │ multi-format  │ │ │
│  │  └──────┬───────┘  └───────────┬───────────┘  └───────┬────────┘ │ │
│  │         │                      │                      │          │ │
│  └─────────┼──────────────────────┼──────────────────────┼──────────┘ │
│            │                      │                      │            │
│  ┌─────────┴──────────────────────┴──────────────────────┴──────────┐ │
│  │                      BACKEND ABSTRACTION                          │ │
│  │                                                                   │ │
│  │  backend_start()  backend_federation_*()  backend_get_cot_stream()│ │
│  │                                                                   │ │
│  └──────────────────────────┬────────────────────────────────────────┘ │
│                             │                                          │
│  ┌──────────────────────────┴────────────────────────────────────────┐ │
│  │                         BACKENDS                                   │ │
│  │                                                                    │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐      │ │
│  │  │   FreeTAK      │  │    OpenTAK     │  │   TAK Server   │      │ │
│  │  │   (Lite)       │  │   (Standard)   │  │  (Enterprise)  │      │ │
│  │  │                │  │                │  │                │      │ │
│  │  │ • Lightweight  │  │ • WebTAK map   │  │ • Federation   │      │ │
│  │  │ • Open source  │  │ • Modern API   │  │ • Full sync    │      │ │
│  │  │ • Low resource │  │ • Good Docker  │  │ • tak.gov cert │      │ │
│  │  └────────────────┘  └────────────────┘  └────────────────┘      │ │
│  │                                                                    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Implementation Roadmap

| Phase | Focus | Deliverables | Status |
|-------|-------|--------------|--------|
| **1** | Headless Core | Remove beacon/webmap, clean foundation | COMPLETE |
| **2** | Backend Abstraction | Interface definition, FreeTAK refactor | COMPLETE |
| **3** | OpenTAK Backend | Standard tier with built-in WebTAK | COMPLETE |
| **4** | Export Engine | GeoPackage export for all backends | COMPLETE |
| **5** | Federation (Basic) | Peer-to-peer connection, manual config | Future |
| **6** | TAK Server Backend | Enterprise tier, tak.gov integration | Future |
| **7** | Federation (Advanced) | Hub-spoke, filtering, mesh support | Future |

---

## Use Case Scenarios

### Scenario 1: Small Volunteer Fire Department

**Tier:** Lite (FreeTAKServer)
**Federation:** None
**Export:** Post-incident GPKG for training review

```bash
./setup.sh --tier lite
./heartbeat start
# ... incident response ...
./heartbeat export --output incident-2026-02-05.gpkg
```

### Scenario 2: County Emergency Management

**Tier:** Standard (OpenTAK)
**Federation:** Hub-spoke to State EOC
**Export:** Shift reports, mutual aid coordination

```bash
./setup.sh --tier standard
./heartbeat federation add --name "State EOC" --host eoc.state.gov
./heartbeat start
# ... operations ...
./heartbeat export --from "today 06:00" --output day-shift.gpkg
```

### Scenario 3: Multi-Agency Task Force

**Tier:** Enterprise (TAK Server)
**Federation:** Mesh between 5 agencies
**Export:** Continuous archive, compliance records

```bash
./setup.sh --tier enterprise
./heartbeat federation add --name "Agency A" --host ...
./heartbeat federation add --name "Agency B" --host ...
# ... configure mesh ...
./heartbeat export --live --output operation-archive.gpkg
```

---

## Technical Considerations

### Data Persistence for Export

To support export, Heartbeat needs to persist CoT data:

| Backend | Native Persistence | Export Strategy |
|---------|-------------------|-----------------|
| FreeTAK | SQLite (basic) | Query DB directly or tap CoT stream |
| OpenTAK | PostgreSQL | Query DB via API |
| TAK Server | PostgreSQL | Query via Data Sync API |

For **live export**, we tap the CoT stream directly and write to GPKG in real-time.

### Federation Protocol Compatibility

TAK federation uses SSL mutual authentication and CoT-over-TLS:

```
Server A                          Server B
   │                                  │
   │──── TLS handshake (certs) ──────►│
   │◄─── TLS handshake (certs) ───────│
   │                                  │
   │──── CoT events (filtered) ──────►│
   │◄─── CoT events (filtered) ───────│
   │                                  │
```

### GeoPackage as Universal Exchange

Why GPKG over other formats:

| Format | Pros | Cons |
|--------|------|------|
| **GeoPackage** | Single file, full schema, SQLite-based, OGC standard | Less common than Shapefile |
| Shapefile | Universal support | Multi-file, attribute limits, no mixed geometry |
| GeoJSON | Human readable, web-friendly | Large files, no schema |
| KML/KMZ | Google Earth compatible | Limited attributes, XML bloat |

**GPKG is the right choice** for archival and GIS analysis.

---

## Success Criteria

### Platform Complete When:

- [ ] User can deploy any of three TAK server tiers with same CLI
- [ ] Two Heartbeat instances can federate and share positions
- [ ] User can export a week of data to GPKG and open in QGIS
- [ ] Documentation covers all three tiers and federation setup
- [ ] End-to-end test: setup → operate → federate → export

---

## Related Documents

| Document | Purpose |
|----------|---------|
| `docs/headless-cleanup-spec.md` | Phase 1 implementation details |
| `docs/roadmap-tak-abstraction.md` | Phase 2-4 backend architecture |
| `docs/vision-heartbeat-platform.md` | This document (strategic vision) |

---

## Resolved Questions

1. **Branding:** Heartbeat keeps its name - it's the "heart" that keeps TAK alive. The broader ecosystem is ALIAS; Heartbeat is one component. Repo structure may evolve to reflect this (heartbeat as subdirectory of larger ALIAS repo).

2. **ALIAS Integration:** See "ALIAS Ecosystem Integration" section below. TAK is the human UI layer; simulation feeds data in, export pulls data out.

3. **Cloud Option:** Yes - Heartbeat should run anywhere (local, VM, cloud). Docker makes this straightforward.

4. **Mobile:** No custom app needed. Clients are **iTAK** (iOS), **ATAK** (Android), and **WebTAK** (browser). These are the standard TAK ecosystem clients.

5. **Licensing Philosophy:** **Free for the prosperity of humanity.** All ALIAS software is free and open when legally possible. The only constraint is upstream dependencies:
   - FreeTAK: Open source, free → Heartbeat Lite is free
   - OpenTAK: Open source, free → Heartbeat Standard is free
   - TAK Server (tak.gov): Restricted distribution → Users must obtain it themselves, but Heartbeat's integration layer is still free

---

## ALIAS Ecosystem Integration

Heartbeat is the TAK component of ALIAS. Here's how it fits:

### Data Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           ALIAS ECOSYSTEM                               │
│                                                                         │
│  ┌──────────────┐                                    ┌──────────────┐  │
│  │  SIMULATION  │                                    │    EXPORT    │  │
│  │              │                                    │              │  │
│  │  • Scenarios │                                    │  • GeoPackage│  │
│  │  • Events    │                                    │  • Analysis  │  │
│  │  • Positions │                                    │  • Archives  │  │
│  └──────┬───────┘                                    └──────▲───────┘  │
│         │                                                   │          │
│         │  Inject CoT                          Extract CoT  │          │
│         │                                                   │          │
│         ▼                                                   │          │
│  ┌──────────────────────────────────────────────────────────┴───────┐  │
│  │                         HEARTBEAT                                 │  │
│  │                    (TAK Server Manager)                          │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────┐ │  │
│  │  │                      TAK SERVER                              │ │  │
│  │  │              (FreeTAK / OpenTAK / TAK Server)                │ │  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │
│  └───────────────────────────────┬───────────────────────────────────┘  │
│                                  │                                      │
│                    CoT Stream (positions, markers, drawings)            │
│                                  │                                      │
│                  ┌───────────────┼───────────────┐                     │
│                  ▼               ▼               ▼                     │
│            ┌──────────┐   ┌──────────┐   ┌──────────┐                 │
│            │   iTAK   │   │   ATAK   │   │  WebTAK  │                 │
│            │  (iOS)   │   │(Android) │   │(Browser) │                 │
│            └──────────┘   └──────────┘   └──────────┘                 │
│                                                                         │
│                      THE HUMAN UI LAYER                                │
│            (Users see positions, draw annotations, chat)               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Simulation Integration (Future)

For training scenarios, ALIAS needs to inject simulated data into TAK:

#### GPS Spoofing for Training

Make clients appear where the simulation says they are:

```
┌──────────────┐     VPN      ┌──────────────┐     CoT      ┌──────────────┐
│  Simulation  │─────────────►│   Client     │─────────────►│  Heartbeat   │
│   Engine     │              │  (iTAK/ATAK) │              │  TAK Server  │
│              │              │              │              │              │
│ "Unit A is   │  Spoofed GPS │ Client shows │  Reports     │ All users    │
│  at 30.5,-96"│  coordinates │ position at  │  position    │ see Unit A   │
│              │              │  30.5, -96   │              │  at 30.5,-96 │
└──────────────┘              └──────────────┘              └──────────────┘
```

**Implementation approaches (decision TBD):**

| Approach | How It Works | Pros | Cons |
|----------|--------------|------|------|
| **1. Mock GPS App** | Android app that provides fake GPS to the system. Sim sends coordinates via VPN, app feeds them to OS location services. | Clean - ATAK thinks it's real GPS. Works with any TAK client. | Requires device control (install app). Android only (iOS locked down). May need developer mode. |
| **2. CoT Injection** | Sim sends CoT position events directly to TAK server, bypassing the client entirely. Client's real GPS is ignored for that UID. | No client modification. Works with any device. Server-side control. | Client still shows its real position locally. Two "selves" issue. Requires UID coordination. |
| **3. ATAK Plugin** | Custom ATAK plugin listens for sim position updates (UDP/TCP) and overrides self-location reporting. | Integrated experience. Plugin can show "sim mode" indicator. | ATAK only (no iTAK). Plugin development required. Must distribute plugin to devices. |
| **4. Hybrid** | CoT injection for observer view + mock GPS for immersive training on select devices. | Best of both worlds. | More complexity. |

**Recommendation:** Start with **CoT Injection** (Approach 2) for the March demo - it's server-side only, no client changes needed. Evaluate Mock GPS (Approach 1) for immersive training later.

#### Sim-to-TAK Bridge

```bash
# Future command
./heartbeat sim connect --source udp://sim-server:5000

# Heartbeat listens for sim events and injects as CoT:
# - Unit positions (appear as icons on map)
# - Events (appear as markers/alerts)
# - Scenario triggers
```

### Export Integration

TAK annotations (what humans draw) become input for other ALIAS components:

```
User draws on map          Heartbeat exports           Other systems consume
─────────────────────     ───────────────────────     ─────────────────────

  "Hazard Zone"     ──►    areas.gpkg:               ──►  Route planning
  (red polygon)            - geometry: POLYGON            avoids this zone
                           - type: hazard
                           - name: "Hazard Zone"

  "Rally Point"     ──►    markers.gpkg:             ──►  Navigation sends
  (green marker)           - geometry: POINT              units here
                           - name: "Rally Point"

  "Evacuation       ──►    routes.gpkg:              ──►  Sim validates
   Route"                  - geometry: LINESTRING         route timing
  (blue line)              - name: "Evac Route"
```

### External Data Inputs (Future)

Beyond simulation, TAK can ingest real-world data feeds:

| Data Source | Protocol | TAK Display | Use Case |
|-------------|----------|-------------|----------|
| **ADS-B Receiver** | dump1090 / Beast | Aircraft icons with callsign, altitude, heading | Airspace deconfliction for helicopter ops |
| **APRS Gateway** | APRS-IS | HAM radio operator positions | Mutual aid, SAR coordination |
| **AVL/GPS Trackers** | Varies | Vehicle positions | Fleet tracking without TAK on every device |
| **Weather Stations** | METAR/TAF | Weather markers | Ops planning |

**ADS-B Integration (air encroachment):**
```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│   ADS-B         │      │   Heartbeat     │      │   TAK Clients   │
│   Receiver      │─────►│   Bridge        │─────►│   (iTAK/ATAK)   │
│   (dump1090)    │ JSON │   (adsb2cot)    │ CoT  │                 │
└─────────────────┘      └─────────────────┘      └─────────────────┘

Aircraft within X nm of ops area appear on map
Altitude + heading shown for deconfliction
```

### Deployment Options

Heartbeat runs wherever you need it:

| Deployment | Use Case | Notes |
|------------|----------|-------|
| **Local laptop** | Field operations, training | No internet required |
| **On-prem server** | EOC, permanent installation | Higher capacity |
| **Cloud VM** | Remote teams, always-on | AWS, Azure, DigitalOcean, etc. |
| **Docker anywhere** | Portable, reproducible | Same image works everywhere |

```bash
# Local
./setup.sh --tier standard

# Cloud (same commands, just on a VM)
ssh user@cloud-vm
git clone ... && cd heartbeat
./setup.sh --tier standard
```

### Connectivity Considerations

**5G/LTE Limitations:**
- Cellular coverage has altitude limits (~300-500m AGL typical)
- Helicopters operating above this altitude lose connectivity
- Ground units in canyons/dense forest may have dead zones

**Fallback Options:**

| Scenario | Primary | Fallback |
|----------|---------|----------|
| Ground ops, good cell coverage | 5G/LTE | - |
| Ground ops, poor cell coverage | 5G/LTE | Silvus MANET radios |
| Helicopter ops | Silvus MANET | Satellite (high latency) |
| Remote wilderness | Silvus MANET mesh | Store-and-forward |

**MANET Integration:**
- Silvus radios provide IP mesh network
- TAK clients connect to local Heartbeat server
- Server federates upstream when connectivity available
- See `docs/guides/network-options.md` for detailed configs
