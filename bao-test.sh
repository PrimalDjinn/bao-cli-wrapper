#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════╗
# ║           bao-setup — Access Test Suite              ║
# ╚══════════════════════════════════════════════════════╝

set -uo pipefail

# ─── Colors & styles ────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m'
W='\033[1;37m' B='\033[0;34m' M='\033[0;35m' DIM='\033[2m' NC='\033[0m'
BOLD='\033[1m'

# ─── Helpers ─────────────────────────────────────────────
info()  { echo -e "${C}  ●  $1${NC}"; }
ok()    { echo -e "${G}  ✔  $1${NC}"; }
warn()  { echo -e "${Y}  ⚠  $1${NC}"; }
fail()  { echo -e "${R}  ✖  $1${NC}"; }
ask()   { echo -en "${B}  ➜  $1 ${W}"; read -r "$2"; echo -en "${NC}"; }
ask_s() { echo -en "${B}  ➜  $1 ${W}"; read -rs "$2"; echo -en "${NC}"; }

banner() {
  echo -e "\n${C}╔══════════════════════════════════════════════════════════╗"
  echo -e "║  ${W}${BOLD}⬡  bao-setup — Access Test Suite${NC}${C}                      ║"
  echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
}

divider() { echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"; }

# ─── Dynamic Input Collector ─────────────────────────────
collect_config() {
  banner
  echo ""
  label() { echo -e "${M}${BOLD}  $1${NC}"; }

  # BAO_ADDR
  if [[ -z "${BAO_ADDR:-}" ]]; then
    ask "OpenBao Server Address [http://127.0.0.1:8200]:" BAO_ADDR
    BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
  else
    info "Using BAO_ADDR from environment"
  fi
  BAO_ADDR="${BAO_ADDR%/}" # strip trailing slash

  # MOUNT_PATH
  if [[ -z "${MOUNT_PATH:-}" ]]; then
    ask "KV Mount Path (e.g. heylomeet) [heylomeet]:" MOUNT_PATH
    MOUNT_PATH="${MOUNT_PATH:-heylomeet}"
  else
    info "Using MOUNT_PATH from environment"
  fi
  MOUNT_PATH="${MOUNT_PATH%/}"

  # ENV
  if [[ -z "${ENV:-}" ]]; then
    ask "Environment (e.g. production) [production]:" ENV
    ENV="${ENV:-production}"
  else
    info "Using ENV from environment"
  fi

  # TEST_KEY
  if [[ -z "${TEST_KEY:-}" ]]; then
    ask "Test Key Name (e.g. api-key) [api-key]:" TEST_KEY
    TEST_KEY="${TEST_KEY:-api-key}"
  else
    info "Using TEST_KEY from environment"
  fi

  echo ""
  label "AppRole Credentials (for private access)"
  info "Leave empty to skip private test"

  if [[ -z "${BAO_ROLE_ID:-}" ]]; then
    ask "BAO_ROLE_ID:" BAO_ROLE_ID
  else
    info "Using BAO_ROLE_ID from environment"
  fi

  if [[ -z "${BAO_SECRET_ID:-}" ]]; then
    ask_s "BAO_SECRET_ID:" BAO_SECRET_ID
    echo ""
  else
    info "Using BAO_SECRET_ID from environment"
  fi

  # Summary
  echo ""
  divider
  label "Configuration"
  echo -e "  ${C}Server    :${NC} ${BAO_ADDR}"
  echo -e "  ${C}Mount     :${NC} ${MOUNT_PATH}"
  echo -e "  ${C}Env       :${NC} ${ENV}"
  echo -e "  ${C}Test Key  :${NC} ${TEST_KEY}"
  [[ -n "$BAO_ROLE_ID" ]] && echo -e "  ${C}Role ID   :${NC} ${DIM}${BAO_ROLE_ID:0:12}...${NC}"
  [[ -n "$BAO_SECRET_ID" ]] && echo -e "  ${C}Secret ID :${NC} ${DIM}${BAO_SECRET_ID:0:12}...${NC}"
  divider

  echo -en "${Y}  ?  Run tests? [y/N] ${NC}"
  read -r ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    warn "Aborted."
    exit 0
  fi
  echo ""
}

# ─── TEST 1: PUBLIC / ANONYMOUS ──────────────────────────
test_public() {
  info "Testing public/anonymous access: ${MOUNT_PATH}/data/${TEST_KEY}"
  local http_code
  http_code=$(curl -s -o /tmp/bao_pub.json -w "%{http_code}" \
    --max-time 5 \
    -H "X-Vault-Token: anonymous" \
    "${BAO_ADDR}/v1/${MOUNT_PATH}/data/${TEST_KEY}" 2>/dev/null || echo "000")

  case "$http_code" in
    200)
      ok "Public access successful!"
      jq '.data.data' /tmp/bao_pub.json 2>/dev/null || echo -e "  ${DIM}(Response body saved to /tmp/bao_pub.json)${NC}"
      ;;
    403) fail "Access denied. Check public policy or anonymous token assignment." ;;
    404)
      warn "Key '${TEST_KEY}' not found. (Expected if not added via UI yet.)"
      ok "Mount & routing working correctly."
      ;;
    *) fail "Connection failed or unexpected response: HTTP ${http_code}" ;;
  esac
  echo ""
}

# ─── TEST 2: APPROLE LOGIN → PRIVATE ACCESS ──────────────
test_private() {
  if [[ -z "$BAO_ROLE_ID" || -z "$BAO_SECRET_ID" ]]; then
    warn "AppRole credentials empty. Skipping private test."
    echo -e "  ${DIM}Set BAO_ROLE_ID & BAO_SECRET_ID to test private access.${NC}\n"
    return
  fi

  info "Logging in via AppRole..."
  local login_resp
  login_resp=$(curl -s --max-time 5 --request POST \
    --header "Content-Type: application/json" \
    --data "{\"role_id\":\"${BAO_ROLE_ID}\",\"secret_id\":\"${BAO_SECRET_ID}\"}" \
    "${BAO_ADDR}/v1/auth/approle/login" 2>/dev/null || echo '{"errors":["connection_failed"]}')

  local client_token
  client_token=$(echo "$login_resp" | jq -r '.auth.client_token // empty')

  if [[ -z "$client_token" || "$client_token" == "null" ]]; then
    fail "AppRole login failed."
    echo -e "  ${DIM}$(echo "$login_resp" | jq '.errors // ["No error details"]' 2>/dev/null)${NC}"
    return 1
  fi
  ok "AppRole login successful."

  info "Testing private access: ${MOUNT_PATH}/data/${TEST_KEY}"
  local http_code
  http_code=$(curl -s -o /tmp/bao_priv.json -w "%{http_code}" \
    --max-time 5 \
    -H "X-Vault-Token: ${client_token}" \
    "${BAO_ADDR}/v1/${MOUNT_PATH}/data/${TEST_KEY}" 2>/dev/null || echo "000")

  case "$http_code" in
    200)
      ok "Private access successful!"
      jq '.data.data' /tmp/bao_priv.json 2>/dev/null || echo -e "  ${DIM}(Response body saved to /tmp/bao_priv.json)${NC}"
      ;;
    403) fail "Access denied. Check private policy or AppRole configuration." ;;
    404)
      warn "Key '${TEST_KEY}' not found. (Expected if not added via UI yet.)"
      ok "Token & AppRole policy routing correctly."
      ;;
    *) fail "Unexpected response: HTTP ${http_code}" ;;
  esac

  # Clean up token
  curl -s --max-time 3 -X POST -H "X-Vault-Token: ${client_token}" \
    "${BAO_ADDR}/v1/auth/token/revoke-self" &>/dev/null
  echo ""
}

# ─── RUN ─────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  fail "jq is required. Install: sudo apt install jq / brew install jq"
  exit 1
fi

collect_config
test_public
test_private

rm -f /tmp/bao_pub.json /tmp/bao_priv.json
divider
ok "✅ Access tests complete."
echo -e "${DIM}Tip: Pre-export variables to skip prompts: export BAO_ADDR=... BAO_ROLE_ID=...${NC}\n"