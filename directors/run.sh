#!/usr/bin/env bash
# directors/run.sh — the judgment interface.
#
# The Director decides WHAT gets done and reviews what came back. It never
# executes — its only power over the Dozer is stamping a task `ready` + a lane.
# That stamp is the single handoff between deciding and doing.
#
#   directors/run.sh triage              # show untriaged work needing a decision
#   directors/run.sh ready <id> <lane>    # approve: stamp ready + lane (dev|marketing)
#   directors/run.sh note  <id> <text>    # leave direction on a task
#
# The actual judgment (is this worth doing? which lane? what's the spec?) is what
# directors/<role>.md tells a model/agent to do. This script is the hands.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tasks/adapter.sh"

case "${1:-triage}" in
  triage)
    echo "[director] untriaged — decide a lane, then: directors/run.sh ready <id> <lane>"
    task_list_untriaged | while IFS=$'\t' read -r id title; do
      [[ -z "$id" ]] && continue
      printf '  #%s  %s\n' "$id" "$title"
    done
    ;;
  ready)
    id="${2:?usage: ready <id> <lane>}"; lane="${3:?usage: ready <id> <lane>}"
    case "$lane" in dev|marketing) ;; *) echo "lane must be dev|marketing" >&2; exit 1 ;; esac
    task_mark_ready "$id" "$lane"
    task_comment "$id" "Director approved → lane:$lane, marked ready."
    echo "[director] #$id stamped ready + lane:$lane — the Dozer can pick it up now."
    ;;
  note)
    id="${2:?usage: note <id> <text>}"; shift 2
    task_comment "$id" "$*"
    echo "[director] noted on #$id"
    ;;
  *) echo "usage: run.sh [triage|ready <id> <lane>|note <id> <text>]" >&2; exit 1 ;;
esac
