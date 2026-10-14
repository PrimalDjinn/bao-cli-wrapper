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

echo
echo "$((total - failures))/$total passed"
exit $((failures > 0))
