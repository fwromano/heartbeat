#!/usr/bin/env python3
"""
GeoPackage writer using sqlite3 + shapely (no GDAL).

Creates OGC-compliant GeoPackage files with point, linestring,
and polygon layers. Geometries are stored as GPKG standard binary
(GP header + WKB).
"""

import sqlite3
import struct

from shapely.geometry import Point, LineString, Polygon


# ---------------------------------------------------------------------------
# GPKG binary geometry encoding
# ---------------------------------------------------------------------------
def to_gpkg_geom(shapely_geom, srs_id=4326):
    """
    Convert a shapely geometry to GeoPackage standard binary format.

    Layout:
      [0-1]   Magic: 0x47, 0x50 ('GP')
      [2]     Version: 0x00
      [3]     Flags: byte order + envelope type
      [4-7]   SRS ID: int32 (little-endian)
      [8-39]  Envelope: 4x float64 (minx, maxx, miny, maxy)
      [40+]   WKB geometry from shapely
    """
    # Flags: little-endian (bit 0 = 1), envelope type xy (bits 1-3 = 001)
    flags = 0b00000011

    if shapely_geom.is_empty:
        # Empty geometry: no envelope
        flags = 0b00100001  # empty flag set, little-endian, no envelope
        header = b"GP"
        header += struct.pack("<B", 0)       # version
        header += struct.pack("<B", flags)   # flags
        header += struct.pack("<i", srs_id)  # SRS ID
        return header + shapely_geom.wkb

    bounds = shapely_geom.bounds  # (minx, miny, maxx, maxy)

    header = b"GP"
    header += struct.pack("<B", 0)       # version
    header += struct.pack("<B", flags)   # flags
    header += struct.pack("<i", srs_id)  # SRS ID
    header += struct.pack(
        "<dddd",
        bounds[0], bounds[2],  # minx, maxx
        bounds[1], bounds[3],  # miny, maxy
    )

    return header + shapely_geom.wkb


# ---------------------------------------------------------------------------
# GPKG initialization SQL
# ---------------------------------------------------------------------------
INIT_SQL = """
PRAGMA application_id = 0x47504B47;
PRAGMA user_version = 10300;

CREATE TABLE IF NOT EXISTS gpkg_spatial_ref_sys (
    srs_name                 TEXT NOT NULL,
    srs_id                   INTEGER NOT NULL PRIMARY KEY,
    organization             TEXT NOT NULL,
    organization_coordsys_id INTEGER NOT NULL,
    definition               TEXT NOT NULL,
    description              TEXT
);

INSERT OR IGNORE INTO gpkg_spatial_ref_sys VALUES (
    'WGS 84 geodetic',
    4326,
    'EPSG',
    4326,
    'GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],AUTHORITY["EPSG","4326"]]',
    'WGS 84'
);

INSERT OR IGNORE INTO gpkg_spatial_ref_sys VALUES (
    'Undefined cartesian SRS', -1, 'NONE', -1,
    'undefined', 'undefined cartesian coordinate reference system'
);
INSERT OR IGNORE INTO gpkg_spatial_ref_sys VALUES (
    'Undefined geographic SRS', 0, 'NONE', 0,
    'undefined', 'undefined geographic coordinate reference system'
);

CREATE TABLE IF NOT EXISTS gpkg_contents (
    table_name  TEXT NOT NULL PRIMARY KEY,
    data_type   TEXT NOT NULL DEFAULT 'features',
    identifier  TEXT UNIQUE,
    description TEXT DEFAULT '',
    last_change TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    min_x       REAL,
    min_y       REAL,
    max_x       REAL,
    max_y       REAL,
    srs_id      INTEGER REFERENCES gpkg_spatial_ref_sys(srs_id)
);

CREATE TABLE IF NOT EXISTS gpkg_geometry_columns (
    table_name         TEXT NOT NULL REFERENCES gpkg_contents(table_name),
    column_name        TEXT NOT NULL,
    geometry_type_name TEXT NOT NULL,
    srs_id             INTEGER NOT NULL REFERENCES gpkg_spatial_ref_sys(srs_id),
    z                  INTEGER NOT NULL DEFAULT 0,
    m                  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (table_name, column_name)
);
"""

# Map geometry type names to shapely constructors (for validation)
GEOM_TYPES = {
    "POINT": "POINT",
    "LINESTRING": "LINESTRING",
    "POLYGON": "POLYGON",
}


class GeoPackageWriter:
    """Create and write to a GeoPackage file."""

    def __init__(self, path):
        self.path = path
        self.conn = sqlite3.connect(path)
        self.conn.executescript(INIT_SQL)
        self.layers = {}  # name -> {"geom_type": str, "columns": list}

    def add_layer(self, name, geometry_type, columns):
        """
        Create a feature table and register it in GPKG metadata.

        Args:
            name: Layer/table name (e.g. "positions")
            geometry_type: "POINT", "LINESTRING", or "POLYGON"
            columns: List of (col_name, col_type) tuples, e.g. [("uid", "TEXT"), ...]
        """
        geom_type = geometry_type.upper()
        if geom_type not in GEOM_TYPES:
            raise ValueError(f"Unsupported geometry type: {geometry_type}")

        # Build CREATE TABLE
        col_defs = ["fid INTEGER PRIMARY KEY AUTOINCREMENT", "geom BLOB"]
        for col_name, col_type in columns:
            col_defs.append(f"{col_name} {col_type}")
        col_sql = ", ".join(col_defs)

        self.conn.execute(f"CREATE TABLE IF NOT EXISTS {name} ({col_sql})")

        # Register in gpkg_contents
        self.conn.execute(
            "INSERT OR IGNORE INTO gpkg_contents (table_name, data_type, identifier, srs_id) "
            "VALUES (?, 'features', ?, 4326)",
            (name, name),
        )

        # Register geometry column
        self.conn.execute(
            "INSERT OR IGNORE INTO gpkg_geometry_columns "
            "(table_name, column_name, geometry_type_name, srs_id, z, m) "
            "VALUES (?, 'geom', ?, 4326, 1, 0)",
            (name, geom_type),
        )

        self.conn.commit()
        self.layers[name] = {"geom_type": geom_type, "columns": columns}

    def add_point_layer(self, name, columns):
        """Convenience: create a Point layer."""
        self.add_layer(name, "POINT", columns)

    def add_linestring_layer(self, name, columns):
        """Convenience: create a LineString layer."""
        self.add_layer(name, "LINESTRING", columns)

    def add_polygon_layer(self, name, columns):
        """Convenience: create a Polygon layer."""
        self.add_layer(name, "POLYGON", columns)

    def insert_feature(self, layer, geom, attrs):
        """
        Insert a feature into a layer.

        Args:
            layer: Layer/table name
            geom: shapely geometry object
            attrs: dict of {column_name: value}
        """
        if layer not in self.layers:
            raise ValueError(f"Unknown layer: {layer}")

        geom_blob = to_gpkg_geom(geom)

        col_names = ["geom"]
        values = [geom_blob]
        for col_name, _ in self.layers[layer]["columns"]:
            col_names.append(col_name)
            values.append(attrs.get(col_name))

        placeholders = ", ".join(["?"] * len(values))
        col_str = ", ".join(col_names)

        self.conn.execute(
            f"INSERT INTO {layer} ({col_str}) VALUES ({placeholders})",
            values,
        )

    def update_bounds(self):
        """Compute and set bounding box per layer in gpkg_contents."""
        for name in self.layers:
            row = self.conn.execute(
                f"SELECT MIN(fid) FROM {name}"
            ).fetchone()
            if row[0] is None:
                continue  # Empty layer

            # Read all geometries to compute bounds
            rows = self.conn.execute(f"SELECT geom FROM {name} WHERE geom IS NOT NULL").fetchall()
            if not rows:
                continue

            min_x = float("inf")
            min_y = float("inf")
            max_x = float("-inf")
            max_y = float("-inf")

            for (blob,) in rows:
                if blob and len(blob) >= 40:
                    # Extract envelope from GPKG header (bytes 8-39)
                    env = struct.unpack_from("<dddd", blob, 8)
                    min_x = min(min_x, env[0])
                    max_x = max(max_x, env[1])
                    min_y = min(min_y, env[2])
                    max_y = max(max_y, env[3])

            if min_x != float("inf"):
                self.conn.execute(
                    "UPDATE gpkg_contents SET min_x=?, min_y=?, max_x=?, max_y=?, "
                    "last_change=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE table_name=?",
                    (min_x, min_y, max_x, max_y, name),
                )

        self.conn.commit()

    def close(self):
        """Update bounds, commit, and close."""
        self.update_bounds()
        self.conn.commit()
        self.conn.close()
