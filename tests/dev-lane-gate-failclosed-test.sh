#!/usr/bin/env bash
# tests/dev-lane-gate-failclosed-test.sh — regression test for GSAI-160.
#
# THE INCIDENT. ollama-cloud hit its monthly usage limit, so every model call returned
# HTTP 429 and every pass exited non-zero. The crew's artifact-rescue (GSAI-147) was
# written for a DIFFERENT failure — a model that finishes its work and then dies on
# teardown — and it could not tell the two apart. Worse, `[[ -s $REVIEW_FILE ]]` is
# true for a review file left behind by an EARLIER attempt in the same kept-for-resume
# worktree. Together: a review that never ran was "rescued" from a stale artifact, its
# old "VERDICT: PASS" was read as this round's verdict, and the branch MERGED. The gate
# failed OPEN — it reported success precisely because it could not reach its judge.
#
# THE CONTRACT. A pass that could not reach its model has produced no judgment, and no
# judgment is not a pass. Two guards, tested here independently:
#
#   PROVIDER-DOWN   — the pass's output carries a provider-level refusal (the ollama
#                     "monthly usage limit" text) and it exits non-zero. Even with a
#                     perfectly good "VERDICT: PASS" artifact sitting on disk, the crew
#                     must FAIL and develop must be untouched. This is the exact shape
#                     of the incident.
#   STALE-ARTIFACT  — the pass exits non-zero and leaves the artifact UNTOUCHED (it
#                     predates this attempt). No provider error in the output at all,
#                     so this guard is proven on its own: an artifact this attempt did
#                     not write can never be its deliverable.
#
# Both seed the artifact by COMMITTING it to the repo before the run, which is how a
# resumed worktree comes to hold a previous round's verdict.
#
# Run:  bash tests/dev-lane-gate-failclosed-test.sh   (exits non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -f "$ROOT"/.artifacts/dev/TEST-FC* 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true; return 0; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# A repo that already carries a PASS review artifact for the task — the "previous
# attempt's verdict" the rescue used to trust.
mkproj() {  # $1 = dir, $2 = task id
  local d="$1" id="$2"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    printf '{"name":"p","version":"1.0.0","scripts":{"test":"bash t.sh"}}\n' > package.json
    printf 'exit 0\n' > t.sh
    printf 'seed\n' > feature.txt
    printf 'VERDICT: PASS\nstale verdict from an earlier attempt\n' > "DOZER-REVIEW-$id.md"
    git add -A && git commit -q -m init
    git branch develop )
}

# Stub agent: architect and build behave; the review is the pass under test.
#   REVIEW_MODE=provider-down → print the provider's refusal, touch nothing, exit 1
#   REVIEW_MODE=untouched     → print an ordinary error, touch nothing, exit 1
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$COUNT_FILE"
if   (( n == 1 )); then pass=architect
elif (( n % 2 == 0 )); then pass=build
else pass=review; fi
case "$pass" in
  architect) printf '# design\n' > "DOZER-DESIGN-$TASK_ID.md"; git add -A && git commit -q -m design; exit 0 ;;
  build)     printf 'dozer change %s\n' "$n" >> feature.txt; git add -A && git commit -q -m "build $n"; exit 0 ;;
  review)
    case "${REVIEW_MODE:?}" in
      provider-down)
        echo 'API Error: 429 {"error":{"message":"you (goofy_hugle_463) have reached your monthly usage limit, add usage credits: https://ollama.com/settings","type":"api_error"}}' ;;
      untouched)
        echo 'the model wrote nothing this round' ;;
    esac
    exit 1 ;;
esac
EOS
chmod +x "$STUB"

BOUND=15
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"; cp "$STUB" "$BINDIR/claude"
SCRUB=( -u MODEL_CMD -u DOZER_MODEL_PROVIDER -u DOZER_MODEL_NAME -u DOZER_MODEL_SOURCE
        -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL
        -u ANTHROPIC_SMALL_FAST_MODEL -u OLLAMA_API_KEY -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC )
# The ROUTED path on purpose: under the MODEL_CMD bypass the verdict parse is skipped
# and REVIEW_VERDICT is forced to PASS, so the bypass could never show the merge this
# test is about. Routing for real puts the verdict gate in the path.
run_crew() {  # $1 = proj, $2 = id, $3 = log, $4.. = extra KEY=VAL
  local proj="$1" id="$2" log="$3"; shift 3
  env "${SCRUB[@]}" PATH="$BINDIR:$PATH" COUNT_FILE="$TMP/$id.count" TIMEBOX_KILL_GRACE=1 \
      DOZER_TIMEOUT_TEST="$BOUND" DOZER_TIMEOUT_MODEL="$BOUND" DOZER_TIMEOUT_DEPS="$BOUND" \
      REPO_ROOT="$ROOT" WORKDIR="$proj" WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
      TASK_ID="$id" \
      DOZER_MODEL_DEV_ARCHITECT="claude:claude-opus-5" \
      DOZER_MODEL_DEV_BUILD="claude:claude-opus-5" \
      DOZER_MODEL_DEV_REVIEW="claude:claude-opus-5" \
      PUSH="false" DOZER_PERSONA="test" "$@" \
      bash "$CREW" "$id" "fail-closed gate test" >"$log" 2>&1
}
dev_head() { git -C "$1" log -1 --format=%s develop 2>/dev/null || true; }

# ── PROVIDER-DOWN: 429 in the output + a stale PASS artifact -> must NOT merge ──────
P1="$TMP/down"; mkproj "$P1" "TEST-FC-A"
LOG="$TMP/a.log"; rc=0
run_crew "$P1" "TEST-FC-A" "$LOG" REVIEW_MODE=provider-down || rc=$?
[[ $rc -ne 0 ]] && ok "PROVIDER-DOWN: crew failed instead of merging on an unreachable model" \
  || { no "PROVIDER-DOWN: crew exited 0 — the gate failed OPEN"; dump "$LOG"; }
[[ "$(dev_head "$P1")" == "init" ]] && ok "PROVIDER-DOWN: develop untouched" \
  || { no "PROVIDER-DOWN: develop moved to '$(dev_head "$P1")'"; dump "$LOG"; }
grep -q 'the model was never reached' "$LOG" \
  && ok "PROVIDER-DOWN: the cause is named, not masked" \
  || { no "PROVIDER-DOWN: no 'never reached' diagnosis in the log"; dump "$LOG"; }
grep -q 'out of credits' "$LOG" \
  && ok "PROVIDER-DOWN: the 429 is reported as out-of-credits specifically" \
  || { no "PROVIDER-DOWN: the credit exhaustion was not identified"; dump "$LOG"; }

# ── STALE-ARTIFACT: ordinary failure + an UNTOUCHED artifact -> must NOT merge ──────
# No provider-error text anywhere, so only the freshness guard can catch this one.
P2="$TMP/stale"; mkproj "$P2" "TEST-FC-B"
LOG2="$TMP/b.log"; rc=0
run_crew "$P2" "TEST-FC-B" "$LOG2" REVIEW_MODE=untouched || rc=$?
[[ $rc -ne 0 ]] && ok "STALE-ARTIFACT: crew failed instead of trusting an old verdict" \
  || { no "STALE-ARTIFACT: crew exited 0 — a previous round's PASS merged the branch"; dump "$LOG2"; }
[[ "$(dev_head "$P2")" == "init" ]] && ok "STALE-ARTIFACT: develop untouched" \
  || { no "STALE-ARTIFACT: develop moved to '$(dev_head "$P2")'"; dump "$LOG2"; }
grep -q 'UNTOUCHED by this attempt' "$LOG2" \
  && ok "STALE-ARTIFACT: the stale artifact is named as the reason" \
  || { no "STALE-ARTIFACT: no staleness diagnosis in the log"; dump "$LOG2"; }
grep -q 'the model was never reached' "$LOG2" \
  && { no "STALE-ARTIFACT: misreported as a provider outage (no 429 in this case)"; dump "$LOG2"; } \
  || ok "STALE-ARTIFACT: not misreported as a provider outage"

[[ $fail -eq 0 ]] && echo "dev-lane-gate-failclosed-test: PASS" || echo "dev-lane-gate-failclosed-test: FAIL"
exit "$fail"
