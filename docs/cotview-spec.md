# CoTView — Lightweight CoT Web Viewer

Replace the broken FreeTAKHub WebMap binary with a simple, maintainable CoT viewer we control.

## Overview

A Python server that:
1. Connects to FTS CoT port as a TCP client
2. Parses incoming CoT XML events
3. Serves a Leaflet-based web page via HTTP
4. Pushes track updates to the browser via WebSocket

No binary blobs, no Node-RED, no reverse engineering. ~300 lines of Python + ~150 lines of JS.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Browser (localhost:8000)                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Leaflet map + markers                               │   │
│  │  WebSocket client → receives track updates           │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            ↑ WebSocket
                            │
┌─────────────────────────────────────────────────────────────┐
│  cotview.py                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │ HTTP server  │    │ WS broadcast │    │ CoT client   │  │
│  │ (serves UI)  │    │ (to browsers)│    │ (TCP to FTS) │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
└─────────────────────────────────────────────────────────────┘
                                                  ↓ TCP
                                           FTS CoT port (:8087)
```

---

## File Structure

```
lib/
  cotview.py          # Main server (HTTP + WebSocket + CoT client)
  cotview.html        # Single-page Leaflet app (embedded or separate)
```

---

## cotview.py Specification

### Dependencies

Standard library only for core functionality:
- `socket` — TCP connection to FTS
- `asyncio` — Event loop, concurrent tasks
- `http.server` or `aiohttp` — HTTP serving
- `xml.etree.ElementTree` — CoT XML parsing

Optional (for WebSocket, pick one):
- `websockets` library (pip install websockets) — cleanest option
- OR pure HTTP polling fallback if we want zero deps

**Recommendation:** Use `websockets` — it's a single pure-Python package, well-maintained, and makes the browser side trivial.

### CLI Arguments

```
--host HOST           FTS host to connect to (default: 127.0.0.1)
--port PORT           FTS CoT port (default: 8087)
--http-port PORT      HTTP/WebSocket port to serve on (default: 8000)
--http-bind ADDR      Address to bind HTTP server (default: 0.0.0.0)
--center-lat LAT      Initial map center latitude
--center-lon LON      Initial map center longitude
--center-zoom ZOOM    Initial map zoom level (default: 15)
--stale-seconds SEC   Remove markers after this many seconds without update (default: 300)
--verbose             Log CoT events to stdout
```

### CoT Client Task

```python
async def cot_client(host, port, track_store, broadcast_fn):
    """
    Connect to FTS CoT port, read XML events, parse, update track_store,
    broadcast to WebSocket clients.
    """
    while True:
        try:
            reader, writer = await asyncio.open_connection(host, port)
            log(f"Connected to {host}:{port}")
            buffer = ""
            while True:
                data = await reader.read(4096)
                if not data:
                    break
                buffer += data.decode('utf-8', errors='replace')
                # CoT events are newline-delimited or </event> delimited
                while '</event>' in buffer:
                    end = buffer.index('</event>') + len('</event>')
                    event_xml = buffer[:end].strip()
                    buffer = buffer[end:].lstrip()
                    if event_xml.startswith('<event'):
                        track = parse_cot_event(event_xml)
                        if track:
                            track_store[track['uid']] = track
                            await broadcast_fn(track)
        except Exception as e:
            log(f"CoT connection error: {e}, reconnecting in 3s...")
            await asyncio.sleep(3)
```

### CoT Parsing

```python
def parse_cot_event(xml_str: str) -> dict | None:
    """
    Parse a CoT XML event into a track dict.

    Returns:
        {
            'uid': str,
            'callsign': str,
            'lat': float,
            'lon': float,
            'alt': float,
            'type': str,        # CoT type (a-f-G-U-C, etc.)
            'team': str | None, # from <group name="...">
            'color': str | None,# from <color argb="...">
            'stale': str,       # ISO timestamp
            'updated': float,   # time.time() when received
        }
    Returns None if parsing fails or required fields missing.
    """
    try:
        root = ET.fromstring(xml_str)
        if root.tag != 'event':
            return None

        point = root.find('point')
        if point is None:
            return None

        uid = root.get('uid', '')
        cot_type = root.get('type', 'a-u-G')
        stale = root.get('stale', '')

        lat = float(point.get('lat', 0))
        lon = float(point.get('lon', 0))
        alt = float(point.get('hae', 0))

        # Ignore invalid coordinates
        if lat == 0 and lon == 0:
            return None

        detail = root.find('detail')
        callsign = uid
        team = None
        color = None

        if detail is not None:
            contact = detail.find('contact')
            if contact is not None:
                callsign = contact.get('callsign', uid)

            group = detail.find('group')
            if group is not None:
                team = group.get('name')

            color_el = detail.find('color')
            if color_el is not None:
                color = color_el.get('argb')

        return {
            'uid': uid,
            'callsign': callsign,
            'lat': lat,
            'lon': lon,
            'alt': alt,
            'type': cot_type,
            'team': team,
            'color': color,
            'stale': stale,
            'updated': time.time(),
        }
    except Exception:
        return None
```

### CoT Type to Marker Style

```python
def cot_type_to_style(cot_type: str) -> dict:
    """
    Convert CoT type string to marker style.

    CoT type format: a-{affiliation}-{battle_dimension}-{function}...

    Affiliations:
        f = friendly (blue)
        h = hostile (red)
        n = neutral (green)
        u = unknown (yellow)

    Returns: {'color': '#hex', 'icon': 'emoji_or_name'}
    """
    parts = cot_type.split('-')
    affiliation = parts[1] if len(parts) > 1 else 'u'

    colors = {
        'f': '#4A90D9',  # friendly - blue
        'h': '#D94A4A',  # hostile - red
        'n': '#4AD94A',  # neutral - green
        'u': '#D9D94A',  # unknown - yellow
        'a': '#D9D94A',  # assumed - yellow
        'p': '#A64AD9',  # pending - purple
        's': '#4AD9D9',  # suspect - cyan
    }

    icons = {
        'f': '🔵',
        'h': '🔴',
        'n': '🟢',
        'u': '🟡',
    }

    return {
        'color': colors.get(affiliation, '#888888'),
        'icon': icons.get(affiliation, '⚪'),
    }
```

### HTTP + WebSocket Server

```python
async def main():
    track_store = {}  # uid -> track dict
    websocket_clients = set()

    async def broadcast(track):
        """Send track update to all connected browsers."""
        msg = json.dumps({'type': 'update', 'track': track})
        dead = set()
        for ws in websocket_clients:
            try:
                await ws.send(msg)
            except:
                dead.add(ws)
        websocket_clients -= dead

    async def ws_handler(websocket, path):
        """Handle new WebSocket connection."""
        websocket_clients.add(websocket)
        try:
            # Send current state
            for track in track_store.values():
                await websocket.send(json.dumps({'type': 'update', 'track': track}))
            # Keep connection alive
            async for msg in websocket:
                pass  # We don't expect messages from client
        finally:
            websocket_clients.discard(websocket)

    async def http_handler(request):
        """Serve the HTML page."""
        # Return cotview.html content
        ...

    # Start CoT client task
    asyncio.create_task(cot_client(args.host, args.port, track_store, broadcast))

    # Start stale cleanup task
    asyncio.create_task(stale_cleanup(track_store, websocket_clients, args.stale_seconds))

    # Start WebSocket server
    ws_server = await websockets.serve(ws_handler, args.http_bind, args.http_port)

    # Note: websockets can also serve HTTP, or use aiohttp for both
    ...
```

### Stale Track Cleanup

```python
async def stale_cleanup(track_store, websocket_clients, stale_seconds):
    """Periodically remove stale tracks and notify clients."""
    while True:
        await asyncio.sleep(10)
        now = time.time()
        stale_uids = [
            uid for uid, track in track_store.items()
            if now - track['updated'] > stale_seconds
        ]
        for uid in stale_uids:
            del track_store[uid]
            msg = json.dumps({'type': 'remove', 'uid': uid})
            for ws in list(websocket_clients):
                try:
                    await ws.send(msg)
                except:
                    pass
```

---

## cotview.html Specification

Single HTML file with embedded CSS and JS. No build step.

### Structure

```html
<!DOCTYPE html>
<html>
<head>
    <title>CoTView</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <style>
        /* Full-screen map */
        html, body, #map { margin: 0; padding: 0; height: 100%; width: 100%; }

        /* Track count overlay */
        .track-count {
            position: absolute;
            top: 10px;
            right: 10px;
            z-index: 1000;
            background: rgba(255,255,255,0.9);
            padding: 8px 12px;
            border-radius: 4px;
            font-family: monospace;
            font-size: 14px;
        }

        /* Connection status */
        .connection-status {
            position: absolute;
            bottom: 10px;
            left: 10px;
            z-index: 1000;
            padding: 4px 8px;
            border-radius: 4px;
            font-family: monospace;
            font-size: 12px;
        }
        .connected { background: #4AD94A; color: white; }
        .disconnected { background: #D94A4A; color: white; }
    </style>
</head>
<body>
    <div id="map"></div>
    <div class="track-count">Tracks: <span id="count">0</span></div>
    <div class="connection-status disconnected" id="status">Disconnected</div>

    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
    <script>
        // Config injected by server
        const CONFIG = {
            wsUrl: 'ws://' + window.location.host + '/ws',
            centerLat: {{CENTER_LAT}},
            centerLon: {{CENTER_LON}},
            centerZoom: {{CENTER_ZOOM}},
        };

        // Initialize map
        const map = L.map('map').setView([CONFIG.centerLat, CONFIG.centerLon], CONFIG.centerZoom);
        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
            attribution: '© OpenStreetMap'
        }).addTo(map);

        // Track markers
        const markers = {};  // uid -> L.marker

        // Affiliation colors
        const COLORS = {
            'f': '#4A90D9',
            'h': '#D94A4A',
            'n': '#4AD94A',
            'u': '#D9D94A',
        };

        function getColor(cotType) {
            const parts = cotType.split('-');
            const aff = parts[1] || 'u';
            return COLORS[aff] || '#888888';
        }

        function createMarkerIcon(color) {
            return L.divIcon({
                className: 'track-marker',
                html: `<div style="
                    width: 12px;
                    height: 12px;
                    background: ${color};
                    border: 2px solid white;
                    border-radius: 50%;
                    box-shadow: 0 0 4px rgba(0,0,0,0.5);
                "></div>`,
                iconSize: [16, 16],
                iconAnchor: [8, 8],
            });
        }

        function updateTrack(track) {
            const color = getColor(track.type);
            const icon = createMarkerIcon(color);

            if (markers[track.uid]) {
                markers[track.uid].setLatLng([track.lat, track.lon]);
                markers[track.uid].setIcon(icon);
            } else {
                markers[track.uid] = L.marker([track.lat, track.lon], { icon })
                    .addTo(map)
                    .bindPopup('');
            }

            markers[track.uid].setPopupContent(`
                <b>${track.callsign}</b><br>
                UID: ${track.uid}<br>
                Type: ${track.type}<br>
                Alt: ${track.alt.toFixed(1)}m<br>
                ${track.team ? 'Team: ' + track.team + '<br>' : ''}
            `);

            document.getElementById('count').textContent = Object.keys(markers).length;
        }

        function removeTrack(uid) {
            if (markers[uid]) {
                map.removeLayer(markers[uid]);
                delete markers[uid];
            }
            document.getElementById('count').textContent = Object.keys(markers).length;
        }

        // WebSocket connection with auto-reconnect
        function connect() {
            const ws = new WebSocket(CONFIG.wsUrl);
            const statusEl = document.getElementById('status');

            ws.onopen = () => {
                statusEl.textContent = 'Connected';
                statusEl.className = 'connection-status connected';
            };

            ws.onclose = () => {
                statusEl.textContent = 'Disconnected';
                statusEl.className = 'connection-status disconnected';
                setTimeout(connect, 2000);
            };

            ws.onerror = () => ws.close();

            ws.onmessage = (event) => {
                const msg = JSON.parse(event.data);
                if (msg.type === 'update') {
                    updateTrack(msg.track);
                } else if (msg.type === 'remove') {
                    removeTrack(msg.uid);
                }
            };
        }

        connect();
    </script>
</body>
</html>
```

---

## Integration with Heartbeat

### lib/webmap.sh Replacement

Option A: Replace `webmap_start()` internals to launch `cotview.py` instead of the FTH binary.

Option B: New file `lib/cotview.sh` with parallel commands, deprecate webmap.

**Recommendation:** Option A — same user-facing commands, different backend.

### Changes to lib/webmap.sh

```bash
# Replace _webmap_bin_path, _webmap_launch, webmap_install
# with cotview equivalents

_cotview_launch() {
    local host="${COTVIEW_FTS_HOST:-127.0.0.1}"
    local port="${COTVIEW_FTS_PORT:-$COT_PORT}"
    local http_port="${WEBMAP_PORT:-8000}"
    local center_lat="${WEBMAP_VIEW_LAT:-${BEACON_LAT:-0}}"
    local center_lon="${WEBMAP_VIEW_LON:-${BEACON_LON:-0}}"
    local center_zoom="${WEBMAP_VIEW_ZOOM:-15}"

    (cd "$LIB_DIR" && nohup python3 cotview.py \
        --host "$host" \
        --port "$port" \
        --http-port "$http_port" \
        --center-lat "$center_lat" \
        --center-lon "$center_lon" \
        --center-zoom "$center_zoom" \
        >> "$WEBMAP_LOG_FILE" 2>&1) &
    echo $! > "$WEBMAP_PID_FILE"
}

webmap_install() {
    # No-op — cotview.py has no external dependencies beyond websockets
    # Could optionally check for websockets: pip show websockets
    load_config
    if [[ "${WEBMAP_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    if ! python3 -c "import websockets" 2>/dev/null; then
        log_info "Installing websockets for CoTView..."
        pip3 install --quiet websockets
    fi
}
```

### Config Variables (reuse existing)

- `WEBMAP_ENABLED` — unchanged
- `WEBMAP_PORT` — HTTP/WS port (default 8000)
- `WEBMAP_VIEW_LAT` — initial map center
- `WEBMAP_VIEW_LON` — initial map center
- `WEBMAP_VIEW_ZOOM` — initial zoom

New optional:
- `COTVIEW_FTS_HOST` — FTS host for CoT connection (default 127.0.0.1)
- `COTVIEW_FTS_PORT` — FTS CoT port (default $COT_PORT)
- `COTVIEW_STALE_SECONDS` — track stale timeout (default 300)

### Remove

- `WEBMAP_URL` — no longer downloading a binary
- `WEBMAP_VIEW_LAYER` — tile layer is hardcoded (could add back later)
- All `_webmap_patch_defaults` binary patching code
- The `data/webmap/` directory with FTH binary

---

## Verification

```bash
# 1. Start server
./heartbeat start

# 2. Check CoTView is running
curl -s http://localhost:8000 | head -5
# Should return HTML

# 3. Open browser
xdg-open http://localhost:8000

# 4. Connect a phone to FTS — marker should appear on map

# 5. Check WebSocket
# Browser console: WebSocket should show "Connected"

# 6. Stop and verify cleanup
./heartbeat stop
ps aux | grep cotview  # nothing
```

---

## Implementation Order

1. **cotview.py** — CoT client + WebSocket broadcast (~150 lines)
2. **cotview.html** — Leaflet map + WS client (~100 lines)
3. **Integrate into lib/webmap.sh** — replace FTH launch with cotview launch
4. **Remove FTH code** — delete binary patching, download logic, Node-RED cleanup
5. **Test end-to-end** — phone → FTS → cotview → browser

---

## Why This is Better

| | FreeTAKHub WebMap | CoTView |
|---|---|---|
| Lines of code | Unknown (compiled binary) | ~300 Python + 150 JS |
| Debuggable | No | Yes |
| Dependencies | Node-RED runtime embedded | `websockets` (1 pip package) |
| CoT parsing | Fragile (patched function node) | Simple XML parsing |
| Connection handling | Race conditions, stale config | Reconnect loop, live state |
| Browser push | Unknown mechanism | Standard WebSocket |
| Customizable | Requires binary patching | Edit Python/HTML |
