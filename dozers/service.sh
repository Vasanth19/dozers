#!/usr/bin/env bash
# dozers/service.sh — run the Dozer loop as a SUPERVISED background service.
#
# The problem this fixes: `dozers/dozer.sh loop` in a terminal dies silently — a
# crash, a closed laptop lid, a logout, a reboot — and nothing brings it back. The
# board just stops draining and no one notices until work piles up.
#
# The fix: hand the loop to the OS process supervisor with an auto-restart policy.
#   macOS  → launchd LaunchAgent with `KeepAlive` (relaunch on ANY exit) + RunAtLoad
#   Linux  → systemd --user unit with `Restart=always`
# Either way, if the loop dies the supervisor relaunches it (throttled so a
# start-up crash can't hot-loop) and every line it prints lands in a log file, so a
# silent death becomes a visible, diagnosable one.
#
#   dozers/service.sh install     # generate the unit, load it, start looping now
#   dozers/service.sh uninstall   # stop + unload + remove the unit
#   dozers/service.sh status      # is it loaded/running? + engine heartbeat
#   dozers/service.sh restart     # kick the supervisor to relaunch the loop
#   dozers/service.sh logs        # tail the loop's stdout/stderr log
#   dozers/service.sh plist       # print the generated launchd plist (no install)
#   dozers/service.sh unit        # print the generated systemd unit  (no install)
#
# Config (env):
#   DOZER_SERVICE_LABEL   service label            (default com.dozers.loop)
#   DOZER_ENV_FILE        sourced before the loop   (default ~/.dozers/dozer.env)
#                         → put `export LINEAR_API_KEY=...` (and any config) here.
#   DOZER_LOG_DIR         where stdout/stderr go     (default ~/.dozers/logs)
#   POLL_SECONDS          loop poll cadence          (default 30)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LABEL="${DOZER_SERVICE_LABEL:-com.dozers.loop}"
ENV_FILE="${DOZER_ENV_FILE:-$HOME/.dozers/dozer.env}"
LOG_DIR="${DOZER_LOG_DIR:-$HOME/.dozers/logs}"
POLL_SECONDS="${POLL_SECONDS:-30}"
OUT_LOG="$LOG_DIR/loop.out.log"
ERR_LOG="$LOG_DIR/loop.err.log"

# A PATH launchd/systemd can rely on: GUI agents inherit a bare PATH, so the loop's
# tools (git, python3, gh, node, claude) must be found. Union of the common homes
# plus whatever PATH is live when we generate the unit.
SERVICE_PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

# The command the supervisor runs: source the env file (so secrets/config live OUTSIDE
# the unit, never baked in), then exec the poll loop. `-l` gives a login shell so the
# user's profile PATH is picked up too.
loop_cmd() {
  printf '[ -f %q ] && { set -a; . %q; set +a; }; exec %q loop' \
    "$ENV_FILE" "$ENV_FILE" "$ROOT/dozers/dozer.sh"
}

# ── launchd (macOS) ─────────────────────────────────────────────────────────────
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

# XML-escape a value before it goes inside a plist <string> (the loop command carries
# `&&`, and paths could carry `&`/`<`/`>`). Order matters: `&` first.
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
        <string>-lc</string>
        <string>$(xesc "$(loop_cmd)")</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(xesc "$ROOT")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(xesc "$SERVICE_PATH")</string>
        <key>POLL_SECONDS</key>
        <string>$(xesc "$POLL_SECONDS")</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$(xesc "$OUT_LOG")</string>
    <key>StandardErrorPath</key>
    <string>$(xesc "$ERR_LOG")</string>
</dict>
</plist>
PLIST
}

launchd_install() {
  mkdir -p "$LOG_DIR" "$(dirname "$PLIST_PATH")" "$(dirname "$ENV_FILE")"
  [[ -f "$ENV_FILE" ]] || { printf '# dozer service env — sourced before the loop.\n# export LINEAR_API_KEY=lin_api_...\n' > "$ENV_FILE"; chmod 600 "$ENV_FILE"; echo "  · wrote env stub $ENV_FILE (put LINEAR_API_KEY here)"; }
  gen_plist > "$PLIST_PATH"
  echo "  · wrote $PLIST_PATH"
  local domain="gui/$(id -u)"
  # bootout any previous copy so bootstrap doesn't error on a stale registration.
  launchctl bootout "$domain/$LABEL" 2>/dev/null || true
  if launchctl bootstrap "$domain" "$PLIST_PATH" 2>/dev/null; then
    launchctl enable "$domain/$LABEL" 2>/dev/null || true
    echo "  · bootstrapped $LABEL into $domain"
  else
    # Older macOS: fall back to the legacy load verb.
    launchctl load -w "$PLIST_PATH" && echo "  · loaded $LABEL (legacy)"
  fi
  echo "✓ Dozer loop is now supervised — it auto-restarts on crash/logout/reboot."
  echo "  logs: $OUT_LOG"
}

launchd_uninstall() {
  local domain="gui/$(id -u)"
  launchctl bootout "$domain/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH" && echo "✓ removed $PLIST_PATH and stopped $LABEL"
}

launchd_status() {
  local domain="gui/$(id -u)"
  echo "== launchd ($LABEL) =="
  if launchctl print "$domain/$LABEL" 2>/dev/null | grep -E '^\s*(state|pid|last exit code) ' ; then :; else
    echo "  (not loaded — run: dozers/service.sh install)"
  fi
}

launchd_restart() {
  local domain="gui/$(id -u)"
  launchctl kickstart -k "$domain/$LABEL" 2>/dev/null && echo "✓ restarted $LABEL" \
    || { launchctl unload "$PLIST_PATH" 2>/dev/null; launchctl load -w "$PLIST_PATH" && echo "✓ reloaded $LABEL (legacy)"; }
}

# ── systemd --user (Linux) ───────────────────────────────────────────────────────
UNIT_NAME="${LABEL##*.}"        # com.dozers.loop -> loop ; keep it short & sane
UNIT_NAME="dozer-${UNIT_NAME}.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"

gen_unit() {
  cat <<UNIT
[Unit]
Description=Dozer poll loop (auto-restart supervisor)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT
Environment=PATH=$SERVICE_PATH
Environment=POLL_SECONDS=$POLL_SECONDS
ExecStart=/bin/bash -lc '$(loop_cmd)'
Restart=always
RestartSec=10
StandardOutput=append:$OUT_LOG
StandardError=append:$ERR_LOG

[Install]
WantedBy=default.target
UNIT
}

systemd_install() {
  mkdir -p "$LOG_DIR" "$UNIT_DIR" "$(dirname "$ENV_FILE")"
  [[ -f "$ENV_FILE" ]] || { printf '# dozer service env — sourced before the loop.\n# export LINEAR_API_KEY=lin_api_...\n' > "$ENV_FILE"; chmod 600 "$ENV_FILE"; echo "  · wrote env stub $ENV_FILE (put LINEAR_API_KEY here)"; }
  gen_unit > "$UNIT_PATH"; echo "  · wrote $UNIT_PATH"
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME"
  echo "✓ Dozer loop is now supervised (systemd --user, Restart=always)."
  echo "  Tip: run 'loginctl enable-linger $USER' so it survives logout."
  echo "  logs: $OUT_LOG"
}

systemd_uninstall() {
  systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_PATH"; systemctl --user daemon-reload 2>/dev/null || true
  echo "✓ removed $UNIT_PATH and stopped $UNIT_NAME"
}

systemd_status()  { echo "== systemd ($UNIT_NAME) =="; systemctl --user status "$UNIT_NAME" --no-pager 2>/dev/null || echo "  (not installed — run: dozers/service.sh install)"; }
systemd_restart() { systemctl --user restart "$UNIT_NAME" && echo "✓ restarted $UNIT_NAME"; }

# ── platform dispatch ─────────────────────────────────────────────────────────────
IS_MAC=0; [[ "$(uname -s)" == "Darwin" ]] && IS_MAC=1

show_heartbeat() { echo; "$ROOT/dozers/dozer.sh" doctor 2>/dev/null | sed -n '/engine heartbeat/,/worktrees/p' | sed '$d' || true; }

case "${1:-status}" in
  install)   (( IS_MAC )) && launchd_install   || systemd_install ;;
  uninstall) (( IS_MAC )) && launchd_uninstall || systemd_uninstall ;;
  status)    (( IS_MAC )) && launchd_status    || systemd_status; show_heartbeat ;;
  restart)   (( IS_MAC )) && launchd_restart   || systemd_restart ;;
  logs)      touch "$OUT_LOG"; echo "== tail $OUT_LOG (Ctrl-C to stop) =="; tail -n 40 -f "$OUT_LOG" ;;
  plist)     gen_plist ;;                 # print only — for inspection / testing
  unit)      gen_unit ;;                  # print only — for inspection / testing
  *) echo "usage: service.sh [install|uninstall|status|restart|logs|plist|unit]" >&2; exit 1 ;;
esac
