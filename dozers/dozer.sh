#!/usr/bin/env bash
# dozers/dozer.sh — the execution engine (floor boss for the Dozers).
#
# Polls for work carrying the greenlight (ready) AND a lane, claims it, resolves
# the task's PROJECT working dir, cd's the crew into it, loads the lane persona,
# runs the crew, and posts incremental updates ON the task. Never decides WHAT.
#
#   dozers/dozer.sh once     # drain now, then exit
#   dozers/dozer.sh loop      # keep draining every POLL_SECONDS (default 30)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tasks/adapter.sh"
POLL_SECONDS="${POLL_SECONDS:-30}"

# Resolve a task's working dir, most-specific first:
#   1) repo:<name> hint on the task   2) the Dozer's Linear TEAM (org default)   3) workdir_default
resolve_workdir() {
  local hint="$1" cfg="$ROOT/org/config.yaml" path=""
  _wd() { grep -E "^[[:space:]]+$1:" "$cfg" 2>/dev/null | head -1 | sed 's/^[[:space:]]*[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g'; }
  [[ -n "$hint" ]] && path="$(_wd "$hint")"                                   # 1) repo hint
  [[ -z "$path" && -n "${LINEAR_TEAM:-}" ]] && path="$(_wd "${LINEAR_TEAM}")" # 2) team/org
  [[ -z "$path" ]] && path="$(grep -E '^workdir_default:' "$cfg" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g')"
  [[ -z "$path" || "$path" == "." ]] && path="$ROOT"
  [[ -d "$path" ]] || path="$ROOT"
  printf '%s' "$path"
}

run_one() { # <id> <lane> <title>
  local id="$1" lane="$2" title="$3"
  local lane_dir
  case "$lane" in
    dev)       lane_dir="dev-lane" ;;
    marketing) lane_dir="mktg-lane" ;;
    *)         lane_dir="$lane-lane" ;;
  esac
  local crew="$ROOT/dozers/$lane_dir/crew.sh"
  local persona="$ROOT/dozers/$lane_dir/dozer.md"
  if [[ ! -x "$crew" ]]; then
    echo "  x no crew for lane '$lane' ($lane_dir/crew.sh) - skipping #$id" >&2; return 0
  fi
  if ! task_claim "$id"; then
    echo "  ~ #$id already claimed, skipping" >&2; return 0
  fi
  task_comment "$id" "Dozer claimed - lane:$lane. Starting now; will post a summary on finish."
  echo "  -> #$id [$lane] $title"
  local hint workdir
  hint="$(task_repo "$id" 2>/dev/null || true)"
  workdir="$(resolve_workdir "$hint")"
  echo "    cwd -> $workdir   ${hint:+(repo:$hint)}"
  local summary_file="$ROOT/.artifacts/$lane/$id.summary"
  rm -f "$summary_file" 2>/dev/null || true
  if WORKDIR="$workdir" DOZER_PERSONA="$persona" REPO_ROOT="$ROOT" "$crew" "$id" "$title"; then
    task_done "$id"
    local body
    if [[ -s "$summary_file" ]]; then body="$(head -n 10 "$summary_file")"; else body="- completed via lane:$lane"; fi
    task_comment "$id" "$(printf 'Dozer done - lane:%s\n%s' "$lane" "$body")"
    echo "  ok #$id done"
  else
    task_comment "$id" "Dozer blocked in lane:$lane - needs a look."; echo "  x #$id failed" >&2
  fi
}

drain() {
  local any=0
  while IFS=$'\t' read -r id lane title; do
    [[ -z "$id" ]] && continue; any=1; run_one "$id" "$lane" "$title"
  done < <(task_list_ready)
  [[ "$any" == 0 ]] && echo "  (nothing ready)" || true
}

case "${1:-once}" in
  once) echo "[dozer] draining greenlit work..."; drain ;;
  loop) echo "[dozer] looping every ${POLL_SECONDS}s (Ctrl-C to stop)"
        while true; do echo "[dozer] $(date '+%H:%M:%S') poll"; drain; sleep "$POLL_SECONDS"; done ;;
  *) echo "usage: dozer.sh [once|loop]" >&2; exit 1 ;;
esac
