#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════╗
# ║           bao-setup — OpenBao Policy Manager         ║
# ╚══════════════════════════════════════════════════════╝

set -euo pipefail

# ─── Colors & styles ────────────────────────────────────
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
B='\033[0;34m'  C='\033[0;36m'  M='\033[0;35m'
W='\033[1;37m'  DIM='\033[2m'   BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────
banner() {
  echo -e "
${C}╔══════════════════════════════════════════════════════════╗
║  ${W}${BOLD}⬡  bao-setup${NC}${C}  —  OpenBao ACL & Policy Manager          ║
╚══════════════════════════════════════════════════════════╝${NC}"
}

divider()   { echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"; }
success()   { echo -e "${G}  ✔  $1${NC}"; }
warn()      { echo -e "${Y}  ⚠  $1${NC}"; }
error()     { echo -e "${R}  ✖  $1${NC}"; }
info()      { echo -e "${C}  ●  $1${NC}"; }
label()     { echo -e "${M}${BOLD}$1${NC}"; }
ask()       { echo -en "${B}  ➜  $1 ${W}"; read -r "$2"; echo -en "${NC}"; }
ask_secret(){ echo -en "${B}  ➜  $1 ${W}"; read -rs "$2"; echo -en "\n${NC}"; }

require_bao() {
  if ! command -v bao &>/dev/null; then
    error "bao CLI not found. Install OpenBao first."
    exit 1
  fi
  if [[ -z "${BAO_ADDR:-}" && -z "${VAULT_ADDR:-}" ]]; then
    warn "BAO_ADDR / VAULT_ADDR not set. Using default http://127.0.0.1:8200"
  fi
}

# The bao client waits 60 seconds per attempt and retries 5xx responses twice, so a hung
# server holds a command for minutes, and a retried write whose first attempt succeeded
# reports a misleading failure. The Worker in front of OpenBao answers 504 after 30 seconds,
# so 40 seconds is enough. Retries are off because operators can re-run a command.
# Anything already set, including the VAULT_* spellings, is left alone.
configure_client() {
  if [[ -z "${BAO_CLIENT_TIMEOUT+x}" && -z "${VAULT_CLIENT_TIMEOUT+x}" ]]; then
    export BAO_CLIENT_TIMEOUT=40
  fi
  if [[ -z "${BAO_MAX_RETRIES+x}" && -z "${VAULT_MAX_RETRIES+x}" ]]; then
    export BAO_MAX_RETRIES=0
  fi
}

# Fail before an interactive session rather than after the last question. `bao status`
# exits 0 when unsealed, 2 when sealed and 1 when it cannot get an answer.
require_server() {
  if [[ "${BAO_SETUP_SKIP_PREFLIGHT:-}" == "1" ]]; then
    return 0
  fi
  local rc=0
  bao status &>/dev/null || rc=$?
  case "${rc}" in
    0) ;;
    2)
      error "OpenBao is sealed. Unseal it before running this command."
      exit 1
      ;;
    *)
      error "OpenBao did not answer a status request (BAO_ADDR=${BAO_ADDR:-${VAULT_ADDR:-unset}})."
      warn "It may be down, unreachable or wedged. Set BAO_SETUP_SKIP_PREFLIGHT=1 to skip this check."
      exit 1
      ;;
  esac
}

confirm() {
  echo -en "${Y}  ?  $1 [y/N] ${NC}"; read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ─── HELP ─────────────────────────────────────────────────
show_help() {
  banner
  echo ""
  echo -e "  ${W}${BOLD}USAGE${NC}"
  echo -e "    ${C}bao-setup${NC} ${Y}<command>${NC} [options]"
  echo ""
  echo -e "  ${W}${BOLD}COMMANDS${NC}"
  divider
  echo -e "  ${Y}setup${NC}               Interactive TUI to configure an app's ACL & policies"
  echo -e "  ${Y}add-app${NC}             Quickly add a new app (alias for setup)"
  echo -e "  ${Y}list${NC}                List all bao-setup managed policies"
  echo -e "  ${Y}renew-public-token${NC}  Revoke and recreate a public token"
  echo -e "  ${Y}revoke${NC}              Revoke a token by accessor or token ID"
  echo -e "  ${Y}help${NC}                Show this message"
  divider
  echo ""
  echo -e "  ${W}${BOLD}EXAMPLES${NC}"
  echo -e "  ${DIM}# Full interactive setup for an app${NC}"
  echo -e "  ${C}./bao-setup.sh setup${NC}"
  echo ""
  echo -e "  ${DIM}# List all managed policies${NC}"
  echo -e "  ${C}./bao-setup.sh list${NC}"
  echo ""
  echo -e "  ${DIM}# Revoke and recreate a public token${NC}"
  echo -e "  ${C}./bao-setup.sh renew-public-token${NC}"
  echo -e "  ${C}./bao-setup.sh renew-public-token heylomeet production${NC}"
  echo ""
  echo -e "  ${W}${BOLD}ENVIRONMENT${NC}"
  echo -e "  ${Y}BAO_ADDR${NC}            OpenBao server address  (e.g. https://bao.example.com:8200)"
  echo -e "  ${Y}BAO_TOKEN${NC}           Root / admin token for management operations"
  echo -e "  ${Y}BAO_CLIENT_TIMEOUT${NC}  Per-request timeout in seconds (default 40)"
  echo -e "  ${Y}BAO_MAX_RETRIES${NC}     Retries for 5xx responses (default 0)"
  echo ""
}

# ─── PUBLIC TOKEN HELPERS ────────────────────────────────
public_token_id_for() {
  local app_name="$1"
  local app_env="$2"
  echo "${app_name}-${app_env}-public"
}

public_policy_name_for() {
  local app_name="$1"
  local app_env="$2"
  echo "${app_name}-${app_env}-public"
}

create_public_token() {
  local app_name="$1"
  local app_env="$2"
  local policy_name="$3"
  local force_recreate="${4:-false}"

  local token_id
  token_id="$(public_token_id_for "${app_name}" "${app_env}")"

  if ! bao policy read "${policy_name}" &>/dev/null; then
    error "Policy '${policy_name}' does not exist. Run setup first or create the policy."
    return 1
  fi

  if bao token lookup "${token_id}" &>/dev/null; then
    if [[ "${force_recreate}" == "true" ]]; then
      info "Revoking existing public token: ${token_id}…"
      bao token revoke "${token_id}" &>/dev/null \
        && success "Existing public token revoked." \
        || warn "Could not revoke '${token_id}' directly. It may already be expired or revoked."
    else
      warn "Token '${token_id}' already exists. Skipping."
      warn "Run: ${0} renew-public-token ${app_name} ${app_env}"
      return 0
    fi
  fi

  info "Creating public access token: ${token_id}…"
  if bao token create \
    -id="${token_id}" \
    -policy="${policy_name}" \
    -no-default-policy \
    -orphan \
    -renewable=false \
    &>/dev/null; then
    success "Public access token created: ${token_id}"
  else
    error "Failed to create public token. Check admin permissions and token ID uniqueness."
    return 1
  fi
}

# ─── LIST ─────────────────────────────────────────────────
cmd_list() {
  banner; echo ""
  label "  Managed Policies (bao-setup)"
  divider

  local policies
  policies=$(bao policies list 2>/dev/null || bao policy list 2>/dev/null)

  if [[ -z "$policies" ]]; then
    warn "No policies found."
    return
  fi

  local found=0
  while IFS= read -r p; do
    [[ "$p" =~ ^(public|private)- ]] || { echo -e "  ${DIM}$p${NC}"; continue; }
    echo -e "  ${C}$p${NC}"
    found=$((found+1))
  done <<< "$policies"

  echo ""
  info "Total: $(echo "$policies" | wc -l | tr -d ' ') policies on server"
  divider
}

# ─── REVOKE ───────────────────────────────────────────────
cmd_revoke() {
  banner; echo ""
  label "  Revoke Token"
  divider

  echo -e "  ${C}1)${NC} Revoke by token ID"
  echo -e "  ${C}2)${NC} Revoke by accessor"
  ask "Choice [1/2]:" REVOKE_CHOICE

  case "$REVOKE_CHOICE" in
    1)
      ask_secret "Token ID:" TOKEN_ID
      bao token revoke "$TOKEN_ID" && success "Token revoked."
      ;;
    2)
      ask "Accessor ID:" ACCESSOR_ID
      bao token revoke -accessor "$ACCESSOR_ID" && success "Token revoked by accessor."
      ;;
    *)
      error "Invalid choice."
      exit 1
      ;;
  esac
}

# ─── RENEW PUBLIC TOKEN ───────────────────────────────────
cmd_renew_public_token() {
  banner; echo ""
  label "  Renew Public Token"
  divider

  local APP_NAME="${1:-}"
  local APP_ENV="${2:-}"

  [[ -z "${APP_NAME}" ]] && ask "App name       (e.g. heylomeet):" APP_NAME
  [[ -z "${APP_ENV}"  ]] && ask "Environment    (e.g. production):" APP_ENV

  local token_id policy_name
  token_id="$(public_token_id_for "${APP_NAME}" "${APP_ENV}")"
  policy_name="$(public_policy_name_for "${APP_NAME}" "${APP_ENV}")"

  echo ""
  label "  Preview"
  echo -e "  App         : ${W}${APP_NAME}${NC}"
  echo -e "  Environment : ${W}${APP_ENV}${NC}"
  echo -e "  Policy      : ${C}${policy_name}${NC}"
  echo -e "  Token       : ${C}${token_id}${NC}"
  divider

  confirm "Revoke and recreate this public token?" || { warn "Aborted."; exit 0; }

  echo ""
  create_public_token "${APP_NAME}" "${APP_ENV}" "${policy_name}" true

  echo ""
  info "Test public access:"
  echo -e "  ${DIM}export BAO_TOKEN=${token_id}${NC}"
  echo -e "  ${DIM}bao token lookup \"\${BAO_TOKEN}\"${NC}"
}

# ─── SETUP ─────────────────────────────────────────────────
cmd_setup() {
  banner; echo ""
  label "  New App Policy Setup"
  divider

  # ── Collect inputs ──
  ask "App name       (e.g. heylomeet):"       APP_NAME
  ask "Environment    (e.g. production):"      APP_ENV

  # Single mount per app: heylomeet/
  local MOUNT_PATH="${APP_NAME}"
  MOUNT_PATH="${MOUNT_PATH%/}"

  # Path structure inside mount: env/public/* and env/private/*
  local PATH_PUBLIC="${APP_ENV}/public"
  local PATH_PRIVATE="${APP_ENV}/private"

  echo ""
  label "  Visibility"
  echo -e "  ${C}1)${NC} Public only   → ${DIM}${MOUNT_PATH}/data/${PATH_PUBLIC}/*${NC}"
  echo -e "  ${C}2)${NC} Private only  → ${DIM}${MOUNT_PATH}/data/${PATH_PRIVATE}/*${NC}"
  echo -e "  ${C}3)${NC} Both          → ${DIM}${MOUNT_PATH}/data/${PATH_PUBLIC}/*${NC} + ${DIM}${MOUNT_PATH}/data/${PATH_PRIVATE}/*${NC}"
  ask "Choice [1/2/3]:" VISIBILITY

  echo ""
  label "  KV Keys (optional)"
  info "Enter specific key names (space-separated) to restrict access"
  info "💡 Leave empty for wildcard access within the path — configure exact keys later via Web UI"

  case "$VISIBILITY" in
    1)
      ask "Public keys:" PUBLIC_KEYS
      PRIVATE_KEYS=""
      ;;
    2)
      PUBLIC_KEYS=""
      ask "Private keys:" PRIVATE_KEYS
      ;;
    3)
      ask "Public keys:" PUBLIC_KEYS
      ask "Private keys:" PRIVATE_KEYS
      ;;
    *)
      error "Invalid choice."
      exit 1
      ;;
  esac

  ask "AppRole TTL for private access (e.g. 8760h, 0=infinite) [8760h]:" TOKEN_TTL_INPUT
  TOKEN_TTL="${TOKEN_TTL_INPUT:-8760h}"

  # ── Warn if no keys specified ──
  if [[ -z "$PUBLIC_KEYS" && -z "$PRIVATE_KEYS" ]]; then
    warn "No KV keys specified. Wildcard policies created — lock down via Web UI later."
  fi

  # ── Preview ──
  echo ""
  divider
  label "  Preview"
  echo -e "  App         : ${W}${APP_NAME}${NC}"
  echo -e "  Environment : ${W}${APP_ENV}${NC}"
  echo -e "  Mount       : ${W}${MOUNT_PATH}${NC}"

  case "$VISIBILITY" in
    1)
      echo -e "  Path        : ${W}${PATH_PUBLIC}${NC} ${DIM}(public)${NC}"
      ;;
    2)
      echo -e "  Path        : ${W}${PATH_PRIVATE}${NC} ${DIM}(private)${NC}"
      ;;
    3)
      echo -e "  Paths       : ${W}${PATH_PUBLIC}${NC} ${DIM}(public)${NC}"
      echo -e "                ${W}${PATH_PRIVATE}${NC} ${DIM}(private)${NC}"
      ;;
  esac

  echo -e "  ${DIM}Full path example: /v1/${MOUNT_PATH}/data/${PATH_PUBLIC}/api-key${NC}"

  [[ -n "$PUBLIC_KEYS"  ]] && echo -e "  Public keys : ${G}${PUBLIC_KEYS}${NC}"
  [[ -n "$PRIVATE_KEYS" ]] && echo -e "  Private keys: ${R}${PRIVATE_KEYS}${NC}"
  [[ -z "$PUBLIC_KEYS" && "$VISIBILITY" != "2" ]] && echo -e "  Public keys : ${Y}(wildcard — add exact keys via UI later)${NC}"
  [[ -z "$PRIVATE_KEYS" && "$VISIBILITY" != "1" ]] && echo -e "  Private keys: ${Y}(wildcard — add exact keys via UI later)${NC}"

  divider
  confirm "Apply this configuration?" || { warn "Aborted."; exit 0; }

  echo ""
  label "  Applying…"
  echo ""

  # ── 1. Enable KV v2 mount (once per app) ──
  if ! bao secrets list -format=json 2>/dev/null | grep -q "\"${MOUNT_PATH}/\""; then
    info "Enabling KV v2 secret engine at '${MOUNT_PATH}'…"
    bao secrets enable -path="${MOUNT_PATH}" kv-v2 \
      && success "KV v2 enabled at '${MOUNT_PATH}'."
  else
    info "KV v2 secret engine already exists at '${MOUNT_PATH}'."
  fi

  # ── 1.5. Create UI placeholders (optional, uses admin token) ──
  # This writes tiny dummy secrets so folders appear in Web UI immediately.
  # Safe to skip — folders will appear after first real secret write anyway.
  info "Creating UI placeholders for folder visibility (optional)…"

  if [[ "$VISIBILITY" == "1" || "$VISIBILITY" == "3" ]]; then
    bao kv put "${MOUNT_PATH}/${PATH_PUBLIC}" _created="true" _type="public" &>/dev/null \
      || warn "Failed to create public placeholder."
  fi

  if [[ "$VISIBILITY" == "2" || "$VISIBILITY" == "3" ]]; then
    bao kv put "${MOUNT_PATH}/${PATH_PRIVATE}" _created="true" _type="private" &>/dev/null \
      || warn "Failed to create private placeholder."
  fi

  success "UI placeholders created (folders will appear in Web UI)"

  # ── 2. Build & write public policy ──
  local pub_policy_name=""

  if [[ "$VISIBILITY" == "1" || "$VISIBILITY" == "3" ]]; then
    # Naming: app-env-type (e.g. heylomeet-production-public)
    pub_policy_name="${APP_NAME}-${APP_ENV}-public"
    local pub_policy=""

    if [[ -n "$PUBLIC_KEYS" ]]; then
      for key in $PUBLIC_KEYS; do
        pub_policy+="
path \"${MOUNT_PATH}/data/${PATH_PUBLIC}\" {
  capabilities = [\"read\"]
}
path \"${MOUNT_PATH}/data/${PATH_PUBLIC}/${key}\" {
  capabilities = [\"read\"]
}

path \"${MOUNT_PATH}/metadata/${PATH_PUBLIC}\" {
  capabilities = [\"read\"]
}
path \"${MOUNT_PATH}/metadata/${PATH_PUBLIC}/${key}\" {
  capabilities = [\"list\", \"read\"]
}
"
      done
    else
      pub_policy="
path \"${MOUNT_PATH}/data/${PATH_PUBLIC}\" {
  capabilities = [\"read\"]
}
path \"${MOUNT_PATH}/data/${PATH_PUBLIC}/*\" {
  capabilities = [\"read\"]
}

path \"${MOUNT_PATH}/metadata/${PATH_PUBLIC}\" {
  capabilities = [\"read\"]
}
path \"${MOUNT_PATH}/metadata/${PATH_PUBLIC}/*\" {
  capabilities = [\"list\", \"read\"]
}
"
    fi

    info "Writing policy: ${pub_policy_name}…"
    echo "$pub_policy" | bao policy write "$pub_policy_name" - \
      && success "Policy '${pub_policy_name}' written."

    # Create named public token (not 'anonymous') for better auditability & management.
    # This token is SAFE TO EXPOSE: read-only, scoped to public paths only.
    # Important: created as an orphan so it is not revoked with the admin token that created it.
    create_public_token "${APP_NAME}" "${APP_ENV}" "${pub_policy_name}"
  fi

  # ── 3. Build & write private policy + AppRole ──
  local priv_policy_name=""
  local role_id="" secret_id="" role_name="${APP_NAME}-${APP_ENV}-backend"

  if [[ "$VISIBILITY" == "2" || "$VISIBILITY" == "3" ]]; then
    priv_policy_name="${APP_NAME}-${APP_ENV}-private"
    local priv_policy=""

    if [[ -n "$PRIVATE_KEYS" ]]; then
      for key in $PRIVATE_KEYS; do
        priv_policy+="
path \"${MOUNT_PATH}/data/${PATH_PRIVATE}\" {
  capabilities = [\"read\", \"list\"]
}
path \"${MOUNT_PATH}/data/${PATH_PRIVATE}/${key}\" {
  capabilities = [\"read\", \"list\"]
}
path \"${MOUNT_PATH}/data/${PATH_PRIVATE}/*\" {
  capabilities = [\"read\", \"list\"]
}

path \"${MOUNT_PATH}/metadata/${PATH_PRIVATE}\" {
  capabilities = [\"read\"]
}
path \"${MOUNT_PATH}/metadata/${PATH_PRIVATE}/${key}\" {
  capabilities = [\"list\", \"read\"]
}
"
      done
    else
      priv_policy="
path \"${MOUNT_PATH}/data/${PATH_PRIVATE}\" {
  capabilities = [\"read\", \"list\"]
}
path \"${MOUNT_PATH}/data/${PATH_PRIVATE}/*\" {
  capabilities = [\"read\", \"list\"]
}

path \"${MOUNT_PATH}/metadata/${PATH_PRIVATE}\" {
  capabilities = [\"read\"]
}
path \"${MOUNT_PATH}/metadata/${PATH_PRIVATE}/*\" {
  capabilities = [\"list\", \"read\"]
}
"
    fi

    info "Writing policy: ${priv_policy_name}…"
    echo "$priv_policy" | bao policy write "$priv_policy_name" - \
      && success "Policy '${priv_policy_name}' written."

    # Enable AppRole auth if missing
    if ! bao auth list -format=json 2>/dev/null | grep -q '"approle/"'; then
      info "Enabling AppRole auth method…"
      bao auth enable approle && success "AppRole enabled."
    fi

    # Configure AppRole
    info "Configuring AppRole: ${role_name}…"

    local ttl_flag=""
    [[ "$TOKEN_TTL" != "0" ]] && ttl_flag="token_ttl=${TOKEN_TTL}"

    bao write auth/approle/role/"${role_name}" \
      token_policies="${priv_policy_name}" \
      token_no_default_policy=true \
      token_renewable=true \
      ${ttl_flag} \
      secret_id_num_uses=0 \
      secret_id_ttl=0 &>/dev/null \
      && success "AppRole '${role_name}' configured."

    # Fetch credentials
    role_id=$(bao read -field=role_id auth/approle/role/"${role_name}/role-id" 2>/dev/null)
    secret_id=$(bao write -f -field=secret_id auth/approle/role/"${role_name}/secret-id" 2>/dev/null)
    success "AppRole credentials generated."
  fi

  # ── 4. Summary ──
  echo ""
  echo -e "${G}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${G}║                   ✔  Setup Complete                      ║${NC}"
  echo -e "${G}╠══════════════════════════════════════════════════════════╣${NC}"
  echo -e "${G}║${NC}  App         : ${W}${APP_NAME}${NC}"
  echo -e "${G}║${NC}  Environment : ${W}${APP_ENV}${NC}"
  echo -e "${G}║${NC}  Mount       : ${W}${MOUNT_PATH}${NC}"

  case "$VISIBILITY" in
    1)
      echo -e "${G}║${NC}  ${DIM}📁 Path in UI: ${MOUNT_PATH} → ${PATH_PUBLIC}${NC}"
      ;;
    2)
      echo -e "${G}║${NC}  ${DIM}📁 Path in UI: ${MOUNT_PATH} → ${PATH_PRIVATE}${NC}"
      ;;
    3)
      echo -e "${G}║${NC}  ${DIM}📁 Paths in UI: ${MOUNT_PATH} → ${PATH_PUBLIC} + ${PATH_PRIVATE}${NC}"
      ;;
  esac

  if [[ "$VISIBILITY" == "1" || "$VISIBILITY" == "3" ]]; then
    echo -e "${G}║${NC}"
    echo -e "${G}║${NC}  ${BOLD}🌐 Public Access${NC}"
    echo -e "${G}║${NC}  Policy      : ${C}${pub_policy_name}${NC}"
    echo -e "${G}║${NC}  Token       : ${C}${APP_NAME}-${APP_ENV}-public${NC}"
    echo -e "${G}║${NC}  ${DIM}💡 This token is SAFE TO EXPOSE: read-only, scoped to public paths${NC}"
    echo -e "${G}║${NC}  Keys        : ${C}${PUBLIC_KEYS:-(wildcard read)}${NC}"
  fi

  if [[ "$VISIBILITY" == "2" || "$VISIBILITY" == "3" ]]; then
    echo -e "${G}║${NC}"
    echo -e "${G}║${NC}  ${BOLD}🔒 Private Access${NC}"
    echo -e "${G}║${NC}  Policy      : ${C}${priv_policy_name}${NC}"
    echo -e "${G}║${NC}  AppRole     : ${W}${role_name}${NC}"
    echo -e "${G}║${NC}  BAO_ROLE_ID    : ${Y}${BOLD}${role_id}${NC}"
    echo -e "${G}║${NC}  BAO_SECRET_ID  : ${Y}${BOLD}${secret_id}${NC}  ${R}← NEVER expose these!${NC}"
    echo -e "${G}║${NC}  Keys        : ${R}${PRIVATE_KEYS:-(wildcard read)}${NC}"
  fi

  echo -e "${G}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if [[ -n "$role_id" ]]; then
    warn "AppRole credentials shown ONCE. Export in your backend:"
    echo -e "  ${DIM}export BAO_ADDR=${BAO_ADDR:-${VAULT_ADDR:-http://127.0.0.1:8200}}${NC}"
    echo -e "  ${DIM}export BAO_ROLE_ID=${role_id}${NC}"
    echo -e "  ${DIM}export BAO_SECRET_ID=${secret_id}${NC}"
    echo ""
  fi

  if [[ "$VISIBILITY" == "1" || "$VISIBILITY" == "3" ]]; then
    info "Test public access:"
    echo -e "  ${DIM}# This token is safe to commit to git / use in frontend${NC}"
    echo -e "  ${DIM}export BAO_TOKEN=${APP_NAME}-${APP_ENV}-public${NC}"
    echo -e "  ${DIM}curl -s -H \"X-Vault-Token: \${BAO_TOKEN}\" \\"
    echo -e "    \${BAO_ADDR}/v1/${MOUNT_PATH}/data/${PATH_PUBLIC} | jq${NC}"
    echo ""
  fi

  # ── 5. Guidance for wildcard setup ──
  if [[ -z "$PUBLIC_KEYS" && -z "$PRIVATE_KEYS" ]]; then
    local BAO_SERVER="${BAO_ADDR:-${VAULT_ADDR:-http://127.0.0.1:8200}}"
    local policy_refs=""

    [[ -n "$pub_policy_name"  ]] && policy_refs+="${pub_policy_name} "
    [[ -n "$priv_policy_name" ]] && policy_refs+="${priv_policy_name}"

    echo ""
    echo -e "${Y}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${Y}║  💡  Next Steps: Lock Down via Web UI                    ║${NC}"
    echo -e "${Y}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${Y}║${NC}  1. Open: ${C}${BAO_SERVER}${NC}"
    echo -e "${Y}║${NC}  2. Go to: ${W}Policies → ${policy_refs}${NC}"

    case "$VISIBILITY" in
      1)
        echo -e "${Y}║${NC}  3. Replace wildcard with exact keys under ${PATH_PUBLIC}:"
        echo -e "${Y}║${NC}     ${DIM}path \"${MOUNT_PATH}/data/${PATH_PUBLIC}/api-key\" { capabilities = [\"read\"] }${NC}"
        ;;
      2)
        echo -e "${Y}║${NC}  3. Replace wildcard with exact keys under ${PATH_PRIVATE}:"
        echo -e "${Y}║${NC}     ${DIM}path \"${MOUNT_PATH}/data/${PATH_PRIVATE}/db-password\" { capabilities = [\"read\"] }${NC}"
        ;;
      3)
        echo -e "${Y}║${NC}  3. Replace wildcards with exact keys:"
        echo -e "${Y}║${NC}     ${DIM}# Public:${NC}"
        echo -e "${Y}║${NC}     ${DIM}path \"${MOUNT_PATH}/data/${PATH_PUBLIC}/api-key\" { capabilities = [\"read\"] }${NC}"
        echo -e "${Y}║${NC}     ${DIM}# Private:${NC}"
        echo -e "${Y}║${NC}     ${DIM}path \"${MOUNT_PATH}/data/${PATH_PRIVATE}/db-password\" { capabilities = [\"read\"] }${NC}"
        ;;
    esac

    echo -e "${Y}║${NC}  4. Save & your app is production-ready!"
    echo -e "${Y}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
  fi
}

# ─── Entry point ──────────────────────────────────────────
require_bao
configure_client

CMD="${1:-help}"
shift || true

case "$CMD" in
  setup|add-app)
    require_server
    cmd_setup
    ;;
  list)
    require_server
    cmd_list
    ;;
  renew-public-token)
    require_server
    cmd_renew_public_token "$@"
    ;;
  revoke)
    require_server
    cmd_revoke
    ;;
  help|--help|-h)
    show_help
    ;;
  *)
    error "Unknown command: ${CMD}"
    echo ""
    show_help
    exit 1
    ;;
esac
