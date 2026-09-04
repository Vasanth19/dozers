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
# Env: WORKDIR, DOZER_PERSONA, REPO_ROOT. Config: integration_branch, model_cmd, push,
#   branch_prefix, worktree_root. DRY_RUN=1 stubs the model + tests.
set -euo pipefail
ID="$1"; TITLE="$2"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORKDIR="${WORKDIR:-.}"; DOZER_PERSONA="${DOZER_PERSONA:-}"
OUT="$REPO_ROOT/.artifacts/dev"; mkdir -p "$OUT"

cfg() { grep -E "^$1:" "$REPO_ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true; }
fail() { echo "    [dev] ✗ $*" >&2; exit 1; }

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
MODEL_CMD="${MODEL_CMD:-$(cfg model_cmd)}"; MODEL_CMD="${MODEL_CMD:-claude -p}"
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
  git worktree add -B "$BRANCH" "$WT" "$base" >/dev/null 2>&1 || fail "could not create worktree $WT off $base"
  echo "    [dev] worktree $WT (off $base)"; echo 1 > "$STATE"
fi
link_deps "$WT"

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

git worktree remove --force "$MW" >/dev/null 2>&1 || true
git worktree add "$MW" "$INTEG" >/dev/null 2>&1 || git worktree add -B "$INTEG" "$MW" "$base"
link_deps "$MW"   # so the green-gate's `npm test` has node_modules — else every merge reverts
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
git worktree remove --force "$MW" >/dev/null 2>&1 || true
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
- Worktree $BRANCH off $INTEG (isolated)
- Coding agent: $agent_line
- Tests: $tests_line
- Merge: serialized (per-project lock) + green-gate — $gate_line
- Merged → $INTEG; worktree + branch cleaned
EOF
echo "    [dev] done #$ID"
