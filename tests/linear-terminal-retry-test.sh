#!/usr/bin/env bash
# tests/linear-terminal-retry-test.sh — GSAI-213: the terminal Linear writes retry, and a
# write that still fails is reported as a failure, never as success.
#
# BRD-96 (2026-09-28) merged and went green, then the terminal merged() write hit a read
# timeout and a 503. Nothing retried it, so the issue sat at dozer:in-progress. tasks/
# linear.sh now wraps merged/review/block in _linear_write_retry: N attempts total, a
# fixed backoff, read from org/config.yaml. claim and requeue are deliberately NOT wrapped.
#
# No network: `python3` is overridden by a shell function (a function beats PATH lookup),
# so the REAL _linear_write_retry runs against a scripted sequence of failures.
#
#   1. a write that fails twice (503, then timeout) and then succeeds lands on attempt 3,
#      with rc 0 — the BRD-96 shape recovers
#   2. a write that always fails returns non-zero after EXACTLY LINEAR_WRITE_RETRIES attempts
#   3. a write that succeeds first time is called once
#   4. claim and requeue are NOT retried (one attempt, the failure surfaces at once)
#
# Run:  bash tests/linear-terminal-retry-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export LINEAR_API_KEY=test-not-used
export LINEAR_WRITE_BACKOFF_S=0
export LINEAR_WRITE_RETRIES=3
# shellcheck source=../tasks/linear.sh
source "$ROOT/tasks/linear.sh"

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# Scripted python3: each call pops the next outcome from SCRIPT (a space-separated list of
# ok | 503 | timeout). Calls are counted in CALLS. Logs the verb it was asked to run.
SCRIPT=""; CALLS=0; LASTVERB=""
python3() {
  CALLS=$((CALLS+1))
  LASTVERB="${3:-}"   # argv: $1 = the script path, $2 = the verb, $3 = the issue id
  local next="${SCRIPT%% *}"
  if [[ "$SCRIPT" == *" "* ]]; then SCRIPT="${SCRIPT#* }"; else SCRIPT=""; fi
  case "$next" in
    ok)      return 0 ;;
    503)     echo "HTTP 503 Service Unavailable" >&2; return 1 ;;
    timeout) echo "read timed out" >&2; return 1 ;;
    *)       echo "scripted python3: no outcome left" >&2; return 1 ;;
  esac
}
reset() { SCRIPT="$1"; CALLS=0; LASTVERB=""; }

# 1. BRD-96 shape: 503, then timeout, then success -> attempt 3 lands
reset "503 timeout ok"
rc=0; task_merged BRD-96 >/dev/null 2>&1 || rc=$?
[[ $rc == 0 ]] && ok "merged write recovers after 503 + timeout (rc 0)" || no "merged write did not recover (rc=$rc)"
[[ $CALLS == 3 ]] && ok "merged write took exactly 3 attempts" || no "merged write took $CALLS attempts, expected 3"
[[ $LASTVERB == BRD-96 ]] && ok "the retry re-sent the same issue id" || no "retry sent '$LASTVERB'"

# 2. always failing: non-zero after exactly LINEAR_WRITE_RETRIES attempts
reset "503 timeout 503 timeout 503 timeout"
rc=0; task_merged BRD-97 >/dev/null 2>&1 || rc=$?
[[ $rc != 0 ]] && ok "a merged write that never lands returns non-zero (the caller must not report success)" \
  || no "a merged write that never lands returned 0 — the stranding bug"
[[ $CALLS == 3 ]] && ok "stopped after exactly 3 attempts (LINEAR_WRITE_RETRIES=3)" || no "made $CALLS attempts, expected 3"

# the same bound holds for review and block, the other two terminal writes
reset "503 503 503"
rc=0; task_review BRD-98 >/dev/null 2>&1 || rc=$?
[[ $rc != 0 && $CALLS == 3 ]] && ok "review(): always-failing write is bounded at 3 attempts" \
  || no "review(): rc=$rc calls=$CALLS, expected non-zero after 3"
reset "503 503 503"
rc=0; task_block BRD-99 >/dev/null 2>&1 || rc=$?
[[ $rc != 0 && $CALLS == 3 ]] && ok "block(): always-failing write is bounded at 3 attempts" \
  || no "block(): rc=$rc calls=$CALLS, expected non-zero after 3"

# 3. first-time success: one call, no retry
reset "ok"
rc=0; task_merged BRD-100 >/dev/null 2>&1 || rc=$?
[[ $rc == 0 && $CALLS == 1 ]] && ok "a write that lands first time is called once" \
  || no "first-time success: rc=$rc calls=$CALLS"

# 4. claim and requeue are NOT wrapped: one attempt, failure surfaces immediately
reset "503 ok"
rc=0; task_requeue BRD-101 >/dev/null 2>&1 || rc=$?
[[ $rc != 0 && $CALLS == 1 ]] && ok "requeue is not retried (one attempt, failure surfaces at once)" \
  || no "requeue was retried: rc=$rc calls=$CALLS"

if (( fail == 0 )); then echo "linear-terminal-retry: PASS"; else echo "linear-terminal-retry: FAIL" >&2; exit 1; fi
