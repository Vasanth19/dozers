#!/usr/bin/env bash
# tests/timebox-test.sh — unit test for dozers/timebox.sh (GSAI-37).
#
# The helper's whole promise is "a hung command dies, grandchildren included, and the
# caller learns it was a TIMEOUT". So the hang here is deliberately a grandchild — a
# `sleep` forked by a child shell, the same shape as `npm test` → vitest → node — and
# the assertion is that it is GONE afterwards, not merely that the wrapper returned.
#
#   HANG      — a command that never finishes returns 124 + TIMEBOX_HIT=1, within the
#               bound plus the kill grace, and its grandchild is dead
#   PASS      — a fast command's status and stdout pass through untouched
#   FAIL      — a fast failing command's own status passes through (not 124)
#   ZERO      — bound 0 runs unbounded (a visible opt-out)
#   BOUNDS    — timebox_secs: env beats config beats default; a non-number fails loudly
#
# Run:  bash tests/timebox-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
GRANDCHILD=""
cleanup() { [[ -n "$GRANDCHILD" ]] && kill -9 "$GRANDCHILD" 2>/dev/null; rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

export TIMEBOX_KILL_GRACE=1
source "$ROOT/dozers/timebox.sh"

# ── HANG: child shell forks a grandchild sleep, then hangs itself ─────────────
PIDFILE="$TMP/grandchild.pid"
start=$SECONDS
timebox 2 "hang probe" "$TMP" "bash -c 'sleep 300 & echo \$! > \"$PIDFILE\"; wait'" >/dev/null 2>"$TMP/hang.err"; rc=$?
took=$(( SECONDS - start ))
GRANDCHILD="$(cat "$PIDFILE" 2>/dev/null || true)"
[[ $rc -eq 124 ]] && ok "HANG: returns 124" || no "HANG: returned $rc, want 124"
[[ "$TIMEBOX_HIT" == 1 ]] && ok "HANG: TIMEBOX_HIT=1" || no "HANG: TIMEBOX_HIT='$TIMEBOX_HIT'"
(( took <= 8 )) && ok "HANG: returned in ${took}s (bound 2s + grace 1s)" || no "HANG: took ${took}s — the bound did not bite"
grep -q "exceeded 2s" "$TMP/hang.err" && ok "HANG: names the bound on stderr" || { no "HANG: no 'exceeded 2s' on stderr"; sed 's/^/    | /' "$TMP/hang.err" >&2; }
sleep 1   # give the KILL a moment to land
if [[ -n "$GRANDCHILD" ]] && kill -0 "$GRANDCHILD" 2>/dev/null; then no "HANG: grandchild sleep (pid $GRANDCHILD) survived — process group not killed"
else ok "HANG: grandchild sleep is dead (process group killed)"; GRANDCHILD=""; fi

# ── HANG-IN-PIPE: same hang, but timebox itself runs inside a pipeline subshell ──
# bash gives a subshell no job control, so `set -m` is a silent no-op there and a
# group-only kill has nothing to signal — the grandchild would survive. The tree walk
# must catch it regardless of where timebox is called from.
PIDFILE2="$TMP/grandchild2.pid"
timebox 2 "hang-in-pipe probe" "$TMP" "bash -c 'sleep 300 & echo \$! > \"$PIDFILE2\"; wait'" 2>/dev/null | cat >/dev/null
sleep 1
g2="$(cat "$PIDFILE2" 2>/dev/null || true)"
if [[ -n "$g2" ]] && kill -0 "$g2" 2>/dev/null; then no "HANG-IN-PIPE: grandchild (pid $g2) survived — kill depends on job control"; kill -9 "$g2" 2>/dev/null
else ok "HANG-IN-PIPE: grandchild dead even with timebox inside a pipeline subshell"; fi

# ── PASS / FAIL: status and stdout pass through ───────────────────────────────
# (stdout to a file, not `$(...)`: a command substitution runs timebox in a subshell,
# so TIMEBOX_HIT in THIS shell would be whatever the previous case left — the crews
# never call it that way, and neither does this test.)
timebox 5 "pass probe" "$TMP" "echo hello; exit 0" >"$TMP/pass.out" 2>/dev/null; rc=$?
out="$(cat "$TMP/pass.out")"
[[ $rc -eq 0 && "$out" == "hello" && "$TIMEBOX_HIT" == 0 ]] && ok "PASS: status 0, stdout intact, no hit" \
  || no "PASS: rc=$rc out='$out' hit=$TIMEBOX_HIT"
timebox 5 "fail probe" "$TMP" "exit 3" 2>/dev/null; rc=$?
[[ $rc -eq 3 && "$TIMEBOX_HIT" == 0 ]] && ok "FAIL: the command's own status (3) passes through" || no "FAIL: rc=$rc hit=$TIMEBOX_HIT"
# LEAK: a fast command must not leave the watchdog's `sleep <bound>` behind. It held
# the inherited stdout open, so `crew | tail` waited the whole bound for EOF. An odd
# bound so the pgrep cannot match anything else on the box.
timebox 4321 "leak probe" "$TMP" "true" 2>/dev/null
# The TERM is delivered before timebox returns; the sleep's teardown can trail it by a
# few ms, so poll briefly rather than judge a single instant. A real leak is still
# there after 3s; an orphaned-for-an-hour sleep never goes away on its own.
leaked=1; for _ in 1 2 3 4 5 6; do pgrep -f "^sleep 4321$" >/dev/null 2>&1 || { leaked=0; break; }; sleep 0.5; done
if (( leaked )); then no "LEAK: watchdog sleep survived the command finishing"; pkill -f "^sleep 4321$" 2>/dev/null
else ok "LEAK: no watchdog sleep left behind after a fast command"; fi
# and the pipe consequence itself: piping a fast timebox must return at once
start=$SECONDS
timebox 4321 "pipe probe" "$TMP" "echo piped" 2>/dev/null | cat >/dev/null
(( SECONDS - start <= 5 )) && ok "LEAK: a piped fast command returns at once (EOF not held by the watchdog)" \
  || no "LEAK: piped fast command took $(( SECONDS - start ))s — something held the pipe"
# the command runs IN the dir it was given
out="$(timebox 5 "cwd probe" "$TMP" "pwd" 2>/dev/null)"
[[ "$out" == "$(cd "$TMP" && pwd)" ]] && ok "runs in the given dir" || no "ran in '$out', want $TMP"

# ── ZERO: bound 0 = unbounded, visibly ────────────────────────────────────────
timebox 0 "zero probe" "$TMP" "sleep 1; exit 0" 2>"$TMP/zero.err"; rc=$?
[[ $rc -eq 0 ]] && grep -q "no time bound" "$TMP/zero.err" && ok "ZERO: 0 runs unbounded and says so" \
  || no "ZERO: rc=$rc stderr='$(cat "$TMP/zero.err")'"
timebox abc "bad probe" "$TMP" "true" 2>/dev/null; rc=$?
[[ $rc -eq 2 ]] && ok "non-numeric bound is rejected (2)" || no "non-numeric bound returned $rc"

# ── BOUNDS: resolution order env > config > default, and loud on garbage ──────
printf 'timeout_test: 77\ntimeout_deps: "88"   # quoted\ntimeout_bad: soon\n' > "$TMP/config.yaml"
TIMEBOX_CONFIG="$TMP/config.yaml"
[[ "$(timebox_secs model 3600)" == 3600 ]] && ok "BOUNDS: default when unset" || no "BOUNDS: default wrong: $(timebox_secs model 3600)"
[[ "$(timebox_secs test 900)" == 77 ]] && ok "BOUNDS: config beats default" || no "BOUNDS: config not read: $(timebox_secs test 900)"
[[ "$(timebox_secs deps 900)" == 88 ]] && ok "BOUNDS: quoted config value parsed" || no "BOUNDS: quoted value: $(timebox_secs deps 900)"
[[ "$(DOZER_TIMEOUT_TEST=5 timebox_secs test 900)" == 5 ]] && ok "BOUNDS: env beats config" || no "BOUNDS: env override ignored"
if timebox_secs bad 10 >/dev/null 2>"$TMP/bad.err"; then no "BOUNDS: 'soon' was accepted"
else grep -q "must be whole seconds" "$TMP/bad.err" && ok "BOUNDS: non-numeric config fails loudly" || no "BOUNDS: failed without a reason"; fi
if DOZER_TIMEOUT_TEST=1.5 timebox_secs test 900 >/dev/null 2>&1; then no "BOUNDS: '1.5' env was accepted"
else ok "BOUNDS: fractional env value rejected"; fi

if [[ $fail == 0 ]]; then echo "timebox-test: PASS"; else echo "timebox-test: FAIL" >&2; exit 1; fi
