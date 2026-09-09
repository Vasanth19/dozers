#!/usr/bin/env bash
# tests/dozer-fanout-test.sh — regression test for GSAI-37 (engine side).
#
# `drain` used to launch a wave of FANOUT crews and `wait` on ALL of them, and `loop`
# could not poll until drain returned. One slow crew therefore idled every other slot
# and froze the poll counter: observed live as inflight=1 against fanout=5, poll stuck
# for 45+ minutes, ~30 greenlit issues waiting. The invariant this test pins down:
# idle capacity and queued greenlit work never coexist.
#
# It drives the REAL engine (dozers/dozer.sh) on the files backend, from a throwaway
# copy of the repo that carries one extra lane, `nap`, whose crew just sleeps for the
# seconds named in the task title. No model, no network.
#
#   LOOP  — fanout 3, one crew that sleeps 40s + five that sleep 1s. Every fast task
#           must reach done/ WHILE the slow crew is still running, with `poll` on the
#           beacon advancing and `inflight` having risen past 1 in the meantime. (Under
#           the old wave `wait`, the first wave {slow, fast, fast} would have blocked
#           the loop for 40s with three tasks still queued.)
#   ONCE  — fanout 2, one crew that sleeps 8s + three that sleep 1s. `once` must keep
#           refilling the free slot as crews finish — all fast tasks done while the
#           slow one is still up — and still exit 0 only after the last crew ends.
#
# Run:  bash tests/dozer-fanout-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; FAKE="$TMP/root"
ENGINE_PID=""
cleanup() {
  [[ -n "$ENGINE_PID" ]] && kill "$ENGINE_PID" 2>/dev/null
  # crews the engine leaves behind on exit: the lock owners and their sleeps
  local lock pid
  for lock in "$TMP"/locks/*.lock; do
    [[ -e "$lock/owner" ]] || continue
    pid="$(grep -E '^pid=' "$lock/owner" | cut -d= -f2)"
    [[ -n "$pid" ]] && { pkill -9 -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null; }
  done
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# ── a throwaway engine: the real scripts + a `nap` lane, its own board and locks ──
mkdir -p "$FAKE/dozers/nap-lane" "$FAKE/tasks" "$FAKE/org"
cp -R "$ROOT/dozers/." "$FAKE/dozers/"
for f in "$ROOT"/tasks/*; do [[ -f "$f" ]] && cp "$f" "$FAKE/tasks/"; done
cp "$ROOT/org/config.yaml" "$FAKE/org/config.yaml"
cat > "$FAKE/dozers/nap-lane/crew.sh" <<'EOS'
#!/usr/bin/env bash
# the nap lane: sleep for the seconds in the title ("... sleep=N"), then report
ID="$1"; TITLE="$2"; secs="${TITLE##*sleep=}"; secs="${secs%% *}"
sleep "$secs"
mkdir -p "$REPO_ROOT/.artifacts/nap"; printf -- '- slept %ss\n' "$secs" > "$REPO_ROOT/.artifacts/nap/$ID.summary"
EOS
chmod +x "$FAKE/dozers/nap-lane/crew.sh"
BOARD="$FAKE/tasks/board"; HB="$TMP/hb"; LOCKS="$TMP/locks"
seed() {  # $1 = id, $2 = seconds
  mkdir -p "$BOARD/ready"; printf 'title: nap sleep=%s\nlane: nap\n' "$2" > "$BOARD/ready/$1.md"
}
engine() {  # $1 = mode, $2 = fanout, $3 = log
  env -u DOZER_MODEL_DEV -u MODEL_CMD BACKEND=files ADAPTER_QUIET=1 REAPER_ENABLED=0 \
      FANOUT="$2" POLL_SECONDS=1 HEARTBEAT_SECONDS=1 LOCK_DIR="$LOCKS" HEARTBEAT_FILE="$HB" \
      bash "$FAKE/dozers/dozer.sh" "$1" >"$3" 2>&1 &
  ENGINE_PID=$!
}
field() { grep -E "^$1=" "$HB" 2>/dev/null | head -1 | cut -d= -f2-; }
done_count() { ls "$BOARD"/done/*.md 2>/dev/null | wc -l | tr -d ' '; }
slow_running() { [[ -f "$BOARD/wip/$1.md" && -d "$LOCKS/$1.lock" ]] && kill -0 "$(grep -E '^pid=' "$LOCKS/$1.lock/owner" | cut -d= -f2)" 2>/dev/null; }
reset_board() { rm -rf "$BOARD" "$LOCKS" "$HB" "$FAKE/.artifacts"; mkdir -p "$BOARD"/{ready,wip,done,blocked,review,inbox} "$LOCKS"; }

# ── LOOP: one slow crew must not idle the other slots or freeze the poll ──────
reset_board
seed NAP-SLOW 40; for i in 1 2 3 4 5; do seed "NAP-F$i" 1; done
LOG="$TMP/loop.log"; engine loop 3 "$LOG"
max_inflight=0; start=$SECONDS; all_fast_done=0
while (( SECONDS - start < 30 )); do
  inf="$(field inflight)"; [[ "$inf" =~ ^[0-9]+$ ]] && (( inf > max_inflight )) && max_inflight=$inf
  if (( $(done_count) >= 5 )); then all_fast_done=1; break; fi
  sleep 0.5
done
took=$(( SECONDS - start ))
if (( all_fast_done )); then ok "LOOP: all 5 fast tasks done in ${took}s"; else no "LOOP: only $(done_count)/5 fast tasks done after ${took}s"; sed 's/^/    | /' "$LOG" >&2; fi
slow_running NAP-SLOW && ok "LOOP: ...while the slow crew is STILL running (its slot, not the engine, is what it holds)" \
  || no "LOOP: the slow crew is not running any more — the fast ones waited on it"
poll="$(field poll)"
[[ "$poll" =~ ^[0-9]+$ ]] && (( poll >= 3 )) && ok "LOOP: poll advanced to $poll during the slow crew" \
  || no "LOOP: poll stuck at '${poll:-?}' while a crew ran"
(( max_inflight >= 2 )) && ok "LOOP: inflight rose to $max_inflight (slots refilled alongside the slow crew)" \
  || no "LOOP: inflight never rose past $max_inflight"
grep -q "ready but waiting: all 3 slots busy" "$LOG" && ok "LOOP: queued work was reported while slots were full" \
  || no "LOOP: no 'slots busy' report in the log"
kill "$ENGINE_PID" 2>/dev/null; wait "$ENGINE_PID" 2>/dev/null; ENGINE_PID=""

# ── ONCE: keeps filling the free slot; exits 0 only after the last crew ───────
cleanup_crews() { local l p; for l in "$LOCKS"/*.lock; do [[ -e "$l/owner" ]] || continue; p="$(grep -E '^pid=' "$l/owner" | cut -d= -f2)"; pkill -9 -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done; }
cleanup_crews; reset_board
seed NAP-SLOW 8; for i in 1 2 3; do seed "NAP-F$i" 1; done
LOG="$TMP/once.log"; start=$SECONDS; engine once 2 "$LOG"; once_pid=$ENGINE_PID
# by ~4s the three 1s tasks are done (slots: slow + one revolving) and the slow one is up
fast_done_early=0
while (( SECONDS - start < 6 )); do (( $(done_count) >= 3 )) && { fast_done_early=1; break; }; sleep 0.5; done
(( fast_done_early )) && slow_running NAP-SLOW && ok "ONCE: 3 fast tasks done at $(( SECONDS - start ))s while the slow crew still runs" \
  || no "ONCE: fast tasks did not finish ahead of the slow crew (done=$(done_count))"
wait "$once_pid"; rc=$?; ENGINE_PID=""
took=$(( SECONDS - start ))
[[ $rc -eq 0 ]] && ok "ONCE: exited 0" || { no "ONCE: exited $rc"; sed 's/^/    | /' "$LOG" >&2; }
(( took >= 8 && took <= 20 )) && ok "ONCE: returned only after the slow crew ended (${took}s)" || no "ONCE: returned at ${took}s"
(( $(done_count) == 4 )) && ok "ONCE: every task reached done/" || no "ONCE: done=$(done_count), want 4"

if [[ $fail == 0 ]]; then echo "dozer-fanout-test: PASS"; else echo "dozer-fanout-test: FAIL" >&2; exit 1; fi
