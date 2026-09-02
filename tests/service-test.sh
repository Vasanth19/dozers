#!/usr/bin/env bash
# tests/service-test.sh — regression test for the supervised-loop service unit.
#
# Proves the generated supervisor unit encodes the auto-restart contract that fixes
# the silent-death failure — WITHOUT touching the live launchd/systemd domain:
#   LABEL      — the unit carries the configured service label
#   COMMAND    — it runs `dozers/dozer.sh loop` (the poll loop, not a one-shot)
#   KEEPALIVE  — launchd KeepAlive / systemd Restart=always is present (auto-restart)
#   RUNATLOAD  — starts on load/boot, not only on demand
#   THROTTLE   — a restart throttle guards against a crash hot-loop
#   ENVFILE    — the env file is sourced (secrets stay OUT of the unit)
#   LOGS       — stdout/stderr are redirected to a file (death becomes visible)
#   VALID      — on macOS the plist is well-formed XML (plutil -lint)
#
# Run:  bash tests/service-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; cleanup() { rm -rf "$TMP" 2>/dev/null || true; }; trap cleanup EXIT

LABEL="com.dozers.looptest"
ENV_FILE="$TMP/dozer.env"
LOG_DIR="$TMP/logs"

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

gen() { # gen <plist|unit>
  DOZER_SERVICE_LABEL="$LABEL" DOZER_ENV_FILE="$ENV_FILE" DOZER_LOG_DIR="$LOG_DIR" \
    POLL_SECONDS=45 bash "$ROOT/dozers/service.sh" "$1"
}

# ── launchd plist (the primary target of the task) ──────────────────────────────
PLIST="$(gen plist)"
echo "$PLIST" | grep -q "<string>$LABEL</string>"                 && ok "plist carries label"              || no "plist missing label"
echo "$PLIST" | grep -q "dozers/dozer.sh"                          && ok "plist runs the loop script"       || no "plist not running dozer.sh"
echo "$PLIST" | grep -q "loop"                                     && ok "plist runs 'loop' subcommand"     || no "plist not in loop mode"
echo "$PLIST" | grep -A1 '<key>KeepAlive</key>' | grep -q '<true/>' && ok "KeepAlive true (auto-restart)"    || no "KeepAlive not set — no auto-restart"
echo "$PLIST" | grep -A1 '<key>RunAtLoad</key>' | grep -q '<true/>' && ok "RunAtLoad true (starts on boot)"  || no "RunAtLoad not set"
echo "$PLIST" | grep -q '<key>ThrottleInterval</key>'              && ok "ThrottleInterval set (no hot-loop)" || no "ThrottleInterval missing"
echo "$PLIST" | grep -q "$ENV_FILE"                                && ok "env file sourced (secrets external)" || no "env file not referenced"
echo "$PLIST" | grep -q "$LOG_DIR/loop.out.log"                    && ok "stdout redirected to log"          || no "StandardOutPath missing"
echo "$PLIST" | grep -q "$LOG_DIR/loop.err.log"                    && ok "stderr redirected to log"          || no "StandardErrorPath missing"
echo "$PLIST" | grep -q '<string>45</string>'                      && ok "POLL_SECONDS threaded into env"    || no "POLL_SECONDS not passed"

# Well-formed plist XML — only assert where plutil exists (macOS).
if command -v plutil >/dev/null 2>&1; then
  echo "$PLIST" > "$TMP/x.plist"
  plutil -lint "$TMP/x.plist" >/dev/null 2>&1 && ok "plist is valid (plutil -lint)" || no "plist failed plutil -lint"
else
  ok "plutil absent — skipping XML lint (non-macOS)"
fi

# ── systemd unit (Linux portability) ────────────────────────────────────────────
UNIT="$(gen unit)"
echo "$UNIT" | grep -q '^Restart=always'        && ok "systemd Restart=always (auto-restart)" || no "systemd Restart missing"
echo "$UNIT" | grep -q '^RestartSec='           && ok "systemd RestartSec set (no hot-loop)"  || no "systemd RestartSec missing"
echo "$UNIT" | grep -q 'dozers/dozer.sh'        && ok "systemd unit runs the loop script"     || no "systemd unit not running dozer.sh"
echo "$UNIT" | grep -q 'WantedBy=default.target' && ok "systemd unit is enable-able"           || no "systemd [Install] missing"

if [[ $fail == 0 ]]; then echo "service-test: PASS"; else echo "service-test: FAIL" >&2; exit 1; fi
