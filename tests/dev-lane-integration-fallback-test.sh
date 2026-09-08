#!/usr/bin/env bash
# tests/dev-lane-integration-fallback-test.sh — regression test for GSAI-15 / GSAI-19.
#
# The dev lane cuts dozer/<id> off the configured integration branch (`develop`) and
# merges back into it. Brain, ecosystem, dozers, the brand + client folders are all
# main-only: no develop branch. Before the fix the crew either failed to create the
# task worktree (DEL-1/2 in the 2026-09-01 dry-run) or, via the merge-worktree
# fallback, CREATED a develop branch — imposing gitflow on a trunk-based repo.
#
# Contract under test (detect, don't impose):
#   DEVELOP  — a repo WITH develop is unchanged: cut off develop, merge into develop
#   MAIN     — a main-only repo (main checked out, the brain/ecosystem shape): cut off
#              main, merge lands on main IN that checkout, and NO develop branch is
#              ever created
#   ORIGIN   — no develop, no main, but origin/HEAD names the default → use that
#   ENV      — INTEGRATION_BRANCH=develop set explicitly still falls back when absent
#   DETACHED — no develop, no main, no origin/HEAD, detached HEAD → the crew FAILS with
#              a clear reason; it never merges into a throwaway detached worktree where
#              the commit would be lost on cleanup
#
# Each case runs the REAL crew with a stub coding agent against a fresh fixture repo.
# Run:  bash tests/dev-lane-integration-fallback-test.sh   (non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -f "$ROOT"/.artifacts/dev/TEST-IB* 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# ── fixtures ──────────────────────────────────────────────────────────────────
# A throwaway repo on branch $2 with a Makefile `test:` target (so the test gate is
# satisfied without npm). Nothing else — no develop unless the case adds one.
mkrepo() {  # $1 = dir, $2 = initial branch name
  local d="$1" b="$2"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b "$b" .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'test:\n\t@true\n' > Makefile
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m "init" )
}
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOA'
#!/usr/bin/env bash
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOA
chmod +x "$STUB"
# run the crew: $1=id $2=proj $3=wt-root $4=log ; extra env via caller.
# INTEGRATION_BRANCH is deliberately NOT set here — the crew must read org/config.yaml
# (`develop`) exactly as it does in production.
crew() { REPO_ROOT="$ROOT" WORKDIR="$2" WORKTREE_ROOT="$3" MODEL_CMD="bash $STUB" PUSH="false" \
         DOZER_PERSONA="test" bash "$CREW" "$1" "integration fallback" >"$4" 2>&1; }
head_subject() { git -C "$1" log -1 --format=%s "$2" 2>/dev/null || true; }
has_branch()   { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }

# ── DEVELOP: develop exists → unchanged ───────────────────────────────────────
echo "DEVELOP: repo with develop → still cuts off develop and merges into develop"
PD="$TMP/pd"; mkrepo "$PD" main; git -C "$PD" branch develop; LD="$TMP/d.log"; rc=0
MAIN_D="$(git -C "$PD" rev-parse main)"
crew TEST-IB-D "$PD" "$TMP/wt-d" "$LD" || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$LD"; }
! grep -q "integration branch 'develop' absent" "$LD" && ok "no fallback taken" || no "fallback taken although develop exists"
grep -q "integration=develop " "$LD" && ok "integration branch is develop" || no "integration branch is not develop"
[[ "$(head_subject "$PD" develop)" == merge*TEST-IB-D* ]] && ok "merge landed on develop" || no "develop HEAD is not the merge: '$(head_subject "$PD" develop)'"
[[ "$(git -C "$PD" rev-parse main)" == "$MAIN_D" ]] && ok "main untouched" || no "main moved"

# ── MAIN: main-only, main checked out (brain / ecosystem / dozers shape) ───────
echo "MAIN: main-only repo (main checked out) → cuts off main, merges into main, never creates develop"
PM="$TMP/pm"; mkrepo "$PM" main; LM="$TMP/m.log"; rc=0
crew TEST-IB-M "$PM" "$TMP/wt-m" "$LM" || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$LM"; }
grep -q "integration branch 'develop' absent — using repo default 'main'" "$LM" && ok "fallback to main logged" || { no "fallback not logged"; dump "$LM"; }
grep -q "worktree .* (off main)" "$LM" && ok "task worktree cut off main" || no "task worktree not cut off main"
grep -q "main is checked out at .* (clean) — merging there" "$LM" && ok "merged in the live main checkout" || no "did not merge in the live checkout"
[[ "$(head_subject "$PM" main)" == merge*TEST-IB-M* ]] && ok "merge commit landed on main" || no "main HEAD is not the merge: '$(head_subject "$PM" main)'"
grep -q "dozer change" "$PM/feature.txt" && ok "live working tree carries the change" || no "live working tree stale"
[[ "$(git -C "$PM" rev-parse --abbrev-ref HEAD)" == "main" ]] && ok "live checkout still on main" || no "live checkout branch changed"
! has_branch "$PM" develop && ok "no develop branch was created" || no "a develop branch was created (gitflow imposed)"
! has_branch "$PM" dozer/TEST-IB-M && ok "task branch cleaned up" || no "task branch left behind"
[[ -z "$(git -C "$PM" status --porcelain --untracked-files=no)" ]] && ok "live checkout left clean" || no "live checkout left dirty"
grep -q "Merged → main" "$ROOT/.artifacts/dev/TEST-IB-M.summary" 2>/dev/null && ok "summary reports the merge target as main" || no "summary does not name main"

# ── ORIGIN: no develop, no main; origin/HEAD → trunk ──────────────────────────
echo "ORIGIN: no develop, no main, origin/HEAD=trunk → uses trunk"
PO_REMOTE="$TMP/po-remote"; mkrepo "$PO_REMOTE" trunk
PO="$TMP/po"; git clone -q "$PO_REMOTE" "$PO"
git -C "$PO" config user.email test@dozer; git -C "$PO" config user.name dozer-test
[[ "$(git -C "$PO" symbolic-ref refs/remotes/origin/HEAD)" == "refs/remotes/origin/trunk" ]] || { echo "  ✗ fixture: origin/HEAD is not trunk" >&2; exit 1; }
LO="$TMP/o.log"; rc=0
crew TEST-IB-O "$PO" "$TMP/wt-o" "$LO" || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$LO"; }
grep -q "integration branch 'develop' absent — using repo default 'trunk'" "$LO" && ok "fallback to trunk (origin/HEAD) logged" || { no "fallback to trunk not logged"; dump "$LO"; }
[[ "$(head_subject "$PO" trunk)" == merge*TEST-IB-O* ]] && ok "merge landed on trunk" || no "trunk HEAD is not the merge: '$(head_subject "$PO" trunk)'"
! has_branch "$PO" develop && ok "no develop branch created" || no "a develop branch was created"
! has_branch "$PO" main && ok "no main branch invented" || no "a main branch was invented"
[[ "$(git -C "$PO_REMOTE" rev-parse trunk)" == "$(git -C "$PO_REMOTE" rev-parse trunk)" && "$(head_subject "$PO_REMOTE" trunk)" == "init" ]] && ok "remote untouched (push=false)" || no "remote trunk moved despite push=false"

# ── ENV: INTEGRATION_BRANCH=develop set explicitly → still falls back ─────────
echo "ENV: INTEGRATION_BRANCH=develop in env on a main-only repo → still falls back to main"
PE="$TMP/pe"; mkrepo "$PE" main; LE="$TMP/e.log"; rc=0
INTEGRATION_BRANCH=develop crew TEST-IB-E "$PE" "$TMP/wt-e" "$LE" || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$LE"; }
grep -q "using repo default 'main'" "$LE" && ok "fallback to main logged" || no "fallback not logged"
[[ "$(head_subject "$PE" main)" == merge*TEST-IB-E* ]] && ok "merge landed on main" || no "main HEAD is not the merge"

# ── DETACHED: nothing to fall back to → fail fast, no silent detached merge ───
echo "DETACHED: no develop, no main, no origin/HEAD, detached HEAD → clear failure"
PX="$TMP/px"; mkrepo "$PX" work
git -C "$PX" checkout -q --detach; LX="$TMP/x.log"; rc=0
crew TEST-IB-X "$PX" "$TMP/wt-x" "$LX" || rc=$?
[[ $rc -ne 0 ]] && ok "crew failed (rc=$rc)" || { no "crew succeeded with nothing to merge into"; dump "$LX"; }
grep -q "no default branch" "$LX" && ok "failure names the missing default branch" || { no "no clear reason in the log"; dump "$LX"; }
grep -q "no default branch" "$ROOT/.artifacts/dev/TEST-IB-X.fail" 2>/dev/null && ok "reason recorded in .fail artifact" || no ".fail artifact missing/empty"
! has_branch "$PX" develop && ok "no develop branch created" || no "a develop branch was created"
[[ "$(head_subject "$PX" work)" == "init" ]] && ok "the only branch is untouched" || no "branch 'work' moved: '$(head_subject "$PX" work)'"
[[ ! -d "$TMP/wt-x/px-merge" ]] && ok "no throwaway merge worktree left" || no "merge worktree left behind"

if [[ $fail == 0 ]]; then echo "dev-lane-integration-fallback-test: PASS"; else echo "dev-lane-integration-fallback-test: FAIL" >&2; exit 1; fi
