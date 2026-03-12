#!/bin/sh
set -e

# --- Configuration ---
THRESHOLD=${BAO_THRESHOLD:-3}
SHARES=${BAO_SHARES:-5}
DATA_DIR=${BAO_DATA_DIR:-/bao/data}
export BAO_ADDR=${BAO_ADDR:-http://127.0.0.1:8200}
KEYS_FILE="$DATA_DIR/keys.json"

# 1. Wait for Database
until nc -z db 5432; do sleep 1; done

# 2. Start OpenBao
bao server -config=/bao/config.json &
BAO_PID=$!

# 3. Wait for API to respond
until wget -qS --spider "$BAO_ADDR/v1/sys/health" 2>&1 | grep -q "HTTP/1.1"; do sleep 1; done

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
if [ -f "/bao/env-policy.hcl" ]; then
    bao policy write env-policy /bao/env-policy.hcl
fi

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