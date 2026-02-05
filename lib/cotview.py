#!/usr/bin/env python3
import argparse
import asyncio
import json
import time
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from http import HTTPStatus

import websockets

try:
    from websockets.http11 import Response, Headers
except Exception:  # pragma: no cover - fallback for older websockets
    Response = None
    Headers = None


def log(message):
    print(f"[cotview] {message}", flush=True)


def _strip_ns(tag):
    if "}" in tag:
        return tag.rsplit("}", 1)[-1]
    return tag


def _find_child(elem, name):
    for child in list(elem):
        if _strip_ns(child.tag) == name:
            return child
    return None


def parse_cot_event(xml_str):
    try:
        root = ET.fromstring(xml_str)
        if _strip_ns(root.tag) != "event":
            return None

        point = _find_child(root, "point")
        if point is None:
            return None

        uid = root.get("uid", "").strip()
        cot_type = root.get("type", "a-u-G")
        stale = root.get("stale", "")

        try:
            lat = float(point.get("lat", 0))
            lon = float(point.get("lon", 0))
            alt = float(point.get("hae", 0))
        except (TypeError, ValueError):
            return None

        if lat == 0 and lon == 0:
            return None

        detail = _find_child(root, "detail")
        callsign = uid or "unknown"
        team = None
        color = None

        if detail is not None:
            contact = _find_child(detail, "contact")
            if contact is not None:
                callsign = contact.get("callsign", callsign)

            group = _find_child(detail, "group")
            if group is not None:
                team = group.get("name")

            color_el = _find_child(detail, "color")
            if color_el is not None:
                color = color_el.get("argb")

        if not uid:
            uid = callsign

        return {
            "uid": uid,
            "callsign": callsign,
            "lat": lat,
            "lon": lon,
            "alt": alt,
            "type": cot_type,
            "team": team,
            "color": color,
            "stale": stale,
            "updated": time.time(),
        }
    except Exception:
        return None


def load_html_template(center_lat, center_lon, center_zoom):
    html_path = Path(__file__).with_name("cotview.html")
    if not html_path.exists():
        raise FileNotFoundError(f"Missing cotview.html at {html_path}")

    html = html_path.read_text(encoding="utf-8")
    html = html.replace("{{CENTER_LAT}}", f"{center_lat:.6f}")
    html = html.replace("{{CENTER_LON}}", f"{center_lon:.6f}")
    html = html.replace("{{CENTER_ZOOM}}", str(center_zoom))
    return html


def http_response(status, body, content_type="text/plain; charset=utf-8"):
    body_bytes = body if isinstance(body, (bytes, bytearray)) else body.encode("utf-8")
    if Response is not None and Headers is not None:
        status_obj = HTTPStatus(status)
        headers = Headers()
        headers["Content-Type"] = content_type
        headers["Content-Length"] = str(len(body_bytes))
        headers["Cache-Control"] = "no-store"
        return Response(status_obj.value, status_obj.phrase, headers, body_bytes)
    return status, [("Content-Type", content_type), ("Content-Length", str(len(body_bytes)))], body_bytes


def make_process_request(html_body_bytes):
    def process_request(*args):
        path = None

        if len(args) == 2:
            if isinstance(args[0], str):
                path = args[0]
            else:
                request = args[1]
                path = getattr(request, "path", None)
        elif len(args) == 1:
            path = getattr(args[0], "path", None)

        if not path:
            return None

        if path.startswith("/ws"):
            return None

        route = path.split("?", 1)[0]
        if route in ("/", "/index.html", "/cotview.html"):
            return http_response(200, html_body_bytes, "text/html; charset=utf-8")

        return http_response(404, "Not found")

    return process_request


def build_hello_event(uid, callsign):
    now = time.time()
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    stale = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + 60))
    return (
        f'<event version="2.0" uid="{uid}" type="t-x-c-t" how="m-g" '
        f'time="{ts}" start="{ts}" stale="{stale}">'
        '<point lat="0" lon="0" hae="0" ce="9999999.0" le="9999999.0"/>'
        f'<detail><contact callsign="{callsign}"/></detail>'
        '</event>\n'
    )


async def cot_client(host, port, track_store, broadcast_fn, hello_interval, verbose=False):
    while True:
        try:
            reader, writer = await asyncio.open_connection(host, port)
            log(f"Connected to CoT stream at {host}:{port}")

            hello_uid = f"cotview-{uuid.uuid4()}"
            hello_callsign = "CoTView"

            async def hello_sender():
                while True:
                    msg = build_hello_event(hello_uid, hello_callsign)
                    writer.write(msg.encode("utf-8"))
                    await writer.drain()
                    await asyncio.sleep(hello_interval)

            hello_task = asyncio.create_task(hello_sender())
            buffer = ""
            while True:
                data = await reader.read(4096)
                if not data:
                    break
                buffer += data.decode("utf-8", errors="replace")
                while "</event>" in buffer:
                    end = buffer.index("</event>") + len("</event>")
                    event_xml = buffer[:end].strip()
                    buffer = buffer[end:].lstrip()
                    if event_xml.startswith("<event"):
                        track = parse_cot_event(event_xml)
                        if track:
                            track_store[track["uid"]] = track
                            if verbose:
                                log(f"CoT update {track['uid']} {track['callsign']} {track['lat']:.6f},{track['lon']:.6f}")
                            await broadcast_fn(track)
            hello_task.cancel()
            try:
                await hello_task
            except Exception:
                pass
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass
        except Exception as exc:
            log(f"CoT connection error: {exc}. Reconnecting in 3s...")
            await asyncio.sleep(3)


async def stale_cleanup(track_store, websocket_clients, stale_seconds):
    while True:
        await asyncio.sleep(10)
        now = time.time()
        stale_uids = [
            uid for uid, track in track_store.items()
            if now - track["updated"] > stale_seconds
        ]
        if not stale_uids:
            continue
        for uid in stale_uids:
            track_store.pop(uid, None)
            msg = json.dumps({"type": "remove", "uid": uid}, separators=(",", ":"))
            for ws in list(websocket_clients):
                try:
                    await ws.send(msg)
                except Exception:
                    websocket_clients.discard(ws)


async def main():
    parser = argparse.ArgumentParser(description="CoTView - Lightweight CoT Web Viewer")
    parser.add_argument("--host", default="127.0.0.1", help="FTS host to connect to")
    parser.add_argument("--port", type=int, default=8087, help="FTS CoT port")
    parser.add_argument("--http-port", type=int, default=8000, help="HTTP/WebSocket port to serve on")
    parser.add_argument("--http-bind", default="0.0.0.0", help="Address to bind HTTP server")
    parser.add_argument("--center-lat", type=float, default=0.0, help="Initial map center latitude")
    parser.add_argument("--center-lon", type=float, default=0.0, help="Initial map center longitude")
    parser.add_argument("--center-zoom", type=int, default=15, help="Initial map zoom level")
    parser.add_argument("--stale-seconds", type=int, default=300, help="Remove markers after this many seconds")
    parser.add_argument("--hello-interval", type=int, default=5, help="Send CoT hello every N seconds")
    parser.add_argument("--verbose", action="store_true", help="Log CoT events to stdout")
    args = parser.parse_args()

    track_store = {}
    websocket_clients = set()

    html_body = load_html_template(args.center_lat, args.center_lon, args.center_zoom).encode("utf-8")
    process_request = make_process_request(html_body)

    async def broadcast(track):
        msg = json.dumps({"type": "update", "track": track}, separators=(",", ":"))
        dead = []
        for ws in list(websocket_clients):
            try:
                await ws.send(msg)
            except Exception:
                dead.append(ws)
        for ws in dead:
            websocket_clients.discard(ws)

    async def ws_handler(*args):
        if len(args) == 1:
            websocket = args[0]
        else:
            websocket = args[0]
        websocket_clients.add(websocket)
        try:
            for track in list(track_store.values()):
                await websocket.send(json.dumps({"type": "update", "track": track}, separators=(",", ":")))
            async for _msg in websocket:
                pass
        finally:
            websocket_clients.discard(websocket)

    asyncio.create_task(
        cot_client(
            args.host,
            args.port,
            track_store,
            broadcast,
            hello_interval=args.hello_interval,
            verbose=args.verbose,
        )
    )
    asyncio.create_task(stale_cleanup(track_store, websocket_clients, args.stale_seconds))

    log(f"Serving HTTP/WebSocket on {args.http_bind}:{args.http_port}")
    async with websockets.serve(ws_handler, args.http_bind, args.http_port, process_request=process_request):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
