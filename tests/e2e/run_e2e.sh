#!/usr/bin/env bash
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$E2E_DIR/../.." && pwd)"

MODE=""
TIER_ARG=""
VERBOSE=0

usage() {
  cat <<'EOF'
Usage: run_e2e.sh [OPTIONS]

Modes (mutually exclusive, one required):
  --tier <1|2|3|4|all>   Build harnesses, start mock server, and run specified tier(s)
  --self-test            Validate E2E infrastructure, build hls_probe, and test mock server
  --list                 List available tier test cases

Options:
  --verbose, -v          Verbose output
  --help, -h             Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --tier requires an argument (1|2|3|4|all)" >&2
        exit 2
      fi
      if [[ -n "$MODE" && "$MODE" != "tier" ]]; then
        echo "ERROR: conflicting mode flags" >&2
        exit 2
      fi
      MODE="tier"
      TIER_ARG="$2"
      shift 2
      ;;
    --self-test)
      if [[ -n "$MODE" && "$MODE" != "self-test" ]]; then
        echo "ERROR: conflicting mode flags" >&2
        exit 2
      fi
      MODE="self-test"
      shift
      ;;
    --list)
      if [[ -n "$MODE" && "$MODE" != "list" ]]; then
        echo "ERROR: conflicting mode flags" >&2
        exit 2
      fi
      MODE="list"
      shift
      ;;
    --verbose|-v)
      VERBOSE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "ERROR: One of --tier, --self-test, or --list is required." >&2
  usage >&2
  exit 2
fi

export E2E_PROJECT_ROOT="$REPO_ROOT"
export E2E_REPO_ROOT="$REPO_ROOT"
export E2E_DIR="$E2E_DIR"
export E2E_APP_PATH="$REPO_ROOT/build/VKMac.app"
export E2E_HARNESS_BIN="$E2E_DIR/harness/bin/vk_e2e_harness"
export E2E_HLS_PROBE_BIN="$E2E_DIR/harness/bin/hls_probe"
export E2E_VERBOSE="$VERBOSE"
export PYTHONPATH="$E2E_DIR/lib${PYTHONPATH:+:$PYTHONPATH}"

if [[ "$MODE" == "list" ]]; then
  echo "E2E Test Suite ($E2E_DIR)"
  for t in 1 2 3 4; do
    tier_script="$E2E_DIR/tiers/tier${t}/run_tier.py"
    if [[ -f "$tier_script" ]]; then
      python3 "$tier_script" --list
    else
      echo "Tier ${t}: not yet implemented"
    fi
  done
  exit 0
fi

if [[ "$MODE" == "self-test" ]]; then
  "$E2E_DIR/harness/build_harness.sh" --if-available
  SELF_TEST_ARGS=()
  if [[ "$VERBOSE" -eq 1 ]]; then
    SELF_TEST_ARGS+=("--verbose")
  fi
  exec python3 "$E2E_DIR/self_test.py" ${SELF_TEST_ARGS[@]+"${SELF_TEST_ARGS[@]}"}
fi

# --tier mode
case "$TIER_ARG" in
  1|2|3|4)
    TIERS=("$TIER_ARG")
    ;;
  all)
    TIERS=(1 2 3 4)
    ;;
  *)
    echo "ERROR: Invalid --tier value '$TIER_ARG'. Expected 1, 2, 3, 4, or all." >&2
    exit 2
    ;;
esac

E2E_RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vkmac_e2e_run.XXXXXX")"
export E2E_RUN_TMP
MOCK_PID=""

CLEANUP_DONE=0

cleanup() {
  local exit_rc=$?
  if [[ "$CLEANUP_DONE" -eq 1 ]]; then
    return "$exit_rc"
  fi
  CLEANUP_DONE=1
  trap - INT TERM

  if [[ -n "$MOCK_PID" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill -TERM "$MOCK_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      if ! kill -0 "$MOCK_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$MOCK_PID" 2>/dev/null; then
      kill -KILL "$MOCK_PID" 2>/dev/null || true
    fi
    wait "$MOCK_PID" 2>/dev/null || true
  fi

  # Terminate any stray VKMac processes launched under E2E_RUN_TMP
  if [[ -n "${E2E_RUN_TMP:-}" ]]; then
    pkill -TERM -f "$E2E_RUN_TMP" 2>/dev/null || true
    if [[ "${E2E_KEEP_TMP:-0}" != "1" ]]; then
      rm -rf "$E2E_RUN_TMP"
    fi
  fi
  return "$exit_rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 1. Build harnesses strictly (both hls_probe and vk_e2e_harness must compile)
"$E2E_DIR/harness/build_harness.sh"

# 2. Verify tier runners exist before running
for t in "${TIERS[@]}"; do
  tier_script="$E2E_DIR/tiers/tier${t}/run_tier.py"
  if [[ ! -f "$tier_script" ]]; then
    echo "ERROR: Tier ${t} runner not found: $tier_script" >&2
    exit 2
  fi
done

# 3. Start local mock server on 127.0.0.1:0
READY_FILE="$E2E_RUN_TMP/mock_ready.txt"
MOCK_LOG="$E2E_RUN_TMP/mock_server.log"
MOCK_FLAGS=("--host" "127.0.0.1" "--port" "0")
if [[ "$VERBOSE" -eq 0 ]]; then
  MOCK_FLAGS+=("--quiet")
fi

python3 "$E2E_DIR/mock_server.py" "${MOCK_FLAGS[@]}" >"$READY_FILE" 2>"$MOCK_LOG" &
MOCK_PID=$!

READY_LINE=""
for _ in $(seq 1 100); do
  if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    echo "ERROR: mock_server.py exited prematurely. Log:" >&2
    cat "$MOCK_LOG" >&2 || true
    exit 1
  fi
  if [[ -s "$READY_FILE" ]]; then
    READY_LINE="$(head -n 1 "$READY_FILE" || true)"
    if [[ -n "$READY_LINE" ]]; then
      break
    fi
  fi
  sleep 0.1
done

if [[ -z "$READY_LINE" ]]; then
  echo "ERROR: Timed out waiting for mock_server.py readiness banner." >&2
  cat "$MOCK_LOG" >&2 || true
  exit 1
fi

read -r MOCK_PORT MOCK_BASE_URL < <(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["status"] == "ready"
print(d["port"], d["base_url"])
' "$READY_LINE")

export E2E_MOCK_PORT="$MOCK_PORT"
export E2E_MOCK_BASE_URL="$MOCK_BASE_URL"
export E2E_MOCK_URL="$MOCK_BASE_URL"
export VK_API_BASE_URL="${MOCK_BASE_URL}/method/"
export VK_OAUTH_TOKEN_URL="${MOCK_BASE_URL}/token"
export VK_OAUTH_AUTHORIZE_URL="${MOCK_BASE_URL}/authorize"

# Verify health endpoint
python3 -c '
import sys, urllib.request
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(sys.argv[1] + "/__admin/health", timeout=5) as r:
    assert r.status == 200
' "$MOCK_BASE_URL"

if [[ "$VERBOSE" -eq 1 ]]; then
  echo "[run_e2e] Mock server ready at $MOCK_BASE_URL (pid=$MOCK_PID)"
fi

# 4. Run requested tiers
OVERALL_RC=0
TIER_ARGS=()
if [[ "$VERBOSE" -eq 1 ]]; then
  TIER_ARGS+=("--verbose")
fi

for t in "${TIERS[@]}"; do
  tier_script="$E2E_DIR/tiers/tier${t}/run_tier.py"
  echo "=== Running Tier ${t} ==="
  if ! python3 "$tier_script" ${TIER_ARGS[@]+"${TIER_ARGS[@]}"}; then
    OVERALL_RC=1
  fi
done

exit "$OVERALL_RC"
