#!/usr/bin/env bash
# tests/heartbeat-check-test.sh — acceptance suite for the engine watchdog (GSAI-31).
#
# One case per row of the decision table in dozers/heartbeat-check.sh, plus the
# properties that decide whether this thing is a watchdog or a decoration:
#   DEBOUNCE  — one alarm per outage, re-armed only after the condition clears
#   DELIVERS  — the alarm reaches the Linear tracking issue as a LABEL (board:to_review),
#               Buzz is an optional second hop that never suppresses it, and the flag
#               comes down on recovery (and stays armed until the clear is delivered)
#   HONEST    — `creds` is green with Linear alone, red only when NO channel can deliver,
#               and never prints a secret value
#
# No network: every Linear call goes through HB_LINEAR_BIN (a recorder), every Buzz send
# through a fake `buzz` on PATH, and the dry-run cases print instead of delivering.
# Run:  bash tests/heartbeat-check-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/dozers/heartbeat-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
has() { grep -qF "$2" <<<"$1"; }

HB="$TMP/heartbeat"; LOCKS="$TMP/locks"; STATE="$TMP/state"; LOG="$TMP/log"; CALLS="$TMP/linear-calls"
mkdir -p "$LOCKS"

# A pinned config so fanout / issue / channel do not depend on the real org/config.yaml.
CFG="$TMP/config.yaml"
cat > "$CFG" <<CFG
fanout: 5
linear_teams: "T1,T2"
alarm_issue: "GSAI-38"
alarm_channel: "chan-1"
alarm_mention: "fizzpubkey"
alarm_interval: 300
CFG

# The Linear recorder: logs every call, answers like the real helper would.
FAKE_LINEAR="$TMP/fake-linear"
cat > "$FAKE_LINEAR" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
[ "${FAKE_FAIL:-}" = "1" ] && { echo "linear: simulated failure"; exit 1; }
case "$1" in
  alarm-probe) printf 'GSAI-38\tbacklog\tclear\tDozer engine alarm\n' ;;
  alarm-raise) echo "GSAI-38 -> board:to_review https://linear.app/x/comment/1" ;;
  alarm-clear) echo "GSAI-38 -> flag removed https://linear.app/x/comment/2" ;;
  count-ready) echo "${FAKE_READY:-3}" ;;
esac
FAKE
chmod +x "$FAKE_LINEAR"
# A fake buzz CLI for the optional-hop case.
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FAKE_BUZZ_CALLS"\n' > "$FAKEBIN/buzz"; chmod +x "$FAKEBIN/buzz"
BUZZ_CALLS="$TMP/buzz-calls"

NOKEY="$TMP/nokey.env"; printf 'BUZZ_RELAY_URL=wss://example.invalid\nBUZZ_PRIVATE_KEY=\n' > "$NOKEY"
WITHKEY="$TMP/withkey.env"; printf 'BUZZ_RELAY_URL=wss://example.invalid\nBUZZ_PRIVATE_KEY=deadbeef\n' > "$WITHKEY"
LINKEY="$TMP/linear.env"; printf 'LINEAR_API_KEY=lin_secretvalue\n' > "$LINKEY"
NOLIN="$TMP/nolinear.env"; printf 'LINEAR_API_KEY=\n' > "$NOLIN"

# Write a beacon that is <age> seconds old, with the given cadence + pid.
beacon() { # <age-seconds> <cadence> <pid> [inflight] [poll]
  printf 'pid=%s\nhost=%s\nts=%s\ninflight=%s\npoll=%s\nevery=%s\n' \
    "$3" "$(hostname -s 2>/dev/null || echo local)" "$(date -u +%FT%TZ)" "${4:-0}" "${5:-1}" "$2" > "$HB"
  # Age is what the check measures, and it measures it by MTIME — so set the mtime.
  local when; when="$(( $(date +%s) - $1 ))"
  touch -t "$(date -r "$when" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$when" +%Y%m%d%H%M.%S)" "$HB"
}
# Pre-seed the poll tracker: poll <n> first seen <ago> seconds ago.
seed_poll() { printf 'poll=%s\npoll_since=%s\n' "$1" "$(( $(date +%s) - $2 ))" > "$STATE"; }
armed() { grep -q '^alarmed=' "$STATE" 2>/dev/null; }

# Defaults: Linear configured (key + recorder), Buzz key absent, dry-run ON.
# Override per case with extra VAR=value args; DRY=0 as the first arg turns dry-run off.
run() { # [DRY=0] <subcommand> <extra env...>
  local dry=1; [ "${1:-}" = "DRY=0" ] && { dry=0; shift; }
  local sub="$1"; shift
  local out r
  out="$(env -u LINEAR_API_KEY -u BUZZ_PRIVATE_KEY -u BUZZ_RELAY_URL \
      HEARTBEAT_FILE="$HB" LOCK_DIR="$LOCKS" HB_STATE_FILE="$STATE" HB_RUN_LOG="$LOG" \
      DOZER_CONFIG="$CFG" HB_LINEAR_BIN="$FAKE_LINEAR" FAKE_CALLS="$CALLS" FAKE_BUZZ_CALLS="$BUZZ_CALLS" \
      HB_LINEAR_ENV="$LINKEY" HB_VAULT_ENV="$NOKEY" \
      HB_DRY_RUN="$dry" "$@" bash "$CHECK" "$sub" 2>&1)"; r=$?
  printf '%s' "$out"; return "$r"
}

echo "== dozer heartbeat watchdog =="
rm -f "$STATE" "$CALLS" "$BUZZ_CALLS"

# ── ROW: beacon missing + a loop process exists -> ALARM ───────────────────────
rm -f "$HB"
out="$(run check HB_ASSUME_LOOP=yes)"
if has "$out" "not beating" && has "$out" "beacon-never-written"; then
  ok "no beacon while a loop runs -> ALARM (beacon never written)"
else no "missing-beacon-with-loop should alarm; got: $out"; fi
rm -f "$STATE"

# ── ROW: beacon missing + no loop process -> silent ────────────────────────────
out="$(run check HB_ASSUME_LOOP=no)"
if [ -z "$out" ] && ! armed; then ok "no beacon and no engine -> silent (nothing is meant to run)"
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
rm -f "$STATE"
beacon 5 30 $$
out="$(run check HB_ASSUME_ENGINE=dead HB_ASSUME_CREWS=0)"
has "$out" "engine-gone" && ok "fresh beacon naming a DEAD pid -> ALARM (engine gone)" \
  || no "dead engine pid should alarm; got: $out"

# ── the alarm renders real, actionable text, aimed at the Linear surface ───────
if has "$out" "🔴" && has "$out" "would alarm-raise GSAI-38" && has "$out" "board:to_review" && has "$out" "dozers/service.sh restart"; then
  ok "alarm text carries the flag, the tracking issue + label, and the restart command"
else no "alarm text is missing flag/issue/label/restart; got: $out"; fi
has "$out" "Buzz hop skipped" && ok "with no BUZZ_PRIVATE_KEY the Buzz hop is skipped, quietly, as optional" \
  || no "Buzz hop should be reported as skipped; got: $out"

# ── ROW: alive but NOT DISPATCHING (poll frozen + idle slots + queued work) ───
# The beacon is fresh and a crew is live — every older row stays silent here. The
# poll tracker in the state file is what catches it: poll unchanged for > 10 cycles,
# inflight < fanout, and greenlit work queued.
beacon 5 30 $$ 1 42; seed_poll 42 400          # poll=42 first seen 400s ago = 13 cycles of 30s
out="$(run check HB_ASSUME_CREWS=1 HB_ASSUME_READY=6)"
if has "$out" "not-dispatching" && has "$out" "inflight=1 of fanout=5" && has "$out" "6 greenlit issue(s) queued"; then
  ok "poll frozen 13 cycles + inflight<fanout + 6 queued -> ALARM (alive but not dispatching)"
else no "not-dispatching row did not alarm; got: $out"; fi
beacon 5 30 $$ 5 42; seed_poll 42 400          # inflight == fanout: a full wave, legitimate
out="$(run check HB_ASSUME_CREWS=5 HB_ASSUME_READY=6)"
[ -z "$out" ] && ok "poll frozen but inflight == fanout (full wave) -> silent" || no "full wave should be silent; got: $out"
beacon 5 30 $$ 1 42; seed_poll 42 400
out="$(run check HB_ASSUME_CREWS=1 HB_ASSUME_READY=0)"
[ -z "$out" ] && ok "poll frozen + idle slots but NOTHING queued -> silent" || no "empty queue should be silent; got: $out"
beacon 5 30 $$ 1 42; seed_poll 42 200          # only 6 cycles: not yet
out="$(run check HB_ASSUME_CREWS=1 HB_ASSUME_READY=6)"
[ -z "$out" ] && ok "poll frozen for only 6 cycles -> silent (threshold is > 10)" || no "6 cycles should be silent; got: $out"
beacon 5 30 $$ 1 43; seed_poll 42 400          # the poll MOVED since last check
out="$(run check HB_ASSUME_CREWS=1 HB_ASSUME_READY=6)"
since="$(grep '^poll_since=' "$STATE" | cut -d= -f2)"; nowish=$(( $(date +%s) - since ))
if [ -z "$out" ] && grep -q '^poll=43' "$STATE" && [ "$nowish" -le 5 ]; then
  ok "poll advanced -> silent, tracker resets to the new value seen just now"
else no "poll advance should reset the tracker; out='$out' state=$(cat "$STATE")"; fi
: > "$LOG"; beacon 5 30 $$ 1 42; seed_poll 42 400
out="$(run check HB_ASSUME_CREWS=1 FAKE_FAIL=1)"   # the queue query itself fails
if [ -z "$out" ] && grep -q 'ERROR: queued-work query failed' "$LOG"; then
  ok "queue query failure -> silent but logged (an unknown queue is not a stall)"
else no "queue failure should be silent+logged; out='$out' log=$(tail -2 "$LOG")"; fi
# The real query is only issued when the cheap probes already look frozen.
rm -f "$CALLS"; beacon 5 30 $$ 1 7; seed_poll 7 10
run check HB_ASSUME_CREWS=1 >/dev/null
[ ! -f "$CALLS" ] && ok "a healthy engine never costs a Linear query (count-ready not called)" \
  || no "count-ready was called on a healthy engine: $(cat "$CALLS")"
rm -f "$CALLS"; beacon 5 30 $$ 1 7; seed_poll 7 400
run check HB_ASSUME_CREWS=1 >/dev/null
grep -q '^count-ready' "$CALLS" 2>/dev/null && ok "a frozen poll with idle slots asks Linear for the queue (count-ready)" \
  || no "count-ready should have been called; calls=$(cat "$CALLS" 2>/dev/null)"

# ── live crews are counted by LIVE owner pid, not by lock presence ─────────────
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
if has "$out1" "engine-stalled" && [ -z "$out2" ] && armed; then
  ok "second consecutive outage cycle stays quiet (debounced)"
else no "debounce failed; out2='$out2'"; fi
beacon 5 30 $$
out3="$(run check HB_ASSUME_CREWS=0)"
if ! armed && has "$out3" "would alarm-clear GSAI-38" && has "$out3" "🟢"; then
  ok "recovery takes the flag down (alarm-clear) and re-arms"
else no "recovery should clear + re-arm; armed=$(armed && echo yes || echo no) out3='$out3'"; fi
beacon 200 30 $$
out5="$(run check HB_ASSUME_CREWS=0)"
has "$out5" "engine-stalled" && ok "a NEW outage alarms again after re-arming" || no "re-armed alarm did not fire; got: $out5"

# ── DELIVERS: for real (not dry-run), through the recorder ─────────────────────
rm -f "$STATE" "$CALLS" "$BUZZ_CALLS"; : > "$LOG"; beacon 200 30 $$
run DRY=0 check HB_ASSUME_CREWS=0 >/dev/null
if grep -q '^alarm-raise GSAI-38 ' "$CALLS" 2>/dev/null && grep -q '🔴' "$CALLS" && grep -q '^alarm_via=linear$' "$STATE"; then
  ok "a real alarm calls alarm-raise on the tracking issue with the detail, and records via=linear"
else no "alarm-raise not recorded; calls=$(cat "$CALLS" 2>/dev/null) state=$(cat "$STATE")"; fi
grep -q 'Buzz hop skipped' "$LOG" && ok "…and logs that the Buzz hop was skipped (no key), without failing" \
  || no "Buzz skip should be logged; log=$(cat "$LOG")"
[ ! -f "$BUZZ_CALLS" ] && ok "…and never invoked buzz" || no "buzz was called without a key"
# recovery, delivered
rm -f "$CALLS"; beacon 5 30 $$
run DRY=0 check HB_ASSUME_CREWS=0 >/dev/null
if grep -q '^alarm-clear GSAI-38 ' "$CALLS" 2>/dev/null && grep -q '🟢' "$CALLS" && ! armed; then
  ok "recovery calls alarm-clear on the tracking issue and disarms"
else no "alarm-clear not recorded / still armed; calls=$(cat "$CALLS" 2>/dev/null)"; fi

# ── the flag is not considered down until the clear is DELIVERED ───────────────
rm -f "$STATE" "$CALLS"; beacon 200 30 $$
run DRY=0 check HB_ASSUME_CREWS=0 >/dev/null
beacon 5 30 $$; : > "$LOG"
run DRY=0 check HB_ASSUME_CREWS=0 FAKE_FAIL=1 >/dev/null
if armed && grep -q 'NOT delivered — will retry' "$LOG"; then
  ok "a failed clear keeps the alarm armed and retries next cycle (no stale flag left behind)"
else no "failed clear should stay armed; armed=$(armed && echo yes || echo no) log=$(tail -1 "$LOG")"; fi
rm -f "$CALLS"; run DRY=0 check HB_ASSUME_CREWS=0 >/dev/null
grep -q '^alarm-clear' "$CALLS" 2>/dev/null && ! armed && ok "…and the retry clears it" || no "retry did not clear"

# ── Buzz is a second hop when the key IS present ───────────────────────────────
rm -f "$STATE" "$CALLS" "$BUZZ_CALLS"; beacon 200 30 $$
run DRY=0 check HB_ASSUME_CREWS=0 HB_VAULT_ENV="$WITHKEY" PATH="$FAKEBIN:$PATH" >/dev/null
if grep -q '^alarm-raise' "$CALLS" && grep -q -- '--channel chan-1' "$BUZZ_CALLS" 2>/dev/null && grep -q '@Fizz' "$BUZZ_CALLS" && grep -q '^alarm_via=linear,buzz$' "$STATE"; then
  ok "with a Buzz key the alarm goes to BOTH: Linear label + Buzz @Fizz"
else no "dual delivery failed; calls=$(cat "$CALLS" 2>/dev/null) buzz=$(cat "$BUZZ_CALLS" 2>/dev/null) state=$(cat "$STATE")"; fi

# ── with NO channel at all the alarm is honest about being mute ────────────────
rm -f "$STATE" "$CALLS"; : > "$LOG"; beacon 200 30 $$
run DRY=0 check HB_ASSUME_CREWS=0 HB_LINEAR_ENV="$NOLIN" >/dev/null
if ! armed && grep -q 'delivered to NO channel' "$LOG" && [ ! -f "$CALLS" ]; then
  ok "no Linear key + no Buzz key -> logged as MUTE, not marked as alarmed"
else no "mute alarm should be logged and unarmed; log=$(tail -2 "$LOG")"; fi

# ── status never alarms, and reports the verdict + exit code ───────────────────
rm -f "$STATE" "$CALLS"; beacon 200 30 $$
out="$(run DRY=0 status HB_ASSUME_CREWS=0)"; rc=$?
if (( rc != 0 )) && has "$out" "verdict: alarm (engine-stalled)" && ! armed && [ ! -f "$CALLS" ]; then
  ok "status reports the verdict, exits non-zero, and sends nothing"
else no "status behaved wrong; rc=$rc out=$out"; fi

# ── the generated plist points at THIS checkout and runs `check` ───────────────
out="$(run plist)"
if has "$out" "$ROOT/dozers/heartbeat-check.sh" && has "$out" "<string>check</string>" && has "$out" "StartInterval"; then
  ok "generated plist targets this checkout, runs \`check\`, on an interval"
else no "plist wrong; got: $out"; fi
out="$(run plist HB_INSTALL_ROOT=/opt/stable/dozers)"
has "$out" "/opt/stable/dozers/dozers/heartbeat-check.sh" && ok "HB_INSTALL_ROOT retargets the plist at a stable checkout" \
  || no "HB_INSTALL_ROOT ignored; got: $out"
if command -v plutil >/dev/null 2>&1; then
  printf '%s' "$(run plist)" > "$TMP/agent-lint.plist"
  plutil -lint "$TMP/agent-lint.plist" >/dev/null 2>&1 \
    && ok "generated plist is valid (plutil -lint)" || no "generated plist fails plutil -lint"
fi

# ── HONEST creds: green on Linear alone, red only when nothing can deliver ─────
out="$(run creds)"; rc=$?
if (( rc == 0 )) && has "$out" "Linear board : CAN DELIVER" && has "$out" "reachable ✓" && has "$out" "Buzz hop     : skipped (optional)"; then
  ok "creds is GREEN with the Linear path alone while BUZZ_PRIVATE_KEY is empty"
else no "creds should pass on Linear alone; rc=$rc out=$out"; fi
has "$out" "lin_secretvalue" && no "creds LEAKED the Linear key value" || ok "creds never prints the Linear key value"
out="$(run creds HB_VAULT_ENV="$WITHKEY" PATH="$FAKEBIN:$PATH")"
has "$out" "deadbeef" && no "creds LEAKED the Buzz key value" || ok "creds never prints the Buzz key value"
has "$out" "Buzz hop     : CAN DELIVER" && ok "creds reports the Buzz hop as live when its key is present" || no "Buzz hop should be green; out=$out"
out="$(run creds HB_LINEAR_ENV="$NOLIN")"; rc=$?
if (( rc != 0 )) && has "$out" "NO channel can deliver" && has "$out" "the alarm would be silent"; then
  ok "creds fails loudly when NEITHER channel can deliver"
else no "creds should fail with no channel; rc=$rc out=$out"; fi
out="$(run creds FAKE_FAIL=1)"; rc=$?
(( rc != 0 )) && has "$out" "NOT reachable" && ok "creds is a real round-trip: an unreachable tracking issue is MUTE, not green" \
  || no "unreachable issue should fail creds; rc=$rc out=$out"

# ── install REFUSES to load a watchdog that cannot shout (GSAI-21's lesson) ─────
PL="$TMP/agent.plist"
out="$(run install HB_LINEAR_ENV="$NOLIN" HB_PLIST_PATH="$PL")"; rc=$?
if (( rc != 0 )) && has "$out" "refusing to install" && [ ! -f "$PL" ]; then
  ok "install refuses (and writes no plist) when no channel can deliver"
else no "install should refuse a mute watchdog; rc=$rc plist_exists=$([ -f "$PL" ] && echo yes || echo no) out=$out"; fi

if [[ $fail == 0 ]]; then echo "heartbeat-check-test: PASS"; else echo "heartbeat-check-test: FAIL" >&2; exit 1; fi
