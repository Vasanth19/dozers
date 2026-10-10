#!/usr/bin/env bash
# tests/dev-lane-missing-worktree-test.sh — regression test for GSAI-88.
#
# resolve_test_cmd (crew.sh, GSAI-27's gate) used to treat "the dir doesn't exist" the
# same as "the dir exists but has no test command" — `[[ -f "$d/package.json" ]]` is
# just `false` when `$d` itself is missing, so a vanished worktree (crash-reaper race,
# manual cleanup, disk hiccup) fell through to the GENUINELY-no-test-command branch:
# wrong diagnosis (the repo almost certainly HAS tests) and wrong remedy (the message
# suggests TEST_GATE=off / no_test_gate / a marker file / adding a test script — every
# one of which would blind the gate for a healthy repo instead of fixing the engine
# fault). Worse, if the repo already carries a legitimate test-gate waiver, a missing
# worktree was silently WAIVED too, so the crew "merged" having run nothing, for a
# reason the waiver was never meant to cover.
#
# Why this drives resolve_test_cmd DIRECTLY instead of the full crew (unlike
# dev-lane-test-gate-test.sh's A/B/C): a missing $WT in a real run is only ever
# produced by a race (the worktree vanishing mid-crew), and EVERY earlier checkpoint in
# crew.sh (wt_unsaved's resume check, build_backstop right after the build pass) is
# itself already fail-closed on a `git status` failure — so simulating the vanish via
# a model-pass stub trips one of those pre-existing, unrelated hard-stops before
# resolve_test_cmd is ever reached, and would be testing the wrong code. Extracting the
# REAL resolve_test_cmd/detect_test_cmd/test_gate_waiver source straight out of
# crew.sh and driving it directly gives a deterministic, exact test of the new guard
# itself — the same technique dev-lane-test-gate-test.sh already falls back to (its
# green-gate assertion) for exactly this reason: an end-to-end race is impractical to
# simulate reliably, a source-accurate direct call is not.
#
# Run:  bash tests/dev-lane-missing-worktree-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# Extract the REAL function bodies (TEST_CMD="" through resolve_test_cmd's closing
# brace — covers detect_test_cmd, test_gate_waiver, hygiene_gate_waiver (unused here,
# harmless) and resolve_test_cmd itself) and wrap them with minimal stand-ins for the
# two things crew.sh normally provides: `fail` (here: print + exit 1, no .artifacts
# side effect) and `ecosystem_flag` (here: no ecosystem.yaml entry, ever).
START_LN="$(grep -n '^TEST_CMD="" ' "$CREW" | head -1 | cut -d: -f1)"
END_LN="$(awk '/^resolve_test_cmd\(\) \{/{f=1} f&&/^}$/{print NR; exit}' "$CREW")"
[[ -n "$START_LN" && -n "$END_LN" && "$END_LN" -gt "$START_LN" ]] \
  || { echo "  ✗ could not locate resolve_test_cmd in $CREW to extract" >&2; exit 1; }

HARNESS="$TMP/harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo 'fail() { printf "%s\n" "$*"; exit 1; }'
  echo 'ecosystem_flag() { echo ""; }'
  sed -n "${START_LN},${END_LN}p" "$CREW"
} > "$HARNESS"

# call <dir> <stage> <log> [env assignments...]  — runs resolve_test_cmd in its own
# process (fail() really exits here, same as in the crew) and captures stdout+stderr.
call() {
  local d="$1" stage="$2" log="$3"; shift 3
  env "$@" WORKDIR="$TMP" bash -c '
    source "$1"
    rc=0; resolve_test_cmd "$2" "$3" || rc=$?
    echo "RESOLVED TEST_CMD=[$TEST_CMD] NO_TEST_MSG=[$NO_TEST_MSG]"
    exit "$rc"
  ' _ "$HARNESS" "$d" "$stage" >"$log" 2>&1
}

# ── 1. Missing dir — must be diagnosed as an ENGINE fault, not no-test-command ────
MISSING="$TMP/does-not-exist"
LOG="$TMP/missing.log"; rc=0; call "$MISSING" "task worktree" "$LOG" || rc=$?
[[ $rc -ne 0 ]] && ok "missing dir: resolve_test_cmd fails (not silently proceeding)" \
  || { no "missing dir: resolve_test_cmd returned 0"; sed 's/^/    | /' "$LOG" >&2; }
if grep -qF "$MISSING" "$LOG" && grep -q "ENGINE fault" "$LOG" && grep -q "does not exist" "$LOG"; then
  ok "missing dir: message names the path and diagnoses it as an engine fault"
else
  no "missing dir: message does not clearly diagnose the missing worktree"; sed 's/^/    | /' "$LOG" >&2
fi
if grep -qE 'no_test_gate|TEST_GATE=off|\.dozers-no-test-gate|add a' "$LOG"; then
  no "missing dir: message still suggests a no-test-command remedy"; sed 's/^/    | /' "$LOG" >&2
else
  ok "missing dir: message does NOT suggest the wrong (no-test-command) remedy"
fi

# ── 2. Missing dir, TEST_GATE=off exported — must STILL fail the same way ────────
# The central regression this issue exists to prevent: today TEST_GATE=off short-
# circuits test_gate_waiver and would silently waive a VANISHED WORKTREE, not a
# missing test command — a legitimate waiver applied for a reason it was never meant
# to cover.
LOG="$TMP/missing-waived.log"; rc=0; call "$MISSING" "task worktree" "$LOG" TEST_GATE=off || rc=$?
[[ $rc -ne 0 ]] && ok "missing dir + TEST_GATE=off: still fails — the waiver never reaches a broken engine" \
  || { no "missing dir + TEST_GATE=off: resolve_test_cmd returned 0 — a vanished worktree got waived"; sed 's/^/    | /' "$LOG" >&2; }
grep -q "gate waived" "$LOG" \
  && { no "missing dir + TEST_GATE=off: 'gate waived' logged — test_gate_waiver was consulted for a broken engine"; sed 's/^/    | /' "$LOG" >&2; } \
  || ok "missing dir + TEST_GATE=off: test_gate_waiver was never reached"

# ── 3. Dir exists but is not a git worktree (e.g. orphaned/empty) — same diagnosis ─
BROKEN="$TMP/broken"; mkdir -p "$BROKEN"   # plain dir, no .git at all
LOG="$TMP/broken.log"; rc=0; call "$BROKEN" "green-gate" "$LOG" || rc=$?
[[ $rc -ne 0 ]] && ok "broken dir: resolve_test_cmd fails" \
  || { no "broken dir: resolve_test_cmd returned 0"; sed 's/^/    | /' "$LOG" >&2; }
grep -q "ENGINE fault" "$LOG" && grep -q "not a readable git worktree" "$LOG" \
  && ok "broken dir: message distinguishes 'present but not a git worktree' from 'absent'" \
  || { no "broken dir: message does not name the broken-worktree case"; sed 's/^/    | /' "$LOG" >&2; }

# ── 4. Sanity: a genuinely present, valid worktree with a real test command ───────
GOOD="$TMP/good"; mkdir -p "$GOOD"; ( cd "$GOOD" && git init -q . \
  && printf '{"name":"p","scripts":{"test":"exit 0"}}\n' > package.json )
LOG="$TMP/good.log"; rc=0; call "$GOOD" "preflight" "$LOG" || rc=$?
[[ $rc -eq 0 ]] && ok "present worktree with a test script: resolve_test_cmd succeeds" \
  || { no "present worktree with a test script: resolve_test_cmd failed"; sed 's/^/    | /' "$LOG" >&2; }
grep -q "RESOLVED TEST_CMD=\[npm test\]" "$LOG" \
  && ok "present worktree: TEST_CMD set to the detected command" \
  || no "present worktree: TEST_CMD not set as expected"

# ── 5. Sanity: present, valid worktree, genuinely no test command, no waiver ──────
# Unchanged existing behavior — the new guard must be a no-op once the dir is real.
NOTEST="$TMP/notest"; mkdir -p "$NOTEST"; ( cd "$NOTEST" && git init -q . )
LOG="$TMP/notest.log"; rc=0; call "$NOTEST" "preflight" "$LOG" || rc=$?
[[ $rc -ne 0 ]] && grep -q "no test command detected" "$LOG" \
  && ok "present worktree, no test command, unwaived: still blocks exactly as before" \
  || { no "present worktree, no test command: behavior changed"; sed 's/^/    | /' "$LOG" >&2; }

# ── 6. Sanity: present, valid worktree, no test command, WAIVED ───────────────────
LOG="$TMP/notest-waived.log"; rc=0; call "$NOTEST" "preflight" "$LOG" TEST_GATE=off || rc=$?
[[ $rc -eq 0 ]] && grep -q "gate waived" "$LOG" \
  && ok "present worktree, no test command, TEST_GATE=off: still waived exactly as before" \
  || { no "present worktree, no test command, TEST_GATE=off: waiver broke"; sed 's/^/    | /' "$LOG" >&2; }

# ── 7. Real-crew sanity: the existing test-gate suite (A/B/C) is untouched ────────
if bash "$ROOT/tests/dev-lane-test-gate-test.sh" >"$TMP/f.log" 2>&1; then
  ok "dev-lane-test-gate-test.sh (A/B/C) still passes unmodified"
else
  no "dev-lane-test-gate-test.sh regressed"; sed 's/^/    | /' "$TMP/f.log" >&2
fi

if [[ $fail == 0 ]]; then echo "dev-lane-missing-worktree-test: PASS"; else echo "dev-lane-missing-worktree-test: FAIL" >&2; exit 1; fi
