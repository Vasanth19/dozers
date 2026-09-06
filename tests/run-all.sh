#!/usr/bin/env bash
# tests/run-all.sh — the dozers repo's OWN test command (GSAI-30).
#
# GSAI-27 made "no detectable test command" block a merge. This repo had none of the
# things the ladder looks for (no `test` script, no `test:` target), so the very
# harness that enforces the gate could not clear it: every dozers-repo task would
# land on dozer:blocked. This runner + the Makefile `test` target are that command.
#
# It runs every tests/*-test.sh (or just the ones named as arguments) in a SCRUBBED
# environment and exits non-zero if any of them fails.
#
# Why the scrub: these tests drive the real crews, and a crew inherits the engine's
# environment — MODEL_CMD, DOZER_MODEL_PROVIDER/NAME/SOURCE, DOZER_PERSONA, the
# ANTHROPIC_* routing block, WORKDIR/REPO_ROOT, the lane knobs. Run from a plain
# shell the suite is green; run from inside a Dozer crew (exactly where the test gate
# runs it) those inherited vars leak into the crews under test and assertions fail on
# the environment rather than on the code. A test command that only passes outside the
# harness is not a gate. So: unset everything the engine exports before each test.
#
# Run:  bash tests/run-all.sh [test.sh ...]     (exits non-zero on any failure)
#       TEST_TIMEOUT=300 bash tests/run-all.sh  (per-test watchdog, default 240s)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT="${TEST_TIMEOUT:-240}"

# ── the scrub list: every name the engine/crews/model router export, plus the lane
# knobs and the backend credentials (a test must never reach the real Linear API).
SCRUB=()
for v in $(compgen -e); do
  case "$v" in
    DOZER_*|ANTHROPIC_*|MODEL_CMD|WORKDIR|REPO_ROOT|WORKTREE_ROOT|INTEGRATION_BRANCH \
    |BRANCH_PREFIX|PUSH|DRY_RUN|TEST_GATE|MIGRATION_GATE|DEPS_INSTALL|SCHEMA_GLOBS \
    |MIGRATION_GLOBS|LINEAR_API_KEY|LINEAR_TEAM|BACKEND|GH_REPO|GH_TOKEN|OLLAMA_API_KEY)
      SCRUB+=( -u "$v" ) ;;
  esac
done

TESTS=( "$@" )
if (( ${#TESTS[@]} == 0 )); then
  shopt -s nullglob
  TESTS=( "$ROOT"/tests/*-test.sh )
  shopt -u nullglob
fi
(( ${#TESTS[@]} )) || { echo "run-all: no tests found under $ROOT/tests" >&2; exit 1; }

LOGS="$(mktemp -d)"; trap 'rm -rf "$LOGS"' EXIT
pass=0; failed=()

for t in "${TESTS[@]}"; do
  name="$(basename "$t")"
  log="$LOGS/$name.log"; mark="$LOGS/$name.timeout"
  start=$SECONDS
  env "${SCRUB[@]}" bash "$t" >"$log" 2>&1 &
  pid=$!
  ( sleep "$TIMEOUT"; kill -0 "$pid" 2>/dev/null && { : > "$mark"; kill -9 "$pid" 2>/dev/null; } ) &
  watchdog=$!
  wait "$pid" 2>/dev/null; rc=$?   # 2>/dev/null: hide the shell's "Killed: 9" job notice on a timeout
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  took=$(( SECONDS - start ))
  if [[ -e "$mark" ]]; then
    printf '  ✗ %-34s TIMEOUT after %ss\n' "$name" "$TIMEOUT" >&2; failed+=( "$name (timeout)" )
  elif (( rc == 0 )); then
    printf '  ✓ %-34s %ss\n' "$name" "$took"; (( pass++ ))
  else
    printf '  ✗ %-34s exit %s\n' "$name" "$rc" >&2; failed+=( "$name (exit $rc)" )
  fi
  (( rc != 0 )) && sed 's/^/      | /' "$log" >&2
done

echo
if (( ${#failed[@]} == 0 )); then
  echo "run-all: PASS — ${pass}/${#TESTS[@]}"
else
  printf 'run-all: FAIL — %s/%s passed; failures: %s\n' "$pass" "${#TESTS[@]}" "$(IFS=', '; echo "${failed[*]}")" >&2
  exit 1
fi
