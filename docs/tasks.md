# Tasks

## In Progress

- **[high] CoTView — Replace FreeTAKHub WebMap** — Build a lightweight Python+Leaflet CoT viewer we control. Spec: `docs/cotview-spec.md`
- **[high] Persist FTS database** — Code complete, needs end-to-end test after Docker image rebuild. Test: `docker rmi docker-fts:latest && ./heartbeat start`, verify `docker/data/FTSDataBase.db` exists. Spec: `docs/persistence-webmap-spec.md`

---

### Lifecycle Cleanup Spec

#### Problem

Runtime artifacts accumulate and nobody cleans them. Node-RED drops junk files in the repo root, logs grow forever, stale packages and certs from old test runs survive across re-setups.

#### Artifact lifecycle

| Artifact | Created by | Survives stop? | Survives re-setup? |
|----------|-----------|---------------|-------------------|
| `data/*.pid` | start | No | No |
| `data/beacon.log`, `data/webmap.log` | start | Yes (append) | No |
| `data/webmap/` (binary + config) | webmap_install | Yes | Yes |
| `.config.nodes.json`, `.config.runtime.json`, `package.json`, `JsonDB/` | WebMap Node-RED (dumps in cwd) | No | No |
| `packages/*.zip` | adduser / serve | Yes | No (certs change) |
| `packages/index.html`, `packages/*.png` | serve | Yes | No |
| `docker/certs/*` | FTS container | Yes | No (fresh instance) |
| `docker/data/*` | FTS container | Yes | No |
| `docker/logs/*` | FTS container | Yes | No |
| `docker-compose.override.yml` | _docker_start | No | No |

#### Task 1: Fix WebMap cwd so Node-RED junk lands in `data/webmap/`

**File:** `lib/webmap.sh` — `webmap_start()` line 120

The `nohup` launches the WebMap binary from whatever the shell's cwd is. Node-RED drops `.config.nodes.json`, `.config.runtime.json`, `package.json`, and `JsonDB/` in cwd — currently the repo root.

**Find:**
```bash
    nohup "$bin" "${WEBMAP_DIR}/webMAP_config.json" >> "$WEBMAP_LOG_FILE" 2>&1 &
    echo $! > "$WEBMAP_PID_FILE"
```

**Replace with:**
```bash
    (cd "$WEBMAP_DIR" && nohup "$bin" "webMAP_config.json" >> "$WEBMAP_LOG_FILE" 2>&1) &
    echo $! > "$WEBMAP_PID_FILE"
```

`$WEBMAP_DIR` is `data/webmap/` which is already gitignored via `data/`.

#### Task 2: Clean transient artifacts on `stop`

**File 1:** `lib/webmap.sh` — `webmap_stop()`

After the existing `rm -f "$WEBMAP_PID_FILE"` (line 137), add cleanup of Node-RED runtime files:

```bash
    # Clean Node-RED runtime artifacts
    rm -f "${WEBMAP_DIR}/.config.nodes.json" "${WEBMAP_DIR}/.config.runtime.json" \
          "${WEBMAP_DIR}/package.json" 2>/dev/null
    rm -rf "${WEBMAP_DIR}/JsonDB" 2>/dev/null
```

**File 2:** `lib/server.sh` — `server_stop()`

After the existing PID cleanup block (line 115: `rm -f "$BEACON_PID_FILE" ...`), add log truncation and root-level junk cleanup:

```bash
    # Truncate logs (keep last 200 lines for debugging)
    for lf in "$BEACON_LOG_FILE" "$WEBMAP_LOG_FILE"; do
        if [[ -f "$lf" ]]; then
            tail -200 "$lf" > "${lf}.tmp" && mv "${lf}.tmp" "$lf"
        fi
    done

    # Clean Node-RED junk that may have leaked to repo root (pre-cwd-fix runs)
    rm -f "${HEARTBEAT_DIR}/.config.nodes.json" "${HEARTBEAT_DIR}/.config.runtime.json" \
          "${HEARTBEAT_DIR}/package.json" 2>/dev/null
    rm -rf "${HEARTBEAT_DIR}/JsonDB" 2>/dev/null
```

#### Task 3: Clean slate on re-setup

**File:** `setup.sh` — `main()`, after the "re-run setup" check

After line 113 (`fi` closing the existing config check block) and before line 116 (`ensure_dir "$CONFIG_DIR"`), insert:

```bash
    # ---- Clean previous installation artifacts ----
    if [[ -f "$HEARTBEAT_CONF" ]]; then
        log_step "Cleaning previous installation artifacts"

        # Stop running services
        source "${LIB_DIR}/server.sh"
        server_stop 2>/dev/null || true

        # Remove stale packages (certs will change on fresh setup)
        rm -f "${PACKAGES_DIR}"/*.zip "${PACKAGES_DIR}"/*.png "${PACKAGES_DIR}"/index.html 2>/dev/null

        # Remove Docker volumes (may be root-owned from container)
        if has_docker; then
            local compose_cmd
            compose_cmd=$(get_compose_cmd)
            if [[ -n "$compose_cmd" ]]; then
                (cd "$DOCKER_DIR" && $compose_cmd down -v 2>/dev/null) || true
            fi
        fi
        sudo rm -rf "${DOCKER_DIR}/certs" "${DOCKER_DIR}/data" "${DOCKER_DIR}/logs" 2>/dev/null || true
        ensure_dir "${DOCKER_DIR}/data"
        ensure_dir "${DOCKER_DIR}/logs"
        ensure_dir "${DOCKER_DIR}/certs"

        # Remove stale logs and runtime data
        rm -f "${DATA_DIR}"/*.log "${DATA_DIR}"/*.pid 2>/dev/null
        rm -f "${HEARTBEAT_DIR}/.config.nodes.json" "${HEARTBEAT_DIR}/.config.runtime.json" \
              "${HEARTBEAT_DIR}/package.json" 2>/dev/null
        rm -rf "${HEARTBEAT_DIR}/JsonDB" 2>/dev/null

        log_ok "Previous artifacts cleaned"
    fi
```

The `sudo rm` handles root-owned Docker files. The `|| true` means it silently continues if sudo isn't available.

#### Task 4: Add `./heartbeat clean` command

**File:** `heartbeat` (main CLI)

**Step A:** Add `clean` to the COMMANDS array (line 188):

**Find:**
```bash
COMMANDS=(start stop restart status listen logs qr adduser addusers tailscale beacon package packages serve info update systemd uninstall help)
```

**Replace with:**
```bash
COMMANDS=(start stop restart status listen logs qr adduser addusers tailscale beacon package packages serve clean info update systemd uninstall help)
```

**Step B:** Add `clean` to the help text. In `show_help()`, after the `uninstall` line (line 59):

**Find:**
```bash
    echo "  uninstall            Remove FreeTAKServer and optionally data"
```

**Add after:**
```bash
    echo "  clean                Remove all generated artifacts (packages, certs, logs)"
```

**Step C:** Add the `clean` case to the command dispatch. Before the `info)` case (line 344):

**Find:**
```bash
    info)
        cmd_info
```

**Add before:**
```bash
    clean)
        source "${LIB_DIR}/server.sh"
        server_stop 2>/dev/null || true
        load_config
        log_step "Cleaning all generated artifacts"
        rm -f "${PACKAGES_DIR}"/*.zip "${PACKAGES_DIR}"/*.png "${PACKAGES_DIR}"/index.html 2>/dev/null
        rm -f "${DATA_DIR}"/*.log "${DATA_DIR}"/*.pid 2>/dev/null
        rm -f "${HEARTBEAT_DIR}/.config.nodes.json" "${HEARTBEAT_DIR}/.config.runtime.json" \
              "${HEARTBEAT_DIR}/package.json" 2>/dev/null
        rm -rf "${HEARTBEAT_DIR}/JsonDB" 2>/dev/null
        if has_docker; then
            local compose_cmd
            compose_cmd=$(get_compose_cmd)
            if [[ -n "$compose_cmd" ]]; then
                (cd "$DOCKER_DIR" && $compose_cmd down -v 2>/dev/null) || true
            fi
        fi
        sudo rm -rf "${DOCKER_DIR}/certs" "${DOCKER_DIR}/data" "${DOCKER_DIR}/logs" 2>/dev/null || true
        ensure_dir "${DOCKER_DIR}/data"
        ensure_dir "${DOCKER_DIR}/logs"
        ensure_dir "${DOCKER_DIR}/certs"
        log_ok "Clean. Run ./setup.sh to start fresh."
        ;;
```

#### Files to modify

1. `lib/webmap.sh` — Task 1 (cwd fix) + Task 2 (webmap_stop cleanup)
2. `lib/server.sh` — Task 2 (log truncation + root junk cleanup)
3. `setup.sh` — Task 3 (clean slate on re-setup)
4. `heartbeat` — Task 4 (clean command)

#### Verification

```bash
# 1. WebMap cwd fix
./heartbeat start
ls .config.nodes.json 2>/dev/null         # should NOT exist at repo root
ls data/webmap/.config.nodes.json 2>/dev/null  # should exist here instead

# 2. Stop cleanup
./heartbeat stop
ls data/*.pid 2>/dev/null                 # nothing
ls data/webmap/.config.nodes.json 2>/dev/null  # gone
wc -l data/webmap.log                    # <= 200 lines

# 3. Re-setup clean slate
./setup.sh
ls docker/certs/                         # empty (fresh dirs only)
ls packages/*.zip                        # only the new setup package

# 4. Manual clean
./heartbeat clean
ls docker/data/                          # empty dirs only
ls packages/*.zip 2>/dev/null            # nothing
```

---

## Backlog

- **[med] DataPackage port conflicts** — Warn + disable or remap when port is already in use

## Done

- ~~Lifecycle-aware cleanup~~ — WebMap cwd fix, stop cleanup, re-setup clean slate, `./heartbeat clean` command
- ~~Scrap VM deployment code~~ — Removed `deploy_oracle_free_vm.sh`, `deploy_public_vm.sh`, oracle docs, `detect_public_ip()`
- ~~iTAK connection QR on download page~~ — Second QR code for iTAK "Add Server > Scan QR" flow
- ~~Beacon coordinate guard~~ — Skip beacon send when lat/lon empty instead of crashing
- ~~Lock down ports + harden default credentials~~
- ~~Default to Tailscale + enable WebMap~~
- ~~Auto-refresh Tailscale server IP~~
- ~~Tailscale setup helpers~~
