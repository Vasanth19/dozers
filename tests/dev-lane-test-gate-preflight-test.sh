#!/usr/bin/env bash
# tests/dev-lane-test-gate-preflight-test.sh — regression test for GSAI-32.
#
# GSAI-27 made "no detectable test command" block the merge, but it checked only AFTER
# the coding agent had run. Ordering was the whole bug: the verdict never depended on
# the agent — it is readable from package.json/Makefile in the checkout — yet every
# ungatable repo paid for a full model run (the most expensive step in the lane) to be
# told the merge could not be gated at all. The gate now runs as a PREFLIGHT first.
#
# The assertion that matters is NOT "it blocked" (GSAI-27's test already proves that) —
# it is "it blocked WITHOUT SPENDING THE MODEL". So the stub agent here drops a marker
# file outside the worktree; if that marker exists, the model ran and the fix is absent.
#
# Four cases, each driving the REAL crew against a throwaway repo:
#   A. no test command          -> blocks, and the coding agent was NEVER invoked
#   B. per-repo opt-out marker  -> preflight waives, agent runs, merge lands
#   C. TEST_GATE=bootstrap, agent adds the test command -> agent runs, merge lands
#      (the escape hatch for the task whose JOB is to add tests — GSAI-30 was one)
#   D. TEST_GATE=bootstrap, agent adds NOTHING -> agent runs but the merge still
#      blocks; bootstrap skips the preflight only, it is not TEST_GATE=off
#
# Run:  bash tests/dev-lane-test-gate-preflight-test.sh   (exits non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -f "$ROOT"/.artifacts/dev/TEST-PF* 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# A throwaway repo on `main` + an unmerged `develop`, with the caller's package.json.
mkproj() {  # $1 = dir, $2 = package.json body
  local d="$1" pkg="$2"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    printf '%s\n' "$pkg" > package.json
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m init
    git branch develop )
}

# Stub coding agent. It TOUCHES $RAN_MARKER first — that file is the proof of spend.
# $EXTRA lets a case have the agent change what the later gates will see.
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
: > "$RAN_MARKER"
[[ -n "${EXTRA:-}" ]] && eval "$EXTRA"
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOS
chmod +x "$STUB"

# Extra env is passed as trailing KEY=VAL args and applied with `env`, NOT as a
# `VAR=x run_crew ...` prefix: in bash a prefix assignment on a FUNCTION call leaks
# into the shell afterwards, which would silently carry case C's EXTRA into case D.
run_crew() {  # $1 = proj dir, $2 = task id, $3 = log, $4.. = extra KEY=VAL
  local proj="$1" id="$2" log="$3"; shift 3
  env RAN_MARKER="$TMP/$id.agent-ran" \
      REPO_ROOT="$TMP" WORKDIR="$proj" WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
      MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" "$@" \
      bash "$CREW" "$id" "test gate preflight" >"$log" 2>&1
}
dev_head() { git -C "$1" log -1 --format=%s develop 2>/dev/null || true; }
agent_ran() { [[ -e "$TMP/$1.agent-ran" ]]; }

NO_TESTS='{"name":"p","version":"1.0.0","scripts":{"build":"true"}}'
ADD_TESTS='printf "{\"name\":\"p\",\"version\":\"1.0.0\",\"scripts\":{\"test\":\"exit 0\"}}\n" > package.json'

# ── A. ungatable repo → blocks BEFORE the model is ever invoked ────────────────
PA="$TMP/no-tests"; mkproj "$PA" "$NO_TESTS"
LOG="$TMP/a.log"; rc=0; run_crew "$PA" "TEST-PF-A" "$LOG" || rc=$?
[[ $rc -ne 0 ]] && ok "A: crew blocked" || { no "A: crew exited 0 — ungated merge"; dump "$LOG"; }
agent_ran TEST-PF-A \
  && { no "A: the coding agent RAN before the gate — a full model run was burned"; dump "$LOG"; } \
  || ok "A: coding agent never invoked — no model time spent"
grep -q "preflight: no test command detected" "$TMP/.artifacts/dev/TEST-PF-A.fail" 2>/dev/null \
  && ok "A: the block reason names the preflight" \
  || { no "A: preflight reason missing from .artifacts/dev/TEST-PF-A.fail"; dump "$LOG"; }
grep -q "TEST_GATE=bootstrap" "$TMP/.artifacts/dev/TEST-PF-A.fail" 2>/dev/null \
  && ok "A: reason tells the Director how to unblock an add-the-tests task" \
  || no "A: reason does not mention the bootstrap escape hatch"
[[ "$(dev_head "$PA")" == "init" ]] && ok "A: develop untouched" \
  || no "A: develop advanced to '$(dev_head "$PA")'"

# ── B. per-repo opt-out → preflight waives, the run proceeds normally ──────────
PB="$TMP/opted-out"; mkproj "$PB" "$NO_TESTS"; : > "$PB/.dozers-no-test-gate"
LOG="$TMP/b.log"; rc=0; run_crew "$PB" "TEST-PF-B" "$LOG" || rc=$?
[[ $rc -eq 0 ]] && ok "B: opted-out repo still merges" \
  || { no "B: preflight blocked a waived repo (exit $rc)"; dump "$LOG"; }
agent_ran TEST-PF-B && ok "B: coding agent ran" || no "B: preflight skipped the agent on a waived repo"
[[ "$(dev_head "$PB")" == merge*TEST-PF-B* ]] && ok "B: merge landed on develop" \
  || no "B: develop HEAD is not the expected merge: '$(dev_head "$PB")'"

# ── C. bootstrap: the task's job IS to add the test command ───────────────────
PC="$TMP/bootstrap-adds"; mkproj "$PC" "$NO_TESTS"
LOG="$TMP/c.log"; rc=0
run_crew "$PC" "TEST-PF-C" "$LOG" TEST_GATE=bootstrap EXTRA="$ADD_TESTS" || rc=$?
[[ $rc -eq 0 ]] && ok "C: bootstrap let the add-the-tests task run and merge" \
  || { no "C: crew exited $rc — bootstrap cannot bootstrap"; dump "$LOG"; }
agent_ran TEST-PF-C && ok "C: coding agent ran" || no "C: bootstrap still skipped the agent"
[[ "$(dev_head "$PC")" == merge*TEST-PF-C* ]] && ok "C: merge landed on develop" \
  || no "C: develop HEAD is not the expected merge: '$(dev_head "$PC")'"

# ── D. bootstrap is NOT TEST_GATE=off: no tests delivered → still blocked ──────
PD="$TMP/bootstrap-fails"; mkproj "$PD" "$NO_TESTS"
LOG="$TMP/d.log"; rc=0
run_crew "$PD" "TEST-PF-D" "$LOG" TEST_GATE=bootstrap || rc=$?
[[ $rc -ne 0 ]] && ok "D: bootstrap without a delivered test command still blocks" \
  || { no "D: crew exited 0 — bootstrap degraded into a full waiver"; dump "$LOG"; }
agent_ran TEST-PF-D && ok "D: the agent did run (preflight skipped, as asked)" \
  || no "D: bootstrap skipped the preflight but the agent never ran"
[[ "$(dev_head "$PD")" == "init" ]] && ok "D: develop untouched" \
  || no "D: develop advanced to '$(dev_head "$PD")'"

if [[ $fail == 0 ]]; then echo "dev-lane-test-gate-preflight-test: PASS"
else echo "dev-lane-test-gate-preflight-test: FAIL" >&2; exit 1; fi
