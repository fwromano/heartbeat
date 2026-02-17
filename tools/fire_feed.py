#!/usr/bin/env python3
"""
Wildcard fire incident feed -> TAK CoT injector.
"""

import argparse
import http.cookiejar
import html
import json
import logging
import math
import os
import signal
import sys
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

# Add tools/ to path so we can import sibling modules.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tak_client import TakClient


INCIDENTS_URL = (
    "https://services9.arcgis.com/RHVPKKiFTONKtxq3/arcgis/rest/services/"
    "USA_Wildfires_v1/FeatureServer/0/query"
)


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def iso_future(minutes=20):
    t = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    return t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def safe_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def clean_uid_component(value):
    cleaned = "".join(ch if (ch.isalnum() or ch in "-_.") else "-" for ch in value)
    cleaned = cleaned.strip("-_.")
    return cleaned or "unknown"


class FireFeed:
    def __init__(
        self,
        client,
        bbox,
        interval,
        log_path,
        auto_bbox_url="",
        auto_bbox_user="",
        auto_bbox_password="",
        auto_bbox_range_km=100,
    ):
        self.client = client
        self.bbox = (bbox or "").strip()
        self.interval = max(int(interval), 1)
        self.auto_bbox_url = (auto_bbox_url or "").strip().rstrip("/")
        self.auto_bbox_user = auto_bbox_user or ""
        self.auto_bbox_password = auto_bbox_password or ""
        self.auto_bbox_range_km = max(float(auto_bbox_range_km), 1.0)
        self.auto_bbox_enabled = bool(self.auto_bbox_url and not self.bbox)
        self._auto_bbox_fail_logged = False
        self._auto_bbox_logged_once = False
        self._api_logged_in = False
        self._api_cookie_jar = None
        self._api_opener = None
        self.running = True

        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s [%(levelname)s] %(message)s",
            handlers=[logging.FileHandler(log_path)],
        )
        self.log = logging.getLogger("fire_feed")

    def stop(self, signum=None, frame=None):
        self.log.info("Shutdown signal received")
        self.running = False
        self.client.close()

    def _bbox_params(self, bbox_value):
        if not bbox_value:
            return {}
        parts = [p.strip() for p in bbox_value.split(",")]
        if len(parts) != 4:
            raise ValueError(
                "Invalid --bbox. Expected: lon_min,lat_min,lon_max,lat_max"
            )
        coords = [str(float(p)) for p in parts]
        return {
            "geometry": ",".join(coords),
            "geometryType": "esriGeometryEnvelope",
            "spatialRel": "esriSpatialRelIntersects",
        }

    def _build_api_opener(self):
        if self._api_opener:
            return self._api_opener
        self._api_cookie_jar = http.cookiejar.CookieJar()
        self._api_opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self._api_cookie_jar)
        )
        return self._api_opener

    def _api_request(self, method, path, payload=None):
        opener = self._build_api_opener()
        url = f"{self.auto_bbox_url}{path}"
        data = None
        headers = {"User-Agent": "heartbeat-fire-feed/1.0"}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with opener.open(req, timeout=15) as resp:
            body = resp.read().decode("utf-8", errors="replace")
        if not body:
            return {}
        return json.loads(body)

    def _ensure_api_login(self):
        if self._api_logged_in:
            return
        if not (self.auto_bbox_user and self.auto_bbox_password):
            return
        try:
            self._api_request(
                "POST",
                "/login",
                {"username": self.auto_bbox_user, "password": self.auto_bbox_password},
            )
            self._api_logged_in = True
        except Exception as e:
            raise RuntimeError(f"OTS login failed: {e}") from e

    def _extract_points(self, payload):
        candidates = []

        def _yield_items(node):
            if isinstance(node, list):
                for item in node:
                    yield item
            elif isinstance(node, dict):
                for key in ("data", "points", "items", "results", "records"):
                    child = node.get(key)
                    if isinstance(child, list):
                        for item in child:
                            yield item
                yield node

        def _maybe_lat_lon(item):
            if not isinstance(item, dict):
                return None

            lat = safe_float(item.get("lat"))
            lon = safe_float(item.get("lon"))
            if lat is not None and lon is not None:
                return (lat, lon)

            lat = safe_float(item.get("latitude"))
            lon = safe_float(item.get("longitude"))
            if lat is not None and lon is not None:
                return (lat, lon)

            point = item.get("point")
            if isinstance(point, dict):
                lat = safe_float(point.get("lat"))
                lon = safe_float(point.get("lon"))
                if lat is not None and lon is not None:
                    return (lat, lon)
            elif isinstance(point, str):
                parts = [p.strip() for p in point.split(",")]
                if len(parts) >= 2:
                    lat = safe_float(parts[0])
                    lon = safe_float(parts[1])
                    if lat is not None and lon is not None:
                        return (lat, lon)

            location = item.get("location")
            if isinstance(location, dict):
                lat = safe_float(location.get("lat"))
                lon = safe_float(location.get("lon"))
                if lat is not None and lon is not None:
                    return (lat, lon)

            return None

        for entry in _yield_items(payload):
            coord = _maybe_lat_lon(entry)
            if coord:
                candidates.append(coord)

        return candidates

    def auto_bbox(self):
        if not self.auto_bbox_enabled:
            return None
        try:
            self._ensure_api_login()
            payload = self._api_request("GET", "/point?limit=100")
            points = self._extract_points(payload)
            if not points:
                return None

            avg_lat = sum(lat for lat, _ in points) / len(points)
            avg_lon = sum(lon for _, lon in points) / len(points)

            range_km = self.auto_bbox_range_km
            delta_lat = range_km / 111.32
            cos_lat = max(abs(math.cos(math.radians(avg_lat))), 0.1)
            delta_lon = range_km / (111.32 * cos_lat)

            lat_min = max(-90.0, avg_lat - delta_lat)
            lat_max = min(90.0, avg_lat + delta_lat)
            lon_min = max(-180.0, avg_lon - delta_lon)
            lon_max = min(180.0, avg_lon + delta_lon)

            return f"{lon_min:.6f},{lat_min:.6f},{lon_max:.6f},{lat_max:.6f}"
        except Exception as e:
            raise RuntimeError(f"auto-bbox failed: {e}") from e

    def poll_incidents(self, bbox_override=""):
        params = {
            "where": "1=1",
            "outFields": (
                "IncidentName,DailyAcres,PercentContained,FireDiscoveryDateTime,"
                "POOState,POOCounty,GACC,TotalIncidentPersonnel,FireMgmtComplexity,"
                "FireCause,PredominantFuelGroup,UniqueFireIdentifier,IRWINID,OBJECTID"
            ),
            "f": "geojson",
            "resultRecordCount": 2000,
        }
        params.update(self._bbox_params(bbox_override or self.bbox))

        query = urllib.parse.urlencode(params)
        req = urllib.request.Request(
            f"{INCIDENTS_URL}?{query}",
            headers={"User-Agent": "heartbeat-fire-feed/1.0"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return data.get("features", [])

    def feature_to_cot(self, feature):
        props = feature.get("properties") or {}
        geom = feature.get("geometry") or {}
        coords = geom.get("coordinates") or []
        if len(coords) < 2:
            raise ValueError("missing incident coordinates")

        lon = safe_float(coords[0])
        lat = safe_float(coords[1])
        if lat is None or lon is None:
            raise ValueError("invalid incident coordinates")

        incident_id = (
            props.get("UniqueFireIdentifier")
            or props.get("IRWINID")
            or props.get("OBJECTID")
            or f"{lat:.5f}-{lon:.5f}"
        )
        uid = f"fire-incident-{clean_uid_component(str(incident_id))}"

        name = str(props.get("IncidentName") or "Unknown Fire")
        acres = safe_float(props.get("DailyAcres"))
        acres_str = f"{acres:.0f}" if acres is not None else "?"

        contained = safe_float(props.get("PercentContained"))
        contained_str = f"{contained:.0f}%" if contained is not None else "N/A"

        state = str(props.get("POOState") or "").replace("US-", "")
        cause = str(props.get("FireCause") or "")
        personnel = props.get("TotalIncidentPersonnel")
        personnel_str = f"{personnel}" if personnel not in (None, "") else ""

        remarks = f"{name} | {acres_str} ac | {contained_str} contained"
        if state:
            remarks += f" | {state}"
        if cause:
            remarks += f" | {cause}"
        if personnel_str:
            remarks += f" | {personnel_str} personnel"

        now = iso_now()
        stale = iso_future(20)
        escaped_name = html.escape(name, quote=True)
        escaped_remarks = html.escape(remarks, quote=True)

        return (
            '<?xml version="1.0" encoding="UTF-8"?>'
            f'<event version="2.0" uid="{uid}" type="a-h-G"'
            f' time="{now}" start="{now}" stale="{stale}" how="m-g">'
            f'<point lat="{lat}" lon="{lon}" hae="0" ce="9999999" le="9999999"/>'
            f"<detail>"
            f'<contact callsign="{escaped_name}"/>'
            f"<remarks>{escaped_remarks}</remarks>"
            f'<usericon iconsetpath="34ae1613-9645-4222-a9d2-e5f243dea2865/Military/fire.png"/>'
            f"</detail>"
            f"</event>"
        )

    def _sleep_interval(self):
        # Sleep in 1-second slices so SIGTERM is responsive.
        for _ in range(self.interval):
            if not self.running:
                break
            time.sleep(1)

    def run(self):
        while self.running:
            try:
                self.client.connect()
                while self.running:
                    effective_bbox = self.bbox
                    if not self.bbox and self.auto_bbox_enabled:
                        try:
                            effective_bbox = self.auto_bbox() or ""
                            if effective_bbox:
                                self._auto_bbox_fail_logged = False
                                if not self._auto_bbox_logged_once:
                                    self.log.info(
                                        "Auto-bbox enabled (range=%.1fkm)",
                                        self.auto_bbox_range_km,
                                    )
                                    self._auto_bbox_logged_once = True
                            elif not self._auto_bbox_fail_logged:
                                self.log.warning(
                                    "Auto-bbox found no team points; polling nationwide until positions appear"
                                )
                                self._auto_bbox_fail_logged = True
                        except Exception as e:
                            if not self._auto_bbox_fail_logged:
                                self.log.warning("%s", e)
                                self._auto_bbox_fail_logged = True
                            effective_bbox = ""

                    try:
                        features = self.poll_incidents(bbox_override=effective_bbox)
                    except Exception as e:
                        self.log.warning("ArcGIS poll failed: %s", e)
                        features = []

                    sent = 0
                    for feature in features:
                        if not self.running:
                            break
                        try:
                            cot = self.feature_to_cot(feature)
                            self.client.send(cot)
                            sent += 1
                        except Exception as e:
                            self.log.debug("Skipping malformed incident feature: %s", e)

                    self.log.info("Polled %d incidents, sent %d CoT events", len(features), sent)

                    try:
                        self.client.send_keepalive()
                    except OSError:
                        raise

                    self._sleep_interval()
            except (ConnectionError, OSError, RuntimeError) as e:
                if self.running:
                    self.log.warning("Connection error: %s, retrying in 10s", e)
                    time.sleep(10)
            finally:
                self.client.close()

        self.log.info("Fire feed stopped")


def main():
    parser = argparse.ArgumentParser(description="Heartbeat fire incident CoT feed")
    parser.add_argument("--host", default="127.0.0.1", help="TAK server host")
    parser.add_argument("--port", type=int, default=8087, help="TAK CoT port")
    parser.add_argument("--ssl", action="store_true", help="Use TLS with client certificate")
    parser.add_argument("--cert", default="", help="Client certificate PEM path")
    parser.add_argument("--key", default="", help="Client private key PEM path")
    parser.add_argument("--ca", default="", help="CA certificate PEM path")
    parser.add_argument(
        "--bbox",
        default="",
        help="Optional bbox filter: lon_min,lat_min,lon_max,lat_max",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=900,
        help="Poll interval in seconds (default: 900)",
    )
    parser.add_argument(
        "--auto-bbox-url",
        default="",
        help="OTS API base URL (example: http://127.0.0.1:8081/api)",
    )
    parser.add_argument(
        "--auto-bbox-user",
        default="",
        help="OTS username for auto-bbox API queries",
    )
    parser.add_argument(
        "--auto-bbox-password",
        default="",
        help="OTS password for auto-bbox API queries",
    )
    parser.add_argument(
        "--auto-bbox-range-km",
        type=float,
        default=100.0,
        help="Auto-bbox radius in km around team centroid (default: 100)",
    )
    parser.add_argument("--log", default="data/fire_feed.log", help="Log file path")
    args = parser.parse_args()

    client = TakClient(
        host=args.host,
        port=args.port,
        callsign="HB-FIRE-FEED",
        uid=f"heartbeat-fire-feed-{uuid.uuid4()}",
        use_ssl=args.ssl,
        cert_path=args.cert or None,
        key_path=args.key or None,
        ca_path=args.ca or None,
        platform="heartbeat",
        device="server",
        role="HQ",
        team="Cyan",
    )
    feed = FireFeed(
        client=client,
        bbox=args.bbox,
        interval=args.interval,
        log_path=args.log,
        auto_bbox_url=args.auto_bbox_url,
        auto_bbox_user=args.auto_bbox_user,
        auto_bbox_password=args.auto_bbox_password,
        auto_bbox_range_km=args.auto_bbox_range_km,
    )

    signal.signal(signal.SIGTERM, feed.stop)
    signal.signal(signal.SIGINT, feed.stop)

    feed.run()


if __name__ == "__main__":
    main()
