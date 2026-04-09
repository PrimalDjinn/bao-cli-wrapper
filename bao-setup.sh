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
  echo -e "  ${Y}setup${NC}          Interactive TUI to configure an app's ACL & policies"
  echo -e "  ${Y}add-app${NC}        Quickly add a new app (alias for setup)"
  echo -e "  ${Y}list${NC}           List all bao-setup managed policies"
  echo -e "  ${Y}token${NC}          Generate or retrieve a token for a private app"
  echo -e "  ${Y}revoke${NC}         Revoke a token by accessor or token ID"
  echo -e "  ${Y}help${NC}           Show this message"
  divider
  echo ""
  echo -e "  ${W}${BOLD}EXAMPLES${NC}"
  echo -e "  ${DIM}# Full interactive setup for an app${NC}"
  echo -e "  ${C}./bao-setup.sh setup${NC}"
  echo ""
  echo -e "  ${DIM}# List all managed policies${NC}"
  echo -e "  ${C}./bao-setup.sh list${NC}"
  echo ""
  echo -e "  ${W}${BOLD}ENVIRONMENT${NC}"
  echo -e "  ${Y}BAO_ADDR${NC}       OpenBao server address  (e.g. https://bao.example.com:8200)"
  echo -e "  ${Y}BAO_TOKEN${NC}      Root / admin token for management operations"
  echo ""
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

  echo ""; info "Total: $(echo "$policies" | wc -l | tr -d ' ') policies on server"
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
    1) ask_secret "Token ID:" TOKEN_ID; bao token revoke "$TOKEN_ID" && success "Token revoked." ;;
    2) ask "Accessor ID:" ACCESSOR_ID; bao token revoke -accessor "$ACCESSOR_ID" && success "Token revoked by accessor." ;;
    *) error "Invalid choice."; exit 1 ;;
  esac
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
    1) ask "Public keys:" PUBLIC_KEYS; PRIVATE_KEYS="" ;;
    2) PUBLIC_KEYS=""; ask "Private keys:" PRIVATE_KEYS ;;
    3) ask "Public keys:" PUBLIC_KEYS; ask "Private keys:" PRIVATE_KEYS ;;
    *) error "Invalid choice."; exit 1 ;;
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
    1) echo -e "  Path        : ${W}${PATH_PUBLIC}${NC} ${DIM}(public)${NC}" ;;
    2) echo -e "  Path        : ${W}${PATH_PRIVATE}${NC} ${DIM}(private)${NC}" ;;
    3) echo -e "  Paths       : ${W}${PATH_PUBLIC}${NC} ${DIM}(public)${NC}"
       echo -e "                ${W}${PATH_PRIVATE}${NC} ${DIM}(private)${NC}" ;;
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
    bao secrets enable -path="${MOUNT_PATH}" kv-v2 && success "KV v2 enabled at '${MOUNT_PATH}'."
  else
    info "KV v2 secret engine already exists at '${MOUNT_PATH}'."
  fi

    # ── 1.5. Create UI placeholders (so folders appear in Web UI) ──
  info "Creating UI placeholders to visualize path structure…"
  if [[ "$VISIBILITY" == "1" || "$VISIBILITY" == "3" ]]; then
    bao write "${MOUNT_PATH}/data/${PATH_PUBLIC}/.bao-setup" _path="${PATH_PUBLIC}" _type="public" &>/dev/null || warn "Could not create public placeholder (non-critical)"
    success "Folder '${PATH_PUBLIC}/' now visible in UI"
  fi
  if [[ "$VISIBILITY" == "2" || "$VISIBILITY" == "3" ]]; then
    bao write "${MOUNT_PATH}/data/${PATH_PRIVATE}/.bao-setup" _path="${PATH_PRIVATE}" _type="private" &>/dev/null || warn "Could not create private placeholder (non-critical)"
    success "Folder '${PATH_PRIVATE}/' now visible in UI"
  fi

  # ── 2. Build & write public policy ──
  local pub_policy_name=""
  if [[ "$VISIBILITY" == "1" || "$VISIBILITY" == "3" ]]; then
    # Naming: app-env-type (e.g. heylomeet-production-public)
    pub_policy_name="${APP_NAME}-${APP_ENV}-public"
    local pub_policy=""

    if [[ -n "$PUBLIC_KEYS" ]]; then
      for key in $PUBLIC_KEYS; do
        pub_policy+="
path \"${MOUNT_PATH}/data/${PATH_PUBLIC}/${key}\" {
  capabilities = [\"read\"]
}
path \"${MOUNT_PATH}/metadata/${PATH_PUBLIC}/${key}\" {
  capabilities = [\"list\", \"read\"]
}
"
      done
    else
      pub_policy="
path \"${MOUNT_PATH}/data/${PATH_PUBLIC}/*\" {
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

    # Create named public token (not 'anonymous') for better auditability & management
    # This token is SAFE TO EXPOSE: read-only, scoped to public paths only
    info "Creating public access token…"
    local public_token_id="${APP_NAME}-${APP_ENV}-public"
    if bao token lookup "${public_token_id}" &>/dev/null; then
      warn "Token '${public_token_id}' already exists. Skipping."
    else
      if bao token create -id="${public_token_id}" -policy="${pub_policy_name}" \
        -no-default-policy -renewable=false -ttl=0 &>/dev/null; then
        success "Public access token created: ${public_token_id}"
      else
        warn "Failed to create public token. Check admin permissions."
      fi
    fi
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
path \"${MOUNT_PATH}/data/${PATH_PRIVATE}/${key}\" {
  capabilities = [\"read\", \"list\"]
}
path \"${MOUNT_PATH}/metadata/${PATH_PRIVATE}/${key}\" {
  capabilities = [\"list\", \"read\"]
}
"
      done
    else
      priv_policy="
path \"${MOUNT_PATH}/data/${PATH_PRIVATE}/*\" {
  capabilities = [\"read\", \"list\"]
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
      secret_id_ttl=0 &>/dev/null && success "AppRole '${role_name}' configured."

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
    1) echo -e "${G}║${NC}  ${DIM}📁 Path in UI: ${MOUNT_PATH} → ${PATH_PUBLIC}${NC}" ;;
    2) echo -e "${G}║${NC}  ${DIM}📁 Path in UI: ${MOUNT_PATH} → ${PATH_PRIVATE}${NC}" ;;
    3) echo -e "${G}║${NC}  ${DIM}📁 Paths in UI: ${MOUNT_PATH} → ${PATH_PUBLIC} + ${PATH_PRIVATE}${NC}" ;;
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
    echo -e "    \${BAO_ADDR}/v1/${MOUNT_PATH}/data/${PATH_PUBLIC}/api-key | jq${NC}"
    echo ""
  fi

  # ── 5. Guidance for wildcard setup ──
  if [[ -z "$PUBLIC_KEYS" && -z "$PRIVATE_KEYS" ]]; then
    local BAO_SERVER="${BAO_ADDR:-${VAULT_ADDR:-http://127.0.0.1:8200}}"
    local policy_refs=""
    [[ -n "$pub_policy_name" ]] && policy_refs+="${pub_policy_name} "
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

CMD="${1:-help}"
shift || true

case "$CMD" in
  setup|add-app)  cmd_setup  ;;
  list)           cmd_list   ;;
  revoke)         cmd_revoke ;;
  help|--help|-h) show_help  ;;
  *)
    error "Unknown command: ${CMD}"
    echo ""
    show_help
    exit 1
    ;;
esac