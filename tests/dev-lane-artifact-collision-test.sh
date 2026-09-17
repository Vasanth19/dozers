#!/usr/bin/env bash
# tests/dev-lane-artifact-collision-test.sh — regression test for GSAI-148.
#
# Every dev-lane crew used to write its ARCHITECT design and REVIEW verdict to the
# FIXED root paths DOZER-DESIGN.md / DOZER-REVIEW.md — no task id in them. Any two
# tasks in the SAME repo then shared those paths, and the moment one landed on the
# integration branch, every other in-flight task replayed an add/add conflict on the
# resume rebase ("stale base … CONFLICTS") or at the serial merge ("merge conflict —
# sent back") — blocking real, gated, test-green work on files the lane itself
# excludes from the no-commit gate as not-a-deliverable. This repo lived it: GSAI-148
# was false-blocked when GSAI-154's design landed on develop over GSAI-148's own.
#
# The fix names the artifacts after the issue: DOZER-DESIGN-$ID.md /
# DOZER-REVIEW-$ID.md (ART_ID in crew.sh). Disjoint paths per task → no content
# collision for the rebase or merge lock to even see. Rounds WITHIN one issue still
# share a name — same branch, sequential commits, ordinary same-path edits.
#
# The collision scenario, staged end-to-end against the REAL crew (MODEL_CMD bypass,
# in the idiom of dev-lane-model-prompt-test.sh):
#   TASK A — normal run: stub architect commits DOZER-DESIGN-TEST-AC-A.md, build
#            commits a real change, review writes VERDICT: PASS. Assert it merges.
#   STAGE B — hand-create B's worktree off the PRE-A develop tip (the incident's
#            interleaving: B branched before A merged) with a committed
#            DOZER-DESIGN-TEST-AC-B.md and a small disjoint code change.
#   TASK B — run the crew: it takes the RESUME path, sees develop advanced, and
#            rebases. Assert the log carries "base moved — rebased" and NEITHER
#            "CONFLICTS" nor "merge conflict"; assert exit 0; assert develop now
#            holds BOTH per-issue design files.
# On the unpatched crew this exact scenario dies at the rebase with DOZER-DESIGN.md
# named in the conflict list — verified at build time against the pre-fix crew
# (git-level add/add on the fixed path; the fixture below is byte-identical except
# the artifact names).
#
# Run:  bash tests/dev-lane-artifact-collision-test.sh   (exits non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() {
  rm -f "$ROOT"/.artifacts/dev/TEST-AC* 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# A throwaway repo on `main` (checked out) + `develop` with a fast test command.
mkproj() {  # $1 = dir
  local d="$1"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    printf '{"name":"p","version":"1.0.0","scripts":{"test":"bash t.sh"}}\n' > package.json
    printf 'exit 0\n' > t.sh
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m init
    git branch develop )
}

# Stub coding agent — one for BOTH tasks; it writes the PER-ISSUE artifacts from the
# TASK_ID the runner exports. Invocation 1 is the architect pass, then build/review
# alternate (2=build, 3=review). The architect's content is IDEMPOTENT — the same
# bytes the fixture stages for B — so the resume's architect pass adds no commit.
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$COUNT_FILE"
if   (( n == 1 )); then pass=architect
elif (( n % 2 == 0 )); then pass=build
else pass=review; fi
case "$pass" in
  architect)
    printf '# design for %s\n' "$TASK_ID" > "DOZER-DESIGN-$TASK_ID.md"
    git add -A && git commit -q -m design || true ;;
  build)
    printf 'dozer change %s for %s\n' "$n" "$TASK_ID" >> feature.txt
    git add -A && git commit -q -m "build $n" ;;
  review)
    printf 'VERDICT: PASS\nok\n' > "DOZER-REVIEW-$TASK_ID.md"
    git add -A && git commit -q -m review || true ;;
esac
exit 0
EOS
chmod +x "$STUB"

BOUND=15   # nothing here hangs; headroom over `npm test` startup (see dev-lane-model-exit-test.sh)
WTR="$TMP/wt"; mkdir -p "$WTR"

# MODEL_CMD bypass path: all three passes run the stub through the bypass branch.
run_crew() {  # $1 = proj dir, $2 = task id, $3 = log
  local proj="$1" id="$2" log="$3"
  env COUNT_FILE="$TMP/$id.count" TASK_ID="$id" TIMEBOX_KILL_GRACE=1 \
      DOZER_TIMEOUT_TEST="$BOUND" DOZER_TIMEOUT_MODEL="$BOUND" DOZER_TIMEOUT_DEPS="$BOUND" \
      REPO_ROOT="$TMP" WORKDIR="$proj" WORKTREE_ROOT="$WTR" INTEGRATION_BRANCH="develop" \
      MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" \
      bash "$CREW" "$id" "artifact collision test" >"$log" 2>&1
}

dev_head() { git -C "$1" log -1 --format=%s develop 2>/dev/null || true; }

# ────────────────────────────────────────────────────────────────────────────────
echo "── COLLISION: two tasks, one repo, disjoint artifact names"
P="$TMP/proj"; mkproj "$P"; SLUG="$(basename "$P")"
ID_A="TEST-AC-A"; ID_B="TEST-AC-B"

# ── TASK A: a clean full run — merges onto develop ─────────────────────────────
preA="$(git -C "$P" rev-parse develop)"   # the tip B will have branched from
LOG="$TMP/a.log"; rc=0
run_crew "$P" "$ID_A" "$LOG" || rc=$?
[[ $rc -eq 0 ]] && ok "COLLISION: task A completes (exit 0)" \
  || { no "COLLISION: task A exited $rc"; dump "$LOG"; }
[[ "$(dev_head "$P")" == merge*"$ID_A"* ]] && ok "COLLISION: A merged onto develop" \
  || no "COLLISION: develop HEAD is '$(dev_head "$P")'"
git -C "$P" cat-file -e "develop:DOZER-DESIGN-$ID_A.md" 2>/dev/null \
  && ok "COLLISION: A's per-issue design is on develop" \
  || no "COLLISION: DOZER-DESIGN-$ID_A.md missing on develop"

# ── STAGE B: the incident interleaving — B branched BEFORE A merged ────────────
# Same shape as a crashed/parked B attempt: a worktree under $WTR on the task branch
# holding a committed design + a small code change — exactly what the next crew run
# would RESUME. B's code change goes to its own file so feature.txt is NOT the
# variable under test (an overlapping append there would conflict for unrelated
# content reasons and mask the artifact-collision signal).
WTB="$WTR/$SLUG-$ID_B"
git -C "$P" worktree add -B "dozer/$ID_B" "$WTB" "$preA" >/dev/null 2>&1 \
  || { no "COLLISION: could not stage B's worktree"; exit 1; }
printf '# design for %s\n' "$ID_B" > "$WTB/DOZER-DESIGN-$ID_B.md"
printf 'b-side change\n' > "$WTB/b-code.txt"
git -C "$WTB" add -A && git -C "$WTB" commit -q -m "design + partial build for $ID_B"

# ── TASK B: RESUME — must rebase cleanly over A's merge and land ───────────────
LOG="$TMP/b.log"; rc=0
run_crew "$P" "$ID_B" "$LOG" || rc=$?
[[ $rc -eq 0 ]] && ok "COLLISION: task B completes past the interleaving (exit 0)" \
  || { no "COLLISION: task B exited $rc"; dump "$LOG"; }
grep -q 'RESUMING' "$LOG" \
  && ok "COLLISION: B took the RESUME path (the crash-recovery branch the incident hit)" \
  || { no "COLLISION: B never saw its staged work — the scenario re-ran from scratch"; dump "$LOG"; }
grep -q 'base moved — rebased' "$LOG" \
  && ok "COLLISION: the stale-base rebase ran (develop had advanced past B's fork point)" \
  || { no "COLLISION: no 'base moved — rebased' line — the rebase arm never fired"; dump "$LOG"; }
grep -q 'CONFLICTS' "$LOG" \
  && { no "COLLISION: the stale-base rebase CONFLICTED — the add/add collision is back"; dump "$LOG"; } \
  || ok "COLLISION: rebase clean — no CONFLICTS line"
grep -q 'merge conflict' "$LOG" \
  && { no "COLLISION: the serial merge conflicted"; dump "$LOG"; } \
  || ok "COLLISION: no merge conflict"
[[ "$(dev_head "$P")" == merge*"$ID_B"* ]] && ok "COLLISION: B merged onto develop after A" \
  || no "COLLISION: develop HEAD is '$(dev_head "$P")'"
if git -C "$P" cat-file -e "develop:DOZER-DESIGN-$ID_A.md" 2>/dev/null \
   && git -C "$P" cat-file -e "develop:DOZER-DESIGN-$ID_B.md" 2>/dev/null \
   && git -C "$P" cat-file -e "develop:DOZER-REVIEW-$ID_B.md" 2>/dev/null \
   && git -C "$P" cat-file -e "develop:b-code.txt" 2>/dev/null; then
  ok "COLLISION: develop holds BOTH tasks' per-issue designs + B's review + B's staged code"
else
  no "COLLISION: develop is missing part of the interleaved work: $(git -C "$P" ls-tree --name-only develop | tr '\n' ' ')"
fi
[[ -n "$(git -C "$P" status --porcelain 2>/dev/null)" ]] \
  && no "COLLISION: main checkout left dirty" \
  || ok "COLLISION: worktree state clean after both runs"

if [[ $fail == 0 ]]; then echo "dev-lane-artifact-collision-test: PASS"
else echo "dev-lane-artifact-collision-test: FAIL" >&2; exit 1; fi
