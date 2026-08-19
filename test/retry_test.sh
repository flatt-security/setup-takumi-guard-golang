#!/usr/bin/env bash
#
# Tests for curl_with_retry in action.yml.
#
# The auth step's shell body is extracted from action.yml and run directly, so
# the retry warnings (which go to stderr) can be counted. Judging is by attempt
# count, never by elapsed time: the pre-change implementation also spends tens
# of seconds failing, so wall-clock cannot tell the two apart.
#
# Both the OIDC endpoint and the STS endpoint are pointed at local mocks, so no
# test here needs `id-token: write` or network access.
set -u -o pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ACTION_YML="${ACTION_YML:-$REPO_ROOT/action.yml}"
WORK=$(mktemp -d)
SCRIPT="$WORK/auth.sh"
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

python3 "$REPO_ROOT/test/extract_script.py" "$ACTION_YML" > "$SCRIPT"

FAILURES=0
CASE=""

start_case() {
  CASE=$1
  echo
  echo "=== $CASE ==="
}

check() { # <what> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok   $1: $3"
  else
    echo "  FAIL $1: expected '$2', got '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

check_contains() { # <what> <needle> <file>
  if grep -qF -- "$2" "$3"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: '$2' not found in output"
    sed 's/^/       | /' "$3"
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
  echo "  FAIL mock on port ${port} did not start"
  FAILURES=$((FAILURES + 1))
}

# run_auth <sts-url> -> sets AUTH_EXIT, writes $WORK/out.log, $WORK/github_env
run_auth() {
  rm -f "$WORK/out.log" "$WORK/github_env" "$WORK/github_output"
  touch "$WORK/github_env" "$WORK/github_output"
  rm -rf "$WORK/home"
  mkdir -p "$WORK/home"
  AUTH_EXIT=0
  env -i \
    PATH="$PATH" \
    HOME="$WORK/home" \
    BOT_ID="mock-bot" \
    STS_URL="$1" \
    AUDIENCE_INPUT="" \
    REGISTRY_URL="https://golang.flatt.tech" \
    EXPIRES_IN="1800" \
    SET_GOPROXY="true" \
    ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:${OIDC_PORT}/token" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="mock-request-token" \
    GITHUB_ENV="$WORK/github_env" \
    GITHUB_OUTPUT="$WORK/github_output" \
    bash -e -o pipefail "$SCRIPT" > "$WORK/out.log" 2>&1 || AUTH_EXIT=$?
}

warnings() { grep -c '::warning::attempt' "$WORK/out.log" || true; }

OIDC_PORT=18790
start_mock "$OIDC_PORT" --oidc

# --- 1: STS unreachable ------------------------------------------------------
# 192.0.2.0/24 is TEST-NET-1 (RFC 5737): guaranteed unrouteable, so curl fails
# with a connect timeout on every attempt.
start_case "1: unreachable STS retries 5 times and then fails"
run_auth "https://192.0.2.1"
check "exit" 1 "$AUTH_EXIT"
check "warnings" 4 "$(warnings)"
for n in 1 2 3 4; do
  check_contains "attempt ${n}/5 warning present" "attempt ${n}/5 failed" "$WORK/out.log"
done
check_contains "existing failure message unchanged" "STS exchange failed: curl exit" "$WORK/out.log"
check "GOPROXY not written on failure" "" "$(cat "$WORK/github_env")"

# --- 2: STS 400 --------------------------------------------------------------
start_case "2: HTTP 400 is not retried"
STS_PORT=18791
start_mock "$STS_PORT" --codes 400,200,200,200,200
run_auth "http://127.0.0.1:${STS_PORT}"
check "exit" 1 "$AUTH_EXIT"
check "warnings" 0 "$(warnings)"
check_contains "existing failure message unchanged" \
  "STS returned HTTP 400 without an access_token" "$WORK/out.log"
check "GOPROXY not written on failure" "" "$(cat "$WORK/github_env")"

# --- 3: STS 503, 503, 200 ----------------------------------------------------
start_case "3: 5xx is retried and the third attempt succeeds"
STS_PORT=18792
start_mock "$STS_PORT" --codes 503,503,200
run_auth "http://127.0.0.1:${STS_PORT}"
check "exit" 0 "$AUTH_EXIT"
check "warnings" 2 "$(warnings)"
check_contains "authenticated notice" "Authenticated as bot mock-bot" "$WORK/out.log"
check "GOPROXY written" "GOPROXY=https://golang.flatt.tech" "$(cat "$WORK/github_env")"
check_contains ".netrc written for the registry host" \
  "machine golang.flatt.tech login _ password sts-access-token" "$WORK/home/.netrc"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all retry tests passed"
else
  echo "${FAILURES} check(s) failed"
fi
exit $((FAILURES > 0))
