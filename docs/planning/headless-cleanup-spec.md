# Headless Branch Cleanup Specification

> **Branch:** `headless`
> **Purpose:** Remove beacon and webmap components to create a minimal, headless TAK server deployment
> **Created:** 2026-02-05

---

## Executive Summary

This document specifies the complete removal of the **Beacon** and **WebMap (CoTView)** components from Heartbeat. The goal is a streamlined, headless TAK server that focuses solely on:

- FreeTAKServer lifecycle management (start/stop/status)
- Connection package generation for team members
- QR code generation for mobile onboarding
- Docker and native deployment modes

---

## Components to Remove

### 1. Beacon Component

**Description:** Broadcasts the server/laptop as a map dot (CoT event) to FreeTAKServer at configurable intervals.

| Item | Type | Action |
|------|------|--------|
| `lib/beacon.sh` | File | **DELETE** |
| `data/beacon.pid` | Runtime | Auto-cleaned |
| `data/beacon.log` | Runtime | Auto-cleaned |

### 2. WebMap (CoTView) Component

**Description:** Real-time browser-based map viewer showing all connected TAK devices via WebSocket.

| Item | Type | Action |
|------|------|--------|
| `lib/webmap.sh` | File | **DELETE** |
| `lib/cotview.py` | File | **DELETE** |
| `lib/cotview.html` | File | **DELETE** |
| `data/webmap/` | Directory | **DELETE** (if exists) |
| `data/webmap.pid` | Runtime | Auto-cleaned |
| `data/webmap.log` | Runtime | Auto-cleaned |

### 3. Related Documentation

| Item | Action |
|------|--------|
| `docs/cotview-spec.md` | **DELETE** |
| `docs/persistence-webmap-spec.md` | **DELETE** |

---

## Files to Modify

### 1. `heartbeat` (Main CLI Entry Point)

**Location:** `/heartbeat`

#### Changes Required:

**A. Remove from COMMANDS array (line ~189):**
```bash
# BEFORE:
COMMANDS=(start stop restart status listen logs qr adduser addusers tailscale beacon package packages serve clean info update systemd uninstall help)

# AFTER:
COMMANDS=(start stop restart status listen logs qr adduser addusers tailscale package packages serve clean info update systemd uninstall help)
```

**B. Remove beacon from help text (line ~50):**
```bash
# DELETE this line:
echo "  beacon [cmd]         Send a server beacon (map dot)"
```

**C. Remove beacon command routing (lines ~325-328):**
```bash
# DELETE this entire case block:
    beacon)
        source "${LIB_DIR}/beacon.sh"
        beacon_cmd "$@"
        ;;
```

---

### 2. `lib/server.sh` (Server Lifecycle)

**Location:** `/lib/server.sh`

#### Changes Required:

**A. Remove beacon/webmap from `server_start()` (lines ~19-29):**
```bash
# DELETE these lines after _docker_start/_native_start:
    source "${LIB_DIR}/beacon.sh"
    beacon_start || true

    if [[ "${WEBMAP_ENABLED:-false}" == "true" ]]; then
        source "${LIB_DIR}/webmap.sh"
        webmap_start || true
    fi
```

**B. Remove beacon/webmap from `server_stop()` (lines ~103-119):**
```bash
# DELETE these lines:
    source "${LIB_DIR}/beacon.sh"
    beacon_stop || true

    if [[ "${WEBMAP_ENABLED:-false}" == "true" ]]; then
        source "${LIB_DIR}/webmap.sh"
        webmap_stop || true
    fi

    # Clean up stale PID files
    rm -f "$BEACON_PID_FILE" "$WEBMAP_PID_FILE" "$PID_FILE" 2>/dev/null

    # Truncate logs (keep last 200 lines for debugging)
    for lf in "$BEACON_LOG_FILE" "$WEBMAP_LOG_FILE"; do
        if [[ -f "$lf" ]]; then
            tail -200 "$lf" > "${lf}.tmp" && mv "${lf}.tmp" "$lf"
        fi
    done
```

**Replace with:**
```bash
    # Clean up stale PID file
    rm -f "$PID_FILE" 2>/dev/null
```

**C. Remove beacon_status from `server_status()` (lines ~252-254):**
```bash
# DELETE these lines:
    source "${LIB_DIR}/beacon.sh"
    beacon_status
    echo ""
```

---

### 3. `lib/common.sh` (Shared Utilities)

**Location:** `/lib/common.sh`

#### Changes Required:

**A. Remove WebMap/Beacon path definitions (lines ~50-58):**
```bash
# DELETE these lines:
WEBMAP_DIR="${DATA_DIR}/webmap"

WEBMAP_PID_FILE="${DATA_DIR}/webmap.pid"
WEBMAP_LOG_FILE="${DATA_DIR}/webmap.log"
BEACON_PID_FILE="${DATA_DIR}/beacon.pid"
BEACON_LOG_FILE="${DATA_DIR}/beacon.log"
```

---

### 4. `config/heartbeat.conf.example` (Configuration Template)

**Location:** `/config/heartbeat.conf.example`

#### Changes Required:

**A. Remove WebMap configuration section (lines ~32-41):**
```bash
# DELETE this entire section:
# Web map (CoTView)
WEBMAP_ENABLED="true"
WEBMAP_PORT=8000
WEBMAP_VIEW_LAT="30.63443"
WEBMAP_VIEW_LON="-96.47834"
WEBMAP_VIEW_ZOOM=15
# Optional CoTView settings
# COTVIEW_FTS_HOST="127.0.0.1"
# COTVIEW_FTS_PORT=8087
# COTVIEW_STALE_SECONDS=300
```

**B. Remove Beacon configuration section (lines ~43-49):**
```bash
# DELETE this entire section:
# Beacon (shows server/laptop as a map dot)
BEACON_ENABLED="true"
BEACON_NAME="Heartbeat Beacon"
BEACON_INTERVAL=10
BEACON_LAT="30.63443"
BEACON_LON="-96.47834"
BEACON_ALT=0
```

---

### 5. `setup.sh` (Installation Script)

**Location:** `/setup.sh`

#### Changes Required:

Review and remove any beacon/webmap initialization logic, including:
- Default coordinate prompts for beacon position
- WebMap port configuration
- Any WEBMAP_* or BEACON_* variable initialization

---

### 6. `README.md` (User Documentation)

**Location:** `/README.md`

#### Changes Required:

- Remove any feature mentions of:
  - "Beacon system (shows server as a map dot)"
  - "Web-based map viewer (WebMap/CoTView)"
  - "Real-time browser-based map"
- Update feature list to reflect headless nature
- Remove usage examples involving `beacon` command

---

## Cleanup Tasks Checklist

### Phase 1: Delete Files
- [ ] Delete `lib/beacon.sh`
- [ ] Delete `lib/webmap.sh`
- [ ] Delete `lib/cotview.py`
- [ ] Delete `lib/cotview.html`
- [ ] Delete `docs/cotview-spec.md`
- [ ] Delete `docs/persistence-webmap-spec.md`
- [ ] Delete `data/webmap/` directory (if exists)

### Phase 2: Modify Core Files
- [ ] Edit `heartbeat` - remove beacon command and help text
- [ ] Edit `lib/server.sh` - remove beacon/webmap lifecycle calls
- [ ] Edit `lib/common.sh` - remove beacon/webmap path variables
- [ ] Edit `config/heartbeat.conf.example` - remove beacon/webmap config sections

### Phase 3: Update Documentation
- [ ] Edit `README.md` - remove beacon/webmap feature descriptions
- [ ] Review `docs/field-quickstart.md` for beacon/webmap references
- [ ] Review `docs/network-options.md` for beacon/webmap references
- [ ] Review `docs/tasks.md` for outdated task references

### Phase 4: Testing
- [ ] Verify `./heartbeat start` works without errors
- [ ] Verify `./heartbeat stop` works without errors
- [ ] Verify `./heartbeat status` displays correctly
- [ ] Verify `./heartbeat package "Test"` generates package
- [ ] Verify `./heartbeat qr` displays QR code
- [ ] Verify `./heartbeat help` shows updated commands

### Phase 5: Cleanup
- [ ] Run `./heartbeat clean` to remove any leftover artifacts
- [ ] Verify no orphaned references in codebase with grep
- [ ] Commit changes with descriptive message

---

## Code Changes Summary

| File | Lines Removed | Lines Modified |
|------|---------------|----------------|
| `lib/beacon.sh` | 226 | 0 (deleted) |
| `lib/webmap.sh` | 145 | 0 (deleted) |
| `lib/cotview.py` | ~300 | 0 (deleted) |
| `lib/cotview.html` | ~200 | 0 (deleted) |
| `heartbeat` | ~8 | 0 |
| `lib/server.sh` | ~20 | ~2 |
| `lib/common.sh` | ~6 | 0 |
| `config/heartbeat.conf.example` | ~18 | 0 |

**Total estimated lines removed:** ~900+

---

## Verification Commands

After completing all changes, run these commands to verify cleanup:

```bash
# Check for any remaining beacon references
grep -r "beacon" lib/ heartbeat config/ --include="*.sh" --include="*.py"

# Check for any remaining webmap references
grep -r "webmap\|cotview\|WEBMAP\|COTVIEW" lib/ heartbeat config/ --include="*.sh" --include="*.py"

# Verify deleted files don't exist
ls lib/beacon.sh lib/webmap.sh lib/cotview.py lib/cotview.html 2>&1 | grep "No such file"

# Test basic functionality
./heartbeat help
./heartbeat status
```

---

## Architecture After Cleanup

```
heartbeat/
├── heartbeat              Main CLI (simplified)
├── setup.sh               Installation script (simplified)
├── config/
│   ├── heartbeat.conf           Runtime config
│   └── heartbeat.conf.example   Template (no beacon/webmap)
├── lib/
│   ├── common.sh          Utilities (cleaned)
│   ├── server.sh          FTS lifecycle (cleaned)
│   ├── package.sh         Connection packages (unchanged)
│   ├── qr.sh              QR generation (unchanged)
│   └── install.sh         System installation (unchanged)
├── docker/
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── entrypoint.sh
│   └── FTSConfig.yaml
├── templates/             (unchanged)
├── packages/              (unchanged)
└── docs/
    ├── headless-cleanup-spec.md  (this file)
    ├── field-quickstart.md       (updated)
    └── network-options.md        (reviewed)
```

---

## Remaining Commands After Cleanup

| Command | Description |
|---------|-------------|
| `start` | Start the TAK server |
| `stop` | Stop the TAK server |
| `restart` | Restart the TAK server |
| `status` | Show server status and port checks |
| `listen` | Live monitor - follow connections and events |
| `logs [-f]` | View server logs |
| `qr` | Show QR code for iTAK/ATAK |
| `adduser <name>` | Create a TAK server login |
| `addusers <file>` | Bulk create users from file |
| `tailscale` | Set SERVER_IP to Tailscale IP |
| `package <name>` | Generate connection package |
| `packages` | List generated packages |
| `serve [port]` | HTTP serve packages for download |
| `clean` | Remove generated artifacts |
| `info` | Show server connection details |
| `update` | Update FreeTAKServer |
| `systemd` | Install systemd service |
| `uninstall` | Remove FreeTAKServer |
| `help` | Show help |

---

## Notes

1. **Backward Compatibility:** Existing `heartbeat.conf` files with BEACON_* and WEBMAP_* variables will still work - they'll simply be ignored. No migration script needed.

2. **Data Cleanup:** The `./heartbeat clean` command should be run after the changes to remove any leftover beacon/webmap artifacts from previous runs.

3. **Docker Compose Override:** The docker-compose.override.yml file that adds localhost binding for WebMap connectivity can be removed or simplified since WebMap no longer needs it.

4. **Future Considerations:** If map visualization is needed in the future, consider integrating with external TAK visualization tools rather than bundling CoTView.
