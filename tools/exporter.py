#!/usr/bin/env python3
"""
CoT export to GeoPackage.

Raw mode: full dump (positions, markers, routes, areas)
GCM mode: Graphic Control Measures only (YAML mapping)
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sqlite3
import sys
import xml.etree.ElementTree as ET

from shapely.geometry import Point, LineString, Polygon

# Add tools/ to path so we can import sibling modules
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cot_parser import classify_event
from gpkg_writer import GeoPackageWriter


RAW_LAYERS = {
    "positions": {
        "geometry": "Point",
        "columns": [
            ("event_id", "INTEGER"),
            ("session_id", "INTEGER"),
            ("uid", "TEXT"),
            ("callsign", "TEXT"),
            ("cot_type", "TEXT"),
            ("event_time", "TEXT"),
            ("start_time", "TEXT"),
            ("stale_time", "TEXT"),
            ("how", "TEXT"),
            ("remarks", "TEXT"),
            ("stroke_color", "TEXT"),
            ("fill_color", "TEXT"),
            ("stroke_weight", "TEXT"),
            ("detail_xml", "TEXT"),
            ("raw_xml", "TEXT"),
            ("hae", "REAL"),
            ("ce", "REAL"),
            ("le", "REAL"),
        ],
    },
    "markers": {
        "geometry": "Point",
        "columns": [
            ("event_id", "INTEGER"),
            ("session_id", "INTEGER"),
            ("uid", "TEXT"),
            ("callsign", "TEXT"),
            ("cot_type", "TEXT"),
            ("event_time", "TEXT"),
            ("start_time", "TEXT"),
            ("stale_time", "TEXT"),
            ("how", "TEXT"),
            ("remarks", "TEXT"),
            ("stroke_color", "TEXT"),
            ("fill_color", "TEXT"),
            ("stroke_weight", "TEXT"),
            ("detail_xml", "TEXT"),
            ("raw_xml", "TEXT"),
        ],
    },
    "routes": {
        "geometry": "LineString",
        "columns": [
            ("event_id", "INTEGER"),
            ("session_id", "INTEGER"),
            ("uid", "TEXT"),
            ("callsign", "TEXT"),
            ("cot_type", "TEXT"),
            ("event_time", "TEXT"),
            ("start_time", "TEXT"),
            ("stale_time", "TEXT"),
            ("how", "TEXT"),
            ("remarks", "TEXT"),
            ("stroke_color", "TEXT"),
            ("fill_color", "TEXT"),
            ("stroke_weight", "TEXT"),
            ("detail_xml", "TEXT"),
            ("raw_xml", "TEXT"),
            ("point_count", "INTEGER"),
            ("geometry_points_json", "TEXT"),
        ],
    },
    "areas": {
        "geometry": "Polygon",
        "columns": [
            ("event_id", "INTEGER"),
            ("session_id", "INTEGER"),
            ("uid", "TEXT"),
            ("callsign", "TEXT"),
            ("cot_type", "TEXT"),
            ("event_time", "TEXT"),
            ("start_time", "TEXT"),
            ("stale_time", "TEXT"),
            ("how", "TEXT"),
            ("remarks", "TEXT"),
            ("stroke_color", "TEXT"),
            ("fill_color", "TEXT"),
            ("stroke_weight", "TEXT"),
            ("detail_xml", "TEXT"),
            ("raw_xml", "TEXT"),
            ("point_count", "INTEGER"),
            ("geometry_points_json", "TEXT"),
        ],
    },
}


def extract_remarks(detail_xml: str) -> str:
    if not detail_xml:
        return ""
    try:
        detail = ET.fromstring(detail_xml)
    except ET.ParseError:
        return ""

    remarks = detail.find("remarks") or detail.find(".//remarks")
    if remarks is None:
        return ""

    if remarks.text and remarks.text.strip():
        return remarks.text.strip()

    for key in ("remarks", "text"):
        value = remarks.get(key)
        if value:
            return value.strip()

    return ""


def extract_style_fields(detail_xml: str) -> dict[str, str]:
    fields = {
        "stroke_color": "",
        "fill_color": "",
        "stroke_weight": "",
    }
    if not detail_xml:
        return fields
    try:
        detail = ET.fromstring(detail_xml)
    except ET.ParseError:
        return fields

    def _extract_value(tag_names, attrs=("value", "argb", "color")):
        for tag in tag_names:
            elem = detail.find(f".//{tag}")
            if elem is None:
                continue
            for attr in attrs:
                v = elem.get(attr)
                if v:
                    return str(v)
            if elem.text and elem.text.strip():
                return elem.text.strip()
        return ""

    fields["stroke_color"] = _extract_value(("strokeColor", "color"))
    fields["fill_color"] = _extract_value(("fillColor",))
    fields["stroke_weight"] = _extract_value(("strokeWeight", "lineWidth"), attrs=("value", "width"))
    return fields


def build_common_attrs(row: sqlite3.Row) -> dict:
    detail_xml = row["detail_xml"] or ""
    style = extract_style_fields(detail_xml)
    return {
        "event_id": row["id"],
        "session_id": row["session_id"],
        "uid": row["uid"],
        "callsign": row["callsign"],
        "cot_type": row["event_type"],
        "event_time": row["time"],
        "start_time": row["start"],
        "stale_time": row["stale"],
        "how": row["how"],
        "remarks": extract_remarks(detail_xml),
        "stroke_color": style["stroke_color"],
        "fill_color": style["fill_color"],
        "stroke_weight": style["stroke_weight"],
        "detail_xml": detail_xml,
        "raw_xml": row["raw_xml"] or "",
    }


def load_geometry_points(conn: sqlite3.Connection, event_id: int):
    rows = conn.execute(
        "SELECT lat, lon, hae FROM cot_geometry_points WHERE event_id = ? ORDER BY point_order",
        (event_id,),
    ).fetchall()
    return rows


def build_point(row: sqlite3.Row):
    if row["lat"] is None or row["lon"] is None:
        return None
    return Point(row["lon"], row["lat"])


def build_linestring(points):
    if len(points) < 2:
        return None
    coords = [(row["lon"], row["lat"]) for row in points]
    return LineString(coords)


def build_polygon(points):
    if len(points) < 3:
        return None
    coords = [(row["lon"], row["lat"]) for row in points]
    if coords[0] != coords[-1]:
        coords.append(coords[0])
    return Polygon(coords)


def _is_closed_shape(detail_xml: str, points) -> bool:
    if len(points) >= 3 and points[0] == points[-1]:
        return True
    if not detail_xml:
        return False
    try:
        detail = ET.fromstring(detail_xml)
    except ET.ParseError:
        return False

    polyline = detail.find(".//polyline")
    if polyline is not None:
        closed = (polyline.get("closed") or "").strip().lower()
        if closed in {"true", "1", "yes"}:
            return True

    return detail.find(".//polygon") is not None


def _is_area_like_route(row: sqlite3.Row, points) -> bool:
    """
    Detect iTAK/ATAK drawn shapes that arrive as u-d-r but are semantically areas.

    Some clients emit rectangles/polygons as u-d-r with 4+ vertices and a fillColor,
    without setting polyline@closed or repeating the first vertex at the end.
    """
    if len(points) < 3:
        return False
    event_type = (row["event_type"] or "").lower()
    detail_xml = row["detail_xml"] or ""
    if _is_closed_shape(detail_xml, points):
        return True

    # Keep freeform routes (u-d-f) as lines unless they are explicitly closed.
    # Some clients include fill/styling tags even for open strokes.
    if event_type.startswith("u-d-f"):
        return False

    # Rectangle/polygon tools often arrive as u-d-r without explicit closure.
    if not event_type.startswith("u-d-r"):
        return False

    try:
        detail = ET.fromstring(detail_xml) if detail_xml else None
    except ET.ParseError:
        detail = None

    if detail is not None:
        if detail.find(".//fillColor") is not None:
            return True
        if detail.find(".//closed") is not None:
            return True

    callsign = (row["callsign"] or "").lower()
    uid = (row["uid"] or "").lower()
    shape_hints = ("rectangleshape", "polygonshape", "shapefile")
    return any(h in callsign or h in uid for h in shape_hints)


def _to_float(value) -> float | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    text = text.replace(",", "")
    for suffix in ("m", "meter", "meters", "ft", "feet"):
        if text.lower().endswith(suffix):
            text = text[: -len(suffix)].strip()
            break
    try:
        v = float(text)
    except (TypeError, ValueError):
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return v


def _extract_circle_radius_m(row: sqlite3.Row) -> float | None:
    detail_xml = row["detail_xml"] or ""
    if not detail_xml:
        return None

    try:
        detail = ET.fromstring(detail_xml)
    except ET.ParseError:
        return None

    # Prefer explicit radius-style fields first.
    for elem in detail.iter():
        tag = (elem.tag or "").lower()
        for key in ("radius", "r", "range", "distance"):
            if key in elem.attrib:
                v = _to_float(elem.attrib.get(key))
                if v and v > 0:
                    return v
        if tag in ("radius", "range", "distance"):
            v = _to_float(elem.attrib.get("value") or elem.text)
            if v and v > 0:
                return v
        for key in ("major", "minor", "semimajor", "semiminor"):
            if key in elem.attrib:
                v = _to_float(elem.attrib.get(key))
                if v and v > 0:
                    # In ATAK/iTAK shape payloads these are typically in meters
                    # as axis lengths for ellipse/circle tools.
                    return v

    return None


def _build_circle_polygon_from_row(row: sqlite3.Row, vertices: int = 64):
    radius_m = _extract_circle_radius_m(row)
    if not radius_m or radius_m <= 0:
        return None
    if row["lat"] is None or row["lon"] is None:
        return None

    lat0 = math.radians(float(row["lat"]))
    lon0 = math.radians(float(row["lon"]))
    earth_radius_m = 6378137.0
    angular_distance = radius_m / earth_radius_m

    coords = []
    for i in range(vertices):
        bearing = 2.0 * math.pi * i / vertices
        lat = math.asin(
            math.sin(lat0) * math.cos(angular_distance)
            + math.cos(lat0) * math.sin(angular_distance) * math.cos(bearing)
        )
        lon = lon0 + math.atan2(
            math.sin(bearing) * math.sin(angular_distance) * math.cos(lat0),
            math.cos(angular_distance) - math.sin(lat0) * math.sin(lat),
        )
        coords.append((math.degrees(lon), math.degrees(lat)))

    if coords and coords[0] != coords[-1]:
        coords.append(coords[0])
    return Polygon(coords) if len(coords) >= 4 else None


def add_layers(writer: GeoPackageWriter, layers_config: dict):
    for name, cfg in layers_config.items():
        geometry = (cfg.get("geometry") or "").lower()
        columns = cfg.get("columns") or []
        if geometry == "point":
            writer.add_point_layer(name, columns)
        elif geometry == "linestring":
            writer.add_linestring_layer(name, columns)
        elif geometry == "polygon":
            writer.add_polygon_layer(name, columns)
        else:
            raise ValueError(f"Unknown geometry type for layer {name}: {geometry}")


def export_raw(db_path: str, output_path: str, session_id: int | None = None):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    writer = GeoPackageWriter(output_path)

    try:
        add_layers(writer, RAW_LAYERS)

        query = "SELECT * FROM cot_events"
        params = []
        if session_id is not None:
            query += " WHERE session_id = ?"
            params.append(session_id)
        query += " ORDER BY time"

        for row in conn.execute(query, params):
            layer = classify_event(row["event_type"], row["how"] or "")
            points = []
            if layer not in RAW_LAYERS:
                points = load_geometry_points(conn, row["id"])
                if len(points) >= 2:
                    layer = "areas" if _is_closed_shape(row["detail_xml"], points) else "routes"
                else:
                    circle_geom = _build_circle_polygon_from_row(row)
                    if circle_geom is not None:
                        layer = "areas"
                    else:
                        continue

            if layer in ("positions", "markers"):
                geom = build_point(row)
                if geom is None:
                    continue

                attrs = build_common_attrs(row)

                if layer == "positions":
                    attrs.update({
                        "hae": row["hae"],
                        "ce": row["ce"],
                        "le": row["le"],
                    })

                writer.insert_feature(layer, geom, attrs)
                continue

            if not points:
                points = load_geometry_points(conn, row["id"])
            if layer == "routes" and _is_area_like_route(row, points):
                layer = "areas"
            if layer == "routes":
                geom = build_linestring(points)
            else:
                geom = build_polygon(points)
                if geom is None:
                    geom = _build_circle_polygon_from_row(row)

            if geom is None:
                continue

            attrs = build_common_attrs(row)
            coords = [(pt["lon"], pt["lat"], pt["hae"]) for pt in points]
            attrs["point_count"] = len(coords)
            attrs["geometry_points_json"] = json.dumps(coords, separators=(",", ":"))

            writer.insert_feature(layer, geom, attrs)

    finally:
        writer.close()
        conn.close()


def select_events(conn: sqlite3.Connection, dedup_by_uid: bool, session_id: int | None = None):
    where = ""
    params = []
    if session_id is not None:
        where = "WHERE session_id = ?"
        params.append(session_id)

    if not dedup_by_uid:
        return conn.execute(f"SELECT * FROM cot_events {where} ORDER BY time", params)

    query = f"""
        SELECT e.*
        FROM cot_events e
        JOIN (
            SELECT uid, MAX(time) AS max_time
            FROM cot_events
            {where}
            GROUP BY uid
        ) latest
        ON e.uid = latest.uid AND e.time = latest.max_time
        {where}
        ORDER BY e.time
    """
    # Dedup query uses the same filter in both subquery and outer query.
    return conn.execute(query, params + params)


def extract_attribute(row: sqlite3.Row, name: str) -> str | None:
    if name == "cot_type":
        return row["event_type"]
    if name == "remarks":
        return extract_remarks(row["detail_xml"])
    if name in row.keys():
        return row[name]
    return None


def export_gcm(db_path: str, output_path: str, mapping_path: str, session_id: int | None = None):
    from gcm_mapper import GcmMapper

    mapper = GcmMapper(mapping_path)

    layers_config = {}
    for layer_name, cfg in mapper.layers.items():
        geometry = cfg.get("geometry")
        if not geometry:
            raise ValueError(f"Layer {layer_name} missing geometry in mapping")
        attrs = [(attr, "TEXT") for attr in (cfg.get("attributes") or [])]
        layers_config[layer_name] = {
            "geometry": geometry,
            "columns": attrs,
        }

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    writer = GeoPackageWriter(output_path)

    try:
        add_layers(writer, layers_config)

        for row in select_events(conn, mapper.deduplicate_by_uid, session_id=session_id):
            layer = mapper.classify(row["event_type"])
            if not layer:
                continue

            layer_cfg = mapper.get_layer_config(layer)
            geometry = (layer_cfg.get("geometry") or "").lower()

            if geometry == "point":
                geom = build_point(row)
            elif geometry == "linestring":
                points = load_geometry_points(conn, row["id"])
                geom = build_linestring(points)
            elif geometry == "polygon":
                points = load_geometry_points(conn, row["id"])
                geom = build_polygon(points)
            else:
                raise ValueError(f"Unknown geometry type for layer {layer}: {geometry}")

            if geom is None:
                continue

            attrs = {}
            for attr_name in layer_cfg.get("attributes", []) or []:
                attrs[attr_name] = extract_attribute(row, attr_name)

            writer.insert_feature(layer, geom, attrs)

    finally:
        writer.close()
        conn.close()


def parse_args():
    parser = argparse.ArgumentParser(description="Export CoT events to GeoPackage")
    parser.add_argument("--db", default="data/cot_records.db", help="SQLite database path")
    parser.add_argument("--output", required=True, help="Output GeoPackage file")
    parser.add_argument(
        "--session-id",
        type=int,
        help="Limit export to a specific recording session ID",
    )
    parser.add_argument(
        "--mode",
        choices=["raw", "gcm"],
        default="raw",
        help="Export mode (raw or gcm)",
    )
    parser.add_argument("--gcm", action="store_true", help="Alias for --mode gcm")
    parser.add_argument("--mapping", help="GCM mapping YAML file")
    return parser.parse_args()


def main():
    args = parse_args()
    mode = "gcm" if args.gcm else args.mode

    if mode == "raw":
        export_raw(args.db, args.output, session_id=args.session_id)
        return

    mapping_path = args.mapping
    if not mapping_path:
        raise SystemExit("--mapping is required for GCM export")

    export_gcm(args.db, args.output, mapping_path, session_id=args.session_id)


if __name__ == "__main__":
    main()
