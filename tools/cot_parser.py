#!/usr/bin/env python3
"""
CoT (Cursor-on-Target) stream parser.

Handles raw TCP stream framing and XML event extraction.
No external dependencies -- stdlib only.
"""

import xml.etree.ElementTree as ET


class CotStreamParser:
    """
    Buffer incoming TCP data and extract complete <event>...</event> documents.
    Discards noise/garbage between events. Keeps partial events in buffer.
    """

    def __init__(self):
        self.buffer = ""
        self._event_start = "<event"

    def feed(self, data: str) -> list:
        """Feed raw TCP data, return list of complete event XML strings."""
        self.buffer += data
        events = []
        while True:
            start = self.buffer.find(self._event_start)
            if start == -1:
                # Keep a partial "<event" prefix if chunk boundaries split the tag.
                # Example: chunk1 ends with "<ev", chunk2 begins with "ent ...".
                keep = ""
                max_prefix = len(self._event_start) - 1
                tail = self.buffer[-max_prefix:] if max_prefix > 0 else self.buffer
                for i in range(max_prefix, 0, -1):
                    prefix = self._event_start[:i]
                    if tail.endswith(prefix):
                        keep = prefix
                        break
                self.buffer = keep
                break
            end = self.buffer.find("</event>", start)
            if end == -1:
                self.buffer = self.buffer[start:]  # Keep partial event
                break
            end += len("</event>")
            events.append(self.buffer[start:end])
            self.buffer = self.buffer[end:]
        return events


def parse_cot_event(xml_str: str) -> dict:
    """
    Parse a complete <event>...</event> XML string into a structured dict.

    Returns dict with keys: uid, type, how, time, start, stale,
    callsign, lat, lon, hae, ce, le, detail_xml, geometry_points.
    Returns None on parse failure.
    """
    try:
        root = ET.fromstring(xml_str)
    except ET.ParseError:
        return None

    if root.tag != "event":
        return None

    # Core event attributes
    result = {
        "uid": root.get("uid", ""),
        "type": root.get("type", ""),
        "how": root.get("how", ""),
        "time": root.get("time", ""),
        "start": root.get("start", ""),
        "stale": root.get("stale", ""),
    }

    # Point element
    point = root.find("point")
    if point is not None:
        try:
            result["lat"] = float(point.get("lat", 0))
            result["lon"] = float(point.get("lon", 0))
            result["hae"] = float(point.get("hae", 0))
            result["ce"] = float(point.get("ce", 0))
            result["le"] = float(point.get("le", 0))
        except (ValueError, TypeError):
            result["lat"] = None
            result["lon"] = None
            result["hae"] = None
            result["ce"] = None
            result["le"] = None
    else:
        result["lat"] = None
        result["lon"] = None
        result["hae"] = None
        result["ce"] = None
        result["le"] = None

    # Detail element
    detail = root.find("detail")
    if detail is not None:
        result["detail_xml"] = ET.tostring(detail, encoding="unicode")
        # Callsign from contact element
        contact = detail.find("contact")
        result["callsign"] = contact.get("callsign", "") if contact is not None else ""
        # Multi-point geometry
        result["geometry_points"] = extract_geometry_points(detail)
    else:
        result["detail_xml"] = ""
        result["callsign"] = ""
        result["geometry_points"] = []

    return result


def extract_geometry_points(detail: ET.Element) -> list:
    """
    Extract ordered (lat, lon, hae) tuples from geometry-bearing detail elements.

    CoT commonly encodes route/polygon vertices as:
    - any element with point="lat,lon[,hae]"
    - elements with explicit lat/lon[/hae] attributes

    Order is preserved as encountered in the XML document.
    """
    points = []

    def add_point(lat, lon, hae):
        key = (lat, lon, hae)
        # Keep traversal order and preserve ring-closing points (first == last).
        # Only collapse immediate duplicates produced by noisy payloads.
        if points and points[-1] == key:
            return
        points.append(key)

    for elem in detail.iter():
        point_str = elem.get("point")
        if point_str:
            parts = [p.strip() for p in point_str.split(",")]
            if len(parts) >= 2:
                try:
                    lat = float(parts[0])
                    lon = float(parts[1])
                    hae = float(parts[2]) if len(parts) > 2 and parts[2] != "" else 0.0
                    add_point(lat, lon, hae)
                    continue
                except (ValueError, TypeError):
                    pass

        lat_s = elem.get("lat")
        lon_s = elem.get("lon")
        if lat_s is None or lon_s is None:
            continue
        try:
            lat = float(lat_s)
            lon = float(lon_s)
            hae_s = elem.get("hae")
            hae = float(hae_s) if hae_s is not None else 0.0
            add_point(lat, lon, hae)
        except (ValueError, TypeError):
            continue

    return points


def classify_event(event_type: str) -> str:
    """Classify a CoT event type into a layer name by prefix matching."""
    if event_type.startswith("a-"):
        return "positions"
    if event_type.startswith("b-m-p"):
        return "markers"
    if event_type.startswith("b-m-r"):
        return "routes"
    if event_type.startswith("u-d-r"):
        return "routes"
    if event_type.startswith("u-d-f"):
        # Freehand/user-drawn payloads can be open paths or closed areas.
        # Exporter resolves route vs polygon from geometry closure/hints.
        return "routes"
    if event_type.startswith("u-d-c"):
        return "areas"
    return "other"


def is_multi_point_type(event_type: str) -> bool:
    """Returns True for CoT types that carry multi-point geometry (routes, polygons)."""
    return (
        event_type.startswith("b-m-r")
        or event_type.startswith("u-d-r")
        or event_type.startswith("u-d-f")
    )
