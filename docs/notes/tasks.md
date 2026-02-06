# Tasks

## In Progress

None.

## Backlog

- **[high] Update architecture diagram** — Remove beacon/webmap from `docs/architecture/architecture-v2.drawio` (manual edit in draw.io)
- **[med] DataPackage port conflicts** — Warn + disable or remap when port is already in use
- **[high] Backend abstraction** — Refactor FreeTAK-specific code behind interface (see `docs/planning/roadmap-tak-abstraction.md`)
- **[med] OpenTAK backend** — Add OpenTAK Server as alternative backend with built-in WebTAK
- **[low] TAK Server backend** — Add official TAK Server (tak.gov) support
- **[med] GeoPackage export** — Export CoT data (points, lines, polygons) to GPKG
- **[low] Federation support** — Connect multiple Heartbeat instances
- **[low] Add LICENSE file** — Document "free for humanity" philosophy

## Done

- ~~Headless cleanup~~ — Removed beacon/webmap components, cleaned foundation for backend abstraction
- ~~Docs reorganization~~ — Structured docs into planning/, guides/, architecture/, notes/
- ~~Scrap VM deployment code~~ — Removed `deploy_oracle_free_vm.sh`, `deploy_public_vm.sh`, oracle docs, `detect_public_ip()`
- ~~iTAK connection QR on download page~~ — Second QR code for iTAK "Add Server > Scan QR" flow
- ~~Lock down ports + harden default credentials~~
- ~~Auto-refresh Tailscale server IP~~
- ~~Tailscale setup helpers~~
