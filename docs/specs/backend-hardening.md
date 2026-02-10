# Backend Hardening Spec — Heartbeat v1.0 Demo Readiness

**Author:** Claude (spec review for Cody)
**Date:** 2026-02-09
**Goal:** `git clone` → `./setup.sh` → `./heartbeat start` → phone connects → recorder captures → export works — on a fresh Linux box, for either backend.

**Guiding principle:** _Defaults work. Everything is configurable. If something is wrong, detect it and fix it automatically._

---

## Table of Contents

1. [CRITICAL: Port Mapping Bug](#1-critical-port-mapping-bug)
2. [Revert Default Backend to FreeTAK](#2-revert-default-backend-to-freetak)
3. [Remove Hardcoded Credentials](#3-remove-hardcoded-credentials)
4. [Simplify Package Generation](#4-simplify-package-generation)
5. [Backend Health Checks with Auto-Fix](#5-backend-health-checks-with-auto-fix)
6. [Backend Abstraction Finish-Through](#6-backend-abstraction-finish-through)
7. [Review: Cody's Datastore Upsert](#7-review-codys-datastore-upsert)

---

## 1. CRITICAL: Port Mapping Bug

### Problem

`patch_opentak_config()` in `lib/install.sh:368-409` patches the **wrong config keys**. It sets:

```python
"OTS_COT_PORT": int(cot_port),       # <-- does NOT exist in OTS config
"OTS_SSL_COT_PORT": int(ssl_port),   # <-- does NOT exist in OTS config
```

But OpenTAK Server 1.7.6 uses these keys:

```yaml
OTS_TCP_STREAMING_PORT: 8088    # <-- the REAL TCP CoT key
OTS_SSL_STREAMING_PORT: 8089    # <-- the REAL SSL CoT key
```

Because the patcher has `if key in cfg: cfg[key] = value`, and these keys don't exist, the patch is a **silent no-op**. OTS keeps its default `8088`, while Heartbeat's `heartbeat.conf` says `COT_PORT=8087`. Result:

- Recorder connects to 8087 → nothing is listening → fails
- `_wait_for_server()` checks port 8087 → reports "still starting"
- `./heartbeat status` shows port 8087 as "not detected"
- OTS is actually healthy on 8088, but Heartbeat doesn't know

### Current state on the machine

```
heartbeat.conf:  COT_PORT=8087
OTS config.yml:  OTS_TCP_STREAMING_PORT: 8088
OTS eud_handler: actually listening on 8088  (confirmed via ss -tlnp)
```

### Solution

**Option A (recommended): Align Heartbeat defaults to OTS defaults**

Change the default CoT port for OpenTAK to 8088 in `setup.sh`:

```bash
# In setup.sh, auto_ports() or the opentak override block:
if [[ "$backend" == "opentak" ]]; then
    cot_port=8088   # OTS default TCP streaming port
    api_port=8443
    dp_port=8443
fi
```

AND fix `patch_opentak_config()` to use the correct keys:

```python
# In lib/install.sh patch_opentak_config():
for key, value in {
    "OTS_SERVER_ADDRESS": server_ip,
    "OTS_LISTENER_PORT": 8081,
    "OTS_TCP_STREAMING_PORT": int(cot_port),   # FIXED: was OTS_COT_PORT
    "OTS_SSL_STREAMING_PORT": int(ssl_port),   # FIXED: was OTS_SSL_COT_PORT
    "OTS_MEDIAMTX_ENABLE": False,
    "SECURITY_TWO_FACTOR": False,
    "SQLALCHEMY_DATABASE_URI": db_uri,
}.items():
```

**Option B: Force OTS to use 8087**

Same patch fix, but keep `cot_port=8087`. This works because the patcher will now actually write `OTS_TCP_STREAMING_PORT: 8087` into `config.yml`. But it diverges from OTS documentation/defaults — anyone reading OTS docs will expect 8088.

**Recommendation:** Option A. Match OTS defaults. Backend-specific port defaults belong in the backend, not hardcoded globally.

### Files to change

| File | Change |
|------|--------|
| `lib/install.sh:394-398` | Fix key names: `OTS_COT_PORT` → `OTS_TCP_STREAMING_PORT`, `OTS_SSL_COT_PORT` → `OTS_SSL_STREAMING_PORT` |
| `lib/install.sh:396` | Fix key name: `OTS_WEBSERVER_PORT` → `OTS_LISTENER_PORT` (correct OTS key) |
| `setup.sh:~285` | Set `cot_port=8088` for opentak backend |
| `lib/backends/opentak.sh:22` | Change default: `COT_PORT:-8088` |
| `config/heartbeat.conf.example:27` | Add comment that OTS uses 8088 |

---

## 2. Revert Default Backend to FreeTAK

### Problem

`setup.sh:108-109` defaults to `opentak` for fresh installs. OpenTAK hasn't completed a single successful end-to-end run. FreeTAK is proven and tested.

### Current code

```bash
# setup.sh line 107-110
# Default backend for fresh installs: OpenTAK.
if [[ -z "$backend" ]]; then
    backend="opentak"
fi
```

### Solution

```bash
# Default backend for fresh installs: FreeTAK (Lite tier).
# Use --backend opentak for Standard tier (SSL + WebTAK).
if [[ -z "$backend" ]]; then
    backend="freetak"
fi
```

Also update:
- `setup.sh` help text (around line 55) to say `freetak` is default
- `config/heartbeat.conf.example:19` to say `TAK_BACKEND="freetak"` with a comment noting opentak is available

### Files to change

| File | Change |
|------|--------|
| `setup.sh:108-109` | `backend="opentak"` → `backend="freetak"` |
| `setup.sh:~55` | Update help text |
| `config/heartbeat.conf.example:19` | `TAK_BACKEND="freetak"` |

---

## 3. Remove Hardcoded Credentials

### Problem

`franky/romano123` appears in 4 places:
1. `setup.sh:321-323` — default OpenTAK user/pass
2. `setup.sh:346` — error message example
3. `config/heartbeat.conf.example:37-38` — example config
4. `lib/package.sh:52-53` — hardcoded `administrator/password` for API auth

Additionally, `lib/install.sh:708-709` advises falling back to `administrator / password`.

### Solution

**A. `setup.sh` default credentials:**

```bash
# Replace lines 318-324:
local default_user="admin"
local default_pass=""
# Both backends use generated passwords by default.
# Users can override with --username / --password flags.
```

This means `gen_password()` (already exists at line 336) will always generate a random password when no explicit password is provided. The generated password is shown during setup and written to config — the user sees it.

**B. Config example:**

```bash
# Replace lines 37-38 in heartbeat.conf.example:
FTS_USERNAME="admin"             # Default TAK/WebTAK username (set during setup)
FTS_PASSWORD=""                  # Generated during setup — do not commit
```

**C. Package generation admin creds:**

The `_generate_opentak_package` function at `lib/package.sh:52-53` hardcodes:
```bash
local admin_user="administrator"
local admin_password="password"
```

Instead, read from config:
```bash
local admin_user="${FTS_USERNAME:-admin}"
local admin_password="${FTS_PASSWORD}"
if [[ -z "$admin_password" ]]; then
    log_error "No admin password in config. Re-run setup.sh."
    return 1
fi
```

**D. Error messages:**

Remove the `(example: romano123)` text from `setup.sh:346`.

### Files to change

| File | Lines | Change |
|------|-------|--------|
| `setup.sh` | 321-323 | Generic defaults |
| `setup.sh` | 346 | Remove example password |
| `config/heartbeat.conf.example` | 37-38 | Generic placeholders |
| `lib/package.sh` | 52-53 | Read creds from config |
| `lib/install.sh` | ~708 | Remove hardcoded fallback advice |

---

## 4. Simplify Package Generation

### Problem

`_generate_opentak_package()` in `lib/package.sh:43-239` is ~200 lines with 4 cascading fallback tiers:

1. **Tier 1** (lines 82-118): Local datastore upsert + admin API pre-provision + cert request via API
2. **Tier 2** (lines 120-153): Repeat tier 1 identically (no value)
3. **Tier 3** (lines 155-176): Retry cert request using admin creds
4. **Tier 4** (lines 178-210): Direct local CA issuance via Python (the one that actually works)

In testing, the API-based tiers fail because the API has authentication quirks. Tier 4 (direct CA) is the only reliable path because it bypasses the API entirely and calls the CA module directly.

### Solution

Simplify to 2 tiers:

**Tier 1: Ensure user exists (datastore upsert)**
```bash
opentak_upsert_user_local "${ots_dir}" "${ots_venv}" "${safe_name}" "${user_password}" "user" 3
# If this fails, log warning but continue — cert gen doesn't strictly need the user to exist
```

**Tier 2: Generate cert directly via CA**
```bash
(
    cd "${ots_dir}"
    OTS_DATA_FOLDER="${ots_dir}" \
    OTS_CONFIG_PATH="${ots_dir}/config.yml" \
    OTS_CONFIG_FILE="${ots_dir}/config.yml" \
    "${ots_venv}/bin/python3" - "${cert_user}" "${SERVER_IP}" "${webtak_port}" <<'PY'
from opentakserver.certificate_authority import CertificateAuthority
# ... (existing tier 4 code)
ca.issue_certificate(username, False)
PY
)
```

**Remove:** All `curl` API fallback loops (tiers 1-3's cert request portions). The API-based approach can be added back once we have a working e2e setup to validate it against.

### Target size

~60-70 lines instead of ~200. The function should:
1. Validate inputs (name, password length)
2. Upsert user in datastore
3. Generate cert via CA directly
4. Build the zip package (manifest + pref + certs)

### Files to change

| File | Change |
|------|--------|
| `lib/package.sh:43-239` | Rewrite `_generate_opentak_package` — drop tiers 1-3 curl loops, keep datastore upsert + direct CA |

---

## 5. Backend Health Checks with Auto-Fix

### Philosophy

When `./heartbeat start` or `./heartbeat status` runs, it should **verify the real state** and **auto-correct** mismatches. This is especially important because we have two backends with different port defaults, and stale config/services from previous runs.

### 5a. Port Verification on Start

After `backend_start()`, the `_wait_for_server()` function in `lib/server.sh:325-368` checks `COT_PORT` to confirm the server is accepting connections. This needs to be backend-aware.

**Current problem:** For OTS, it checks port 8087 (from config) but OTS listens on 8088.

**Solution — add a `backend_get_cot_port()` function to the interface:**

```bash
# lib/backends/interface.sh — add to contract:
backend_get_cot_port() {
    # Return the actual TCP CoT port this backend uses.
    # Backends override to return their real port.
    echo "${COT_PORT:-8087}"
}
```

```bash
# lib/backends/opentak.sh:
backend_get_cot_port() {
    load_config
    echo "${COT_PORT:-8088}"
}
```

```bash
# lib/backends/freetak.sh:
backend_get_cot_port() {
    load_config
    echo "${COT_PORT:-8087}"
}
```

Then `_wait_for_server()` uses `backend_get_cot_port` instead of raw `$COT_PORT`.

**Alternatively** (simpler, if we go with Option A from section 1): just fix the defaults so `COT_PORT` is correct for each backend. Then the existing `_wait_for_server` already works. This is the preferred approach.

### 5b. Service Health Check on Status

`./heartbeat status` already checks ports. Enhance it to also verify:

1. **Config/runtime port agreement** — does the config `COT_PORT` match what's actually listening?
2. **Required services running** — for OTS, are all 4 systemd services active?
3. **Auto-fix stale state** — if services are dead but PID files exist, clean up

Add a `backend_health_check()` function:

```bash
# lib/backends/interface.sh:
backend_health_check() {
    # Returns 0 if healthy, 1 if issues found (with warnings logged).
    # Implementations should check ports, processes, config agreement.
    return 0
}
```

```bash
# lib/backends/opentak.sh:
backend_health_check() {
    local issues=0
    load_config
    local actual_cot_port="${COT_PORT:-8088}"

    # Check all 4 required services
    for svc in opentakserver cot_parser eud_handler eud_handler_ssl; do
        if ! systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
            log_warn "Service ${svc} is not running"
            ((issues++))
        fi
    done

    # Check actual port listening matches config
    if ! port_listening "$actual_cot_port"; then
        log_warn "TCP CoT port ${actual_cot_port} not listening"
        # Try to find what port eud_handler IS on
        local real_port
        real_port=$(ss -tlnp 2>/dev/null | grep eud_handler | grep -oP ':(\d+)' | head -1 | tr -d ':')
        if [[ -n "$real_port" && "$real_port" != "$actual_cot_port" ]]; then
            log_warn "eud_handler is on port ${real_port}, but config says ${actual_cot_port}"
            log_warn "Fix: set_config COT_PORT ${real_port}"
        fi
        ((issues++))
    fi

    # Check nginx
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        log_warn "nginx is not running (WebTAK will be unavailable)"
        ((issues++))
    fi

    return $((issues > 0 ? 1 : 0))
}
```

Wire this into `server_status()` and optionally into `server_start()` (post-start verification).

### 5c. Pre-Start Validation

Before starting OTS, verify prerequisites exist:

```bash
# In backend_start() for opentak.sh, before systemctl start:
_opentak_preflight() {
    local ots_dir="${DATA_DIR}/opentak"

    # 1. Systemd service files exist
    if [[ ! -f /etc/systemd/system/opentakserver.service ]]; then
        log_error "OpenTAK not installed. Run: ./setup.sh --backend opentak"
        return 1
    fi

    # 2. Venv is intact
    if [[ ! -x "${ots_dir}/venv/bin/opentakserver" ]]; then
        log_error "OpenTAK venv is broken. Re-run setup."
        return 1
    fi

    # 3. Config exists
    if [[ ! -f "${ots_dir}/config.yml" ]]; then
        log_error "OpenTAK config missing. Re-run setup."
        return 1
    fi

    # 4. PostgreSQL is running
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        log_warn "PostgreSQL not running, starting..."
        sudo systemctl start postgresql
    fi

    # 5. RabbitMQ is running
    if ! systemctl is-active --quiet rabbitmq-server 2>/dev/null; then
        log_warn "RabbitMQ not running, starting..."
        sudo systemctl start rabbitmq-server
    fi

    # 6. nginx is running
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        log_warn "nginx not running, starting..."
        sudo systemctl start nginx
    fi

    return 0
}
```

### Files to change

| File | Change |
|------|--------|
| `lib/backends/interface.sh` | Add `backend_health_check()` stub |
| `lib/backends/opentak.sh` | Implement `backend_health_check()` + `_opentak_preflight()` |
| `lib/backends/freetak.sh` | Implement `backend_health_check()` (check port + PID) |
| `lib/server.sh:325-368` | Update `_wait_for_server` to use correct port per backend |
| `lib/server.sh:80-181` | Wire health check into `server_status()` |

---

## 6. Backend Abstraction Finish-Through

### 6a. Interface Validation

`_load_backend()` in `lib/server.sh:10-27` sources the backend file but never verifies it implements the required functions.

**Add validation:**

```bash
_load_backend() {
    load_config
    local backend="${TAK_BACKEND:-freetak}"
    local backend_file="${LIB_DIR}/backends/${backend}.sh"

    if [[ ! -f "$backend_file" ]]; then
        log_error "Unknown backend: ${backend}"
        exit 1
    fi

    source "$backend_file"

    # Verify contract
    local required_fns=(
        backend_name backend_supports backend_get_ports
        backend_start backend_stop backend_status
        backend_logs backend_get_package
    )
    for fn in "${required_fns[@]}"; do
        if ! declare -f "$fn" >/dev/null 2>&1; then
            log_error "Backend '${backend}' missing required function: ${fn}"
            exit 1
        fi
    done
}
```

### 6b. FTS-Specific Variable Names

The config uses `FTS_*` prefixes for fields that are now shared across backends:

| Current name | Used by | Better name |
|-------------|---------|-------------|
| `FTS_USERNAME` | Both | `TAK_USERNAME` |
| `FTS_PASSWORD` | Both | `TAK_PASSWORD` |
| `FTS_SECRET_KEY` | FTS only | Keep |
| `FTS_CONNECTION_MSG` | Both | `TAK_CONNECTION_MSG` |
| `FTS_DATA_DIR` | FTS only | Keep |

**Recommendation:** Add aliases in `load_config()` for backward compatibility:

```bash
# In lib/common.sh load_config():
# Backward-compatible aliases (FTS_* → TAK_*)
TAK_USERNAME="${TAK_USERNAME:-${FTS_USERNAME:-admin}}"
TAK_PASSWORD="${TAK_PASSWORD:-${FTS_PASSWORD:-}}"
TAK_CONNECTION_MSG="${TAK_CONNECTION_MSG:-${FTS_CONNECTION_MSG:-Welcome to TAK}}"
```

This way new code uses `TAK_*`, old configs with `FTS_*` still work, and nobody breaks. Migrate `setup.sh` to write `TAK_*` keys. For the demo, this is a **nice-to-have** — keep `FTS_*` names if the rename is too risky.

### 6c. Backend-Specific Port Defaults

Currently `auto_ports()` in `setup.sh:72-94` always starts from the same port numbers. For OpenTAK, the TCP CoT default should be 8088 not 8087.

**Solution:** Move port defaults into each backend or have `auto_ports` accept the backend name:

```bash
auto_ports() {
    local backend="${1:-freetak}"
    local cot ssl api dp

    case "$backend" in
        opentak)
            cot=$(find_free_port 8088)
            ssl=$(find_free_port 8089)
            api=8443
            dp=8443
            ;;
        *)
            cot=$(find_free_port 8087)
            ssl=$(find_free_port 8089)
            api=$(find_free_port 19023)
            dp=8443
            ;;
    esac

    echo "${cot} ${ssl} ${api} ${dp}"
}
```

### Files to change

| File | Change |
|------|--------|
| `lib/server.sh:10-27` | Add interface validation in `_load_backend()` |
| `lib/common.sh` | Add `TAK_*` aliases in `load_config()` (optional, nice-to-have) |
| `setup.sh:72-94` | Make `auto_ports()` backend-aware |

---

## 7. Review: Cody's Datastore Upsert

### What Cody Added

1. **`opentak_upsert_user_local()`** in `lib/common.sh:153-235` — a Python-based function that directly imports OpenTAK's Flask app and uses Flask-Security's datastore to create/update users.

2. **`setup_opentak_default_user()`** in `lib/install.sh:672-713` — now tries the datastore upsert first, falls back to Flask CLI.

3. **Package generation** in `lib/package.sh` — pre-provisions user via datastore upsert before cert generation.

### Assessment

**The datastore upsert (`lib/common.sh:153-235`) is well-implemented:**
- Validates venv existence and password length
- Retry loop with configurable attempts
- Creates roles (`user`, `administrator`) via `find_or_create_role`
- Upserts user (create or update password + activate)
- Filters Mumble noise from output
- Returns proper exit codes for caller to handle

**One concern:** The retry loop (lines 172-227) retries the entire Python script execution on failure. Each attempt creates a full Flask app context. If the failure is a DB connection error (PostgreSQL not ready), retrying makes sense. If the failure is a code error (bad import), all retries will fail identically. Consider adding a small sleep between retries:

```bash
# After failed attempt, before retry:
sleep $((attempt))  # exponential-ish backoff: 1s, 2s, 3s...
```

**The setup default user fallback (`lib/install.sh:672-713`) is reasonable:**
- Primary: datastore upsert (fast, no Flask CLI dependency)
- Fallback: Flask CLI commands (slower, more dependencies)
- Soft-fail: setup continues with warning if both fail

**No changes needed** for Cody's datastore upsert — it's the right pattern. The simplification work is in `package.sh` (section 4 above), not in the upsert helper itself.

---

## Implementation Priority

### Must-have for demo (do these first)

| # | Task | Risk | Effort |
|---|------|------|--------|
| 1 | Fix port mapping bug (section 1) | **P0** — server appears broken without this | Small |
| 2 | Revert default backend (section 2) | **P0** — fresh installs get untested backend | Tiny |
| 3 | Remove hardcoded creds (section 3) | **P1** — security + professionalism | Small |
| 4 | Simplify package gen (section 4) | **P1** — current code doesn't work reliably | Medium |

### Should-have for demo (do if time permits)

| # | Task | Risk | Effort |
|---|------|------|--------|
| 5 | Pre-start validation (section 5c) | **P1** — prevents confusing failures | Small |
| 6 | Backend-aware port defaults (section 6c) | **P1** — prevents port mismatches | Small |
| 7 | Interface validation (section 6a) | **P2** — catches bugs early | Tiny |

### Nice-to-have (post-demo)

| # | Task | Risk | Effort |
|---|------|------|--------|
| 8 | Health check with auto-fix (section 5b) | **P2** — great UX | Medium |
| 9 | Rename FTS_* → TAK_* (section 6b) | **P3** — cosmetic, backward compat needed | Medium |

---

## Verification Checklist

After implementing, verify this end-to-end flow works on each backend:

### FreeTAK (Lite)
```bash
./setup.sh                          # defaults to freetak
./heartbeat start                   # starts FTS, waits for port 8087
./heartbeat status                  # shows green, port 8087 listening
./heartbeat package testuser        # generates TCP package
# Connect phone via iTAK to <ip>:8087 TCP
./heartbeat record start            # recorder connects to 8087
./heartbeat stop                    # auto-exports recording
```

### OpenTAK (Standard)
```bash
./setup.sh --backend opentak       # installs OTS
./heartbeat start                   # starts systemd services, waits for port 8088
./heartbeat status                  # shows green, ports 8088+8089+8443 listening
./heartbeat package testuser        # generates SSL package via direct CA
# Import package in iTAK, connect via SSL to <ip>:8089
# Open WebTAK at https://<ip>:8443
./heartbeat record start            # recorder connects to 8088
./heartbeat stop                    # auto-exports recording
```
