# Heartbeat Future Roadmap

> **Updated:** 2026-02-10
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

### Dynamic package serve
- Auto-generate next package when one is downloaded
- Hybrid: pre-gen one, kick off background gen when it's pulled
- Replace `python3 -m http.server` with custom handler in `tools/serve.py`

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

### Simulation Integration (ALIAS)

For training scenarios, inject simulated data into TAK:

**Recommended approach:** CoT Injection -- server-side only, no client changes. Sim sends CoT position events directly to TAK server. Clients see simulated units on the map.

```bash
# Future command
./heartbeat sim connect --source udp://sim-server:5000
```

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
