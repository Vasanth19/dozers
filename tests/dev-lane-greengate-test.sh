#!/usr/bin/env bash
# tests/dev-lane-greengate-test.sh — regression test for GSAI-23.
#
# The dev-lane green-gate re-runs `npm test` in a FRESH merge worktree after
# merging. Build deps (node_modules) are NOT committed — they live only in the
# real checkout — so if they aren't symlinked into the merge worktree the gate
# runs with no deps, fails, and REVERTS every merge (the cfw-website blocker).
#
# This test drives the actual crew end-to-end against a throwaway repo whose
# `test` script passes ONLY when node_modules is present. It proves a green
# task lands on the integration branch instead of being reverted.
#
# Run:  bash tests/dev-lane-greengate-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"
command -v npm >/dev/null 2>&1 || { echo "SKIP: npm not installed" >&2; exit 0; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# ── a throwaway project whose test needs an UNCOMMITTED node_modules ──────────
PROJ="$TMP/proj"; mkdir -p "$PROJ"; cd "$PROJ"
git init -q -b main .
git config user.email test@dozer && git config user.name dozer-test
printf 'node_modules\n' > .gitignore   # no trailing slash: also ignores the dep symlink
# `npm test` passes only if node_modules/.installed exists in the worktree.
printf '{\n  "name":"proj","version":"1.0.0",\n  "scripts":{"test":"test -f node_modules/.installed"}\n}\n' > package.json
printf 'seed\n' > feature.txt
git add -A && git commit -q -m "init"
git branch develop                       # integration branch, not checked out
mkdir node_modules && : > node_modules/.installed   # build artifact — never committed

# ── stub coding agent: makes one real commit inside the worktree ──────────────
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOS
chmod +x "$STUB"

# ── run the real crew (green-gate active: DRY_RUN unset) ──────────────────────
LOG="$TMP/crew.log"; rc=0
REPO_ROOT="$TMP" WORKDIR="$PROJ" \
  WORKTREE_ROOT="$TMP/wt" INTEGRATION_BRANCH="develop" \
  MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" \
  bash "$CREW" "TEST-GG1" "green-gate dep link" >"$LOG" 2>&1 || rc=$?

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

[[ $rc -eq 0 ]] && ok "crew exited clean (gate passed, no revert)" \
  || { no "crew exited $rc — gate reverted the merge"; sed 's/^/    | /' "$LOG" >&2; }

# develop must have advanced to a merge commit that carries the agent's change.
DEV_HEAD_MSG="$(git -C "$PROJ" log -1 --format=%s develop 2>/dev/null || true)"
[[ "$DEV_HEAD_MSG" == merge*TEST-GG1* ]] && ok "merge commit landed on develop" \
  || no "develop HEAD is not the expected merge: '$DEV_HEAD_MSG'"

git -C "$PROJ" grep -q "dozer change" develop -- feature.txt 2>/dev/null \
  && ok "agent's change is present on develop" \
  || no "agent's change missing from develop"

if [[ $fail == 0 ]]; then echo "dev-lane-greengate-test: PASS"; else echo "dev-lane-greengate-test: FAIL" >&2; exit 1; fi
