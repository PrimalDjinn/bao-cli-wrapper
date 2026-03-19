#!/bin/sh
set -e

# --- Configuration ---
THRESHOLD=${BAO_THRESHOLD:-3}
SHARES=${BAO_SHARES:-5}
DATA_DIR=${BAO_DATA_DIR:-/bao/data}
export BAO_ADDR=${BAO_ADDR:-http://127.0.0.1:8200}
KEYS_FILE="$DATA_DIR/keys.json"

# --- Prepare config ---
if [ -f /bao/config.json ]; then
    echo "[INIT] Injecting environment variables into config.json..."
    envsubst < /bao/config.json > /bao/config.env.json
    CONFIG_FILE="/bao/config.env.json"
else
    echo "[ERROR] /bao/config.json not found!"
    exit 1
fi

# 1. Wait for Database
until nc -z db ${POSTGRES_PORT}; do sleep 1; done

# 2. Start OpenBao
bao server -config="$CONFIG_FILE" &
BAO_PID=$!

# 3. Wait for API to respond (check valid HTTP status codes for vault states: init, sealed, unsealed)
echo "[INIT] Waiting for OpenBao API to be ready..."
until curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BAO_ADDR/v1/sys/health" | grep -qE "^(200|400|472|501|503)"; do sleep 1; done

# 4. Initialize if needed
if [ ! -f "$KEYS_FILE" ]; then
    bao operator init -key-shares="$SHARES" -key-threshold="$THRESHOLD" -format=json > "$KEYS_FILE"
fi

# 5. Unseal
for i in $(seq 0 $(($THRESHOLD - 1))); do
    UNSEAL_KEY=$(jq -r ".unseal_keys_b64[$i]" "$KEYS_FILE")
    bao operator unseal "$UNSEAL_KEY" > /dev/null
done

# 6. BLOCKING CHECK: Wait for Unseal to be processed by the core
export BAO_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")
while [ "$(bao status -format=json | jq -r '.sealed')" != "false" ]; do
    sleep 1
done

# 7. Provisioning
# Enable AppRole
bao auth enable approle 2>/dev/null || true

# Apply Policy
echo "[INIT] Syncing policies..."
for f in /bao/policy/*.hcl; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .hcl)
  bao policy write "$name" "$f"
done

# Configure Role
bao write auth/approle/role/my-app \
    token_policies="env-policy" \
    token_ttl=1h \
    token_max_ttl=4h > /dev/null

# Capture Credentials
ROLE_ID=$(bao read -field=role_id auth/approle/role/my-app/role-id)
SECRET_ID=$(bao write -f -field=secret_id auth/approle/role/my-app/secret-id)

# 8. Final Consolidated Output
echo "=================================================="
echo "      OPENBAO INITIALIZATION COMPLETE"
echo "=================================================="
echo "Root Token:     $BAO_TOKEN"
echo "Threshold:      $THRESHOLD of $SHARES"
echo "--------------------------------------------------"
echo "APP CREDENTIALS"
echo "BAO_ROLE_ID:   $ROLE_ID"
echo "BAO_SECRET_ID: $SECRET_ID"
echo "=================================================="

# Maintain process
wait $BAO_PID