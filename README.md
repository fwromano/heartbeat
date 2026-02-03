# Heartbeat

TAK server deployment and management for teams.

Automates [FreeTAKServer](https://github.com/FreeTAKTeam/FreeTakServer) setup so your team can share locations via [iTAK](https://apps.apple.com/us/app/itak/id1561656396) (iOS) and [ATAK](https://play.google.com/store/apps/details?id=com.atakmap.app.civ) (Android) over cellular or WiFi.

## Quick Start

```bash
# 1. Run setup (interactive - picks Docker or native, configures everything)
./setup.sh

# 2. Start the server
./heartbeat start

# 3. Generate a connection package for a team member
./heartbeat package "Chief Smith"

# 4. Serve packages over HTTP so phones can download them
./heartbeat serve
```

Open the URL on your phone, download the `.zip`, and import it into iTAK/ATAK.

Setup generates default TAK credentials. You can view them anytime with `./heartbeat qr`
or in `config/heartbeat.conf`.

## Requirements

**Server** (any one of):
- Linux with Docker (recommended)
- Linux with Python 3.8+

**Clients** (team members' phones):
- iPhone: [iTAK](https://apps.apple.com/us/app/itak/id1561656396) (free)
- Android: [ATAK-CIV](https://play.google.com/store/apps/details?id=com.atakmap.app.civ) (free)
- Browser: WebTAK (if running FreeTAKServer with WebTAK enabled)

## Commands

```
./heartbeat <command> [args]

Server:
  start                Start the TAK server
  stop                 Stop the TAK server
  restart              Restart the TAK server
  status               Show server status and port checks
  listen               Live monitor -- follow connections and events
  logs [-f]            View server logs (-f to follow)

Team:
  qr                   Show QR code to scan from iTAK/ATAK
  adduser <name> [pw]  Create a TAK server login for a team member
  addusers <file>      Create users from a list (one name per line)
  tailscale            Set SERVER_IP to the Tailscale IP
  package <name>       Generate a connection package for a member
  packages             List all generated packages
  serve [port]         HTTP-serve packages for phone download (default :9000)

System:
  info                 Show server connection details
  update               Update FreeTAKServer to latest version
  systemd              Install systemd service (native mode, requires sudo)
  uninstall            Remove FreeTAKServer and optionally data

Notes:
- If you omit `[pw]` in `adduser`, the password defaults to the name.
- `addusers` ignores blank lines and `#` comments.
- Packages embed the server IP; if the IP changes, regenerate packages.
```

## Setup Modes

### Docker (recommended)

Runs FreeTAKServer in an isolated container. Requires Docker and Docker Compose.

```bash
./setup.sh --docker
```

Note: `./setup.sh` generates `docker/FTSConfig.yaml` from your config values; the
tracked `docker/FTSConfig.yaml.example` is just a template.

### Native

Installs FreeTAKServer into a Python virtualenv under `data/venv/`. No Docker needed.

```bash
./setup.sh --native
```

## Connecting from iTAK

**Option A - Import a data package:**

1. Generate: `./heartbeat package "Your Name"`
2. Serve:   `./heartbeat serve`
3. On your phone, open the URL shown in a browser
4. Download the `.zip` file
5. Open it with iTAK (share sheet > iTAK, or Files > open with iTAK)

**Option B - Manual configuration:**

1. Open iTAK > Settings > Network Preferences > Servers
2. Add server:
   - Address: your server IP (shown by `./heartbeat info`)
   - Port: `8087`
   - Protocol: TCP

## Connecting from ATAK

Same two options as iTAK. ATAK can also import data packages from:
- Settings > Tool Preferences > Network Preferences > Manage Server Connections > Import

## Project Structure

```
heartbeat/
  setup.sh              Setup installer
  heartbeat             Main CLI tool
  lib/
    common.sh           Shared utilities
    install.sh          Installation logic
    server.sh           Server management
    package.sh          Data package generation
  config/
    heartbeat.conf.example
  docker/
    Dockerfile
    docker-compose.yml
    FTSConfig.yaml.example
    certs/              Generated TLS certs (gitignored)
  templates/
    manifest.xml        Data package manifest template
    server.pref         Connection preferences template
  docs/
    field-quickstart.md
    network-options.md
  packages/             Generated .zip packages (gitignored)
  data/                 Runtime data (gitignored)
```

## Browser Map (WebMap)

Heartbeat can auto-launch the FreeTAKHub WebMap (browser map) on startup.
Enable it during setup with `./setup.sh --webmap` or set `WEBMAP_ENABLED="true"`
in `config/heartbeat.conf`. WebMap will run locally and be accessible at:

```
http://SERVER_IP:8000/tak-map
```

## Server Beacon (Map Dot)

Heartbeat can send a simple CoT beacon so the server/laptop appears on the map.
Set coordinates once and it will auto-start on `./heartbeat start`:

```
./heartbeat beacon set --lat 34.0500 --lon -118.2500 --name "HQ"
```

Disable with `--no-beacon` during setup or `BEACON_ENABLED="false"` in config.

## Field Quick Start

See `docs/field-quickstart.md` for a one-page, non-technical runbook.

## Network Notes

- Server and phones must be on the same network (WiFi/LAN), or the server must be reachable over a VPN
- Default CoT port is **8087 TCP** - ensure your firewall allows it
- DataPackage port is **8443** (FreeTAKServer default)
- If Tailscale is installed, setup defaults to the Tailscale IP (use --no-tailscale to force LAN)
- WebMap defaults on (use --no-webmap to disable)
- Beacon defaults on (set `BEACON_LAT/LON` to place the dot, or disable with --no-beacon)
- If TAILSCALE_MODE is enabled, Heartbeat will auto-refresh SERVER_IP to the current Tailscale IP

## Troubleshooting

**Server won't start:** Check logs with `./heartbeat logs`. Common issues:
- Port already in use: change ports in `config/heartbeat.conf`
- Python dependency errors (native mode): try Docker mode instead

**Phone can't connect:** Verify with `./heartbeat status` that ports show "listening", then:
- Confirm phone and server are on the same WiFi
- Check firewall: `sudo ufw allow 8087/tcp`
- Try the IP shown by `./heartbeat info`

**iTAK doesn't import the package:** Make sure you're opening the `.zip` file directly with iTAK, not unzipping it first.
