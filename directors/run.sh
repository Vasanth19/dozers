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
#   directors/run.sh answer <id>         # board protocol: did Vas answer the newest board-ask? (read-only)
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
  answer)
    # GSAI-41: the reconcile probe. exit 0 = Vas answered (answers printed) → swap
    # board:to_review → board:responded; exit 3 = still waiting → leave it alone;
    # exit 2 = no board-ask on the issue. Never swap on anything but exit 0.
    id="${2:?usage: answer <id>}"
    if out="$(task_board_answer "$id")"; then
      echo "[director] #$id answered by Vas — swap board:to_review → board:responded and act this pass:"
      sed 's/^/  /' <<<"$out"
    else
      rc=$?
      case "$rc" in
        3) echo "[director] #$id still waiting on Vas — every later comment is marked (an agent's). Leave board:to_review on." ;;
        2) echo "[director] #$id has no board-ask marker — nothing to reconcile." ;;
        *) echo "[director] #$id probe failed (exit $rc)" >&2 ;;
      esac
      exit "$rc"
    fi
    ;;
  *) echo "usage: run.sh [triage|ready <id> <lane>|note <id> <text>|answer <id>]" >&2; exit 1 ;;
esac
