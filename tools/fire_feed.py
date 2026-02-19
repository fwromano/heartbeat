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
PERIMETERS_URL = (
    "https://services9.arcgis.com/RHVPKKiFTONKtxq3/arcgis/rest/services/"
    "USA_Wildfires_v1/FeatureServer/1/query"
)

# Coarse Texas outline that is densified to 100 points for region filtering.
TEXAS_REGION_BASE_COORDS = [
    (-106.645646, 31.895754),
    (-104.990322, 31.799532),
    (-103.066650, 31.783148),
    (-103.066650, 36.500704),
    (-100.000381, 36.500704),
    (-100.000381, 34.563278),
    (-99.063713, 34.563278),
    (-98.000000, 34.530000),
    (-97.140000, 33.840000),
    (-95.900000, 33.890000),
    (-94.430000, 33.620000),
    (-94.043147, 33.019543),
    (-94.483841, 31.001490),
    (-93.508292, 30.005611),
    (-93.700000, 29.760000),
    (-94.260000, 29.410000),
    (-94.670000, 28.950000),
    (-95.090000, 28.780000),
    (-95.810000, 28.300000),
    (-96.310000, 28.140000),
    (-96.560000, 27.730000),
    (-97.230000, 26.060000),
    (-97.420000, 25.840000),
    (-97.520000, 26.510000),
    (-98.130000, 26.980000),
    (-99.170000, 27.500000),
    (-99.520000, 27.860000),
    (-100.100000, 28.190000),
    (-100.800000, 28.650000),
    (-101.420000, 29.500000),
    (-102.480000, 29.770000),
    (-103.070000, 29.370000),
    (-104.590000, 29.560000),
    (-106.645646, 31.895754),
]

REGION_BOUNDARIES = {"texas": TEXAS_REGION_BASE_COORDS}
REGION_ALIASES = {"tx": "texas"}


def densify_closed_ring(coords, target_points=100):
    """
    Return a closed ring with approximately target_points vertices.
    """
    if not coords:
        return []

    ring = list(coords)
    if ring[0] != ring[-1]:
        ring.append(ring[0])

    target_points = max(int(target_points), len(ring))
    segment_lengths = []
    total_length = 0.0
    for idx in range(len(ring) - 1):
        x1, y1 = ring[idx]
        x2, y2 = ring[idx + 1]
        length = math.hypot(x2 - x1, y2 - y1)
        segment_lengths.append(length)
        total_length += length

    if total_length <= 0.0:
        return ring

    samples = max(target_points - 1, 1)
    out = []
    for sample_idx in range(samples):
        distance = (total_length * sample_idx) / samples
        traversed = 0.0
        for idx, seg_len in enumerate(segment_lengths):
            start = ring[idx]
            end = ring[idx + 1]
            if seg_len <= 0.0:
                continue
            if traversed + seg_len >= distance:
                ratio = (distance - traversed) / seg_len
                x = start[0] + ((end[0] - start[0]) * ratio)
                y = start[1] + ((end[1] - start[1]) * ratio)
                out.append((x, y))
                break
            traversed += seg_len
        else:
            out.append(ring[-1])

    if out and out[0] != out[-1]:
        out.append(out[0])
    return out


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
        region,
        interval,
        log_path,
        auto_bbox_url="",
        auto_bbox_user="",
        auto_bbox_password="",
        auto_bbox_range_km=100,
        include_perimeters=False,
        perimeter_simplify=0.001,
        perimeter_max_vertices=250,
    ):
        self.client = client
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s [%(levelname)s] %(message)s",
            handlers=[logging.FileHandler(log_path)],
        )
        self.log = logging.getLogger("fire_feed")

        self.bbox = (bbox or "").strip()
        self.region = (region or "").strip().lower()
        self.interval = max(int(interval), 1)
        self.auto_bbox_url = (auto_bbox_url or "").strip().rstrip("/")
        self.auto_bbox_user = auto_bbox_user or ""
        self.auto_bbox_password = auto_bbox_password or ""
        self.auto_bbox_range_km = max(float(auto_bbox_range_km), 1.0)
        self.auto_bbox_enabled = bool(self.auto_bbox_url and not self.bbox and not self.region)
        self._auto_bbox_fail_logged = False
        self._auto_bbox_logged_once = False
        self._api_logged_in = False
        self._api_cookie_jar = None
        self._api_opener = None
        self.include_perimeters = bool(include_perimeters)
        self.perimeter_simplify = max(float(perimeter_simplify), 0.0)
        self.perimeter_max_vertices = max(int(perimeter_max_vertices), 16)
        self._bbox_bounds = self._parse_bbox_bounds(self.bbox)
        self._region_name, self._region_polygon, self._region_bounds = self._build_region_filter(
            self.region
        )
        self._region_box = None
        if self._region_bounds is not None:
            try:
                from shapely.geometry import box

                self._region_box = box(*self._region_bounds)
            except Exception:
                self._region_box = None
        if self._region_name:
            self.log.info("Region filter enabled: %s", self._region_name)
        self._perimeter_shapely_unavailable_logged = False
        self.running = True

    def stop(self, signum=None, frame=None):
        self.log.info("Shutdown signal received")
        self.running = False
        self.client.close()

    def _parse_bbox_bounds(self, bbox_value):
        if not bbox_value:
            return None
        try:
            lon_min, lat_min, lon_max, lat_max = [float(p.strip()) for p in bbox_value.split(",")]
        except Exception:
            self.log.warning(
                "Invalid bbox '%s' for perimeter clipping; expected lon_min,lat_min,lon_max,lat_max",
                bbox_value,
            )
            return None
        return (min(lon_min, lon_max), min(lat_min, lat_max), max(lon_min, lon_max), max(lat_min, lat_max))

    def _point_in_bbox(self, lat, lon):
        if self._bbox_bounds is None:
            return True
        lon_min, lat_min, lon_max, lat_max = self._bbox_bounds
        return lon_min <= lon <= lon_max and lat_min <= lat <= lat_max

    def _build_region_filter(self, region_value):
        if not region_value:
            return "", None, None

        normalized = REGION_ALIASES.get(region_value, region_value)
        base_coords = REGION_BOUNDARIES.get(normalized)
        if not base_coords:
            self.log.warning(
                "Unsupported region '%s'; expected one of: %s",
                region_value,
                ", ".join(sorted(REGION_BOUNDARIES.keys())),
            )
            return "", None, None

        ring = densify_closed_ring(base_coords, target_points=100)
        lons = [lon for lon, _ in ring]
        lats = [lat for _, lat in ring]
        bounds = (min(lons), min(lats), max(lons), max(lats))

        try:
            from shapely.geometry import Polygon

            polygon = Polygon(ring)
            if not polygon.is_valid:
                polygon = polygon.buffer(0)
            if polygon.is_empty:
                raise ValueError("empty polygon after cleanup")
            return normalized, polygon, bounds
        except Exception as e:
            self.log.warning(
                "Region '%s' using bbox-only fallback (shapely unavailable: %s)",
                normalized,
                e,
            )
            return normalized, None, bounds

    def _point_in_region(self, lat, lon):
        if self._region_bounds is None:
            return True

        lon_min, lat_min, lon_max, lat_max = self._region_bounds
        if not (lon_min <= lon <= lon_max and lat_min <= lat <= lat_max):
            return False
        if self._region_polygon is None:
            return True

        try:
            from shapely.geometry import Point

            return bool(self._region_polygon.covers(Point(lon, lat)))
        except Exception:
            return True

    def _point_in_scope(self, lat, lon):
        return self._point_in_bbox(lat, lon) and self._point_in_region(lat, lon)

    def _incident_in_scope(self, feature):
        geom = feature.get("geometry") or {}
        coords = geom.get("coordinates") or []
        if len(coords) < 2:
            return False
        lon = safe_float(coords[0])
        lat = safe_float(coords[1])
        if lat is None or lon is None:
            return False
        return self._point_in_scope(lat, lon)

    def _perimeter_intersects_scope(self, feature):
        geometry = feature.get("geometry") or {}

        try:
            from shapely.geometry import box, shape

            geom = shape(geometry)
            if geom.is_empty:
                return False

            if self._bbox_bounds is not None:
                bbox_geom = box(*self._bbox_bounds)
                if not geom.intersects(bbox_geom):
                    return False

            if self._region_polygon is not None:
                return bool(geom.intersects(self._region_polygon))
            if self._region_box is not None:
                return bool(geom.intersects(self._region_box))
            return True
        except Exception:
            vertices = self._shape_coords_fallback(geometry)
            for point in vertices:
                if len(point) < 2:
                    continue
                lon = safe_float(point[0])
                lat = safe_float(point[1])
                if lat is None or lon is None:
                    continue
                if self._point_in_scope(lat, lon):
                    return True
            return False

    def _region_bbox_str(self):
        if self._region_bounds is None:
            return ""
        lon_min, lat_min, lon_max, lat_max = self._region_bounds
        return f"{lon_min:.6f},{lat_min:.6f},{lon_max:.6f},{lat_max:.6f}"

    def _intersect_bounds(self, a_bounds, b_bounds):
        if a_bounds is None:
            return b_bounds
        if b_bounds is None:
            return a_bounds

        lon_min = max(a_bounds[0], b_bounds[0])
        lat_min = max(a_bounds[1], b_bounds[1])
        lon_max = min(a_bounds[2], b_bounds[2])
        lat_max = min(a_bounds[3], b_bounds[3])
        if lon_min >= lon_max or lat_min >= lat_max:
            return None
        return (lon_min, lat_min, lon_max, lat_max)

    def _format_bounds(self, bounds):
        if bounds is None:
            return ""
        lon_min, lat_min, lon_max, lat_max = bounds
        return f"{lon_min:.6f},{lat_min:.6f},{lon_max:.6f},{lat_max:.6f}"

    def _query_bbox(self, bbox_value):
        bbox_bounds = self._parse_bbox_bounds(bbox_value)
        query_bounds = self._intersect_bounds(bbox_bounds, self._region_bounds)
        if query_bounds is None and (bbox_bounds is not None or self._region_bounds is not None):
            return "__empty__"
        if query_bounds is not None:
            return self._format_bounds(query_bounds)
        return bbox_value

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

    def poll_perimeters(self, bbox_override=""):
        params = {
            "where": "1=1",
            "outFields": "IncidentName,GISAcres,DateCurrent,IRWINID,FeatureCategory,OBJECTID",
            "f": "geojson",
            "resultRecordCount": 500,
        }
        params.update(self._bbox_params(bbox_override or self.bbox))

        query = urllib.parse.urlencode(params)
        req = urllib.request.Request(
            f"{PERIMETERS_URL}?{query}",
            headers={"User-Agent": "heartbeat-fire-feed/1.0"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return data.get("features", [])

    def _shape_coords_fallback(self, geometry):
        geom_type = (geometry or {}).get("type")
        coords = (geometry or {}).get("coordinates") or []
        if geom_type == "Polygon" and coords:
            return coords[0] or []
        if geom_type == "MultiPolygon" and coords and coords[0]:
            return coords[0][0] or []
        return []

    def _simplify_perimeter(self, geometry):
        try:
            from shapely.geometry import shape
        except Exception:
            if not self._perimeter_shapely_unavailable_logged:
                self.log.warning(
                    "Shapely unavailable; using raw perimeter geometry without simplification"
                )
                self._perimeter_shapely_unavailable_logged = True
            ring = self._shape_coords_fallback(geometry)
            if not ring:
                return [], None
            vertices = [(safe_float(p[0]), safe_float(p[1])) for p in ring if len(p) >= 2]
            vertices = [(lon, lat) for lon, lat in vertices if lon is not None and lat is not None]
            if not vertices:
                return [], None
            centroid_lon = sum(lon for lon, _ in vertices) / len(vertices)
            centroid_lat = sum(lat for _, lat in vertices) / len(vertices)
            return vertices, (centroid_lat, centroid_lon)

        geom = shape(geometry or {})
        if geom.is_empty:
            return [], None

        if geom.geom_type == "MultiPolygon":
            geom = max(geom.geoms, key=lambda g: g.area)
        if geom.geom_type != "Polygon":
            return [], None

        simplified = geom.simplify(self.perimeter_simplify, preserve_topology=True)
        if simplified.geom_type == "MultiPolygon":
            simplified = max(simplified.geoms, key=lambda g: g.area)
        if simplified.geom_type != "Polygon":
            return [], None

        coords = list(simplified.exterior.coords)
        if len(coords) > self.perimeter_max_vertices:
            step = max(1, len(coords) // self.perimeter_max_vertices)
            coords = coords[::step]
            if coords and coords[0] != coords[-1]:
                coords.append(coords[0])

        vertices = [(safe_float(lon), safe_float(lat)) for lon, lat in coords]
        vertices = [(lon, lat) for lon, lat in vertices if lon is not None and lat is not None]
        if not vertices:
            return [], None

        centroid = simplified.centroid
        return vertices, (centroid.y, centroid.x)

    def _perimeter_anchor_lat_lon(self, geometry, fallback_centroid):
        if not fallback_centroid:
            return None

        fallback_lat, fallback_lon = fallback_centroid
        try:
            from shapely.geometry import box, shape

            geom = shape(geometry or {})
            if geom.is_empty:
                return fallback_lat, fallback_lon

            anchor_geom = geom
            if self._region_polygon is not None:
                intersection = anchor_geom.intersection(self._region_polygon)
                if not intersection.is_empty:
                    anchor_geom = intersection
            elif self._region_box is not None:
                intersection = anchor_geom.intersection(self._region_box)
                if not intersection.is_empty:
                    anchor_geom = intersection

            if self._bbox_bounds is not None:
                bbox_geom = box(*self._bbox_bounds)
                intersection = anchor_geom.intersection(bbox_geom)
                if not intersection.is_empty:
                    anchor_geom = intersection

            rep = anchor_geom.representative_point()
            return rep.y, rep.x
        except Exception:
            return fallback_lat, fallback_lon

    def perimeter_to_cot(self, feature):
        props = feature.get("properties") or {}
        geometry = feature.get("geometry") or {}
        vertices, centroid = self._simplify_perimeter(geometry)
        if len(vertices) < 3 or centroid is None:
            raise ValueError("invalid perimeter geometry")

        lat, lon = centroid
        perimeter_id = (
            props.get("IRWINID")
            or props.get("OBJECTID")
            or f"{lat:.5f}-{lon:.5f}"
        )
        uid = f"fire-perimeter-{clean_uid_component(str(perimeter_id))}"

        name = str(props.get("IncidentName") or "Unknown Fire")
        acres = safe_float(props.get("GISAcres"))
        acres_str = f"{acres:.0f}" if acres is not None else "?"
        category = str(props.get("FeatureCategory") or "")

        remarks = f"{name} perimeter | {acres_str} ac"
        if category:
            remarks += f" | {category}"

        now = iso_now()
        stale = iso_future(30)
        escaped_name = html.escape(name, quote=True)
        escaped_remarks = html.escape(remarks, quote=True)
        links = "".join(
            f'<link point="{v_lat:.6f},{v_lon:.6f},0" type="b-m-p-w" relation="c"/>'
            for v_lon, v_lat in vertices
        )

        return (
            '<?xml version="1.0" encoding="UTF-8"?>'
            f'<event version="2.0" uid="{uid}" type="u-d-f"'
            f' time="{now}" start="{now}" stale="{stale}" how="m-g">'
            f'<point lat="{lat:.6f}" lon="{lon:.6f}" hae="0" ce="9999999" le="9999999"/>'
            f"<detail>"
            f"{links}"
            f'<contact callsign="{escaped_name} Perimeter"/>'
            f'<precisionLocation altsrc="DTED0" geopointsrc="manual"/>'
            f"<remarks>{escaped_remarks}</remarks>"
            f'<shape><polyline closed="true"/></shape>'
            f'<strokeColor value="-65536"/>'
            f'<fillColor value="1157562368"/>'
            f'<strokeWeight value="3.0"/>'
            f'<strokeStyle value="solid"/>'
            f"<marti/>"
            f'<__geofence elevationMonitored="false" maxElevation="NaN" minElevation="NaN" monitor="All" tracking="false" trigger="Both"/>'
            f"</detail>"
            f"</event>"
        )

    def perimeter_anchor_to_cot(self, feature):
        """
        Emit a high-visibility point marker at the perimeter centroid so
        operators can quickly locate expected polygon areas while zoomed out.
        """
        props = feature.get("properties") or {}
        geometry = feature.get("geometry") or {}
        vertices, centroid = self._simplify_perimeter(geometry)
        if len(vertices) < 3 or centroid is None:
            raise ValueError("invalid perimeter geometry")

        geometry = feature.get("geometry") or {}
        anchor_lat_lon = self._perimeter_anchor_lat_lon(geometry, centroid)
        if anchor_lat_lon is None:
            raise ValueError("invalid perimeter anchor")
        lat, lon = anchor_lat_lon
        perimeter_id = (
            props.get("IRWINID")
            or props.get("OBJECTID")
            or f"{lat:.5f}-{lon:.5f}"
        )
        uid = f"fire-perimeter-anchor-{clean_uid_component(str(perimeter_id))}"

        name = str(props.get("IncidentName") or "Unknown Fire")
        acres = safe_float(props.get("GISAcres"))
        acres_str = f"{acres:.0f}" if acres is not None else "?"

        remarks = f"{name} perimeter anchor | {acres_str} ac"

        now = iso_now()
        stale = iso_future(30)
        escaped_name = html.escape(name, quote=True)
        escaped_remarks = html.escape(remarks, quote=True)
        # Maroon marker tone.
        color_argb = "-8388608"
        anchor_type = "b-m-p-s-o"

        return (
            '<?xml version="1.0" encoding="UTF-8"?>'
            f'<event version="2.0" uid="{uid}" type="{anchor_type}"'
            f' time="{now}" start="{now}" stale="{stale}" how="m-g">'
            f"<detail>"
            f'<precisionlocation geopointsrc="manual" altsrc="manual"/>'
            f'<status readiness="true"/>'
            f'<color argb="{color_argb}"/>'
            f'<contact callsign="{escaped_name} Octagon"/>'
            f"<marti><dest></dest></marti>"
            f'<usericon iconsetpath="COT_MAPPING_SPOTMAP/{anchor_type}/{color_argb}"/>'
            f"<remarks>{escaped_remarks}</remarks>"
            f"</detail>"
            f'<point lat="{lat:.6f}" lon="{lon:.6f}" hae="0.0" ce="0.0" le="0.0"/>'
            f"</event>"
        )

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

                    query_bbox = self._query_bbox(effective_bbox)

                    try:
                        if query_bbox == "__empty__":
                            polled_incidents = []
                        else:
                            polled_incidents = self.poll_incidents(bbox_override=query_bbox)
                    except Exception as e:
                        self.log.warning("ArcGIS poll failed: %s", e)
                        polled_incidents = []

                    features = [f for f in polled_incidents if self._incident_in_scope(f)]

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

                    perimeter_count = 0
                    perimeter_sent = 0
                    perimeter_anchor_sent = 0
                    if self.include_perimeters:
                        try:
                            if query_bbox == "__empty__":
                                polled_perimeters = []
                            else:
                                polled_perimeters = self.poll_perimeters(
                                    bbox_override=query_bbox
                                )
                        except Exception as e:
                            self.log.warning("Perimeter poll failed: %s", e)
                            polled_perimeters = []

                        perimeter_features = [
                            f for f in polled_perimeters if self._perimeter_intersects_scope(f)
                        ]
                        perimeter_count = len(perimeter_features)
                        for feature in perimeter_features:
                            if not self.running:
                                break
                            try:
                                cot = self.perimeter_to_cot(feature)
                                self.client.send(cot)
                                # Also emit an anchor marker at centroid for visibility.
                                anchor = self.perimeter_anchor_to_cot(feature)
                                self.client.send(anchor)
                                perimeter_anchor_sent += 1
                                perimeter_sent += 1
                            except Exception as e:
                                self.log.debug(
                                    "Skipping malformed perimeter feature: %s", e
                                )

                    self.log.info(
                        (
                            "Polled incidents=%d in_scope=%d sent=%d "
                            "perimeters=%d in_scope=%d sent=%d anchors=%d"
                        ),
                        len(polled_incidents),
                        len(features),
                        sent,
                        len(polled_perimeters) if self.include_perimeters else 0,
                        perimeter_count,
                        perimeter_sent,
                        perimeter_anchor_sent,
                    )

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
        "--region",
        default="",
        help="Named polygon filter (supported: texas)",
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
    parser.add_argument(
        "--include-perimeters",
        action="store_true",
        help="Also poll fire perimeters (FeatureServer layer 1) and emit polygon CoT",
    )
    parser.add_argument(
        "--perimeter-simplify",
        type=float,
        default=0.001,
        help="Shapely simplify tolerance for perimeters (default: 0.001)",
    )
    parser.add_argument(
        "--perimeter-max-vertices",
        type=int,
        default=250,
        help="Max perimeter vertices after decimation (default: 250)",
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
        region=args.region,
        interval=args.interval,
        log_path=args.log,
        auto_bbox_url=args.auto_bbox_url,
        auto_bbox_user=args.auto_bbox_user,
        auto_bbox_password=args.auto_bbox_password,
        auto_bbox_range_km=args.auto_bbox_range_km,
        include_perimeters=args.include_perimeters,
        perimeter_simplify=args.perimeter_simplify,
        perimeter_max_vertices=args.perimeter_max_vertices,
    )

    signal.signal(signal.SIGTERM, feed.stop)
    signal.signal(signal.SIGINT, feed.stop)

    feed.run()


if __name__ == "__main__":
    main()
