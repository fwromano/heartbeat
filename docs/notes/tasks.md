# Tasks

> **Last updated:** 2026-02-11

## In Progress

- **[med] End-to-end OpenTAK validation** -- Setup works, devices connect, certs generate. Need to confirm multi-device location + annotation sharing after `./heartbeat reset` clears stale RabbitMQ state. Requires field test with 2+ physical devices.

## Backlog

- **[med] Dynamic package serve** -- Auto-generate next package when one is downloaded. No implementation exists; still using `python3 -m http.server`. See `docs/planning/future.md`.
- **[med] Rethink iTAK server QR** -- What should the iTAK "Add Server > Scan QR" code contain for TCP-only? Currently not working in iTAK.
- **[med] DataPackage port conflicts** -- Warn + disable or remap when port is already in use
- **[low] GPKG import pipeline** -- Inject GeoPackage features into TAK server as CoT events. Design spec at `docs/planning/gpkg-import-spec.md`, zero implementation.
- **[high] Recorder watchdog + ingest health** -- Upgrade `./heartbeat status` from PID-only to ingest-aware health (last-event age, per-session event delta, recorder heartbeat) so silent recorder failures are surfaced during mission runtime.
- **[med] OpenTAK portability for Standard tier** -- Evaluate containerized OpenTAK stack (OTS + Postgres + RabbitMQ) to reduce host-coupled cleanup/reinstall burden and improve migration parity with Lite tier.
- **[med] Add shell test baseline (bats-core)** -- Add regression tests for command resolution + config mutation paths (`resolve_cmd`, `set_config`, backend selection, parser assumptions) to catch brittle shell/output changes early.
- **[low] TAK Server backend** -- Add official TAK Server (tak.gov) support
- **[low] Federation support** -- Connect multiple Heartbeat instances
- **[low] Add LICENSE file** -- Document "free for humanity" philosophy

## Done

- ~~Backend hardening~~ -- Port mapping fix, credential cleanup, package simplification, health checks, reset command
- ~~OpenTAK backend~~ -- Native systemd installer, SSL packages, WebTAK, per-device cert identity
- ~~Backend abstraction~~ -- Created lib/backends/ with interface.sh, freetak.sh, opentak.sh
- ~~Auto-increment device naming~~ -- `./heartbeat package` auto-names device-1, device-2, ...
- ~~CoT recording + GeoPackage export~~ -- Recorder daemon, SQLite storage, raw + GCM export, auto-record on start/stop
- ~~Headless cleanup~~ -- Removed beacon/webmap components, cleaned foundation
- ~~Remove adduser/addusers~~ -- TCP-only Lite tier doesn't need auth
- ~~Docs reorganization~~ -- Structured docs into planning/, guides/, architecture/, notes/
- ~~Scrap VM deployment code~~ -- Removed oracle/public deploy scripts
- ~~Lock down ports + harden default credentials~~
- ~~Auto-refresh Tailscale server IP~~
- ~~Tailscale setup helpers~~
