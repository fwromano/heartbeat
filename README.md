# Heartbeat

TAK server deployment and management for teams.

Heartbeat wraps [FreeTAKServer](https://github.com/FreeTAKTeam/FreeTakServer) (Lite) and [OpenTAK Server](https://github.com/brian7704/OpenTAKServer) (Standard) behind a single CLI so your team can share locations, draw routes, and drop annotations via [iTAK](https://apps.apple.com/us/app/itak/id1561656396) (iOS) and [ATAK](https://play.google.com/store/apps/details?id=com.atakmap.app.civ) (Android).

## Quick Start

```bash
# First time only
./setup.sh                    # picks backend, mode, ports, credentials

# Start the server (recorder + package page auto-start)
./heartbeat start

# Onboard devices
# open http://SERVER_IP:9000 on each device

# After the operation
./heartbeat stop              # auto-exports recorded data to .gpkg
```

That's it. Phones download the `.zip` and import it into iTAK/ATAK. After initial onboarding, your daily workflow is just `start` and `stop` — recording and export happen automatically.

For OpenTAK (multiple devices), generate additional packages as needed:
```bash
./heartbeat package "Squad 2"   # one unique package per device
```

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
  start                Start the TAK server (recorder + package page auto-start)
  stop                 Stop the server (auto-exports recorded data)
  restart              Restart the server (OpenTAK: full stack reset)
  reset                Full reset (backend + dependencies)
  status               Show server status, ports, and health checks
  listen               Live monitor -- follow connections and events
  logs [-f]            View server logs (-f to follow)

Team:
  qr                   Show optional QR for package page URL
  tailscale            Set SERVER_IP to the Tailscale IP
  package [name]       Generate a data package (auto-names if omitted)
  packages             List all generated packages
  serve [port]         HTTP-serve packages for device download (default :9000)

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
- OpenTAK packages are device-specific (one per device, unique certs). `./heartbeat serve` now auto-generates a unique package per download tap.
- Package page auto-starts with `./heartbeat start` by default (`HEARTBEAT_AUTOSERVE=true`).
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

To install OpenTAK from a fork/branch instead of PyPI, set:

```bash
OTS_GIT_URL="https://github.com/fwromano/OpenTAKServer.git"
OTS_GIT_REF="heartbeat-fixes"   # or main
./setup.sh --backend opentak
```

`setup.sh` persists these in `config/heartbeat.conf`, and `./heartbeat update` uses the same source.

## Connecting from iTAK / ATAK

### Option A - Data package (recommended)

1. Run `./heartbeat start` on the server (package page auto-starts)
2. On each device, open `http://SERVER_IP:9000` in a browser
3. Download the `.zip` file
4. Open it with iTAK (share sheet > iTAK) or ATAK (import manager)

Packages are auto-generated when you serve. For OpenTAK, each tap on the serve page generates a unique per-device package automatically. You can still pre-generate named packages with `./heartbeat package "Name"`.

### Option B - Manual connection (FreeTAK only)

1. Open iTAK > Settings > Network Preferences > Servers
2. Add server:
   - Address: your server IP (shown by `./heartbeat info`)
   - Port: `8087`
   - Protocol: TCP

## Recording and Export

Recording and export are fully automatic. `./heartbeat start` begins capturing all CoT events (positions, markers, routes, polygons) and `./heartbeat stop` exports them to GeoPackage.

Output files land in `data/exports/` — open directly in QGIS, ArcGIS, or any spatial tool. No GDAL required.

```bash
# Check what's been recorded (during an operation)
./heartbeat record status

# Manual export anytime (without stopping the server)
./heartbeat export -o tracks.gpkg

# Export tactical geometry only (no position tracks)
./heartbeat export --gcm -o tactical.gpkg
```

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
│   ├── package_server.py       HTTP server with OpenTAK auto package endpoint
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
│   ├── specs/                  Active implementation specs
│   ├── planning/               Future roadmaps and design docs
│   ├── guides/                 Field quickstart, network options
│   ├── notes/                  Working notes and task tracking
│   └── archive/                Completed specs and historical docs
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
