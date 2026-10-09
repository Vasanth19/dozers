#!/usr/bin/env bash
# tests/dev-lane-turbopack-deps-test.sh — regression test for GSAI-261.
#
# Turbopack (`next dev --turbo` / `next build --turbopack`, default since Next.js 15)
# refuses to resolve any module whose REAL path falls outside the project root it
# auto-detects from the nearest lockfile. A symlinked node_modules always fails that
# check: `realpath()` on the link resolves back to the real checkout, which sits in a
# completely different directory tree from the worktree. This fired on the FIRST
# `npm test`/`next build` call in every Next.js/Turbopack repo — the test gate died in
# seconds, before a single test ran.
#
# The fix clones node_modules (APFS `cp -Rc`) into the worktree instead of symlinking
# it, so every file resolves to a real path physically inside the worktree — the same
# root the lockfile already puts it in.
#
# This drives the real crew end to end with the real checkout and the worktree root in
# TWO SEPARATE tmp trees (not just separate subdirs of one tmp dir), so a symlink
# across them is unambiguously a cross-filesystem-tree link, exactly like a real
# Dozer worktree (~/.dozers/worktrees/<repo>-<issue>) vs. a real checkout anywhere
# else. A fake `npm` stands in for the real one: `ci` provisions node_modules, `test`
# fails EXACTLY the way Turbopack's root-boundary check fails — comparing node_modules'
# resolved real path against the resolved cwd, not merely checking `-L`. That means this
# test is RED against the pre-fix crew.sh (symlinked node_modules resolves outside the
# worktree → rejected) and GREEN after the fix (cloned node_modules resolves inside it).
#
# Run:  bash tests/dev-lane-turbopack-deps-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="${CREW:-$ROOT/dozers/dev-lane/crew.sh}"

HOST_TMP="$(mktemp -d)"     # the "real checkout" lives here
WT_TMP="$(mktemp -d)"       # a DIFFERENT tmp tree — stands in for ~/.dozers/worktrees
cleanup() { rm -rf "$HOST_TMP" "$WT_TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# ── fake npm: `ci` provisions node_modules; `test` fails/passes on the SAME
# root-boundary check Turbopack does — resolved node_modules path vs. resolved cwd,
# not a simple `-L` check (a symlinked node_modules IS a dir once you `cd` into it,
# so only comparing resolved paths catches the real bug) ──────────────────────────
mkdir -p "$HOST_TMP/bin"
cat > "$HOST_TMP/bin/npm" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  ci|install)
    mkdir -p node_modules && : > node_modules/.installed
    echo "added 1 package"; exit 0 ;;
  test)
    real_nm="$(cd node_modules 2>/dev/null && pwd -P)"
    want_nm="$(pwd -P)/node_modules"
    if [[ "$real_nm" != "$want_nm" ]]; then
      echo "Error: Module not found — node_modules resolves to '$real_nm', outside of the project root '$(pwd -P)'" >&2
      exit 1
    fi
    [[ -f node_modules/.installed ]] || { echo "sh: next: command not found" >&2; exit 127; }
    echo "1 passed"; exit 0 ;;
esac
exit 0
EOS
chmod +x "$HOST_TMP/bin/npm"

# ── a throwaway Next.js-shaped repo: package.json + lockfile, host already has
# node_modules "installed" (so the fast/clone path is the one under test, not a
# fresh npm ci) ────────────────────────────────────────────────────────────────
PROJ="$HOST_TMP/proj"; mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email test@dozer && git -C "$PROJ" config user.name dozer-test
printf 'node_modules\n' > "$PROJ/.gitignore"   # no trailing slash: ignores a clone exactly like it ignored a link
printf '{"name":"proj","version":"1.0.0","scripts":{"test":"next build --turbopack"}}\n' > "$PROJ/package.json"
printf '{"name":"proj","version":"1.0.0","lockfileVersion":3,"packages":{}}\n' > "$PROJ/package-lock.json"
printf 'seed\n' > "$PROJ/feature.txt"
git -C "$PROJ" add -A && git -C "$PROJ" commit -q -m init
git -C "$PROJ" branch develop                  # integration branch, not checked out

mkdir -p "$PROJ/node_modules" && : > "$PROJ/node_modules/.installed"

# ── stub coding agent: one real commit inside the task worktree ───────────────
STUB="$HOST_TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOS
chmod +x "$STUB"

# ── run the real crew (green-gate active: DRY_RUN unset) ──────────────────────
LOG="$HOST_TMP/crew.log"; rc=0
env PATH="$HOST_TMP/bin:$PATH" \
  REPO_ROOT="$HOST_TMP" WORKDIR="$PROJ" \
  WORKTREE_ROOT="$WT_TMP/wt" INTEGRATION_BRANCH="develop" \
  MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" \
  bash "$CREW" "TEST-TBPK1" "turbopack node_modules root check" >"$LOG" 2>&1 || rc=$?

[[ $rc -eq 0 ]] && ok "crew exited clean — node_modules resolved inside the worktree's own root" \
  || { no "crew exited $rc — the Turbopack-style root-boundary check rejected node_modules (this is the GSAI-261 bug if seen against unpatched crew.sh)"
       sed 's/^/    | /' "$LOG" >&2; }

DEV_HEAD_MSG="$(git -C "$PROJ" log -1 --format=%s develop 2>/dev/null || true)"
[[ "$DEV_HEAD_MSG" == merge*TEST-TBPK1* ]] && ok "merge commit landed on develop" \
  || no "develop HEAD is not the expected merge: '$DEV_HEAD_MSG'"

git -C "$PROJ" grep -q "dozer change" develop -- feature.txt 2>/dev/null \
  && ok "agent's change is present on develop" \
  || no "agent's change missing from develop"

if [[ $fail == 0 ]]; then echo "dev-lane-turbopack-deps-test: PASS"; else echo "dev-lane-turbopack-deps-test: FAIL" >&2; exit 1; fi
