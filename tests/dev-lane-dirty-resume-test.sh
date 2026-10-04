#!/usr/bin/env bash
# tests/dev-lane-dirty-resume-test.sh — regression test for GSAI-152 (GSAI-157 rescue).
#
# A resumed task whose worktree holds UNCOMMITTED output (a tracked edit, or an
# untracked file) used to die at the stale-base rebase: `git rebase <base>` refuses a
# dirty tree ("cannot rebase: You have unstaged changes"), and the crew reported that
# as a stale-base CONFLICT even though nothing conflicted. The fix snapshots the dirty
# output into a `wip(<ID>)` commit BEFORE the RESUMING decision, so the rebase (and the
# existing resume machinery) runs on a clean tree.
#
# Scenarios, each against a throwaway repo and the real crew:
#   A) dirty + base moved, NO conflict → rescue, rebase, green merge      (the bug)
#   B) dirty + base moved, CONFLICT    → stale-base failure, wip kept, nothing lost
#   C) dirty + base unmoved            → rescue, resume as-is
#   D) dirty, NO committed work        → rescue turns it into a resume (fresh-start shape)
#   E) .env + node_modules present     → never committed in wip; a worktree dirty ONLY
#                                        with those is not "dirty" at all
#   F) a rebase a crashed run left     → fail closed; the rebase is NOT aborted
#
# Run:  bash tests/dev-lane-dirty-resume-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

WT_ROOT="$TMP/wt"
STUB=""

# ── a scratch repo: main checked out, develop branched, feature.txt + task.txt seeds ──
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

# ── stub coding agent (same shape as dev-lane-stale-base-test.sh): attempt 1 runs $3,
# commits, then dies → the crew keeps the worktree for resume. Attempts 2+ append to
# task.txt and commit. The counter in $2 proves whether the model ran again.
write_stub() {  # $1 = stub path, $2 = counter file, $3 = attempt-1 file op
  cat > "$1" <<EOS
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
EOS
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

# the wip commit for issue $2 in the history of ref $3 (default HEAD) of repo $1
wip_sha() {
  git -C "$1" log --format='%H %s' "${3:-HEAD}" 2>/dev/null | grep "wip($2)" | head -1 | cut -d' ' -f1 || true
}

# ── scenario A: dirty + base moved, NON-conflicting → rescue, rebase, green merge ──
echo "── A: dirty worktree + base moved, no conflict → rescue, rebase, green merge"
PROJA="$(new_project projA)"
write_stub "$TMP/stubA.sh" "$TMP/nA" "printf 'task work 1\n' > task.txt"
STUB="$TMP/stubA.sh"

rc=0; run_crew "$PROJA" TEST-DRA1 "dirty resume clean rebase" "$TMP/crewA1.log" || rc=$?
[[ $rc -ne 0 && -d "$WT_ROOT/projA-TEST-DRA1" ]] \
  && ok "attempt 1 died with the worktree kept (Seance precondition)" \
  || { no "attempt 1 did not leave a resumable worktree"; sed 's/^/    | /' "$TMP/crewA1.log" >&2; }

WTA="$WT_ROOT/projA-TEST-DRA1"
printf 'UNSAVED EDIT\n' >> "$WTA/task.txt"          # tracked edit, uncommitted
printf 'scratch\n' > "$WTA/scratch.txt"             # untracked output
( cd "$PROJA" && git checkout -q develop \
  && printf 'develop moved\n' > advance.txt \
  && git add -A && git commit -q -m "advance develop" )

rc=0; run_crew "$PROJA" TEST-DRA1 "dirty resume clean rebase" "$TMP/crewA2.log" || rc=$?
[[ $rc -eq 0 ]] && ok "resume run exited clean" \
  || { no "resume run exited $rc"; sed 's/^/    | /' "$TMP/crewA2.log" >&2; }

grep -q "rescued uncommitted output in .* as wip(TEST-DRA1)" "$TMP/crewA2.log" \
  && ok "crew rescued the dirty output as wip(TEST-DRA1) before resuming" \
  || no "no 'rescued uncommitted output … as wip(TEST-DRA1)' line in the crew log"
grep -q "cannot rebase" "$TMP/crewA2.log" \
  && no "rebase refused the dirty tree (the bug: 'cannot rebase: You have unstaged changes')" \
  || ok "no 'cannot rebase' refusal"
grep -q "base moved — rebased" "$TMP/crewA2.log" \
  && ok "base moved — rebased (clean tree, no conflict)" \
  || no "no 'base moved — rebased' line in the crew log"
[[ "$(git -C "$PROJA" log -1 --format=%s develop)" == merge*TEST-DRA1* ]] \
  && ok "merge commit landed on develop" \
  || no "develop HEAD is not the merge commit"
git -C "$PROJA" show develop:task.txt 2>/dev/null | grep -q "UNSAVED EDIT" \
  && ok "the unsaved tracked edit reached develop" \
  || no "unsaved tracked edit LOST"
git -C "$PROJA" cat-file -e develop:scratch.txt 2>/dev/null \
  && ok "the untracked output reached develop" \
  || no "untracked output LOST"

# ── scenario B: dirty + base moved, CONFLICT → stale-base failure, nothing discarded ──
echo "── B: dirty worktree + base moved, conflict → stale-base failure, wip kept"
PROJB="$(new_project projB)"
write_stub "$TMP/stubB.sh" "$TMP/nB" "printf 'TASK SIDE\n' > feature.txt"
STUB="$TMP/stubB.sh"

rc=0; run_crew "$PROJB" TEST-DRB1 "dirty resume conflict" "$TMP/crewB1.log" || rc=$?
[[ $rc -ne 0 && -d "$WT_ROOT/projB-TEST-DRB1" ]] \
  && ok "attempt 1 died with the worktree kept" \
  || { no "attempt 1 did not leave a resumable worktree"; sed 's/^/    | /' "$TMP/crewB1.log" >&2; }

WTB="$WT_ROOT/projB-TEST-DRB1"
printf 'TASK SIDE + UNSAVED\n' > "$WTB/feature.txt"  # dirty, and it conflicts with develop
( cd "$PROJB" && git checkout -q develop \
  && printf 'DEVELOP SIDE\n' > feature.txt \
  && git add -A && git commit -q -m "advance develop (conflict)" )

rc=0; run_crew "$PROJB" TEST-DRB1 "dirty resume conflict" "$TMP/crewB2.log" || rc=$?
[[ $rc -ne 0 ]] && ok "resume run FAILED (it must not merge a conflict)" \
  || { no "resume run unexpectedly succeeded"; sed 's/^/    | /' "$TMP/crewB2.log" >&2; }

grep -q "rescued uncommitted output" "$TMP/crewB2.log" \
  && ok "dirty output was rescued before the rebase" \
  || no "no rescue line — the dirty output was not snapshotted"
grep -q "stale base:" "$TMP/crewB2.log" \
  && ok "failure reason is the explicit stale-base message" \
  || no "no 'stale base:' failure in the crew log"
grep -q "feature.txt" "$TMP/crewB2.log" \
  && ok "conflicting file feature.txt is NAMED in the failure" \
  || no "conflicting file not named"
grep -q "cannot rebase" "$TMP/crewB2.log" \
  && no "rebase refused the dirty tree instead of conflicting (the bug)" \
  || ok "not the 'cannot rebase' refusal"
WIPB="$(wip_sha "$WTB" TEST-DRB1)"
[[ -n "$WIPB" ]] && git -C "$WTB" cat-file -t "$WIPB" >/dev/null 2>&1 \
  && ok "wip(TEST-DRB1) commit is on the branch after the abort" \
  || no "wip commit missing after the abort — the unsaved output may be lost"
[[ -n "$WIPB" ]] && git -C "$WTB" show "$WIPB:feature.txt" 2>/dev/null | grep -q "UNSAVED" \
  && ok "the unsaved edit is preserved inside the wip commit" \
  || no "the unsaved edit is NOT in the wip commit"
[[ ! -d "$(git -C "$WTB" rev-parse --git-path rebase-merge)" && ! -d "$(git -C "$WTB" rev-parse --git-path rebase-apply)" ]] \
  && ok "no rebase in progress (abort clean)" \
  || no "a rebase is still IN PROGRESS in the worktree (abort failed)"
[[ "$(cat "$TMP/nB")" == "1" ]] && ok "model did NOT run again (stale base caught before any spend)" \
  || no "model ran again despite the stale base (counter=$(cat "$TMP/nB" 2>/dev/null))"

# ── scenario C: dirty + base unmoved → rescue, then resume as-is ──────────────────
echo "── C: dirty worktree + base unmoved → rescue, resume as-is"
PROJC="$(new_project projC)"
write_stub "$TMP/stubC.sh" "$TMP/nC" "printf 'task work 1\n' > task.txt"
STUB="$TMP/stubC.sh"

rc=0; run_crew "$PROJC" TEST-DRC1 "dirty resume unmoved" "$TMP/crewC1.log" || rc=$?
[[ $rc -ne 0 && -d "$WT_ROOT/projC-TEST-DRC1" ]] \
  && ok "attempt 1 died with the worktree kept" \
  || { no "attempt 1 did not leave a resumable worktree"; sed 's/^/    | /' "$TMP/crewC1.log" >&2; }

WTC="$WT_ROOT/projC-TEST-DRC1"
printf 'UNSAVED EDIT\n' >> "$WTC/task.txt"
printf 'scratch\n' > "$WTC/scratch.txt"

rc=0; run_crew "$PROJC" TEST-DRC1 "dirty resume unmoved" "$TMP/crewC2.log" || rc=$?
[[ $rc -eq 0 ]] && ok "resume run exited clean" \
  || { no "resume run exited $rc"; sed 's/^/    | /' "$TMP/crewC2.log" >&2; }
grep -q "rescued uncommitted output" "$TMP/crewC2.log" \
  && ok "dirty output rescued" \
  || no "no rescue line"
grep -q "has not moved — resuming as-is" "$TMP/crewC2.log" \
  && ok "crew took the unchanged-base path" \
  || no "no 'has not moved' line"
grep -q "base moved — rebased" "$TMP/crewC2.log" \
  && no "crew rebased a branch whose base never moved" \
  || ok "no rebase on the unmoved base"
git -C "$PROJC" show develop:task.txt 2>/dev/null | grep -q "UNSAVED EDIT" \
  && ok "the unsaved tracked edit reached develop" \
  || no "unsaved tracked edit LOST"
git -C "$PROJC" cat-file -e develop:scratch.txt 2>/dev/null \
  && ok "the untracked output reached develop" \
  || no "untracked output LOST"

# ── scenario D: dirty, NO committed work → rescue turns it into a resume ──────────
echo "── D: dirty worktree, no committed work (fresh-start shape) → rescue, resume"
PROJD="$(new_project projD)"
git -C "$PROJD" worktree add -q -B dozer/TEST-DRD1 "$WT_ROOT/projD-TEST-DRD1" develop
WTD="$WT_ROOT/projD-TEST-DRD1"
git -C "$WTD" config user.email test@dozer; git -C "$WTD" config user.name dozer-test
printf 'DIRTY NO COMMIT\n' > "$WTD/feature.txt"      # tracked edit, nothing committed
printf 'scratch\n' > "$WTD/scratch.txt"
echo 1 > "$TMP/nD"                                   # attempts 2+ (the normal path)
write_stub "$TMP/stubD.sh" "$TMP/nD" "true"
STUB="$TMP/stubD.sh"

rc=0; run_crew "$PROJD" TEST-DRD1 "dirty fresh-start shape" "$TMP/crewD.log" || rc=$?
[[ $rc -eq 0 ]] && ok "run exited clean" \
  || { no "run exited $rc"; sed 's/^/    | /' "$TMP/crewD.log" >&2; }
grep -q "rescued uncommitted output" "$TMP/crewD.log" \
  && ok "dirty output rescued before the RESUMING decision" \
  || no "no rescue line"
grep -q "RESUMING #TEST-DRD1" "$TMP/crewD.log" \
  && ok "the rescue turned the dirty worktree into a resume" \
  || no "crew did not resume — it took the fresh-start path"
grep -q "worktree .* (off develop)" "$TMP/crewD.log" \
  && no "fresh-start path ran and would have removed the dirty worktree" \
  || ok "fresh-start path (worktree remove --force) never ran"
git -C "$PROJD" log develop --format=%s | grep -q "^wip(TEST-DRD1)" \
  && ok "wip(TEST-DRD1) commit landed on develop" \
  || no "no wip commit reached develop"
git -C "$PROJD" show develop:feature.txt 2>/dev/null | grep -q "DIRTY NO COMMIT" \
  && ok "the uncommitted tracked edit survived into develop" \
  || no "uncommitted tracked edit LOST"

# ── scenario E: .env + node_modules are never committed, and do not count as dirty ─
echo "── E: .env + node_modules → excluded from wip, and not 'dirty' on their own"
PROJE="$(new_project projE)"
write_stub "$TMP/stubE.sh" "$TMP/nE" "printf 'task work 1\n' > task.txt"
STUB="$TMP/stubE.sh"

rc=0; run_crew "$PROJE" TEST-DRE1 "dirty resume deps" "$TMP/crewE1.log" || rc=$?
[[ $rc -ne 0 && -d "$WT_ROOT/projE-TEST-DRE1" ]] \
  && ok "attempt 1 died with the worktree kept" \
  || { no "attempt 1 did not leave a resumable worktree"; sed 's/^/    | /' "$TMP/crewE1.log" >&2; }

WTE="$WT_ROOT/projE-TEST-DRE1"
printf 'UNSAVED EDIT\n' >> "$WTE/task.txt"          # the real dirt
printf 'scratch\n' > "$WTE/scratch.txt"
printf 'SECRET=do-not-commit\n' > "$WTE/.env"
mkdir -p "$WTE/node_modules/pkg" && printf 'module.exports = 1\n' > "$WTE/node_modules/pkg/index.js"
# the stub's own build commit runs `git add -A` and would sweep these in, so the
# assertion is on the WIP commit, which is made before the stub runs again.
rc=0; run_crew "$PROJE" TEST-DRE1 "dirty resume deps" "$TMP/crewE2.log" || rc=$?
# a clean run removes its worktree, so the wip commit is read from the merged repo
WIPE="$(wip_sha "$PROJE" TEST-DRE1 develop)"
[[ -n "$WIPE" ]] && ok "wip(TEST-DRE1) commit made" \
  || { no "no wip commit — rescue did not run"; sed 's/^/    | /' "$TMP/crewE2.log" >&2; }
if [[ -n "$WIPE" ]]; then
  git -C "$PROJE" show --name-only --format= "$WIPE" | grep -qx "task.txt" \
    && ok "the tracked edit is in the wip commit" \
    || no "tracked edit missing from the wip commit"
  git -C "$PROJE" show --name-only --format= "$WIPE" | grep -qx "scratch.txt" \
    && ok "the untracked scratch file is in the wip commit" \
    || no "untracked scratch file missing from the wip commit"
  git -C "$PROJE" show --name-only --format= "$WIPE" | grep -Eq '(^|/)(\.env|node_modules)(/|$)' \
    && no ".env or node_modules was COMMITTED in the wip commit (secret/bloat leak)" \
    || ok ".env and node_modules are NOT in the wip commit"
fi

PROJE2="$(new_project projE2)"
write_stub "$TMP/stubE2.sh" "$TMP/nE2" "printf 'task work 1\n' > task.txt"
STUB="$TMP/stubE2.sh"
rc=0; run_crew "$PROJE2" TEST-DRE2 "deps only" "$TMP/crewE2a.log" || rc=$?
WTE2="$WT_ROOT/projE2-TEST-DRE2"
[[ -d "$WTE2" ]] || { no "attempt 1 did not leave a worktree"; sed 's/^/    | /' "$TMP/crewE2a.log" >&2; }
printf 'SECRET=do-not-commit\n' > "$WTE2/.env"
mkdir -p "$WTE2/node_modules/pkg" && printf 'module.exports = 1\n' > "$WTE2/node_modules/pkg/index.js"
rc=0; run_crew "$PROJE2" TEST-DRE2 "deps only" "$TMP/crewE2b.log" || rc=$?
grep -q "rescued uncommitted output" "$TMP/crewE2b.log" \
  && no "a worktree dirty ONLY with .env/node_modules was treated as dirty" \
  || ok "a worktree holding only .env + node_modules is not 'dirty'"
[[ -z "$(wip_sha "$WTE2" TEST-DRE2)" ]] && ok "no wip commit for a deps-only worktree" \
  || no "a wip commit was made for a deps-only worktree"

# ── scenario F: a rebase a crashed run left behind → fail closed, rebase NOT aborted ─
echo "── F: dirty worktree with a rebase already in progress → fail closed, untouched"
PROJF="$(new_project projF)"
write_stub "$TMP/stubF.sh" "$TMP/nF" "printf 'task work 1\n' > task.txt"
STUB="$TMP/stubF.sh"

rc=0; run_crew "$PROJF" TEST-DRF1 "dirty rebase in progress" "$TMP/crewF1.log" || rc=$?
WTF="$WT_ROOT/projF-TEST-DRF1"
[[ $rc -ne 0 && -d "$WTF" ]] \
  && ok "attempt 1 died with the worktree kept" \
  || { no "attempt 1 did not leave a resumable worktree"; sed 's/^/    | /' "$TMP/crewF1.log" >&2; }

printf 'UNSAVED EDIT\n' >> "$WTF/task.txt"
GDF="$(git -C "$WTF" rev-parse --absolute-git-dir)"
mkdir "$GDF/rebase-merge"                            # simulate a crashed run's rebase
rc=0; run_crew "$PROJF" TEST-DRF1 "dirty rebase in progress" "$TMP/crewF2.log" || rc=$?
[[ $rc -ne 0 ]] && ok "run FAILED closed rather than touching the rebase" \
  || no "run succeeded despite a rebase in progress"
grep -q "could not be snapshotted" "$TMP/crewF2.log" \
  && ok "failure names the worktree and says it was NOT removed" \
  || no "no 'could not be snapshotted' failure"
[[ -d "$GDF/rebase-merge" ]] && ok "the leftover rebase was NOT aborted (the Director decides)" \
  || no "the leftover rebase was touched"
[[ -z "$(wip_sha "$WTF" TEST-DRF1)" ]] && ok "no wip commit made over a rebase in progress" \
  || no "a wip commit was made over a rebase in progress"
[[ -d "$WTF" ]] && git -C "$WTF" show "HEAD:task.txt" >/dev/null 2>&1 \
  && ok "the worktree and its branch are kept" \
  || no "the worktree was removed"
[[ "$(cat "$TMP/nF")" == "1" ]] && ok "model did NOT run again" \
  || no "model ran again over a rebase in progress (counter=$(cat "$TMP/nF" 2>/dev/null))"

if [[ $fail == 0 ]]; then echo "dev-lane-dirty-resume-test: PASS"; else echo "dev-lane-dirty-resume-test: FAIL" >&2; exit 1; fi
