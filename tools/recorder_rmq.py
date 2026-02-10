#!/usr/bin/env python3
"""
Heartbeat OpenTAK RabbitMQ recorder.

Consumes CoT JSON envelopes from RabbitMQ's `firehose` exchange and writes
events to the same SQLite schema used by the socket recorder.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import sqlite3
import sys
import time
from datetime import datetime, timezone

import pika

# Add tools/ to path so we can import sibling modules.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cot_parser import parse_cot_event


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

RECONNECT_DELAY = 3


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class RabbitCotRecorder:
    def __init__(
        self,
        host: str,
        port: int,
        username: str,
        password: str,
        vhost: str,
        exchange: str,
        routing_key: str,
        db_path: str,
        log_path: str,
    ):
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.vhost = vhost
        self.exchange = exchange
        self.routing_key = routing_key
        self.db_path = db_path
        self.log_path = log_path
        self.running = True
        self.session_id: int | None = None
        self.db_conn: sqlite3.Connection | None = None

        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s [%(levelname)s] %(message)s",
            handlers=[logging.FileHandler(log_path)],
        )
        self.log = logging.getLogger("recorder-rmq")

    def init_db(self):
        conn = sqlite3.connect(self.db_path)
        conn.executescript(SCHEMA_SQL)
        conn.close()
        self.log.info("Database initialized: %s", self.db_path)

    def open_session(self):
        self.db_conn = sqlite3.connect(self.db_path)
        self.db_conn.execute("PRAGMA journal_mode=WAL")
        self.db_conn.execute("PRAGMA foreign_keys=ON")
        cursor = self.db_conn.execute(
            "INSERT INTO recording_sessions (started_at, server_host, server_port) VALUES (?, ?, ?)",
            (iso_now(), self.host, self.port),
        )
        self.session_id = cursor.lastrowid
        self.db_conn.commit()
        self.log.info("Recording session %d started", self.session_id)

    def close_session(self):
        if self.db_conn and self.session_id:
            try:
                self.db_conn.execute(
                    "UPDATE recording_sessions SET stopped_at = ? WHERE id = ?",
                    (iso_now(), self.session_id),
                )
                self.db_conn.commit()
            except Exception:
                pass

        if self.db_conn:
            try:
                self.db_conn.close()
            except Exception:
                pass
            self.db_conn = None
        self.session_id = None

    def record_event(self, xml_str: str) -> bool:
        if not self.db_conn or not self.session_id:
            return False

        parsed = parse_cot_event(xml_str)
        if parsed is None:
            return False

        geometry_points = parsed.get("geometry_points") or []
        has_point = parsed["lat"] is not None and parsed["lon"] is not None
        has_geometry = len(geometry_points) > 0
        if not has_point and not has_geometry:
            return False

        anchor_lat = parsed["lat"]
        anchor_lon = parsed["lon"]
        anchor_hae = parsed["hae"]
        if not has_point and has_geometry:
            anchor_lat, anchor_lon, anchor_hae = geometry_points[0]

        try:
            cursor = self.db_conn.execute(
                """INSERT OR IGNORE INTO cot_events
                   (session_id, uid, event_type, callsign, time, start, stale,
                    how, lat, lon, hae, ce, le, detail_xml, raw_xml)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    self.session_id,
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
                if geometry_points:
                    for i, (lat, lon, hae) in enumerate(geometry_points):
                        self.db_conn.execute(
                            """INSERT OR IGNORE INTO cot_geometry_points
                               (event_id, point_order, lat, lon, hae)
                               VALUES (?, ?, ?, ?, ?)""",
                            (event_id, i, lat, lon, hae),
                        )

                self.db_conn.execute(
                    "UPDATE recording_sessions SET events_count = events_count + 1 WHERE id = ?",
                    (self.session_id,),
                )
                self.db_conn.commit()
                return True

            self.db_conn.commit()
            return False
        except sqlite3.Error as e:
            self.log.warning("DB insert error: %s", e)
            return False

    def _on_message(self, _channel, _method, _properties, body):
        try:
            payload = json.loads(body.decode("utf-8", errors="replace"))
        except Exception:
            return

        cot = payload.get("cot")
        if not cot or "<event" not in cot:
            return

        self.record_event(cot)

    def run(self):
        self.init_db()

        while self.running:
            connection = None
            channel = None
            queue_name = None
            try:
                credentials = pika.PlainCredentials(self.username, self.password)
                params = pika.ConnectionParameters(
                    host=self.host,
                    port=self.port,
                    virtual_host=self.vhost,
                    credentials=credentials,
                    heartbeat=60,
                    blocked_connection_timeout=30,
                )
                connection = pika.BlockingConnection(params)
                channel = connection.channel()
                channel.exchange_declare(exchange=self.exchange, passive=True)

                result = channel.queue_declare(queue="", exclusive=True, auto_delete=True)
                queue_name = result.method.queue
                channel.queue_bind(
                    exchange=self.exchange, queue=queue_name, routing_key=self.routing_key
                )

                self.open_session()
                self.log.info(
                    "Consuming from exchange '%s' on %s:%d (queue=%s)",
                    self.exchange,
                    self.host,
                    self.port,
                    queue_name,
                )

                channel.basic_consume(
                    queue=queue_name, on_message_callback=self._on_message, auto_ack=True
                )

                while self.running:
                    connection.process_data_events(time_limit=1)

            except pika.exceptions.AMQPError as e:
                if self.running:
                    self.log.warning("RabbitMQ error: %s — retrying in %ds", e, RECONNECT_DELAY)
            except Exception as e:
                if self.running:
                    self.log.error("Unexpected error: %s — retrying in %ds", e, RECONNECT_DELAY)
            finally:
                self.close_session()
                if channel:
                    try:
                        if channel.is_open and queue_name:
                            channel.queue_delete(queue=queue_name)
                    except Exception:
                        pass
                if connection:
                    try:
                        connection.close()
                    except Exception:
                        pass

            if self.running:
                time.sleep(RECONNECT_DELAY)

        self.log.info("Recorder stopped")

    def stop(self, _signum=None, _frame=None):
        self.log.info("Shutdown signal received")
        self.running = False


def parse_args():
    parser = argparse.ArgumentParser(description="Heartbeat OpenTAK RabbitMQ CoT Recorder")
    parser.add_argument("--host", default="127.0.0.1", help="RabbitMQ host")
    parser.add_argument("--port", type=int, default=5672, help="RabbitMQ port")
    parser.add_argument("--username", default="guest", help="RabbitMQ username")
    parser.add_argument("--password", default="guest", help="RabbitMQ password")
    parser.add_argument("--vhost", default="/", help="RabbitMQ virtual host")
    parser.add_argument("--exchange", default="firehose", help="RabbitMQ exchange name")
    parser.add_argument("--routing-key", default="", help="Binding routing key")
    parser.add_argument("--db", default="data/cot_records.db", help="SQLite database path")
    parser.add_argument("--log", default="data/recorder.log", help="Log file path")
    return parser.parse_args()


def main():
    args = parse_args()
    recorder = RabbitCotRecorder(
        host=args.host,
        port=args.port,
        username=args.username,
        password=args.password,
        vhost=args.vhost,
        exchange=args.exchange,
        routing_key=args.routing_key,
        db_path=args.db,
        log_path=args.log,
    )

    signal.signal(signal.SIGTERM, recorder.stop)
    signal.signal(signal.SIGINT, recorder.stop)
    recorder.run()


if __name__ == "__main__":
    main()
