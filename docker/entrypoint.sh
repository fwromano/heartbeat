#!/bin/bash
# Entrypoint for Heartbeat FTS container
#
# FTS's first-run wizard prompts on stdin and overwrites the YAML config.
# Strategy:
#   - Start FTS normally (foreground, with stdin pipe).
#   - A background patcher waits for FTS to finish writing config, then
#     fixes addresses and ports so enrollment data matches the host.
#   - On the FIRST run the patcher kills FTS after patching, causing Docker
#     to restart the container.  On subsequent runs it patches early and
#     lets FTS continue.

CONFIG_PATH="/opt/fts/FTSConfig.yaml"
SERVER_IP="${SERVER_IP:-0.0.0.0}"
COT_PORT="${COT_PORT:-8087}"
SSL_COT_PORT="${SSL_COT_PORT:-8089}"
API_PORT="${API_PORT:-19023}"
DATAPACKAGE_PORT="${DATAPACKAGE_PORT:-8443}"
PATCH_MARKER="/opt/fts/data/.heartbeat_patched"

echo "[heartbeat] Config: $CONFIG_PATH"
echo "[heartbeat] Server IP: $SERVER_IP"
echo "[heartbeat] Ports: CoT=$COT_PORT SSL=$SSL_COT_PORT API=$API_PORT DP=$DATAPACKAGE_PORT"

# ---------------------------------------------------------------------------
# Patch config to match host ports and IP
# ---------------------------------------------------------------------------
_patch_config() {
    if [ "$SERVER_IP" != "0.0.0.0" ]; then
        sed -i "s|FTS_USER_ADDRESS:.*|FTS_USER_ADDRESS: $SERVER_IP|" "$CONFIG_PATH"
        sed -i "s|FTS_DP_ADDRESS:.*|FTS_DP_ADDRESS: $SERVER_IP|" "$CONFIG_PATH"
    fi
    sed -i "s|FTS_COT_PORT:.*|FTS_COT_PORT: $COT_PORT|" "$CONFIG_PATH"
    sed -i "s|FTS_SSLCOT_PORT:.*|FTS_SSLCOT_PORT: $SSL_COT_PORT|" "$CONFIG_PATH"
    sed -i "s|FTS_API_PORT:.*|FTS_API_PORT: $API_PORT|" "$CONFIG_PATH"
    sed -i "s|FTS_DB_PATH:.*|FTS_DB_PATH: /opt/fts/data|" "$CONFIG_PATH"
    echo "[heartbeat] Patched config: IP=$SERVER_IP CoT=$COT_PORT SSL=$SSL_COT_PORT API=$API_PORT"
}

# ---------------------------------------------------------------------------
# Background patcher
# ---------------------------------------------------------------------------
_background_patch() {
    # Wait for FTS to generate its config (contains FTS_NODE_ID)
    local tries=0
    while [ $tries -lt 60 ]; do
        if grep -q 'FTS_NODE_ID' "$CONFIG_PATH" 2>/dev/null; then
            break
        fi
        sleep 1
        tries=$((tries + 1))
    done

    sleep 2  # let FTS finish flushing

    _patch_config

    if [ ! -f "$PATCH_MARKER" ]; then
        # First run: kill FTS so Docker restarts us with the patched config
        touch "$PATCH_MARKER"
        echo "[heartbeat] First-run patch done, restarting..."
        sleep 1
        kill 1 2>/dev/null || true
    else
        echo "[heartbeat] Config re-patched for this session"
    fi
}

# Launch patcher in background
_background_patch &

# ---------------------------------------------------------------------------
# Persist database to mounted volume
# ---------------------------------------------------------------------------
DB_VOLUME="/opt/fts/data/FTSDataBase.db"
DB_DEFAULT="/opt/fts/FTSDataBase.db"
if [ -f "$DB_DEFAULT" ] && [ ! -L "$DB_DEFAULT" ]; then
    mv "$DB_DEFAULT" "$DB_VOLUME"
fi
ln -sf "$DB_VOLUME" "$DB_DEFAULT"

# ---------------------------------------------------------------------------
# Start FTS (foreground)
# ---------------------------------------------------------------------------
echo "[heartbeat] Starting FreeTAKServer..."
{
    echo "yes"
    echo "$CONFIG_PATH"
    echo "0.0.0.0"
    echo ""
    echo ""
    echo ""
    echo ""
    echo ""
    echo ""
    echo ""
    echo ""
    echo ""
    echo ""
    echo ""
    echo ""
    sleep infinity
} | python3 -m FreeTAKServer.controllers.services.FTS
