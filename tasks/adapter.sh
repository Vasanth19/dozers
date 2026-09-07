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
#   task_claim <id>       -> take the task, non-zero if already taken.
#                            Atomic on the files backend (single rename); best-effort
#                            on github (read-then-write) — assumes ONE worker/runner,
#                            which the cloud Action and a single local loop both satisfy.
#   task_done  <id>       -> mark the task finished
#   task_comment <id> <text>  -> leave a note on the task
#
# Optional RECOVERY verbs (implemented by files/github/linear; used by
# dozers/reaper.sh to reclaim work stranded by a crashed Dozer):
#   task_list_inflight    -> print "<id>\t<lane>\t<title>" per CLAIMED-but-unfinished
#                            task (excludes anything awaiting human review).
#   task_requeue <id>     -> undo a claim: put the task back to ready (keep its lane).
# A backend without these degrades gracefully — the reaper still reaps stale locks.
#
# Optional BRIEF verb (GSAI-7; implemented by files/github/linear):
#   task_description <id> -> print the task body (the Director's brief). The engine
#                            hands it to the crew as a file (DOZER_BRIEF) so a lane can
#                            route on the brief's content, e.g. a `production:` line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve the backend: env wins, else read org/config.yaml, else default to files.
if [[ -z "${BACKEND:-}" ]]; then
  BACKEND="$(grep -E '^[[:space:]]*backend:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*backend:[[:space:]]*//; s/#.*//; s/[[:space:]]//g; s/"//g; s/'"'"'//g' || true)"
fi
BACKEND="${BACKEND:-files}"

case "$BACKEND" in
  linear)              source "$ROOT/tasks/linear.sh" ;;
  github|github-issues) source "$ROOT/tasks/github-issues.sh" ;;
  files)               source "$ROOT/tasks/files.sh" ;;
  *) echo "adapter: unknown backend '$BACKEND' (use: linear | github | files)" >&2; exit 1 ;;
esac

# Loud, so you always know which plug is in.
[[ "${ADAPTER_QUIET:-}" == "1" ]] || echo "[adapter] backend = $BACKEND" >&2
