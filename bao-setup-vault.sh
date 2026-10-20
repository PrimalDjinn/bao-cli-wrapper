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
  case "${1:-help}" in help|--help|-h) return 0 ;; esac

  # Never fall back to the CLI's localhost default: credentials minted on the wrong
  # server look valid but the real one rejects them. Use BAO_ADDR/VAULT_ADDR if set,
  # else the .env next to this script (see .env.example).
  if [[ -z "${BAO_ADDR:-}" && -z "${VAULT_ADDR:-}" ]]; then
    local env_file
    env_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.env"
    if [[ -f "${env_file}" ]]; then
      set -a
      # shellcheck disable=SC1090
      source "${env_file}"
      set +a
      info "Loaded ${env_file}"
    fi
  fi
  if [[ -z "${BAO_ADDR:-}" && -z "${VAULT_ADDR:-}" ]]; then
    error "BAO_ADDR is not set. Export it or add it to .env (see .env.example)."
    exit 1
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
  echo -e "  ${Y}check-approle${NC}       Log in with an AppRole, optionally read, then revoke the token"
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
  echo -e "  ${DIM}# Prove an AppRole works, with a 15 minute token, then revoke the token${NC}"
  echo -e "  ${C}./bao-setup.sh check-approle --ttl 15m --read heylomeet/production/private${NC}"
  echo ""
  echo -e "  ${W}${BOLD}ENVIRONMENT${NC}"
  echo -e "  ${Y}BAO_ADDR${NC}            OpenBao server address  (e.g. https://bao.example.com:8200)"
  echo -e "  ${Y}BAO_TOKEN${NC}           Root / admin token for management operations"
  echo -e "  ${Y}BAO_CLIENT_TIMEOUT${NC}  Per-request timeout in seconds (default 40)"
  echo -e "  ${Y}BAO_MAX_RETRIES${NC}     Retries for 5xx responses (default 0)"
  echo -e "  ${Y}BAO_SETUP_TOKEN_TTL${NC}      setup: default AppRole token TTL (default 10m)"
  echo -e "  ${Y}BAO_SETUP_TOKEN_MAX_TTL${NC}  setup: default AppRole token max TTL (default 1h)"
  echo -e "  ${Y}BAO_ROLE_ID${NC}         check-approle: role ID (prompted when unset)"
  echo -e "  ${Y}BAO_SECRET_ID${NC}       check-approle: secret ID (prompted when unset)"
  echo -e "  ${Y}BAO_SECRET_ID_FILE${NC}  check-approle: private file holding the secret ID (--secret-id-file)"
  echo -e "  ${Y}BAO_LOGIN_TTL${NC}       check-approle: token TTL to request, e.g. 15m"
  echo ""
}

# Roles are created without the default policy, so a private token can neither look up nor
# revoke itself unless its policy says so. That is what lets an application revoke its token
# after a one-shot read instead of leaving it to live out its TTL. Public tokens are
# deliberately excluded: they are safe to expose, so they must not be able to revoke themselves.
TOKEN_SELF_POLICY='
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
'

# AppRole token lifetimes. Every login creates a token that OpenBao keeps, in memory and in
# storage, until it expires, so the defaults are short. Override them per run at the prompts,
# or for scripted runs with BAO_SETUP_TOKEN_TTL and BAO_SETUP_TOKEN_MAX_TTL.
DEFAULT_TOKEN_TTL="${BAO_SETUP_TOKEN_TTL:-10m}"
DEFAULT_TOKEN_MAX_TTL="${BAO_SETUP_TOKEN_MAX_TTL:-1h}"

# Prints the number of seconds in a duration: plain seconds, or Go-style units such as 10m,
# 1h or 1h30m. Fails on anything else, so a value can never smuggle in another argument.
duration_seconds() {
  local rest="$1" total=0 number unit
  if [[ "${rest}" =~ ^[0-9]{1,9}$ ]]; then
    echo "$((10#${rest}))"
    return 0
  fi
  [[ "${rest}" =~ ^([0-9]{1,9}[smhd])+$ ]] || return 1
  while [[ -n "${rest}" ]]; do
    [[ "${rest}" =~ ^([0-9]{1,9})([smhd])(.*)$ ]] || return 1
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"
    case "${unit}" in
      s) total=$((total + 10#${number})) ;;
      m) total=$((total + 10#${number} * 60)) ;;
      h) total=$((total + 10#${number} * 3600)) ;;
      d) total=$((total + 10#${number} * 86400)) ;;
    esac
  done
  echo "${total}"
}

# 0 leaves a lifetime to the server default. A token cannot be asked to outlive its maximum.
validate_token_lifetimes() {
  local ttl="$1" max="$2" ttl_seconds max_seconds
  if ! ttl_seconds="$(duration_seconds "${ttl}")"; then
    error "Invalid token TTL '${ttl}'. Use seconds or a duration such as 10m or 1h."
    return 1
  fi
  if ! max_seconds="$(duration_seconds "${max}")"; then
    error "Invalid token max TTL '${max}'. Use seconds or a duration such as 10m or 1h."
    return 1
  fi
  if (( ttl_seconds > 0 && max_seconds > 0 && ttl_seconds > max_seconds )); then
    error "The token TTL (${ttl}) cannot exceed the token max TTL (${max})."
    return 1
  fi
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

# ─── CHECK APPROLE ────────────────────────────────────────
# One login, any number of reads with that same token, then revoke-self. The token is
# never printed and the secret ID never appears in a process argument (it travels on
# stdin), so the check leaves no long-lived token behind.
CHECK_TOKEN=""
CHECK_ERRORS=""
CHECK_HOME=""

# The token is forgotten only once it is revoked, so if the revoke is interrupted or fails, the
# EXIT trap tries again.
revoke_check_token() {
  [[ -n "${CHECK_TOKEN}" ]] || return 0
  BAO_TOKEN="${CHECK_TOKEN}" bao token revoke -self &>/dev/null || return 1
  CHECK_TOKEN=""
}

# Prove freshly issued credentials work on this server before printing them: log in
# the same isolated way as check-approle (secret on stdin, no admin token, empty HOME),
# then revoke that token.
verify_new_approle() {
  local token login_home
  login_home="$(mktemp -d)"
  if ! token="$(printf '{"role_id":"%s","secret_id":"%s"}' "$1" "$2" | env -u BAO_TOKEN -u VAULT_TOKEN \
      -u BAO_CONFIG_PATH -u VAULT_CONFIG_PATH HOME="${login_home}" \
      bao write -field=token auth/approle/login - 2>/dev/null)" || [[ -z "${token}" ]]; then
    rm -rf "${login_home}"
    error "The server rejected the new AppRole credentials; not printing them."
    exit 1
  fi
  rm -rf "${login_home}"
  BAO_TOKEN="${token}" bao token revoke -self &>/dev/null \
    || warn "Could not revoke the test login token; it expires with the role's token TTL."
}

cleanup_check() {
  [[ -z "${CHECK_ERRORS}" ]] || rm -f "${CHECK_ERRORS}"
  [[ -z "${CHECK_HOME}" ]] || rm -rf "${CHECK_HOME}"
  revoke_check_token || true
}

# Reads a secret ID from the first line of a private file, so it never touches a command
# line, a shell history or the process environment.
read_secret_id_file() {
  local file="$1" mode
  if [[ ! -f "${file}" || -L "${file}" ]]; then
    error "The secret ID file must be a regular file, not a symlink."
    return 1
  fi
  mode="$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}" 2>/dev/null || true)"
  if [[ -z "${mode}" || "${mode: -2}" != "00" ]]; then
    error "The secret ID file must not be accessible to group or others (chmod 600)."
    return 1
  fi
  SECRET_ID_FROM_FILE=""
  IFS= read -r SECRET_ID_FROM_FILE < "${file}" || true
  [[ -n "${SECRET_ID_FROM_FILE}" ]] || { error "The secret ID file is empty."; return 1; }
}

valid_login_ttl() {
  duration_seconds "$1" &>/dev/null
}

cmd_check_approle() {
  banner; echo ""
  label "  Check AppRole Login"
  divider

  local requested_ttl="${BAO_LOGIN_TTL:-}" secret_id_file="${BAO_SECRET_ID_FILE:-}"
  local -a reads=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --secret-id-file)
        [[ $# -ge 2 ]] || { error "--secret-id-file needs a path."; exit 1; }
        secret_id_file="$2"
        shift 2
        ;;
      --ttl)
        [[ $# -ge 2 ]] || { error "--ttl needs a duration, e.g. 15m."; exit 1; }
        requested_ttl="$2"
        shift 2
        ;;
      --read)
        [[ $# -ge 2 ]] || { error "--read needs a KV path, e.g. heylomeet/production/private."; exit 1; }
        reads+=("$2")
        shift 2
        ;;
      *)
        error "Unknown option: $1"
        exit 1
        ;;
    esac
  done

  if [[ -n "${requested_ttl}" ]] && ! valid_login_ttl "${requested_ttl}"; then
    error "Invalid TTL '${requested_ttl}'. Use seconds or a duration such as 15m or 1h."
    exit 1
  fi

  local role_id="${BAO_ROLE_ID:-}" secret_id="${BAO_SECRET_ID:-}"
  if [[ -n "${secret_id_file}" ]]; then
    if [[ -n "${secret_id}" ]]; then
      error "Use either a secret ID file or BAO_SECRET_ID, not both."
      exit 1
    fi
    read_secret_id_file "${secret_id_file}" || exit 1
    secret_id="${SECRET_ID_FROM_FILE}"
    SECRET_ID_FROM_FILE=""
  fi
  if [[ -z "${role_id}" ]]; then ask "Role ID:" role_id; fi
  if [[ -z "${secret_id}" ]]; then ask_secret "Secret ID:" secret_id; fi
  if [[ ! "${role_id}" =~ ^[A-Za-z0-9._-]+$ || ! "${secret_id}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    error "Role ID and secret ID may only contain letters, digits, '.', '_' and '-'."
    exit 1
  fi

  # `ttl` is optional. Servers that do not know it ignore it and answer with a warning.
  local payload="{\"role_id\":\"${role_id}\",\"secret_id\":\"${secret_id}\""
  if [[ -n "${requested_ttl}" ]]; then payload+=",\"ttl\":\"${requested_ttl}\""; fi
  payload+="}"

  local token
  CHECK_ERRORS="$(mktemp)"
  CHECK_HOME="$(mktemp -d)"
  # bash runs the EXIT trap on exit and when a signal ends the script, so the token is revoked
  # on every path. Separate INT and TERM traps would only delay it until a running read ends.
  trap cleanup_check EXIT

  # No admin credential reaches the login, so it checks the role on its own. BAO_TOKEN and
  # VAULT_TOKEN are removed, and an empty HOME hides the token that `bao login` stores in
  # ~/.vault-token and any token helper named in the CLI's config file.
  if ! token="$(printf '%s' "${payload}" | env -u BAO_TOKEN -u VAULT_TOKEN \
      -u BAO_CONFIG_PATH -u VAULT_CONFIG_PATH HOME="${CHECK_HOME}" \
      bao write -field=token auth/approle/login - 2>"${CHECK_ERRORS}")" || [[ -z "${token}" ]]; then
    error "AppRole login failed: check the credentials, the role, and that OpenBao is reachable."
    exit 1
  fi
  CHECK_TOKEN="${token}"
  success "Logged in. The token is not shown."

  if [[ -n "${requested_ttl}" ]] && grep -qi 'unrecognized parameters.*ttl' "${CHECK_ERRORS}"; then
    warn "This server ignored the requested TTL (older servers do); the role's token_ttl applies."
  fi

  local granted=""
  granted="$(BAO_TOKEN="${CHECK_TOKEN}" bao token lookup -field=ttl 2>/dev/null)" || granted=""
  info "Requested TTL : ${requested_ttl:-role default}"
  if [[ -n "${granted}" ]]; then
    info "Token TTL     : ${granted}s"
  else
    warn "Could not read the token TTL: the role's policy needs read on auth/token/lookup-self."
  fi

  local failed=0 path
  for path in "${reads[@]+"${reads[@]}"}"; do
    if BAO_TOKEN="${CHECK_TOKEN}" bao kv get "${path}" &>/dev/null; then
      success "Read ${path} (values not shown)"
    else
      error "Cannot read ${path}"
      failed=1
    fi
  done

  if revoke_check_token; then
    success "Token revoked with revoke-self."
  else
    warn "Could not revoke the token: the role's policy needs update on auth/token/revoke-self."
    warn "It expires by itself${granted:+ in ${granted}s}."
    failed=1
  fi

  return "${failed}"
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

  info "Every login creates a token that OpenBao keeps until it expires, so lifetimes are short by"
  info "default. Raise them only for an app that needs longer; 0 leaves a lifetime to the server."
  ask "AppRole token TTL for private access (e.g. 10m) [${DEFAULT_TOKEN_TTL}]:" TOKEN_TTL_INPUT
  TOKEN_TTL="${TOKEN_TTL_INPUT:-${DEFAULT_TOKEN_TTL}}"
  ask "AppRole token max TTL, renewals included (e.g. 1h) [${DEFAULT_TOKEN_MAX_TTL}]:" TOKEN_MAX_TTL_INPUT
  TOKEN_MAX_TTL="${TOKEN_MAX_TTL_INPUT:-${DEFAULT_TOKEN_MAX_TTL}}"
  validate_token_lifetimes "$TOKEN_TTL" "$TOKEN_MAX_TTL" || exit 1

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
  if [[ "$VISIBILITY" != "1" ]]; then
    echo -e "  Token TTL   : ${W}${TOKEN_TTL}${NC} ${DIM}(max ${TOKEN_MAX_TTL})${NC}"
  fi

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

    priv_policy+="${TOKEN_SELF_POLICY}"

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

    local -a ttl_args=()
    if [[ "$TOKEN_TTL" != "0" ]]; then ttl_args+=("token_ttl=${TOKEN_TTL}"); fi
    if [[ "$TOKEN_MAX_TTL" != "0" ]]; then ttl_args+=("token_max_ttl=${TOKEN_MAX_TTL}"); fi

    if ! bao write auth/approle/role/"${role_name}" \
      token_policies="${priv_policy_name}" \
      token_no_default_policy=true \
      token_renewable=true \
      ${ttl_args[@]+"${ttl_args[@]}"} \
      secret_id_num_uses=0 \
      secret_id_ttl=0 >/dev/null; then
      error "Could not configure AppRole '${role_name}'."
      exit 1
    fi
    success "AppRole '${role_name}' configured."

    # Fetch credentials; any failure stops the run instead of printing blanks.
    if ! role_id=$(bao read -field=role_id auth/approle/role/"${role_name}/role-id") || [[ -z "${role_id}" ]]; then
      error "Could not read the role ID for '${role_name}'."
      exit 1
    fi
    if ! secret_id=$(bao write -f -field=secret_id auth/approle/role/"${role_name}/secret-id") || [[ -z "${secret_id}" ]]; then
      error "Could not create a secret ID for '${role_name}'."
      exit 1
    fi
    verify_new_approle "${role_id}" "${secret_id}"
    success "AppRole credentials generated and verified with a test login."
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
require_bao "${1:-help}"
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
  check-approle)
    require_server
    cmd_check_approle "$@"
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
