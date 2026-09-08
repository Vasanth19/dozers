#!/usr/bin/env bash
# tests/dev-lane-monorepo-deps-test.sh — regression test for GSAI-67.
#
# In a workspace monorepo (pnpm/npm/yarn workspaces) each package has its OWN
# node_modules — `vitest` lives in packages/web/node_modules/.bin, not the root.
# link_deps used to symlink only the root node_modules into the task + merge
# worktrees, so the root `npm test` (which fans out to the packages) ran with the
# package binaries missing → "vitest: command not found" → the green-gate reverted
# a perfectly clean merge.
#
# This drives the real crew against a throwaway monorepo whose root `test` script
# passes ONLY when BOTH the root and the package node_modules are present, and
# asserts the merge lands on develop instead of being reverted. It also checks that
# the root node_modules is not walked (a nested node_modules INSIDE it is never
# linked as if it were a package).
#
# Run:  bash tests/dev-lane-monorepo-deps-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"
command -v npm >/dev/null 2>&1 || { echo "SKIP: npm not installed" >&2; exit 0; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# ── a throwaway monorepo: root + packages/web, each with UNCOMMITTED node_modules ─
PROJ="$TMP/proj"; mkdir -p "$PROJ/packages/web" "$PROJ/packages/api"; cd "$PROJ"
git init -q -b main .
git config user.email test@dozer && git config user.name dozer-test
printf 'node_modules\n.env.local\n' > .gitignore   # no trailing slash: also ignores the dep symlinks
# root test = what a workspace runner does: run each package's test in its own dir,
# and that package's test needs ITS node_modules/.bin/vitest.
printf '{\n  "name":"mono","version":"1.0.0","workspaces":["packages/*"],\n  "scripts":{"test":"test -f node_modules/.installed && (cd packages/web && npm test) && (cd packages/api && npm test)"}\n}\n' > package.json
printf '{\n  "name":"web","version":"1.0.0",\n  "scripts":{"test":"test -x node_modules/.bin/vitest && node_modules/.bin/vitest"}\n}\n' > packages/web/package.json
printf '{\n  "name":"api","version":"1.0.0",\n  "scripts":{"test":"test -f ../../node_modules/.installed"}\n}\n' > packages/api/package.json
printf 'seed\n' > feature.txt
git add -A && git commit -q -m "init"
git branch develop                       # integration branch, not checked out

# build artifacts — never committed:
mkdir -p node_modules/hoisted/node_modules && : > node_modules/.installed   # root (+ a nested one INSIDE it)
mkdir -p packages/web/node_modules/.bin                                     # per-package binaries
printf '#!/usr/bin/env bash\necho "vitest ok"\n' > packages/web/node_modules/.bin/vitest
chmod +x packages/web/node_modules/.bin/vitest
printf 'WEB_SECRET=1\n' > packages/web/.env.local                           # per-package env file
# packages/api deliberately has NO node_modules (a workspace that only uses hoisted deps)

# ── stub coding agent: makes one real commit inside the worktree, and records
# what link_deps put there (the worktree is reaped on success, so probe it now).
STUB="$TMP/stub-agent.sh"; PROBE="$TMP/probe"
cat > "$STUB" <<EOS2
#!/usr/bin/env bash
{
  [[ -L packages/web/node_modules ]]      && echo web-nm-linked
  [[ -L packages/web/.env.local ]]        && echo web-env-linked
  [[ ! -e packages/api/node_modules ]]    && echo api-untouched
  git status --porcelain --ignored packages/web/node_modules | grep -q '^!!' && echo web-nm-ignored
} > "$PROBE"
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOS2
chmod +x "$STUB"

# ── run the real crew (green-gate active: DRY_RUN unset) ──────────────────────
LOG="$TMP/crew.log"; rc=0
REPO_ROOT="$TMP" WORKDIR="$PROJ" \
  WORKTREE_ROOT="$TMP/wt" INTEGRATION_BRANCH="develop" \
  MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" \
  bash "$CREW" "TEST-MONO1" "monorepo dep link" >"$LOG" 2>&1 || rc=$?

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

[[ $rc -eq 0 ]] && ok "crew exited clean (gate passed, no revert)" \
  || { no "crew exited $rc — gate reverted the merge"; sed 's/^/    | /' "$LOG" >&2; }

DEV_HEAD_MSG="$(git -C "$PROJ" log -1 --format=%s develop 2>/dev/null || true)"
[[ "$DEV_HEAD_MSG" == merge*TEST-MONO1* ]] && ok "merge commit landed on develop" \
  || no "develop HEAD is not the expected merge: '$DEV_HEAD_MSG'"

git -C "$PROJ" grep -q "dozer change" develop -- feature.txt 2>/dev/null \
  && ok "agent's change is present on develop" \
  || no "agent's change missing from develop"

# What the stub agent saw inside the task worktree (same link_deps path as the merge worktree).
grep -qx web-nm-linked "$PROBE"  2>/dev/null && ok "packages/web/node_modules linked into the worktree" \
  || no "packages/web/node_modules NOT linked"
grep -qx web-env-linked "$PROBE" 2>/dev/null && ok "packages/web/.env.local linked into the worktree" \
  || no "packages/web/.env.local NOT linked"
grep -qx api-untouched "$PROBE"  2>/dev/null && ok "packages/api (no deps in checkout) left alone" \
  || no "packages/api/node_modules unexpectedly created"
grep -qx web-nm-ignored "$PROBE" 2>/dev/null && ok "package node_modules symlink is git-ignored (never committed)" \
  || no "package node_modules symlink not ignored"
grep -q "linked deps for packages/web/" "$LOG" && ok "crew logged the packages/web link" \
  || no "crew log has no 'linked deps for packages/web/' line"
grep -q "linked deps for node_modules/" "$LOG" && no "find walked INTO the root node_modules" \
  || ok "root node_modules pruned, not walked"

if [[ $fail == 0 ]]; then echo "dev-lane-monorepo-deps-test: PASS"; else echo "dev-lane-monorepo-deps-test: FAIL" >&2; exit 1; fi
