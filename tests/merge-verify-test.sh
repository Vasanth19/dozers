#!/usr/bin/env bash
# tests/merge-verify-test.sh — regression test for GSAI-119.
#
# The engine used to label dozer:merged-develop on the dev crew's EXIT CODE alone —
# no check that a merge commit actually landed on the integration branch. Exit-0
# without a merge (CFW-215/CFW-252, verified live 2026-09-14; CFW-141 twice on
# 2026-09-08) put fake PROMOTE rows on Vas's Ship gate with nothing to promote.
#
# The fix, tested here end to end:
#   1. the dev crew writes a merge RECEIPT (branch + merge SHA) after its green-gate
#   2. dozer.sh git-verifies that SHA is an ancestor of the branch BEFORE labelling;
#      an unverifiable claim blocks the issue and never labels it merged
#   3. dozers/audit-merged.sh repairs the existing phantom labels (strip + requeue)
#      and strips the label off closed issues (Ship-gate hygiene)
#
# Run:  bash tests/merge-verify-test.sh   (non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v npm >/dev/null 2>&1 || { echo "SKIP: npm not installed" >&2; exit 0; }

TMP="$(mktemp -d)"
cleanup() {
  rm -f "$ROOT"/.artifacts/dev/MV-* 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# ── fixtures ──────────────────────────────────────────────────────────────────
# Throwaway project: package.json test passes only when node_modules/.installed
# exists (deps symlinked from the real checkout by the crew). Same shape as the
# merge-target test's fixture.
mkproj() {  # $1 = dir
  local d="$1"; mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    printf '{\n  "name":"proj","version":"1.0.0",\n  "scripts":{"test":"test -f node_modules/.installed"}\n}\n' > package.json
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m "init"
    git branch develop
    mkdir node_modules && : > node_modules/.installed
  )
}
AGENT="$TMP/stub-agent.sh"
cat > "$AGENT" <<'EOA'
#!/usr/bin/env bash
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOA
chmod +x "$AGENT"

# ── case 1: the real crew writes a receipt naming the landed merge ────────────
echo "case 1: real crew (DRY_RUN) writes a receipt; verify-merge.sh confirms it"
P1="$TMP/p1"; mkproj "$P1"; L1="$TMP/c1.log"; rc=0
DRY_RUN=1 REPO_ROOT="$ROOT" WORKDIR="$P1" WORKTREE_ROOT="$TMP/wt1" INTEGRATION_BRANCH="develop" \
  MODEL_CMD="bash $AGENT" PUSH="false" DOZER_PERSONA="test" \
  bash "$ROOT/dozers/dev-lane/crew.sh" MV-1 "receipt" >"$L1" 2>&1 || rc=$?
[[ $rc -eq 0 ]] && ok "crew exited clean" || { no "crew exited $rc"; dump "$L1"; }
RC1="$ROOT/.artifacts/dev/MV-1.merge"
[[ -s "$RC1" ]] && ok "merge receipt written" || no "no receipt at $RC1"
grep -q '^branch=develop$' "$RC1" && ok "receipt names the integration branch" || no "receipt missing branch="
SHA1="$(grep -E '^merge_sha=' "$RC1" | cut -d= -f2)"
git -C "$P1" merge-base --is-ancestor "$SHA1" develop && ok "receipt SHA is on develop" || no "receipt SHA is NOT on develop"
vout="$(REPO_ROOT="$ROOT" bash "$ROOT/dozers/verify-merge.sh" MV-1 "$P1" 2>&1)" && ok "verify-merge: $vout" || { no "verify-merge failed on a real merge: $vout"; }
[[ "$vout" == ok* ]] && ok "verify output is a proof line: $vout" || no "verify output not a proof line"

# ── case 2: verify-merge.sh on claims that are NOT true ───────────────────────
echo "case 2: verify-merge.sh rejects a phantom (missing receipt / reverted merge)"
P2="$TMP/p2"; mkproj "$P2"
# 2a: no receipt at all (the phantom signature: exit 0, nothing merged)
vout2="$(REPO_ROOT="$ROOT" RECEIPT="$TMP/nowhere.merge" bash "$ROOT/dozers/verify-merge.sh" MV-2 "$P2" 2>&1)" && no "phantom WITHOUT receipt verified (!)" || true
[[ "$vout2" == *"no merge receipt"* ]] && ok "missing receipt rejected with the phantom signature named" || no "wrong reason: $vout2"
# 2b: a receipt whose merge was REVERTED — sha exists but is not an ancestor
( cd "$P2"
  git checkout -q -b dozer/MV-2 develop
  printf 'x\n' >> feature.txt; git add -A; git commit -q -m "task"
  git checkout -q develop
  git merge -q --no-ff dozer/MV-2 -m "merge dozer/MV-2 into develop — #MV-2 test"
)
MSHA="$(git -C "$P2" rev-parse HEAD)"
git -C "$P2" checkout -q develop && git -C "$P2" reset --hard -q HEAD~1 >/dev/null 2>&1
cat > "$TMP/reverted.merge" <<EOF
branch=develop
merge_sha=$MSHA
EOF
vout3="$(REPO_ROOT="$ROOT" RECEIPT="$TMP/reverted.merge" bash "$ROOT/dozers/verify-merge.sh" MV-2 "$P2" 2>&1)" && no "reverted merge verified (!)" || true
[[ "$vout3" == *"NOT an ancestor"* ]] && ok "reverted merge rejected with git evidence attached" || no "wrong reason: $vout3"
# 2c: a receipt naming a branch that does not exist
cat > "$TMP/wrongbranch.merge" <<EOF
branch=vapour
merge_sha=$MSHA
EOF
vout4="$(REPO_ROOT="$ROOT" RECEIPT="$TMP/wrongbranch.merge" bash "$ROOT/dozers/verify-merge.sh" MV-2 "$P2" 2>&1)" && no "merge onto nonexistent branch verified (!)" || true
[[ "$vout4" == *"no local branch 'vapour'"* ]] && ok "receipt naming a nonexistent branch rejected" || no "wrong reason: $vout4"

# ── case 3: the ENGINE labels only on proof (files backend, full run_one) ─────
# A whole engine copy so the phantom case can swap the dev crew for an exit-0 stub
# without touching the checkout under test.
echo "case 3: engine runs — happy path labels, phantom exit-0 blocks"
ENG="$TMP/engine"; mkdir -p "$ENG"
cp -R "$ROOT"/dozers "$ROOT"/tasks "$ROOT"/org "$ENG"/
mkdir -p "$ENG/.artifacts/dev" "$ENG/tasks/board"/{inbox,ready,wip,review,blocked,done}
BOARD="$ENG/tasks/board"
run_engine() {  # $1 = log file
  BACKEND=files ADAPTER_QUIET=1 REAPER_ENABLED=0 LOCK_DIR="$TMP/locks" FANOUT=1 \
    WORKTREE_ROOT="$TMP/wt-engine" INTEGRATION_BRANCH="develop" PUSH="false" \
    MODEL_CMD="bash $AGENT" \
    bash "$ENG/dozers/dozer.sh" once >"$1" 2>&1
}

# 3a happy: real crew + stub agent → verified → the task lands in done/
P3="$TMP/p3"; mkproj "$P3"
printf 'title: %s\nlane: dev\n' "happy path" > "$BOARD/ready/MV-3.md"
L3="$TMP/e3.log"; rc=0
WORKDIR_DEFAULT="$P3" run_engine "$L3" || rc=$?
[[ $rc -eq 0 ]] && ok "engine exited clean" || { no "engine exited $rc"; dump "$L3"; }
[[ -f "$BOARD/done/MV-3.md" ]] && ok "verified merge -> task done" || { no "task not in done/"; ls "$BOARD"/*/ 2>/dev/null | dump /dev/stdin; }
grep -q "^    verify-merge: ok .* is on develop" "$L3" && ok "engine logged the proof line" || no "no verify-merge proof in engine log"
git -C "$P3" merge-base --is-ancestor "$(git -C "$P3" log -1 --format=%H develop)" develop >/dev/null && [[ "$(git -C "$P3" log -1 --format=%s develop)" == merge*MV-3* ]] && ok "merge actually on develop" || no "merge missing from develop"

# 3b phantom: swap the dev crew for an exit-0-no-merge stub → blocked, not done
cat > "$ENG/dozers/dev-lane/crew.sh" <<'EOX'
#!/usr/bin/env bash
# phantom stub: reports success, merges nothing, writes no receipt — the exact
# GSAI-119 signature from CFW-215/CFW-252.
exit 0
EOX
chmod +x "$ENG/dozers/dev-lane/crew.sh"
P4="$TMP/p4"; mkproj "$P4"
printf 'title: %s\nlane: dev\n' "phantom" > "$BOARD/ready/MV-4.md"
L4="$TMP/e4.log"; rc=0
WORKDIR_DEFAULT="$P4" run_engine "$L4" || rc=$?
[[ $rc -eq 0 ]] && ok "engine exited clean on a phantom crew" || { no "engine exited $rc"; dump "$L4"; }
[[ -f "$BOARD/blocked/MV-4.md" ]] && ok "phantom -> blocked, NOT done" || no "phantom ended up somewhere other than blocked/"
[[ ! -f "$BOARD/done/MV-4.md" ]] && ok "phantom never labelled done/merged" || no "phantom landed in done/ — the bug is back"
grep -q "could NOT be verified" "$BOARD/blocked/MV-4.md" 2>/dev/null && ok "block comment carries the verification failure" || no "block comment missing the reason"
grep -q "no merge receipt" "$BOARD/blocked/MV-4.md" 2>/dev/null && ok "block comment names the phantom signature" || no "block comment missing the receipt detail"
PRE4="$(git -C "$P4" rev-parse develop)"
[[ "$(git -C "$P4" rev-parse develop)" == "$PRE4" ]] && [[ -z "$(git -C "$P4" log --format=%s --grep='MV-4' develop)" ]] && ok "develop untouched by the phantom" || no "phantom moved develop"

# ── case 4: audit-merged.sh repairs phantom labels, strips closed ones ────────
echo "case 4: one-shot audit — verify, strip+requeue phantoms, strip closed"
# Linear stub: list-merged-dev from a fixture; mutations recorded to $CALLS.
CALLS="$TMP/audit.calls"; : > "$CALLS"
LINSTUB="$TMP/linear-stub.sh"
cat > "$LINSTUB" <<EOL
#!/usr/bin/env bash
case "\$1" in
  list-merged-dev) cat "$TMP/audit.rows" ;;
  *) echo "\$@" >> "$CALLS" ;;
esac
EOL
chmod +x "$LINSTUB"
# Resolver stub: repo hints map to throwaway repos under $TMP.
RESSTUB="$TMP/resolver-stub.sh"
cat > "$RESSTUB" <<EOL
#!/usr/bin/env bash
case "\$2" in
  r-real)    echo "$TMP/ra" ;;
  *) exit 1 ;;
esac
EOL
chmod +x "$RESSTUB"
# Repo with ONE real merge (AM-1) and nothing for AM-2.
RA="$TMP/ra"; mkproj "$RA"
( cd "$RA"
  git checkout -q -b dozer/AM-1 main
  printf 'a\n' >> feature.txt; git add -A; git commit -q -m "am1"
  git checkout -q develop
  git merge -q --no-ff dozer/AM-1 -m "merge dozer/AM-1 into develop — #AM-1 real"
)
# An old commit that merely MENTIONS AM-2 — the Paperclip-era collision trap from
# the issue: it must NOT count as AM-2's merge.
( cd "$RA"
  git checkout -q develop
  printf 'old\n' >> feature.txt; git add -A
  git commit -q -m "Merge AM-2 (ab-scheduler parallel batch)"
)
cat > "$TMP/audit.rows" <<EOF
AM-1	CFW	r-real	started	dev
AM-2	GSAI	r-real	started	dev
AM-3	CFW	r-real	completed	dev
AM-4	LL	bogus	started	dev
EOF
L5="$TMP/audit.log"
AUDIT_LINEAR_API="$LINSTUB" AUDIT_RESOLVER="$RESSTUB" bash "$ROOT/dozers/audit-merged.sh" >"$L5" 2>&1 || { no "audit exited non-zero"; dump "$L5"; }
grep -q "✓ AM-1 *merge verified" "$L5" && ok "real merge keeps its label" || no "real merge not verified"
grep -q "✗ AM-2 *PHANTOM" "$L5" && ok "phantom detected" || { no "phantom missed (the 'Merge AM-2' message trap matched?)"; dump "$L5"; }
grep -q "AM-4.*UNRESOLVED" "$L5" && ok "unresolvable repo left alone and listed" || no "unresolved not reported"
grep -q "4 checked — 1 verified, 1 phantom requeued, 1 closed stripped, 1 unresolved" "$L5" && ok "count line is exact" || { no "count line wrong"; dump "$L5"; }
grep -qE 'audit-requeue AM-2' "$CALLS" && ok "phantom requeued (label stripped + ready)" || { no "audit-requeue not called for AM-2"; dump "$CALLS"; }
grep -qE 'audit-strip AM-3' "$CALLS" && ok "closed issue stripped (Ship-gate hygiene)" || no "audit-strip not called for AM-3"
grep -q 'comment AM-2' "$CALLS" && ok "phantom got an explanatory comment" || no "no comment on AM-2"
! grep -qE 'audit-(requeue|strip) AM-1' "$CALLS" && ok "verified issue untouched" || no "verified issue mutated"
! grep -qE 'audit-(requeue|strip) AM-4' "$CALLS" && ok "unresolved issue untouched" || no "unresolved issue mutated"
# dry-run: same verdicts, NO mutations
: > "$CALLS"
AUDIT_LINEAR_API="$LINSTUB" AUDIT_RESOLVER="$RESSTUB" bash "$ROOT/dozers/audit-merged.sh" --dry-run >"$TMP/audit-dry.log" 2>&1
grep -q 'PHANTOM.*dry-run' "$TMP/audit-dry.log" && ok "dry-run reports the phantom" || no "dry-run missed the phantom"
[[ ! -s "$CALLS" ]] && ok "dry-run made NO mutations" || { no "dry-run mutated"; dump "$CALLS"; }

# Deep-history regression (found live during GSAI-119's own audit): `git log | grep -q`
# under pipefail reads as NOT-FOUND when the matching line is EARLY in the output (the
# merge is at HEAD, as usual) and much history follows — grep exits on the match, git
# dies to SIGPIPE, pipefail reports 141. Every real repo tripped it. So: history BELOW
# the match, long enough to overflow the pipe buffer, built cheaply via commit-tree.
echo "case 4b: audit verifies a merge at HEAD with deep history below it (SIGPIPE trap)"
RB="$TMP/rb"; mkproj "$RB"
( cd "$RB"
  tip="$(git rev-parse develop)"; tree="$(git rev-parse develop^{tree})"
  # ~180-char subjects, 450 of them ≈ 80KB of post-match output — past the pipe buffer,
  # so the old `git log | grep -q` + pipefail reads it as a phantom (SIGPIPE).
  pad="$(printf 'x%.0s' $(seq 170))"
  for i in $(seq 450); do tip="$(git commit-tree "$tree" -p "$tip" -m "old history $i $pad")"; done
  git update-ref refs/heads/develop "$tip"
  git checkout -q -b dozer/AM-5 develop
  printf 'b\n' >> feature.txt; git add -A; git commit -q -m "am5"
  git checkout -q develop && git merge -q --no-ff dozer/AM-5 -m "merge dozer/AM-5 into develop — #AM-5 deep"
)
cat > "$RESSTUB" <<EOL
#!/usr/bin/env bash
case "\$2" in
  r-real)    echo "$TMP/ra" ;;
  r-deep)    echo "$TMP/rb" ;;
  *) exit 1 ;;
esac
EOL
cat > "$TMP/audit.rows" <<EOF
AM-5	GSAI	r-deep	unstarted	dev
EOF
AUDIT_LINEAR_API="$LINSTUB" AUDIT_RESOLVER="$RESSTUB" bash "$ROOT/dozers/audit-merged.sh" --dry-run >"$TMP/audit-deep.log" 2>&1
grep -q "✓ AM-5 *merge verified" "$TMP/audit-deep.log" && ok "deep-history merge verified" || { no "deep-history merge read as phantom (SIGPIPE trap is back)"; dump "$TMP/audit-deep.log"; }
# SIGPIPE itself is a WRITE race — whether a 450-commit history overflows the pipe
# before grep closes depends on the machine, so the deep-history case above can
# vacuously pass. The deterministic anchor: the trap SHAPE (git log piped into a
# quitting grep, under pipefail) must not be how the merge check is written at all.
grep -qE 'git -C "[^"]*" log --first-parent[^|]*\| *grep -q' "$ROOT/dozers/audit-merged.sh" \
  && no "merge check still pipes git log into grep -q (SIGPIPE trap shape)" \
  || ok "merge check captures the log BEFORE grep (no SIGPIPE shape)"
grep -qE 'grep -qE .* <<< "\$log"' "$ROOT/dozers/audit-merged.sh" \
  && ok "grep reads the captured history" || no "captured log is not what grep reads"

if [[ $fail == 0 ]]; then echo "merge-verify-test: PASS"; else echo "merge-verify-test: FAIL" >&2; exit 1; fi
