#!/usr/bin/env bash
# dozers/dozer.sh — the execution engine (floor boss for the Dozers).
#
# Polls the backend for work carrying the greenlight (ready) AND a lane, claims it,
# resolves the task's PROJECT working dir (from the task's team/org or repo hint),
# cd's the crew into it, runs the crew, posts incremental updates ON the task.
# Multi-team aware, parallel-safe (atomic mkdir lock), fan-out capable.
#
#   dozers/dozer.sh once     # drain now, then exit
#   dozers/dozer.sh loop      # keep draining every POLL_SECONDS (default 30)
#
# Config (org/config.yaml or env): linear_teams ("CFW,LL"), fanout (1..8),
#   workdir_default, workdirs (team/repo -> path). One process can serve all teams.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tasks/adapter.sh"

cfg() { grep -E "^$1:" "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true; }
POLL_SECONDS="${POLL_SECONDS:-30}"
FANOUT="${FANOUT:-$(cfg fanout)}"; FANOUT="${FANOUT:-1}"; (( FANOUT < 1 )) && FANOUT=1
LOCK_DIR="${LOCK_DIR:-$HOME/.dozers/locks}"; mkdir -p "$LOCK_DIR"

# Resolve a task's working dir from the CANONICAL registry (~/ecosystem/ecosystem.yaml),
# most-specific first:
#   1) repo:<id> hint on the task   2) the task's Linear TEAM/org   3) config workdir_default
# Paths live ONLY in ecosystem.yaml — never hardcoded here or in a label.
resolve_workdir() {
  local hint="$1" team="$2" cfgf="$ROOT/org/config.yaml" path=""
  # Canonical source: ecosystem.yaml (repo id -> local, or Linear team -> org default repo)
  path="$(python3 "$ROOT/tasks/ecosystem_workdir.py" ${hint:+--repo "$hint"} ${team:+--team "$team"} 2>/dev/null || true)"
  # Fallback: config workdir_default, then the dozers repo root.
  [[ -z "$path" ]] && path="${WORKDIR_DEFAULT:-$(grep -E '^workdir_default:' "$cfgf" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true)}"
  [[ -z "$path" || "$path" == "." ]] && path="$ROOT"
  path="${path/#\~/$HOME}"
  [[ -d "$path" ]] || path="$ROOT"
  printf '%s' "$path"
}

# Always invoked backgrounded (own subshell), so the EXIT trap + lock are scoped.
run_one() { # <id> <lane> <title>
  local id="$1" lane="$2" title="$3"
  # atomic local mutex so parallel Dozers never double-grab the same task
  local lock="$LOCK_DIR/${id//\//_}.lock"
  if ! mkdir "$lock" 2>/dev/null; then echo "  ~ #$id locked locally, skipping"; return 0; fi
  trap 'rm -rf "$lock" 2>/dev/null || true' EXIT
  # Liveness beacon: record the worker PID so the reaper can tell a live run from a
  # crashed one (dead PID => stale lock => the task gets requeued). See dozers/reaper.sh.
  printf 'pid=%s\nhost=%s\ntask=%s\nlane=%s\nts=%s\n' \
    "$BASHPID" "$(hostname -s 2>/dev/null || echo local)" "$id" "$lane" \
    "$(date -u +%FT%TZ 2>/dev/null || date)" > "$lock/owner" 2>/dev/null || true

  local lane_dir
  case "$lane" in dev) lane_dir="dev-lane";; marketing) lane_dir="mktg-lane";; *) lane_dir="$lane-lane";; esac
  local crew="$ROOT/dozers/$lane_dir/crew.sh" persona="$ROOT/dozers/$lane_dir/dozer.md"
  [[ -x "$crew" ]] || { echo "  x no crew for lane '$lane' ($lane_dir) - skipping #$id" >&2; return 0; }

  if ! task_claim "$id"; then echo "  ~ #$id already claimed, skipping" >&2; return 0; fi
  task_comment "$id" "Dozer claimed - lane:$lane. Starting now; will post a summary on finish."
  echo "  -> #$id [$lane] $title"

  local hint team workdir
  hint="$(task_repo "$id" 2>/dev/null || true)"
  team="$(task_team "$id" 2>/dev/null || true)"
  workdir="$(resolve_workdir "$hint" "$team")"
  echo "    cwd -> $workdir  ${team:+[team:$team]}${hint:+ (repo:$hint)}"

  local summary_file="$ROOT/.artifacts/$lane/$id.summary"; rm -f "$summary_file" 2>/dev/null || true
  if WORKDIR="$workdir" DOZER_PERSONA="$persona" REPO_ROOT="$ROOT" "$crew" "$id" "$title"; then
    local verb
    if [[ "$lane" == "marketing" ]]; then task_review "$id"; verb="staged for review"; else task_merged "$id"; verb="merged to develop"; fi
    local body
    if [[ -s "$summary_file" ]]; then body="$(head -n 10 "$summary_file")"; else body="- completed via lane:$lane"; fi
    task_comment "$id" "$(printf 'Dozer %s - lane:%s\n%s' "$verb" "$lane" "$body")"
    echo "  ok #$id $verb"
  else
    task_block "$id"; task_comment "$id" "Dozer blocked in lane:$lane - needs a look."; echo "  x #$id failed" >&2
  fi
}

drain() {
  local any=0; local -a pids=()
  while IFS=$'\t' read -r id lane title; do
    [[ -z "$id" ]] && continue; any=1
    run_one "$id" "$lane" "$title" &
    pids+=("$!")
    if (( ${#pids[@]} >= FANOUT )); then wait "${pids[@]}" 2>/dev/null || true; pids=(); fi
  done < <(task_list_ready)
  (( ${#pids[@]} )) && { wait "${pids[@]}" 2>/dev/null || true; }
  (( any )) || echo "  (nothing ready)"
}

# Crash recovery: reclaim work stranded by a Dozer that died mid-task (stale locks +
# orphaned in-flight tasks). Idempotent; runs on startup and on a cadence in `loop`.
REAPER_ENABLED="${REAPER_ENABLED:-1}"
recover() { [[ "$REAPER_ENABLED" == 1 && -x "$ROOT/dozers/reaper.sh" ]] && "$ROOT/dozers/reaper.sh" "$@" || true; }

case "${1:-once}" in
  once)    echo "[dozer] recovering stranded work, then draining (fanout=$FANOUT)..."; recover; drain ;;
  recover) recover "${2:-}" ;;                              # run the reaper standalone (pass --dry-run)
  loop) echo "[dozer] looping every ${POLL_SECONDS}s, fanout=$FANOUT (Ctrl-C to stop)"
        recover                                             # heal once on startup
        REAPER_EVERY="${REAPER_EVERY:-10}"; ticks=0         # then re-run every N polls
        while true; do
          echo "[dozer] $(date '+%H:%M:%S') poll"; drain
          ticks=$((ticks+1)); (( REAPER_EVERY > 0 && ticks % REAPER_EVERY == 0 )) && recover
          sleep "$POLL_SECONDS"
        done ;;
  *) echo "usage: dozer.sh [once|loop|recover [--dry-run]]" >&2; exit 1 ;;
esac
