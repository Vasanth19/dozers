#!/usr/bin/env bash
# dozers/dev-lane/crew.sh — DEV lane crew: isolate/RESUME → agent → test → serial-merge
# (per-project merge lock + green-gate) → cleanup. Fail-fast; never merges red.
#
# Resilience (inspired by gastown):
#   • Seance (resume): if a prior attempt left COMMITTED work in this task's worktree
#     (e.g. a crash), REUSE the worktree and tell the agent to continue — not restart.
#     The reaper leaves worktrees intact on failure precisely so this can happen.
#   • Stale base (GSAI-70): a resume first checks the integration branch is still an
#     ancestor of the task branch — if it advanced since the worktree was built, the
#     branch is rebased onto the new base BEFORE resuming (a conflicting rebase aborts
#     and FAILS, naming the conflicting files). Otherwise every resume quietly builds
#     on the old base and the lane merge-conflicts forever (LL-19, LL-26, CFW-202).
#   • Refinery (merge queue): merges to the integration branch are serialized by a
#     per-project lock, and each merge is GREEN-GATED — verified on the integration
#     branch after merging; a merge that breaks it is reverted and the task sent back.
#
# Env: WORKDIR, DOZER_PERSONA, REPO_ROOT. Config: integration_branch, push,
#   branch_prefix, worktree_root. DRY_RUN=1 stubs the model + tests (+ deps install).
#   DEPS_INSTALL=off skips the lockfile install that otherwise runs when a worktree
#   has a package.json but no node_modules (GSAI-26). On the merge worktree that
#   install happens AFTER the merge (GSAI-124), so a first package.json arriving with
#   the change still gets node_modules before the green-gate runs.
#
# Integration branch (GSAI-15 / GSAI-19): `develop` when the repo has one (local or
#   remote), else the repo's own default — origin/HEAD → main → the checked-out branch.
#   Never creates develop; a detached HEAD with nothing above it fails fast.
#
# Merge target (GSAI-26): if the integration branch is already checked out somewhere
#   (e.g. the main checkout sits on develop) the merge happens IN that checkout when
#   it's clean; a dirty checkout fails fast. Otherwise a throwaway merge worktree.
#   On failure the reason lands in .artifacts/dev/<id>.fail for the block comment.
#
# Test gate (GSAI-27): NO detectable test command is a hard STOP, not a shrug.
#   Opt out per repo only — .dozers-no-test-gate marker, `no_test_gate: true` in the
#   repo's ecosystem.yaml entry, or TEST_GATE=off for a single deliberate run.
#   Checked THREE times: a PREFLIGHT before the model (GSAI-32 — the answer is already
#   knowable from the checkout, so don't pay for a run that can never merge), again on
#   the task worktree after the agent, and once more at the green-gate.
#
# Model routing: THREE passes, each on its OWN brain — ARCHITECT (spec → DOZER-DESIGN.md),
#   BUILD (implement the design), REVIEW (verdict → DOZER-REVIEW.md). Each resolves its
#   dotted role via dozers/model.sh: models.dev.<pass> → flat models.dev → models.default.
#   Override per-run with DOZER_MODEL_DEV[_<PASS>]="<provider>[:<model>]", or bypass
#   routing entirely by exporting MODEL_CMD (all three passes then share it). A route
#   that can't be satisfied FAILS the crew — no silent fallback.
#
# Time bounds (GSAI-37): every command this crew hands to a repo or a model runs under
#   dozers/timebox.sh — the coding agent, the lockfile install, the test run in the task
#   worktree, the green-gate run, the push. A command that exceeds its bound is killed
#   (whole process group, so a hung grandchild goes too) and the crew FAILS naming the
#   timeout; nothing merges. Knobs: org/config.yaml `timeout_model / _test / _deps /
#   _push`, env DOZER_TIMEOUT_<NAME> per run. Before this a single asleep `pnpm test`
#   held a slot for 8 hours and, through the engine's wave `wait`, every other slot too.
set -euo pipefail
ID="$1"; TITLE="$2"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORKDIR="${WORKDIR:-.}"; DOZER_PERSONA="${DOZER_PERSONA:-}"
OUT="$REPO_ROOT/.artifacts/dev"; mkdir -p "$OUT"

cfg() { grep -E "^$1:" "$REPO_ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true; }
# fail: print the reason AND record it in $OUT/<id>.fail so the engine can put it
# in the block comment (GSAI-26 #3) — Directors shouldn't have to read loop.err.log.
fail() { echo "    [dev] ✗ $*" >&2; printf '%s\n' "$*" > "$OUT/$ID.fail" 2>/dev/null || true; exit 1; }
rm -f "$OUT/$ID.fail" 2>/dev/null || true

# ── Time bounds (GSAI-37) — resolved up front so a bad value fails before any spend ──
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/timebox.sh"
TIMEBOX_CONFIG="$REPO_ROOT/org/config.yaml"
T_MODEL="$(timebox_secs model 3600)" || fail "bad timeout_model / DOZER_TIMEOUT_MODEL"
T_TEST="$(timebox_secs test 900)"    || fail "bad timeout_test / DOZER_TIMEOUT_TEST"
T_DEPS="$(timebox_secs deps 900)"    || fail "bad timeout_deps / DOZER_TIMEOUT_DEPS"
T_PUSH="$(timebox_secs push 300)"    || fail "bad timeout_push / DOZER_TIMEOUT_PUSH"
# run_tests: the one place a test command is executed, so both runs (task worktree and
# green-gate) get the same bound. Returns the command's status; 124 + TIMEBOX_HIT=1 on
# a hang. Callers turn TIMEBOX_HIT into a failure text that NAMES the timeout.
run_tests() {  # $1 = dir, $2 = stage label
  timebox "$T_TEST" "$2 tests (\`$TEST_CMD\`)" "$1" "$TEST_CMD"
}
timed_out_msg() {  # $1 = what, $2 = seconds, $3 = knob name → the failure text for a hang
  printf '%s timed out after %ss (DOZER_TIMEOUT_%s / timeout_%s in org/config.yaml) — killed its process group' \
    "$1" "$2" "${3^^}" "$3"
}

# Symlink uncommitted build deps (node_modules, env files) from the real checkout
# into a worktree so `npm test` resolves them. Needed for BOTH the task worktree
# AND the merge worktree — the green-gate runs tests in the fresh merge worktree,
# which otherwise has no node_modules and reverts every merge (GSAI-23).
#
# Monorepos (GSAI-67): pnpm/npm/yarn workspaces put each package's binaries in
# <pkg>/node_modules/.bin — `vitest` lives in apps/web/node_modules, NOT the root.
# Linking only the root node_modules left every workspace package bare, so the
# gate ran `vitest: command not found` and reverted clean merges. Now every nested
# node_modules in the real checkout (packages/*, apps/*, any depth up to 5, never
# descending INTO a node_modules or .git) is linked at the same relative path —
# only when that package dir exists in the worktree (it's on the branch). The env
# files beside each package are linked the same way.
DEP_ENTRIES=( node_modules .env .env.local .env.development )
link_deps() {  # $1 = target worktree dir
  local d="$1" x pkg rel src nm
  [[ "$(cd "$WORKDIR" 2>/dev/null && pwd -P)" == "$(cd "$d" 2>/dev/null && pwd -P)" ]] && return 0
  link_deps_dir "$WORKDIR" "$d"
  # nested: each package dir in the real checkout that has its own node_modules.
  # (no -mindepth: it would stop -prune applying at depth 1 and find would walk the
  # whole root node_modules; the root entry is skipped in the loop instead.)
  while IFS= read -r nm; do
    [[ -n "$nm" && "$nm" != "$WORKDIR/node_modules" ]] || continue
    pkg="$(dirname "$nm")"; rel="${pkg#"$WORKDIR"/}"
    [[ -d "$d/$rel" ]] || continue     # package not on this branch — nothing to run there
    link_deps_dir "$pkg" "$d/$rel" && echo "    [dev] linked deps for $rel/"
  done < <(find "$WORKDIR" -maxdepth 5 \( -name .git -o -name node_modules \) -prune \
             -name node_modules -print 2>/dev/null)
}
link_deps_dir() {  # $1 = source dir (real checkout), $2 = target dir (worktree)
  local s="$1" t="$2" x
  for x in "${DEP_ENTRIES[@]}"; do
    [[ -e "$s/$x" && ! -e "$t/$x" ]] && ln -s "$s/$x" "$t/$x" 2>/dev/null || true
  done
}

# Deps by lockfile (GSAI-26 #2): a worktree with a package.json but NO node_modules
# (nothing to symlink — the real checkout never had deps installed, e.g. cfw-website)
# would run `npm test` bare → "vitest: command not found" → gate=0 → every merge
# reverted (CFW-31 failed 18 attempts that way). Install from the lockfile first, so
# a failure here is reported as the INSTALL's — never disguised as "merge broke
# develop". No lockfile → no install (a deps-free package.json is legitimate) and the
# test run speaks for itself. DEPS_INSTALL=off disables. Output → $OUT/<id>.deps-<stage>.log
# (never inside the worktree — it may be a live checkout; one log per stage so the
# green-gate's install can't overwrite the task worktree's).
#
# Returns 1 with $DEPS_FAIL_MSG set rather than failing outright (GSAI-124) — the
# green-gate calls this AFTER it has merged, so it must revert before it fails.
# Callers with nothing to undo just `|| fail "$DEPS_FAIL_MSG"`.
DEPS_FAIL_MSG=""
install_deps() {  # $1 = worktree dir, $2 = stage label (also names the log)
  local d="$1" what="$2" cmd log
  DEPS_FAIL_MSG=""; log="$OUT/$ID.deps-${what// /-}.log"
  [[ -f "$d/package.json" ]] || return 0
  [[ -e "$d/node_modules" ]] && return 0
  [[ "${DEPS_INSTALL:-on}" == "off" ]] && { echo "    [dev] $what: deps install off"; return 0; }
  if   [[ -f "$d/pnpm-lock.yaml" ]];    then cmd="pnpm install --frozen-lockfile --prefer-offline"
  elif [[ -f "$d/package-lock.json" ]]; then cmd="npm ci"
  elif [[ -f "$d/yarn.lock" ]];         then cmd="yarn install --frozen-lockfile"
  else echo "    [dev] ⚠ $what: package.json but no lockfile and no node_modules — not installing"; return 0; fi
  echo "    [dev] $what: node_modules missing — $cmd"
  timebox "$T_DEPS" "$what deps install" "$d" "$cmd" >"$log" 2>&1 && return 0
  if (( TIMEBOX_HIT )); then
    DEPS_FAIL_MSG="$(timed_out_msg "$what deps install (\`$cmd\` in $d)" "$T_DEPS" deps) — see $log"
  else
    DEPS_FAIL_MSG="$what deps install failed ($cmd in $d) — see $log; last lines:
$(tail -n 5 "$log" 2>/dev/null | sed 's/^/      /')"
  fi
  return 1
}

# ── Test gate (GSAI-27) ──────────────────────────────────────────────────────
# The Dozer's whole safety claim is "a merge that breaks the integration branch is
# reverted and the task sent back". That claim is VACUOUS when no test command is
# found: the old ladder ended in `⚠ no test command detected — proceeding` and merged
# anyway, with the warning going only to loop.out.log. cfw-social has no `test` script,
# so five merges (CFW-31/93/104/134/173) landed ungated on 2026-09-05 and nothing said
# so. Now an undetectable test command FAILS the crew — the issue lands on
# dozer:blocked with the reason in the Linear comment, and the Director decides.
#
# Opt-out is PER REPO, never a global default (a gate you can switch off everywhere at
# once is not a gate). Any one of:
#   1) a `.dozers-no-test-gate` marker file in the repo (or in the worktree)
#   2) `no_test_gate: true` on that repo's project entry in ~/ecosystem/ecosystem.yaml
#   3) TEST_GATE=off in the env — one deliberate run, set by a Director
TEST_CMD=""   # set by resolve_test_cmd; empty means "waived for this repo"

detect_test_cmd() {  # $1 = dir → echoes the command; returns 1 when there is none
  local d="$1"
  if   [[ -f "$d/package.json" ]] && grep -q '"test"[[:space:]]*:' "$d/package.json"; then echo "npm test"
  elif [[ -f "$d/Makefile" ]] && grep -qE '^test:' "$d/Makefile"; then echo "make test"
  else return 1; fi
}

test_gate_waiver() {  # $1 = dir → echoes WHY the gate is off for this repo, else 1
  local d="$1" flag
  [[ "${TEST_GATE:-on}" == "off" ]] && { echo "TEST_GATE=off for this run"; return 0; }
  [[ -f "$WORKDIR/.dozers-no-test-gate" || -f "$d/.dozers-no-test-gate" ]] \
    && { echo ".dozers-no-test-gate marker in the repo"; return 0; }
  flag="$(python3 "$REPO_ROOT/tasks/ecosystem_workdir.py" --flag no_test_gate --path "$WORKDIR" 2>/dev/null || true)"
  [[ "$flag" == "true" ]] && { echo "no_test_gate: true in ecosystem.yaml"; return 0; }
  return 1
}

# Sets $TEST_CMD for a dir, or explains why there is nothing to run. Returns 1 when
# the gate is ungated AND unwaived, so callers that must clean up first (the
# green-gate has already merged) can revert before failing; $NO_TEST_MSG holds the
# reason. Callers with nothing to undo just `|| fail "$NO_TEST_MSG"`.
NO_TEST_MSG=""
resolve_test_cmd() {  # $1 = dir, $2 = stage label
  local d="$1" stage="$2" why
  TEST_CMD=""; NO_TEST_MSG=""
  if TEST_CMD="$(detect_test_cmd "$d")"; then echo "    [dev] $stage: test command \`$TEST_CMD\`"; return 0; fi
  TEST_CMD=""
  if why="$(test_gate_waiver "$d")"; then
    echo "    [dev] ⚠ $stage: no test command — gate waived for this repo ($why)"; return 0
  fi
  NO_TEST_MSG="$stage: no test command detected in $d — refusing to merge ungated (GSAI-27).
      Add a \`test\` script to package.json (or a \`test:\` target in the Makefile),
      or opt this repo out deliberately: a .dozers-no-test-gate file in the repo,
      \`no_test_gate: true\` on its ecosystem.yaml entry, or TEST_GATE=off for one run."
  return 1
}

# Migration gate (LL-31 guardrail): a change that touches a DB schema MUST ship
# with a matching migration, else deploys drift and break. We block the merge
# BEFORE it happens — fail-fast, sent back to the Director. Globs are configurable
# (org/config.yaml) and default to Prisma; repos with no schema files → no-op.
# Escape hatch: put [skip-migration] in a commit message for a legit schema edit
# that genuinely needs no migration (e.g. a datasource/generator-only change).
migration_gate() {  # $1 = worktree dir, $2 = compare base (integration branch)
  local wt="$1" cmp="$2" changed f g schema_hits="" mig=0 sg mg
  sg="${SCHEMA_GLOBS:-$(cfg schema_globs)}"; sg="${sg:-*.prisma}"
  mg="${MIGRATION_GLOBS:-$(cfg migration_globs)}"; mg="${mg:-*/migrations/* */migrate/*}"
  [[ "${MIGRATION_GATE:-on}" == "off" ]] && { echo "    [dev] migration gate: off"; return 0; }
  read -ra SG_ARR <<< "$sg"; read -ra MG_ARR <<< "$mg"
  changed="$(git -C "$wt" diff --name-only "$cmp"..."$BRANCH" 2>/dev/null || true)"
  [[ -z "$changed" ]] && return 0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    for g in "${MG_ARR[@]}"; do [[ "$f" == $g ]] && mig=1; done
    for g in "${SG_ARR[@]}"; do [[ "$f" == $g ]] && schema_hits+="      $f"$'\n'; done
  done <<< "$changed"
  [[ -z "$schema_hits" ]] && return 0                 # no schema touched → nothing to gate
  (( mig )) && { echo "    [dev] migration gate: schema change ships with a migration ✓"; return 0; }
  if git -C "$wt" log --format=%B "$cmp".."$BRANCH" 2>/dev/null | grep -qF '[skip-migration]'; then
    echo "    [dev] migration gate: schema change, no migration — overridden by [skip-migration]"; return 0
  fi
  fail "schema change with no matching migration (LL-31 guardrail) — add a migration (or [skip-migration] if none is needed); worktree kept, sent back
$schema_hits"
}

cd "$WORKDIR" 2>/dev/null || fail "workdir missing: $WORKDIR"
git rev-parse --git-dir >/dev/null 2>&1 || fail "not a git repo: $WORKDIR"

INTEG="${INTEGRATION_BRANCH:-$(cfg integration_branch)}"; INTEG="${INTEG:-develop}"
# ── Model routing: the lane runs THREE model passes (architect → build → review), each
# on its OWN route, resolved just before the pass runs (see dozers/model.sh + config
# `models:`). A pass's route block is expanded only INSIDE that pass's timebox subshell,
# so its exports (ANTHROPIC_*, the provider token, MODEL_CMD) live exactly as long as
# the pass and never leak back into the crew env the merge/test sections see.
# MODEL_CMD already in the env wins for every pass (legacy/manual override). Otherwise
# the pass's DOTTED role resolves nested → flat lane → models.default. Fail fast: a bad
# provider or a missing key stops the crew — it never silently falls back to claude.
DOZER_ROLE="${DOZER_ROLE:-dev}"
PASS_ROWS=()   # "pass: provider/model" per run, in order — the summary reports all three

_PASS_BLOCK=""; _PASS_DESC=""
resolve_pass() {  # $1 = pass (architect|build|review) → sets _PASS_BLOCK + _PASS_DESC
  local role="$DOZER_ROLE.$1"
  if [[ -n "${MODEL_CMD:-}" ]]; then
    DOZER_MODEL_PROVIDER="${DOZER_MODEL_PROVIDER:-env}"; DOZER_MODEL_NAME="${DOZER_MODEL_NAME:-MODEL_CMD}"
    _PASS_BLOCK=":"; _PASS_DESC="${DOZER_MODEL_PROVIDER}/${DOZER_MODEL_NAME}"
    return 0
  fi
  _PASS_BLOCK="$("$REPO_ROOT/dozers/model.sh" env "$role")" \
    || fail "model routing failed for role '$role'"
  # Desc from a throwaway subshell — the route's exports must not enter the crew env.
  _PASS_DESC="$(eval "$_PASS_BLOCK" >/dev/null; printf '%s/%s' "${DOZER_MODEL_PROVIDER:-?}" "${DOZER_MODEL_NAME:-default}")"
}

# run_model_pass <pass> <prompt> — one agent run under its own route, its own timebox.
run_model_pass() {  # $1 = architect|build|review, $2 = prompt
  resolve_pass "$1"
  echo "    [dev] $1 model: $_PASS_DESC"
  PASS_ROWS+=("$1: $_PASS_DESC")
  if ! _PASS_BLOCK="$_PASS_BLOCK" _PASS_PROMPT="$2" timebox "$T_MODEL" "$1 agent" "$WT" \
       'eval "$_PASS_BLOCK"; eval "$MODEL_CMD \"$_PASS_PROMPT\""'; then
    (( TIMEBOX_HIT )) && fail "$(timed_out_msg "$1 agent" "$T_MODEL" model); worktree kept for resume"
    fail "$1 agent failed (worktree kept for resume)"
  fi
}
PUSH="${PUSH:-$(cfg push)}"
PREFIX="${BRANCH_PREFIX:-$(cfg branch_prefix)}"; PREFIX="${PREFIX:-dozer}"
WT_ROOT="${WORKTREE_ROOT:-$(cfg worktree_root)}"; WT_ROOT="${WT_ROOT:-$HOME/.dozers/worktrees}"; WT_ROOT="${WT_ROOT/#\~/$HOME}"; mkdir -p "$WT_ROOT"
BRANCH="$PREFIX/$ID"; SLUG="$(basename "$WORKDIR")"
WT="$WT_ROOT/$SLUG-$ID"; MW="$WT_ROOT/$SLUG-merge"; STATE="$WT_ROOT/$SLUG-$ID.state"

# Detect, don't impose (GSAI-15 / GSAI-19). If the configured integration branch
# (develop) is absent from THIS repo, fall back to the repo's own default branch so
# trunk-based / main-only repos (brain, ecosystem, dozers, the brand + client folders)
# work unchanged — we never create a develop branch here. Ladder: origin/HEAD → main →
# the checked-out branch. When develop DOES exist (local or remote) behavior is
# identical to before. A detached HEAD with nothing above it on the ladder is NOT a
# branch: `rev-parse --abbrev-ref HEAD` prints the literal "HEAD", and a merge into
# that would land in a throwaway worktree and vanish on cleanup — so it resolves to
# nothing and the crew fails fast below, before any model time is spent.
_default_branch() {
  local d
  d="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; d="${d#refs/remotes/origin/}"
  if [[ -n "$d" ]]; then echo "$d"; return; fi
  if git show-ref --verify --quiet refs/heads/main; then echo "main"; return; fi
  d="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [[ -n "$d" && "$d" != "HEAD" ]] && echo "$d" || true
}
if ! git show-ref --verify --quiet "refs/heads/$INTEG" \
   && ! git show-ref --verify --quiet "refs/remotes/origin/$INTEG"; then
  _fallback="$(_default_branch)"
  [[ -n "$_fallback" ]] || fail "integration branch '$INTEG' absent and no default branch in $WORKDIR (no origin/HEAD, no main, HEAD detached) — check out or configure a branch to merge into, then re-greenlight"
  echo "    [dev] integration branch '$INTEG' absent — using repo default '$_fallback'"
  INTEG="$_fallback"
fi

echo "    [dev] cwd=$(pwd)  integration=$INTEG  branch=$BRANCH"
[[ -n "$DOZER_PERSONA" ]] && echo "    [dev] persona: $DOZER_PERSONA" || true
[[ -f AGENTS.md ]] && echo "    [dev] + project AGENTS.md" || true

if git show-ref --verify --quiet "refs/heads/$INTEG"; then base="$INTEG"; else base="HEAD"; fi

# ── 1. isolate — or RESUME (Seance) if a prior attempt left committed work ──────
RESUMING=0; attempt=1
if [[ -d "$WT" ]] && git -C "$WT" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null 2>&1 \
   && [[ -n "$(git -C "$WT" log --oneline "$base..$BRANCH" 2>/dev/null)" ]]; then
  RESUMING=1; attempt=$(( $(cat "$STATE" 2>/dev/null || echo 1) + 1 )); echo "$attempt" > "$STATE"
  echo "    [dev] RESUMING #$ID (attempt $attempt) — reusing worktree"
  # GSAI-70: the integration branch may have ADVANCED after this worktree was built
  # (`git log "$base..$BRANCH"` alone can't tell — it is non-empty either way, which is
  # why a stale worktree used to resume as-is and then merge-conflict forever). If
  # $base is no longer an ancestor of $BRANCH, rebase the task branch onto the new
  # base BEFORE anything else runs. A rebase that conflicts is ABORTED and reported
  # as "stale base" with the conflicting files named — the Director sees why, and the
  # prior commits are never silently discarded. The path taken is logged either way.
  if git merge-base --is-ancestor "$base" "$BRANCH" 2>/dev/null; then
    echo "    [dev] resume check: base $base has not moved — resuming as-is"
  else
    _old_base="$(git merge-base "$base" "$BRANCH" 2>/dev/null || true)"
    _new_base="$(git rev-parse --verify --short "$base" 2>/dev/null || echo "$base")"
    if _rb_out="$(git -C "$WT" rebase "$base" 2>&1)"; then
      echo "    [dev] base moved — rebased ${_old_base:0:7}..${_new_base}"
    else
      _rb_conflicts="$(git -C "$WT" status --porcelain --untracked-files=no 2>/dev/null \
        | awk '$1 ~ /^(UU|AA|AU|UA|DU|UD|DD)$/ {print $2}' | sort -u | sed 's/^/      /')"
      git -C "$WT" rebase --abort >/dev/null 2>&1 || true
      if [[ -n "$_rb_conflicts" ]]; then
        fail "stale base: $INTEG advanced (${_old_base:0:7} → ${_new_base}) after this worktree was built, and rebasing $BRANCH onto it CONFLICTS — worktree kept, sent back (rebase aborted; nothing discarded). Conflicting files:
$_rb_conflicts"
      else
        fail "stale base: $INTEG advanced (${_old_base:0:7} → ${_new_base}) after this worktree was built, and rebasing $BRANCH onto it failed — worktree kept, sent back (rebase aborted; nothing discarded). git said:
$(printf '%s\n' "$_rb_out" | tail -n 5 | sed 's/^/      /')"
      fi
    fi
  fi
  echo "    [dev]   prior commits on $BRANCH off $base:"
  git -C "$WT" log --oneline "$base..$BRANCH" 2>/dev/null | sed 's/^/          /'
else
  git worktree prune >/dev/null 2>&1 || true
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  _wt_err="$(git worktree add -B "$BRANCH" "$WT" "$base" 2>&1 >/dev/null)" \
    || fail "could not create worktree $WT off $base: ${_wt_err:-unknown git error}"
  echo "    [dev] worktree $WT (off $base)"; echo 1 > "$STATE"
fi

# ── 1b. Test-gate PREFLIGHT (GSAI-32) ──────────────────────────────────────────
# The gate below runs only AFTER the coding agent, so a repo with no detectable test
# command burned a full model run — the single most expensive step in the lane — just
# to be told the merge could never be gated. Nothing about that verdict depends on the
# agent: `detect_test_cmd` reads package.json / Makefile out of the checkout we already
# have. So ask now, and stop before spending anything. Same gate, same waivers, same
# blocked-with-a-reason outcome for the Director — only cheaper and sooner.
#
# Deliberately BEFORE link_deps/install_deps too: an ungatable repo shouldn't pay for
# an `npm ci` either.
#
# One legitimate case would otherwise be locked out: a task whose whole JOB is to add
# the test command (GSAI-30 did exactly that for this repo — under a preflight it would
# have blocked itself before it could ever run). TEST_GATE=bootstrap skips THIS check
# only; the post-agent gate and the green-gate still run in full, so the task still
# blocks unless the agent actually delivered a test command. That is the difference
# from TEST_GATE=off, which waives the gate everywhere for the run.
if [[ "${DRY_RUN:-}" != "1" ]]; then
  if [[ "${TEST_GATE:-on}" == "bootstrap" ]]; then
    echo "    [dev] ⚠ preflight skipped (TEST_GATE=bootstrap) — post-agent gate + green-gate still enforced"
  else
    resolve_test_cmd "$WT" "preflight" || fail "$NO_TEST_MSG
      Caught BEFORE the coding agent ran — no model time was spent (GSAI-32).
      If THIS task is the one that adds the test command, re-greenlight it with
      TEST_GATE=bootstrap, which skips only this preflight and still gates the merge."
  fi
fi

link_deps "$WT"
[[ "${DRY_RUN:-}" == "1" ]] || install_deps "$WT" "task worktree" || fail "$DEPS_FAIL_MSG"

# ── 2. three model passes: ARCHITECT → BUILD → REVIEW (each on its own route) ────
# ARCHITECT turns the spec into DOZER-DESIGN.md; BUILD implements that design (and must
# still clear every existing gate: deps, tests, no-commit); REVIEW judges spec-vs-diff
# and writes DOZER-REVIEW.md whose first line is the verdict. A FAIL verdict buys ONE
# rebuild with the review notes; a second FAIL blocks the task.

# -- prompts ----------------------------------------------------------------------
read -r -d '' ARCH_PROMPT <<EOF || true
You are the ARCHITECT pass of a Dozer dev lane, working inside a dedicated git worktree on branch $BRANCH.
Rules (from $DOZER_PERSONA): read the task spec, then DESIGN the implementation — write
DOZER-DESIGN.md at the worktree root (approach, files to touch, edge cases, how it gets
tested) and commit it. Write and commit ONLY DOZER-DESIGN.md: no code, no other edits.
Do NOT merge, push, switch branches, or remove this worktree.

TASK #$ID: $TITLE
EOF

read -r -d '' BUILD_PROMPT <<EOF || true
You are the BUILD pass of a Dozer dev lane, working inside a dedicated git worktree on branch $BRANCH.
Implement the design in DOZER-DESIGN.md (the architect pass's plan — follow it).
Rules (from $DOZER_PERSONA): do ALL work here; run the project's
tests until green; commit. Do NOT merge, push, switch branches, or remove this worktree.

TASK #$ID: $TITLE
EOF

if (( RESUMING )); then
  _resume_note="RESUMING (attempt $attempt). Prior work is ALREADY committed on $BRANCH:
$(git -C "$WT" log --oneline "$base..$BRANCH")
Continue from there — do NOT redo committed work; finish the pass and commit."
  ARCH_PROMPT="$_resume_note
If DOZER-DESIGN.md is already committed on this branch, review it and amend ONLY if the
design must change (then commit it again); otherwise commit nothing new.

$ARCH_PROMPT"
  BUILD_PROMPT="$_resume_note

$BUILD_PROMPT"
  unset _resume_note
fi

if [[ "${DRY_RUN:-}" == "1" ]]; then
  for _p in architect build review; do
    resolve_pass "$_p"
    echo "    [dev] $_p model: $_PASS_DESC"
    PASS_ROWS+=("$_p: $_PASS_DESC")
  done
  unset _p
  echo "    [dev] DRY_RUN — skipping models$([[ $RESUMING == 1 ]] && echo ' (resume)')"
  printf '# DOZER-DESIGN (dry-run stub)\n' > "$WT/DOZER-DESIGN.md"
  printf 'dozer #%s attempt %s: %s\n' "$ID" "$attempt" "$TITLE" >> "$WT/.dozer-log"
  printf 'VERDICT: PASS\n(dry-run stub review)\n' > "$WT/DOZER-REVIEW.md"
  git -C "$WT" add -A && git -C "$WT" commit -q -m "dozer #$ID: $TITLE (dry-run stub, attempt $attempt)" || true
else
  # -- 2a. ARCHITECT: spec -> DOZER-DESIGN.md -------------------------------------
  run_model_pass architect "$ARCH_PROMPT"
  if [[ -z "${MODEL_CMD:-}" ]]; then
    # The pass was told to write AND commit the design; backstop the commit so the
    # build diff/merge never lose it (still fail-fast on NO design at all).
    [[ -s "$WT/DOZER-DESIGN.md" ]] \
      || fail "architect produced no DOZER-DESIGN.md (worktree kept for resume)"
    git -C "$WT" add DOZER-DESIGN.md 2>/dev/null \
      && git -C "$WT" commit -q -m "dozer #$ID: design (architect pass)" 2>/dev/null || true
  fi

  # -- 2b. BUILD: implement the design + the full downstream gates ----------------
  # Build is a function because a FAILed review triggers exactly ONE rebuild.
  build_once() {  # $1 = extra prompt block (review notes on the rebuild)
    local prompt="$BUILD_PROMPT" anchor
    [[ -n "${1:-}" ]] && prompt="$prompt

$1"
    # The no-commit gate anchors at HEAD *now*: the architect pass commits the design,
    # so diffing against $base would pass vacuously even if the build wrote nothing.
    anchor="$(git -C "$WT" rev-parse HEAD)"
    run_model_pass build "$prompt"
    # no-op if the agent (or link_deps) already provided node_modules
    install_deps "$WT" "task worktree" || fail "$DEPS_FAIL_MSG"
    resolve_test_cmd "$WT" "task worktree" || fail "$NO_TEST_MSG"
    if [[ -n "$TEST_CMD" ]] && ! run_tests "$WT" "task worktree"; then
      (( TIMEBOX_HIT )) && fail "$(timed_out_msg "tests (\`$TEST_CMD\`)" "$T_TEST" test); not merging (worktree kept for resume)"
      fail "tests failed — not merging (worktree kept for resume)"
    fi
    # `if !` not `&&`: build_once is CALLED as a plain command under set -e, so the
    # function's exit status is its last command's — a bare `diff --quiet && fail`
    # would return 1 (diff found the commits) and kill the crew right after a
    # PASSING build. Inside `if`, the diff's status is exempt from set -e.
    if git -C "$WT" diff --quiet "$anchor" -- 2>/dev/null; then
      fail "build agent produced no commits on $BRANCH"
    fi
  }

  # -- 2c. REVIEW: spec + diff -> DOZER-REVIEW.md, first line VERDICT: PASS|FAIL --
  REVIEW_VERDICT=""
  review_once() {
    local vline
    read -r -d '' _rev_prompt <<EOF || true
You are the REVIEW pass of a Dozer dev lane, working inside a dedicated git worktree on branch $BRANCH.
Judge, don't build: change NOTHING except the review file. Given the spec and the diff
of this branch below, decide whether the implementation satisfies the spec and is sound
(DOZER-DESIGN.md is the architect pass's plan — check the build followed it). Then write
DOZER-REVIEW.md at the worktree root whose FIRST LINE is exactly "VERDICT: PASS" or
"VERDICT: FAIL", followed by your reasons, and commit ONLY that file.
Do NOT merge, push, switch branches, or remove this worktree.

TASK #$ID: $TITLE

DIFF ($base..HEAD):
$(git -C "$WT" diff "$base" 2>/dev/null)
EOF
    run_model_pass review "$_rev_prompt"
    unset _rev_prompt
    if [[ -z "${MODEL_CMD:-}" ]]; then
      git -C "$WT" add DOZER-REVIEW.md 2>/dev/null \
        && git -C "$WT" commit -q -m "dozer #$ID: review (review pass)" 2>/dev/null || true
      vline="$(head -n1 "$WT/DOZER-REVIEW.md" 2>/dev/null | tr -d '\r' || true)"
      # A missing or garbled verdict IS a fail — no free pass to merge.
      case "$vline" in
        "VERDICT: PASS") REVIEW_VERDICT="PASS" ;;
        "VERDICT: FAIL") REVIEW_VERDICT="FAIL" ;;
        *)               REVIEW_VERDICT="FAIL" ;;
      esac
      echo "    [dev] review verdict: $REVIEW_VERDICT"
    else
      REVIEW_VERDICT="PASS"   # MODEL_CMD bypass (legacy/tests): no verdict contract
    fi
  }

  build_once ""
  review_once
  if [[ "$REVIEW_VERDICT" == "FAIL" ]]; then
    _notes="$(cat "$WT/DOZER-REVIEW.md" 2>/dev/null || true)"
    echo "    [dev] review failed — one rebuild with the review notes"
    build_once "The REVIEW pass FAILED the previous build. Its notes (DOZER-REVIEW.md):

$_notes

Fix what it names, then run the tests and commit."
    review_once
    if [[ "$REVIEW_VERDICT" == "FAIL" ]]; then
      _notes="$(cat "$WT/DOZER-REVIEW.md" 2>/dev/null || true)"
      fail "review failed TWICE — not merging (worktree kept, sent back). Review notes:
$(printf '%s\n' "$_notes" | head -n 40 | sed 's/^/      /')"
    fi
    unset _notes
  fi
fi

# ── 2b. Migration gate (LL-31): block a schema change with no matching migration ──
migration_gate "$WT" "$base"

# ── 3. Refinery: serialize merges (per-project lock) + green-gate the integration ──
MLOCK="$WT_ROOT/.merge-$SLUG.lock"; _t=$SECONDS
until mkdir "$MLOCK" 2>/dev/null; do (( SECONDS - _t > 300 )) && fail "merge lock busy >5m for $SLUG"; sleep 1; done
trap 'rmdir "$MLOCK" 2>/dev/null || true' EXIT
echo "    [dev] merge lock acquired ($SLUG)"

# Where does the merge happen? A branch can be checked out in only ONE worktree, so
# when $INTEG is already checked out somewhere (the main cfw-social checkout sits on
# develop — GSAI-26 #1) a fresh merge worktree can't take it and every merge failed.
# Merge IN that checkout when it's clean for tracked files; refuse loudly when dirty.
# Never --detach + update-ref: that desyncs the live checkout's index from its branch.
MW_OWNED=1
git worktree prune >/dev/null 2>&1 || true
_integ_at="$(git worktree list --porcelain 2>/dev/null \
  | awk -v b="branch refs/heads/$INTEG" '/^worktree /{p=substr($0,10)} $0==b{print p; exit}')"
if [[ -n "$_integ_at" && "$(cd "$_integ_at" 2>/dev/null && pwd -P)" != "$(cd "$MW" 2>/dev/null && pwd -P)" ]]; then
  if [[ -n "$(git -C "$_integ_at" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    fail "integration branch $INTEG is checked out dirty at $_integ_at; cannot merge — commit or stash there, then re-greenlight"
  fi
  MW="$_integ_at"; MW_OWNED=0
  echo "    [dev] $INTEG is checked out at $MW (clean) — merging there"
else
  git worktree remove --force "$MW" >/dev/null 2>&1 || true
  git worktree add "$MW" "$INTEG" >/dev/null 2>&1 \
    || git worktree add -B "$INTEG" "$MW" "$base" >/dev/null 2>&1 \
    || fail "could not create merge worktree $MW on $INTEG"
fi
PREMERGE="$(git -C "$MW" rev-parse HEAD)"
if git -C "$MW" merge --no-ff "$BRANCH" -m "merge $BRANCH into $INTEG — #$ID $TITLE" >/dev/null 2>&1; then
  echo "    [dev] merged $BRANCH → $INTEG"
else
  git -C "$MW" merge --abort >/dev/null 2>&1 || true
  if git -C "$WT" rebase "$INTEG" >/dev/null 2>&1 && \
     git -C "$MW" merge --no-ff "$BRANCH" -m "merge $BRANCH into $INTEG (rebased) — #$ID" >/dev/null 2>&1; then
    echo "    [dev] merged $BRANCH → $INTEG (after rebase)"
  else
    git -C "$MW" merge --abort >/dev/null 2>&1 || true
    fail "merge conflict on $BRANCH → $INTEG — worktree kept, sent back"
  fi
fi
# Deps for the green-gate are provisioned on the POST-merge tree (GSAI-124) — the
# exact tree the gate is about to test. They used to be provisioned BEFORE the merge,
# while $MW still sat on the untouched integration branch, which silently skipped the
# one case that needs them most: the task that adds a repo's FIRST package.json. The
# pre-merge tree had no package.json to install from, so install_deps returned early;
# the merge then brought package.json in and the gate ran `npm test` bare → "command
# not found" → the merge was reverted and the issue blocked with the flatly wrong
# reason "merge broke develop". Same for link_deps: a branch that adds a new workspace
# package only gets that package's deps linked once its dir is actually on the tree.
link_deps "$MW"   # so the green-gate's `npm test` has node_modules — else every merge reverts

# green-gate: the integration branch must STILL pass after the merge, else revert it.
# The same hole is closed here (GSAI-27): a merge with nothing to run is NOT green,
# it is unverified — revert it and send the task back, exactly as a red one.
#
# The merge has already happened at this point, so every rung below reports through
# $gate_why and lets the single revert-and-fail at the bottom undo it — including the
# deps install, whose failure must be named AS the install and never mistaken for a
# broken integration branch.
GATE_WAIVED=0
if [[ "${DRY_RUN:-}" != "1" ]]; then
  gate=1; gate_why=""
  if ! install_deps "$MW" "green-gate"; then
    gate=0; gate_why="$DEPS_FAIL_MSG"
  elif ! resolve_test_cmd "$MW" "green-gate"; then
    gate=0; gate_why="$NO_TEST_MSG"
  elif [[ -z "$TEST_CMD" ]]; then
    GATE_WAIVED=1
  elif ! run_tests "$MW" "green-gate"; then
    gate=0
    # A hang on the integration branch is not "red", it is unverified — same outcome
    # (revert + send back) but the reason must say TIMEOUT, not "broke develop".
    if (( TIMEBOX_HIT )); then gate_why="$(timed_out_msg "green-gate tests (\`$TEST_CMD\` on $INTEG)" "$T_TEST" test)"
    else gate_why="merge broke $INTEG"; fi
  fi
  if (( ! gate )); then
    git -C "$MW" reset --hard "$PREMERGE" >/dev/null 2>&1 || true
    fail "$gate_why — reverted to keep $INTEG green; task sent back"
  fi
  (( GATE_WAIVED )) && echo "    [dev] green-gate: waived (no test command, opted out)" \
                    || echo "    [dev] green-gate: $INTEG still passing after merge"
fi
if [[ "$PUSH" == "true" ]]; then
  if timebox "$T_PUSH" "push" "$MW" "git push origin \"$INTEG\" >/dev/null 2>&1"; then echo "    [dev] pushed $INTEG"
  elif (( TIMEBOX_HIT )); then echo "    [dev] ⚠ push timed out after ${T_PUSH}s (DOZER_TIMEOUT_PUSH / timeout_push) — $INTEG merged locally, not pushed"
  else echo "    [dev] ⚠ push failed"; fi
fi

# ── 4. cleanup (success): drop worktrees + branch + state; merge lock released on EXIT ──
(( MW_OWNED )) && { git worktree remove --force "$MW" >/dev/null 2>&1 || true; }
git worktree remove --force "$WT" >/dev/null 2>&1 || true
git branch -D "$BRANCH" >/dev/null 2>&1 || true
rm -f "$STATE" 2>/dev/null || true

cat > "$OUT/$ID.md" <<EOF
# DEV result for #$ID
task: $TITLE
project: $WORKDIR
branch: $BRANCH → $INTEG (merged, green-gated, cleaned up)
EOF
if [[ "${DRY_RUN:-}" == "1" ]]; then agent_line="stub commit (dry-run)"; tests_line="skipped (dry-run)"; gate_line="skipped (dry-run)"
elif (( GATE_WAIVED )); then agent_line="implemented + committed"; tests_line="no test command — gate waived for this repo"; gate_line="not verified (test gate opted out)"
else agent_line="implemented + committed"; tests_line="gate passed"; gate_line="$INTEG green after merge"; fi
_models=""; for _p in "${PASS_ROWS[@]:-}"; do [[ -n "$_p" ]] && _models+="${_models:+ · }$_p"; done; unset _p
cat > "$OUT/$ID.summary" <<EOF
- Picked up: $TITLE$([[ $RESUMING == 1 ]] && echo " (RESUMED, attempt $attempt)")
- models (architect → build → review): ${_models:-unresolved}
- Worktree $BRANCH off $INTEG (isolated)
- Coding agent: $agent_line
- Tests: $tests_line
- Merge: serialized (per-project lock) + green-gate — $gate_line
- Merged → $INTEG$( (( MW_OWNED )) || echo " (in existing checkout $MW)" ); worktree + branch cleaned
EOF
echo "    [dev] done #$ID"
