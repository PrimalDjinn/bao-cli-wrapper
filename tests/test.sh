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
  new_case; run_script "demo\nstaging\n2\n${keys}\n\n\ny\n" setup
  policy="$FAKE_BAO_DIR/policy-demo-staging-private.hcl"
  check "private policy (keys='${keys}') grants revoke-self and lookup-self" \
    "$([[ $rc -eq 0 && -f $policy ]] && grep -q 'path "auth/token/revoke-self"' "$policy" && grep -q 'path "auth/token/lookup-self"' "$policy" && echo 0 || echo 1)"
done

check_self_capabilities() { # policy file: exactly lookup-self (read) and revoke-self (update)
  local policy="$1"
  grep -A1 'path "auth/token/revoke-self"' "$policy" | grep -q 'capabilities = \["update"\]' &&
    grep -A1 'path "auth/token/lookup-self"' "$policy" | grep -q 'capabilities = \["read"\]' &&
    [[ $(grep -c 'auth/token/' "$policy") -eq 2 ]]
}
for keys in "" "api-key"; do
  new_case; run_script "demo\nstaging\n2\n${keys}\n\n\ny\n" setup
  check "private policy (keys='${keys}') grants revoke-self update, lookup-self read and nothing else under auth/token" \
    "$(check_self_capabilities "$FAKE_BAO_DIR/policy-demo-staging-private.hcl" && echo 0 || echo 1)"
done

new_case; run_script "demo\nstaging\n1\n\n\n\ny\n" setup
check "the public policy never grants token self-service" \
  "$([[ -f $FAKE_BAO_DIR/policy-demo-staging-public.hcl ]] && ! grep -q 'auth/token' "$FAKE_BAO_DIR/policy-demo-staging-public.hcl" && echo 0 || echo 1)"

# --- short AppRole token lifetimes ---------------------------------------------
role_call() { calls | grep 'ARGS=write auth/approle/role/' || true; }
no_role_written() { [[ -z "$(role_call)" ]] && ! has_call 'policy write' && ! has_call 'secrets enable'; }

new_case; run_script "demo\nstaging\n2\n\n\n\ny\n" setup
check "a new role defaults to a 10 minute token with a 1 hour maximum" \
  "$(role_call | grep -q 'token_ttl=10m token_max_ttl=1h ' && ! has_call '8760h' && output_has 'Token TTL' && echo 0 || echo 1)"

new_case; run_script "demo\nstaging\n2\n\n30m\n2h\ny\n" setup
check "the prompts override both lifetimes" "$(role_call | grep -q 'token_ttl=30m token_max_ttl=2h ' && echo 0 || echo 1)"

new_case; EXTRA_ENV=(BAO_SETUP_TOKEN_TTL=5m BAO_SETUP_TOKEN_MAX_TTL=45m); run_script "demo\nstaging\n2\n\n\n\ny\n" setup
check "the environment changes the defaults offered" "$(role_call | grep -q 'token_ttl=5m token_max_ttl=45m ' && output_has '\[5m\]' && echo 0 || echo 1)"
EXTRA_ENV=()

new_case; run_script "demo\nstaging\n2\n\n720h\n720h\ny\n" setup
check "an app that needs longer tokens can ask for them" "$(role_call | grep -q 'token_ttl=720h token_max_ttl=720h ' && echo 0 || echo 1)"

new_case; run_script "demo\nstaging\n2\n\n0\n0\ny\n" setup
check "0 leaves both lifetimes to the server" "$(role_call | grep -q 'token_renewable=true secret_id_num_uses=0' && ! role_call | grep -q 'token_ttl\|token_max_ttl' && echo 0 || echo 1)"

new_case; run_script "demo\nstaging\n2\n\n90m\n1h30m\ny\n" setup
check "a TTL equal to the maximum is accepted across units" "$([[ $rc -eq 0 ]] && role_call | grep -q 'token_ttl=90m token_max_ttl=1h30m ' && echo 0 || echo 1)"

new_case; run_script "demo\nstaging\n2\n\n91m\n1h30m\ny\n" setup
check "a TTL above the maximum is rejected before anything is written" "$([[ $rc -ne 0 ]] && output_has 'cannot exceed' && no_role_written && echo 0 || echo 1)"

new_case; run_script "demo\nstaging\n2\n\n10m token_policies=root\n1h\ny\n" setup
check "a TTL that tries to add another argument is rejected" "$([[ $rc -ne 0 ]] && output_has 'Invalid token TTL' && no_role_written && ! calls | grep -q 'token_policies=root' && echo 0 || echo 1)"

new_case; run_script "demo\nstaging\n2\n\n10m\nsoon\ny\n" setup
check "an invalid maximum is rejected" "$([[ $rc -ne 0 ]] && output_has 'Invalid token max TTL' && no_role_written && echo 0 || echo 1)"

# --- check-approle -------------------------------------------------------------
creds=(BAO_ROLE_ID=role-id-sentinel BAO_SECRET_ID=secret-id-sentinel BAO_TOKEN=admin-token-sentinel)

new_case; EXTRA_ENV=("${creds[@]}"); run_script "" check-approle --ttl 15m --read demo/staging/private --read demo/staging/other
login="$(cat "$FAKE_BAO_DIR/login.stdin" 2>/dev/null)"
check "login sends the role, secret and requested ttl as JSON on stdin" \
  "$([[ $login == '{"role_id":"role-id-sentinel","secret_id":"secret-id-sentinel","ttl":"15m"}' ]] && echo 0 || echo 1)"
check "the secret ID is never a process argument" "$(calls | grep -q 'secret-id-sentinel' && echo 1 || echo 0)"
check "the login does not send the admin token" "$(has_call 'TOKEN= TIMEOUT=40 RETRIES=0 HOME=[^ ]* ARGS=write -field=token auth/approle/login -' && echo 0 || echo 1)"
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

# --- the login uses no ambient credential -------------------------------------
new_case; printf 'stored-login-token-sentinel' > "$FAKE_BAO_DIR/.vault-token"
EXTRA_ENV=(BAO_ROLE_ID=role-id-sentinel BAO_SECRET_ID=secret-id-sentinel); run_script "" check-approle --read demo/staging/private
login_line="$(calls | grep 'ARGS=write -field=token auth/approle/login' || true)"
check "a token stored by bao login is not sent with the login" \
  "$([[ $rc -eq 0 && -n $login_line && $login_line == *' TOKEN= TIMEOUT'* ]] && echo 0 || echo 1)"
check "the login runs in a throwaway HOME that is removed afterwards" \
  "$(login_home="$(sed -n 's/.* HOME=\([^ ]*\) ARGS=write -field=token.*/\1/p' <<< "$login_line")"; [[ -n $login_home && $login_home != "$FAKE_BAO_DIR" && ! -e $login_home ]] && echo 0 || echo 1)"
EXTRA_ENV=()

# --- the secret ID from a file --------------------------------------------------
new_case; printf 'file-secret-id-sentinel\n' > "$FAKE_BAO_DIR/secret"; chmod 600 "$FAKE_BAO_DIR/secret"
EXTRA_ENV=(BAO_ROLE_ID=role-id-sentinel); run_script "" check-approle --secret-id-file "$FAKE_BAO_DIR/secret"
check "a secret ID can come from a private file and never from an argument" \
  "$([[ $rc -eq 0 ]] && grep -q '"secret_id":"file-secret-id-sentinel"' "$FAKE_BAO_DIR/login.stdin" && ! calls | grep -q 'file-secret-id-sentinel' && echo 0 || echo 1)"

new_case; printf 'file-secret-id-sentinel\n' > "$FAKE_BAO_DIR/secret"; chmod 600 "$FAKE_BAO_DIR/secret"
EXTRA_ENV=(BAO_ROLE_ID=role-id-sentinel BAO_SECRET_ID_FILE="$FAKE_BAO_DIR/secret"); run_script "" check-approle
check "BAO_SECRET_ID_FILE works like the flag" "$([[ $rc -eq 0 ]] && grep -q 'file-secret-id-sentinel' "$FAKE_BAO_DIR/login.stdin" && echo 0 || echo 1)"

new_case; printf 'file-secret-id-sentinel\n' > "$FAKE_BAO_DIR/secret"; chmod 640 "$FAKE_BAO_DIR/secret"
EXTRA_ENV=(BAO_ROLE_ID=role-id-sentinel); run_script "" check-approle --secret-id-file "$FAKE_BAO_DIR/secret"
check "a secret ID file readable by the group is refused before any login" \
  "$([[ $rc -ne 0 ]] && output_has 'chmod 600' && ! has_call 'approle/login' && echo 0 || echo 1)"

new_case; printf 'file-secret-id-sentinel\n' > "$FAKE_BAO_DIR/secret"; chmod 600 "$FAKE_BAO_DIR/secret"; ln -s "$FAKE_BAO_DIR/secret" "$FAKE_BAO_DIR/link"
EXTRA_ENV=(BAO_ROLE_ID=role-id-sentinel); run_script "" check-approle --secret-id-file "$FAKE_BAO_DIR/link"
check "a symlinked secret ID file is refused" "$([[ $rc -ne 0 ]] && output_has 'regular file' && ! has_call 'approle/login' && echo 0 || echo 1)"

new_case; : > "$FAKE_BAO_DIR/empty"; chmod 600 "$FAKE_BAO_DIR/empty"
EXTRA_ENV=(BAO_ROLE_ID=role-id-sentinel); run_script "" check-approle --secret-id-file "$FAKE_BAO_DIR/empty"
check "an empty secret ID file is refused" "$([[ $rc -ne 0 ]] && output_has 'empty' && ! has_call 'approle/login' && echo 0 || echo 1)"

new_case; printf 'file-secret-id-sentinel\n' > "$FAKE_BAO_DIR/secret"; chmod 600 "$FAKE_BAO_DIR/secret"
EXTRA_ENV=(BAO_ROLE_ID=role-id-sentinel BAO_SECRET_ID=env-secret-id-sentinel); run_script "" check-approle --secret-id-file "$FAKE_BAO_DIR/secret"
check "a file and BAO_SECRET_ID together are refused" "$([[ $rc -ne 0 ]] && output_has 'not both' && ! has_call 'approle/login' && echo 0 || echo 1)"
EXTRA_ENV=()

# --- a failed or interrupted revoke is retried -----------------------------------
new_case; EXTRA_ENV=("${creds[@]}" FAKE_REVOKE_FAIL_ONCE=1); run_script "" check-approle
check "a revoke that fails is retried on exit and the failure is still reported" \
  "$([[ $rc -ne 0 && $(count_calls 'TOKEN=login-token-sentinel .*ARGS=token revoke -self') -eq 2 ]] && output_has 'Could not revoke' && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}" FAKE_REVOKE_FAIL=1); run_script "" check-approle
check "a revoke that keeps failing is tried twice, not forever" \
  "$([[ $rc -ne 0 && $(count_calls 'TOKEN=login-token-sentinel .*ARGS=token revoke -self') -eq 2 ]] && echo 0 || echo 1)"

new_case; EXTRA_ENV=("${creds[@]}"); run_script "" check-approle
check "a revoke that succeeds is not repeated on exit" \
  "$([[ $rc -eq 0 && $(count_calls 'ARGS=token revoke -self') -eq 1 ]] && echo 0 || echo 1)"

# --- no CLI config reaches the login -----------------------------------------------
new_case; EXTRA_ENV=("${creds[@]}" BAO_CONFIG_PATH=/etc/bao/admin.hcl VAULT_CONFIG_PATH=/etc/vault/admin.hcl)
run_script "" check-approle --read demo/staging/private
login_line="$(calls | grep 'ARGS=write -field=token auth/approle/login' || true)"
check "BAO_CONFIG_PATH and VAULT_CONFIG_PATH are not passed to the login" \
  "$([[ $rc -eq 0 && -n $login_line && $login_line == 'CONFIG= TOKEN='* ]] && echo 0 || echo 1)"
check "the test environment really carries the config paths to the other calls" \
  "$(calls | grep 'ARGS=status' | grep -q 'CONFIG=/etc/bao/admin.hcl/etc/vault/admin.hcl' && echo 0 || echo 1)"
EXTRA_ENV=()

# --- interrupts and termination --------------------------------------------------------
# The shell is started in its own session with default signal handling (a background job
# of this script would inherit "ignore SIGINT"). "group" signals the whole process group, as
# a terminal does for Ctrl-C; "shell" signals only the script while its call is still running.
# The blocker holds either the read or the first revoke open.
signal_check() { # signal, target (group|shell), expected exit status, blocker (read|revoke), revokes
  new_case
  local blocker="FAKE_BLOCK_READ=1" extra=(--read demo/staging/private)
  if [[ "$4" == revoke ]]; then blocker="FAKE_BLOCK_REVOKE_ONCE=1"; extra=(); fi
  EXTRA_ENV=(BAO_ROLE_ID=role-id-sentinel BAO_SECRET_ID=secret-id-sentinel "$blocker")
  env -i HOME="$FAKE_BAO_DIR" PATH="$FAKE_BAO_DIR/bin:/usr/bin:/bin" FAKE_BAO_DIR="$FAKE_BAO_DIR" \
    BAO_ADDR=https://bao.example "${EXTRA_ENV[@]}" \
    perl -MPOSIX -e 'POSIX::setsid(); $SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV or die' -- \
    bash "$ROOT/bao-setup-vault.sh" check-approle "${extra[@]+"${extra[@]}"}" > "$out" 2>&1 &
  local pid=$! group="" waited=0
  while [[ ! -s "$FAKE_BAO_DIR/blocked" && $waited -lt 100 ]]; do sleep 0.1; waited=$((waited + 1)); done
  group="$(cat "$FAKE_BAO_DIR/blocked" 2>/dev/null)"
  if [[ -n "$group" ]]; then
    if [[ "$2" == group ]]; then kill "-$1" -- "-$group"; else kill "-$1" "$pid"; fi
  fi
  wait "$pid"; rc=$?
  [[ -z "$group" ]] || kill -KILL -- "-$group" 2> /dev/null || true
  check "SIG$1 to the $2 during a $4 still revokes the token ($5 revoke calls) and exits $3" \
    "$([[ -n $group && $rc -eq $3 && $(count_calls 'TOKEN=login-token-sentinel .*ARGS=token revoke -self') -eq $5 ]] && echo 0 || echo 1)"
  EXTRA_ENV=()
}
if command -v perl > /dev/null; then
  signal_check INT group 130 read 1
  signal_check TERM group 143 read 1
  signal_check TERM shell 143 read 1
  # The interrupted revoke never finished, so the exit trap revokes again.
  signal_check TERM group 143 revoke 2
  signal_check TERM shell 143 revoke 2
else
  echo "skip - signal tests need perl"
fi

echo
echo "$((total - failures))/$total passed"
exit $((failures > 0))
