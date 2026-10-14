#!/usr/bin/env bash
# Behavioural tests for bao-setup-vault.sh against a fake bao CLI. No server is needed.
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0 total=0

new_case() {
  FAKE_BAO_DIR="$(mktemp -d)"
  export FAKE_BAO_DIR
  mkdir -p "$FAKE_BAO_DIR/bin"
  cp "$ROOT/tests/fake-bao" "$FAKE_BAO_DIR/bin/bao"
  : > "$FAKE_BAO_DIR/calls.log"
  out="$FAKE_BAO_DIR/out.txt"
}

# run_script <stdin> <args...>: runs the script with a clean FAKE_* and BAO_* environment.
run_script() {
  local input="$1"; shift
  printf '%b' "$input" | env -i HOME="$FAKE_BAO_DIR" PATH="$FAKE_BAO_DIR/bin:/usr/bin:/bin" \
    FAKE_BAO_DIR="$FAKE_BAO_DIR" BAO_ADDR=https://bao.example "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
    bash "$ROOT/bao-setup-vault.sh" "$@" > "$out" 2>&1
  rc=$?
}

check() { # name, condition result (0 = pass)
  total=$((total + 1))
  if [[ "$2" == 0 ]]; then echo "ok   - $1"; else echo "FAIL - $1"; failures=$((failures + 1)); fi
}
calls() { cat "$FAKE_BAO_DIR/calls.log"; }
has_call() { calls | grep -q -- "$1"; }
count_calls() { calls | grep -c -- "$1" || true; }
output_has() { grep -q -- "$1" "$out"; }

EXTRA_ENV=()

# --- client bounds -------------------------------------------------------------
new_case; run_script "" list
check "defaults bound each request to 40 seconds with no retries" "$(has_call 'TIMEOUT=40 RETRIES=0' && echo 0 || echo 1)"

new_case; EXTRA_ENV=(BAO_CLIENT_TIMEOUT=7 BAO_MAX_RETRIES=1); run_script "" list
check "an explicit timeout and retry count are kept" "$(has_call 'TIMEOUT=7 RETRIES=1' && echo 0 || echo 1)"

new_case; EXTRA_ENV=(VAULT_CLIENT_TIMEOUT=9 VAULT_MAX_RETRIES=3); run_script "" list
check "the VAULT_* spellings are not overridden" "$(has_call 'TIMEOUT= RETRIES=' && echo 0 || echo 1)"
EXTRA_ENV=()

# --- preflight -----------------------------------------------------------------
new_case; EXTRA_ENV=(FAKE_STATUS_RC=2); run_script "" setup
check "a sealed server stops setup before any question" "$([[ $rc -ne 0 ]] && output_has 'sealed' && ! output_has 'App name' && echo 0 || echo 1)"

new_case; EXTRA_ENV=(FAKE_STATUS_RC=1); run_script "" list
check "an unreachable server stops the command with guidance" "$([[ $rc -ne 0 ]] && output_has 'did not answer' && [[ $(count_calls 'ARGS=policies') -eq 0 ]] && echo 0 || echo 1)"

new_case; EXTRA_ENV=(FAKE_STATUS_RC=1 BAO_SETUP_SKIP_PREFLIGHT=1); run_script "" list
check "the preflight can be skipped" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"

new_case; EXTRA_ENV=(FAKE_STATUS_RC=1); run_script "" help
check "help needs no server" "$([[ $rc -eq 0 ]] && output_has 'COMMANDS' && echo 0 || echo 1)"
EXTRA_ENV=()

# --- private policy lets a token inspect and revoke itself ---------------------
for keys in "" "api-key"; do
  new_case; run_script "demo\nstaging\n2\n${keys}\n\ny\n" setup
  policy="$FAKE_BAO_DIR/policy-demo-staging-private.hcl"
  check "private policy (keys='${keys}') grants revoke-self and lookup-self" \
    "$([[ $rc -eq 0 && -f $policy ]] && grep -q 'path "auth/token/revoke-self"' "$policy" && grep -q 'path "auth/token/lookup-self"' "$policy" && echo 0 || echo 1)"
done

new_case; run_script "demo\nstaging\n1\n\n\ny\n" setup
check "the public policy never grants token self-service" \
  "$([[ -f $FAKE_BAO_DIR/policy-demo-staging-public.hcl ]] && ! grep -q 'auth/token' "$FAKE_BAO_DIR/policy-demo-staging-public.hcl" && echo 0 || echo 1)"

# --- check-approle -------------------------------------------------------------
creds=(BAO_ROLE_ID=role-id-sentinel BAO_SECRET_ID=secret-id-sentinel BAO_TOKEN=admin-token-sentinel)

new_case; EXTRA_ENV=("${creds[@]}"); run_script "" check-approle --ttl 15m --read demo/staging/private --read demo/staging/other
login="$(cat "$FAKE_BAO_DIR/login.stdin" 2>/dev/null)"
check "login sends the role, secret and requested ttl as JSON on stdin" \
  "$([[ $login == '{"role_id":"role-id-sentinel","secret_id":"secret-id-sentinel","ttl":"15m"}' ]] && echo 0 || echo 1)"
check "the secret ID is never a process argument" "$(calls | grep -q 'secret-id-sentinel' && echo 1 || echo 0)"
check "the login does not send the admin token" "$(has_call 'TOKEN= TIMEOUT=40 RETRIES=0 ARGS=write -field=token auth/approle/login -' && echo 0 || echo 1)"
check "one login serves every read" "$([[ $(count_calls 'ARGS=write -field=token') -eq 1 && $(count_calls 'TOKEN=login-token-sentinel .*ARGS=kv get') -eq 2 ]] && echo 0 || echo 1)"
check "the token is revoked once with revoke-self after the reads" \
  "$([[ $(count_calls 'TOKEN=login-token-sentinel .*ARGS=token revoke -self') -eq 1 ]] && [[ $(calls | grep -n 'kv get' | tail -1 | cut -d: -f1) -lt $(calls | grep -n 'revoke -self' | cut -d: -f1) ]] && echo 0 || echo 1)"
check "success exits 0 and prints no token or secret" \
  "$([[ $rc -eq 0 ]] && ! output_has 'login-token-sentinel' && ! output_has 'secret-id-sentinel' && ! output_has 'secret-value-sentinel' && output_has 'Token TTL' && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}" FAKE_WARN_TTL=1); run_script "" check-approle --ttl 1h
check "an ignored ttl is reported" "$([[ $rc -eq 0 ]] && output_has 'ignored the requested TTL' && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}"); run_script "" check-approle
check "without --ttl no ttl is requested" "$([[ $(cat "$FAKE_BAO_DIR/login.stdin") == '{"role_id":"role-id-sentinel","secret_id":"secret-id-sentinel"}' ]] && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}" BAO_LOGIN_TTL=30m); run_script "" check-approle
check "BAO_LOGIN_TTL supplies the default ttl" "$(grep -q '"ttl":"30m"' "$FAKE_BAO_DIR/login.stdin" && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}" FAKE_READ_FAIL=1); run_script "" check-approle --read demo/staging/private
check "a failed read fails the check but the token is still revoked" \
  "$([[ $rc -ne 0 ]] && output_has 'Cannot read' && has_call 'ARGS=token revoke -self' && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}" FAKE_REVOKE_FAIL=1); run_script "" check-approle
check "a failed revoke is reported and fails the check" "$([[ $rc -ne 0 ]] && output_has 'Could not revoke' && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}" FAKE_LOOKUP_FAIL=1); run_script "" check-approle
check "a role that cannot look itself up still works and says why" "$([[ $rc -eq 0 ]] && output_has 'lookup-self' && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}" FAKE_LOGIN_FAIL=1); run_script "" check-approle
check "a failed login fails without revoking anything" "$([[ $rc -ne 0 ]] && output_has 'AppRole login failed' && ! has_call 'revoke' && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}"); run_script "" check-approle --ttl 'soon'
check "an invalid ttl is rejected before any login" "$([[ $rc -ne 0 ]] && output_has 'Invalid TTL' && ! has_call 'approle/login' && echo 0 || echo 1)"

new_case; EXTRA_ENV=(BAO_ROLE_ID=role BAO_SECRET_ID='bad"id'); run_script "" check-approle
check "credentials that could break the JSON are rejected before any login" "$([[ $rc -ne 0 ]] && output_has 'may only contain' && ! has_call 'approle/login' && echo 0 || echo 1)"

new_case; EXTRA_ENV=(); run_script "typed-role\ntyped-secret\n" check-approle
check "missing credentials are prompted for" "$([[ $rc -eq 0 ]] && grep -q '"role_id":"typed-role","secret_id":"typed-secret"' "$FAKE_BAO_DIR/login.stdin" && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}"); run_script "" check-approle --bogus
check "unknown options are rejected" "$([[ $rc -ne 0 ]] && output_has 'Unknown option' && ! has_call 'approle/login' && echo 0 || echo 1)"

echo
echo "$((total - failures))/$total passed"
exit $((failures > 0))
