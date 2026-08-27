#!/usr/bin/env bash
# worker/worker.sh — the execution engine.
#
# It runs the floor: poll the backend for work that carries BOTH the ready gate
# AND a lane, claim it atomically, hand it to that lane's crew, mark it done.
# It never decides WHAT to do — only executes what the Director has stamped ready.
#
# Usage:
#   worker/worker.sh once     # drain everything ready right now, then exit
#   worker/worker.sh loop      # keep draining every POLL_SECONDS (default 30)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tasks/adapter.sh"

POLL_SECONDS="${POLL_SECONDS:-30}"

run_one() { # <id> <lane> <title>
  local id="$1" lane="$2" title="$3"
  local lane_script="$ROOT/worker/lanes/$lane.sh"

  if [[ ! -x "$lane_script" ]]; then
    echo "  ✗ no crew for lane '$lane' — skipping #$id" >&2
    return 0
  fi
  # Claim atomically. If this fails, another Worker already took it.
  if ! task_claim "$id"; then
    echo "  ~ #$id already claimed, skipping" >&2
    return 0
  fi
  echo "  → #$id [$lane] $title"
  if "$lane_script" "$id" "$title"; then
    task_done "$id"
    task_comment "$id" "✅ Worker finished via lane:$lane"
    echo "  ✓ #$id done"
  else
    task_comment "$id" "⚠️ Worker hit an error in lane:$lane — needs a look"
    echo "  ✗ #$id failed" >&2
  fi
}

drain() {
  local any=0
  # read lines of "<id>\t<lane>\t<title>"
  while IFS=$'\t' read -r id lane title; do
    [[ -z "$id" ]] && continue
    any=1
    run_one "$id" "$lane" "$title"
  done < <(task_list_ready)
  if [[ "$any" == 0 ]]; then echo "  (nothing ready)"; fi
}

case "${1:-once}" in
  once) echo "[worker] draining ready+lane work…"; drain ;;
  loop)
    echo "[worker] looping every ${POLL_SECONDS}s (Ctrl-C to stop)"
    while true; do
      echo "[worker] $(date '+%H:%M:%S') poll"
      drain
      sleep "$POLL_SECONDS"
    done ;;
  *) echo "usage: worker.sh [once|loop]" >&2; exit 1 ;;
esac
