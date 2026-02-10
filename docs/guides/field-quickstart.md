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

## 1) Start the server
```bash
./setup.sh           # first time only (or ./setup.sh --backend opentak)
./heartbeat start
```

Setup auto-detects Docker, picks free ports, generates credentials. Recording starts automatically.

## 2) Get the server address
```bash
./heartbeat info
```
Use the **Server IP** shown.

## 3) Distribute connection packages

```bash
# Generate packages (one per device for OpenTAK)
./heartbeat package              # auto-names: device-1, device-2, ...
./heartbeat package "Chief"      # or pick a name

# Serve over HTTP
./heartbeat serve
```

Phones open: `http://SERVER_IP:9000` -- download zip -- import into iTAK/ATAK.

**OpenTAK important:** Each device must import a *different* package. Sharing one package across phones causes identity collisions and breaks message routing.

**FreeTAK alternative (manual):**
- Server: `SERVER_IP`
- Port: `8087`
- Protocol: TCP

## 4) Confirm it's working
```bash
./heartbeat status    # check ports and health
./heartbeat listen    # live event monitor
```
You should see connections and data events.

## 5) After the operation
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
./heartbeat package      # regenerate packages with new IP
```
