#!/usr/bin/env python3
"""
CoT export to GeoPackage.

Raw mode: full dump (positions, markers, routes, areas)
GCM mode: Graphic Control Measures only (YAML mapping)
"""

from __future__ import annotations

import argparse
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
            ("uid", "TEXT"),
            ("callsign", "TEXT"),
            ("cot_type", "TEXT"),
            ("time", "TEXT"),
            ("hae", "REAL"),
            ("ce", "REAL"),
            ("le", "REAL"),
        ],
    },
    "markers": {
        "geometry": "Point",
        "columns": [
            ("uid", "TEXT"),
            ("callsign", "TEXT"),
            ("cot_type", "TEXT"),
            ("time", "TEXT"),
            ("remarks", "TEXT"),
        ],
    },
    "routes": {
        "geometry": "LineString",
        "columns": [
            ("uid", "TEXT"),
            ("callsign", "TEXT"),
            ("cot_type", "TEXT"),
            ("time", "TEXT"),
        ],
    },
    "areas": {
        "geometry": "Polygon",
        "columns": [
            ("uid", "TEXT"),
            ("callsign", "TEXT"),
            ("cot_type", "TEXT"),
            ("time", "TEXT"),
            ("remarks", "TEXT"),
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


def export_raw(db_path: str, output_path: str):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    writer = GeoPackageWriter(output_path)

    try:
        add_layers(writer, RAW_LAYERS)

        for row in conn.execute("SELECT * FROM cot_events ORDER BY time"):
            layer = classify_event(row["event_type"])
            if layer not in RAW_LAYERS:
                continue

            if layer in ("positions", "markers"):
                geom = build_point(row)
                if geom is None:
                    continue

                attrs = {
                    "uid": row["uid"],
                    "callsign": row["callsign"],
                    "cot_type": row["event_type"],
                    "time": row["time"],
                }

                if layer == "positions":
                    attrs.update({
                        "hae": row["hae"],
                        "ce": row["ce"],
                        "le": row["le"],
                    })
                else:
                    attrs["remarks"] = extract_remarks(row["detail_xml"])

                writer.insert_feature(layer, geom, attrs)
                continue

            points = load_geometry_points(conn, row["id"])
            if layer == "routes":
                geom = build_linestring(points)
            else:
                geom = build_polygon(points)

            if geom is None:
                continue

            attrs = {
                "uid": row["uid"],
                "callsign": row["callsign"],
                "cot_type": row["event_type"],
                "time": row["time"],
            }
            if layer == "areas":
                attrs["remarks"] = extract_remarks(row["detail_xml"])

            writer.insert_feature(layer, geom, attrs)

    finally:
        writer.close()
        conn.close()


def select_events(conn: sqlite3.Connection, dedup_by_uid: bool):
    if not dedup_by_uid:
        return conn.execute("SELECT * FROM cot_events ORDER BY time")

    return conn.execute(
        """
        SELECT e.*
        FROM cot_events e
        JOIN (
            SELECT uid, MAX(time) AS max_time
            FROM cot_events
            GROUP BY uid
        ) latest
        ON e.uid = latest.uid AND e.time = latest.max_time
        ORDER BY e.time
        """
    )


def extract_attribute(row: sqlite3.Row, name: str) -> str | None:
    if name == "cot_type":
        return row["event_type"]
    if name == "remarks":
        return extract_remarks(row["detail_xml"])
    if name in row.keys():
        return row[name]
    return None


def export_gcm(db_path: str, output_path: str, mapping_path: str):
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

        for row in select_events(conn, mapper.deduplicate_by_uid):
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
        export_raw(args.db, args.output)
        return

    mapping_path = args.mapping
    if not mapping_path:
        raise SystemExit("--mapping is required for GCM export")

    export_gcm(args.db, args.output, mapping_path)


if __name__ == "__main__":
    main()
