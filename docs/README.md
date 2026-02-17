# Heartbeat Documentation

> TAK Server Manager for the ALIAS Ecosystem

[Back to main README](../README.md)

---

## Architecture

System topology and technical reference.

| Document | Description |
|----------|-------------|
| [System Topology](architecture/topology.md) | Full architecture: ecosystem, backend abstraction, data pipeline, port allocation |

---

## Guides

User-facing documentation.

| Document | Description |
|----------|-------------|
| [Field Quickstart](guides/field-quickstart.md) | One-page runbook for getting a team online fast |
| [Network Options](guides/network-options.md) | LAN, Tailscale, cellular, MANET, and connectivity patterns |

---

## Command Surface

Current operational command groups in `./heartbeat`.

| Group | Commands |
|-------|----------|
| Server | `start`, `stop`, `restart`, `reset`, `status`, `listen`, `logs` |
| Team | `qr`, `tailscale`, `package`, `packages`, `serve` |
| Recording/Feeds/Export | `record`, `fire`, `export` |
| System | `info`, `update`, `systemd`, `uninstall`, `clean`, `help` |

---

## Specs

Implementation specifications (handed to developers).

| Document | Status | Description |
|----------|--------|-------------|
| [Backend Hardening](specs/backend-hardening.md) | Mostly implemented | Port mapping fix, credential cleanup, package simplification, health checks |

---

## Planning

Future roadmaps and design documents for features not yet implemented.

| Document | Status | Description |
|----------|--------|-------------|
| [Future Roadmap](planning/future.md) | Current | TAK Server backend, federation, simulation, external data inputs |
| [GPKG Import Spec](planning/gpkg-import-spec.md) | Not implemented | Design for injecting GeoPackage features into TAK as CoT events |

---

## Notes

Working notes and task tracking.

| File | Description |
|------|-------------|
| [tasks.md](notes/tasks.md) | Current task tracking (in-progress, backlog, done) |
| [TAK-sync.txt](notes/TAK-sync.txt) | Raw requirements notes from planning session (2026-02-05) |

---

## Archive

Completed specs and historical documents. These describe work that has already been implemented and are preserved for reference and design decision history.

| File | Status | Description |
|------|--------|-------------|
| [Headless Cleanup Spec](archive/headless-cleanup-spec.md) | COMPLETE | Phase 1: beacon/webmap removal |
| [CoT Export Spec](archive/cot-export-spec.md) | COMPLETE | Recording + GeoPackage export pipeline |
| [TAK Abstraction Roadmap](archive/roadmap-tak-abstraction.md) | Phases 1-3,5 COMPLETE | Backend abstraction phases 1-5 |
| [Platform Vision](archive/vision-heartbeat-platform.md) | Pillars 1,3 done; Pillar 2 future | Strategic vision: tiered TAK, federation, data export |
