# Tasks

## In Progress

- **[med] End-to-end OpenTAK validation** -- Setup works, devices connect, certs generate. Need to confirm multi-device location + annotation sharing after `./heartbeat reset` clears stale RabbitMQ state.
- **[med] Dynamic package serve** -- Auto-generate next package when one is downloaded, so the serve page always has a fresh unique package ready.

## Backlog

- **[med] Rethink iTAK server QR** -- What should the iTAK "Add Server > Scan QR" code contain for TCP-only? Currently not working in iTAK.
- **[med] DataPackage port conflicts** -- Warn + disable or remap when port is already in use
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
