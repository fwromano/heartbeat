#!/usr/bin/env python3
"""
CoT Recorder Daemon.

Connects to a TAK server's CoT TCP port as a client, sends an SA
identification event, and passively records all received CoT events
to a SQLite database.

Usage:
    python3 tools/recorder.py --host 127.0.0.1 --port 8087 \
        --db data/cot_records.db --log data/recorder.log
"""

import argparse
import logging
import os
import signal
import socket
import sqlite3
import ssl
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

# Add tools/ to path so we can import cot_parser as a sibling module
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cot_parser import CotStreamParser, parse_cot_event


# ---------------------------------------------------------------------------
# SQL schema
# ---------------------------------------------------------------------------
SCHEMA_SQL = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS recording_sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at   TEXT NOT NULL,
    stopped_at   TEXT,
    server_host  TEXT NOT NULL,
    server_port  INTEGER NOT NULL,
    events_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS cot_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  INTEGER REFERENCES recording_sessions(id),
    uid         TEXT NOT NULL,
    event_type  TEXT NOT NULL,
    callsign    TEXT,
    time        TEXT NOT NULL,
    start       TEXT NOT NULL,
    stale       TEXT NOT NULL,
    how         TEXT,
    lat         REAL,
    lon         REAL,
    hae         REAL,
    ce          REAL,
    le          REAL,
    detail_xml  TEXT,
    raw_xml     TEXT NOT NULL,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(uid, time)
);

CREATE INDEX IF NOT EXISTS idx_cot_type     ON cot_events(event_type);
CREATE INDEX IF NOT EXISTS idx_cot_time     ON cot_events(time);
CREATE INDEX IF NOT EXISTS idx_cot_uid      ON cot_events(uid);
CREATE INDEX IF NOT EXISTS idx_cot_callsign ON cot_events(callsign);

CREATE TABLE IF NOT EXISTS cot_geometry_points (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id    INTEGER NOT NULL REFERENCES cot_events(id) ON DELETE CASCADE,
    point_order INTEGER NOT NULL,
    lat         REAL NOT NULL,
    lon         REAL NOT NULL,
    hae         REAL,
    UNIQUE(event_id, point_order)
);

CREATE INDEX IF NOT EXISTS idx_geom_event ON cot_geometry_points(event_id);
"""

# SA keepalive interval (seconds)
SA_INTERVAL = 240  # 4 minutes
STARTUP_SA_INTERVAL = 2
STARTUP_SA_RETRIES = 3
SOCKET_READ_TIMEOUT = 5
RECONNECT_DELAY = 3


def iso_now():
    """Current UTC time as ISO 8601 string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def iso_future(minutes=5):
    """UTC time N minutes in the future as ISO 8601."""
    t = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    return t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class CotRecorder:
    """Main recorder daemon that connects to a TAK server and records CoT events."""

    def __init__(
        self,
        host,
        port,
        db_path,
        log_path,
        use_ssl=False,
        cert_path=None,
        key_path=None,
        ca_path=None,
        group_name="Cyan",
        group_role="HQ",
    ):
        self.host = host
        self.port = port
        self.db_path = db_path
        self.log_path = log_path
        self.use_ssl = use_ssl
        self.cert_path = cert_path
        self.key_path = key_path
        self.ca_path = ca_path
        self.group_name = group_name
        self.group_role = group_role
        self.running = True
        self.sock = None
        self.session_id = None
        self.recorder_uid = f"heartbeat-recorder-{uuid.uuid4()}"
        self.recorder_callsign = f"HB-REC-{uuid.uuid4().hex[:8]}"
        self.received_foreign_event = False

        # Set up logging
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s [%(levelname)s] %(message)s",
            handlers=[
                logging.FileHandler(log_path),
            ],
        )
        self.log = logging.getLogger("recorder")

    def init_db(self):
        """Create database schema if it doesn't exist."""
        conn = sqlite3.connect(self.db_path)
        conn.executescript(SCHEMA_SQL)
        conn.close()
        self.log.info("Database initialized: %s", self.db_path)

    def make_sa_event(self):
        """Build the SA (self-identification) XML event."""
        now = iso_now()
        stale = iso_future(5)
        return (
            '<?xml version="1.0" encoding="UTF-8"?>'
            f'<event version="2.0"'
            f' uid="{self.recorder_uid}"'
            f' type="a-f-G-U-C"'
            f' time="{now}"'
            f' start="{now}"'
            f' stale="{stale}"'
            f' how="m-g">'
            f'<point lat="0.0" lon="0.0" hae="0" ce="9999999" le="9999999"/>'
            f"<detail>"
            f'<contact callsign="{self.recorder_callsign}"/>'
            f'<__group name="{self.group_name}" role="{self.group_role}"/>'
            f'<precisionlocation altsrc="DTED0"/>'
            f'<takv version="heartbeat" platform="recorder" device="server" os="linux"/>'
            f"</detail>"
            f"</event>"
        )

    def connect(self):
        """Establish connection and send SA event."""
        raw_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        raw_sock.settimeout(SOCKET_READ_TIMEOUT)

        if self.use_ssl:
            context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
            context.check_hostname = False

            if self.ca_path:
                context.load_verify_locations(cafile=self.ca_path)
                context.verify_mode = ssl.CERT_REQUIRED
            else:
                context.verify_mode = ssl.CERT_NONE

            if not self.cert_path or not self.key_path:
                raise RuntimeError("SSL mode requires cert/key paths")

            context.load_cert_chain(certfile=self.cert_path, keyfile=self.key_path)
            self.sock = context.wrap_socket(raw_sock, server_hostname=self.host)
        else:
            self.sock = raw_sock

        self.sock.connect((self.host, self.port))
        self.sock.settimeout(SOCKET_READ_TIMEOUT)
        mode = "SSL" if self.use_ssl else "TCP"
        self.log.info("Connected (%s) to %s:%d", mode, self.host, self.port)

        # Send SA identification
        self.send_sa_event("initial")

    def send_sa_event(self, reason="keepalive"):
        """Send an SA event to keep the recorder registered as a client."""
        sa = self.make_sa_event()
        self.sock.sendall(sa.encode("utf-8"))
        if reason == "initial":
            self.log.info(
                "SA event sent (callsign=%s, uid=%s)",
                self.recorder_callsign,
                self.recorder_uid,
            )
        else:
            self.log.info("SA %s sent", reason)

    def record_event(self, conn, session_id, xml_str):
        """Parse a CoT event XML and insert into the database."""
        parsed = parse_cot_event(xml_str)
        if parsed is None:
            return False

        # Skip our own SA events
        if parsed["uid"] == self.recorder_uid:
            return False
        self.received_foreign_event = True

        geometry_points = parsed.get("geometry_points") or []
        has_point = parsed["lat"] is not None and parsed["lon"] is not None
        has_geometry = len(geometry_points) > 0

        # Keep events that have either a main point or multi-point geometry.
        if not has_point and not has_geometry:
            return False

        anchor_lat = parsed["lat"]
        anchor_lon = parsed["lon"]
        anchor_hae = parsed["hae"]
        if not has_point and has_geometry:
            # Some drawing CoTs omit top-level point; use first vertex as anchor.
            anchor_lat, anchor_lon, anchor_hae = geometry_points[0]

        try:
            cursor = conn.execute(
                """INSERT OR IGNORE INTO cot_events
                   (session_id, uid, event_type, callsign, time, start, stale,
                    how, lat, lon, hae, ce, le, detail_xml, raw_xml)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    session_id,
                    parsed["uid"],
                    parsed["type"],
                    parsed["callsign"],
                    parsed["time"],
                    parsed["start"],
                    parsed["stale"],
                    parsed["how"],
                    anchor_lat,
                    anchor_lon,
                    anchor_hae,
                    parsed["ce"],
                    parsed["le"],
                    parsed["detail_xml"],
                    xml_str,
                ),
            )

            if cursor.rowcount > 0:
                event_id = cursor.lastrowid

                # Persist any parsed geometry points, regardless of event type prefix.
                if geometry_points:
                    for i, (lat, lon, hae) in enumerate(geometry_points):
                        conn.execute(
                            """INSERT OR IGNORE INTO cot_geometry_points
                               (event_id, point_order, lat, lon, hae)
                               VALUES (?, ?, ?, ?, ?)""",
                            (event_id, i, lat, lon, hae),
                        )

                # Increment session event count
                conn.execute(
                    "UPDATE recording_sessions SET events_count = events_count + 1 WHERE id = ?",
                    (session_id,),
                )
                conn.commit()
                return True

            conn.commit()
            return False  # Duplicate, skipped

        except sqlite3.Error as e:
            self.log.warning("DB insert error: %s", e)
            return False

    def run(self):
        """Main loop with auto-reconnect."""
        self.init_db()
        parser = CotStreamParser()

        while self.running:
            db_conn = None
            try:
                self.connect()

                db_conn = sqlite3.connect(self.db_path)
                db_conn.execute("PRAGMA journal_mode=WAL")
                db_conn.execute("PRAGMA foreign_keys=ON")

                # Create new recording session
                now = iso_now()
                cursor = db_conn.execute(
                    "INSERT INTO recording_sessions (started_at, server_host, server_port) VALUES (?, ?, ?)",
                    (now, self.host, self.port),
                )
                self.session_id = cursor.lastrowid
                db_conn.commit()
                self.log.info("Recording session %d started", self.session_id)

                self.received_foreign_event = False
                last_sa_time = time.monotonic()
                startup_sa_retries = 0

                while self.running:
                    try:
                        data = self.sock.recv(65536)
                    except socket.timeout:
                        data = None
                    except OSError:
                        break

                    if data == b"":
                        self.log.warning("Connection closed by server")
                        break

                    if data:
                        try:
                            text = data.decode("utf-8", errors="replace")
                        except Exception:
                            continue

                        events = parser.feed(text)
                        for event_xml in events:
                            inserted = self.record_event(db_conn, self.session_id, event_xml)
                            if inserted:
                                self.log.debug("Recorded event")

                    elapsed = time.monotonic() - last_sa_time
                    if (
                        not self.received_foreign_event
                        and startup_sa_retries < STARTUP_SA_RETRIES
                        and elapsed >= STARTUP_SA_INTERVAL
                    ):
                        try:
                            self.send_sa_event(f"startup retry {startup_sa_retries + 1}")
                            last_sa_time = time.monotonic()
                            startup_sa_retries += 1
                        except OSError:
                            break

                    # SA keepalive
                    elif elapsed >= SA_INTERVAL:
                        try:
                            self.send_sa_event("keepalive")
                            last_sa_time = time.monotonic()
                        except OSError:
                            break

            except (ConnectionRefusedError, ConnectionResetError, OSError) as e:
                if self.running:
                    self.log.warning("Connection error: %s — retrying in 5s", e)
                    time.sleep(5)

            except Exception as e:
                if self.running:
                    self.log.error("Unexpected error: %s — retrying in 10s", e)
                    time.sleep(10)

            finally:
                # Close socket
                if self.sock:
                    try:
                        self.sock.close()
                    except Exception:
                        pass
                    self.sock = None

                # Close recording session
                if db_conn and self.session_id:
                    try:
                        db_conn.execute(
                            "UPDATE recording_sessions SET stopped_at = ? WHERE id = ?",
                            (iso_now(), self.session_id),
                        )
                        db_conn.commit()
                    except Exception:
                        pass

                if db_conn:
                    try:
                        db_conn.close()
                    except Exception:
                        pass
                    db_conn = None

                self.session_id = None

                # Avoid tight reconnect storms when server immediately closes.
                if self.running:
                    time.sleep(RECONNECT_DELAY)

        self.log.info("Recorder stopped")

    def stop(self, signum=None, frame=None):
        """Signal handler -- sets running=False and shuts down the socket."""
        self.log.info("Shutdown signal received")
        self.running = False
        if self.sock:
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser(description="Heartbeat CoT Recorder")
    parser.add_argument("--host", default="127.0.0.1", help="TAK server host")
    parser.add_argument("--port", type=int, default=8087, help="CoT TCP port")
    parser.add_argument("--ssl", action="store_true", help="Use TLS with client certificate")
    parser.add_argument("--cert", default="", help="Client certificate PEM path")
    parser.add_argument("--key", default="", help="Client private key PEM path")
    parser.add_argument("--ca", default="", help="CA certificate PEM path")
    parser.add_argument("--group", default="Cyan", help="TAK group name for SA keepalive")
    parser.add_argument("--role", default="HQ", help="TAK group role for SA keepalive")
    parser.add_argument("--db", default="data/cot_records.db", help="SQLite database path")
    parser.add_argument("--log", default="data/recorder.log", help="Log file path")
    args = parser.parse_args()

    recorder = CotRecorder(
        args.host,
        args.port,
        args.db,
        args.log,
        use_ssl=args.ssl,
        cert_path=args.cert or None,
        key_path=args.key or None,
        ca_path=args.ca or None,
        group_name=args.group,
        group_role=args.role,
    )

    signal.signal(signal.SIGTERM, recorder.stop)
    signal.signal(signal.SIGINT, recorder.stop)

    recorder.run()


if __name__ == "__main__":
    main()
