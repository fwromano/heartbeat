#!/usr/bin/env python3
"""
Apply durable Heartbeat runtime patches to OpenTAK's eud_handler client_controller.

This script is idempotent and safe to re-run after setup or package upgrades.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ON_CHANNEL_CLOSE_PATCH = """\
    def on_channel_close(self, channel: Channel, error):
        self.logger.error(
            f"RabbitMQ channel closed for {self.callsign or self.address}: {error!r}"
        )
        self.rabbit_channel = None

        # Keep the EUD socket alive and try to recover the broker channel.
        # Hard-disconnecting here causes repeated reconnect storms and dropped CoT.
        if (
            self.rabbit_connection
            and not self.rabbit_connection.is_closing
            and not self.rabbit_connection.is_closed
        ):
            try:
                self.rabbit_connection.ioloop.add_callback_threadsafe(
                    lambda: self.rabbit_connection.channel(on_open_callback=self.on_channel_open)
                )
                self.logger.warning(
                    f"Attempting RabbitMQ channel recovery for {self.callsign or self.address}"
                )
                return
            except BaseException as exc:
                self.logger.error(
                    f"RabbitMQ channel recovery failed for {self.callsign or self.address}: {exc}"
                )
                self.logger.error(traceback.format_exc())

        # Final fallback: close this client connection.
        self.shutdown = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
"""


ON_CHANNEL_OPEN_PATCH = """\
    def on_channel_open(self, channel: Channel):
        self.logger.debug(f"Opening RabbitMQ channel for {self.callsign or self.address}")
        self.rabbit_channel = channel
        self.rabbit_channel.add_on_close_callback(self.on_channel_close)

        # Race-proof recorder queue setup: parse_device_info can run before the
        # AMQP channel is fully open. Ensure recorder bindings/consumers exist
        # as soon as the channel comes up.
        if self.uid and self.callsign and self.callsign.startswith("HB-REC-"):
            self.rabbit_channel.queue_declare(queue=self.uid)
            self.rabbit_channel.queue_bind(
                exchange="groups",
                queue=self.uid,
                routing_key="__HEARTBEAT_RECORDER__.OUT",
            )
            if {
                "exchange": "groups",
                "routing_key": "__HEARTBEAT_RECORDER__.OUT",
                "queue": self.uid,
            } not in self.bound_queues:
                self.bound_queues.append(
                    {
                        "exchange": "groups",
                        "routing_key": "__HEARTBEAT_RECORDER__.OUT",
                        "queue": self.uid,
                    }
                )
            self.rabbit_channel.basic_consume(
                queue=self.uid, on_message_callback=self.on_message, auto_ack=True
            )

        for message in self.cached_messages:
            self.route_cot(message)

        self.cached_messages.clear()
"""

EUD_SOCKETIO_PUBLISH_PATCH = """\
                # Save the EUD info for local state. Do not publish to flask-socketio
                # here: some deployments do not provision that exchange and RabbitMQ
                # will close this channel on publish, dropping CoT routing.
                self.eud = eud
                # NOTE: If WebSocket map fanout is needed, it should be gated behind
                # an explicit config flag and guaranteed exchange declaration.
"""

PARSE_DEVICE_INFO_IDENTITY_PATCH = """\
        contact = event.find("contact")
        takv = event.find("takv")
        event_type = event.attrs.get("type", "")

        # Prefer SA events; if missing, only accept events that still carry
        # TAK client metadata (<takv>). This avoids shape UID/callsign hijacks.
        if event_type != "a-f-G-U-C" and not takv:
            return

        if takv or contact:
            uid = event.attrs.get("uid")
        else:
            return

        contact = event.find("contact")
"""


RECORDER_TAP_BIND_PATCH = """\
                    self.rabbit_channel.queue_declare(queue=callsign_queue)
                    self.rabbit_channel.queue_declare(queue=self.uid)

                    if self.callsign and self.callsign.startswith("HB-REC-"):
                        self.rabbit_channel.queue_bind(
                            exchange="groups",
                            queue=self.uid,
                            routing_key="__HEARTBEAT_RECORDER__.OUT",
                        )
                        if {
                            "exchange": "groups",
                            "routing_key": "__HEARTBEAT_RECORDER__.OUT",
                            "queue": self.uid,
                        } not in self.bound_queues:
                            self.bound_queues.append(
                                {
                                    "exchange": "groups",
                                    "routing_key": "__HEARTBEAT_RECORDER__.OUT",
                                    "queue": self.uid,
                                }
                            )
"""


ROUTE_COT_PATCH = """\
    def route_cot(self, event):
        if not event:
            return
        try:
            if not self.rabbit_channel or not self.rabbit_channel.is_open:
                self.cached_messages.append(event)
                self.logger.error("RabbitMQ channel is closed, caching cot")
                return

            # Route all CoTs to the firehose exchange for plugins and users that connect directly to RabbitMQ
            self.rabbit_channel.basic_publish(
                exchange="firehose",
                body=json.dumps({"uid": self.uid, "cot": str(event)}),
                routing_key="",
                properties=pika.BasicProperties(
                    expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                ),
            )

            # Route all cots to the cot_parser direct exchange to be processed by a pool of cot_parser processes
            self.rabbit_channel.basic_publish(
                exchange="cot_parser",
                body=json.dumps({"uid": self.uid, "cot": str(event)}),
                routing_key="cot_parser",
                properties=pika.BasicProperties(
                    expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                ),
            )

            # Heartbeat recorder tap: duplicate all routed CoT to a dedicated key.
            # Recorder clients bind to this key and can capture without changing
            # normal group membership semantics.
            self.rabbit_channel.basic_publish(
                exchange="groups",
                routing_key="__HEARTBEAT_RECORDER__.OUT",
                body=json.dumps({"uid": self.uid, "cot": str(event)}),
                properties=pika.BasicProperties(
                    expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                ),
            )

            mission_changes = []
            destinations = event.find_all("dest")
            if destinations:
                for destination in destinations:
                    creator = event.find("creator")
                    creator_uid = self.uid
                    if creator and "uid" in creator.attrs:
                        creator_uid = creator.attrs["uid"]

                    # ATAK and WinTAK use callsign, iTAK uses uid
                    if "callsign" in destination.attrs and destination.attrs["callsign"]:
                        self.rabbit_channel.basic_publish(
                            exchange="dms",
                            routing_key=destination.attrs["callsign"],
                            body=json.dumps({"uid": self.uid, "cot": str(event)}),
                            properties=pika.BasicProperties(
                                expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                            ),
                        )

                    # iTAK uses its own UID in the <dest> tag when sending CoTs to a mission so we don't send those to the dms exchange
                    elif "uid" in destination.attrs and destination["uid"] != self.uid:
                        self.rabbit_channel.basic_publish(
                            exchange="dms",
                            routing_key=destination.attrs["uid"],
                            body=json.dumps({"uid": self.uid, "cot": str(event)}),
                            properties=pika.BasicProperties(
                                expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                            ),
                        )

                    # For data sync missions
                    elif "mission" in destination.attrs:
                        with self.app.app_context():
                            mission = self.db.session.execute(
                                self.db.session.query(Mission).filter_by(
                                    name=destination.attrs["mission"]
                                )
                            ).first()

                            if not mission:
                                self.logger.error(
                                    f"No such mission found: {destination.attrs['mission']}"
                                )
                                return

                            mission = mission[0]
                            self.rabbit_channel.basic_publish(
                                "missions",
                                routing_key=f"missions.{destination.attrs['mission']}",
                                body=json.dumps({"uid": self.uid, "cot": str(event)}),
                                properties=pika.BasicProperties(
                                    expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                                ),
                            )

                            mission_uid = self.db.session.execute(
                                self.db.session.query(MissionUID).filter_by(uid=event.attrs["uid"])
                            ).first()

                            if not mission_uid:
                                mission_uid = MissionUID()
                                mission_uid.uid = event.attrs["uid"]
                                mission_uid.mission_name = destination.attrs["mission"]
                                mission_uid.timestamp = datetime_from_iso8601_string(
                                    event.attrs["start"]
                                )
                                mission_uid.creator_uid = creator_uid
                                mission_uid.cot_type = event.attrs["type"]

                                color = event.find("color")
                                icon = event.find("usericon")
                                point = event.find("point")
                                contact = event.find("contact")

                                if color and "argb" in color.attrs:
                                    mission_uid.color = color.attrs["argb"]
                                elif color and "value" in color.attrs:
                                    mission_uid.color = color.attrs["value"]
                                if icon:
                                    mission_uid.iconset_path = icon["iconsetpath"]
                                if point:
                                    mission_uid.latitude = float(point.attrs["lat"])
                                    mission_uid.longitude = float(point.attrs["lon"])
                                if contact:
                                    mission_uid.callsign = contact.attrs["callsign"]

                                try:
                                    self.db.session.add(mission_uid)
                                    self.db.session.commit()
                                except sqlalchemy.exc.IntegrityError:
                                    self.db.session.rollback()
                                    self.db.session.execute(
                                        update(MissionUID).values(**mission_uid.serialize())
                                    )

                                mission_change = MissionChange()
                                mission_change.isFederatedChange = False
                                mission_change.change_type = MissionChange.ADD_CONTENT
                                mission_change.mission_name = destination.attrs["mission"]
                                mission_change.timestamp = datetime_from_iso8601_string(
                                    event.attrs["start"]
                                )
                                mission_change.creator_uid = creator_uid
                                mission_change.server_time = datetime_from_iso8601_string(
                                    event.attrs["start"]
                                )
                                mission_change.mission_uid = event.attrs["uid"]

                                self.db.session.execute(
                                    insert(MissionChange).values(**mission_change.serialize())
                                )
                                self.db.session.commit()

                                body = {
                                    "uid": self.app.config.get("OTS_NODE_ID"),
                                    "cot": tostring(
                                        generate_mission_change_cot(
                                            destination.attrs["mission"],
                                            mission,
                                            mission_change,
                                            cot_event=event,
                                        )
                                    ).decode("utf-8"),
                                }
                                mission_changes.append({"mission": mission.name, "message": body})
                                self.rabbit_channel.basic_publish(
                                    "missions",
                                    routing_key=f"missions.{mission.name}",
                                    body=json.dumps(body),
                                )

            if not destinations and not self.is_ssl:
                # Publish all CoT messages received by TCP and that have no destination to the __ANON__ group
                self.rabbit_channel.basic_publish(
                    exchange="groups",
                    routing_key="__ANON__.OUT",
                    body=json.dumps({"uid": self.uid, "cot": str(event)}),
                    properties=pika.BasicProperties(
                        expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                    ),
                )
                return

            if not destinations:
                with self.app.app_context():
                    group_memberships = db.session.execute(
                        db.session.query(GroupUser).filter_by(
                            user_id=self.user.id, direction=Group.IN, enabled=True
                        )
                    ).all()
                    if not group_memberships:
                        # Default to the __ANON__ group if the user doesn't belong to any IN groups
                        self.rabbit_channel.basic_publish(
                            exchange="groups",
                            routing_key="__ANON__.OUT",
                            body=json.dumps({"uid": self.uid, "cot": str(event)}),
                            properties=pika.BasicProperties(
                                expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                            ),
                        )

                    for membership in group_memberships:
                        membership = membership[0]
                        self.rabbit_channel.basic_publish(
                            exchange="groups",
                            routing_key=f"{membership.group.name}.{Group.OUT}",
                            body=json.dumps({"uid": self.uid, "cot": str(event)}),
                            properties=pika.BasicProperties(
                                expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                            ),
                        )

            if mission_changes:
                for change in mission_changes:
                    self.rabbit_channel.basic_publish(
                        "missions",
                        routing_key=f"missions.{change['mission']}",
                        body=json.dumps(change["message"]),
                        properties=pika.BasicProperties(
                            expiration=self.app.config.get("OTS_RABBITMQ_TTL")
                        ),
                    )
        except BaseException as exc:
            self.cached_messages.append(event)
            self.logger.error(
                f"route_cot publish failure for {self.callsign or self.address}: {exc}"
            )
            self.logger.error(traceback.format_exc())
            return
"""


def replace_block(text: str, start_rx: str, end_rx: str | None, replacement: str) -> tuple[str, bool]:
    start_match = re.search(start_rx, text, flags=re.MULTILINE)
    if not start_match:
        raise RuntimeError(f"Could not find block start pattern: {start_rx}")

    start_idx = start_match.start()
    if end_rx is None:
        end_idx = len(text)
    else:
        end_match = re.search(end_rx, text[start_match.end():], flags=re.MULTILINE)
        if not end_match:
            raise RuntimeError(f"Could not find block end pattern: {end_rx}")
        end_idx = start_match.end() + end_match.start()

    existing = text[start_idx:end_idx]
    if existing.rstrip() == replacement.rstrip():
        return text, False

    new_text = text[:start_idx] + replacement + "\n" + text[end_idx:]
    return new_text, True


def replace_eud_socketio_publish_block(text: str) -> tuple[str, bool]:
    start_marker = (
        "                # If the RabbitMQ channel is open, publish the EUD info to socketio "
        "to be displayed on the web UI map.\n"
        "                # Also save the EUD's info for on_channel_open to publish\n"
    )
    start_idx = text.find(start_marker)
    if start_idx == -1:
        # Already patched or upstream changed.
        return text, False

    end_marker = "    def send_meshtastic_node_info(self, eud):\n"
    end_idx = text.find(end_marker, start_idx)
    if end_idx == -1:
        raise RuntimeError("Could not locate end of EUD socketio publish block")

    new_text = text[:start_idx] + EUD_SOCKETIO_PUBLISH_PATCH + "\n" + text[end_idx:]
    return new_text, True


def replace_parse_device_info_identity_block(text: str) -> tuple[str, bool]:
    desired_guard = 'if event_type != "a-f-G-U-C" and not takv:\n'
    if desired_guard in text:
        return text, False

    start_markers = [(
        '        contact = event.find("contact")\n'
        '        takv = event.find("takv")\n\n'
        "        if takv or contact:\n"
        '            uid = event.attrs["uid"]\n'
        "        else:\n"
        "            return\n\n"
        '        contact = event.find("contact")\n'
    ), (
        '        contact = event.find("contact")\n'
        '        takv = event.find("takv")\n'
        '        event_type = event.attrs.get("type", "")\n'
        "\n"
        "        # Only use standard self-location CoT for device identity registration.\n"
        "        # Shape/annotation events can carry temporary UIDs and callsigns that\n"
        "        # should not become queue names.\n"
        '        if event_type != "a-f-G-U-C":\n'
        "            return\n"
        "\n"
        "        if takv or contact:\n"
        '            uid = event.attrs.get("uid")\n'
        "        else:\n"
        "            return\n"
        "\n"
        '        contact = event.find("contact")\n'
    )]

    for start_marker in start_markers:
        start_idx = text.find(start_marker)
        if start_idx != -1:
            end_idx = start_idx + len(start_marker)
            new_text = text[:start_idx] + PARSE_DEVICE_INFO_IDENTITY_PATCH + text[end_idx:]
            return new_text, True

    # Upstream changed or already patched in a different form.
    return text, False


def replace_legacy_recorder_broadcast_block(text: str) -> tuple[str, bool]:
    start_marker = (
        "                            # Heartbeat recorder sessions (HB-REC-*) should passively\n"
        "                            # observe all outbound group traffic for capture/export.\n"
        '                            if self.callsign and self.callsign.startswith("HB-REC-"):\n'
    )
    start_idx = text.find(start_marker)
    if start_idx == -1:
        return text, False

    end_marker = "                            if not group_memberships:\n"
    end_idx = text.find(end_marker, start_idx)
    if end_idx == -1:
        # Upstream shape changed; keep behavior unchanged if we can't safely trim.
        return text, False

    new_text = text[:start_idx] + text[end_idx:]
    return new_text, True


def replace_recorder_tap_bind_block(text: str) -> tuple[str, bool]:
    marker = (
        'self.rabbit_channel.queue_bind(\n'
        '                            exchange="groups",\n'
        '                            queue=self.uid,\n'
        '                            routing_key="__HEARTBEAT_RECORDER__.OUT",\n'
    )
    if marker in text:
        return text, False

    start_marker = (
        "                    self.rabbit_channel.queue_declare(queue=callsign_queue)\n"
        "                    self.rabbit_channel.queue_declare(queue=self.uid)\n"
    )
    start_idx = text.find(start_marker)
    if start_idx == -1:
        # Upstream changed or already patched in a different form.
        return text, False

    end_idx = start_idx + len(start_marker)
    new_text = text[:start_idx] + RECORDER_TAP_BIND_PATCH + text[end_idx:]
    return new_text, True


def target_file_from_venv(venv: Path) -> Path:
    matches = sorted(
        venv.glob("lib/python*/site-packages/opentakserver/eud_handler/client_controller.py")
    )
    if not matches:
        raise RuntimeError(f"Could not find client_controller.py under venv: {venv}")
    return matches[0]


def patch_file(path: Path) -> bool:
    original = path.read_text(encoding="utf-8")
    patched, changed_0 = replace_block(
        original,
        r"^    def on_channel_open\(self, channel: Channel\):\n",
        r"^    def on_channel_close\(self, channel: Channel, error\):\n",
        ON_CHANNEL_OPEN_PATCH,
    )
    patched, changed_1 = replace_block(
        patched,
        r"^    def on_channel_close\(self, channel: Channel, error\):\n",
        r"^    def on_close\(self, connection, error\):\n",
        ON_CHANNEL_CLOSE_PATCH,
    )
    patched, changed_2 = replace_block(
        patched,
        r"^    def route_cot\(self, event\):\n",
        None,
        ROUTE_COT_PATCH,
    )
    patched, changed_3 = replace_eud_socketio_publish_block(patched)
    patched, changed_4 = replace_parse_device_info_identity_block(patched)
    patched, changed_5 = replace_recorder_tap_bind_block(patched)
    patched, changed_6 = replace_legacy_recorder_broadcast_block(patched)

    if not (changed_0 or changed_1 or changed_2 or changed_3 or changed_4 or changed_5 or changed_6):
        return False

    path.write_text(patched, encoding="utf-8")
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Patch OpenTAK client_controller runtime behavior")
    parser.add_argument("--venv", required=True, help="OpenTAK venv path (e.g. data/opentak/venv)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    venv = Path(args.venv).expanduser().resolve()
    if not venv.exists():
        print(f"[error] venv does not exist: {venv}", file=sys.stderr)
        return 1

    target = target_file_from_venv(venv)
    changed = patch_file(target)
    print(f"[ok] patched {target}" if changed else f"[ok] already patched {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
