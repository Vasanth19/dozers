#!/usr/bin/env bash
# dozers/heartbeat-check.sh — the watchdog that reads the engine's beacon (GSAI-31).
#
# `dozers/dozer.sh loop` keeps a beacon fresh at $HEARTBEAT_FILE (see beat_start there).
# This is the other half: something that NOTICES when it stops. A dead engine looks
# exactly like an empty board from the outside — that is the failure that cost us on
# 2026-09-02, and the reason GSAI-21 shipped an interim ps-based check. This replaces
# it, and covers strictly more: a loop that is alive but WEDGED still stops beating,
# and a beacon that is stale for a legitimate reason (a long crew run) stays silent.
#
#   heartbeat-check.sh check       # one pass: decide, log, alarm if warranted (default)
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
#   beacon fresh (age < 3x its own cadence)             -> silent
#   beacon stale + a live crew is holding a run-lock    -> silent, but logged (long task)
#   beacon stale + no live crew                         -> ALARM  engine stalled
#
# Staleness is measured against the cadence the beacon PUBLISHES (`every=`), not a
# number duplicated here — emitter and watchdog cannot drift apart that way.
#
# Debounced: one alarm per outage. The state file is removed only when the condition
# clears, so a five-minute agent does not shout twelve times an hour about one outage.
#
# Test / manual seams (all unset in production — the real probes run when absent):
#   HB_ASSUME_LOOP=yes|no        bypass the `ps` scan for a dozer.sh loop process
#   HB_ASSUME_ENGINE=alive|dead  bypass the beacon-pid liveness probe
#   HB_ASSUME_CREWS=<n>          bypass the live-run-lock scan
#   HB_DRY_RUN=1                 print the alarm instead of sending it
#   HB_STATE_FILE / HB_RUN_LOG   override the debounce state + log paths
#   HB_VAULT_ENV / HB_PLIST_PATH override the credential file / the agent's plist path
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
INTERVAL="${HB_INTERVAL:-$(cfg alarm_interval)}"; INTERVAL="${INTERVAL:-300}"
LABEL="${HB_SERVICE_LABEL:-com.dozers.heartbeat-check}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$RUN_LOG")" 2>/dev/null || true
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$RUN_LOG" 2>/dev/null || true; }

# Credentials for standalone/scheduled runs (anything already in the env wins).
#
# `set -a` around this is LOAD-BEARING, not decoration: the vault files assign without
# `export`, and the sender runs in a child process. GSAI-21 shipped without it — the key
# never crossed the subshell, the watchdog was silent by construction, and nobody knew
# for four days. A watchdog that cannot prove it can shout is not a watchdog.
set -a
[ -n "$VAULT_ENV" ] && [ -f "$VAULT_ENV" ] && . "$VAULT_ENV"
set +a

# ── probes ──────────────────────────────────────────────────────────────────────
beacon_epoch() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
field() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }

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

# ── the verdict ─────────────────────────────────────────────────────────────────
# Sets VERDICT=alarm|silent, REASON=<short slug>, DETAIL=<one human line>.
assess() {
  local age cadence stale_after crews
  crews="$(live_crews)"

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

  cadence="$(field "$HEARTBEAT_FILE" every)"
  case "$cadence" in ''|*[!0-9]*) cadence=30 ;; esac
  stale_after=$(( cadence * 3 ))
  age=$(( $(date +%s) - $(beacon_epoch "$HEARTBEAT_FILE") ))

  engine_alive; local ea=$?
  if [ "$ea" -eq 1 ]; then
    VERDICT=alarm; REASON="engine-gone"
    DETAIL="the beacon names pid $(field "$HEARTBEAT_FILE" pid), which is no longer running on this host. Last beat ${age}s ago; $crews crew(s) still holding a lock."
    return
  fi

  if [ "$age" -lt "$stale_after" ]; then
    VERDICT=silent; REASON="fresh"
    DETAIL="beat ${age}s ago (cadence ${cadence}s), $crews crew(s) in flight."
    return
  fi

  if [ "$crews" -gt 0 ]; then
    # A long crew run is not a fault — but it IS worth a log line, because with the
    # beat on its own clock (GSAI-31) a healthy engine should never go stale at all.
    VERDICT=silent; REASON="stale-but-busy"
    DETAIL="beacon ${age}s old (threshold ${stale_after}s) but $crews crew(s) are alive — long task, not a stall."
    return
  fi

  VERDICT=alarm; REASON="engine-stalled"
  DETAIL="beacon has not advanced for ${age}s (threshold ${stale_after}s = 3x its ${cadence}s cadence) and no crew is running. The engine is wedged or gone."
}

# ── the alarm ───────────────────────────────────────────────────────────────────
send_alarm() {
  local msg restart='dozers/service.sh restart   # or: dozers/service.sh install'
  msg=$(printf '🔴 **Dozer engine is not beating** — %s\n\n%s\n\nBeacon `%s`:\n```\n%s\n```\nRestart:\n```\n%s\n```\n_dozers/heartbeat-check.sh (GSAI-31)._' \
    "$REASON" "$DETAIL" "$HEARTBEAT_FILE" "$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo '(no beacon file)')" "$restart")
  [ -n "$MENTION" ] && msg="$(printf '%s\n\n@Fizz' "$msg")"

  if [ "${HB_DRY_RUN:-}" = "1" ]; then
    log "DRY_RUN alarm ($REASON): $DETAIL"
    printf 'DRY_RUN would send to %s:\n%s\n' "${CHANNEL:-<no channel configured>}" "$msg"
    return 0
  fi
  if [ -z "$CHANNEL" ]; then log "ERROR: alarm condition ($REASON) but no alarm_channel configured — cannot post."; return 1; fi
  if [ -z "${BUZZ_PRIVATE_KEY:-}" ] || [ -z "${BUZZ_RELAY_URL:-}" ]; then
    log "ERROR: alarm condition ($REASON) but BUZZ creds missing ($VAULT_ENV) — cannot post."
    return 1
  fi
  if buzz messages send --channel "$CHANNEL" ${MENTION:+--mention "$MENTION"} --content "$msg" >>"$RUN_LOG" 2>&1; then
    log "ALARM SENT ($REASON) to $CHANNEL."
    return 0
  fi
  log "ERROR: buzz messages send failed — see above."
  return 1
}

check() {
  VERDICT=""; REASON=""; DETAIL=""
  assess
  local armed; armed="$([ -f "$STATE_FILE" ] && echo yes || echo no)"
  log "check: verdict=$VERDICT reason=$REASON alarmed_already=$armed :: $DETAIL"

  if [ "$VERDICT" = "alarm" ]; then
    if [ -f "$STATE_FILE" ]; then
      log "already alarmed this outage — staying quiet (debounce)."
    elif send_alarm; then
      printf 'ts=%s\nreason=%s\n' "$(date -u +%FT%TZ)" "$REASON" > "$STATE_FILE"
    fi
    return 0
  fi
  if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    log "condition cleared ($REASON) — alarm re-armed."
  fi
}

# Can this watchdog actually shout? GSAI-21's whole failure was that it could not, and
# nothing said so for four days — the vault assigns without `export`, the key never
# reached the sender's subshell, and every cycle logged a clean bill of health. So the
# ability to send is itself checkable, in the same clean environment launchd provides.
# Prints NAMES and presence only — never a secret value.
creds() {
  local rc=0
  printf '== can this watchdog shout? ==\n'
  printf '   vault    : %s %s\n' "${VAULT_ENV:-<unset>}" "$([ -n "$VAULT_ENV" ] && [ -f "$VAULT_ENV" ] && echo '(found)' || { echo '(MISSING)'; rc=1; })"
  printf '   channel  : %s\n' "$([ -n "$CHANNEL" ] && echo "$CHANNEL" || { echo '(none configured — alarms cannot post)'; rc=1; })"
  printf '   mention  : %s\n' "$([ -n "$MENTION" ] && echo "${MENTION:0:12}… " || echo '(none)')"
  local v
  for v in BUZZ_RELAY_URL BUZZ_PRIVATE_KEY; do
    if [ -n "${!v:-}" ]; then printf '   %-9s: exported into this environment ✓\n' "$v"
    else printf '   %-9s: NOT SET — the alarm would be silent ✗\n' "$v"; rc=1; fi
  done
  printf '   buzz cli : %s\n' "$(command -v buzz 2>/dev/null || { echo '(not on PATH — the alarm cannot send)'; rc=1; })"
  return $rc
}

status() {
  VERDICT=""; REASON=""; DETAIL=""
  assess
  printf '== dozer heartbeat check ==\n'
  printf '   beacon : %s\n' "$HEARTBEAT_FILE"
  printf '   verdict: %s (%s)\n' "$VERDICT" "$REASON"
  printf '   detail : %s\n' "$DETAIL"
  printf '   armed  : %s\n' "$([ -f "$STATE_FILE" ] && echo 'alarm already sent this outage' || echo 'ready to alarm')"
  [ "$VERDICT" = "alarm" ] && return 1 || return 0
}

# ── launchd agent ───────────────────────────────────────────────────────────────
# Generated, not checked in — so it always points at wherever this repo actually
# lives, exactly like dozers/service.sh does for the engine itself.
PLIST_PATH="${HB_PLIST_PATH:-$HOME/Library/LaunchAgents/$LABEL.plist}"
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
        <string>$(xesc "$ROOT/dozers/heartbeat-check.sh")</string>
        <string>check</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(xesc "$ROOT")</string>
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
  mkdir -p "$(dirname "$PLIST_PATH")" "$(dirname "$RUN_LOG")"
  gen_plist > "$PLIST_PATH"; echo "  · wrote $PLIST_PATH"
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
