#!/usr/bin/env bash
# tests/dev-lane-greengate-deps-test.sh — regression test for GSAI-124.
#
# The dev lane installs a worktree's deps from its lockfile when there is a
# package.json but no node_modules (GSAI-26 #2). On the MERGE worktree that
# install used to run BEFORE the merge — while the worktree still sat on the
# untouched integration branch. So for the one task that adds a repo's FIRST
# package.json, the pre-merge tree had nothing to install from, the install was
# skipped, the merge then brought package.json in, and the green-gate ran
# `npm test` bare → "command not found" → the merge was reverted and the issue
# blocked with the flatly wrong reason "merge broke develop".
#
# The deps step must therefore run on the POST-merge tree — the exact tree the
# gate is about to test. And because the merge has already happened by then, an
# install that FAILS must revert the merge and be reported AS the install, never
# disguised as a broken integration branch.
#
# Both scenarios drive the real crew against a throwaway repo with a fake `npm`
# on PATH (hermetic + offline): `npm ci` provisions node_modules, `npm test`
# fails exactly like a missing binary when node_modules is absent.
#
# Run:  bash tests/dev-lane-greengate-deps-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# ── a fake npm: hermetic, offline, and it models the real failure mode ────────
# `ci` provisions node_modules (or fails, when FAKE_NPM_CI_FAILS=1); `test` dies
# with "command not found" when node_modules is absent — exactly what a bare
# worktree does.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  ci|install)
    [[ "${FAKE_NPM_CI_FAILS:-0}" == "1" ]] && { echo "npm ERR! lockfile out of sync" >&2; exit 1; }
    mkdir -p node_modules && : > node_modules/.installed && echo "added 1 package"; exit 0 ;;
  test)
    [[ -f node_modules/.installed ]] || { echo "sh: vitest: command not found" >&2; exit 127; }
    echo "1 passed"; exit 0 ;;
esac
exit 0
EOS
chmod +x "$TMP/bin/npm"

# ── a repo whose integration branch has NO package.json at all ────────────────
# (the real cfw-website / first-package.json case: nothing to install pre-merge)
new_repo() {  # $1 = dir
  local p="$1"; mkdir -p "$p"; ( cd "$p"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore   # no trailing slash: also ignores a dep symlink
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m "init"
    git branch develop )                   # integration branch, not checked out
}

# ── stub coding agent: adds the repo's FIRST package.json + lockfile ──────────
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
printf '{\n  "name":"proj","version":"1.0.0",\n  "scripts":{"test":"vitest run"}\n}\n' > package.json
printf '{"name":"proj","version":"1.0.0","lockfileVersion":3,"packages":{}}\n' > package-lock.json
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent: add package.json + tests"
EOS
chmod +x "$STUB"

run_crew() {  # $1 = project dir, $2 = id, $3 = log; extra env in $EXTRA_ENV[@]
  env PATH="$TMP/bin:$PATH" "${EXTRA_ENV[@]}" \
    REPO_ROOT="$TMP" WORKDIR="$1" \
    WORKTREE_ROOT="$TMP/wt-$2" INTEGRATION_BRANCH="develop" \
    MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" \
    TEST_GATE="bootstrap" \
    bash "$CREW" "$2" "add the first package.json" >"$3" 2>&1
}

# ── 1. the bug: first package.json must still reach the gate with node_modules ─
P1="$TMP/proj1"; new_repo "$P1"
LOG1="$TMP/crew1.log"; rc=0; EXTRA_ENV=()
run_crew "$P1" "TEST-GGD1" "$LOG1" || rc=$?

[[ $rc -eq 0 ]] && ok "crew exited clean — first package.json got deps before the gate" \
  || { no "crew exited $rc — the green-gate ran without node_modules"; sed 's/^/    | /' "$LOG1" >&2; }

DEV_HEAD_MSG="$(git -C "$P1" log -1 --format=%s develop 2>/dev/null || true)"
[[ "$DEV_HEAD_MSG" == merge*TEST-GGD1* ]] && ok "merge commit landed on develop" \
  || no "develop HEAD is not the expected merge: '$DEV_HEAD_MSG'"

grep -q 'green-gate: node_modules missing' "$LOG1" \
  && ok "deps were installed for the green-gate (post-merge tree)" \
  || no "green-gate never installed deps — install ran against the pre-merge tree"

grep -q 'merge broke develop' "$LOG1" && no "reported 'merge broke develop'" \
  || ok "never blamed the merge"

# ── 2. a post-merge install that FAILS must revert and be named as the install ─
P2="$TMP/proj2"; new_repo "$P2"
BEFORE2="$(git -C "$P2" rev-parse develop)"
LOG2="$TMP/crew2.log"; rc=0
# fail ONLY the green-gate's install: the task worktree installs fine, so the
# failure can only come from the post-merge step.
GATE_NPM="$TMP/bin2"; mkdir -p "$GATE_NPM"
cat > "$GATE_NPM/npm" <<EOS
#!/usr/bin/env bash
# a lockfile install that breaks only once the merge worktree is involved
if [[ "\${1:-}" == "ci" && "\$PWD" == *-merge* ]]; then echo "npm ERR! lockfile out of sync" >&2; exit 1; fi
exec "$TMP/bin/npm" "\$@"
EOS
chmod +x "$GATE_NPM/npm"
env PATH="$GATE_NPM:$TMP/bin:$PATH" \
  REPO_ROOT="$TMP" WORKDIR="$P2" \
  WORKTREE_ROOT="$TMP/wt-2" INTEGRATION_BRANCH="develop" \
  MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" TEST_GATE="bootstrap" \
  bash "$CREW" "TEST-GGD2" "add the first package.json" >"$LOG2" 2>&1 || rc=$?

[[ $rc -ne 0 ]] && ok "crew failed when the post-merge install failed" \
  || { no "crew passed despite a failed green-gate install"; sed 's/^/    | /' "$LOG2" >&2; }

[[ "$(git -C "$P2" rev-parse develop)" == "$BEFORE2" ]] \
  && ok "develop reverted to its pre-merge commit" \
  || no "develop kept a merge whose gate never ran"

REASON="$(cat "$TMP/.artifacts/dev/TEST-GGD2.fail" 2>/dev/null || true)"
[[ "$REASON" == *"deps install failed"* ]] \
  && ok "failure names the deps install" \
  || no "failure reason does not name the install: '$REASON'"
[[ "$REASON" != *"merge broke develop"* ]] \
  && ok "failure is not disguised as 'merge broke develop'" \
  || no "install failure reported as 'merge broke develop'"

if [[ $fail == 0 ]]; then echo "dev-lane-greengate-deps-test: PASS"; else echo "dev-lane-greengate-deps-test: FAIL" >&2; exit 1; fi
