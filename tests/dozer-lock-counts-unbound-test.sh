#!/usr/bin/env bash
# tests/dozer-lock-counts-unbound-test.sh — GSAI-213 §6: the "lock: unbound variable" report.
#
# The BRD-96 log showed `lock: unbound variable` from the engine. The line was not found by
# reading. This test runs the REAL lock-counting functions under `set -euo pipefail`
# against the lock layouts the engine actually meets, and asserts that none of them
# reports an unbound variable, and that each returns the right count:
#
#   empty        no locks at all
#   pid-only     a `pid` file and no `owner` (the Directors' director-<role>.lock layout)
#   owner-less   an empty lock directory
#   live         an `owner` with a live pid, a task and a repo= line
#   dead         an `owner` whose pid is gone
#
# The functions are extracted verbatim from dozers/dozer.sh (the file has no source guard,
# so a plain `source` would run the engine). Each fixture runs in its own shell, the way
# the engine runs them. The reaper's dry run runs on the two fixtures it can see too.
#
# If every fixture passes, the defect is NOT reproduced on this tree, and no code change is
# made for it (see DOZER-DESIGN-GSAI-213.md §6). A failure names the function and the line.
#
# Run:  bash tests/dozer-lock-counts-unbound-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOZER="$ROOT/dozers/dozer.sh"
TMP="$(mktemp -d)"; LIVE=""

cleanup() { [[ -n "$LIVE" ]] && kill "$LIVE" 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# A live pid for the fixtures that need one.
sleep 120 & LIVE=$!

# ── extract the real functions, verbatim ──────────────────────────────────────────────
# A one-line definition (`name() { ...; }`) is printed alone; a multi-line one runs to the
# next line that starts with `}`.
extract() {
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") {
      print
      if ($0 ~ /\}[[:space:]]*(#.*)?$/) exit
      inside = 1; next
    }
    inside { print; if ($0 ~ /^\}/) exit }
  ' "$DOZER"
}
FN="$TMP/functions.sh"
{
  echo 'GROUP_TEAMS=(); GROUP_SLOTS=(); RKEYS=(); RCOUNT=()'
  for f in team_of group_index group_live_counts inflight_count repo_key_of repo_live_counts; do
    extract "$f"
  done
} > "$FN"
for f in team_of group_index group_live_counts inflight_count repo_key_of repo_live_counts; do
  grep -q "^$f() {" "$FN" && ok "extracted $f from dozers/dozer.sh" || no "could not extract $f from dozers/dozer.sh"
done

# The engine's resolver is not under test here; these stubs make every task uncapped.
DRIVER="$TMP/driver.sh"
cat > "$DRIVER" <<EOF
set -euo pipefail
task_repo() { :; }; task_team() { :; }; resolve_workdir() { return 1; }
source "$FN"
echo "inflight=\$(inflight_count)"
echo "groups=\$(group_live_counts)"
echo "repos=[\$(repo_live_counts | tr '\n' ',')]"
EOF

# ── fixtures ──────────────────────────────────────────────────────────────────────────
mk() { mkdir -p "$1"; }
EMPTY="$TMP/locks-empty";     mk "$EMPTY"
PIDONLY="$TMP/locks-pidonly"; mk "$PIDONLY/director-guzz.lock"; printf '%s\n' "$LIVE" > "$PIDONLY/director-guzz.lock/pid"
mk "$PIDONLY/CFW-9.lock"; printf '%s\n' "$LIVE" > "$PIDONLY/CFW-9.lock/pid"
OWNERLESS="$TMP/locks-ownerless"; mk "$OWNERLESS/CFW-8.lock"
LIVEDIR="$TMP/locks-live";    mk "$LIVEDIR/CFW-7.lock"
printf 'pid=%s\nhost=test\ntask=CFW-7\nlane=dev\nts=now\nrepo=/tmp/repo-a\n' "$LIVE" > "$LIVEDIR/CFW-7.lock/owner"
DEADDIR="$TMP/locks-dead";    mk "$DEADDIR/CFW-6.lock"
printf 'pid=999999\nhost=test\ntask=CFW-6\nlane=dev\nts=now\nrepo=/tmp/repo-b\n' > "$DEADDIR/CFW-6.lock/owner"

# run <lock-dir> -> sets OUT_STDOUT, OUT_STDERR, OUT_RC
run() {
  local err="$TMP/err.$$"
  OUT_STDOUT="$(LOCK_DIR="$1" bash "$DRIVER" 2>"$err")"; OUT_RC=$?
  OUT_STDERR="$(cat "$err" 2>/dev/null || true)"; rm -f "$err"
}

check_clean() {  # <name> — rc 0 and no unbound-variable anywhere
  if [[ $OUT_RC == 0 ]]; then ok "$1: completed (rc 0)"; else no "$1: aborted rc=$OUT_RC: $OUT_STDERR"; fi
  if grep -q 'unbound variable' <<<"$OUT_STDERR$OUT_STDOUT"; then
    no "$1: reported an unbound variable: $OUT_STDERR"
  else ok "$1: no unbound variable on stdout or stderr"; fi
}

run "$EMPTY"
check_clean "empty LOCK_DIR"
[[ "$OUT_STDOUT" == *"inflight=0"* ]] && ok "empty LOCK_DIR: in-flight count is 0" || no "empty: $OUT_STDOUT"
[[ "$OUT_STDOUT" == *"repos=[]"* ]]   && ok "empty LOCK_DIR: no repo counts" || no "empty repos: $OUT_STDOUT"

run "$PIDONLY"
check_clean "pid-only lock"
[[ "$OUT_STDOUT" == *"inflight=0"* ]] && ok "pid-only lock (director + owner-less pid file): not counted as in-flight" \
  || no "pid-only counted as in-flight: $OUT_STDOUT"

run "$OWNERLESS"
check_clean "owner-less lock"
[[ "$OUT_STDOUT" == *"inflight=0"* ]] && ok "owner-less lock: not counted as in-flight" || no "owner-less counted: $OUT_STDOUT"

run "$LIVEDIR"
check_clean "live owner lock"
[[ "$OUT_STDOUT" == *"inflight=1"* ]]          && ok "live owner lock: counted as one in-flight crew" || no "live: $OUT_STDOUT"
[[ "$OUT_STDOUT" == *"groups=1"* ]]            && ok "live owner lock: counted in the default group" || no "live groups: $OUT_STDOUT"
[[ "$OUT_STDOUT" == *"repos=[/tmp/repo-a,]"* ]] && ok "live owner lock: its repo= checkout is counted" || no "live repos: $OUT_STDOUT"

run "$DEADDIR"
check_clean "dead owner lock"
[[ "$OUT_STDOUT" == *"inflight=0"* ]] && ok "dead owner lock (pid gone): not counted" || no "dead counted: $OUT_STDOUT"

# ── the reaper's dry run on the fixtures it can read ─────────────────────────────────
for dir in "$EMPTY" "$PIDONLY"; do
  name="$(basename "$dir")"
  err="$TMP/reaper.err"
  rout="$(BACKEND=files LOCK_DIR="$dir" bash "$ROOT/dozers/reaper.sh" --dry-run 2>"$err")"; rrc=$?
  if [[ $rrc == 0 ]] && ! grep -q 'unbound variable' "$err" && ! grep -q 'unbound variable' <<<"$rout"; then
    ok "reaper --dry-run on $name: completed, no unbound variable"
  else
    no "reaper --dry-run on $name: rc=$rrc $(cat "$err")"
  fi
done

if (( fail == 0 )); then echo "dozer-lock-counts-unbound: PASS"; else echo "dozer-lock-counts-unbound: FAIL" >&2; exit 1; fi
