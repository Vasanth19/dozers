#!/usr/bin/env bash
# tests/dev-lane-stale-base-test.sh — regression test for GSAI-70.
#
# The Seance resume path in dozers/dev-lane/crew.sh used to resume whenever
# `git log "$base..$BRANCH"` was non-empty — which is ALSO true when the integration
# branch advanced after the worktree was built. A resumed branch then kept building
# on the OLD base, died at the merge step with a generic conflict, and every
# re-greenlight reused the same stale worktree and failed the same way FOREVER
# (LL-19, LL-26, CFW-202; LL-21 dead-ended exactly like this).
#
# The fix checks ancestry before resuming: base still an ancestor → resume as-is;
# base moved → rebase the task branch onto the new base first; a conflicting rebase
# is aborted and the crew FAILS with a "stale base" reason naming the conflicting
# files — never silently discarding the prior commits.
#
# Three scenarios against the real crew, each with a throwaway repo:
#   A) develop moved, NO conflict  → resume rebases, merge lands green
#   B) develop moved, CONFLICT     → stale-base failure naming the file, work kept
#   C) develop unmoved             → resume as-is, no rebase
#
# Run:  bash tests/dev-lane-stale-base-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

WT_ROOT="$TMP/wt"
STUB=""

# ── a scratch repo: main checked out, develop branched, feature.txt seed ────────
new_project() {  # $1 = dir name → echoes repo path
  local p="$TMP/$1"
  mkdir -p "$p"
  ( cd "$p"
    git init -q -b main .
    git config user.email test@dozer; git config user.name dozer-test
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m "init"
    git branch develop                      # integration branch, not checked out
  )
  echo "$p"
}

# ── stub coding agent: attempt 1 commits ($3 decides WHAT) then dies → the crew
# fails with "worktree kept for resume", exactly the Seance precondition. Attempts
# 2+ append to task.txt and exit clean. The attempt counter lives in $2 so a test
# can prove whether the model ran again (it must NOT run after a stale-base fail).
write_stub() {  # $1 = stub path, $2 = counter file, $3 = attempt-1 file op
  cat > "$1" <<EOS2
#!/usr/bin/env bash
n=\$(( \$(cat "$2" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$2"
if [[ \$n -eq 1 ]]; then
  $3
  git add -A && git commit -q -m "task: attempt 1"
  exit 1                                  # die AFTER committing → worktree kept
else
  printf 'task work %s\n' "\$n" >> task.txt
  git add -A && git commit -q -m "task: attempt \$n"
fi
EOS2
  chmod +x "$1"
}

run_crew() {  # $1 = project dir, $2 = issue id, $3 = title, $4 = log path
  local rc=0
  REPO_ROOT="$TMP" WORKDIR="$1" \
    WORKTREE_ROOT="$WT_ROOT" INTEGRATION_BRANCH="develop" \
    MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" TEST_GATE=off \
    bash "$CREW" "$2" "$3" >"$4" 2>&1 || rc=$?
  return "$rc"
}

# ── scenario A: develop moved, NON-conflicting → resume rebases, merge lands ────
echo "── A: base moved, no conflict → rebase + green merge"
PROJA="$(new_project projA)"
write_stub "$TMP/stubA.sh" "$TMP/nA" "printf 'task work 1\n' > task.txt"
STUB="$TMP/stubA.sh"

rc=0; run_crew "$PROJA" TEST-SBA1 "stale-base clean rebase" "$TMP/crewA1.log" || rc=$?
[[ $rc -ne 0 ]] && grep -q "coding agent failed (worktree kept for resume)" "$TMP/crewA1.log" \
  && [[ -d "$WT_ROOT/projA-TEST-SBA1" ]] \
  && ok "attempt 1 died with the worktree kept (Seance precondition)" \
  || { no "attempt 1 did not leave a resumable worktree"; sed 's/^/    | /' "$TMP/crewA1.log" >&2; }

( cd "$PROJA" && git checkout -q develop \
  && printf 'develop moved\n' > advance.txt \
  && git add -A && git commit -q -m "advance develop" )   # develops sits checked-out here now (the cfw-social shape)

rc=0; run_crew "$PROJA" TEST-SBA1 "stale-base clean rebase" "$TMP/crewA2.log" || rc=$?
[[ $rc -eq 0 ]] && ok "resume run exited clean" \
  || { no "resume run exited $rc"; sed 's/^/    | /' "$TMP/crewA2.log" >&2; }

grep -q "base moved — rebased" "$TMP/crewA2.log" \
  && ok "crew logged the rebase ([dev] base moved — rebased <old>..<new>)" \
  || no "no 'base moved — rebased' line in the crew log"
grep -q "has not moved — resuming as-is" "$TMP/crewA2.log" \
  && no "crew claimed the base had NOT moved (wrong path)" \
  || ok "crew did NOT take the unchanged-base path"
[[ "$(cat "$TMP/nA")" == "2" ]] && ok "agent ran again after the rebase (resume continued)" \
  || no "agent did NOT run again after the rebase (counter=$(cat "$TMP/nA" 2>/dev/null))"

DEV_MSGS="$(git -C "$PROJA" log --format=%s develop 2>/dev/null)"
[[ "$(git -C "$PROJA" log -1 --format=%s develop)" == merge*TEST-SBA1* ]] \
  && ok "merge commit landed on develop" \
  || no "develop HEAD is not the merge commit"
grep -q "advance develop" <<< "$DEV_MSGS" && ok "develop's advance commit is still on develop" \
  || no "advance commit missing from develop"
git -C "$PROJA" show develop:task.txt 2>/dev/null | grep -q "task work 2" \
  && ok "both task commits are on develop" \
  || no "task work missing from develop"

# ── scenario B: develop moved, CONFLICT → stale-base failure, nothing discarded ──
echo "── B: base moved, conflict → stale-base failure naming the file"
PROJB="$(new_project projB)"
write_stub "$TMP/stubB.sh" "$TMP/nB" "printf 'TASK SIDE\n' > feature.txt"
STUB="$TMP/stubB.sh"

rc=0; run_crew "$PROJB" TEST-SBB1 "stale-base conflict" "$TMP/crewB1.log" || rc=$?
[[ $rc -ne 0 && -d "$WT_ROOT/projB-TEST-SBB1" ]] \
  && ok "attempt 1 died with the worktree kept" \
  || { no "attempt 1 did not leave a resumable worktree"; sed 's/^/    | /' "$TMP/crewB1.log" >&2; }

( cd "$PROJB" && git checkout -q develop \
  && printf 'DEVELOP SIDE\n' > feature.txt \
  && git add -A && git commit -q -m "advance develop (conflict)" )

rc=0; run_crew "$PROJB" TEST-SBB1 "stale-base conflict" "$TMP/crewB2.log" || rc=$?
[[ $rc -ne 0 ]] && ok "resume run FAILED (it must not merge a conflict)" \
  || { no "resume run unexpectedly succeeded"; sed 's/^/    | /' "$TMP/crewB2.log" >&2; }

grep -q "stale base:" "$TMP/crewB2.log" \
  && ok "failure reason is the explicit stale-base message" \
  || no "no 'stale base:' failure in the crew log"
grep -q "feature.txt" "$TMP/crewB2.log" \
  && ok "conflicting file feature.txt is NAMED in the failure" \
  || no "conflicting file not named"
grep -q "nothing discarded" "$TMP/crewB2.log" \
  && ok "failure states the rebase was aborted and nothing discarded" \
  || no "failure does not state nothing was discarded"
grep -q "merge conflict on dozer/" "$TMP/crewB2.log" \
  && no "still died with the GENERIC merge-step conflict (the bug)" \
  || ok "not the generic merge-step conflict"
FAIL_FILE="$TMP/.artifacts/dev/TEST-SBB1.fail"
[[ -f "$FAIL_FILE" ]] && grep -q "stale base:" "$FAIL_FILE" && grep -q "feature.txt" "$FAIL_FILE" \
  && ok "block-comment reason file carries the stale-base reason + file" \
  || no "TEST-SBB1.fail missing the stale-base reason"
[[ "$(cat "$TMP/nB")" == "1" ]] && ok "model did NOT run again (stale base caught before any spend)" \
  || no "model ran again despite the stale base (counter=$(cat "$TMP/nB" 2>/dev/null))"

WTB="$WT_ROOT/projB-TEST-SBB1"
[[ "$(git -C "$WTB" log -1 --format=%s)" == "task: attempt 1" ]] \
  && ok "prior task commit is still on the branch after the abort" \
  || no "prior commit LOST after the abort"
if git -C "$PROJB" merge-base --is-ancestor develop dozer/TEST-SBB1 2>/dev/null; then
  no "branch was SILENTLY rebased onto the moved base despite the conflict"
else
  ok "branch NOT moved onto the new base (left intact for the Director to see)"
fi
grep -q "TASK SIDE" "$WTB/feature.txt" \
  && ok "worktree content untouched by the abort" \
  || no "worktree content damaged by the abort"
[[ ! -d "$(git -C "$WTB" rev-parse --git-path rebase-merge)" && ! -d "$(git -C "$WTB" rev-parse --git-path rebase-apply)" ]] \
  && ok "no rebase in progress (abort clean)" \
  || no "a rebase is still IN PROGRESS in the worktree (abort failed)"

# ── scenario C: develop unmoved → resume as-is, no rebase ───────────────────────
echo "── C: base unmoved → resume as-is"
PROJC="$(new_project projC)"
write_stub "$TMP/stubC.sh" "$TMP/nC" "printf 'task work 1\n' > task.txt"
STUB="$TMP/stubC.sh"

rc=0; run_crew "$PROJC" TEST-SBC1 "stale-base unmoved" "$TMP/crewC1.log" || rc=$?
[[ $rc -ne 0 && -d "$WT_ROOT/projC-TEST-SBC1" ]] \
  && ok "attempt 1 died with the worktree kept" \
  || { no "attempt 1 did not leave a resumable worktree"; sed 's/^/    | /' "$TMP/crewC1.log" >&2; }

rc=0; run_crew "$PROJC" TEST-SBC1 "stale-base unmoved" "$TMP/crewC2.log" || rc=$?
[[ $rc -eq 0 ]] && ok "resume run exited clean" \
  || { no "resume run exited $rc"; sed 's/^/    | /' "$TMP/crewC2.log" >&2; }

grep -q "has not moved — resuming as-is" "$TMP/crewC2.log" \
  && ok "crew logged the unchanged-base path" \
  || no "no 'has not moved' line — the unchanged-base path is not logged"
grep -q "base moved — rebased" "$TMP/crewC2.log" \
  && no "crew REBASED a branch whose base never moved" \
  || ok "no rebase on the unmoved base"
[[ "$(git -C "$PROJC" log -1 --format=%s develop)" == merge*TEST-SBC1* ]] \
  && ok "merge commit landed on develop" \
  || no "develop HEAD is not the merge commit"

if [[ $fail == 0 ]]; then echo "dev-lane-stale-base-test: PASS"; else echo "dev-lane-stale-base-test: FAIL" >&2; exit 1; fi
