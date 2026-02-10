# Heartbeat

TAK server deployment and management for teams.

Heartbeat wraps [FreeTAKServer](https://github.com/FreeTAKTeam/FreeTakServer) (Lite) and [OpenTAK Server](https://github.com/brian7704/OpenTAKServer) (Standard) behind a single CLI so your team can share locations, draw routes, and drop annotations via [iTAK](https://apps.apple.com/us/app/itak/id1561656396) (iOS) and [ATAK](https://play.google.com/store/apps/details?id=com.atakmap.app.civ) (Android).

## Quick Start

```bash
# 1. Run setup (picks backend, mode, ports, credentials)
./setup.sh

# 2. Start the server (recorder auto-starts)
./heartbeat start

# 3. Generate connection packages for devices
./heartbeat package              # auto-names: device-1, device-2, ...
./heartbeat package "Chief Smith" # or pick a name

# 4. Serve packages over HTTP so phones can download them
./heartbeat serve
```

Open the URL on your phone, download the `.zip`, and import it into iTAK/ATAK.

Credentials are generated during setup and stored in `config/heartbeat.conf`.

## Backends

Heartbeat supports two TAK server backends through a pluggable abstraction layer (`lib/backends/`). Pick the one that fits your mission:

| | FreeTAK (Lite) | OpenTAK (Standard) |
|---|---|---|
| Transport | TCP only | SSL + TCP |
| Authentication | None | Per-device certs + user management |
| WebTAK (browser map) | No | Yes (:8443) |
| Lines/polygons relay | Crashes on complex types | Works |
| Install method | Docker or Python venv | Native systemd (postgres, rabbitmq, nginx) |
| Default CoT port | 8087 | 8088 |

```bash
# Lite (default)
./setup.sh

# Standard
./setup.sh --backend opentak
```

## Requirements

**Server** (any one of):
- Linux with Docker (FreeTAK Docker mode)
- Linux with Python 3.8+ (FreeTAK native mode)
- Linux with Python 3.10+, PostgreSQL, RabbitMQ, nginx (OpenTAK)

**Clients** (team members' phones):
- iPhone: [iTAK](https://apps.apple.com/us/app/itak/id1561656396) (free)
- Android: [ATAK-CIV](https://play.google.com/store/apps/details?id=com.atakmap.app.civ) (free)

## Commands

```
./heartbeat <command> [args]

Server:
  start                Start the TAK server (recorder auto-starts)
  stop                 Stop the server (auto-exports recorded data)
  restart              Restart the server (OpenTAK: full stack reset)
  reset                Full reset (backend + dependencies)
  status               Show server status, ports, and health checks
  listen               Live monitor -- follow connections and events
  logs [-f]            View server logs (-f to follow)

Team:
  qr                   Show QR code to scan from iTAK/ATAK
  tailscale            Set SERVER_IP to the Tailscale IP
  package [name]       Generate a connection package (auto-names if omitted)
  packages             List all generated packages
  serve [port]         HTTP-serve packages for phone download (default :9000)

Recording & Export:
  record status        Check recorder status and event count
  record start|stop    Manually control recorder (auto-starts with server)
  export [-o file]     Export recorded events to GeoPackage (.gpkg)
  export --gcm [-o f]  Export GCM (tactical geometry) only

System:
  info                 Show server connection details
  update               Update the active TAK backend
  systemd              Install systemd service (native mode, requires sudo)
  uninstall            Remove the active TAK backend
  clean                Remove all generated artifacts (packages, certs, logs)
  help                 Show this help

Notes:
- Commands support prefix matching: "st" -> "start", "sta" -> "status"
- Packages embed the server IP; if the IP changes, regenerate packages.
- OpenTAK packages are device-specific (one per device, unique certs).
```

## Setup Modes

### FreeTAK - Docker (recommended for Lite)

Runs FreeTAKServer in an isolated container. Requires Docker and Docker Compose.

```bash
./setup.sh --docker
```

### FreeTAK - Native

Installs FreeTAKServer into a Python virtualenv under `data/venv/`. No Docker needed.

```bash
./setup.sh --native
```

### OpenTAK - Native (Standard tier)

Installs OpenTAK Server as native systemd services with PostgreSQL, RabbitMQ, and nginx.

```bash
./setup.sh --backend opentak
```

This gives you SSL certificates, per-device identity, WebTAK browser map on :8443, and reliable relay of lines/polygons/annotations between devices.

## Connecting from iTAK / ATAK

### Option A - Import a data package (recommended)

1. Generate: `./heartbeat package` (or `./heartbeat package "Your Name"`)
2. Serve:   `./heartbeat serve`
3. On your phone, open the URL shown in a browser
4. Download the `.zip` file
5. Open it with iTAK (share sheet > iTAK, or Files > open with iTAK)

**OpenTAK note:** Each device must import a different package. Do not share one package across multiple phones/tablets -- this causes identity collisions and breaks message routing.

### Option B - Manual configuration (FreeTAK only)

1. Open iTAK > Settings > Network Preferences > Servers
2. Add server:
   - Address: your server IP (shown by `./heartbeat info`)
   - Port: `8087`
   - Protocol: TCP

## Recording and Export

Heartbeat records all CoT events (positions, markers, routes, polygons) from the TAK server into a SQLite database. Recording starts automatically with `./heartbeat start` and exports automatically on `./heartbeat stop`.

```bash
# Check what's been recorded
./heartbeat record status

# Manual export anytime
./heartbeat export -o tracks.gpkg

# Export tactical geometry only (no position tracks)
./heartbeat export --gcm -o tactical.gpkg
```

Output is OGC GeoPackage (.gpkg) -- opens directly in QGIS, ArcGIS, or any spatial tool. No GDAL required on the server.

## Project Structure

```
heartbeat/
├── setup.sh                    Setup installer
├── heartbeat                   Main CLI tool
├── lib/
│   ├── common.sh               Shared utilities, config, logging
│   ├── server.sh               Server lifecycle (delegates to backends)
│   ├── record.sh               Recorder daemon management
│   ├── export.sh               GeoPackage export wrapper
│   ├── package.sh              Connection package generation + HTTP serving
│   ├── install.sh              System deps + backend-specific installers
│   ├── qr.sh                   QR code generation
│   └── backends/
│       ├── interface.sh        Backend contract (abstract interface)
│       ├── freetak.sh          FreeTAK implementation (Docker or venv)
│       └── opentak.sh          OpenTAK implementation (native systemd)
├── tools/
│   ├── recorder.py             CoT TCP client daemon
│   ├── cot_parser.py           CoT XML stream parser
│   ├── exporter.py             SQLite -> GeoPackage converter
│   ├── gpkg_writer.py          OGC GeoPackage writer (no GDAL)
│   ├── gcm_mapper.py           YAML-based GCM classification
│   └── requirements.txt        Python deps (shapely, pyyaml)
├── config/
│   ├── heartbeat.conf.example  Configuration template
│   └── gcm-mapping.yml         GCM export classification rules
├── docker/
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── FTSConfig.yaml.example
├── templates/
│   ├── manifest.xml            Data package manifest template
│   └── server.pref             Connection preferences template
├── docs/
│   ├── README.md               Documentation index
│   ├── architecture/           System topology and diagrams
│   ├── planning/               Vision, roadmaps, specs
│   ├── guides/                 Field quickstart, network options
│   ├── specs/                  Implementation specs
│   └── notes/                  Working notes
├── packages/                   Generated .zip packages (gitignored)
└── data/                       Runtime data (gitignored)
```

## Field Quick Start

See [docs/guides/field-quickstart.md](docs/guides/field-quickstart.md) for a one-page, non-technical runbook.

## Network Notes

- Server and phones must be on the same network (WiFi/LAN), or the server must be reachable over a VPN
- **FreeTAK:** Default CoT port is 8087 TCP
- **OpenTAK:** Default CoT port is 8088 TCP (SSL on 8089), WebTAK on 8443
- DataPackage/API port is 8443
- If Tailscale is installed, setup defaults to the Tailscale IP
- Ensure your firewall allows the CoT port: `sudo ufw allow 8087/tcp` (or 8088 for OpenTAK)

## Troubleshooting

**Server won't start:** Check logs with `./heartbeat logs`. Common issues:
- Port already in use: change ports in `config/heartbeat.conf`
- Python dependency errors (native mode): try Docker mode instead
- OpenTAK: check that PostgreSQL, RabbitMQ, and nginx are running

**Phone can't connect:** Verify with `./heartbeat status` that ports show "listening", then:
- Confirm phone and server are on the same WiFi
- Check firewall: `sudo ufw allow 8087/tcp` (or 8088 for OpenTAK)
- Try the IP shown by `./heartbeat info`

**OpenTAK: devices don't see each other's locations/annotations:**
- Make sure each device has its own unique package (don't share one .zip across devices)
- Try `./heartbeat reset` to clear stale RabbitMQ state
- Check logs for "channel closed" errors -- this usually means cert identity collision

**iTAK doesn't import the package:** Make sure you're opening the `.zip` file directly with iTAK, not unzipping it first.

**Export is empty:** Confirm the recorder was running (`./heartbeat record status`) and that devices were connected while it was active.
