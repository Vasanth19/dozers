#!/usr/bin/env bash
# tests/dev-lane-no-commit-gate-test.sh — regression test for GSAI-149.
#
# The no-commit gate in build_once used to anchor at the current HEAD immediately
# before the build pass and fail when the branch did not advance past it ("did THIS
# attempt add commits?"). On a RESUME whose work is already complete the build agent
# correctly adds nothing — there is nothing left to write — so the gate failed a task
# holding finished, tested work ahead of the base, forever (GSAI-144 attempt 4,
# BRD-88): a completed task could never finish, and each attempt burned a full
# architect+build+review cycle rediscovering the work was done. The GSAI-147
# commits:<anchor> proof had the same blind spot: a build flake on a resume failed
# the crew before the gate could judge, leaving a finished branch unrescuable.
#
# The gate now asks "does the branch hold anything to merge?" — a diff vs the pinned
# base SHA EXCLUDING the pass artifacts (the PER-ISSUE DOZER-DESIGN-<id>.md /
# DOZER-REVIEW-<id>.md, GSAI-148 — and the LEGACY root names, so a pre-fix resumed
# branch whose committed design sits at the old fixed path is still scored
# "design is not a deliverable"), the one definition shared by the gate and the build
# pass's changes: proof. Excluding the artifacts is what keeps a FIRST attempt whose
# only commit is the architect's design file from passing (the crew's design backstop
# commits it before the build runs, so a naive `git log $base..$BRANCH` gate would
# wave a no-op first build through — the design-commit hole this suite pins shut).
#
# Four cases against the REAL crew, in the idiom of dev-lane-model-exit-test.sh,
# each on a throwaway repo (main + develop) driven through the ROUTED path (a stub
# `claude` on PATH, no MODEL_CMD bypass — the garbled-review trick and the verdict
# parse need the non-bypass branch, and the design backstop commit only exists
# there). The stub counts invocations per run (1=architect, then build/review
# alternate) and behaves per env: BUILD_MODE=work|nothing, REVIEW_MODE=pass|garbled.
#
#   RESUME-FINISHED (the headline) — run 1: garbled reviews → blocked "review failed
#               TWICE", worktree KEPT holding the design + build commits. Run 2 (a
#               resume) with BUILD_MODE=nothing: the build adds nothing. The crew
#               exits 0, logs "build pass added nothing — branch already N commits
#               ahead …", the merge lands on develop, and the GSAI-119 receipt is
#               written and verifiable.
#   FIRST-ATTEMPT-NOOP — fresh project, BUILD_MODE=nothing: the architect commits
#               the design, the build writes nothing, tests are green → blocked with
#               EXACTLY "build agent produced no commits on dozer/TEST-NG-B", develop
#               untouched, worktree kept. The branch's one commit proves the naive
#               log gate this suite refuses would have passed it.
#   RESUME-TESTS-FAIL — same run-1 construction; between runs a failing t.sh is
#               committed onto the kept task branch (prior work that is NOT green).
#               Run 2 with BUILD_MODE=nothing: the gate passes on the existing
#               feature diff, the tests run and fail → blocked with "tests failed
#               after Ns — not merging (worktree kept for resume)" (GSAI-151 added
#               the elapsed), develop untouched. The gate
#               runs AFTER the tests by construction, so it never rescues red work.
#   LEGACY-EXCLUDED (GSAI-148) — the architect ALSO commits the pre-fix root
#               DOZER-DESIGN.md and the build adds nothing → still blocked with the
#               byte-identical message: the legacy scheme stays excluded, so a pre-fix
#               resumed branch is still scored "design is not a deliverable".
#
# Run:  bash tests/dev-lane-no-commit-gate-test.sh   (exits non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() {
  rm -f "$ROOT"/.artifacts/dev/TEST-NG-* 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# A throwaway repo on `main` (checked out) + `develop` with a fast test command
# (`npm test` → bash t.sh) — the same shape as dev-lane-model-exit-test.sh.
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

# Stub coding agent. Counts invocations in $COUNT_FILE (a FRESH file per run, so the
# resume runs re-count from 1: architect again). Invocation 1 is the architect pass,
# then build/review alternate. Artifacts are the PER-ISSUE names (GSAI-148), built from
# the TASK_ID the runner exports. Modes:
#   BUILD_MODE  work (default) | nothing    — "nothing" adds NO change to the branch
#   REVIEW_MODE pass (default) | garbled    — "garbled" writes a review with no verdict
#   ARCH_LEGACY 1                          — ALSO commits the legacy root
#                                            DOZER-DESIGN.md (the pre-fix name), for the
#                                            LEGACY-EXCLUDED case
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$COUNT_FILE"
if   (( n == 1 )); then pass=architect
elif (( n % 2 == 0 )); then pass=build
else pass=review; fi
case "$pass" in
  architect)
    printf '# design\n' > "DOZER-DESIGN-$TASK_ID.md"
    [[ "${ARCH_LEGACY:-0}" == 1 ]] && printf '# legacy design\n' > DOZER-DESIGN.md
    git add -A && git commit -q -m design || true ;;   # resume: identical content → no new commit
  build)
    case "${BUILD_MODE:-work}" in
      nothing) : ;;                                     # the resume / first-noop pin
      *) printf 'dozer change %s\n' "$n" >> feature.txt
         git add -A && git commit -q -m "build $n" ;;
    esac ;;
  review)
    if [[ "${REVIEW_MODE:-pass}" == garbled ]]; then
      printf 'Reviewing the diff, but the write was truncated before any verdict line\n' > "DOZER-REVIEW-$TASK_ID.md"
    else
      printf 'VERDICT: PASS\nall good\n' > "DOZER-REVIEW-$TASK_ID.md"
    fi
    git add -A && git commit -q -m "review $n" || true ;;
esac
exit 0
EOS
chmod +x "$STUB"

# Routed path (no MODEL_CMD bypass): the passes' routes resolve for real, landing on
# the stub `claude` earlier in PATH. The SCRUB matters for the same reason as in
# dev-lane-model-exit-test.sh: run-all.sh launches this suite from inside a REAL
# Dozer crew, and an inherited MODEL_CMD / DOZER_MODEL_* would silently take the
# bypass branch (skipping the verdict parse — the gate the garbled runs exercise).
SCRUB_ROUTE=( -u MODEL_CMD -u DOZER_MODEL_PROVIDER -u DOZER_MODEL_NAME -u DOZER_MODEL_SOURCE
              -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL
              -u ANTHROPIC_SMALL_FAST_MODEL -u OLLAMA_API_KEY -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC )
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"; cp "$STUB" "$BINDIR/claude"
WT_ROOT="$TMP/wt"
run_crew() {  # $1 = proj dir, $2 = task id, $3 = log, $4.. = extra KEY=VAL (COUNT_FILE=… required)
  local proj="$1" id="$2" log="$3"; shift 3
  env "${SCRUB_ROUTE[@]}" PATH="$BINDIR:$PATH" \
      REPO_ROOT="$ROOT" WORKDIR="$proj" WORKTREE_ROOT="$WT_ROOT" INTEGRATION_BRANCH="develop" \
      TASK_ID="$id" \
      DOZER_MODEL_DEV_ARCHITECT="claude:claude-opus-5" \
      DOZER_MODEL_DEV_BUILD="claude:claude-opus-5" \
      DOZER_MODEL_DEV_REVIEW="claude:claude-opus-5" \
      PUSH="false" DOZER_PERSONA="test" "$@" \
      bash "$CREW" "$id" "no-commit gate test" >"$log" 2>&1
}

dev_head() { git -C "$1" log -1 --format=%s develop 2>/dev/null || true; }
reason()   { cat "$ROOT/.artifacts/dev/$1.fail" 2>/dev/null || true; }

# ── RESUME-FINISHED: resume whose work is complete, build adds nothing → merges ─
echo "── RESUME-FINISHED: the headline — a finished task can finish"
PA="$TMP/resume-finished"; mkproj "$PA"; ID_A="TEST-NG-A"; WTA="$WT_ROOT/$(basename "$PA")-$ID_A"

LOG="$TMP/a1.log"; rc=0
run_crew "$PA" "$ID_A" "$LOG" COUNT_FILE="$TMP/a-r1.count" REVIEW_MODE=garbled || rc=$?
[[ $rc -ne 0 ]] && ok "RESUME-FINISHED: run 1 blocked (exit $rc)" \
  || { no "RESUME-FINISHED: run 1 unexpectedly exited 0"; dump "$LOG"; }
r="$(reason "$ID_A")"
[[ "$r" == *"review failed TWICE"* ]] && ok "RESUME-FINISHED: run 1 died on two garbled reviews (worktree kept)" \
  || { no "RESUME-FINISHED: run 1 died with the wrong reason: '$r'"; dump "$LOG"; }
[[ -d "$WTA" ]] && ok "RESUME-FINISHED: worktree kept holding the prior work (the Seance precondition)" \
  || no "RESUME-FINISHED: worktree gone before the resume"
grep -q 'dozer change' "$WTA/feature.txt" 2>/dev/null \
  && ok "RESUME-FINISHED: run 1's build output is committed on the kept branch" \
  || no "RESUME-FINISHED: no build output on the kept branch"

LOG="$TMP/a2.log"; rc=0
run_crew "$PA" "$ID_A" "$LOG" COUNT_FILE="$TMP/a-r2.count" BUILD_MODE=nothing REVIEW_MODE=pass || rc=$?
[[ $rc -eq 0 ]] && ok "RESUME-FINISHED: the resume exits 0 with the build adding NOTHING" \
  || { no "RESUME-FINISHED: the resume exited $rc — a finished task still cannot finish (the bug)"; dump "$LOG"; }
grep -qF 'build pass added nothing — branch already' "$LOG" \
  && ok "RESUME-FINISHED: the plain resume line is logged" \
  || { no "RESUME-FINISHED: no resume info line in the log"; dump "$LOG"; }
grep -qF 'already 4 commits ahead of develop' "$LOG" \
  && ok "RESUME-FINISHED: the resume line counts the 4 prior commits (design, build, garbled review, rebuild — the identical second garbled review adds no commit)" \
  || { no "RESUME-FINISHED: wrong commit count in the resume line"; dump "$LOG"; }
grep -qF 'build agent produced no commits' "$LOG" \
  && { no "RESUME-FINISHED: the OLD gate still fired on a finished branch"; dump "$LOG"; } \
  || ok "RESUME-FINISHED: the per-attempt gate never fired"
[[ "$(dev_head "$PA")" == merge*"$ID_A"* ]] && ok "RESUME-FINISHED: merge landed on develop" \
  || no "RESUME-FINISHED: develop HEAD is '$(dev_head "$PA")'"
mrcpt="$ROOT/.artifacts/dev/$ID_A.merge"
msha="$(sed -n 's/^merge_sha=//p' "$mrcpt" 2>/dev/null)"
if [[ -f "$mrcpt" ]] && grep -q '^branch=develop$' "$mrcpt" \
   && [[ -n "$msha" ]] && git -C "$PA" merge-base --is-ancestor "$msha" develop 2>/dev/null; then
  ok "RESUME-FINISHED: GSAI-119 merge receipt written and verifiable"
else no "RESUME-FINISHED: merge receipt missing or unverifiable: $(cat "$mrcpt" 2>/dev/null)"; fi

# ── FIRST-ATTEMPT-NOOP: only the design commit ahead of base → still FAILS ──────
echo "── FIRST-ATTEMPT-NOOP: the design-commit hole stays shut"
PB="$TMP/first-attempt-noop"; mkproj "$PB"; ID_B="TEST-NG-B"

LOG="$TMP/b.log"; rc=0
run_crew "$PB" "$ID_B" "$LOG" COUNT_FILE="$TMP/b.count" BUILD_MODE=nothing || rc=$?
[[ $rc -ne 0 ]] && ok "FIRST-ATTEMPT-NOOP: crew blocked (exit $rc)" \
  || { no "FIRST-ATTEMPT-NOOP: a no-op first build merged (the design-commit hole is open)"; dump "$LOG"; }
r="$(reason "$ID_B")"
[[ "$r" == "build agent produced no commits on dozer/$ID_B" ]] \
  && ok "FIRST-ATTEMPT-NOOP: blocked with the byte-identical old message" \
  || { no "FIRST-ATTEMPT-NOOP: wrong reason: '$r'"; dump "$LOG"; }
[[ "$(dev_head "$PB")" == "init" ]] && ok "FIRST-ATTEMPT-NOOP: develop untouched" \
  || no "FIRST-ATTEMPT-NOOP: develop advanced to '$(dev_head "$PB")'"
[[ -d "$WT_ROOT/$(basename "$PB")-$ID_B" ]] && ok "FIRST-ATTEMPT-NOOP: worktree kept for resume" \
  || no "FIRST-ATTEMPT-NOOP: worktree removed"
branch_log="$(git -C "$PB" log --format=%s "develop..dozer/$ID_B" 2>/dev/null)"
[[ "$branch_log" == "design" ]] \
  && ok "FIRST-ATTEMPT-NOOP: the ONLY commit ahead of base is the design — a naive log gate would have passed this" \
  || no "FIRST-ATTEMPT-NOOP: unexpected branch contents ahead of base: '$branch_log'"

# ── RESUME-TESTS-FAIL: the gate never rescues work that is not green ────────────
echo "── RESUME-TESTS-FAIL: gate passes on the feature diff, tests still gate"
PC="$TMP/resume-tests-fail"; mkproj "$PC"; ID_C="TEST-NG-C"; WTC="$WT_ROOT/$(basename "$PC")-$ID_C"

LOG="$TMP/c1.log"; rc=0
run_crew "$PC" "$ID_C" "$LOG" COUNT_FILE="$TMP/c-r1.count" REVIEW_MODE=garbled || rc=$?
[[ $rc -ne 0 && -d "$WTC" ]] && ok "RESUME-TESTS-FAIL: run 1 blocked with the worktree kept" \
  || { no "RESUME-TESTS-FAIL: run 1 did not leave a resumable worktree"; dump "$LOG"; }

# Between runs: commit a FAILING t.sh onto the kept task branch — prior work that
# is not green (as if an earlier attempt had left red tests behind).
printf 'exit 1\n' > "$WTC/t.sh"
git -C "$WTC" add t.sh && git -C "$WTC" commit -q -m "prior work: not green"

LOG="$TMP/c2.log"; rc=0
run_crew "$PC" "$ID_C" "$LOG" COUNT_FILE="$TMP/c-r2.count" BUILD_MODE=nothing REVIEW_MODE=pass || rc=$?
[[ $rc -ne 0 ]] && ok "RESUME-TESTS-FAIL: the resume blocks (exit $rc)" \
  || { no "RESUME-TESTS-FAIL: red prior work MERGED (the tests stopped gating)"; dump "$LOG"; }
r="$(reason "$ID_C")"
# GSAI-151: the red line now carries the elapsed seconds ("tests failed after Ns —
# not merging …"), so this pins the semantics, not the exact string.
[[ "$r" == *"tests failed after"* && "$r" == *"not merging"* ]] \
  && ok "RESUME-TESTS-FAIL: blocked by the TEST gate, which runs before the merge" \
  || { no "RESUME-TESTS-FAIL: wrong reason: '$r'"; dump "$LOG"; }
grep -qF 'build agent produced no commits' "$LOG" \
  && { no "RESUME-TESTS-FAIL: the no-commit gate fired instead of the test gate"; dump "$LOG"; } \
  || ok "RESUME-TESTS-FAIL: the no-commit gate passed on the existing feature diff (the tests did the judging)"
[[ "$(dev_head "$PC")" == "init" ]] && ok "RESUME-TESTS-FAIL: develop untouched" \
  || no "RESUME-TESTS-FAIL: develop advanced to '$(dev_head "$PC")'"

# ── LEGACY-EXCLUDED (GSAI-148): a legacy-named design-only diff is ALSO not output ──
# Pre-fix branches carry their committed design at the FIXED root DOZER-DESIGN.md — a
# resume of such a branch must still be scored "a design file is not a deliverable".
# The exclusion list keeps BOTH schemes, so a branch whose only diff is design files
# (legacy + per-issue) still fails the gate. ARCH_LEGACY=1 makes the stub commit the
# legacy design alongside the per-issue one; BUILD_MODE=nothing adds nothing else.
echo "── LEGACY-EXCLUDED: the pre-fix design path is also not a deliverable"
PD="$TMP/legacy-excluded"; mkproj "$PD"; ID_D="TEST-NG-D"

LOG="$TMP/d.log"; rc=0
run_crew "$PD" "$ID_D" "$LOG" COUNT_FILE="$TMP/d.count" BUILD_MODE=nothing ARCH_LEGACY=1 || rc=$?
[[ $rc -ne 0 ]] && ok "LEGACY-EXCLUDED: crew blocked (exit $rc)" \
  || { no "LEGACY-EXCLUDED: a legacy-design-only diff PASSED the gate"; dump "$LOG"; }
r="$(reason "$ID_D")"
[[ "$r" == "build agent produced no commits on dozer/$ID_D" ]] \
  && ok "LEGACY-EXCLUDED: blocked by the gate — the legacy design file counted as nothing" \
  || { no "LEGACY-EXCLUDED: wrong reason: '$r'"; dump "$LOG"; }
git -C "$PD" cat-file -e "dozer/$ID_D:DOZER-DESIGN.md" 2>/dev/null \
  && ok "LEGACY-EXCLUDED: the legacy-named design really was committed on the branch (the pin is exercised)" \
  || no "LEGACY-EXCLUDED: stub never committed DOZER-DESIGN.md — the case proves nothing"
[[ "$(dev_head "$PD")" == "init" ]] && ok "LEGACY-EXCLUDED: develop untouched" \
  || no "LEGACY-EXCLUDED: develop advanced to '$(dev_head "$PD")'"

if [[ $fail == 0 ]]; then echo "dev-lane-no-commit-gate-test: PASS"
else echo "dev-lane-no-commit-gate-test: FAIL" >&2; exit 1; fi
