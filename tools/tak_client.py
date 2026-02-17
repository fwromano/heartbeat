#!/usr/bin/env python3
"""
Reusable TAK CoT TCP/SSL client.
"""

import logging
import socket
import ssl
import uuid
from datetime import datetime, timedelta, timezone


def _iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _iso_future(minutes=5):
    t = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    return t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class TakClient:
    """TCP/SSL client for sending CoT events to a TAK server."""

    def __init__(
        self,
        host,
        port,
        callsign,
        uid=None,
        use_ssl=False,
        cert_path=None,
        key_path=None,
        ca_path=None,
        platform="heartbeat",
        device="server",
        role="HQ",
        team="Cyan",
        logger=None,
    ):
        self.host = host
        self.port = port
        self.callsign = callsign
        self.uid = uid or f"{callsign}-{uuid.uuid4()}"
        self.use_ssl = use_ssl
        self.cert_path = cert_path
        self.key_path = key_path
        self.ca_path = ca_path
        self.platform = platform
        self.device = device
        self.role = role
        self.team = team
        self.sock = None
        self.log = logger or logging.getLogger("tak_client")

    def _make_sa_event(self):
        now = _iso_now()
        stale = _iso_future(5)
        return (
            '<?xml version="1.0" encoding="UTF-8"?>'
            f'<event version="2.0"'
            f' uid="{self.uid}"'
            f' type="a-f-G-U-C"'
            f' time="{now}"'
            f' start="{now}"'
            f' stale="{stale}"'
            f' how="m-g">'
            f'<point lat="0.0" lon="0.0" hae="0" ce="9999999" le="9999999"/>'
            f"<detail>"
            f'<contact callsign="{self.callsign}"/>'
            f'<__group name="{self.team}" role="{self.role}"/>'
            f'<precisionlocation altsrc="DTED0"/>'
            f'<takv version="heartbeat" platform="{self.platform}" device="{self.device}" os="linux"/>'
            f"</detail>"
            f"</event>"
        )

    def connect(self):
        """Establish connection and send SA identification."""
        self.close()

        raw_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        raw_sock.settimeout(5)

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
        self.sock.setblocking(True)

        mode = "SSL" if self.use_ssl else "TCP"
        self.log.info("Connected (%s) to %s:%d", mode, self.host, self.port)

        self.send_keepalive()
        self.log.info("SA event sent (callsign=%s, uid=%s)", self.callsign, self.uid)

    def send(self, cot_xml: str):
        """Send a CoT XML event. Raises OSError on connection failure."""
        if not self.sock:
            raise OSError("TAK client is not connected")
        self.sock.sendall(cot_xml.encode("utf-8"))

    def send_keepalive(self):
        """Send SA event to maintain connection."""
        self.send(self._make_sa_event())

    def close(self):
        """Close the socket."""
        if not self.sock:
            return
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass
        self.sock = None
