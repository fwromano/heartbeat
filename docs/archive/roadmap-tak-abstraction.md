# Heartbeat Development Roadmap: TAK Server Abstraction

> **Document:** Technical Roadmap & Architecture Vision
> **Created:** 2026-02-05
> **Updated:** 2026-02-10
> **Status:** Phases 1-3 and 5 COMPLETE. Phase 4 (TAK Server) not started.

---

## Vision Statement

Transform Heartbeat from a FreeTAKServer-specific tool into a **universal TAK server management layer** that supports multiple TAK server implementations through a pluggable backend architecture.

```
┌─────────────────────────────────────────────────────────────┐
│                     HEARTBEAT CLI                           │
│         (Unified interface for all TAK servers)             │
├─────────────────────────────────────────────────────────────┤
│                   ABSTRACTION LAYER                         │
│        (Common API for lifecycle, users, packages)          │
├───────────────┬───────────────────┬─────────────────────────┤
│   FreeTAK     │     OpenTAK       │      TAK Server         │
│   Backend     │     Backend       │      Backend            │
│  (headless)   │  (built-in map)   │    (tak.gov)            │
└───────────────┴───────────────────┴─────────────────────────┘
```

---

## Roadmap Phases

### Phase 1: Headless Core (COMPLETE)

**Goal:** Strip Heartbeat to its essential server management functions

**Branch:** `headless`

**Deliverables:**
- [x] Create headless branch
- [x] Document cleanup spec (`docs/archive/headless-cleanup-spec.md`)
- [x] Remove beacon component
- [x] Remove webmap/CoTView component
- [x] Clean configuration templates
- [x] Update documentation
- [x] Test core functionality

**Outcome:** A minimal, focused CLI that manages FreeTAKServer lifecycle without bundled visualization tools.

**Target:** Ready for March 25-26 demo (~March 11)

---

### Phase 2: Backend Abstraction Layer (COMPLETE)

**Goal:** Introduce a provider/backend architecture that decouples Heartbeat from FreeTAKServer specifics

**Estimated Effort:** Medium

#### 2.1 Define Backend Interface

Create a standardized interface that all TAK server backends must implement:

```bash
# Proposed: lib/backends/interface.sh

# Lifecycle (required - all backends)
backend_install()      # Install/setup the TAK server
backend_start()        # Start the server
backend_stop()         # Stop the server
backend_status()       # Return server status
backend_logs()         # Stream/show logs
backend_update()       # Update to latest version
backend_uninstall()    # Remove the server

# Package Generation (required - all backends)
backend_get_package()  # Get connection package (TCP or SSL)
backend_get_ports()    # Required ports

# Capabilities (query what backend supports)
backend_supports()     # Check capability: "ssl", "users", "webmap", "federation"

# Optional - only if backend_supports("users") returns true
backend_create_user()  # Create a TAK user
backend_delete_user()  # Remove a TAK user
backend_list_users()   # List all users

# Optional - only if backend_supports("ssl") returns true
backend_get_ssl_package()  # Get SSL cert enrollment package
```

**Capability Matrix:**

| Capability | FreeTAK (Lite) | OpenTAK (Standard) | TAK Server (Enterprise) |
|------------|----------------|--------------------|-----------------------|
| `ssl` | No | Yes | Yes |
| `users` | No* | Yes (via WebTAK) | Yes (via Admin UI) |
| `webmap` | No | Yes (built-in) | Yes (built-in) |
| `federation` | No | Limited | Yes |

*FreeTAK Lite is TCP-only, zero-auth for maximum simplicity

#### 2.2 Refactor FreeTAK as First Backend

```
lib/
├── backends/
│   ├── interface.sh       # Abstract interface definition
│   ├── freetak.sh         # FreeTAKServer implementation
│   └── common.sh          # Shared backend utilities
├── server.sh              # Calls backend_* functions
└── ...
```

#### 2.3 Configuration Extension

```bash
# config/heartbeat.conf

# Backend selection
TAK_BACKEND="freetak"    # Options: freetak, opentak, takserver

# Backend-specific settings follow...
```

---

### Phase 3: OpenTAK Server Backend (COMPLETE)

**Goal:** Add support for OpenTAK Server as an alternative backend

**Why OpenTAK:**
- Active open-source development
- **Built-in web map interface** (no need for external CoTView)
- Modern architecture
- Good Docker support
- Growing community

#### 3.1 OpenTAK Integration Points

| Feature | OpenTAK Approach |
|---------|------------------|
| Installation | Docker image or native |
| Web Map | Built-in at `:8080/webtak` |
| User Management | REST API or config file |
| SSL Certificates | Auto-generated or manual |
| Data Packages | Native support |

#### 3.2 Implementation

```
lib/backends/
├── opentak.sh             # OpenTAK backend implementation
└── opentak/
    ├── docker-compose.yml # OpenTAK Docker setup
    └── config.yml         # OpenTAK configuration template
```

#### 3.3 User Experience

```bash
# Setup with OpenTAK backend
./setup.sh --backend opentak

# Or switch existing installation
./heartbeat config set TAK_BACKEND opentak
./heartbeat reinstall

# Web map comes for free
./heartbeat start
# => Server running at :8087
# => Web map available at :8080/webtak
```

**Key Advantage:** OpenTAK's built-in WebTAK interface eliminates the need for a separate map viewer component, giving you visualization without the maintenance burden of CoTView.

---

### Phase 4: Official TAK Server Backend (tak.gov)

**Goal:** Support the official TAK Server from tak.gov for users who need full military/government-grade capabilities

**Why Official TAK Server:**
- Full feature parity with military deployments
- Official support channel
- Certified for government use
- Most complete protocol implementation
- Federation support
- Advanced data sync

#### 4.1 Considerations

| Aspect | Notes |
|--------|-------|
| **Licensing** | Requires tak.gov account and acceptance of terms |
| **Distribution** | Cannot redistribute; user must download from tak.gov |
| **Installation** | More complex; typically RPM/DEB packages or Docker |
| **Requirements** | PostgreSQL database, more resources |
| **Target Users** | Government agencies, military, large organizations |

#### 4.2 TAK Server Integration Points

| Feature | TAK Server Approach |
|---------|---------------------|
| User Management | Admin UI or REST API |
| Data Packages | Enrollment package generation |
| SSL Certificates | Server-managed certs |

#### 4.3 Implementation Approach

```
lib/backends/
├── takserver.sh           # TAK Server backend implementation
└── takserver/
    ├── docker-compose.yml # TAK Server Docker orchestration
    ├── setup-guide.md     # Manual steps user must complete
    └── config-templates/  # Configuration templates
```

#### 4.4 Guided Setup Flow

Since TAK Server cannot be auto-downloaded, Heartbeat provides guided setup:

```bash
./setup.sh --backend takserver

# Heartbeat output:
# >>> TAK Server Setup (tak.gov)
#
# TAK Server requires manual download from tak.gov:
#
# 1. Visit: https://tak.gov/products/tak-server
# 2. Log in with your tak.gov credentials
# 3. Download the Docker release (takserver-docker-X.X.zip)
# 4. Place the ZIP file in: /path/to/heartbeat/docker/takserver/
#
# [Press Enter when ready...]
```

#### 4.5 Feature Matrix

| Feature | FreeTAK | OpenTAK | TAK Server |
|---------|---------|---------|------------|
| Open Source | Yes | Yes | No |
| Free to Use | Yes | Yes | Yes* |
| Docker Support | Yes | Yes | Yes |
| Native Install | Yes | Yes | Yes |
| Built-in WebTAK | No | Yes | Yes |
| User Management | Yes | Yes | Yes |
| SSL/Certs | Basic | Good | Full |
| Federation | No | Limited | Full |
| Data Sync | Basic | Good | Full |
| REST API | Yes | Yes | Yes |
| Resource Usage | Low | Medium | Higher |
| Setup Complexity | Easy | Easy | Medium |
| **Recommended Deploy** | **Native (pip)** | **Docker** | **Docker** |

*TAK Server is free but requires tak.gov registration

> **Note:** FreeTAK (Lite) is a pure Python package — Docker is supported but not required. Native pip install in a venv is lighter and simpler for field laptops. Docker becomes the preferred deployment for OpenTAK and TAK Server where the infrastructure (PostgreSQL, WebTAK, certs) benefits from containerization.

---

### Phase 5: CoT Recording and GeoPackage Export (COMPLETE)

**Goal:** Capture CoT events and export to GIS-friendly GeoPackage

**Why:**
- Demonstrates Heartbeat as more than a TAK installer
- Enables GIS workflows and data analysis
- Critical for March demo

#### 5.1 Recording Pipeline

- Recorder connects as a CoT client and records all events
- SQLite storage in WAL mode for concurrent export
- Manual `record start/stop/status` commands

#### 5.2 Export Pipeline

- Raw export to 4-layer GeoPackage (positions, markers, routes, areas)
- GCM export with YAML-based mapping and exclusions
- No GDAL dependency, shapely only

---

## Architecture Evolution

### Current State (Pre-Headless)
```
heartbeat
└── Tightly coupled to FreeTAKServer
    ├── Beacon (embedded)
    ├── CoTView/WebMap (embedded)
    └── FTS-specific code throughout
```

### Phase 1 Complete (Headless)
```
heartbeat
└── Clean FreeTAKServer management
    ├── No beacon
    ├── No webmap
    └── Focused lifecycle management
```

### Phase 2 Complete (Abstraction)
```
heartbeat
├── CLI Layer (backend-agnostic)
├── Abstraction Layer (interface.sh)
└── Backends/
    └── freetak.sh
```

### Phase 3+ Complete (Multi-Backend)
```
heartbeat
├── CLI Layer (backend-agnostic)
├── Abstraction Layer (interface.sh)
└── Backends/
    ├── freetak.sh   (Lite — lightweight, open source)
    ├── opentak.sh   (Standard — built-in map, SSL, systemd)
    └── takserver.sh (Enterprise — future, tak.gov)
```

---

## Implementation Priority

| Phase | Priority | Effort | Status |
|-------|----------|--------|--------|
| 1. Headless Core | **HIGH** | Low | COMPLETE |
| 2. Abstraction Layer | **HIGH** | Medium | COMPLETE |
| 3. OpenTAK Backend | **HIGH** | Medium | COMPLETE |
| 4. TAK Server Backend | **LOW** | High | Not started |
| 5. CoT Export Engine | **HIGH** | Medium | COMPLETE |

---

## Success Metrics

### Phase 1 (Headless)
- [x] All tests pass without beacon/webmap
- [x] `./heartbeat start/stop/status` work cleanly
- [x] Package generation functional
- [x] Documentation updated

### Phase 2 (Abstraction)
- [x] Backend interface defined and documented
- [x] FreeTAK refactored to use interface
- [x] No FreeTAK-specific code in core CLI
- [x] Adding new backend requires only new backend file

### Phase 3 (OpenTAK)
- [x] OpenTAK installs via `./setup.sh --backend opentak`
- [x] All core commands work with OpenTAK
- [x] Built-in WebTAK accessible after start
- [x] User can switch between FreeTAK and OpenTAK

### Phase 4 (TAK Server)
- [ ] Guided setup flow for tak.gov download
- [ ] TAK Server lifecycle management works
- [ ] Federation configuration support
- [ ] Documentation for government users

### Phase 5 (CoT Export)
- [x] CoT recorder daemon with reconnect and WAL storage
- [x] Raw GeoPackage export (positions, markers, routes, areas)
- [x] GCM export with YAML mapping
- [x] CLI commands: `record` and `export`
- [x] Documentation and verification steps

---

## Open Questions

1. **Backend Switching:** Should users be able to switch backends on an existing installation, or require fresh setup?

2. **Data Migration:** If switching backends, can we migrate users/certs/packages?

3. **Feature Flags:** How do we handle commands that only work with certain backends (e.g., federation only on TAK Server)?

4. **Naming:** Should we rename from "Heartbeat" to something more generic that reflects multi-backend support?

---

## Next Steps (as of 2026-02-10)

1. ~~Implement CoT Export~~ - COMPLETE
2. ~~Stabilize OpenTAK~~ - COMPLETE (native systemd, SSL packages, health checks, reset)
3. **Validate end-to-end OpenTAK multi-device** - Confirm location + annotation sharing after reset (blocked on field test)
4. **Dynamic package serve** - Backlog (no implementation started; still using `python3 -m http.server`)
5. **Define TAK Server** - Backlog (tak.gov backend, future phase)

---

## References

- [FreeTAKServer GitHub](https://github.com/FreeTAKTeam/FreeTakServer)
- [OpenTAK GitHub](https://github.com/opentakserver/opentakserver)
- [TAK Server (tak.gov)](https://tak.gov/products/tak-server)
- [TAK Protocol Documentation](https://github.com/TAK-Product-Center/tak-ml)
