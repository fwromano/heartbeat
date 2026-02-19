# Heartbeat Future Roadmap

> **Updated:** 2026-02-11
> **Context:** Phases 1-4 (headless core, backend abstraction, OpenTAK, CoT export) are complete.
> Detailed specs for completed work are archived in `docs/archive/`.

---

## What's Done

| Phase | What | Status |
|-------|------|--------|
| Headless Core | Removed beacon/webmap, clean CLI | COMPLETE |
| Backend Abstraction | interface.sh contract, freetak.sh, opentak.sh | COMPLETE |
| OpenTAK Backend | Native systemd, SSL packages, WebTAK, health checks, reset | COMPLETE |
| CoT Export | Recorder daemon, raw + GCM GeoPackage export, auto-record lifecycle | COMPLETE |

---

## Near-Term (pre-demo)

### Validate end-to-end OpenTAK multi-device
- Confirm location + annotation sharing between devices after `./heartbeat reset`
- Both devices on unique certs, RabbitMQ channels stay clean

### Recorder reliability hardening
- Add recorder watchdog checks to `./heartbeat status` (not just PID presence)
- Track ingest freshness (`last_event_at`, events in current session) and alert when stale
- Decide whether restart should auto-heal recorder when ingest stalls

### OpenTAK portability improvement
- Investigate containerized Standard tier (OTS + Postgres + RabbitMQ) for faster moves/resets
- Compare operational tradeoffs vs current native/systemd install (security, performance, maintenance)

### Shell test baseline (bats-core)
- Add minimal CI-safe tests for `resolve_cmd`, `set_config`, backend defaults, and parsing assumptions
- Build a small fixture matrix for OpenTAK/FreeTAK config permutations

---

## Future Phases

### TAK Server Backend (Enterprise tier)

Add official TAK Server from tak.gov for government/military users.

- Requires tak.gov account and acceptance of terms
- Cannot redistribute; user must download from tak.gov
- Guided setup: `./setup.sh --backend takserver` prompts user to provide the ZIP
- Full federation, data sync, certified for government use

| Feature | FreeTAK | OpenTAK | TAK Server |
|---------|---------|---------|------------|
| Open Source | Yes | Yes | No |
| Free to Use | Yes | Yes | Yes* |
| Built-in WebTAK | No | Yes | Yes |
| Federation | No | Limited | Full |
| SSL/Certs | Basic | Good | Full |

*TAK Server is free but requires tak.gov registration

### Federation

Connect multiple Heartbeat instances to share SA across organizations.

**Modes:**
- Hub-Spoke: EOC aggregates field teams
- Peer-to-Peer: two agencies share during an incident
- Mesh: all servers interconnected

**Data flow:**
- Outbound: positions, markers, drawings, chat (configurable filters)
- Inbound: federated positions appear as external contacts
- Filtering by callsign, group, bounding box, or data type

**Backend support:**
- FreeTAK: limited/custom implementation
- OpenTAK: partial (SSL mutual auth)
- TAK Server: full (native federation protocol)

### Browser TAK Interface (WebTAK + CloudTAK)

Track browser-first TAK access for teams that want map ops without installing ATAK/iTAK on every endpoint.

**Scope:**
- Keep OpenTAK WebTAK support as the default browser path in Heartbeat Standard
- Evaluate CloudTAK integration path for browser-based TAK workflows
- Decide whether CloudTAK is:
  - a separate backend target, or
  - an auxiliary web interface attached to existing backends

**Evaluation criteria:**
- Licensing and redistribution model (confirm open-source status and packaging constraints)
- Authentication model and certificate compatibility with existing package flow
- Mission/Data Sync compatibility for operator workflows
- Deployment fit (native/systemd vs container) and operational complexity
- Feature parity vs OpenTAK WebTAK for field requirements

**Proposed deliverables:**
- Capability matrix: OpenTAK WebTAK vs CloudTAK
- Minimal proof-of-concept deployment guide
- Recommendation: adopt, defer, or keep as optional experimental backend

### Simulation Integration (ALIAS)

For training scenarios, inject simulated data into TAK:

**Recommended approach:** CoT Injection -- server-side only, no client changes. Sim sends CoT position events directly to TAK server. Clients see simulated units on the map.

```bash
# Future command
./heartbeat sim connect --source udp://sim-server:5000
```

### Dynamic Package Serve

Auto-generate next package when one is downloaded, so the serve page always has a fresh unique package ready. Replace `python3 -m http.server` with custom handler in `tools/serve.py`.

> **Status:** No implementation exists. Currently using basic `python3 -m http.server`.

### GPKG Import Pipeline

Read features from a GeoPackage file, generate CoT XML events, and inject them into a running TAK server. See `docs/planning/gpkg-import-spec.md` for the design spec.

> **Status:** Designed but NOT IMPLEMENTED. Zero implementation code exists.

### External Data Inputs

| Data Source | Protocol | TAK Display | Use Case |
|-------------|----------|-------------|----------|
| ADS-B Receiver | dump1090 | Aircraft icons | Airspace deconfliction |
| APRS Gateway | APRS-IS | HAM radio positions | Mutual aid, SAR |
| AVL/GPS Trackers | Varies | Vehicle positions | Fleet tracking |
| Weather Stations | METAR/TAF | Weather markers | Ops planning |

---

## Open Questions

1. **Backend switching:** Should users be able to switch backends on an existing install, or require fresh setup?
2. **Data migration:** If switching backends, can we migrate users/certs/packages?
3. **Feature flags:** How to handle commands that only work with certain backends (e.g., federation only on TAK Server)?

---

## Licensing Philosophy

**Free for the prosperity of humanity.** All ALIAS software is free and open when legally possible.

- FreeTAK: open source, free -- Heartbeat Lite is free
- OpenTAK: open source, free -- Heartbeat Standard is free
- TAK Server: restricted distribution -- users must obtain it themselves, Heartbeat's integration layer is still free

---

## References

- [FreeTAKServer GitHub](https://github.com/FreeTAKTeam/FreeTakServer)
- [OpenTAK GitHub](https://github.com/brian7704/OpenTAKServer)
- [TAK Server (tak.gov)](https://tak.gov/products/tak-server)
- [CloudTAK GitHub](https://github.com/dfpc-coe/CloudTAK)
