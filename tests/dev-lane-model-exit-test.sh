#!/usr/bin/env bash
# tests/dev-lane-model-exit-test.sh — regression test for GSAI-147.
#
# run_model_pass used to treat ANY non-zero status out of the timeboxed model session
# as a dead pass — but the session's exit code is a side-channel, not the deliverable.
# A model CLI can write DOZER-DESIGN.md, commit the build, or write "VERDICT: PASS"
# into DOZER-REVIEW.md and still exit non-zero (crash on teardown, a final-turn API
# error). The crew then failed and discarded the artifact that was already on disk;
# a passing review died and the task re-ran from resume (three more model runs of
# spend). Now the pass's ARTIFACT is the contract and the exit code only decides
# whether to look: non-timeout + deliverable on disk → continue (with a loud ⚠
# naming the pass, the exit code, and the artifact); otherwise → fail as before.
#
# Four cases, each driving the REAL crew against a throwaway repo (in the idiom of
# dev-lane-timeout-test.sh), with a stub agent that counts invocations and misbehaves
# per pass:
#   RESCUE    — all three passes deliver their artifact then exit non-zero -> the
#               crew still exits 0, the merge lands on develop, the GSAI-119 receipt
#               is written, and the log carries the ⚠ rescue lines per pass
#   NO-ARTIFACT — the architect exits non-zero having written NOTHING -> blocked with
#               "architect agent failed (worktree kept for resume)", develop untouched:
#               the rescue is earned by a deliverable, not by exit-code generosity
#   TIMEOUT-PRECEDENCE — the architect writes DOZER-DESIGN.md then HANGS -> still
#               blocked with the model-timeout reason (GSAI-37): an artifact must
#               never rescue a timeout (a killed process may leave a truncated file)
#   GARBLED-VERDICT — the review writes a review with NO "VERDICT:" line and exits 1
#               (routed through a stub `claude`, no MODEL_CMD bypass, so the verdict
#               parse runs): rescued, parsed FAIL -> ONE rebuild -> second garbled
#               review -> "review failed TWICE". Proves the rescue feeds the verdict
#               gate instead of going around it — a truncated artifact can buy a
#               rebuild, never a merge.
#
# Run:  bash tests/dev-lane-model-exit-test.sh   (exits non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() {
  rm -f "$ROOT"/.artifacts/dev/TEST-ME* 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# A throwaway repo on `main` + `develop` with a fast, always-green test command.
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

# Stub coding agent. Counts invocations in $COUNT_FILE; invocation 1 is the architect
# pass, 2 the build, 3 the review, and the cycle repeats (4 would be the rebuild after
# a FAILed review, 5 the re-review). Behaviors per env:
#   ARCH_MODE   ok (default) | nothing | hang     ARCH_EXIT   (default 0)
#   REVIEW_MODE pass (default) | garbled          REVIEW_EXIT (default 0)
#   BUILD_EXIT  (default 0)
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$COUNT_FILE"
# 1=architect; then build/review alternate (2,4,… are builds — the even one after a
# FAILed review is the rebuild; 3,5,… are reviews).
if   (( n == 1 )); then pass=architect
elif (( n % 2 == 0 )); then pass=build
else pass=review; fi
rc=0
case "$pass" in
  architect)
    case "${ARCH_MODE:-ok}" in
      hang)
        # deliver the artifact FIRST, then hang — the timeout test of an artifact
        printf '# design\n' > DOZER-DESIGN.md
        git add -A && git commit -q -m design
        sleep 120 ;;
      nothing) ;;
      *) printf '# design\n' > DOZER-DESIGN.md
         git add -A && git commit -q -m design ;;
    esac
    rc="${ARCH_EXIT:-0}" ;;
  build)
    printf 'dozer change %s\n' "$n" >> feature.txt
    git add -A && git commit -q -m "build $n"
    rc="${BUILD_EXIT:-0}" ;;
  review)
    if [[ "${REVIEW_MODE:-pass}" == garbled ]]; then
      printf 'Reviewing the diff, but the write was truncated before any verdict line\n' > DOZER-REVIEW.md
    else
      printf 'VERDICT: PASS\nall good\n' > DOZER-REVIEW.md
    fi
    git add -A && git commit -q -m "review $n" || true
    rc="${REVIEW_EXIT:-0}" ;;
esac
exit "$rc"
EOS
chmod +x "$STUB"

BOUND=15   # far below the 120s hang, comfortably above `npm test` startup (see the
           # BOUND rationale in dev-lane-timeout-test.sh — 2s measured machine load)

# MODEL_CMD bypass path: all three passes run the stub through the bypass branch.
run_crew() {  # $1 = proj dir, $2 = task id, $3 = log, $4.. = extra KEY=VAL
  local proj="$1" id="$2" log="$3"; shift 3
  env COUNT_FILE="$TMP/$id.count" TIMEBOX_KILL_GRACE=1 \
      DOZER_TIMEOUT_TEST="$BOUND" DOZER_TIMEOUT_MODEL="$BOUND" DOZER_TIMEOUT_DEPS="$BOUND" \
      REPO_ROOT="$TMP" WORKDIR="$proj" WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
      MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" "$@" \
      bash "$CREW" "$id" "model exit test" >"$log" 2>&1
}

# Routed path (no MODEL_CMD): resolves the passes' routes for real, landing on a stub
# `claude` earlier in PATH. Needed for GARBLED-VERDICT — the verdict parse is skipped
# under the MODEL_CMD bypass, and that parse IS the gate this case exercises.
# The SCRUB matters: this suite is run by run-all.sh from inside a REAL Dozer crew,
# where MODEL_CMD and the DOZER_MODEL_* routing block are already exported — an
# inherited MODEL_CMD would silently take the bypass branch and the parse-gate case
# would assert on the harness's env instead of the code (same failure class as the
# GSAI-30 scrub in run-all.sh).
SCRUB_ROUTE=( -u MODEL_CMD -u DOZER_MODEL_PROVIDER -u DOZER_MODEL_NAME -u DOZER_MODEL_SOURCE
              -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL
              -u ANTHROPIC_SMALL_FAST_MODEL -u OLLAMA_API_KEY -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC )
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"; cp "$STUB" "$BINDIR/claude"
run_crew_routed() {  # same args as run_crew
  local proj="$1" id="$2" log="$3"; shift 3
  env "${SCRUB_ROUTE[@]}" PATH="$BINDIR:$PATH" COUNT_FILE="$TMP/$id.count" TIMEBOX_KILL_GRACE=1 \
      DOZER_TIMEOUT_TEST="$BOUND" DOZER_TIMEOUT_MODEL="$BOUND" DOZER_TIMEOUT_DEPS="$BOUND" \
      REPO_ROOT="$ROOT" WORKDIR="$proj" WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
      DOZER_MODEL_DEV_ARCHITECT="claude:claude-opus-5" \
      DOZER_MODEL_DEV_BUILD="claude:claude-opus-5" \
      DOZER_MODEL_DEV_REVIEW="claude:claude-opus-5" \
      PUSH="false" DOZER_PERSONA="test" "$@" \
      bash "$CREW" "$id" "model exit test" >"$log" 2>&1
}

dev_head() { git -C "$1" log -1 --format=%s develop 2>/dev/null || true; }
reason()   { cat "$1/.artifacts/dev/$2.fail" 2>/dev/null || true; }   # $1 = REPO_ROOT of the run
count()    { cat "$TMP/$1.count" 2>/dev/null || echo 0; }

# ── RESCUE: every pass delivers its artifact, then exits non-zero ─────────────
PA="$TMP/rescue"; mkproj "$PA"
LOG="$TMP/a.log"; rc=0
run_crew "$PA" "TEST-ME-A" "$LOG" ARCH_EXIT=3 BUILD_EXIT=3 REVIEW_EXIT=1 || rc=$?
[[ $rc -eq 0 ]] && ok "RESCUE: crew exits 0 despite all three passes exiting non-zero" \
  || { no "RESCUE: crew exited $rc"; dump "$LOG"; }
[[ "$(dev_head "$PA")" == merge*TEST-ME-A* ]] && ok "RESCUE: merge landed on develop" \
  || no "RESCUE: develop HEAD is '$(dev_head "$PA")'"
mrcpt="$TMP/.artifacts/dev/TEST-ME-A.merge"
msha="$(sed -n 's/^merge_sha=//p' "$mrcpt" 2>/dev/null)"
if [[ -f "$mrcpt" ]] && grep -q '^branch=develop$' "$mrcpt" \
   && [[ -n "$msha" ]] && git -C "$PA" merge-base --is-ancestor "$msha" develop 2>/dev/null; then
  ok "RESCUE: GSAI-119 merge receipt written and verifiable"
else no "RESCUE: merge receipt missing or unverifiable: $(cat "$mrcpt" 2>/dev/null)"; fi
grep -q '⚠ architect agent exited 3 but DOZER-DESIGN.md is on disk' "$LOG" \
  && ok "RESCUE: ⚠ line names the architect pass + exit code + artifact" \
  || { no "RESCUE: no architect rescue line"; dump "$LOG"; }
grep -q '⚠ build agent exited 3 but' "$LOG" \
  && ok "RESCUE: ⚠ line names the build rescue (commits proof)" \
  || { no "RESCUE: no build rescue line"; dump "$LOG"; }
grep -q '⚠ review agent exited 1 but DOZER-REVIEW.md is on disk' "$LOG" \
  && ok "RESCUE: ⚠ line names the review pass + exit code + artifact (the headline)" \
  || { no "RESCUE: no review rescue line"; dump "$LOG"; }

# ── NO-ARTIFACT: non-zero exit with NOTHING delivered -> fails exactly as before ──
PB="$TMP/no-artifact"; mkproj "$PB"
LOG="$TMP/b.log"; rc=0
run_crew "$PB" "TEST-ME-B" "$LOG" ARCH_MODE=nothing ARCH_EXIT=3 || rc=$?
[[ $rc -ne 0 ]] && ok "NO-ARTIFACT: crew blocked (exit $rc)" || { no "NO-ARTIFACT: crew exited 0"; dump "$LOG"; }
r="$(reason "$TMP" TEST-ME-B)"
[[ "$r" == "architect agent failed (worktree kept for resume)" ]] \
  && ok "NO-ARTIFACT: blocked with the original reason — the rescue needs a deliverable" \
  || { no "NO-ARTIFACT: wrong reason: '$r'"; dump "$LOG"; }
grep -q '⚠ .*agent exited .* continuing from' "$LOG" && { no "NO-ARTIFACT: a rescue was logged despite no artifact"; dump "$LOG"; } \
  || ok "NO-ARTIFACT: no rescue line in the log"
[[ "$(dev_head "$PB")" == "init" ]] && ok "NO-ARTIFACT: develop untouched" \
  || no "NO-ARTIFACT: develop advanced to '$(dev_head "$PB")'"
[[ -d "$TMP/wt-TEST-ME-B/no-artifact-TEST-ME-B" ]] && ok "NO-ARTIFACT: worktree kept for resume" \
  || no "NO-ARTIFACT: worktree removed"

# ── TIMEOUT-PRECEDENCE: artifact on disk + a HANG -> timeout still fails ───────
PC="$TMP/timeout"; mkproj "$PC"
LOG="$TMP/c.log"; start=$SECONDS; rc=0
run_crew "$PC" "TEST-ME-C" "$LOG" ARCH_MODE=hang || rc=$?
took=$(( SECONDS - start ))
[[ $rc -ne 0 ]] && ok "TIMEOUT-PRECEDENCE: crew blocked (exit $rc) in ${took}s" \
  || { no "TIMEOUT-PRECEDENCE: crew exited 0 with a hung agent"; dump "$LOG"; }
r="$(reason "$TMP" TEST-ME-C)"
[[ "$r" == *"architect agent timed out after ${BOUND}s"* && "$r" == *"DOZER_TIMEOUT_MODEL"* ]] \
  && ok "TIMEOUT-PRECEDENCE: reason names the model timeout, not a rescue" \
  || { no "TIMEOUT-PRECEDENCE: wrong reason: '$r'"; dump "$LOG"; }
grep -q '⚠ architect' "$LOG" && no "TIMEOUT-PRECEDENCE: the artifact rescued a timeout" \
  || ok "TIMEOUT-PRECEDENCE: the on-disk DOZER-DESIGN.md did NOT rescue the timeout"
[[ "$(dev_head "$PC")" == "init" ]] && ok "TIMEOUT-PRECEDENCE: develop untouched" \
  || no "TIMEOUT-PRECEDENCE: develop advanced to '$(dev_head "$PC")'"

# ── GARBLED-VERDICT: rescued review feeds the verdict gate, not around it ──────
PD="$TMP/garbled"; mkproj "$PD"
LOG="$TMP/d.log"; rc=0
run_crew_routed "$PD" "TEST-ME-D" "$LOG" REVIEW_MODE=garbled REVIEW_EXIT=1 || rc=$?
[[ $rc -ne 0 ]] && ok "GARBLED-VERDICT: crew blocked (exit $rc)" \
  || { no "GARBLED-VERDICT: crew merged with a garbled review"; dump "$LOG"; }
r="$(reason "$ROOT" TEST-ME-D)"
[[ "$r" == *"review failed TWICE"* ]] && ok "GARBLED-VERDICT: two garbled reviews block the task" \
  || { no "GARBLED-VERDICT: wrong reason: '$r'"; dump "$LOG"; }
[[ "$(count TEST-ME-D)" == 5 ]] && ok "GARBLED-VERDICT: the one rebuild ran (5 passes: arch,build,rev,rebuild,re-review)" \
  || { no "GARBLED-VERDICT: stub ran $(count TEST-ME-D) times, expected 5"; dump "$LOG"; }
[[ "$(grep -c '⚠ review agent exited 1 but DOZER-REVIEW.md is on disk' "$LOG")" == 2 ]] \
  && ok "GARBLED-VERDICT: both garbled reviews were rescued, then gated by the verdict parse" \
  || { no "GARBLED-VERDICT: expected 2 review rescue lines"; dump "$LOG"; }
[[ "$(dev_head "$PD")" == "init" ]] && ok "GARBLED-VERDICT: develop untouched — no merge from a truncated PASS" \
  || no "GARBLED-VERDICT: develop advanced to '$(dev_head "$PD")'"

if [[ $fail == 0 ]]; then echo "dev-lane-model-exit-test: PASS"
else echo "dev-lane-model-exit-test: FAIL" >&2; exit 1; fi
