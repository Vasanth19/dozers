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
# 2026-09-05 crash loop: launchd's com.dozers.loop resolved a stale Homebrew
# `claude` (2.1.201) ahead of ~/.npm-global/bin/claude (2.1.261), crashing crews.
export PATH="$HOME/.npm-global/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tasks/adapter.sh"

cfg() { grep -E "^$1:" "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true; }
POLL_SECONDS="${POLL_SECONDS:-30}"
FANOUT="${FANOUT:-$(cfg fanout)}"; FANOUT="${FANOUT:-1}"; (( FANOUT < 1 )) && FANOUT=1
LOCK_DIR="${LOCK_DIR:-$HOME/.dozers/locks}"; mkdir -p "$LOCK_DIR"
# Liveness heartbeat: a single beacon the engine keeps fresh, so an external watcher
# (dozers/heartbeat-check.sh, or `doctor`) can tell the loop is still alive and how
# busy it is.
HEARTBEAT_FILE="${HEARTBEAT_FILE:-$HOME/.dozers/heartbeat}"
# How often the beacon is re-emitted while the engine is up. Deliberately NOT tied to
# the drain: a drain can run far longer than a poll interval and the beacon has to keep
# advancing through it (see beat_start). Watchers read this cadence off the beacon
# itself (`every=`) instead of guessing, so emitter and monitor cannot drift apart.
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-$POLL_SECONDS}"
[[ "$HEARTBEAT_SECONDS" =~ ^[0-9]+$ ]] || HEARTBEAT_SECONDS=30
(( HEARTBEAT_SECONDS < 1 )) && HEARTBEAT_SECONDS=1

# Snapshot count of in-flight run-locks (tasks claimed across every Dozer on this host,
# since LOCK_DIR is shared). Cheap directory scan, no backend call.
inflight_count() {
  local n=0 lock; shopt -s nullglob
  for lock in "$LOCK_DIR"/*.lock; do n=$((n+1)); done
  shopt -u nullglob; printf '%s' "$n"
}

# Epoch seconds of the last beat. The beacon is rewritten atomically (tmp + rename) on
# every beat, so its MTIME *is* the beat time — no ISO-8601 parsing, and portable across
# BSD and GNU date. Missing file -> 0 (infinitely old), which is the honest answer.
beacon_epoch() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Emit the heartbeat: last-poll ts + engine pid + LIVE in-flight count + the beat
# cadence. Written atomically (tmp then mv) so a reader never sees a half-written
# beacon; the tmp name uses $BASHPID (not $$) so the background ticker and the main
# shell can never clobber each other's temp file. Best-effort — a failed write must
# never take down the poll loop.
#
# Arg $1 = poll tick number. OMITTED means "keep the tick already on the beacon" —
# that is what the ticker does when it re-beats mid-drain, so a fresh `ts` never
# pretends to be a new poll cycle.
heartbeat() {
  local tick="${1:-}"
  [[ -z "$tick" ]] && tick="$(grep -E '^poll=' "$HEARTBEAT_FILE" 2>/dev/null | head -1 | cut -d= -f2)"
  [[ -z "$tick" ]] && tick=0
  mkdir -p "$(dirname "$HEARTBEAT_FILE")" 2>/dev/null || true
  local tmp="$HEARTBEAT_FILE.$BASHPID.tmp"
  printf 'pid=%s\nhost=%s\nts=%s\ninflight=%s\npoll=%s\nevery=%s\n' \
    "$$" "$(hostname -s 2>/dev/null || echo local)" \
    "$(date -u +%FT%TZ 2>/dev/null || date)" "$(inflight_count)" "$tick" "$HEARTBEAT_SECONDS" \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$HEARTBEAT_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# ── Keep the beacon beating WHILE the engine works (GSAI-31) ────────────────────
# heartbeat() used to be called only between polls, and `drain` blocks until its crews
# finish — so the beacon froze for the whole drain. Observed live 2026-09-06 04:12-04:25Z:
# unchanged for 13 minutes at `inflight=0` while this engine was healthily supervising
# three crews. Both fields lied: `ts` looked dead, `inflight` looked idle. A monitor
# built on that beacon false-alarms on every long task and is blind to the real load.
#
# The fix takes the beat off the loop's clock. A background ticker re-emits every
# HEARTBEAT_SECONDS for as long as the engine lives. Being a subshell it inherits $$
# (the ENGINE's pid), so the beacon still names the process a watcher should probe, and
# it re-counts run-locks on every beat, so `inflight` is live rather than a snapshot.
#
# It must never outlive the engine — a ticker still beating for a dead engine is a
# beacon that lies, the one failure a liveness monitor cannot survive. So it re-probes
# the engine with `kill -0` every iteration and stops within one tick of the engine
# going away, SIGKILL included (which no trap can catch). The EXIT trap in `loop` only
# makes the ordinary case immediate.
BEAT_PID=""
beat_start() {
  [[ -n "$BEAT_PID" ]] && return 0
  local engine=$$
  ( while kill -0 "$engine" 2>/dev/null; do
      sleep "$HEARTBEAT_SECONDS"
      kill -0 "$engine" 2>/dev/null || break
      heartbeat
    done ) 2>/dev/null &
  BEAT_PID=$!
}
beat_stop() {
  [[ -n "$BEAT_PID" ]] || return 0
  kill "$BEAT_PID" 2>/dev/null || true
  wait "$BEAT_PID" 2>/dev/null || true
  BEAT_PID=""
}

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

  # The crew leaves TWO artifacts: <id>.summary on success, <id>.fail (the reason) on
  # failure — the latter goes into the block comment so a Director never has to read
  # loop.err.log to learn why (GSAI-26 #3).
  local summary_file="$ROOT/.artifacts/$lane/$id.summary" fail_file="$ROOT/.artifacts/$lane/$id.fail"
  rm -f "$summary_file" "$fail_file" 2>/dev/null || true
  if WORKDIR="$workdir" DOZER_PERSONA="$persona" REPO_ROOT="$ROOT" "$crew" "$id" "$title"; then
    local verb
    if [[ "$lane" == "marketing" ]]; then task_review "$id"; verb="staged for review"; else task_merged "$id"; verb="merged to develop"; fi
    local body
    if [[ -s "$summary_file" ]]; then body="$(head -n 10 "$summary_file")"; else body="- completed via lane:$lane"; fi
    task_comment "$id" "$(printf 'Dozer %s - lane:%s\n%s' "$verb" "$lane" "$body")"
    echo "  ok #$id $verb"
  else
    local reason
    if [[ -s "$fail_file" ]]; then reason="$(head -c 2000 "$fail_file")"
    else reason="crew exited without recording a reason — see the Dozer loop log (~/.dozers/logs/loop.err.log)"; fi
    task_block "$id"
    task_comment "$id" "$(printf 'Dozer blocked in lane:%s - needs a look.\nReason: %s' "$lane" "$reason")"
    echo "  x #$id failed: $reason" >&2
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

# Health view (a witness/doctor): what's in flight, is it alive, and orphans.
doctor() {
  echo "== dozer doctor =="
  echo "-- in-flight run-locks ($LOCK_DIR) --"
  shopt -s nullglob; local any=0 lock id pid ts st
  for lock in "$LOCK_DIR"/*.lock; do
    any=1
    id="$(grep -E '^task=' "$lock/owner" 2>/dev/null | cut -d= -f2)"; [[ -z "$id" ]] && id="$(basename "$lock" .lock)"
    pid="$(grep -E '^pid=' "$lock/owner" 2>/dev/null | cut -d= -f2)"
    ts="$(grep -E '^ts=' "$lock/owner" 2>/dev/null | cut -d= -f2)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then st="ALIVE pid=$pid"; else st="DEAD/stale pid=${pid:-?}"; fi
    printf '   %-14s %-22s since %s\n' "$id" "[$st]" "${ts:-?}"
  done
  shopt -u nullglob; (( any )) || echo "   (none)"
  echo "-- engine heartbeat ($HEARTBEAT_FILE) --"
  if [[ -f "$HEARTBEAT_FILE" ]]; then
    local hpid hts hinf hpoll hevery hst hage
    hpid="$(grep -E '^pid='      "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2)"
    hts="$(grep -E '^ts='        "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2)"
    hinf="$(grep -E '^inflight=' "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2)"
    hpoll="$(grep -E '^poll='    "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2)"
    # `|| true` is not decoration: a beacon written before GSAI-31 has no `every=` line,
    # grep exits 1, and under `set -e` that killed `doctor` mid-report — the health
    # command dying on the exact legacy state you'd run it to inspect.
    hevery="$(grep -E '^every='  "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2 || true)"; hevery="${hevery:-$HEARTBEAT_SECONDS}"
    if [[ -n "$hpid" ]] && kill -0 "$hpid" 2>/dev/null; then hst="ALIVE"; else hst="DEAD/stale"; fi
    # Age of the beacon: with the ticker running it should never exceed `every` by much.
    hage="$(( $(date +%s) - $(beacon_epoch "$HEARTBEAT_FILE") ))"
    (( hage >= 3 * hevery )) && hst="$hst/STALE" || true
    printf '   [%s] pid=%s  beat=%s (%ss ago, every %ss)  in-flight=%s  poll#=%s\n' \
      "$hst" "${hpid:-?}" "${hts:-?}" "$hage" "$hevery" "${hinf:-?}" "${hpoll:-?}"
  else
    echo "   (no heartbeat yet — engine not looping)"
  fi
  echo "-- worktrees ($HOME/.dozers/worktrees) --"; ls -1 "$HOME/.dozers/worktrees" 2>/dev/null | sed 's/^/   /' || echo "   (none)"
  echo "-- backend in-flight (claimed) --"
  if declare -F task_list_inflight >/dev/null; then task_list_inflight 2>/dev/null | sed 's/^/   /'; else echo "   (backend has no inflight view)"; fi
}

case "${1:-once}" in
  once)    echo "[dozer] recovering stranded work, then draining (fanout=$FANOUT)..."; recover; drain ;;
  recover) recover "${2:-}" ;;                              # run the reaper standalone (pass --dry-run)
  heartbeat) heartbeat "${2:-}"; cat "$HEARTBEAT_FILE" ;;   # emit one beat now, print it (scriptable/testable)
  doctor)  doctor ;;                                        # health view: in-flight, alive?, orphans
  loop) echo "[dozer] looping every ${POLL_SECONDS}s, fanout=$FANOUT, beating every ${HEARTBEAT_SECONDS}s (Ctrl-C to stop)"
        recover                                             # heal once on startup
        REAPER_EVERY="${REAPER_EVERY:-10}"; ticks=0         # then re-run every N polls
        heartbeat "$ticks"                                  # beat once before the first drain
        trap 'beat_stop' EXIT                               # stop the ticker the moment we go
        trap 'beat_stop; exit 0' INT TERM
        beat_start                                          # ...then keep beating THROUGH each drain
        while true; do
          echo "[dozer] $(date '+%H:%M:%S') poll"; drain
          ticks=$((ticks+1)); heartbeat "$ticks"            # stamp the new tick (the ticker keeps ts fresh between these)
          (( REAPER_EVERY > 0 && ticks % REAPER_EVERY == 0 )) && recover
          sleep "$POLL_SECONDS"
        done ;;
  *) echo "usage: dozer.sh [once|loop|recover [--dry-run]|heartbeat [tick]|doctor]" >&2; exit 1 ;;
esac
