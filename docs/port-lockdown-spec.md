# Spec: Lock Down Ports + Harden Default Password

**Branch**: `v0-fixes`
**Status**: Ready for implementation

---

## Task 1 of 7: `docker/docker-compose.yml` — bind ports to specific IPs

**Find** (lines 8-12):
```yaml
    ports:
      - "${COT_PORT:-8087}:${COT_PORT:-8087}"
      - "${SSL_COT_PORT:-8089}:${SSL_COT_PORT:-8089}"
      - "${API_PORT:-19023}:${API_PORT:-19023}"
      - "${DATAPACKAGE_PORT:-8443}:8443"
```

**Replace with**:
```yaml
    ports:
      - "${SERVER_IP:-127.0.0.1}:${COT_PORT:-8087}:${COT_PORT:-8087}"
      - "${SERVER_IP:-127.0.0.1}:${SSL_COT_PORT:-8089}:${SSL_COT_PORT:-8089}"
      - "127.0.0.1:${API_PORT:-19023}:${API_PORT:-19023}"
      - "${SERVER_IP:-127.0.0.1}:${DATAPACKAGE_PORT:-8443}:8443"
```

**Rationale**: CoT/SSL/DP bind to `SERVER_IP` so VPN clients can reach them. API gets hardcoded `127.0.0.1` because it's only accessed via `docker exec` (never over the network). Fallback `127.0.0.1` if `SERVER_IP` is unset. `SERVER_IP` is already exported at `lib/server.sh:40`.

**Verify**: `grep 'SERVER_IP\|127.0.0.1' docker/docker-compose.yml` — all 4 port lines should have a host IP prefix.

---

## Task 2 of 7: `lib/package.sh` — bind serve to SERVER_IP

**Find** (last line of `serve_packages()`):
```bash
    python3 -m http.server "$port" --bind 0.0.0.0 2>/dev/null
```

**Replace with**:
```bash
    python3 -m http.server "$port" --bind "${SERVER_IP}" 2>/dev/null
```

**Verify**: `grep -n 'bind' lib/package.sh` — should show `"${SERVER_IP}"`, not `0.0.0.0`.

---

## Task 3 of 7: `lib/install.sh` — lock down native-mode FTS addresses

Only edit the **native-mode** YAML heredoc (inside `install_native_mode()`). Do NOT touch the Docker-mode block above it.

**Find** (around lines 148-152):
```yaml
  FTS_DP_ADDRESS: "0.0.0.0"
  FTS_USER_ADDRESS: "0.0.0.0"
  FTS_API_PORT: ${API_PORT}
  FTS_FED_PORT: 9000
  FTS_API_ADDRESS: "0.0.0.0"
```

**Replace with**:
```yaml
  FTS_DP_ADDRESS: "${SERVER_IP}"
  FTS_USER_ADDRESS: "${SERVER_IP}"
  FTS_API_PORT: ${API_PORT}
  FTS_FED_PORT: 9000
  FTS_API_ADDRESS: "127.0.0.1"
```

**Rationale**: Docker mode already uses `${SERVER_IP}` for DP/USER (lines 71-72). Native mode was left at `0.0.0.0`, which both exposes services on all interfaces and embeds a broken address in data packages.

**Verify**: `grep '0.0.0.0' lib/install.sh` — should return zero matches.

---

## Task 4 of 7: `lib/common.sh` — add `gen_password()`

**Insert after** `gen_secret()` (after the closing `}` on line 155), before `ensure_dir()`:

```bash
gen_password() {
    head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 12
}
```

Do NOT modify `gen_secret()` — it stays as-is for FTS_SECRET_KEY.

**Verify**: `grep -A2 'gen_password' lib/common.sh` — function should exist and match exactly.

---

## Task 5 of 7: `setup.sh` — generate random default password

**Find** (around lines 259-266):
```bash
    # ---- Default credentials ----
    local fts_user="team"
    local fts_pass="${fts_user}"
    if $INTERACTIVE; then
        echo ""
        fts_user=$(prompt_default "Default TAK username" "$fts_user")
        fts_pass=$(prompt_default "Default TAK password" "$fts_user")
    fi
```

**Replace with**:
```bash
    # ---- Default credentials ----
    local fts_user="team"
    local fts_pass
    fts_pass=$(gen_password)
    if $INTERACTIVE; then
        echo ""
        fts_user=$(prompt_default "Default TAK username" "$fts_user")
        fts_pass=$(prompt_default "Default TAK password" "$fts_pass")
    fi
```

Two differences from before:
1. `fts_pass` initialized via `gen_password` instead of `"${fts_user}"`
2. Interactive password prompt default is the generated password, not the username

**Verify**: `grep -A5 'Default credentials' setup.sh` — should show `gen_password`, never `${fts_user}` for the password.

---

## Task 6 of 7: `config/heartbeat.conf.example` — update password default

**Find**:
```bash
FTS_PASSWORD="team"      # Default TAK password (generated during setup)
```

**Replace with**:
```bash
FTS_PASSWORD=""           # Auto-generated random password (see setup output)
```

**Verify**: `grep FTS_PASSWORD config/heartbeat.conf.example` — should show empty quotes and new comment.

---

## Task 7 of 7: `docs/todo.md` — remove VM items, mark urgent done

**Replace entire file contents with**:
```markdown
# TODO (Ordered by Urgency)

## Medium
- Improve SSH hardening in deploy scripts (avoid StrictHostKeyChecking=no or document risk).
- Handle DataPackage port conflicts more explicitly (warn + disable or remap).
```

The two urgent items (port exposure, weak creds) are resolved by this spec. The two high items (Oracle deploy idempotency, deploy script dependency checks) are scrapped — no VM deployments planned.

---

## Do NOT change these (and why)

| File:line | Current value | Why it stays |
|---|---|---|
| `lib/package.sh:42` | `local password="${safe_name}"` | Per-user passwords stay as name=name. Changing to random breaks re-generation (FTS API returns "exists" on second call, so displayed password wouldn't match stored one). Acceptable for VPN-only deployments. |
| `lib/install.sh:75` | `FTS_API_ADDRESS: "0.0.0.0"` (Docker mode) | This is inside the container. Docker port bindings (Task 1) control external access. Changing it inside the container would break `docker exec` API calls. |
| `lib/server.sh` | No changes | Already exports `SERVER_IP` for docker-compose substitution at line 40. |
