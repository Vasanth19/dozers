#!/usr/bin/env bash
# dozers/reaper.sh — crash-recovery sweep (inspired by gastown's reaper / witness).
#
# When a Dozer dies mid-task (crash, kill -9, machine restart), the task is left
# STRANDED: claiming it dropped `ready` (so the poll won't re-pick it) and its local
# lock went stale (so even re-flagging it hits "locked locally, skipping"). Nothing
# resumes it. This sweep heals both failure modes:
#
#   1. STALE LOCKS  — a lock whose owning PID is dead (or older than REAPER_MAX_AGE)
#                     is removed. Liveness = POSIX signal-0 probe (`kill -0 <pid>`),
#                     the same idea as gastown's beads/stale_pid.
#   2. ORPHAN TASKS — an in-flight (claimed) task with no LIVE lock is requeued back
#                     to `ready`, so the next poll re-runs it. The dev crew re-isolates
#                     its worktree on pickup (`git worktree prune` + `remove --force`),
#                     so no worktree cleanup is needed here.
#
# This is the Dozer's lightweight witness/deacon: idempotent and safe to run on
# startup and on a cadence during the poll loop. A task with a live worker is never
# touched.
#
#   dozers/reaper.sh              # heal now
#   dozers/reaper.sh --dry-run    # report what it WOULD do; change nothing
#   DRY_RUN=1 dozers/reaper.sh    # same
#
# Env:
#   LOCK_DIR         where run locks live       (default ~/.dozers/locks)
#   REAPER_MAX_AGE   secs; backstop for a lock whose PID looks alive but is a runaway
#                    or was recycled            (default 21600 = 6h)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER_QUIET=1 source "$ROOT/tasks/adapter.sh"

LOCK_DIR="${LOCK_DIR:-$HOME/.dozers/locks}"; mkdir -p "$LOCK_DIR"
REAPER_MAX_AGE="${REAPER_MAX_AGE:-21600}"
DRY_RUN="${DRY_RUN:-0}"
case "${1:-}" in --dry-run|-n) DRY_RUN=1 ;; esac

_now()    { date +%s; }
_mtime()  { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }  # macOS || linux
_alive()  { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }                             # signal-0 probe
_field()  { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
_lockdir() { printf '%s/%s.lock' "$LOCK_DIR" "${1//\//_}"; }

# Is <id>'s lock backed by a LIVE worker (pid alive AND within max-age)?
# echoes: live | stale | none
_lock_state() {
  local lock; lock="$(_lockdir "$1")"
  [[ -d "$lock" ]] || { echo none; return; }
  local pid age; pid="$(_field "$lock/owner" pid)"; age=$(( $(_now) - $(_mtime "$lock") ))
  if _alive "$pid" && (( age < REAPER_MAX_AGE )); then echo live; else echo stale; fi
}

declare -A REAPED=()
_reap_lock() {   # kill a runaway worker (if still alive) + remove its stale lock
  local id="$1" lock; lock="$(_lockdir "$id")"
  [[ -d "$lock" ]] || return 0
  [[ -n "${REAPED[$id]:-}" ]] && return 0
  REAPED[$id]=1
  local pid; pid="$(_field "$lock/owner" pid)"
  if _alive "$pid"; then   # over-age but process still running => runaway; kill it (watchdog)
    if [[ "$DRY_RUN" == 1 ]]; then echo "  [dry] would KILL runaway worker pid=$pid ($id)"
    else kill "$pid" 2>/dev/null || true; sleep 1; kill -9 "$pid" 2>/dev/null || true; echo "  killed runaway worker pid=$pid ($id)"; fi
  fi
  if [[ "$DRY_RUN" == 1 ]]; then echo "  [dry] would reap stale lock: $id"
  else rm -rf "$lock" && echo "  reaped stale lock: $id"; fi
}

reaped=0 requeued=0 healthy=0

# ── 1. Requeue orphaned in-flight tasks (claimed, but no live worker) ───────────
if declare -F task_list_inflight >/dev/null; then
  while IFS=$'\t' read -r id lane title; do
    [[ -z "$id" ]] && continue
    case "$(_lock_state "$id")" in
      live)  healthy=$((healthy+1)); continue ;;        # a worker is on it — leave it
      stale) _reap_lock "$id"; reaped=$((reaped+1)) ;;
      none)  : ;;                                        # already lockless, still orphaned
    esac
    if [[ "$DRY_RUN" == 1 ]]; then
      echo "  [dry] would requeue orphaned task: $id (lane:${lane:-?}) ${title:-}"
    elif task_requeue "$id"; then
      task_comment "$id" "♻️ Reaper requeued this task: its Dozer stopped without finishing (no live worker). It will be re-picked on the next poll." 2>/dev/null || true
      echo "  requeued orphaned task: $id (lane:${lane:-?})"
    else
      echo "  ! could not requeue $id (backend refused)" >&2; continue
    fi
    requeued=$((requeued+1))
  done < <(task_list_inflight 2>/dev/null || true)
else
  echo "  (backend '$BACKEND' has no task_list_inflight — orphan-requeue skipped; still reaping stale locks)" >&2
fi

# ── 2. Sweep leftover stale locks whose task already moved on (done/cleaned) ────
shopt -s nullglob
for lock in "$LOCK_DIR"/*.lock; do
  local_id="$(_field "$lock/owner" task)"; [[ -z "$local_id" ]] && local_id="$(basename "$lock" .lock)"
  pid="$(_field "$lock/owner" pid)"; age=$(( $(_now) - $(_mtime "$lock") ))
  _alive "$pid" && (( age < REAPER_MAX_AGE )) && continue
  before="${REAPED[$local_id]:-}"
  _reap_lock "$local_id"
  [[ -z "$before" ]] && reaped=$((reaped+1))
done
shopt -u nullglob

printf '[reaper] %srequeued=%d reaped-locks=%d healthy=%d\n' "$([[ "$DRY_RUN" == 1 ]] && echo '(dry) ')" "$requeued" "$reaped" "$healthy"
