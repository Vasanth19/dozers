#!/usr/bin/env bash
# tests/dev-lane-timeout-per-repo-test.sh — regression test for GSAI-151.
#
# The test bound used to be a single global knob (org/config.yaml `timeout_test: 900`,
# or DOZER_TIMEOUT_TEST per run). This repo's own suite is heavy by nature (~155s
# standalone, ~1350s measured in-crew under launchd's Background band — see the
# service.sh ProcessType fix), so the flat 900 killed two GREEN runs of the engine's
# own gates (GSAI-73). The bound is now per-repo: `timeout_test:` on the repo's
# ecosystem.yaml entry (next to no_test_gate) beats the org config, and the env
# override still beats both. The failure lines also carry the ELAPSED time, so
# "tests timed out" says how far the run got.
#
# Precedence, most-specific first:
#   DOZER_TIMEOUT_TEST  >  timeout_test on the repo's ecosystem.yaml entry
#                        >  timeout_test in org/config.yaml  >  900
#
# Cases, each driving the REAL crew (MODEL_CMD stub) against a throwaway repo, with
# ECOSYSTEM_REGISTRY pointed at a fixture registry and REPO_ROOT at a fixture root
# whose org/config.yaml carries `timeout_test: 5`:
#   PER-REPO  — registry maps the repo to timeout_test: 8 (with org-config 10 also
#               live, proving per-repo beats org): a hanging test command → blocked,
#               the reason names `timed out after 8s` AND the per-repo source; develop
#               untouched; the hung grandchild is dead.
#   ENV WINS  — same repo, DOZER_TIMEOUT_TEST=12 → the reason names 12s.
#   FALLBACK  — repo absent from the fixture registry → org-config 10 applies; the
#               reason names 10s.
#
# The fixture bounds are 8/10/12s — distinct, so which tier WON is provable from the
# number in the reason, and all far below the 300s fixture hang but comfortably ABOVE
# `npm test`'s own startup: dev-lane-timeout-test.sh learned the hard way that a bound
# inside npm's startup envelope measures machine load, not behaviour, and flakes under
# in-crew load (the very pathology GSAI-151 exists to absorb).
#   ELAPSED   — a fast-FAILING test command → .fail carries `failed after <n>s`.
#   GARBAGE   — registry value `90O` → the crew fails FAST, naming the value and the
#               file, with the stub never invoked (no model time spent).
#
# Run:  bash tests/dev-lane-timeout-per-repo-test.sh   (exits non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() {
  local f; for f in "$TMP"/*.grandchild; do [[ -e "$f" ]] && { kill -9 "$(cat "$f")" 2>/dev/null || true; }; done
  rm -rf "$TMP" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# Fixture REPO_ROOT: org/config.yaml carries the org-level bound (5) so the PER-REPO
# case proves the registry entry beats it, and a copy of the registry reader so the
# per-repo lookup really runs (not silently absent).
RROOT="$TMP/root"; mkdir -p "$RROOT/org" "$RROOT/tasks"
printf 'timeout_test: 10\n' > "$RROOT/org/config.yaml"
cp "$ROOT/tasks/ecosystem_workdir.py" "$RROOT/tasks/ecosystem_workdir.py"

REGISTRY="$TMP/ecosystem.yaml"   # written per case by write_registry

# A throwaway repo on `main` + `develop`. t.sh hangs (forking a traceable grandchild
# sleep) when $HANG_WHERE matches its cwd; with FAIL_TEST=1 it just exits 1.
mkproj() {  # $1 = dir
  local d="$1"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    printf '{"name":"p","version":"1.0.0","scripts":{"test":"bash t.sh"}}\n' > package.json
    cat > t.sh <<'EOS'
#!/usr/bin/env bash
[[ "${FAIL_TEST:-}" == 1 ]] && exit 1
case "$PWD" in
  ${HANG_WHERE:-__never__}) sleep 300 & echo $! > "$GRANDCHILD_FILE"; wait ;;
esac
exit 0
EOS
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m init
    git branch develop )
}

# Stub coding agent: commits a change per invocation; INV_COUNT lets the GARBAGE case
# prove the model never ran (fail before spend).
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
if [[ -n "${INV_COUNT:-}" ]]; then
  n=$(( $(cat "$INV_COUNT" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$INV_COUNT"
fi
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOS
chmod +x "$STUB"

write_registry() {  # $1 = yaml body under projects:
  cat > "$REGISTRY" <<EOF
projects:
$1
infrastructure: []
EOF
}

run_crew() {  # $1 = proj dir, $2 = task id, $3 = log, $4.. = extra KEY=VAL
  local proj="$1" id="$2" log="$3"; shift 3
  env ECOSYSTEM_REGISTRY="$REGISTRY" GRANDCHILD_FILE="$TMP/$id.grandchild" TIMEBOX_KILL_GRACE=1 \
      REPO_ROOT="$RROOT" WORKDIR="$proj" WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
      MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" "$@" \
      bash "$CREW" "$id" "per-repo timeout test" >"$log" 2>&1
}
dev_head() { git -C "$1" log -1 --format=%s develop 2>/dev/null || true; }
reason()   { cat "$RROOT/.artifacts/dev/$1.fail" 2>/dev/null || true; }
grandchild_dead() {  # $1 = id → 0 if the recorded grandchild is gone (or was never forked)
  local pid; pid="$(cat "$TMP/$1.grandchild" 2>/dev/null || true)"
  [[ -z "$pid" ]] && return 1
  sleep 1; ! kill -0 "$pid" 2>/dev/null
}

# ── PER-REPO: the registry entry beats org-config 10 ──────────────────────────
echo "── PER-REPO: timeout_test on the repo's ecosystem.yaml entry wins"
PA="$TMP/per-repo"; mkproj "$PA"
write_registry "  - id: p
    local: $PA
    timeout_test: 8"
LOG="$TMP/a.log"; rc=0
run_crew "$PA" "TEST-PR-A" "$LOG" HANG_WHERE="*-TEST-PR-A" || rc=$?
[[ $rc -ne 0 ]] && ok "PER-REPO: crew blocked (exit $rc)" || { no "PER-REPO: crew exited 0 on a hang"; dump "$LOG"; }
r="$(reason TEST-PR-A)"
[[ "$r" == *"timed out after 8s"* && "$r" == *"ecosystem.yaml"* ]] \
  && ok "PER-REPO: reason names 8s and the per-repo source (not org-config 10s, not the 900 default)" \
  || { no "PER-REPO: wrong reason: '$r'"; dump "$LOG"; }
[[ "$r" == *"ran "*"s before the kill"* ]] && ok "PER-REPO: reason carries the elapsed time" \
  || no "PER-REPO: reason lacks elapsed: '$r'"
[[ "$(dev_head "$PA")" == "init" ]] && ok "PER-REPO: develop untouched" || no "PER-REPO: develop advanced to '$(dev_head "$PA")'"
grandchild_dead TEST-PR-A && ok "PER-REPO: hung grandchild is dead (group killed)" || no "PER-REPO: grandchild sleep survived"

# ── ENV WINS: DOZER_TIMEOUT_TEST beats the registry entry ──────────────────────
echo "── ENV WINS: the per-run env override beats the per-repo bound"
PE="$TMP/env-wins"; mkproj "$PE"
write_registry "  - id: p
    local: $PE
    timeout_test: 8"
LOG="$TMP/b.log"; rc=0
run_crew "$PE" "TEST-PR-B" "$LOG" HANG_WHERE="*-TEST-PR-B" DOZER_TIMEOUT_TEST=12 || rc=$?
[[ $rc -ne 0 ]] && ok "ENV WINS: crew blocked (exit $rc)" || { no "ENV WINS: crew exited 0 on a hang"; dump "$LOG"; }
r="$(reason TEST-PR-B)"
[[ "$r" == *"timed out after 12s"* ]] && ok "ENV WINS: reason names 12s (not the registry's 8s)" \
  || { no "ENV WINS: wrong reason: '$r'"; dump "$LOG"; }
[[ "$(dev_head "$PE")" == "init" ]] && ok "ENV WINS: develop untouched" || no "ENV WINS: develop advanced"
grandchild_dead TEST-PR-B && ok "ENV WINS: hung grandchild is dead (group killed)" || no "ENV WINS: grandchild sleep survived"

# ── FALLBACK: repo absent from the registry → org-config 10 ───────────────────
echo "── FALLBACK: no registry entry → org/config.yaml applies"
PF="$TMP/fallback"; mkproj "$PF"
write_registry "  - id: other
    local: $TMP/somewhere-else
    timeout_test: 8"
LOG="$TMP/c.log"; rc=0
run_crew "$PF" "TEST-PR-C" "$LOG" HANG_WHERE="*-TEST-PR-C" || rc=$?
[[ $rc -ne 0 ]] && ok "FALLBACK: crew blocked (exit $rc)" || { no "FALLBACK: crew exited 0 on a hang"; dump "$LOG"; }
r="$(reason TEST-PR-C)"
[[ "$r" == *"timed out after 10s"* && "$r" == *"org/config.yaml"* ]] \
  && ok "FALLBACK: reason names 10s from org/config.yaml" \
  || { no "FALLBACK: wrong reason: '$r'"; dump "$LOG"; }
[[ "$(dev_head "$PF")" == "init" ]] && ok "FALLBACK: develop untouched" || no "FALLBACK: develop advanced"
grandchild_dead TEST-PR-C && ok "FALLBACK: hung grandchild is dead (group killed)" || no "FALLBACK: grandchild sleep survived"

# ── ELAPSED: a fast-failing test names how long it ran ────────────────────────
echo "── ELAPSED: red tests report the elapsed seconds"
PG="$TMP/elapsed"; mkproj "$PG"
write_registry "  - id: p
    local: $PG"
LOG="$TMP/d.log"; rc=0
run_crew "$PG" "TEST-PR-D" "$LOG" FAIL_TEST=1 || rc=$?
[[ $rc -ne 0 ]] && ok "ELAPSED: crew blocked (exit $rc)" || { no "ELAPSED: crew exited 0 on red tests"; dump "$LOG"; }
r="$(reason TEST-PR-D)"
[[ "$r" =~ tests\ failed\ after\ [0-9]+s && "$r" == *"not merging"* ]] \
  && ok "ELAPSED: reason carries 'tests failed after Ns'" \
  || { no "ELAPSED: wrong reason: '$r'"; dump "$LOG"; }
[[ "$(dev_head "$PG")" == "init" ]] && ok "ELAPSED: develop untouched" || no "ELAPSED: develop advanced"

# ── GARBAGE: a non-numeric registry value fails FAST, before any spend ────────
echo "── GARBAGE: bad registry value stops the crew before the model runs"
PZ="$TMP/garbage"; mkproj "$PZ"
write_registry "  - id: p
    local: $PZ
    timeout_test: 90O"
LOG="$TMP/e.log"; rc=0
run_crew "$PZ" "TEST-PR-E" "$LOG" INV_COUNT="$TMP/e.count" || rc=$?
[[ $rc -ne 0 ]] && ok "GARBAGE: crew failed (exit $rc)" || { no "GARBAGE: crew exited 0 with '90O' as the bound"; dump "$LOG"; }
r="$(reason TEST-PR-E)"
[[ "$r" == *"90O"* && "$r" == *"ecosystem.yaml"* && "$r" == *"must be whole seconds"* ]] \
  && ok "GARBAGE: reason names the value, the file, and the contract" \
  || { no "GARBAGE: wrong reason: '$r'"; dump "$LOG"; }
[[ ! -e "$TMP/e.count" ]] && ok "GARBAGE: the model never ran — failed before any spend" \
  || no "GARBAGE: the stub ran ($(cat "$TMP/e.count") invocations) before the bad bound was rejected"
[[ ! -d "$TMP/wt-TEST-PR-E/garbage-TEST-PR-E" ]] && ok "GARBAGE: failed before a worktree was even built" \
  || no "GARBAGE: validation ran too late — worktree exists"

if [[ $fail == 0 ]]; then echo "dev-lane-timeout-per-repo-test: PASS"
else echo "dev-lane-timeout-per-repo-test: FAIL" >&2; exit 1; fi
