#!/usr/bin/env bash
#
# Tests for the `token` output.
#
# The auth and set-outputs steps are extracted from action.yml and run
# directly against local OIDC and STS mocks, so no test here needs
# `id-token: write` or network access. The set-outputs step is fed exactly
# what the auth step wrote to GITHUB_OUTPUT, which is how the runner wires
# `steps.auth.outputs.*` into it.
set -u -o pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ACTION_YML="${ACTION_YML:-$REPO_ROOT/action.yml}"
WORK=$(mktemp -d)
AUTH_SCRIPT="$WORK/auth.sh"
OUTPUTS_SCRIPT="$WORK/set-outputs.sh"
MOCK_PIDS=()

cleanup() {
  for pid in "${MOCK_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

python3 "$REPO_ROOT/test/extract_script.py" "$ACTION_YML" auth > "$AUTH_SCRIPT"
python3 "$REPO_ROOT/test/extract_script.py" "$ACTION_YML" set-outputs > "$OUTPUTS_SCRIPT"

FAILURES=0

start_case() {
  echo
  echo "=== $1 ==="
}

check() { # <what> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok   $1: $3"
  else
    echo "  FAIL $1: expected '$2', got '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

start_mock() { # <port> <extra args...>
  local port=$1; shift
  python3 "$REPO_ROOT/test/mock_server.py" --port "$port" "$@" &
  MOCK_PIDS+=("$!")
  local i
  for i in $(seq 1 40); do
    if curl -sf -o /dev/null "http://127.0.0.1:${port}/__ready"; then return 0; fi
    sleep 0.25
  done
  echo "FATAL: mock on port ${port} did not start"
  exit 1
}

# output_value <file> <name> -> the value of name=value in a GITHUB_OUTPUT file
output_value() {
  sed -n "s/^$2=//p" "$1"
}

# run_steps <bot-id> <sts-url>
# Runs the auth step, then the set-outputs step with the auth step's outputs.
# Sets AUTH_EXIT and OUTPUTS_EXIT; the action's final outputs are in
# $WORK/action_output. The logs are $WORK/out.log (auth) and
# $WORK/outputs.log (set-outputs).
run_steps() {
  rm -rf "$WORK/home" "$WORK/auth_output" "$WORK/action_output" "$WORK/github_env" "$WORK/out.log" "$WORK/outputs.log"
  mkdir -p "$WORK/home"
  touch "$WORK/auth_output" "$WORK/action_output" "$WORK/github_env"
  AUTH_EXIT=0
  env -i \
    PATH="$PATH" \
    HOME="$WORK/home" \
    BOT_ID="$1" \
    STS_URL="$2" \
    AUDIENCE_INPUT="" \
    REGISTRY_URL="https://golang.flatt.tech" \
    EXPIRES_IN="1800" \
    SET_GOPROXY="true" \
    ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:${OIDC_PORT}/token" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="mock-request-token" \
    GITHUB_ENV="$WORK/github_env" \
    GITHUB_OUTPUT="$WORK/auth_output" \
    bash -e -o pipefail "$AUTH_SCRIPT" > "$WORK/out.log" 2>&1 || AUTH_EXIT=$?

  # A failed auth step fails the job, so the set-outputs step never runs.
  OUTPUTS_EXIT=skipped
  [ "$AUTH_EXIT" -eq 0 ] || return 0
  OUTPUTS_EXIT=0
  env -i \
    PATH="$PATH" \
    ACCESS_TOKEN="$(output_value "$WORK/auth_output" token)" \
    EXPIRES_AT="$(output_value "$WORK/auth_output" expires_at)" \
    GITHUB_OUTPUT="$WORK/action_output" \
    bash -e -o pipefail "$OUTPUTS_SCRIPT" > "$WORK/outputs.log" 2>&1 || OUTPUTS_EXIT=$?
}

# --- 0: action outputs wiring --------------------------------------------------
# The cases below run the step bodies only, so they cannot see which step output
# each action output reads. A typo there would leave the action output empty.
start_case "0: action outputs read the set-outputs step"
output_ref() { # <output name> -> the value expression of that action output
  python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["outputs"][sys.argv[2]]["value"])' \
    "$ACTION_YML" "$1" 2>/dev/null
}
check "token" '${{ steps.set-outputs.outputs.token }}' "$(output_ref token)"
check "token-expires-at" '${{ steps.set-outputs.outputs.token-expires-at }}' "$(output_ref token-expires-at)"

OIDC_PORT=18800
start_mock "$OIDC_PORT" --oidc

# The mock STS answers with access_token "sts-access-token".

# --- 1: authenticated ----------------------------------------------------------
start_case "1: authenticated run sets the token output to the STS access token"
STS_PORT=18801
start_mock "$STS_PORT" --codes 200
run_steps "mock-bot" "http://127.0.0.1:${STS_PORT}"
check "auth exit" 0 "$AUTH_EXIT"
check "set-outputs exit" 0 "$OUTPUTS_EXIT"
check "token output" "sts-access-token" "$(output_value "$WORK/action_output" token)"
check "token output written once" 1 "$(grep -c '^token=' "$WORK/action_output")"
check "token-expires-at still set" 1 "$(grep -c '^token-expires-at=' "$WORK/action_output")"
check ".netrc password matches the token output" \
  "machine golang.flatt.tech login _ password sts-access-token" "$(cat "$WORK/home/.netrc")"
# The runner prints the set-outputs step's env: in the log before that step
# runs, so the mask that hides ACCESS_TOKEN there is the one the auth step
# registers.
check "token masked by auth" 1 "$(grep -c '^::add-mask::sts-access-token$' "$WORK/out.log")"
check "token masked by set-outputs" 1 "$(grep -c '^::add-mask::sts-access-token$' "$WORK/outputs.log")"

# --- 2: anonymous --------------------------------------------------------------
start_case "2: anonymous mode leaves the token output unset"
run_steps "" "http://127.0.0.1:${STS_PORT}"
check "auth exit" 0 "$AUTH_EXIT"
check "set-outputs exit" 0 "$OUTPUTS_EXIT"
check "token output lines" 0 "$(grep -c '^token=' "$WORK/action_output")"
check "no token-expires-at" 0 "$(grep -c '^token-expires-at=' "$WORK/action_output")"

# --- 3: rejected by STS --------------------------------------------------------
start_case "3: a rejected exchange writes no token output"
STS_PORT=18802
start_mock "$STS_PORT" --codes 403
run_steps "mock-bot" "http://127.0.0.1:${STS_PORT}"
check "auth exit" 1 "$AUTH_EXIT"
check "auth step token output lines" 0 "$(grep -c '^token=' "$WORK/auth_output")"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all output tests passed"
else
  echo "${FAILURES} check(s) failed"
fi
exit $((FAILURES > 0))
