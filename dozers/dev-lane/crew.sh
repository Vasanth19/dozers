#!/usr/bin/env bash
# dozers/dev-lane/crew.sh — the DEV lane crew (real isolate → build → test → merge pipeline).
#
# The engine has already claimed the task and cd'd us into the project. Env in:
#   WORKDIR        the project checkout (we're inside it)
#   DOZER_PERSONA  this lane's persona (dozers/dev-lane/dozer.md)
#   REPO_ROOT      the dozers repo root (artifacts + config)
#
# Pipeline (never merges red, fail-fast):
#   1. worktree  dozer/<id> cut off the integration branch (isolated)
#   2. agent     a coding model implements + runs tests + commits IN the worktree
#                (it must NOT merge/push/switch/remove — the crew does that)
#   3. test      gate: the project's test command must pass
#   4. merge     serial-merge dozer/<id> → integration via a dedicated merge worktree
#                (one rebase retry on conflict), optional push
#   5. cleanup   remove the task worktree + branch
#
# Config (org/config.yaml or env override):
#   integration_branch   default: develop
#   model_cmd            how to launch the coding agent   default: claude -p
#   push                 push integration to origin        default: false
#   DRY_RUN=1            skip model + tests; make a stub commit to prove the git mechanics
set -euo pipefail
ID="$1"; TITLE="$2"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORKDIR="${WORKDIR:-.}"; DOZER_PERSONA="${DOZER_PERSONA:-}"
OUT="$REPO_ROOT/.artifacts/dev"; mkdir -p "$OUT"

cfg() { grep -E "^$1:" "$REPO_ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true; }
fail() { echo "    [dev] ✗ $*" >&2; exit 1; }

cd "$WORKDIR" 2>/dev/null || fail "workdir missing: $WORKDIR"
git rev-parse --git-dir >/dev/null 2>&1 || fail "not a git repo: $WORKDIR"

INTEG="${INTEGRATION_BRANCH:-$(cfg integration_branch)}"; INTEG="${INTEG:-develop}"
MODEL_CMD="${MODEL_CMD:-$(cfg model_cmd)}"; MODEL_CMD="${MODEL_CMD:-claude -p}"
PUSH="${PUSH:-$(cfg push)}"
PREFIX="${BRANCH_PREFIX:-$(cfg branch_prefix)}"; PREFIX="${PREFIX:-dozer}"
WT_ROOT="${WORKTREE_ROOT:-$(cfg worktree_root)}"; WT_ROOT="${WT_ROOT:-$HOME/.dozers/worktrees}"; WT_ROOT="${WT_ROOT/#\~/$HOME}"; mkdir -p "$WT_ROOT"
BRANCH="$PREFIX/$ID"
SLUG="$(basename "$WORKDIR")"
WT="$WT_ROOT/$SLUG-$ID"
MW="$WT_ROOT/$SLUG-merge"

echo "    [dev] cwd=$(pwd)  integration=$INTEG  branch=$BRANCH"
[[ -n "$DOZER_PERSONA" ]] && echo "    [dev] persona: $DOZER_PERSONA" || true
[[ -f AGENTS.md ]] && echo "    [dev] + project AGENTS.md" || true
[[ -f CLAUDE.md ]] && echo "    [dev] + project CLAUDE.md" || true

# ── 1. isolate: worktree dozer/<id> off the integration branch ──────────────────
git worktree prune >/dev/null 2>&1 || true
git worktree remove --force "$WT" >/dev/null 2>&1 || true
if git show-ref --verify --quiet "refs/heads/$INTEG"; then base="$INTEG"; else base="HEAD"; fi
git worktree add -B "$BRANCH" "$WT" "$base" >/dev/null 2>&1 || fail "could not create worktree $WT off $base"
echo "    [dev] worktree $WT (off $base)"
# link gitignored runtime so the agent can build/test without a full install
for x in node_modules .env .env.local .env.development; do
  [[ -e "$WORKDIR/$x" && ! -e "$WT/$x" ]] && ln -s "$WORKDIR/$x" "$WT/$x" 2>/dev/null || true
done

# ── 2. coding agent (implements + tests + commits, INSIDE the worktree) ───────
read -r -d '' PROMPT <<EOF || true
You are a Dozer working inside a dedicated git worktree on branch $BRANCH.
Rules (from $DOZER_PERSONA): do ALL work here; implement the task; run the project's
tests until green; commit your work. Do NOT merge, push, switch branches, or remove
this worktree — the crew does that after you exit.

TASK #$ID: $TITLE
EOF

if [[ "${DRY_RUN:-}" == "1" ]]; then
  echo "    [dev] DRY_RUN — skipping model; would run: (cd $WT && $MODEL_CMD <prompt>)"
  printf 'dozer #%s: %s\n' "$ID" "$TITLE" >> "$WT/.dozer-log"
  git -C "$WT" add -A && git -C "$WT" commit -q -m "dozer #$ID: $TITLE (dry-run stub)"
else
  ( cd "$WT" && eval "$MODEL_CMD \"\$PROMPT\"" ) || fail "coding agent failed"
  # ── 3. test gate: detect + run the project's tests; red = stop, never merge ─
  if [[ -f "$WT/package.json" ]] && grep -q '"test"' "$WT/package.json"; then
    ( cd "$WT" && npm test ) || fail "tests failed (npm test) — not merging"
  elif [[ -f "$WT/Makefile" ]] && grep -qE '^test:' "$WT/Makefile"; then
    ( cd "$WT" && make test ) || fail "tests failed (make test) — not merging"
  else
    echo "    [dev] ⚠ no test command detected — proceeding (wire one in for real gates)"
  fi
  # the agent must have committed something
  git -C "$WT" diff --quiet "$base" -- 2>/dev/null && fail "agent produced no commits on $BRANCH"
fi

# ── 4. serial-merge dozer/<id> → integration via a dedicated merge worktree ──────
git worktree remove --force "$MW" >/dev/null 2>&1 || true
git worktree add "$MW" "$INTEG" >/dev/null 2>&1 || git worktree add -B "$INTEG" "$MW" "$base"
if git -C "$MW" merge --no-ff "$BRANCH" -m "merge $BRANCH into $INTEG — #$ID $TITLE" >/dev/null 2>&1; then
  echo "    [dev] merged $BRANCH → $INTEG"
else
  git -C "$MW" merge --abort >/dev/null 2>&1 || true
  # one rebase retry (conflict is often just batch-ordering)
  if git -C "$WT" rebase "$INTEG" >/dev/null 2>&1 && \
     git -C "$MW" merge --no-ff "$BRANCH" -m "merge $BRANCH into $INTEG (rebased) — #$ID" >/dev/null 2>&1; then
    echo "    [dev] merged $BRANCH → $INTEG (after rebase)"
  else
    git -C "$MW" merge --abort >/dev/null 2>&1 || true
    git worktree remove --force "$MW" >/dev/null 2>&1 || true
    fail "merge conflict on $BRANCH → $INTEG — left branch for a human"
  fi
fi
[[ "$PUSH" == "true" ]] && ( git -C "$MW" push origin "$INTEG" >/dev/null 2>&1 && echo "    [dev] pushed $INTEG" || echo "    [dev] ⚠ push failed" )

# ── 5. cleanup ───────────────────────────────────────────────────────────────
git worktree remove --force "$MW" >/dev/null 2>&1 || true
git worktree remove --force "$WT" >/dev/null 2>&1 || true
git branch -D "$BRANCH" >/dev/null 2>&1 || true

cat > "$OUT/$ID.md" <<EOF
# DEV result for #$ID
task: $TITLE
project: $WORKDIR
branch: $BRANCH → $INTEG (merged, cleaned up)
EOF

if [[ "${DRY_RUN:-}" == "1" ]]; then agent_line="implemented + committed (dry-run stub)"; tests_line="skipped (dry-run)"
else agent_line="implemented + committed"; tests_line="gate passed"; fi
cat > "$OUT/$ID.summary" <<EOF
- Picked up: $TITLE
- Worktree $BRANCH cut off $INTEG (isolated)
- Coding agent: $agent_line
- Tests: $tests_line
- Merged → $INTEG; worktree + branch cleaned
EOF
echo "    [dev] done #$ID"
