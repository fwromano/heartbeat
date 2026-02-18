# Field Quick Start (One-Page)

Goal: get everyone's phone sharing live location on the same map, fast.

## Pick your backend

| | FreeTAK (Lite) | OpenTAK (Standard) |
|---|---|---|
| Setup | `./setup.sh` | `./setup.sh --backend opentak` |
| Transport | TCP, no auth | SSL certs, per-device identity |
| Browser map | No | Yes (WebTAK on :8443) |
| Lines/polygons | Crashes on complex types | Works |

> **Start with Lite** if you just need location sharing. Move to Standard when you need annotations, routes, or a browser map.

## 1) Setup and start
```bash
./setup.sh           # first time only (or ./setup.sh --backend opentak)
./heartbeat start    # server + recorder + package page auto-start
```

## 2) Onboard phones
Phones open: `http://SERVER_IP:9000` -- download zip -- import into iTAK/ATAK.
`./heartbeat serve` is optional if you need to run the package page manually.

**OpenTAK important:** Each device must import a *different* package. Sharing one package across phones causes identity collisions and breaks message routing.

**FreeTAK alternative (manual connection):**
- Server: `SERVER_IP` (shown by `./heartbeat info`)
- Port: `8087` (FreeTAK) or `8088` (OpenTAK TCP) or `8089` (OpenTAK SSL)
- Protocol: TCP

**OpenTAK WebTAK (browser access):**
- Open `https://SERVER_IP:8443/` in any browser
- Accept the self-signed certificate warning
- Log in with the credentials shown during setup

## 3) Confirm it's working
```bash
./heartbeat status    # check ports and health
./heartbeat listen    # live event monitor
```
You should see connections and data events.

## 4) After the operation
```bash
./heartbeat stop      # auto-exports recorded data to .gpkg
```

The exported GeoPackage opens in QGIS, ArcGIS, or any GIS tool.

---

# Network reality check (fast)

## Same Wi-Fi (easiest)
- All phones + server on same Wi-Fi
- Works with no internet

## Internet hosting (when phones are on 5G)
- Server must be reachable from the public internet
- If you don't control the router or inbound ports, **hosting from a work laptop usually won't work**
- Alternatives:
  - Public VM (works anywhere)
  - Mesh VPN (Tailscale/ZeroTier) for no-router setups

## Tailscale VPN
```bash
./heartbeat tailscale    # auto-sets SERVER_IP to Tailscale address
```
After changing the IP, regenerate packages with `./heartbeat serve` (auto-generates) or `./heartbeat package "Name"`.
After changing the IP, restart to refresh the package page URL:
```bash
./heartbeat restart
```
