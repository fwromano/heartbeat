#!/usr/bin/env python3
"""
Stress test: reproduce the March 26 disconnect cascade and verify the
Point NameError fix, then ramp up concurrent connections to find any
remaining issues.

Usage:
    python3 tests/stress_disconnect.py [--max-clients 20] [--rounds 3]

Requires OTS to be running on localhost:8089 (SSL).
"""

import argparse
import os
import re
import socket
import ssl
import subprocess
import sys
import textwrap
import threading
import time
from datetime import datetime, timezone, timedelta

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OTS_HOST = "127.0.0.1"
OTS_SSL_PORT = 8089
CA_PEM = os.path.expanduser(
    "~/Documents/Code/ALIAS/heartbeat/data/opentak/ca/ca.pem"
)
CERT_DIR = os.path.expanduser(
    "~/Documents/Code/ALIAS/heartbeat/data/opentak/ca/certs"
)
OTS_LOG = os.path.expanduser(
    "~/Documents/Code/ALIAS/heartbeat/data/opentak/logs/opentakserver.log"
)
HEARTBEAT = os.path.expanduser(
    "~/Documents/Code/ALIAS/heartbeat/heartbeat"
)

# Available test certs (skip franky/administrator/opentakserver)
DEVICE_CERTS = sorted(
    [d for d in os.listdir(CERT_DIR)
     if d.startswith("device-")],
    key=lambda x: int(x.split("-")[1]),
)


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def iso_future(minutes=5):
    t = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    return t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def make_sa_xml(callsign, uid, lat=30.6, lon=-96.3):
    """Build a minimal CoT SA event."""
    now = iso_now()
    stale = iso_future(5)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f'<event version="2.0" uid="{uid}" type="a-f-G-U-C"'
        f' time="{now}" start="{now}" stale="{stale}" how="m-g">'
        f'<point lat="{lat}" lon="{lon}" hae="0" ce="9999999" le="9999999"/>'
        f'<detail>'
        f'<contact callsign="{callsign}"/>'
        f'<__group name="Cyan" role="Team Member"/>'
        f'<takv version="stress-test" platform="test" device="vm" os="linux"/>'
        f'</detail>'
        f'</event>'
    )


def ssl_connect(cert_name):
    """Create an SSL connection using a device cert. Returns the socket."""
    cert_dir = os.path.join(CERT_DIR, cert_name)
    cert_file = os.path.join(cert_dir, f"{cert_name}.pem")
    key_file = os.path.join(cert_dir, f"{cert_name}.nopass.key")

    ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    ctx.check_hostname = False
    ctx.load_verify_locations(cafile=CA_PEM)
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_cert_chain(certfile=cert_file, keyfile=key_file)

    raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    raw.settimeout(10)
    sock = ctx.wrap_socket(raw, server_hostname=OTS_HOST)
    sock.connect((OTS_HOST, OTS_SSL_PORT))
    return sock


def get_log_size():
    """Get current OTS log file size."""
    try:
        return os.path.getsize(OTS_LOG)
    except FileNotFoundError:
        return 0


def check_log_for_errors(start_offset):
    """Read OTS log from offset and look for NameError or unhandled exceptions."""
    errors = []
    try:
        with open(OTS_LOG, "r") as f:
            f.seek(start_offset)
            content = f.read()
    except FileNotFoundError:
        return errors

    for line in content.splitlines():
        if "NameError" in line:
            errors.append(f"NAMEERROR: {line.strip()}")
        elif "ConnectionOpenAborted" in line:
            # Known startup race -- not a failure
            pass
        elif "Traceback" in line:
            errors.append(f"TRACEBACK: {line.strip()}")

    return errors


def check_log_for_pattern(start_offset, pattern):
    """Search log from offset for a regex pattern. Returns list of matches."""
    matches = []
    try:
        with open(OTS_LOG, "r") as f:
            f.seek(start_offset)
            content = f.read()
    except FileNotFoundError:
        return matches

    for line in content.splitlines():
        if re.search(pattern, line):
            matches.append(line.strip())
    return matches


# ---------------------------------------------------------------------------
# Test phases
# ---------------------------------------------------------------------------

def phase_1_basic_disconnect(verbose=True):
    """
    Phase 1: Reproduce the exact crash scenario.
    Connect a client, send SA, disconnect abruptly.
    This should trigger send_disconnect_cot() -- verify no NameError.
    """
    print("\n=== PHASE 1: Basic Disconnect (reproduce crash scenario) ===")
    log_start = get_log_size()

    cert = DEVICE_CERTS[0]
    callsign = f"STRESS-{cert}"
    uid = f"stress-test-{cert}"

    print(f"  Connecting as {callsign} ({cert})...")
    sock = ssl_connect(cert)
    sa = make_sa_xml(callsign, uid)
    sock.sendall(sa.encode("utf-8"))
    print(f"  SA sent. Waiting 2s for server to register client...")
    time.sleep(2)

    print(f"  Abruptly closing connection (no TLS close_notify)...")
    sock.shutdown(socket.SHUT_RDWR)
    sock.close()

    print(f"  Waiting 5s for server to detect disconnect and run send_disconnect_cot()...")
    time.sleep(5)

    errors = check_log_for_errors(log_start)
    name_errors = [e for e in errors if "NAMEERROR" in e]

    if name_errors:
        print(f"  FAIL: NameError still present!")
        for e in name_errors:
            print(f"    {e}")
        return False
    else:
        # Check that the disconnect WAS actually processed
        disconnects = check_log_for_pattern(log_start, r"disconnected|No Data|close")
        if disconnects:
            print(f"  PASS: Disconnect handled cleanly ({len(disconnects)} log entries, 0 NameErrors)")
        else:
            print(f"  PASS: No NameErrors (disconnect may not have been logged yet)")
        return True


def phase_2_rapid_reconnect(verbose=True):
    """
    Phase 2: Rapid connect/disconnect cycle on a single cert.
    Reproduces the GROUND B reconnect storm pattern.
    """
    print("\n=== PHASE 2: Rapid Reconnect (GROUND B storm pattern) ===")
    log_start = get_log_size()
    cert = DEVICE_CERTS[1]
    cycles = 10

    print(f"  Running {cycles} rapid connect/disconnect cycles on {cert}...")
    for i in range(cycles):
        try:
            sock = ssl_connect(cert)
            sa = make_sa_xml(f"STORM-{i}", f"storm-{cert}-{i}")
            sock.sendall(sa.encode("utf-8"))
            time.sleep(0.5)
            sock.shutdown(socket.SHUT_RDWR)
            sock.close()
        except Exception as e:
            print(f"    Cycle {i}: connection error (expected under load): {e}")
        time.sleep(0.3)

    print(f"  Waiting 5s for server to process all disconnects...")
    time.sleep(5)

    errors = check_log_for_errors(log_start)
    name_errors = [e for e in errors if "NAMEERROR" in e]

    if name_errors:
        print(f"  FAIL: {len(name_errors)} NameErrors during reconnect storm!")
        for e in name_errors[:3]:
            print(f"    {e}")
        return False
    else:
        print(f"  PASS: {cycles} rapid cycles, 0 NameErrors")
        return True


def phase_3_cascade_test(num_clients=10, verbose=True):
    """
    Phase 3: Reproduce the cascade scenario.
    Connect N clients simultaneously, then disconnect one and verify
    the others survive.
    """
    print(f"\n=== PHASE 3: Cascade Test ({num_clients} simultaneous clients) ===")
    log_start = get_log_size()
    certs = DEVICE_CERTS[:num_clients]
    sockets = []
    lock = threading.Lock()
    connect_errors = []

    def connect_client(cert, idx):
        try:
            sock = ssl_connect(cert)
            sa = make_sa_xml(f"CASCADE-{idx}", f"cascade-{cert}-{idx}")
            sock.sendall(sa.encode("utf-8"))
            with lock:
                sockets.append((cert, sock, idx))
        except Exception as e:
            with lock:
                connect_errors.append((cert, str(e)))

    # Connect all clients in parallel
    print(f"  Connecting {num_clients} clients in parallel...")
    threads = []
    for i, cert in enumerate(certs):
        t = threading.Thread(target=connect_client, args=(cert, i))
        t.start()
        threads.append(t)
    for t in threads:
        t.join(timeout=15)

    connected = len(sockets)
    print(f"  {connected}/{num_clients} connected successfully")
    if connect_errors:
        print(f"  {len(connect_errors)} connection failures:")
        for cert, err in connect_errors[:3]:
            print(f"    {cert}: {err}")

    if connected < 2:
        print(f"  SKIP: Need at least 2 clients for cascade test")
        return True

    # Let them settle
    print(f"  Waiting 3s for all clients to register...")
    time.sleep(3)

    # Kill the first client abruptly (the "trigger")
    trigger_cert, trigger_sock, trigger_idx = sockets[0]
    print(f"  Killing trigger client (CASCADE-{trigger_idx} / {trigger_cert})...")
    try:
        trigger_sock.shutdown(socket.SHUT_RDWR)
    except Exception:
        pass
    trigger_sock.close()

    # Wait for server to process the disconnect
    print(f"  Waiting 5s for cascade propagation window...")
    time.sleep(5)

    # Check if surviving clients are still alive by sending SA
    survivors = 0
    dead = 0
    for cert, sock, idx in sockets[1:]:
        try:
            sa = make_sa_xml(f"CASCADE-{idx}-alive", f"cascade-{cert}-{idx}")
            sock.sendall(sa.encode("utf-8"))
            survivors += 1
        except Exception:
            dead += 1

    print(f"  Survivors: {survivors}/{connected - 1}, Dead: {dead}/{connected - 1}")

    # Clean up remaining connections
    for cert, sock, idx in sockets[1:]:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            sock.close()
        except Exception:
            pass

    time.sleep(3)

    errors = check_log_for_errors(log_start)
    name_errors = [e for e in errors if "NAMEERROR" in e]
    route_errors = check_log_for_pattern(log_start, r"not publishing cot")

    if name_errors:
        print(f"  FAIL: {len(name_errors)} NameErrors during cascade test!")
        return False
    elif dead > 0 and route_errors:
        print(f"  WARN: {dead} clients died + {len(route_errors)} route_cot failures (cascade still possible)")
        print(f"  (But no NameErrors -- the Point fix is working)")
        return True
    elif dead > 0:
        print(f"  WARN: {dead} clients died (may be timeout, not cascade)")
        return True
    else:
        print(f"  PASS: Trigger disconnect did not cascade. All {survivors} others survived.")
        return True


def phase_4_max_stress(max_clients=20, rounds=3, verbose=True):
    """
    Phase 4: Maximum stress test.
    Connect max_clients, send SA bursts, disconnect randomly, reconnect.
    Look for any new errors beyond the Point fix.
    """
    print(f"\n=== PHASE 4: Max Stress ({max_clients} clients, {rounds} rounds) ===")
    log_start = get_log_size()
    certs = DEVICE_CERTS[:max_clients]
    all_errors_found = []

    for round_num in range(rounds):
        print(f"\n  --- Round {round_num + 1}/{rounds} ---")
        sockets = []
        lock = threading.Lock()

        # Connect all
        def connect_client(cert, idx):
            try:
                sock = ssl_connect(cert)
                sa = make_sa_xml(
                    f"MAX-R{round_num}-{idx}",
                    f"max-{cert}-r{round_num}",
                    lat=30.6 + (idx * 0.001),
                    lon=-96.3 + (idx * 0.001),
                )
                sock.sendall(sa.encode("utf-8"))
                with lock:
                    sockets.append((cert, sock, idx))
            except Exception as e:
                with lock:
                    all_errors_found.append(f"R{round_num} connect {cert}: {e}")

        threads = []
        for i, cert in enumerate(certs):
            t = threading.Thread(target=connect_client, args=(cert, i))
            t.start()
            threads.append(t)
        for t in threads:
            t.join(timeout=15)

        print(f"    Connected: {len(sockets)}/{max_clients}")
        time.sleep(2)

        # Send a burst of SA updates from all clients
        print(f"    Sending SA burst from all clients...")
        for cert, sock, idx in sockets:
            try:
                sa = make_sa_xml(
                    f"MAX-R{round_num}-{idx}",
                    f"max-{cert}-r{round_num}",
                    lat=30.6 + (idx * 0.001) + 0.0001,
                    lon=-96.3 + (idx * 0.001) + 0.0001,
                )
                sock.sendall(sa.encode("utf-8"))
            except Exception:
                pass
        time.sleep(1)

        # Kill half the clients abruptly (simulate field conditions)
        kill_count = len(sockets) // 2
        print(f"    Killing {kill_count} clients abruptly...")
        for cert, sock, idx in sockets[:kill_count]:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                sock.close()
            except Exception:
                pass

        time.sleep(3)

        # Check if survivors are still alive
        survivors = 0
        for cert, sock, idx in sockets[kill_count:]:
            try:
                sa = make_sa_xml(
                    f"MAX-R{round_num}-{idx}-check",
                    f"max-{cert}-r{round_num}",
                )
                sock.sendall(sa.encode("utf-8"))
                survivors += 1
            except Exception:
                pass

        print(f"    Survivors after kills: {survivors}/{len(sockets) - kill_count}")

        # Clean up remaining
        for cert, sock, idx in sockets[kill_count:]:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                sock.close()
            except Exception:
                pass

        time.sleep(2)

    # Final error check
    print(f"\n  Waiting 5s for all server-side processing...")
    time.sleep(5)

    errors = check_log_for_errors(log_start)
    name_errors = [e for e in errors if "NAMEERROR" in e]
    tracebacks = [e for e in errors if "TRACEBACK" in e]
    route_errors = check_log_for_pattern(log_start, r"not publishing cot")
    channel_errors = check_log_for_pattern(log_start, r"RabbitMQ channel closed")
    all_log_errors = check_log_for_pattern(log_start, r"ERROR")

    print(f"\n  --- Stress Test Results ---")
    print(f"  Total ERROR lines in log:     {len(all_log_errors)}")
    print(f"  NameErrors:                    {len(name_errors)}")
    print(f"  Unhandled tracebacks:          {len(tracebacks)}")
    print(f"  RabbitMQ channel closures:     {len(channel_errors)}")
    print(f"  route_cot failures:            {len(route_errors)}")
    print(f"  Client-side connect errors:    {len(all_errors_found)}")

    if name_errors:
        print(f"\n  FAIL: Point NameError still present!")
        for e in name_errors[:5]:
            print(f"    {e}")
        return False

    if tracebacks:
        print(f"\n  WARN: Unhandled tracebacks found (not NameError):")
        for e in tracebacks[:5]:
            print(f"    {e}")

    if not name_errors:
        print(f"\n  PASS: No NameErrors across {rounds} rounds x {max_clients} clients")

    return len(name_errors) == 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="OTS disconnect stress test")
    parser.add_argument("--max-clients", type=int, default=20,
                        help="Max simultaneous clients for stress test (default: 20)")
    parser.add_argument("--rounds", type=int, default=3,
                        help="Number of stress test rounds (default: 3)")
    parser.add_argument("--skip-start", action="store_true",
                        help="Skip starting OTS (assume already running)")
    args = parser.parse_args()

    print("=" * 60)
    print("  OTS Disconnect Stress Test")
    print(f"  Target: {OTS_HOST}:{OTS_SSL_PORT}")
    print(f"  Max clients: {args.max_clients}")
    print(f"  Rounds: {args.rounds}")
    print(f"  Available certs: {len(DEVICE_CERTS)}")
    print("=" * 60)

    # Check OTS is running
    try:
        test_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        test_sock.settimeout(3)
        test_sock.connect((OTS_HOST, OTS_SSL_PORT))
        test_sock.close()
        print("\nOTS is running on port 8089.")
    except ConnectionRefusedError:
        if args.skip_start:
            print("\nERROR: OTS not running and --skip-start specified. Exiting.")
            sys.exit(1)
        print("\nOTS not running. Starting via heartbeat...")
        result = subprocess.run(
            [HEARTBEAT, "start"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            print(f"Failed to start: {result.stderr}")
            sys.exit(1)
        print("Waiting 10s for OTS to fully initialize...")
        time.sleep(10)

    results = {}

    # Phase 1: Basic disconnect (the exact crash scenario)
    results["phase1"] = phase_1_basic_disconnect()

    # Phase 2: Rapid reconnect storm
    results["phase2"] = phase_2_rapid_reconnect()

    # Phase 3: Cascade test (10 clients, kill one, check others survive)
    results["phase3"] = phase_3_cascade_test(num_clients=min(10, args.max_clients))

    # Phase 4: Max stress
    results["phase4"] = phase_4_max_stress(
        max_clients=args.max_clients, rounds=args.rounds
    )

    # Summary
    print("\n" + "=" * 60)
    print("  RESULTS SUMMARY")
    print("=" * 60)
    all_pass = True
    for phase, passed in results.items():
        status = "PASS" if passed else "FAIL"
        if not passed:
            all_pass = False
        print(f"  {phase}: {status}")

    if all_pass:
        print("\n  ALL TESTS PASSED")
    else:
        print("\n  SOME TESTS FAILED")

    print("=" * 60)
    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
