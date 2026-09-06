#!/usr/bin/env bash
# tests/heartbeat-test.sh — regression test for the engine liveness heartbeat.
#
# Proves the beacon dozer.sh emits carries the fields the reaper/doctor/monitor rely
# on, and — the GSAI-31 regression — that it keeps beating WHILE the engine works:
#   FIELDS    — pid + ts + inflight + poll + every are all present
#   PID       — heartbeat pid is THIS emitter (a live, probeable process)
#   INFLIGHT  — count reflects the run-locks in LOCK_DIR at beat time
#   ATOMIC    — no leftover *.tmp beacon after the write
#   TICK      — a beat with no explicit tick keeps the tick already on the beacon
#   DRAIN     — the beacon advances DURING a blocking drain, and `inflight` is live
#               (before GSAI-31 it froze for the whole drain at a pre-crew count)
#   ORPHAN    — the ticker dies with the engine; a SIGKILLed engine stops beating
#               (a beacon that keeps ticking for a dead engine is worse than none)
#
# Run:  bash tests/heartbeat-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
LOCK_DIR="$TMP/locks"; mkdir -p "$LOCK_DIR"
HB="$TMP/heartbeat"

cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

mklock() { mkdir -p "$LOCK_DIR/$1.lock"; printf 'pid=%s\ntask=%s\n' "$2" "$1" > "$LOCK_DIR/$1.lock/owner"; }

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
field() { grep -E "^$1=" "$HB" 2>/dev/null | head -1 | cut -d= -f2-; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# ── two tasks in flight -> heartbeat must report inflight=2 ─────────────────────
mklock HBT-A 111111
mklock HBT-B 222222
BACKEND=files ADAPTER_QUIET=1 LOCK_DIR="$LOCK_DIR" HEARTBEAT_FILE="$HB" \
  bash "$ROOT/dozers/dozer.sh" heartbeat 7 >/dev/null

[[ -f "$HB" ]]                 && ok "heartbeat file written"        || no "heartbeat file missing"
[[ -n "$(field pid)"  ]]      && ok "pid field present"             || no "pid field missing"
[[ -n "$(field ts)"   ]]      && ok "ts field present"              || no "ts field missing"
[[ "$(field inflight)" == 2 ]] && ok "in-flight counts run-locks (2)" || no "in-flight wrong: got '$(field inflight)' want 2"
[[ "$(field poll)"     == 7 ]] && ok "poll tick recorded"           || no "poll tick wrong: got '$(field poll)' want 7"
# `every` publishes the beat cadence so a watcher derives its staleness threshold from
# the beacon instead of guessing — the two can then never drift apart.
[[ "$(field every)" =~ ^[0-9]+$ ]] && ok "every (beat cadence) published" || no "every field missing/non-numeric: '$(field every)'"

# pid is the engine's own $$ — a numeric process id the reaper can signal-0 probe while
# the loop runs. (A one-shot `heartbeat` invocation exits at once, so we assert shape, not
# liveness; the loop path keeps $$ alive across polls.)
hpid="$(field pid)"
[[ "$hpid" =~ ^[0-9]+$ ]] && ok "heartbeat pid is numeric ($hpid)" || no "heartbeat pid not numeric: '$hpid'"

# no half-written temp beacon left behind (atomic tmp+mv)
if ls "$HB".*.tmp >/dev/null 2>&1; then no "leftover .tmp beacon"; else ok "no leftover .tmp (atomic write)"; fi

# ── a beat with no explicit tick KEEPS the tick already on the beacon ───────────
# The ticker re-beats mid-drain with no tick argument; it must refresh `ts` without
# pretending a new poll cycle happened.
BACKEND=files ADAPTER_QUIET=1 LOCK_DIR="$LOCK_DIR" HEARTBEAT_FILE="$HB" \
  bash "$ROOT/dozers/dozer.sh" heartbeat >/dev/null
[[ "$(field poll)" == 7 ]] && ok "tickless beat preserves poll# (7)" || no "tickless beat lost the tick: got '$(field poll)'"

# ── zero locks -> inflight=0 ────────────────────────────────────────────────────
rm -rf "$LOCK_DIR"/*.lock
BACKEND=files ADAPTER_QUIET=1 LOCK_DIR="$LOCK_DIR" HEARTBEAT_FILE="$HB" \
  bash "$ROOT/dozers/dozer.sh" heartbeat >/dev/null
[[ "$(field inflight)" == 0 ]] && ok "in-flight is 0 with no locks" || no "in-flight wrong: got '$(field inflight)' want 0"

# ── doctor must survive BOTH beacon formats ────────────────────────────────────
# A beacon written before GSAI-31 has no `every=` line. `doctor` is what you run to
# inspect exactly that state, so it must not die on it.
BACKEND=files ADAPTER_QUIET=1 LOCK_DIR="$LOCK_DIR" HEARTBEAT_FILE="$HB" \
  bash "$ROOT/dozers/dozer.sh" doctor >"$TMP/doctor.out" 2>&1 \
  && grep -q 'in-flight=' "$TMP/doctor.out" && ok "doctor reports a current beacon" \
  || no "doctor failed on a current beacon: $(tail -3 "$TMP/doctor.out")"
printf 'pid=%s\nhost=%s\nts=2026-09-06T04:12:14Z\ninflight=0\npoll=313\n' "$$" "$(hostname -s)" > "$TMP/legacy-hb"
BACKEND=files ADAPTER_QUIET=1 LOCK_DIR="$LOCK_DIR" HEARTBEAT_FILE="$TMP/legacy-hb" \
  bash "$ROOT/dozers/dozer.sh" doctor >"$TMP/doctor2.out" 2>&1 \
  && grep -q 'in-flight=' "$TMP/doctor2.out" && ok "doctor survives a legacy beacon (no every= line)" \
  || no "doctor died on a legacy beacon: $(tail -3 "$TMP/doctor2.out")"

# ── DRAIN: the beacon must stay fresh while the engine is busy (GSAI-31) ────────
# Build a throwaway engine root with a `slow` lane whose crew just sleeps, so a drain
# blocks for a known, long-relative-to-the-beat interval. `dozer.sh` derives ROOT from
# its own path, so a symlinked copy of the script re-roots the whole engine here; the
# backend dir is a real copy so the fake board never touches the repo's own.
ER="$TMP/engine"; mkdir -p "$ER/dozers/slow-lane"
ln -s "$ROOT/dozers/dozer.sh" "$ER/dozers/dozer.sh"
cp -R "$ROOT/tasks" "$ER/tasks"; cp -R "$ROOT/org" "$ER/org"
rm -rf "$ER/tasks/board"
cat > "$ER/dozers/slow-lane/crew.sh" <<'CREW'
#!/usr/bin/env bash
# test crew: hold the drain open long enough to watch the beacon beat through it.
sleep "${SLOW_CREW_SECONDS:-6}"
CREW
chmod +x "$ER/dozers/slow-lane/crew.sh"
touch "$ER/dozers/slow-lane/dozer.md"
mkdir -p "$ER/tasks/board/ready"
printf 'title: slow task\nlane: slow\n' > "$ER/tasks/board/ready/HBT-SLOW.md"

DHB="$TMP/hb-drain"; DLOCKS="$TMP/locks-drain"; mkdir -p "$DLOCKS"
# POLL_SECONDS is long so the ONLY thing that can refresh the beacon during the drain
# is the ticker — not the once-per-poll beat.
BACKEND=files ADAPTER_QUIET=1 LOCK_DIR="$DLOCKS" HEARTBEAT_FILE="$DHB" \
  POLL_SECONDS=120 HEARTBEAT_SECONDS=1 REAPER_ENABLED=0 SLOW_CREW_SECONDS=6 FANOUT=1 \
  bash "$ER/dozers/dozer.sh" loop >"$TMP/loop.log" 2>&1 &
ENGINE=$!

# Wait for the crew to actually be in flight (its run-lock exists), then sample.
for _ in $(seq 1 60); do [[ -d "$DLOCKS/HBT-SLOW.lock" ]] && break; sleep 0.2; done
if [[ -d "$DLOCKS/HBT-SLOW.lock" ]]; then ok "slow crew claimed (drain is blocking)"; else no "slow crew never claimed — see $TMP/loop.log"; fi

t0="$(mtime "$DHB")"
inflight_seen=0
for _ in $(seq 1 8); do
  sleep 0.5
  [[ "$(grep -E '^inflight=' "$DHB" 2>/dev/null | cut -d= -f2)" == 1 ]] && inflight_seen=1
done
t1="$(mtime "$DHB")"
kill "$ENGINE" 2>/dev/null || true; wait "$ENGINE" 2>/dev/null || true

(( t1 > t0 )) && ok "beacon advanced DURING the drain (${t0} -> ${t1})" \
  || no "beacon FROZE during the drain (mtime stuck at $t0) — GSAI-31 regression"
(( inflight_seen )) && ok "in-flight reported the live crew (1) mid-drain" \
  || no "in-flight never showed the running crew — stale snapshot, GSAI-31 regression"

# ── ORPHAN: SIGKILL the engine; the ticker must stop beating with it ────────────
OHB="$TMP/hb-orphan"; OLOCKS="$TMP/locks-orphan"; mkdir -p "$OLOCKS"
rm -rf "$ER/tasks/board"; mkdir -p "$ER/tasks/board/ready"   # empty board: idle loop
BACKEND=files ADAPTER_QUIET=1 LOCK_DIR="$OLOCKS" HEARTBEAT_FILE="$OHB" \
  POLL_SECONDS=120 HEARTBEAT_SECONDS=1 REAPER_ENABLED=0 \
  bash "$ER/dozers/dozer.sh" loop >"$TMP/loop2.log" 2>&1 &
ENGINE2=$!
for _ in $(seq 1 40); do [[ -f "$OHB" ]] && break; sleep 0.2; done
sleep 2
kill -9 "$ENGINE2" 2>/dev/null || true; wait "$ENGINE2" 2>/dev/null || true
sleep 3                                   # >2 ticks: an orphan ticker would have beaten
k0="$(mtime "$OHB")"; sleep 2; k1="$(mtime "$OHB")"
(( k1 == k0 )) && ok "ticker died with a SIGKILLed engine (beacon stopped)" \
  || no "ORPHAN ticker still beating after the engine was killed ($k0 -> $k1) — the beacon lies"

if [[ $fail == 0 ]]; then echo "heartbeat-test: PASS"; else echo "heartbeat-test: FAIL" >&2; exit 1; fi
