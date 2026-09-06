#!/usr/bin/env bash
# tests/dev-lane-test-gate-test.sh — regression test for GSAI-27.
#
# The dev lane used to end its test-detection ladder with
#     else echo "⚠ no test command detected — proceeding"
# and merge anyway. Both gates — the task-worktree run AND the post-merge green-gate
# that is supposed to revert a merge which breaks the integration branch — were
# silently skipped for any repo without a `test` script (cfw-social: five ungated
# merges on 2026-09-05). "Never merges red" is worthless if nothing is ever run.
#
# Three cases, each driving the REAL crew against a throwaway repo:
#   A. no test command anywhere      -> crew FAILS, nothing lands on develop
#   B. same repo + per-repo opt-out  -> crew succeeds, merge lands (waiver honoured)
#   C. test command on develop but the BRANCH removes it -> the task worktree can't
#      see it either, so it blocks BEFORE merging and develop is untouched — the
#      green-gate's own guard is asserted directly on the crew source.
#
# Run:  bash tests/dev-lane-test-gate-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -f "$ROOT"/.artifacts/dev/TEST-TG* 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# A throwaway repo on `main` + an unmerged `develop`, with whatever package.json the
# caller passes (empty string = no package.json at all).
mkproj() {  # $1 = dir, $2 = package.json body ("" = none)
  local d="$1" pkg="$2"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    [[ -n "$pkg" ]] && printf '%s\n' "$pkg" > package.json
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m init
    git branch develop )
}

# Stub coding agent: one real commit inside the worktree. $EXTRA runs first, so a case
# can have the branch change what the test gate will see.
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
[[ -n "${EXTRA:-}" ]] && eval "$EXTRA"
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOS
chmod +x "$STUB"

run_crew() {  # $1 = proj dir, $2 = task id, $3 = log; extra env comes from the caller
  REPO_ROOT="$TMP" WORKDIR="$1" WORKTREE_ROOT="$TMP/wt-$2" INTEGRATION_BRANCH="develop" \
    MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" \
    bash "$CREW" "$2" "test gate" >"$3" 2>&1
}
dev_head() { git -C "$1" log -1 --format=%s develop 2>/dev/null || true; }

# ── A. no test command at all → must BLOCK, not merge ─────────────────────────
PA="$TMP/no-tests"; mkproj "$PA" '{"name":"p","version":"1.0.0","scripts":{"build":"true"}}'
LOG="$TMP/a.log"; rc=0; run_crew "$PA" "TEST-TG-A" "$LOG" || rc=$?
[[ $rc -ne 0 ]] && ok "A: crew failed instead of merging ungated" \
  || { no "A: crew exited 0 — an ungated merge still goes through"; sed 's/^/    | /' "$LOG" >&2; }
[[ "$(dev_head "$PA")" == "init" ]] && ok "A: develop untouched" \
  || no "A: develop advanced to '$(dev_head "$PA")' — the merge landed anyway"
grep -q "no test command detected" "$TMP/.artifacts/dev/TEST-TG-A.fail" 2>/dev/null \
  && ok "A: reason recorded for the Linear block comment" \
  || no "A: no reason in .artifacts/dev/TEST-TG-A.fail"

# ── B. same repo, per-repo opt-out marker → merge is allowed ───────────────────
PB="$TMP/opted-out"; mkproj "$PB" '{"name":"p","version":"1.0.0","scripts":{"build":"true"}}'
: > "$PB/.dozers-no-test-gate"
LOG="$TMP/b.log"; rc=0; run_crew "$PB" "TEST-TG-B" "$LOG" || rc=$?
[[ $rc -eq 0 ]] && ok "B: opted-out repo still merges" \
  || { no "B: crew exited $rc despite the .dozers-no-test-gate marker"; sed 's/^/    | /' "$LOG" >&2; }
[[ "$(dev_head "$PB")" == merge*TEST-TG-B* ]] && ok "B: merge landed on develop" \
  || no "B: develop HEAD is not the expected merge: '$(dev_head "$PB")'"
grep -q "gate waived" "$LOG" && ok "B: waiver logged, not silent" || no "B: waiver not logged"

# ── C. develop has a test command but the branch deletes it → must BLOCK ───────
PC="$TMP/removes-tests"; mkproj "$PC" '{"name":"p","version":"1.0.0","scripts":{"test":"exit 0"}}'
LOG="$TMP/c.log"; rc=0
EXTRA='printf "{\"name\":\"p\",\"version\":\"1.0.0\"}\n" > package.json' \
  run_crew "$PC" "TEST-TG-C" "$LOG" || rc=$?
[[ $rc -ne 0 ]] && ok "C: a branch that removes the test command blocks" \
  || { no "C: crew exited 0 — the branch removed the only gate and still merged"; sed 's/^/    | /' "$LOG" >&2; }
[[ "$(dev_head "$PC")" == "init" ]] && ok "C: develop untouched" \
  || no "C: develop advanced to '$(dev_head "$PC")'"

# The green-gate must carry the same guard, so a merge that leaves the integration
# branch with nothing to run is reverted rather than declared green (issue: "the same
# hole is closed for the green-gate path, not just the task-worktree path").
awk '/^GATE_WAIVED=0/,/^fi$/' "$CREW" | grep -q 'resolve_test_cmd "\$MW" "green-gate"' \
  && awk '/^GATE_WAIVED=0/,/^fi$/' "$CREW" | grep -q 'reset --hard "\$PREMERGE"' \
  && ok "green-gate resolves a test command and reverts when it can't" \
  || no "green-gate still declares success without running anything"

if [[ $fail == 0 ]]; then echo "dev-lane-test-gate-test: PASS"; else echo "dev-lane-test-gate-test: FAIL" >&2; exit 1; fi
