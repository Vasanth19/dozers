#!/usr/bin/env bash
# tests/dev-lane-merge-target-test.sh — regression test for GSAI-26.
#
# Three harness defects blocked every cfw-social / cfw-website merge on 2026-09-05:
#   1. `git worktree add $MW develop` fails when develop is ALREADY checked out (the
#      main checkout sits on it) → the merge must happen IN that checkout if clean,
#      and refuse loudly if dirty.
#   2. The green-gate ran `npm test` in a worktree with NO node_modules (nothing to
#      symlink from a checkout whose deps were never installed) → every merge
#      reverted → deps must be installed from the lockfile first; an install failure
#      must be reported as such, not as "merge broke develop".
#   3. The block comment carried no reason → the crew's fail() message must reach it.
#
# Each case runs the REAL crew (or the real engine, files backend) against a fresh
# throwaway repo. Run:  bash tests/dev-lane-merge-target-test.sh  (non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"
command -v npm >/dev/null 2>&1 || { echo "SKIP: npm not installed" >&2; exit 0; }

TMP="$(mktemp -d)"
BOARD="$ROOT/tasks/board"
cleanup() {
  rm -f "$BOARD"/*/MTT-*.md 2>/dev/null || true
  rm -f "$ROOT"/.artifacts/dev/MTT-* "$ROOT"/.artifacts/dev/TEST-MT* 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# ── fixtures ──────────────────────────────────────────────────────────────────
# A throwaway project: package.json whose `test` passes only when node_modules/.installed
# exists (deps are never committed). $1 = dir, $2 = "checkout-develop" | "branch-only",
# $3 = "with-deps" | "no-deps".
mkproj() {
  local d="$1" mode="$2" deps="$3"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    printf '{\n  "name":"proj","version":"1.0.0",\n  "scripts":{"test":"test -f node_modules/.installed"}\n}\n' > package.json
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m "init"
    if [[ "$mode" == "checkout-develop" ]]; then git checkout -q -b develop; else git branch develop; fi
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
         MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" bash "$CREW" "$1" "merge target" >"$4" 2>&1; }

# ── case 1: develop checked out in the main repo + CLEAN → merge lands THERE ──
echo "case 1: develop checked out elsewhere (clean) → merges in that checkout"
P1="$TMP/p1"; mkproj "$P1" checkout-develop with-deps; L1="$TMP/c1.log"; rc=0
crew TEST-MT1 "$P1" "$TMP/wt1" "$L1" || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$L1"; }
grep -q "is checked out at .* (clean) — merging there" "$L1" && ok "crew merged in the existing checkout" || no "crew did not detect the existing checkout"
[[ "$(git -C "$P1" rev-parse --abbrev-ref HEAD)" == "develop" ]] && ok "main checkout still on develop" || no "main checkout branch changed"
[[ "$(git -C "$P1" log -1 --format=%s develop)" == merge*TEST-MT1* ]] && ok "merge commit landed on develop" || no "develop HEAD is not the merge: $(git -C "$P1" log -1 --format=%s develop)"
grep -q "dozer change" "$P1/feature.txt" && ok "live working tree carries the change (index in sync)" || no "live working tree stale"
[[ -z "$(git -C "$P1" status --porcelain --untracked-files=no)" ]] && ok "main checkout left clean" || no "main checkout left dirty"
[[ ! -d "$TMP/wt1/p1-merge" ]] && ok "no throwaway merge worktree created" || no "merge worktree created despite existing checkout"
[[ -d "$P1" ]] && ok "existing checkout NOT removed on cleanup" || no "existing checkout was removed!"

# ── case 1b: same, DRY_RUN=1 (the spec's acceptance check) ────────────────────
echo "case 1b: develop checked out elsewhere, DRY_RUN=1 → merges"
P1B="$TMP/p1b"; mkproj "$P1B" checkout-develop no-deps; L1B="$TMP/c1b.log"; rc=0
DRY_RUN=1 crew TEST-MT1B "$P1B" "$TMP/wt1b" "$L1B" || rc=$?
[[ $rc -eq 0 ]] && ok "DRY_RUN crew exited clean" || { no "DRY_RUN crew exited $rc"; dump "$L1B"; }
[[ "$(git -C "$P1B" log -1 --format=%s develop)" == merge*TEST-MT1B* ]] && ok "DRY_RUN merge landed on develop" || no "DRY_RUN merge missing"

# ── case 2: develop checked out DIRTY → clear failure, nothing touched ─────────
echo "case 2: develop checked out elsewhere (dirty) → clear failure"
P2="$TMP/p2"; mkproj "$P2" checkout-develop with-deps; L2="$TMP/c2.log"; rc=0
printf 'uncommitted edit\n' >> "$P2/feature.txt"      # tracked file modified → dirty
PRE2="$(git -C "$P2" rev-parse develop)"
crew TEST-MT2 "$P2" "$TMP/wt2" "$L2" || rc=$?
[[ $rc -ne 0 ]] && ok "crew failed (rc=$rc)" || no "crew succeeded against a dirty checkout"
grep -q "integration branch develop is checked out dirty at" "$L2" && ok "failure names the dirty checkout" || { no "no dirty-checkout message"; dump "$L2"; }
grep -q "checked out dirty" "$ROOT/.artifacts/dev/TEST-MT2.fail" 2>/dev/null && ok "reason recorded in .fail artifact" || no ".fail artifact missing/empty"
[[ "$(git -C "$P2" rev-parse develop)" == "$PRE2" ]] && ok "develop untouched" || no "develop moved"
grep -q "uncommitted edit" "$P2/feature.txt" && ok "user's uncommitted edit preserved" || no "uncommitted edit lost"
git -C "$P2" rev-parse --verify -q refs/heads/dozer/TEST-MT2 >/dev/null && ok "task branch kept for resume" || no "task branch dropped"
[[ ! -d "$TMP/wt2/.merge-p2.lock" ]] && ok "merge lock released" || no "merge lock leaked"

# ── case 3: deps missing everywhere → installed from lockfile, then gated ──────
echo "case 3: no node_modules anywhere + pnpm-lock.yaml → installed, merged"
P3="$TMP/p3"; mkproj "$P3" branch-only no-deps
( cd "$P3" && : > pnpm-lock.yaml && git add -A && git commit -q -m "lockfile" && git branch -f develop main )
BIN="$TMP/bin"; mkdir -p "$BIN"; COUNT="$TMP/pnpm.count"; : > "$COUNT"
cat > "$BIN/pnpm" <<'EOP'
#!/usr/bin/env bash
# stub package manager: `pnpm install ...` materialises node_modules/.installed;
# fails on the call number named in PNPM_FAIL_ON (to exercise the install-failure path).
n=$(( $(wc -l < "$PNPM_COUNT") + 1 )); echo "$n $PWD $*" >> "$PNPM_COUNT"
[[ "$1" == "install" ]] || { echo "stub pnpm: unexpected args $*" >&2; exit 2; }
[[ "${PNPM_FAIL_ON:-0}" == "$n" ]] && { echo "ERR_PNPM_STUB simulated install failure" >&2; exit 1; }
mkdir -p node_modules && : > node_modules/.installed
EOP
chmod +x "$BIN/pnpm"
L3="$TMP/c3.log"; rc=0
PATH="$BIN:$PATH" PNPM_COUNT="$COUNT" crew TEST-MT3 "$P3" "$TMP/wt3" "$L3" || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$L3"; }
grep -q "task worktree: node_modules missing — pnpm install --frozen-lockfile --prefer-offline" "$L3" && ok "task worktree deps installed by lockfile" || no "task worktree install not logged"
grep -q "green-gate: node_modules missing — pnpm install" "$L3" && ok "green-gate deps installed by lockfile" || no "green-gate install not logged"
grep -q "green-gate: develop still passing" "$L3" && ok "green-gate passed with installed deps" || no "green-gate did not pass"
[[ "$(git -C "$P3" log -1 --format=%s develop)" == merge*TEST-MT3* ]] && ok "merge landed on develop" || no "merge missing from develop"
[[ ! -e "$P3/.dozer-deps-install.log" ]] && ok "no install litter in the checkout" || no "install log written into the checkout"

# ── case 3b: green-gate install FAILS → distinct message, develop untouched ────
echo "case 3b: green-gate deps install fails → 'green-gate deps install failed', not 'merge broke develop'"
P3B="$TMP/p3b"; mkproj "$P3B" branch-only no-deps
( cd "$P3B" && : > pnpm-lock.yaml && git add -A && git commit -q -m "lockfile" && git branch -f develop main )
: > "$COUNT"; PRE3B="$(git -C "$P3B" rev-parse develop)"; L3B="$TMP/c3b.log"; rc=0
PATH="$BIN:$PATH" PNPM_COUNT="$COUNT" PNPM_FAIL_ON=2 crew TEST-MT3B "$P3B" "$TMP/wt3b" "$L3B" || rc=$?
[[ $rc -ne 0 ]] && ok "crew failed (rc=$rc)" || no "crew succeeded despite install failure"
grep -q "green-gate deps install failed" "$L3B" && ok "failure is the install's" || { no "install failure not reported as such"; dump "$L3B"; }
! grep -q "merge broke develop" "$L3B" && ok "not disguised as 'merge broke develop'" || no "reported as 'merge broke develop'"
grep -q "ERR_PNPM_STUB" "$L3B" && ok "install log tail included in the reason" || no "install log tail missing"
[[ "$(git -C "$P3B" rev-parse develop)" == "$PRE3B" ]] && ok "develop untouched" || no "develop moved"

# ── case 4: the ENGINE puts the crew's reason in the block comment ─────────────
echo "case 4: engine block comment carries the fail reason (files backend)"
if ls "$BOARD"/wip/*.md >/dev/null 2>&1; then
  echo "  SKIP: tasks/board/wip is not empty — refusing to run the engine against live work" >&2
else
  P4="$TMP/p4"; mkproj "$P4" checkout-develop with-deps
  printf 'uncommitted edit\n' >> "$P4/feature.txt"
  mkdir -p "$BOARD/ready"; printf 'title: %s\nlane: dev\n' "engine reason" > "$BOARD/ready/MTT-4.md"
  L4="$TMP/c4.log"
  BACKEND=files ADAPTER_QUIET=1 REAPER_ENABLED=0 LOCK_DIR="$TMP/locks" FANOUT=1 \
    WORKDIR_DEFAULT="$P4" WORKTREE_ROOT="$TMP/wt4" INTEGRATION_BRANCH="develop" \
    MODEL_CMD="bash $STUB" PUSH="false" bash "$ROOT/dozers/dozer.sh" once >"$L4" 2>&1 || true
  [[ -f "$BOARD/blocked/MTT-4.md" ]] && ok "task moved to blocked" || { no "task not blocked"; dump "$L4"; }
  grep -q "Reason: integration branch develop is checked out dirty at" "$BOARD/blocked/MTT-4.md" 2>/dev/null \
    && ok "block comment carries the reason" || { no "block comment has no reason"; cat "$BOARD/blocked/MTT-4.md" 2>/dev/null | dump /dev/stdin; }
fi

if [[ $fail == 0 ]]; then echo "dev-lane-merge-target-test: PASS"; else echo "dev-lane-merge-target-test: FAIL" >&2; exit 1; fi
