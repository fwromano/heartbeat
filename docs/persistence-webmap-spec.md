# Data Persistence + WebMap Fixes — Investigation & Fix Spec

## Status after first implementation pass

| Task | Status | Notes |
|------|--------|-------|
| A — DB persistence | **Broken** | Entrypoint change not in Docker image (stale cache) |
| B — WebMap FTS URL | **Partial** | Config rewrite to 127.0.0.1 works. Connection fails due to race condition |
| B — Beacon host | **Needs testing** | Code change in place, untested (server didn't fully boot) |
| B — Override file | **Needs testing** | Generated correctly, needs port-conflict check |
| C — Browser auto-open | **Needs testing** | Code in place, not reached during failed test |
| D — PID cleanup | **Working** | Confirmed: no stale PIDs after stop |
| D — Override cleanup | **Working** | Confirmed: override removed after stop |

---

## Ticket 1: Docker image not rebuilt — entrypoint changes invisible

### Problem

`docker/entrypoint.sh` is **COPY'd into the image** at build time (Dockerfile line 29):

```dockerfile
COPY entrypoint.sh /entrypoint.sh
```

`_docker_start()` runs `docker compose up -d` **without `--build`**. The image
`docker-fts:latest` was last built **2026-02-03 12:38**. All entrypoint changes
made after that date (the DB symlink from Task A) are not in the running
container.

### Fix

In `lib/server.sh` `_docker_start()`, change `up -d` to `up -d --build`.
Docker layer caching makes no-op rebuilds fast (~2 s).

### Status: Fixed by Cody

---

## Ticket 2: DB persistence — verify symlink after rebuild

### Problem

After Ticket 1 is fixed, the symlink code in `docker/entrypoint.sh` (lines
71-79) needs verification. The symlink creates:

```
/opt/fts/FTSDataBase.db  →  /opt/fts/data/FTSDataBase.db
                                    ↕ (volume mount)
                             docker/data/FTSDataBase.db (host)
```

### Potential issues to investigate

1. **First-run wizard resets FTS_DB_PATH.** The template `FTSConfig.yaml` sets
   `FTS_DB_PATH: "/opt/fts/data"`, but FTS's first-run wizard may overwrite the
   config with defaults. The patcher (`_patch_config`) only fixes addresses and
   ports — it does NOT re-set `FTS_DB_PATH`. If the wizard sets
   `FTS_DB_PATH: "/opt/fts"`, FTS writes to `/opt/fts/FTSDataBase.db` (the
   symlink target), which should still redirect to the volume. But if it writes
   to a completely different path, the symlink is bypassed.

2. **SQLite and dangling symlinks.** On first boot, `ln -sf` creates a symlink
   to `/opt/fts/data/FTSDataBase.db` which doesn't exist yet. SQLite's
   `connect()` with `check_same_thread=False` should create the file at the
   symlink target. But if FTS or Python resolves the realpath and fails, the
   DB gets created as a regular file replacing the symlink.

3. **First-run kill/restart cycle.** The background patcher kills PID 1 on
   first run, Docker restarts the container. The symlink logic runs again on
   restart. If the first (aborted) run already created a regular DB file at
   `/opt/fts/FTSDataBase.db`, the `mv` should catch it and move it to the
   volume. But timing matters — did FTS have time to create the DB before
   being killed?

### Fix (if FTS_DB_PATH gets reset by wizard)

Add `FTS_DB_PATH` to `_patch_config()` in `docker/entrypoint.sh`.

### Status: Fixed by Cody (added FTS_DB_PATH to _patch_config)

### Verification steps

```bash
# 1. Rebuild and start
./heartbeat stop
(cd docker && docker compose build)
./heartbeat start

# 2. Wait for full boot (2+ minutes on first run due to kill/restart cycle)

# 3. Check inside container
docker exec heartbeat-fts ls -la /opt/fts/FTSDataBase.db
# Expected: symlink → /opt/fts/data/FTSDataBase.db

docker exec heartbeat-fts ls -la /opt/fts/data/FTSDataBase.db
# Expected: regular file, non-zero size

# 4. Check on host
ls -la docker/data/FTSDataBase.db
# Expected: regular file, matches container

# 5. Test persistence
./heartbeat stop && ./heartbeat start
# DB should still exist, users/tracks preserved
```

---

## Ticket 3: WebMap race condition — starts before FTS CoT port ready

### Problem

WebMap logs show `connect failed 127.0.0.1:8087`. The config fix to use
`127.0.0.1` instead of the Tailscale IP **is working** (confirmed in log).
The failure is a timing issue.

### Root cause: startup sequence timing

```
_docker_start()
  → docker compose up -d          # container starts
  → _wait_for_server()            # waits up to 30s for Docker healthcheck
                                  # BUT healthcheck has start_period: 30s
                                  # so Docker won't even CHECK for 30s
  → returns (possibly with "may still be starting" warning)

webmap_start()
  → port_listening(COT_PORT)      # waits up to 15s
  → starts WebMap                 # FTS CoT port still not ready
```

### Fix

Replace `port_listening` with `port_accepting "127.0.0.1"` and increase
wait to 60 iterations x 2s = 120s max.

### Status: Fixed by Cody

---

## Ticket 4: Stale webMAP_config.json on disk

### Problem

`data/webmap/webMAP_config.json` still contains old IP after config changes.
`webmap_start()` rewrites this file, but only when it runs past the PID check.

### Fix

Move `_webmap_write_config` before the PID check in `webmap_start()`.

### Status: Fixed by Cody

---

## Recommended test sequence (after all fixes)

```bash
# 1. Clean slate
./heartbeat stop
docker rmi docker-fts:latest 2>/dev/null   # force full rebuild

# 2. Start and wait for FULL boot
./heartbeat start
# Wait for "Server is accepting connections" or the QR code to appear

# 3. Verify DB persistence
ls -la docker/data/FTSDataBase.db
docker exec heartbeat-fts ls -la /opt/fts/FTSDataBase.db

# 4. Verify WebMap
cat data/webmap/webMAP_config.json          # should show 127.0.0.1
tail -20 data/webmap.log                    # no "connect failed" in latest block
curl -s http://localhost:8000/tak-map | head -5

# 5. Verify persistence across restart
./heartbeat stop && ./heartbeat start
ls -la docker/data/FTSDataBase.db           # still there

# 6. Verify clean stop
./heartbeat stop
ls data/*.pid 2>/dev/null                   # nothing
ls docker/docker-compose.override.yml 2>/dev/null  # nothing
```
