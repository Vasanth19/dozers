#!/usr/bin/env bash
# tests/crew-profile-test.sh — the crew PROFILE selector + the model turn cap (GSAI-170).
#
# The dev lane used to run exactly one pipeline: ARCHITECT → BUILD → REVIEW, three
# model passes, for every issue regardless of what the issue was. That is the right
# shape for code and the wrong shape for housekeeping — a label rename does not need a
# design document and a second opinion — and it is how the factory spent its budget on
# its own paperwork. The `lite` profile is ONE build pass on the lane's cheap `small`
# route under a tight turn ceiling; `full` stays the default for everything else.
#
# Separately: a wall-clock timebox stops a HANG, never a LOOP. The 2026-09-20 spend
# audit put ~52% of all Ollama spend on the dev BUILD role, whose fix-the-failing-tests
# loop runs happily to the 1h timeout_model. So the build role now carries a TURN cap.
#
# Cases (throwaway repo + stub agent, in the idiom of dev-lane-model-prompt-test.sh):
#   LABEL      a `crew:lite` issue selects lite and NEVER spawns architect or review —
#              the acceptance criterion. Proven two ways at once: the stub agent is
#              invoked exactly ONCE, and no DOZER-DESIGN-*/DOZER-REVIEW-* file reaches
#              the integration branch.
#   OPSLANE    lane:ops selects lite with no label and no project at all.
#   PLAINDEV   a plain CFW issue — lane:dev, a CFW project, no crew:lite — selects
#              full: three passes, architect and review both present.
#   NOSIGNAL   no meta file and no lane (a backend that cannot answer) selects FULL.
#              A missing fact must never quietly downgrade a code task to one pass.
#   FORCED     DOZER_CREW forces a profile for one run.
#   BADPROFILE a profile the config does not define FAILS the crew — no silent default.
#   TURNCAP    the BUILD role's invocation carries `--max-turns 60` from config; the
#              lite profile's 25 overrides it; an uncapped role gets no flag at all.
#   SMALLROUTE `dev.small` resolves the lane's pin to a real route (what lite runs on).
#   NOCAPFLAG  a provider whose CLI has no turn flag (codex) reports the budget as
#              UNSUPPORTED instead of pretending the loop is capped.
#
# Run:  bash tests/crew-profile-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() {
  rm -f "$ROOT"/.artifacts/dev/TEST-CP* 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }
has() { grep -qF -- "$2" <<<"$1"; }   # `--`: several needles here start with a dash

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

# Stub coding agent. Counts invocations in $COUNT_FILE and records, per invocation, the
# pass name the crew announced for it — the crew prints "[dev] <pass> model: …" just
# before each run, so $PASS_FILE is the ORDER OF PASSES the crew actually spawned.
# It deduces its own pass from the count the way the real trio orders them, and writes
# whatever that pass is contracted to produce.
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$COUNT_FILE"
if   [[ "${LITE_STUB:-0}" == 1 ]]; then pass=build
elif (( n == 1 )); then pass=architect
elif (( n % 2 == 0 )); then pass=build
else pass=review; fi
printf '%s\n' "$pass" >> "$PASS_FILE"
case "$pass" in
  architect)
    printf '# design\n' > "DOZER-DESIGN-$TASK_ID.md"
    git add -A && git commit -q -m design ;;
  build)
    printf 'built by %s\n' "$TASK_ID" > built.txt
    git add -A && git commit -q -m "build" ;;
  review)
    printf 'VERDICT: PASS\nok\n' > "DOZER-REVIEW-$TASK_ID.md"
    git add -A && git commit -q -m review || true ;;
esac
exit 0
EOS

BOUND=15   # nothing here hangs; headroom over `npm test` startup

# run_crew <proj> <id> <log> [KEY=VAL ...] — the MODEL_CMD bypass path, so no case in
# this file needs a provider, a key, or a network. The profile SELECTION and the pass
# GATING both sit above the routing, which is what these cases are about; TURNCAP
# below exercises the routed path separately through model_route.py itself.
run_crew() {
  local proj="$1" id="$2" log="$3"; shift 3
  : > "$TMP/$id.passes"
  env COUNT_FILE="$TMP/$id.count" PASS_FILE="$TMP/$id.passes" TIMEBOX_KILL_GRACE=1 \
      DOZER_TIMEOUT_TEST="$BOUND" DOZER_TIMEOUT_MODEL="$BOUND" DOZER_TIMEOUT_DEPS="$BOUND" \
      REPO_ROOT="$TMP" WORKDIR="$proj" WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
      TASK_ID="$id" MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" "$@" \
      bash "$CREW" "$id" "a housekeeping chore" >"$log" 2>&1
}

# meta <id> <line>... — write an engine-shaped $DOZER_CREW_META file (tab-separated).
meta() {
  local f="$TMP/$1.meta"; shift
  : > "$f"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
  printf '%s' "$f"
}

echo "== crew profile selection =="

# ── LABEL: `crew:lite` → lite, and architect/review never run ─────────────────────
ID=TEST-CP-LABEL; PROJ="$TMP/label"; LOG="$TMP/label.log"
mkproj "$PROJ"
M="$(meta "$ID" "$(printf 'project\tCFW: Assistant')" "$(printf 'label\tlane:dev')" "$(printf 'label\tcrew:lite')")"
if run_crew "$PROJ" "$ID" "$LOG" DOZER_LANE=dev DOZER_CREW_META="$M" LITE_STUB=1; then
  out="$(cat "$LOG")"; passes="$(tr '\n' ' ' < "$TMP/$ID.passes")"
  n="$(cat "$TMP/$ID.count" 2>/dev/null || echo 0)"
  if has "$out" "crew profile: lite (the issue carries crew:lite)"; then
    ok "LABEL crew:lite selects the lite profile"
  else no "LABEL did not select lite; got: $(grep -F 'crew profile' <<<"$out" || true)"; fi
  if [[ "$passes" == "build " && "$n" == 1 ]]; then
    ok "LABEL lite ran the BUILD pass ONCE and nothing else (passes: $passes)"
  else no "LABEL expected exactly one build pass, got n=$n passes='$passes'"; dump "$LOG"; fi
  if has "$out" "architect pass skipped (crew profile: lite)" \
     && has "$out" "review pass skipped (crew profile: lite)"; then
    ok "LABEL lite announces the skipped architect + review passes"
  else no "LABEL missing the skip announcements"; dump "$LOG"; fi
  # The merged branch must carry the build's file and NEITHER pass artifact.
  merged="$(git -C "$PROJ" ls-tree -r --name-only develop)"
  if has "$merged" "built.txt" && ! grep -qE 'DOZER-(DESIGN|REVIEW)' <<<"$merged"; then
    ok "LABEL lite merged the build and produced no design/review artifact"
  else no "LABEL merged tree wrong: $merged"; fi
else no "LABEL crew run failed"; dump "$LOG"; fi

# ── OPSLANE: lane:ops alone → lite ────────────────────────────────────────────────
ID=TEST-CP-OPS; PROJ="$TMP/ops"; LOG="$TMP/ops.log"
mkproj "$PROJ"
if run_crew "$PROJ" "$ID" "$LOG" DOZER_LANE=ops LITE_STUB=1; then
  out="$(cat "$LOG")"; passes="$(tr '\n' ' ' < "$TMP/$ID.passes")"
  if has "$out" "crew profile: lite (lane:ops is a lite lane)" && [[ "$passes" == "build " ]]; then
    ok "OPSLANE lane:ops selects lite with no label and no project"
  else no "OPSLANE wrong: $(grep -F 'crew profile' <<<"$out" || true) passes='$passes'"; dump "$LOG"; fi
else no "OPSLANE crew run failed"; dump "$LOG"; fi

# ── PLAINDEV: an ordinary CFW issue → the full trio ───────────────────────────────
ID=TEST-CP-FULL; PROJ="$TMP/full"; LOG="$TMP/full.log"
mkproj "$PROJ"
M="$(meta "$ID" "$(printf 'project\tCFW: Assistant')" "$(printf 'label\tlane:dev')" "$(printf 'label\trepo:cfw-social')")"
if run_crew "$PROJ" "$ID" "$LOG" DOZER_LANE=dev DOZER_CREW_META="$M"; then
  out="$(cat "$LOG")"; passes="$(tr '\n' ' ' < "$TMP/$ID.passes")"
  if has "$out" "crew profile: full (no lite signal (lane/label/project))"; then
    ok "PLAINDEV a plain lane:dev CFW issue selects full"
  else no "PLAINDEV did not select full; got: $(grep -F 'crew profile' <<<"$out" || true)"; fi
  if [[ "$passes" == "architect build review " ]]; then
    ok "PLAINDEV full ran architect → build → review (passes: $passes)"
  else no "PLAINDEV expected the trio, got '$passes'"; dump "$LOG"; fi
else no "PLAINDEV crew run failed"; dump "$LOG"; fi

# ── NOSIGNAL: no meta, no lane — a backend that cannot answer → FULL ──────────────
ID=TEST-CP-NOSIG; PROJ="$TMP/nosig"; LOG="$TMP/nosig.log"
mkproj "$PROJ"
if run_crew "$PROJ" "$ID" "$LOG"; then
  passes="$(tr '\n' ' ' < "$TMP/$ID.passes")"
  if has "$(cat "$LOG")" "crew profile: full" && [[ "$passes" == "architect build review " ]]; then
    ok "NOSIGNAL no facts at all still runs the FULL trio (never a silent downgrade)"
  else no "NOSIGNAL expected full, got '$passes'"; dump "$LOG"; fi
else no "NOSIGNAL crew run failed"; dump "$LOG"; fi

# ── FORCED: DOZER_CREW pins the profile for one run ───────────────────────────────
ID=TEST-CP-FORCE; PROJ="$TMP/force"; LOG="$TMP/force.log"
mkproj "$PROJ"
M="$(meta "$ID" "$(printf 'project\tCFW: Assistant')" "$(printf 'label\tlane:dev')")"
if run_crew "$PROJ" "$ID" "$LOG" DOZER_LANE=dev DOZER_CREW_META="$M" DOZER_CREW=lite LITE_STUB=1; then
  passes="$(tr '\n' ' ' < "$TMP/$ID.passes")"
  if has "$(cat "$LOG")" "DOZER_CREW=lite (forced for this run)" && [[ "$passes" == "build " ]]; then
    ok "FORCED DOZER_CREW overrides the selection"
  else no "FORCED expected a forced lite run, got '$passes'"; dump "$LOG"; fi
else no "FORCED crew run failed"; dump "$LOG"; fi

# ── BADPROFILE: an undefined profile fails the crew, loudly ───────────────────────
ID=TEST-CP-BAD; PROJ="$TMP/bad"; LOG="$TMP/bad.log"
mkproj "$PROJ"
if run_crew "$PROJ" "$ID" "$LOG" DOZER_CREW=turbo; then
  no "BADPROFILE an unknown profile must FAIL the crew, not run something"
else
  if has "$(cat "$LOG")" "unknown crew profile 'turbo'"; then
    ok "BADPROFILE an undefined profile fails fast and names itself"
  else no "BADPROFILE failed without naming the profile"; dump "$LOG"; fi
fi

echo "== turn cap =="

# The routed path, through the resolver the crew calls. A temp config so the real
# org/config.yaml is never read, and a fake vault so no key is ever needed.
CFG="$TMP/config.yaml"; VAULT="$TMP/ollama-cloud.env"
printf 'OLLAMA_API_KEY=fake-key-do-not-use-0000\n' > "$VAULT"; chmod 600 "$VAULT"
cat > "$CFG" <<YAML
models:
  default: { provider: claude, model: "claude-opus-5" }
  dev:
    architect: { provider: ollama-cloud, model: "glm-5.3:cloud" }
    build:     { provider: ollama-cloud, model: "kimi-k3:cloud", max_turns: 60 }
    review:    { provider: codex, model: "gpt-5-codex", max_turns: 40 }
    small:     "glm-5.3-flash:cloud"
ollama_env: "$VAULT"
YAML

SCRUB=( -u OLLAMA_API_KEY -u MODEL_CMD -u DOZER_MAX_TURNS
        -u DOZER_MODEL_PROVIDER -u DOZER_MODEL_NAME -u DOZER_MODEL_SOURCE
        -u DOZER_MODEL_MAX_TURNS -u DOZER_MODEL_MAX_TURNS_UNSUPPORTED
        -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL
        -u ANTHROPIC_SMALL_FAST_MODEL )
route() {  # [VAR=val ...] <role>
  local -a envs=()
  while [[ "${1:-}" == *=* ]]; do envs+=("$1"); shift; done
  env "${SCRUB[@]}" ${envs[@]+"${envs[@]}"} python3 "$ROOT/tasks/model_route.py" "$1" --config "$CFG"
}

# ── TURNCAP: the build invocation carries the cap; lite's ceiling overrides it ────
out="$(route dev.build)"
has "$out" "export MODEL_CMD='claude -p --max-turns 60'" \
  && ok "TURNCAP the BUILD role's invocation carries --max-turns 60 from config" \
  || no "TURNCAP build cmd missing the cap; got: $(grep MODEL_CMD <<<"$out")"

out="$(route DOZER_MAX_TURNS=25 dev.build)"
has "$out" "--max-turns 25" \
  && ok "TURNCAP the crew profile's ceiling (DOZER_MAX_TURNS=25) beats the role's 60" \
  || no "TURNCAP profile ceiling ignored; got: $(grep MODEL_CMD <<<"$out")"

out="$(route DOZER_MAX_TURNS_DEV_BUILD=7 dev.build)"
has "$out" "--max-turns 7" \
  && ok "TURNCAP the per-role env override wins over both" \
  || no "TURNCAP per-role override ignored; got: $(grep MODEL_CMD <<<"$out")"

out="$(route dev.architect)"
if ! grep -qF -- "--max-turns" <<<"$out" && ! grep -qF "export DOZER_MODEL_MAX_TURNS=" <<<"$out"; then
  ok "TURNCAP an uncapped role gets no flag and claims no budget"
else no "TURNCAP architect is uncapped in config but got a cap; got: $out"; fi

out="$(route DOZER_MAX_TURNS=0 dev.build 2>&1)" && rc=0 || rc=$?
(( rc != 0 )) && has "$out" "whole number of turns" \
  && ok "TURNCAP a nonsense budget fails fast rather than being ignored" \
  || no "TURNCAP max_turns=0 should exit non-zero; rc=$rc out=$out"

# ── SMALLROUTE: `dev.small` is what the lite profile runs on ──────────────────────
out="$(route dev.small)"
if has "$out" "export ANTHROPIC_MODEL=glm-5.3-flash:cloud" \
   && has "$out" "export DOZER_MODEL_PROVIDER=ollama-cloud"; then
  ok "SMALLROUTE dev.small promotes the lane's pin to a real route on the lane's provider"
else no "SMALLROUTE wrong; got: $out"; fi

# ── NOCAPFLAG: codex has no turn flag — report it, never fake it ──────────────────
out="$(route dev.review)"
if ! grep -qF -- "--max-turns" <<<"$out" \
   && has "$out" "export DOZER_MODEL_MAX_TURNS=40" \
   && has "$out" "export DOZER_MODEL_MAX_TURNS_UNSUPPORTED=1"; then
  ok "NOCAPFLAG a provider with no turn flag reports the budget as UNSUPPORTED"
else no "NOCAPFLAG codex route wrong; got: $out"; fi

(( fail )) && { echo "crew-profile-test: FAIL" >&2; exit 1; }
echo "crew-profile-test: PASS"
