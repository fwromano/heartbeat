#!/usr/bin/env python3
"""
Heartbeat package HTTP server.

For OpenTAK, /next-package generates and returns a unique per-device package
on each request so multiple operators can self-serve from one URL.
"""

import argparse
import re
import shutil
import subprocess
import threading
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


DEVICE_RE = re.compile(r"^device-(\d+)(?:_connection)?\.zip$")


def sanitize_member_name(name: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_-]", "", name.replace(" ", "_"))
    return safe


def next_device_name(packages_dir: Path) -> str:
    max_n = 0
    if packages_dir.exists():
        for path in packages_dir.iterdir():
            if not path.is_file():
                continue
            match = DEVICE_RE.match(path.name)
            if not match:
                continue
            n = int(match.group(1))
            if n > max_n:
                max_n = n
    return f"device-{max_n + 1}"


class PackageHTTPServer(ThreadingHTTPServer):
    def __init__(
        self,
        server_address,
        request_handler_class,
        *,
        packages_dir: Path,
        heartbeat_dir: Path,
        allow_opentak_auto: bool,
    ):
        super().__init__(server_address, request_handler_class)
        self.packages_dir = packages_dir
        self.heartbeat_dir = heartbeat_dir
        self.allow_opentak_auto = allow_opentak_auto
        self.generate_lock = threading.Lock()


class PackageHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, directory=None, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    @property
    def server_ctx(self) -> PackageHTTPServer:
        return self.server  # type: ignore[return-value]

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/next-package", "/api/next-package"):
            self._handle_next_package()
            return
        super().do_GET()

    def _handle_next_package(self):
        if not self.server_ctx.allow_opentak_auto:
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return

        with self.server_ctx.generate_lock:
            member_name = next_device_name(self.server_ctx.packages_dir)
            safe_name = sanitize_member_name(member_name)
            package_path = self.server_ctx.packages_dir / f"{safe_name}.zip"

            heartbeat_cmd = self.server_ctx.heartbeat_dir / "heartbeat"
            cmd = [str(heartbeat_cmd), "package", member_name]
            try:
                proc = subprocess.run(
                    cmd,
                    cwd=str(self.server_ctx.heartbeat_dir),
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
            except subprocess.TimeoutExpired:
                self.send_error(
                    HTTPStatus.GATEWAY_TIMEOUT,
                    "Package generation timed out",
                )
                return
            if proc.returncode != 0:
                body = "Package generation failed.\n\n"
                if proc.stderr:
                    body += proc.stderr.strip() + "\n"
                if proc.stdout:
                    body += proc.stdout.strip() + "\n"
                payload = body.encode("utf-8", errors="replace")
                self.send_response(HTTPStatus.INTERNAL_SERVER_ERROR)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return

            if not package_path.is_file():
                self.send_error(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    f"Generated package missing: {package_path.name}",
                )
                return

        size = package_path.stat().st_size
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", f'attachment; filename="{package_path.name}"')
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with package_path.open("rb") as f:
            shutil.copyfileobj(f, self.wfile)


def main():
    parser = argparse.ArgumentParser(description="Heartbeat package HTTP server")
    parser.add_argument("--bind", default="0.0.0.0", help="Bind host")
    parser.add_argument("--port", type=int, default=9000, help="Listen port")
    parser.add_argument("--packages-dir", required=True, help="Directory to serve")
    parser.add_argument("--heartbeat-dir", required=True, help="Heartbeat repo root")
    parser.add_argument(
        "--opentak-auto",
        action="store_true",
        help="Enable /next-package auto-generation endpoint",
    )
    args = parser.parse_args()

    packages_dir = Path(args.packages_dir).resolve()
    heartbeat_dir = Path(args.heartbeat_dir).resolve()
    packages_dir.mkdir(parents=True, exist_ok=True)

    handler = lambda *a, **kw: PackageHandler(  # noqa: E731
        *a, directory=str(packages_dir), **kw
    )
    httpd = PackageHTTPServer(
        (args.bind, args.port),
        handler,
        packages_dir=packages_dir,
        heartbeat_dir=heartbeat_dir,
        allow_opentak_auto=args.opentak_auto,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
