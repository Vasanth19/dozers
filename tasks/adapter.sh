#!/usr/bin/env bash
# tasks/adapter.sh — the pluggable task backend.
#
# This is the whole point of the system: the Director and the Worker never
# talk to GitHub / files / Linear directly. They call the five functions
# below, and this file routes them to whichever backend is configured.
#
# To swap backends, change ONE value: BACKEND (env var or org/config.yaml).
# Everything above this line stays identical.
#
# Every backend must implement these five functions:
#   task_list_untriaged   -> print one "<id>\t<title>" per line (no lane yet)
#   task_list_ready       -> print one "<id>\t<lane>\t<title>" per line (ready+lane)
#   task_mark_ready <id> <lane>   -> stamp an issue ready and give it a lane
#   task_claim <id>       -> atomically take the task (returns non-zero if already taken)
#   task_done  <id>       -> mark the task finished
#   task_comment <id> <text>  -> leave a note on the task
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve the backend: env wins, else read org/config.yaml, else default to files.
if [[ -z "${BACKEND:-}" ]]; then
  BACKEND="$(grep -E '^\s*backend:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*backend:\s*//; s/#.*//; s/[[:space:]]//g' || true)"
fi
BACKEND="${BACKEND:-files}"

case "$BACKEND" in
  github|github-issues) source "$ROOT/tasks/github-issues.sh" ;;
  files)               source "$ROOT/tasks/files.sh" ;;
  *) echo "adapter: unknown backend '$BACKEND' (use: github | files)" >&2; exit 1 ;;
esac

# Loud, so you always know which plug is in.
[[ "${ADAPTER_QUIET:-}" == "1" ]] || echo "[adapter] backend = $BACKEND" >&2
