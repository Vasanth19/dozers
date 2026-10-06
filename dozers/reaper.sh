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
#                     the same idea as gastown's beads/stale_pid. Only OUR locks: a lock
#                     with no `owner` file belongs to another holder (the Directors' own
#                     `director-<role>.lock`) and is never touched — see _lock_foreign.
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
# GSAI-60: every scripted comment self-stamps `<!-- board-note by:<this> -->` — the
# board reconcile reads an unmarked comment as Vas's answer.
export DOZER_COMMENT_BY="dozer-reaper"

LOCK_DIR="${LOCK_DIR:-$HOME/.dozers/locks}"; mkdir -p "$LOCK_DIR"
REAPER_MAX_AGE="${REAPER_MAX_AGE:-21600}"
DRY_RUN="${DRY_RUN:-0}"
case "${1:-}" in --dry-run|-n) DRY_RUN=1 ;; esac

_now()    { date +%s; }
_mtime()  { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }  # macOS || linux
_alive()  { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }                             # signal-0 probe
# A field read must never be fatal. Under `set -euo pipefail` a grep on a MISSING file
# exits 2, pipefail propagates it, and `x="$(_field ...)"` then aborts the whole sweep —
# which is exactly what a `director-*.lock` (no `owner` file) did: every reaper run died
# at exit 2, swallowed by dozer.sh's `|| true`, so nothing was ever requeued or reaped
# while a Director held a lock (GSAI-96). Absence is expressed as empty output, not an error.
_field()  { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }
_lockdir() { printf '%s/%s.lock' "$LOCK_DIR" "${1//\//_}"; }

# LOCK_DIR is a SHARED namespace (~/.dozers/locks): the Dozer's run-locks live beside
# other holders' mutexes — notably the Directors' `director-<role>.lock`, written by
# ecosystem/scripts/director-awake.sh, which stores its pid in a BARE `pid` file and
# has no `owner` at all. Reading only `owner` gave those locks an EMPTY pid, `_alive ""`
# is false, and the sweep below deleted a LIVE Director's lock — letting a second pass
# start on top of the running one (GSAI-96). Two rules keep us in our lane:
#
#   _lock_pid      — read the pid from EITHER layout, so liveness is never guessed.
#   _lock_foreign  — a lock with no `owner` is not ours. Never kill it, never remove it;
#                    its holder does its own stale recovery. We only report it.
#
# The invariant this rests on: every Dozer run-lock writes `owner` (dozer.sh run_one
# fails the run and drops the lock if it cannot), so "no owner" means "not a run-lock".
# (The first symptom was worse than a wrong verdict: reading a missing `owner` under
# `set -e` aborted the sweep outright — see _field above.)
_lock_pid() {
  local lock="$1" pid
  pid="$(_field "$lock/owner" pid)"
  [[ -z "$pid" && -f "$lock/pid" ]] && pid="$(head -1 "$lock/pid" 2>/dev/null | tr -dc '0-9')"
  printf '%s' "$pid"
}
_lock_foreign() { [[ ! -f "$1/owner" ]]; }

# Is <id>'s lock backed by a LIVE worker (pid alive AND within max-age)?
# echoes: live | stale | none | foreign
_lock_state() {
  local lock; lock="$(_lockdir "$1")"
  [[ -d "$lock" ]] || { echo none; return; }
  _lock_foreign "$lock" && { echo foreign; return; }
  local pid age; pid="$(_lock_pid "$lock")"; age=$(( $(_now) - $(_mtime "$lock") ))
  if _alive "$pid" && (( age < REAPER_MAX_AGE )); then echo live; else echo stale; fi
}

# GSAI-213: where a lane's crew leaves its artifacts, mirroring dozer.sh's own
# art_dir mapping (the marketing crew writes to "mktg", not "marketing").
_art_dir_for_lane() { case "$1" in marketing) echo mktg ;; *) echo "$1" ;; esac; }

# GSAI-213: local proof that an id's finished work outlived its worker — a Linear write
# that failed after the git work landed (the marker _terminal_write in dozer.sh writes,
# naming the verb that failed), or a dev-lane merge receipt with no marker (a kill -9
# after the merge, before run_one wrote anything). A proof is EVIDENCE, not a verdict:
# the reaper re-proves the work against git before it retries anything (BRD-96 was a
# finished merge requeued because nobody looked).
#
# Sets, and always returns 0 (this runs under `set -euo pipefail`, and a nonzero return
# here would abort the whole sweep):
#   PROOF_STATE    retry     proven against git — retry PROOF_VERB for the id
#                  legacy    a merge receipt with no workdir= (written before this change):
#                            it cannot be verified, so the id is HELD, never requeued
#                  unproven  a marker/receipt exists but git does not back it — requeue
#                  none      no proof at all — ordinary requeue
#   PROOF_VERB     the tasks/linear.sh verb to retry (task_merged / task_review / task_block)
#   PROOF_WORKDIR  the checkout the work landed in
#   PROOF_REASON   one line for the log
# Host-local: .artifacts/ lives on the machine that ran the crew, so a crew on another
# host is invisible here and falls through to the ordinary requeue.
_prove_terminal_write() {  # <id> <lane>
  local id="$1" lane="$2" art marker rec verb="" wd="" rec_wd="" vout=""
  PROOF_STATE=none PROOF_VERB="" PROOF_WORKDIR="" PROOF_REASON=""
  art="$ROOT/.artifacts/$(_art_dir_for_lane "$lane")"
  marker="$art/$id.linear-write-failed"; rec="$art/$id.merge"
  if [[ -s "$marker" ]]; then
    verb="$(_field "$marker" verb)"; wd="$(_field "$marker" workdir)"
  fi
  if [[ -s "$rec" ]]; then
    rec_wd="$(_field "$rec" workdir)"
    [[ -z "$verb" ]] && verb=task_merged
    [[ -z "$wd" ]] && wd="$rec_wd"
  fi
  if [[ -z "$verb" ]]; then return 0; fi

  PROOF_VERB="$verb" PROOF_WORKDIR="$wd"
  if [[ "$verb" == task_merged && -z "$wd" ]]; then
    PROOF_STATE=legacy
    PROOF_REASON="the merge receipt has no workdir= (written before GSAI-213), so it cannot be re-verified against git"
    return 0
  fi
  case "$verb" in
    task_merged)
      # The same gate run_one uses: the receipt's merge sha must be a NEW ancestor of the
      # integration branch in $wd, containing the task's own tip (GSAI-119 / GSAI-211 / GSAI-217).
      if vout="$(REPO_ROOT="$ROOT" "$ROOT/dozers/verify-merge.sh" "$id" "$wd" 2>&1)"; then
        PROOF_STATE=retry
      else
        PROOF_STATE=unproven; PROOF_REASON="verify-merge: ${vout%%$'\n'*}"
      fi ;;
    task_review)
      # Marketing: the staged draft is the only evidence the work exists.
      if [[ -n "$wd" && -s "$wd/.dozers-review/$id.md" ]]; then
        PROOF_STATE=retry
      else
        PROOF_STATE=unproven; PROOF_REASON="no staged draft at $wd/.dozers-review/$id.md"
      fi ;;
    task_block)
      # The work did not finish; re-stating the block needs no git proof.
      PROOF_STATE=retry ;;
    *)
      PROOF_STATE=unproven; PROOF_REASON="unknown verb '$verb' in the write-failure marker" ;;
  esac
  return 0
}

declare -A REAPED=()
_reap_lock() {   # kill a runaway worker (if still alive) + remove its stale lock
  local id="$1" lock; lock="$(_lockdir "$id")"
  [[ -d "$lock" ]] || return 0
  _lock_foreign "$lock" && return 1          # not a Dozer run-lock — hands off
  [[ -n "${REAPED[$id]:-}" ]] && return 0
  REAPED[$id]=1
  local pid; pid="$(_lock_pid "$lock")"
  if _alive "$pid"; then   # over-age but process still running => runaway; kill it (watchdog)
    if [[ "$DRY_RUN" == 1 ]]; then echo "  [dry] would KILL runaway worker pid=$pid ($id)"
    else kill "$pid" 2>/dev/null || true; sleep 1; kill -9 "$pid" 2>/dev/null || true; echo "  killed runaway worker pid=$pid ($id)"; fi
  fi
  if [[ "$DRY_RUN" == 1 ]]; then echo "  [dry] would reap stale lock: $id"
  else rm -rf "$lock" && echo "  reaped stale lock: $id"; fi
}

reaped=0 requeued=0 healthy=0 foreign=0 relabeled=0 rewritten=0 held=0

# ── 0. Reconcile stale off-ramp labels (GSAI-213) ───────────────────────────────
# An issue carrying dozer:in-progress TOGETHER WITH an off-ramp label
# (merged-develop/needs-review/blocked) already finished — tests/linear-inflight-
# test.sh's MERGED-2 fixture is the standing proof the sweep below must never requeue
# that shape (GSAI-119: the work is done; requeueing would re-run a finished crew).
# Until now nothing ever went back and stripped the lingering in-progress label, so
# the issue sat in the Linear "Running" view forever even though it was done. Run
# BEFORE the orphan sweep, guarded the same way: only acts when no live worker holds
# the id.
if declare -F task_list_stale_offramp >/dev/null && declare -F task_finish_repair >/dev/null; then
  while IFS=$'\t' read -r id lane title; do
    [[ -z "$id" ]] && continue
    [[ "$(_lock_state "$id")" == "live" ]] && continue   # a worker is still on it — leave it
    if [[ "$DRY_RUN" == 1 ]]; then
      echo "  [dry] would finish-repair $id (lane:${lane:-?}): stale dozer:in-progress next to an off-ramp label"
    elif task_finish_repair "$id"; then
      task_comment "$id" "♻️ Reaper stripped a lingering dozer:in-progress label — this task already finished (it carries an off-ramp label); the in-progress label just never cleared." 2>/dev/null || true
      echo "  finish-repaired $id (lane:${lane:-?}): stale dozer:in-progress stripped"
    else
      echo "  ! could not finish-repair $id (backend refused)" >&2; continue
    fi
    relabeled=$((relabeled+1))
  done < <(task_list_stale_offramp 2>/dev/null || true)
else
  echo "  (backend '$BACKEND' has no task_list_stale_offramp/task_finish_repair — stale off-ramp repair skipped)" >&2
fi

# ── 1. Requeue orphaned in-flight tasks (claimed, but no live worker) ───────────
if declare -F task_list_inflight >/dev/null; then
  while IFS=$'\t' read -r id lane title; do
    [[ -z "$id" ]] && continue
    case "$(_lock_state "$id")" in
      live)  healthy=$((healthy+1)); continue ;;        # a worker is on it — leave it
      stale) if _reap_lock "$id"; then reaped=$((reaped+1)); fi ;;
      none)  : ;;                                        # already lockless, still orphaned
      # A task id holding a lock we did not write: we cannot prove anything about it,
      # and requeueing while the lock stands would just loop (drain skips locked ids).
      foreign) echo "  ! $id is locked by a non-Dozer holder — left alone" >&2; continue ;;
    esac
    # GSAI-213: local, git-backed proof this id's work is already done (a merge
    # receipt, or a write-failure marker naming the exact verb that failed) must be
    # checked BEFORE requeueing — otherwise the ENTIRE crew (architect→build→test→
    # merge) reruns on a task whose work is already merged and verified. Retry just
    # the recorded Linear write instead. Falls back to the ordinary requeue path
    # when no such proof exists (the genuine-crash case this reaper already handles).
    _prove_terminal_write "$id" "$lane"
    case "$PROOF_STATE" in
      retry)
        if [[ "$DRY_RUN" == 1 ]]; then
          echo "  [dry] would retry terminal write '$PROOF_VERB' for $id instead of requeuing (proof checked against git: $PROOF_WORKDIR)"
        elif "$PROOF_VERB" "$id"; then
          rm -f "$ROOT/.artifacts/$(_art_dir_for_lane "$lane")/$id.linear-write-failed" 2>/dev/null || true
          task_comment "$id" "♻️ Reaper found a Linear write from a previous run that failed ($PROOF_VERB), re-checked it against git, and re-applied it instead of requeueing the task." 2>/dev/null || true
          echo "  retried terminal write '$PROOF_VERB' for $id (lane:${lane:-?}) instead of requeuing"
        else
          # The proof is good, so the work is finished. Requeueing it would re-run a
          # finished crew (the BRD-96 failure). Hold it; the marker stays for the next pass.
          echo "  ! retry of '$PROOF_VERB' for $id still failed — held in-progress, the work is git-verified; marker kept for the next pass" >&2
          continue
        fi
        rewritten=$((rewritten+1)); continue ;;
      legacy)
        # Unverifiable, so neither retry nor requeue. One comment, then quiet: the sentinel
        # keeps every later pass from re-posting it.
        noted="$ROOT/.artifacts/$(_art_dir_for_lane "$lane")/$id.legacy-proof-noted"
        if [[ "$DRY_RUN" == 1 ]]; then
          echo "  [dry] would hold $id in-progress: $PROOF_REASON"
        else
          if [[ ! -e "$noted" ]] && task_comment "$id" "⚠️ Reaper cannot verify this task's finished merge: $PROOF_REASON. It is left at dozer:in-progress rather than requeued, because a requeue would re-run finished work. A Director should check the merge on the integration branch and re-label the task." 2>/dev/null; then
            : > "$noted"
          fi
          echo "  ! $id held in-progress: $PROOF_REASON" >&2
        fi
        held=$((held+1)); continue ;;
      unproven)
        echo "  · $id: local proof did not check out ($PROOF_REASON) — requeueing" >&2 ;;
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
# LOCK_DIR is shared, so this glob sees other holders' locks too. Skip anything without
# an `owner` — it is not a run-lock, and deleting it out from under a live holder is the
# GSAI-96 bug. Their pid is still probed, purely so the report tells the truth.
shopt -s nullglob
for lock in "$LOCK_DIR"/*.lock; do
  if _lock_foreign "$lock"; then
    foreign=$((foreign+1))
    pid="$(_lock_pid "$lock")"
    _alive "$pid" || echo "  · foreign lock left alone (holder pid=${pid:-?} not alive): $(basename "$lock")"
    continue
  fi
  local_id="$(_field "$lock/owner" task)"; [[ -z "$local_id" ]] && local_id="$(basename "$lock" .lock)"
  pid="$(_lock_pid "$lock")"; age=$(( $(_now) - $(_mtime "$lock") ))
  _alive "$pid" && (( age < REAPER_MAX_AGE )) && continue
  before="${REAPED[$local_id]:-}"
  _reap_lock "$local_id" || continue
  [[ -z "$before" ]] && reaped=$((reaped+1))
done
shopt -u nullglob

# ── 3. Release-cap sweep (GSAI-252) — an exhausted issue must never sit without a board-ask.
# Throttled inside the verb (BUDGET_SWEEP_EVERY), so calling it on every reaper pass is cheap.
# A failure is reported, not fatal: the reaper's requeue and lock work above already ran.
if declare -F task_budget_sweep >/dev/null; then
  if [[ "$DRY_RUN" == 1 ]]; then
    task_budget_sweep --dry-run || echo "  ! budget sweep reported failures (see above)" >&2
  else
    task_budget_sweep || echo "  ! budget sweep reported failures (see above)" >&2
  fi
fi

printf '[reaper] %srequeued=%d reaped-locks=%d healthy=%d foreign-skipped=%d relabeled=%d rewritten=%d held=%d\n' \
  "$([[ "$DRY_RUN" == 1 ]] && echo '(dry) ')" "$requeued" "$reaped" "$healthy" "$foreign" "$relabeled" "$rewritten" "$held"
