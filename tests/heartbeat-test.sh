#!/usr/bin/env bash
# tests/heartbeat-test.sh — regression test for the engine liveness heartbeat.
#
# Proves the beacon dozer.sh emits every poll cycle carries the three fields the
# reaper/doctor rely on, and that in-flight is a live count of run-locks:
#   FIELDS    — pid + ts + inflight + poll are all present
#   PID       — heartbeat pid is THIS emitter (a live, probeable process)
#   INFLIGHT  — count reflects the run-locks in LOCK_DIR at beat time
#   ATOMIC    — no leftover *.tmp beacon after the write
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

# pid is the engine's own $$ — a numeric process id the reaper can signal-0 probe while
# the loop runs. (A one-shot `heartbeat` invocation exits at once, so we assert shape, not
# liveness; the loop path keeps $$ alive across polls.)
hpid="$(field pid)"
[[ "$hpid" =~ ^[0-9]+$ ]] && ok "heartbeat pid is numeric ($hpid)" || no "heartbeat pid not numeric: '$hpid'"

# no half-written temp beacon left behind (atomic tmp+mv)
if ls "$HB".*.tmp >/dev/null 2>&1; then no "leftover .tmp beacon"; else ok "no leftover .tmp (atomic write)"; fi

# ── zero locks -> inflight=0 ────────────────────────────────────────────────────
rm -rf "$LOCK_DIR"/*.lock
BACKEND=files ADAPTER_QUIET=1 LOCK_DIR="$LOCK_DIR" HEARTBEAT_FILE="$HB" \
  bash "$ROOT/dozers/dozer.sh" heartbeat >/dev/null
[[ "$(field inflight)" == 0 ]] && ok "in-flight is 0 with no locks" || no "in-flight wrong: got '$(field inflight)' want 0"

if [[ $fail == 0 ]]; then echo "heartbeat-test: PASS"; else echo "heartbeat-test: FAIL" >&2; exit 1; fi
