#!/usr/bin/env bash
# tests/dev-lane-host-hygiene-test.sh — regression test for GSAI-257.
#
# GSAI-26's dirty check on the "merge in the existing host checkout" path
# (crew.sh host_checkout_hygiene) was only a dirty check, with three blind spots:
#   1. `2>/dev/null` turned a failing `git status` into silent "clean".
#   2. No in-progress-operation check — a paused rebase/cherry-pick can have a
#      perfectly clean tree and still must not be merged into / tested in.
#   3. `--untracked-files=no` ignored untracked debris that then rode straight into
#      the green-gate's test run, judging a tree that wasn't purely $INTEG's history.
#
# Each case runs the REAL crew against a fresh throwaway repo. Run:
#   bash tests/dev-lane-host-hygiene-test.sh   (non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"
command -v npm >/dev/null 2>&1 || { echo "SKIP: npm not installed" >&2; exit 0; }

TMP="$(mktemp -d)"
BOARD="$ROOT/tasks/board"
cleanup() {
  rm -f "$BOARD"/*/HYG-*.md 2>/dev/null || true
  rm -f "$ROOT"/.artifacts/dev/HYG-* 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# ── fixtures (same shape as dev-lane-merge-target-test.sh) ────────────────────
mkproj() {
  local d="$1" deps="$2"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    printf '{\n  "name":"proj","version":"1.0.0",\n  "scripts":{"test":"test -f node_modules/.installed"}\n}\n' > package.json
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m "init"
    git checkout -q -b develop
    [[ "$deps" == "with-deps" ]] && { mkdir node_modules && : > node_modules/.installed; } || true
  )
}
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOA'
#!/usr/bin/env bash
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOA
chmod +x "$STUB"
# run the crew: $1=id $2=proj $3=wt-root $4=log ; extra env via caller
crew() { REPO_ROOT="$ROOT" WORKDIR="$2" WORKTREE_ROOT="$3" INTEGRATION_BRANCH="develop" \
         MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" bash "$CREW" "$1" "host hygiene" >"$4" 2>&1; }

# ── case 1: fast path unchanged — clean + node_modules → merges exactly as before ──
echo "case 1: host checkout clean with node_modules (GSAI-26 fast path) → merges"
P1="$TMP/p1"; mkproj "$P1" with-deps; L1="$TMP/c1.log"; rc=0
crew HYG-1 "$P1" "$TMP/wt1" "$L1" || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$L1"; }
grep -q "is checked out at .* (clean) — merging there" "$L1" && ok "crew merged in the existing checkout" || { no "crew did not detect the existing checkout"; dump "$L1"; }
[[ "$(git -C "$P1" log -1 --format=%s develop)" == merge*HYG-1* ]] && ok "merge commit landed on develop" || no "develop HEAD is not the merge"

# ── case 2: stray untracked file (not in DEP_ENTRIES) blocks the merge ────────
echo "case 2: stray untracked file at the root → hygiene blocks the merge"
P2="$TMP/p2"; mkproj "$P2" with-deps; L2="$TMP/c2.log"; rc=0
printf 'leftover\n' > "$P2/scratch.txt"      # untracked, not node_modules/.env*
PRE2="$(git -C "$P2" rev-parse develop)"
crew HYG-2 "$P2" "$TMP/wt2" "$L2" || rc=$?
[[ $rc -ne 0 ]] && ok "crew failed (rc=$rc)" || { no "crew succeeded against a debris-laden checkout"; dump "$L2"; }
grep -q "unexpected untracked files" "$L2" && ok "failure names the hygiene problem" || { no "no hygiene-failure message"; dump "$L2"; }
grep -q "scratch.txt" "$L2" && ok "failure names scratch.txt" || { no "scratch.txt not named in the failure"; dump "$L2"; }
[[ "$(git -C "$P2" rev-parse develop)" == "$PRE2" ]] && ok "develop untouched" || no "develop moved"
git -C "$P2" rev-parse --verify -q refs/heads/dozer/HYG-2 >/dev/null && ok "task branch kept for resume" || no "task branch dropped"
[[ -f "$P2/scratch.txt" ]] && ok "scratch.txt left in place (no auto-clean)" || no "scratch.txt was removed"

# ── case 3: mid-rebase checkout with a clean tree blocks the merge ────────────
# A REAL `git rebase -i` detaches HEAD (git-worktree-list then reports no branch for
# this checkout, so it wouldn't even be selected as $_integ_at — the design's own
# "detached-HEAD mid-rebase" edge case). To exercise check 2 (the case that matters:
# the branch stays attached — e.g. paused via --onto without detaching), fabricate
# the exact marker git rebase itself leaves, WITHOUT touching HEAD, on an otherwise
# clean, still-attached-to-develop tree.
echo "case 3: host checkout mid-rebase (clean tree, branch still attached) → hygiene blocks the merge"
P3="$TMP/p3"; mkproj "$P3" with-deps; L3="$TMP/c3.log"; rc=0
mkdir -p "$P3/.git/rebase-merge"
echo "refs/heads/develop" > "$P3/.git/rebase-merge/head-name"
git -C "$P3" rev-parse HEAD > "$P3/.git/rebase-merge/onto"
cp "$P3/.git/rebase-merge/onto" "$P3/.git/rebase-merge/orig-head"
echo "noop HEAD" > "$P3/.git/rebase-merge/git-rebase-todo"
[[ "$(git -C "$P3" rev-parse --abbrev-ref HEAD)" == "develop" ]] || { no "fixture precondition failed: HEAD not attached to develop"; }
[[ -z "$(git -C "$P3" status --porcelain --untracked-files=no)" ]] || { no "fixture precondition failed: tree not clean"; }
PRE3="$(git -C "$P3" rev-parse develop)"
crew HYG-3 "$P3" "$TMP/wt3" "$L3" || rc=$?
[[ $rc -ne 0 ]] && ok "crew failed (rc=$rc)" || { no "crew succeeded against a mid-rebase checkout"; dump "$L3"; }
grep -q "mid-rebase" "$L3" && ok "failure names mid-rebase" || { no "no mid-rebase message"; dump "$L3"; }
[[ "$(git -C "$P3" rev-parse develop)" == "$PRE3" ]] && ok "develop untouched" || no "develop moved"

# ── case 4: git status itself fails → named read error, never silent "clean" ──
echo "case 4: git status fails outright → named read error, not a silent pass"
P4="$TMP/p4"; mkproj "$P4" with-deps; L4="$TMP/c4.log"; rc=0
BIN4="$TMP/bin4"; mkdir -p "$BIN4"
REAL_GIT="$(command -v git)"
P4_REAL="$(cd "$P4" && pwd -P)"   # git worktree list reports the realpath (/private/... on macOS)
cat > "$BIN4/git" <<EOG
#!/usr/bin/env bash
# fail ONLY "git -C \$P4 status ..." — any other dir (the task worktree, the merge
# worktree) must keep working, or the crew's OWN internal status reads elsewhere
# break and the failure gets misattributed.
if [[ "\$1" == "-C" && ( "\$2" == "$P4" || "\$2" == "$P4_REAL" ) && "\$3" == "status" ]]; then
  echo "fatal: simulated index corruption" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOG
chmod +x "$BIN4/git"
PRE4="$(git -C "$P4" rev-parse develop)"
rc=0
PATH="$BIN4:$PATH" crew HYG-4 "$P4" "$TMP/wt4" "$L4" || rc=$?
[[ $rc -ne 0 ]] && ok "crew failed (rc=$rc)" || { no "crew succeeded despite a failing git status"; dump "$L4"; }
grep -q "could not be read" "$L4" && ok "failure names a read error" || { no "no read-error message"; dump "$L4"; }
! grep -q "checked out dirty" "$L4" && ok "not silently scored as clean" || no "read failure fell through to a clean verdict"
[[ "$(git -C "$P4" rev-parse develop)" == "$PRE4" ]] && ok "develop untouched" || no "develop moved"

# ── case 5: escape hatches honored, and name which waiver fired ───────────────
echo "case 5a: stray file + HYGIENE_GATE=off → merges, logs the waiver"
P5A="$TMP/p5a"; mkproj "$P5A" with-deps; L5A="$TMP/c5a.log"; rc=0
printf 'leftover\n' > "$P5A/scratch.txt"
HYGIENE_GATE=off crew HYG-5A "$P5A" "$TMP/wt5a" "$L5A" || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$L5A"; }
grep -q "gate waived (HYGIENE_GATE=off for this run)" "$L5A" && ok "log names the HYGIENE_GATE=off waiver" || { no "waiver not logged"; dump "$L5A"; }
[[ "$(git -C "$P5A" log -1 --format=%s develop)" == merge*HYG-5A* ]] && ok "merge landed on develop" || no "merge missing"

echo "case 5b: stray file + .dozers-no-hygiene-gate marker → merges, logs the waiver"
P5B="$TMP/p5b"; mkproj "$P5B" with-deps; L5B="$TMP/c5b.log"; rc=0
printf 'leftover\n' > "$P5B/scratch.txt"
: > "$P5B/.dozers-no-hygiene-gate"
crew HYG-5B "$P5B" "$TMP/wt5b" "$L5B" || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$L5B"; }
grep -q "gate waived (.dozers-no-hygiene-gate marker in the repo)" "$L5B" && ok "log names the marker waiver" || { no "waiver not logged"; dump "$L5B"; }
[[ "$(git -C "$P5B" log -1 --format=%s develop)" == merge*HYG-5B* ]] && ok "merge landed on develop" || no "merge missing"

if [[ $fail == 0 ]]; then echo "dev-lane-host-hygiene-test: PASS"; else echo "dev-lane-host-hygiene-test: FAIL" >&2; exit 1; fi
