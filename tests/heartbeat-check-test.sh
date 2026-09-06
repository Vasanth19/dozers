#!/usr/bin/env bash
# tests/heartbeat-check-test.sh — acceptance suite for the engine watchdog (GSAI-31).
#
# One case per row of the decision table in dozers/heartbeat-check.sh, plus the two
# properties that decide whether this thing is a watchdog or a decoration:
#   DEBOUNCE  — one alarm per outage, re-armed only after the condition clears
#   SHOUTS    — the alarm path actually produces alarm text (GSAI-21 shipped a
#               watchdog that was silent by construction; a merged monitor is not a
#               firing monitor, so we assert on the rendered message)
#
# No network, no real sends: every case runs with HB_DRY_RUN=1 against fixtures.
# Run:  bash tests/heartbeat-check-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/dozers/heartbeat-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
has() { grep -qF "$2" <<<"$1"; }

HB="$TMP/heartbeat"; LOCKS="$TMP/locks"; STATE="$TMP/state"; LOG="$TMP/log"
mkdir -p "$LOCKS"

# Write a beacon that is <age> seconds old, with the given cadence + pid.
beacon() { # <age-seconds> <cadence> <pid> [inflight]
  printf 'pid=%s\nhost=%s\nts=%s\ninflight=%s\npoll=1\nevery=%s\n' \
    "$3" "$(hostname -s 2>/dev/null || echo local)" "$(date -u +%FT%TZ)" "${4:-0}" "$2" > "$HB"
  # Age is what the check measures, and it measures it by MTIME — so set the mtime.
  local when; when="$(( $(date +%s) - $1 ))"
  touch -t "$(date -r "$when" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$when" +%Y%m%d%H%M.%S)" "$HB"
}

run() { # <subcommand> <extra env...>  -> prints stdout+stderr, returns the check's rc
  local sub="$1"; shift
  local out r
  out="$(env HEARTBEAT_FILE="$HB" LOCK_DIR="$LOCKS" HB_STATE_FILE="$STATE" HB_RUN_LOG="$LOG" \
      HB_DRY_RUN=1 "$@" bash "$CHECK" "$sub" 2>&1)"; r=$?
  printf '%s' "$out"; return "$r"
}

echo "== dozer heartbeat watchdog =="
rm -f "$STATE"

# ── ROW: beacon missing + a loop process exists -> ALARM ───────────────────────
rm -f "$HB"
out="$(run check HB_ASSUME_LOOP=yes)"
if has "$out" "not beating" && has "$out" "beacon-never-written"; then
  ok "no beacon while a loop runs -> ALARM (beacon never written)"
else no "missing-beacon-with-loop should alarm; got: $out"; fi
rm -f "$STATE"

# ── ROW: beacon missing + no loop process -> silent ────────────────────────────
out="$(run check HB_ASSUME_LOOP=no)"
if [ -z "$out" ] && [ ! -f "$STATE" ]; then ok "no beacon and no engine -> silent (nothing is meant to run)"
else no "missing-beacon-no-loop should be silent; got: $out"; fi

# ── ROW: beacon fresh -> silent (any crew count) ───────────────────────────────
beacon 5 30 $$
out="$(run check HB_ASSUME_CREWS=0)"
[ -z "$out" ] && ok "fresh beacon, no crews -> silent" || no "fresh beacon should be silent; got: $out"
out="$(run check HB_ASSUME_CREWS=3)"
[ -z "$out" ] && ok "fresh beacon, 3 crews -> silent" || no "fresh+busy should be silent; got: $out"

# ── ROW: stale (>= 3x cadence) + a live crew -> silent, but LOGGED ─────────────
: > "$LOG"
beacon 200 30 $$
out="$(run check HB_ASSUME_CREWS=2)"
if [ -z "$out" ] && grep -q 'stale-but-busy' "$LOG"; then
  ok "stale beacon + live crew -> silent, and logged as a long task"
else no "stale+busy should be silent-but-logged; out='$out' log=$(tail -1 "$LOG")"; fi

# ── ROW: stale + no live crew -> ALARM ─────────────────────────────────────────
rm -f "$STATE"
out="$(run check HB_ASSUME_CREWS=0)"
if has "$out" "engine-stalled" && has "$out" "threshold 90s"; then
  ok "stale beacon + no crew -> ALARM (engine stalled), threshold = 3x cadence"
else no "stale+idle should alarm with a 3x threshold; got: $out"; fi

# ── the beacon names a pid that is gone -> ALARM even while fresh ──────────────
# The ticker stops within a tick of the engine dying, so this only shortens detection
# — but a beacon naming a corpse is never healthy, and waiting 3 cadences to say so
# would be a slower alarm for no benefit.
rm -f "$STATE"
beacon 5 30 $$
out="$(run check HB_ASSUME_ENGINE=dead HB_ASSUME_CREWS=0)"
has "$out" "engine-gone" && ok "fresh beacon naming a DEAD pid -> ALARM (engine gone)" \
  || no "dead engine pid should alarm; got: $out"

# ── SHOUTS: the alarm renders real, actionable text ────────────────────────────
if has "$out" "🔴" && has "$out" "@Fizz" && has "$out" "dozers/service.sh restart"; then
  ok "alarm text carries the flag, the @mention and the restart command"
else no "alarm text is missing flag/mention/restart; got: $out"; fi

# ── live crews are counted by LIVE owner pid, not by lock presence ─────────────
# A stale lock from a crashed crew must not buy a wedged engine silence.
rm -f "$STATE"; beacon 200 30 $$
mkdir -p "$LOCKS/DEAD-1.lock"; printf 'pid=%s\ntask=DEAD-1\n' 999999 > "$LOCKS/DEAD-1.lock/owner"
out="$(run check)"
has "$out" "engine-stalled" && ok "a stale lock (dead owner) does not count as a live crew" \
  || no "dead-owner lock should not suppress the alarm; got: $out"
rm -rf "$LOCKS/DEAD-1.lock"
mkdir -p "$LOCKS/LIVE-1.lock"; printf 'pid=%s\ntask=LIVE-1\n' "$$" > "$LOCKS/LIVE-1.lock/owner"
rm -f "$STATE"
out="$(run check)"
[ -z "$out" ] && ok "a lock with a LIVE owner counts as a running crew (silent)" \
  || no "live-owner lock should suppress the alarm; got: $out"
rm -rf "$LOCKS/LIVE-1.lock"

# ── DEBOUNCE: one alarm per outage; re-armed only after it clears ──────────────
rm -f "$STATE"; beacon 200 30 $$
out1="$(run check HB_ASSUME_CREWS=0)"
out2="$(run check HB_ASSUME_CREWS=0)"
if has "$out1" "engine-stalled" && [ -z "$out2" ] && [ -f "$STATE" ]; then
  ok "second consecutive outage cycle stays quiet (debounced)"
else no "debounce failed; out2='$out2'"; fi
beacon 5 30 $$
out3="$(run check HB_ASSUME_CREWS=0)"
[ ! -f "$STATE" ] && ok "recovery clears the state file (alarm re-armed)" || no "state not cleared on recovery"
beacon 200 30 $$
out5="$(run check HB_ASSUME_CREWS=0)"
has "$out5" "engine-stalled" && ok "a NEW outage alarms again after re-arming" || no "re-armed alarm did not fire; got: $out5"

# ── status never alarms, and reports the verdict + exit code ───────────────────
rm -f "$STATE"; beacon 200 30 $$
out="$(run status HB_ASSUME_CREWS=0)"; rc=$?
if (( rc != 0 )) && has "$out" "verdict: alarm (engine-stalled)" && [ ! -f "$STATE" ]; then
  ok "status reports the verdict, exits non-zero, and sends nothing"
else no "status behaved wrong; rc=$rc out=$out"; fi

# ── the generated plist points at THIS checkout and runs `check` ───────────────
out="$(run plist)"
if has "$out" "$ROOT/dozers/heartbeat-check.sh" && has "$out" "<string>check</string>" && has "$out" "StartInterval"; then
  ok "generated plist targets this checkout, runs \`check\`, on an interval"
else no "plist wrong; got: $out"; fi
if command -v plutil >/dev/null 2>&1; then
  printf '%s' "$out" > "$TMP/agent-lint.plist"
  plutil -lint "$TMP/agent-lint.plist" >/dev/null 2>&1 \
    && ok "generated plist is valid (plutil -lint)" || no "generated plist fails plutil -lint"
fi

# ── creds: reports what it needs to shout, and never prints a secret VALUE ──────
NOKEY="$TMP/nokey.env"; printf 'BUZZ_RELAY_URL=wss://example.invalid\nBUZZ_PRIVATE_KEY=\n' > "$NOKEY"
out="$(run creds HB_VAULT_ENV="$NOKEY")"; rc=$?
if (( rc != 0 )) && has "$out" "BUZZ_PRIVATE_KEY" && has "$out" "the alarm would be silent"; then
  ok "creds fails loudly when the signing key is absent"
else no "creds should fail on a missing key; rc=$rc out=$out"; fi
WITHKEY="$TMP/withkey.env"; printf 'BUZZ_RELAY_URL=wss://example.invalid\nBUZZ_PRIVATE_KEY=deadbeef\n' > "$WITHKEY"
out="$(run creds HB_VAULT_ENV="$WITHKEY")"
has "$out" "deadbeef" && no "creds LEAKED the signing key value" || ok "creds never prints a secret value"

# ── install REFUSES to load a watchdog that cannot shout (GSAI-21's lesson) ─────
# A monitor that merged is not a monitor that fires, so an install that cannot prove
# delivery is a hard stop — and it must not leave a half-installed agent behind.
PL="$TMP/agent.plist"
out="$(run install HB_VAULT_ENV="$NOKEY" HB_PLIST_PATH="$PL")"; rc=$?
if (( rc != 0 )) && has "$out" "refusing to install" && [ ! -f "$PL" ]; then
  ok "install refuses (and writes no plist) when the alarm cannot be delivered"
else no "install should refuse a mute watchdog; rc=$rc plist_exists=$([ -f "$PL" ] && echo yes || echo no) out=$out"; fi

if [[ $fail == 0 ]]; then echo "heartbeat-check-test: PASS"; else echo "heartbeat-check-test: FAIL" >&2; exit 1; fi
