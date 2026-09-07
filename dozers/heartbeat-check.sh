#!/usr/bin/env bash
# dozers/heartbeat-check.sh — the watchdog that reads the engine's beacon (GSAI-31).
#
# `dozers/dozer.sh loop` keeps a beacon fresh at $HEARTBEAT_FILE (see beat_start there).
# This is the other half: something that NOTICES when it stops. A dead engine looks
# exactly like an empty board from the outside — that is the failure that cost us on
# 2026-09-02, and the reason GSAI-21 shipped an interim ps-based check. This replaces
# it, and covers strictly more: a loop that is alive but WEDGED still stops beating,
# a beacon that is stale for a legitimate reason (a long crew run) stays silent, and
# a loop that beats but never dispatches (idle slots + queued work) is caught too.
#
#   heartbeat-check.sh check       # one pass: decide, log, alarm/clear if warranted (default)
#   heartbeat-check.sh status      # print the verdict and exit; never alarms
#   heartbeat-check.sh creds       # can this watchdog actually shout? (names, never values)
#   heartbeat-check.sh install     # generate + load the launchd agent (every alarm_interval)
#   heartbeat-check.sh uninstall   # unload + remove it
#   heartbeat-check.sh plist       # print the generated plist (no install)
#
# ── The decision ────────────────────────────────────────────────────────────────
#   beacon missing + a `dozer.sh loop` process exists   -> ALARM  beacon never written
#   beacon missing + no loop process                    -> silent (nothing is meant to run)
#   beacon names a DEAD pid on this host                -> ALARM  engine process gone
#   beacon stale (age >= 3x its cadence) + no live crew -> ALARM  engine stalled
#   poll= frozen > 10 cycles + inflight < fanout
#                            + greenlit work queued     -> ALARM  alive but not dispatching
#   beacon stale + a live crew is holding a run-lock    -> silent, but logged (long task)
#   beacon fresh                                        -> silent
#
# Staleness is measured against the cadence the beacon PUBLISHES (`every=`), and the
# slot count against `fanout:` in org/config.yaml — nothing is duplicated here, so the
# emitter, the engine and the watchdog cannot drift apart.
#
# ── Where the alarm goes ─────────────────────────────────────────────────────────
# PRIMARY: Linear. The alarm IS a label — `board:to_review` on the standing tracking
# issue (`alarm_issue:` in org/config.yaml). The Board view filters on exactly that
# label and nothing else, so the label is what puts the outage in front of a human.
# The comment (what stalled, the beacon, the age, the restart command) is the detail;
# it notifies nobody on its own, because LINEAR_API_KEY authenticates as the workspace's
# only human and Linear never notifies you about your own comment. On recovery the flag
# comes down (or swaps to `board:responded` if a human commented in between) — a stale
# flag on the Board is a lie, so the alarm is not disarmed until the clear succeeds.
# OPTIONAL second hop: Buzz (`alarm_channel`, @`alarm_mention`) — sent when
# BUZZ_PRIVATE_KEY is present, skipped quietly when it is not. A missing optional
# channel never suppresses the primary one.
#
# Debounced: one alarm per outage. `alarmed=` in the state file marks an outstanding
# alarm and is removed only when the condition clears AND the clear was delivered.
#
# Test / manual seams (all unset in production — the real probes run when absent):
#   HB_ASSUME_LOOP=yes|no        bypass the `ps` scan for a dozer.sh loop process
#   HB_ASSUME_ENGINE=alive|dead  bypass the beacon-pid liveness probe
#   HB_ASSUME_CREWS=<n>          bypass the live-run-lock scan
#   HB_ASSUME_READY=<n>          bypass the greenlit-work query (the not-dispatching row)
#   HB_LINEAR_BIN=<cmd>          replace `python3 tasks/_linear_api.py` (a recorder in tests)
#   HB_DRY_RUN=1                 print the alarm/clear instead of delivering it
#   HB_STATE_FILE / HB_RUN_LOG   override the debounce state + log paths
#   HB_VAULT_ENV / HB_LINEAR_ENV override the Buzz / Linear credential files
#   HB_ISSUE / HB_PLIST_PATH     override the tracking issue / the agent's plist path
#   HB_INSTALL_ROOT              generate the plist against another checkout (see install)
#   HEARTBEAT_FILE / LOCK_DIR    point at fixtures
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cfg() { grep -E "^$1:" "${DOZER_CONFIG:-$ROOT/org/config.yaml}" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true; }
expand() { printf '%s' "${1/#\~/$HOME}"; }

HEARTBEAT_FILE="${HEARTBEAT_FILE:-$HOME/.dozers/heartbeat}"
LOCK_DIR="${LOCK_DIR:-$HOME/.dozers/locks}"
STATE_FILE="${HB_STATE_FILE:-$HOME/.dozers/heartbeat-check.state}"
RUN_LOG="${HB_RUN_LOG:-$HOME/.dozers/logs/heartbeat-check.log}"
CHANNEL="${HB_CHANNEL:-$(cfg alarm_channel)}"
MENTION="${HB_MENTION:-$(cfg alarm_mention)}"
VAULT_ENV="$(expand "${HB_VAULT_ENV:-$(cfg alarm_env)}")"
LINEAR_ENV="$(expand "${HB_LINEAR_ENV:-$(cfg alarm_linear_env)}")"
ALARM_ISSUE="${HB_ISSUE:-$(cfg alarm_issue)}"
FANOUT="$(cfg fanout)"; case "$FANOUT" in ''|*[!0-9]*) FANOUT=1 ;; esac
STALL_CYCLES="${HB_STALL_CYCLES:-10}"          # poll= frozen for more than this many cadences
INTERVAL="${HB_INTERVAL:-$(cfg alarm_interval)}"; INTERVAL="${INTERVAL:-300}"
LABEL="${HB_SERVICE_LABEL:-com.dozers.heartbeat-check}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$RUN_LOG")" 2>/dev/null || true
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$RUN_LOG" 2>/dev/null || true; }

# Credentials for standalone/scheduled runs (anything already in the env wins).
#
# `set -a` around this is LOAD-BEARING, not decoration: the vault files assign without
# `export`, and the senders run in child processes. GSAI-21 shipped without it — the key
# never crossed the subshell, the watchdog was silent by construction, and nobody knew
# for four days. A watchdog that cannot prove it can shout is not a watchdog.
set -a
[ -n "$VAULT_ENV" ]  && [ -f "$VAULT_ENV" ]  && . "$VAULT_ENV"
[ -n "$LINEAR_ENV" ] && [ -f "$LINEAR_ENV" ] && . "$LINEAR_ENV"
set +a
# The Linear helper scopes list queries to these teams (the ready count below).
[ -z "${LINEAR_TEAMS:-}" ] && LINEAR_TEAMS="$(cfg linear_teams)"
[ -z "${LINEAR_TEAMS:-}" ] && LINEAR_TEAMS="$(cfg linear_team)"
export LINEAR_TEAMS

# ── probes ──────────────────────────────────────────────────────────────────────
beacon_epoch() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
field() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
num() { case "$1" in ''|*[!0-9]*) printf '%s' "${2:-0}" ;; *) printf '%s' "$1" ;; esac; }

# The one Linear entry point. Tests point HB_LINEAR_BIN at a recorder; production runs
# the same helper the engine itself uses, so the label vocabulary cannot drift.
linear_cmd() {
  if [ -n "${HB_LINEAR_BIN:-}" ]; then "$HB_LINEAR_BIN" "$@"
  else python3 "$ROOT/tasks/_linear_api.py" "$@"; fi
}
linear_configured() { [ -n "${LINEAR_API_KEY:-}" ] && [ -n "$ALARM_ISSUE" ]; }
buzz_configured()   { [ -n "${BUZZ_PRIVATE_KEY:-}" ] && [ -n "${BUZZ_RELAY_URL:-}" ] && [ -n "$CHANNEL" ] && command -v buzz >/dev/null 2>&1; }

# Is ANY `dozer.sh loop` process on this box? Used only to tell "no beacon because
# nothing runs" (fine) from "no beacon although the engine runs" (broken).
# NB: `pgrep -f 'dozer.sh loop'` does NOT match the live processes on this macOS box
# (an argv-readability quirk — `ps` sees them, pgrep does not), so scanning `ps` is
# the reliable probe. Inherited from GSAI-21, where pgrep would have false-alarmed
# on every cycle.
loop_process_exists() {
  case "${HB_ASSUME_LOOP:-}" in yes) return 0 ;; no) return 1 ;; esac
  local n; n=$(ps -Ao command= 2>/dev/null | grep -F 'dozer.sh loop' | grep -cv 'grep')
  [ "${n:-0}" -gt 0 ]
}

# Is the engine the beacon NAMES still alive? Only meaningful when the beacon was
# written on this host — a pid from another machine says nothing about this one.
# Returns 0 alive, 1 dead, 2 unknown (no pid, or a foreign host).
engine_alive() {
  case "${HB_ASSUME_ENGINE:-}" in alive) return 0 ;; dead) return 1 ;; esac
  local pid host me
  pid="$(field "$HEARTBEAT_FILE" pid)"; host="$(field "$HEARTBEAT_FILE" host)"
  me="$(hostname -s 2>/dev/null || echo local)"
  [ -n "$pid" ] || return 2
  [ -n "$host" ] && [ "$host" != "$me" ] && return 2
  kill -0 "$pid" 2>/dev/null
}

# How many crews are genuinely running right now: run-locks whose owner pid is alive.
# A stale lock left by a crashed crew must not buy the engine silence — that is the
# reaper's problem, and counting it here would mask a real stall.
live_crews() {
  if [ -n "${HB_ASSUME_CREWS:-}" ]; then printf '%s' "$HB_ASSUME_CREWS"; return 0; fi
  local n=0 lock pid
  for lock in "$LOCK_DIR"/*.lock; do
    [ -d "$lock" ] || continue
    pid="$(field "$lock/owner" pid)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && n=$((n+1))
  done
  printf '%s' "$n"
}

# How much greenlit work is queued (dozer:ready + lane:). Only asked when the cheaper
# probes already say the dispatcher looks frozen, so a healthy engine never costs an
# API call. Prints a number; prints nothing (and logs why) if the query fails — an
# unknown queue is not evidence of a stall.
queued_work() {
  if [ -n "${HB_ASSUME_READY:-}" ]; then printf '%s' "$HB_ASSUME_READY"; return 0; fi
  linear_configured || { log "not-dispatching row skipped: no LINEAR_API_KEY, cannot count queued work."; return 0; }
  local out; out="$(linear_cmd count-ready 2>&1)" || { log "ERROR: queued-work query failed: $out"; return 0; }
  printf '%s' "$(num "$out" '')"
}

# ── state file ──────────────────────────────────────────────────────────────────
# One small file, two jobs: the debounce (`alarmed=` while an alarm is outstanding,
# plus which channels carried it) and the poll tracker for the not-dispatching row
# (`poll=` last seen, `poll_since=` when that value was first seen).
sget() { field "$STATE_FILE" "$1"; }
armed() { [ -n "$(sget alarmed)" ]; }
swrite() { # <poll> <poll_since> [alarmed-reason] [alarm-via] [alarm-ts]
  local tmp="$STATE_FILE.tmp"
  { printf 'poll=%s\npoll_since=%s\n' "$1" "$2"
    if [ -n "${3:-}" ]; then printf 'alarmed=%s\nalarm_ts=%s\nalarm_via=%s\n' "$3" "${5:-$(date -u +%FT%TZ)}" "${4:-}"; fi
  } > "$tmp" && mv -f "$tmp" "$STATE_FILE"
}

# ── the verdict ─────────────────────────────────────────────────────────────────
# Sets VERDICT=alarm|silent, REASON=<short slug>, DETAIL=<one human line>, plus the
# poll tracker (POLL_NOW / POLL_SINCE) the caller persists.
assess() {
  local age cadence stale_after crews poll inflight now queued frozen_for frozen_cycles
  crews="$(live_crews)"; now="$(date +%s)"
  POLL_NOW=""; POLL_SINCE=""

  if [ ! -f "$HEARTBEAT_FILE" ]; then
    if loop_process_exists; then
      VERDICT=alarm; REASON="beacon-never-written"
      DETAIL="a \`dozer.sh loop\` process is running but no beacon exists at $HEARTBEAT_FILE — the engine is up and not reporting."
    else
      VERDICT=silent; REASON="no-engine"
      DETAIL="no beacon and no loop process — nothing is supposed to be running."
    fi
    return
  fi

  cadence="$(num "$(field "$HEARTBEAT_FILE" every)" 30)"
  stale_after=$(( cadence * 3 ))
  age=$(( now - $(beacon_epoch "$HEARTBEAT_FILE") ))
  poll="$(field "$HEARTBEAT_FILE" poll)"; inflight="$(num "$(field "$HEARTBEAT_FILE" inflight)" 0)"

  # Poll tracker: same value as last time -> keep its first-seen time; else it moved now.
  POLL_NOW="$poll"
  if [ -n "$poll" ] && [ "$(sget poll)" = "$poll" ] && [ -n "$(sget poll_since)" ]; then POLL_SINCE="$(sget poll_since)"
  else POLL_SINCE="$now"; fi
  frozen_for=$(( now - POLL_SINCE )); frozen_cycles=$(( frozen_for / cadence ))

  engine_alive; local ea=$?
  if [ "$ea" -eq 1 ]; then
    VERDICT=alarm; REASON="engine-gone"
    DETAIL="the beacon names pid $(field "$HEARTBEAT_FILE" pid), which is no longer running on this host. Last beat ${age}s ago; $crews crew(s) still holding a lock."
    return
  fi

  if [ "$age" -ge "$stale_after" ] && [ "$crews" -eq 0 ]; then
    VERDICT=alarm; REASON="engine-stalled"
    DETAIL="beacon has not advanced for ${age}s (threshold ${stale_after}s = 3x its ${cadence}s cadence) and no crew is running. The engine is wedged or gone."
    return
  fi

  # Alive (beating) but not dispatching: the poll counter has not moved for more than
  # STALL_CYCLES cadences while slots sit idle AND greenlit work is queued. A full wave
  # (inflight == fanout) with a frozen poll is legitimate; idle capacity beside queued
  # work is the invariant that should never hold, whatever breaks it (GSAI-37 is the
  # known cause — this only detects it after the fact).
  if [ "$frozen_cycles" -gt "$STALL_CYCLES" ] && [ "$inflight" -lt "$FANOUT" ]; then
    queued="$(queued_work)"
    if [ -n "$queued" ] && [ "$queued" -gt 0 ]; then
      VERDICT=alarm; REASON="not-dispatching"
      DETAIL="beacon is fresh (beat ${age}s ago) but poll=${poll} has not moved for ${frozen_for}s (${frozen_cycles} cycles of ${cadence}s) with inflight=${inflight} of fanout=${FANOUT} and ${queued} greenlit issue(s) queued. The engine is alive but not claiming work."
      return
    fi
  fi

  if [ "$age" -lt "$stale_after" ]; then
    VERDICT=silent; REASON="fresh"
    DETAIL="beat ${age}s ago (cadence ${cadence}s), $crews crew(s) in flight, poll=${poll} for ${frozen_for}s."
    return
  fi

  # A long crew run is not a fault — but it IS worth a log line, because with the
  # beat on its own clock (GSAI-31) a healthy engine should never go stale at all.
  VERDICT=silent; REASON="stale-but-busy"
  DETAIL="beacon ${age}s old (threshold ${stale_after}s) but $crews crew(s) are alive — long task, not a stall."
}

# ── the alarm ───────────────────────────────────────────────────────────────────
RESTART='cd ~/Code/dozers && dozers/service.sh restart   # or: dozers/service.sh install'
headline() { case "$REASON" in not-dispatching) echo 'Dozer engine is alive but not dispatching' ;; *) echo 'Dozer engine is not beating' ;; esac; }

alarm_body() {
  printf '🔴 **%s** — %s\n\n%s\n\nBeacon `%s`:\n```\n%s\n```\nRestart:\n```\n%s\n```\n_dozers/heartbeat-check.sh (GSAI-31) — this flag clears itself when the engine recovers._' \
    "$(headline)" "$REASON" "$DETAIL" "$HEARTBEAT_FILE" "$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo '(no beacon file)')" "$RESTART"
}
recovery_body() {
  printf '🟢 **Dozer engine recovered** — now %s\n\n%s\n\nBeacon `%s`:\n```\n%s\n```\n_dozers/heartbeat-check.sh (GSAI-31) — cleared automatically; nothing to do unless it recurs._' \
    "$REASON" "$DETAIL" "$HEARTBEAT_FILE" "$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo '(no beacon file)')"
}

# Deliver <verb> (alarm-raise | alarm-clear) with <body>. Sets VIA to the channels
# that carried it; returns 0 if at least one did. The primary is Linear; Buzz is an
# optional second hop that never blocks — and never substitutes for — the primary.
deliver() {
  local verb="$1" body="$2" out buzz_msg; VIA=""
  [ -n "$MENTION" ] && buzz_msg="$(printf '%s\n\n@Fizz' "$body")" || buzz_msg="$body"

  if [ "${HB_DRY_RUN:-}" = "1" ]; then
    log "DRY_RUN $verb ($REASON): $DETAIL"
    if linear_configured; then printf 'DRY_RUN would %s %s (%s):\n%s\n' "$verb" "$ALARM_ISSUE" \
      "$([ "$verb" = alarm-raise ] && echo 'apply board:to_review + comment' || echo 'remove board:to_review + comment')" "$body"; VIA="linear"
    else printf 'DRY_RUN: Linear path not configured (LINEAR_API_KEY/alarm_issue) — primary channel MUTE\n'; fi
    if buzz_configured; then printf 'DRY_RUN would send to %s:\n%s\n' "$CHANNEL" "$buzz_msg"; VIA="${VIA:+$VIA,}buzz"
    else printf 'DRY_RUN: Buzz hop skipped (no BUZZ_PRIVATE_KEY) — optional\n'; fi
    [ -n "$VIA" ]; return
  fi

  if linear_configured; then
    if out="$(linear_cmd "$verb" "$ALARM_ISSUE" "$body" 2>&1)"; then
      log "LINEAR $verb ok: $out"; VIA="linear"
    else log "ERROR: Linear $verb failed: $out"; fi
  else
    log "Linear path not configured (LINEAR_API_KEY + alarm_issue) — primary channel MUTE."
  fi

  if buzz_configured; then
    if buzz messages send --channel "$CHANNEL" ${MENTION:+--mention "$MENTION"} --content "$buzz_msg" >>"$RUN_LOG" 2>&1; then
      log "BUZZ $verb ok -> $CHANNEL."; VIA="${VIA:+$VIA,}buzz"
    else log "ERROR: buzz messages send failed — see above (optional hop)."; fi
  else
    log "Buzz hop skipped: no BUZZ_PRIVATE_KEY / channel / cli (optional)."
  fi

  [ -n "$VIA" ] || log "ERROR: $verb ($REASON) delivered to NO channel — the alarm is mute."
  [ -n "$VIA" ]
}

check() {
  VERDICT=""; REASON=""; DETAIL=""
  assess
  local was; was="$(armed && echo yes || echo no)"
  log "check: verdict=$VERDICT reason=$REASON alarmed_already=$was :: $DETAIL"

  if [ "$VERDICT" = "alarm" ]; then
    if armed; then
      log "already alarmed this outage — staying quiet (debounce)."
      swrite "$POLL_NOW" "$POLL_SINCE" "$(sget alarmed)" "$(sget alarm_via)" "$(sget alarm_ts)"
    elif deliver alarm-raise "$(alarm_body)"; then
      swrite "$POLL_NOW" "$POLL_SINCE" "$REASON" "$VIA"
    else
      swrite "$POLL_NOW" "$POLL_SINCE"
    fi
    return 0
  fi

  if armed; then
    # The outage is over; take the flag down. Not disarmed until the clear is delivered —
    # a stale board:to_review on the Board is exactly the lie this thing exists to avoid.
    if deliver alarm-clear "$(recovery_body)"; then
      log "condition cleared ($REASON) — flag taken down, alarm re-armed."
      swrite "$POLL_NOW" "$POLL_SINCE"
    else
      log "condition cleared ($REASON) but the clear was NOT delivered — will retry next cycle."
      swrite "$POLL_NOW" "$POLL_SINCE" "$(sget alarmed)" "$(sget alarm_via)" "$(sget alarm_ts)"
    fi
    return 0
  fi
  swrite "$POLL_NOW" "$POLL_SINCE"
}

# Can this watchdog actually shout? GSAI-21's whole failure was that it could not, and
# nothing said so for four days — the vault assigns without `export`, the key never
# reached the sender's subshell, and every cycle logged a clean bill of health. So the
# ability to send is itself checkable, in the same clean environment launchd provides,
# and the Linear row is a REAL round-trip to the tracking issue, not a presence check.
# Fails only when NO channel can deliver — Buzz is optional. Prints NAMES and presence
# only — never a secret value.
creds() {
  local linear_ok=yes buzz_ok=yes probe
  printf '== can this watchdog shout? ==\n'
  printf -- '-- primary: Linear board (the alarm is the `board:to_review` label) --\n'
  printf '   vault    : %s %s\n' "${LINEAR_ENV:-<unset>}" "$([ -n "$LINEAR_ENV" ] && [ -f "$LINEAR_ENV" ] && echo '(found)' || echo '(MISSING)')"
  if [ -n "${LINEAR_API_KEY:-}" ]; then printf '   LINEAR_API_KEY: exported into this environment ✓\n'
  else printf '   LINEAR_API_KEY: NOT SET ✗\n'; linear_ok=no; fi
  if [ -n "$ALARM_ISSUE" ]; then
    if [ "$linear_ok" = yes ]; then
      if probe="$(linear_cmd alarm-probe "$ALARM_ISSUE" 2>&1)"; then printf '   issue    : %s — reachable ✓ (%s)\n' "$ALARM_ISSUE" "$(printf '%s' "$probe" | tr '\t' ' ')"
      else printf '   issue    : %s — NOT reachable ✗ (%s)\n' "$ALARM_ISSUE" "$probe"; linear_ok=no; fi
    else printf '   issue    : %s (not probed — no key)\n' "$ALARM_ISSUE"; fi
  else printf '   issue    : (alarm_issue not configured in org/config.yaml) ✗\n'; linear_ok=no; fi
  printf '   python3  : %s\n' "$(command -v python3 2>/dev/null || { echo '(not on PATH) ✗'; linear_ok=no; })"

  printf -- '-- second hop: Buzz (optional) --\n'
  printf '   vault    : %s %s\n' "${VAULT_ENV:-<unset>}" "$([ -n "$VAULT_ENV" ] && [ -f "$VAULT_ENV" ] && echo '(found)' || echo '(missing)')"
  printf '   channel  : %s\n' "$([ -n "$CHANNEL" ] && echo "$CHANNEL" || { echo '(none configured)'; buzz_ok=no; })"
  printf '   mention  : %s\n' "$([ -n "$MENTION" ] && echo "${MENTION:0:12}… " || echo '(none)')"
  local v
  for v in BUZZ_RELAY_URL BUZZ_PRIVATE_KEY; do
    if [ -n "${!v:-}" ]; then printf '   %-9s: exported into this environment ✓\n' "$v"
    else printf '   %-9s: NOT SET — optional hop skipped\n' "$v"; buzz_ok=no; fi
  done
  printf '   buzz cli : %s\n' "$(command -v buzz 2>/dev/null || { echo '(not on PATH)'; buzz_ok=no; })"

  printf -- '-- verdict --\n'
  printf '   Linear board : %s\n' "$([ "$linear_ok" = yes ] && echo 'CAN DELIVER ✓' || echo 'MUTE ✗')"
  printf '   Buzz hop     : %s\n' "$([ "$buzz_ok" = yes ] && echo 'CAN DELIVER ✓' || echo 'skipped (optional)')"
  if [ "$linear_ok" = no ] && [ "$buzz_ok" = no ]; then
    printf '   ✗ NO channel can deliver — the alarm would be silent.\n'; return 1
  fi
  [ "$linear_ok" = no ] && printf '   ⚠ primary (Linear) is mute; only the Buzz hop would carry the alarm.\n'
  return 0
}

status() {
  VERDICT=""; REASON=""; DETAIL=""
  assess
  printf '== dozer heartbeat check ==\n'
  printf '   beacon : %s\n' "$HEARTBEAT_FILE"
  printf '   verdict: %s (%s)\n' "$VERDICT" "$REASON"
  printf '   detail : %s\n' "$DETAIL"
  printf '   surface: %s\n' "$(linear_configured && echo "Linear $ALARM_ISSUE (board:to_review)" || echo 'Linear NOT configured')$(buzz_configured && echo ' + Buzz' || echo ' (Buzz hop off)')"
  printf '   armed  : %s\n' "$(armed && echo "alarm outstanding since $(sget alarm_ts) via $(sget alarm_via)" || echo 'ready to alarm')"
  [ "$VERDICT" = "alarm" ] && return 1 || return 0
}

# ── launchd agent ───────────────────────────────────────────────────────────────
# Generated, not checked in — so it always points at wherever this repo actually
# lives, exactly like dozers/service.sh does for the engine itself. HB_INSTALL_ROOT
# targets a different checkout (e.g. the stable one while this one is a worktree);
# `creds` still proves THIS checkout can shout.
PLIST_PATH="${HB_PLIST_PATH:-$HOME/Library/LaunchAgents/$LABEL.plist}"
INSTALL_ROOT="${HB_INSTALL_ROOT:-$ROOT}"
SERVICE_PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
xesc() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }

gen_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(xesc "$LABEL")</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xesc "$INSTALL_ROOT/dozers/heartbeat-check.sh")</string>
        <string>check</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(xesc "$INSTALL_ROOT")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(xesc "$SERVICE_PATH")</string>
    </dict>
    <key>StartInterval</key>
    <integer>$INTERVAL</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$(xesc "$(dirname "$RUN_LOG")/heartbeat-check.out.log")</string>
    <key>StandardErrorPath</key>
    <string>$(xesc "$(dirname "$RUN_LOG")/heartbeat-check.err.log")</string>
</dict>
</plist>
PLIST
}

install_agent() {
  # A watchdog that cannot deliver its alarm is a decoration that costs you four days
  # of false confidence (GSAI-21). So installing one is a hard stop, not a warning:
  # prove it can shout, or say why it cannot and refuse. HB_FORCE_INSTALL=1 loads it
  # anyway — deliberately, with the reason on screen.
  if ! creds; then
    echo
    echo "✗ refusing to install: this watchdog could not prove it can send an alarm." >&2
    echo "  Fix the row(s) marked ✗ above, or re-run with HB_FORCE_INSTALL=1 to load it" >&2
    echo "  regardless (it will detect outages and log them, but shout at nobody)." >&2
    [ "${HB_FORCE_INSTALL:-}" = "1" ] || return 1
    echo "  HB_FORCE_INSTALL=1 — installing a check that can only log." >&2
  fi
  echo
  [ -f "$INSTALL_ROOT/dozers/heartbeat-check.sh" ] || { echo "✗ no heartbeat-check.sh under $INSTALL_ROOT — nothing for launchd to run." >&2; return 1; }
  mkdir -p "$(dirname "$PLIST_PATH")" "$(dirname "$RUN_LOG")"
  gen_plist > "$PLIST_PATH"; echo "  · wrote $PLIST_PATH (runs $INSTALL_ROOT/dozers/heartbeat-check.sh)"
  local domain="gui/$(id -u)"
  launchctl bootout "$domain/$LABEL" 2>/dev/null || true
  if launchctl bootstrap "$domain" "$PLIST_PATH" 2>/dev/null; then
    launchctl enable "$domain/$LABEL" 2>/dev/null || true
    echo "  · bootstrapped $LABEL into $domain"
  else
    launchctl load -w "$PLIST_PATH" && echo "  · loaded $LABEL (legacy)"
  fi
  echo "✓ heartbeat watchdog runs every ${INTERVAL}s. log: $RUN_LOG"
}

uninstall_agent() {
  local domain="gui/$(id -u)"
  launchctl bootout "$domain/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH" && echo "✓ removed $PLIST_PATH and stopped $LABEL"
}

case "${1:-check}" in
  check)     check ;;
  status)    status ;;
  creds)     creds ;;
  install)   install_agent ;;
  uninstall) uninstall_agent ;;
  plist)     gen_plist ;;
  *) echo "usage: heartbeat-check.sh [check|status|creds|install|uninstall|plist]" >&2; exit 1 ;;
esac
