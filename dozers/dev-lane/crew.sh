#!/usr/bin/env bash
# dozers/dev-lane/crew.sh — DEV lane crew: isolate/RESUME → agent → test → serial-merge
# (per-project merge lock + green-gate) → cleanup. Fail-fast; never merges red.
#
# Resilience (inspired by gastown):
#   • Seance (resume): if a prior attempt left COMMITTED work in this task's worktree
#     (e.g. a crash), REUSE the worktree and tell the agent to continue — not restart.
#     The reaper leaves worktrees intact on failure precisely so this can happen.
#   • Refinery (merge queue): merges to the integration branch are serialized by a
#     per-project lock, and each merge is GREEN-GATED — verified on the integration
#     branch after merging; a merge that breaks it is reverted and the task sent back.
#
# Env: WORKDIR, DOZER_PERSONA, REPO_ROOT. Config: integration_branch, push,
#   branch_prefix, worktree_root. DRY_RUN=1 stubs the model + tests (+ deps install).
#   DEPS_INSTALL=off skips the lockfile install that otherwise runs when a worktree
#   has a package.json but no node_modules (GSAI-26).
#
# Merge target (GSAI-26): if the integration branch is already checked out somewhere
#   (e.g. the main checkout sits on develop) the merge happens IN that checkout when
#   it's clean; a dirty checkout fails fast. Otherwise a throwaway merge worktree.
#   On failure the reason lands in .artifacts/dev/<id>.fail for the block comment.
#
# Model routing: the brain this lane runs on comes from org/config.yaml `models.dev`
#   (provider + model), resolved by dozers/model.sh. Override per-run with
#   DOZER_MODEL_DEV="<provider>[:<model>]" (e.g. ollama-cloud:glm-5.2), or bypass
#   routing entirely by exporting MODEL_CMD. A route that can't be satisfied FAILS the
#   crew — no silent fallback.
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

# Symlink uncommitted build deps (node_modules, env files) from the real checkout
# into a worktree so `npm test` resolves them. Needed for BOTH the task worktree
# AND the merge worktree — the green-gate runs tests in the fresh merge worktree,
# which otherwise has no node_modules and reverts every merge (GSAI-23).
link_deps() {  # $1 = target worktree dir
  local d="$1" x
  for x in node_modules .env .env.local .env.development; do
    [[ -e "$WORKDIR/$x" && ! -e "$d/$x" ]] && ln -s "$WORKDIR/$x" "$d/$x" 2>/dev/null || true
  done
}

# Deps by lockfile (GSAI-26 #2): a worktree with a package.json but NO node_modules
# (nothing to symlink — the real checkout never had deps installed, e.g. cfw-website)
# would run `npm test` bare → "vitest: command not found" → gate=0 → every merge
# reverted (CFW-31 failed 18 attempts that way). Install from the lockfile first, so
# a failure here is reported as the INSTALL's — never disguised as "merge broke
# develop". No lockfile → no install (a deps-free package.json is legitimate) and the
# test run speaks for itself. DEPS_INSTALL=off disables. Output → $OUT/<id>.deps.log
# (never inside the worktree — it may be a live checkout).
install_deps() {  # $1 = worktree dir, $2 = label for the failure message
  local d="$1" what="$2" cmd
  [[ -f "$d/package.json" ]] || return 0
  [[ -e "$d/node_modules" ]] && return 0
  [[ "${DEPS_INSTALL:-on}" == "off" ]] && { echo "    [dev] $what: deps install off"; return 0; }
  if   [[ -f "$d/pnpm-lock.yaml" ]];    then cmd="pnpm install --frozen-lockfile --prefer-offline"
  elif [[ -f "$d/package-lock.json" ]]; then cmd="npm ci"
  elif [[ -f "$d/yarn.lock" ]];         then cmd="yarn install --frozen-lockfile"
  else echo "    [dev] ⚠ $what: package.json but no lockfile and no node_modules — not installing"; return 0; fi
  echo "    [dev] $what: node_modules missing — $cmd"
  ( cd "$d" && $cmd ) >"$OUT/$ID.deps.log" 2>&1 \
    || fail "$what deps install failed ($cmd in $d) — see $OUT/$ID.deps.log; last lines:
$(tail -n 5 "$OUT/$ID.deps.log" 2>/dev/null | sed 's/^/      /')"
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
# ── Model routing: which brain runs this lane (see dozers/model.sh + config `models:`).
# MODEL_CMD already in the env wins (legacy/manual override). Otherwise resolve the
# ROLE's route — fail fast: a bad provider or a missing key stops the crew, it never
# silently falls back to claude.
DOZER_ROLE="${DOZER_ROLE:-dev}"
if [[ -n "${MODEL_CMD:-}" ]]; then
  DOZER_MODEL_PROVIDER="${DOZER_MODEL_PROVIDER:-env}"; DOZER_MODEL_NAME="${DOZER_MODEL_NAME:-MODEL_CMD}"
else
  _route="$("$REPO_ROOT/dozers/model.sh" env "$DOZER_ROLE")" || fail "model routing failed for role '$DOZER_ROLE'"
  eval "$_route"; unset _route
fi
MODEL_DESC="${DOZER_MODEL_PROVIDER:-claude}/${DOZER_MODEL_NAME:-default}"
PUSH="${PUSH:-$(cfg push)}"
PREFIX="${BRANCH_PREFIX:-$(cfg branch_prefix)}"; PREFIX="${PREFIX:-dozer}"
WT_ROOT="${WORKTREE_ROOT:-$(cfg worktree_root)}"; WT_ROOT="${WT_ROOT:-$HOME/.dozers/worktrees}"; WT_ROOT="${WT_ROOT/#\~/$HOME}"; mkdir -p "$WT_ROOT"
BRANCH="$PREFIX/$ID"; SLUG="$(basename "$WORKDIR")"
WT="$WT_ROOT/$SLUG-$ID"; MW="$WT_ROOT/$SLUG-merge"; STATE="$WT_ROOT/$SLUG-$ID.state"

# Detect, don't impose. If the configured integration branch (e.g. develop) is
# absent from THIS repo, fall back to the repo's own default branch so trunk-based
# / main-only repos work unchanged — we never create a develop branch here. When
# develop DOES exist (local or remote) behavior is identical to before.
_default_branch() {
  local d
  d="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; d="${d#refs/remotes/origin/}"
  if [[ -n "$d" ]]; then echo "$d"; return; fi
  if git show-ref --verify --quiet refs/heads/main; then echo "main"; return; fi
  git rev-parse --abbrev-ref HEAD 2>/dev/null
}
if ! git show-ref --verify --quiet "refs/heads/$INTEG" \
   && ! git show-ref --verify --quiet "refs/remotes/origin/$INTEG"; then
  _fallback="$(_default_branch)"
  [[ -n "$_fallback" ]] || fail "integration branch '$INTEG' absent and no default branch in $WORKDIR"
  echo "    [dev] integration branch '$INTEG' absent — using repo default '$_fallback'"
  INTEG="$_fallback"
fi

echo "    [dev] cwd=$(pwd)  integration=$INTEG  branch=$BRANCH"
echo "    [dev] model: $MODEL_DESC"
[[ -n "$DOZER_PERSONA" ]] && echo "    [dev] persona: $DOZER_PERSONA" || true
[[ -f AGENTS.md ]] && echo "    [dev] + project AGENTS.md" || true

if git show-ref --verify --quiet "refs/heads/$INTEG"; then base="$INTEG"; else base="HEAD"; fi

# ── 1. isolate — or RESUME (Seance) if a prior attempt left committed work ──────
RESUMING=0; attempt=1
if [[ -d "$WT" ]] && git -C "$WT" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null 2>&1 \
   && [[ -n "$(git -C "$WT" log --oneline "$base..$BRANCH" 2>/dev/null)" ]]; then
  RESUMING=1; attempt=$(( $(cat "$STATE" 2>/dev/null || echo 1) + 1 )); echo "$attempt" > "$STATE"
  echo "    [dev] RESUMING #$ID (attempt $attempt) — reusing worktree; prior commits:"
  git -C "$WT" log --oneline "$base..$BRANCH" 2>/dev/null | sed 's/^/          /'
else
  git worktree prune >/dev/null 2>&1 || true
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  _wt_err="$(git worktree add -B "$BRANCH" "$WT" "$base" 2>&1 >/dev/null)" \
    || fail "could not create worktree $WT off $base: ${_wt_err:-unknown git error}"
  echo "    [dev] worktree $WT (off $base)"; echo 1 > "$STATE"
fi
link_deps "$WT"
[[ "${DRY_RUN:-}" == "1" ]] || install_deps "$WT" "task worktree"

# ── 2. coding agent (implements + tests + commits INSIDE the worktree) ─────────
read -r -d '' PROMPT <<EOF || true
You are a Dozer working inside a dedicated git worktree on branch $BRANCH.
Rules (from $DOZER_PERSONA): do ALL work here; implement the task; run the project's
tests until green; commit. Do NOT merge, push, switch branches, or remove this worktree.

TASK #$ID: $TITLE
EOF
if (( RESUMING )); then
  PROMPT="RESUMING (attempt $attempt). Prior work is ALREADY committed on $BRANCH:
$(git -C "$WT" log --oneline "$base..$BRANCH")
Continue from there — do NOT redo committed work; finish the task and commit.

$PROMPT"
fi

if [[ "${DRY_RUN:-}" == "1" ]]; then
  echo "    [dev] DRY_RUN — skipping model$([[ $RESUMING == 1 ]] && echo ' (resume)')"
  printf 'dozer #%s attempt %s: %s\n' "$ID" "$attempt" "$TITLE" >> "$WT/.dozer-log"
  git -C "$WT" add -A && git -C "$WT" commit -q -m "dozer #$ID: $TITLE (dry-run stub, attempt $attempt)" || true
else
  ( cd "$WT" && eval "$MODEL_CMD \"\$PROMPT\"" ) || fail "coding agent failed (worktree kept for resume)"
  install_deps "$WT" "task worktree"   # no-op if the agent (or link_deps) already provided node_modules
  if [[ -f "$WT/package.json" ]] && grep -q '"test"' "$WT/package.json"; then
    ( cd "$WT" && npm test ) || fail "tests failed — not merging (worktree kept for resume)"
  elif [[ -f "$WT/Makefile" ]] && grep -qE '^test:' "$WT/Makefile"; then
    ( cd "$WT" && make test ) || fail "tests failed — not merging (worktree kept for resume)"
  else echo "    [dev] ⚠ no test command detected — proceeding"; fi
  git -C "$WT" diff --quiet "$base" -- 2>/dev/null && fail "agent produced no commits on $BRANCH"
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
link_deps "$MW"   # so the green-gate's `npm test` has node_modules — else every merge reverts
[[ "${DRY_RUN:-}" == "1" ]] || install_deps "$MW" "green-gate"
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
# green-gate: the integration branch must STILL pass after the merge, else revert it.
if [[ "${DRY_RUN:-}" != "1" ]]; then
  gate=1
  if [[ -f "$MW/package.json" ]] && grep -q '"test"' "$MW/package.json"; then ( cd "$MW" && npm test ) || gate=0
  elif [[ -f "$MW/Makefile" ]] && grep -qE '^test:' "$MW/Makefile"; then ( cd "$MW" && make test ) || gate=0; fi
  if (( ! gate )); then
    git -C "$MW" reset --hard "$PREMERGE" >/dev/null 2>&1 || true
    fail "merge broke $INTEG — reverted to keep it green; task sent back"
  fi
  echo "    [dev] green-gate: $INTEG still passing after merge"
fi
[[ "$PUSH" == "true" ]] && ( git -C "$MW" push origin "$INTEG" >/dev/null 2>&1 && echo "    [dev] pushed $INTEG" || echo "    [dev] ⚠ push failed" )

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
else agent_line="implemented + committed"; tests_line="gate passed"; gate_line="$INTEG green after merge"; fi
cat > "$OUT/$ID.summary" <<EOF
- Picked up: $TITLE$([[ $RESUMING == 1 ]] && echo " (RESUMED, attempt $attempt)")
- model: $MODEL_DESC
- Worktree $BRANCH off $INTEG (isolated)
- Coding agent: $agent_line
- Tests: $tests_line
- Merge: serialized (per-project lock) + green-gate — $gate_line
- Merged → $INTEG$( (( MW_OWNED )) || echo " (in existing checkout $MW)" ); worktree + branch cleaned
EOF
echo "    [dev] done #$ID"
