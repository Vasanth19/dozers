#!/usr/bin/env bash
# dozers/dozer.sh — the execution engine (floor boss for the Dozers).
#
# Polls the backend for work carrying the greenlight (ready) AND a lane, claims it,
# resolves the task's PROJECT working dir (from the task's team/org or repo hint),
# cd's the crew into it, runs the crew, posts incremental updates ON the task.
# Multi-team aware, parallel-safe (atomic mkdir lock), fan-out capable. Crews are
# SLOTS that outlive a poll (GSAI-37): a finished crew's slot is refilled at once, a
# slow crew holds only its own slot, and the poll keeps advancing throughout.
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
# GSAI-60: every scripted comment self-stamps `<!-- board-note by:<this> -->` — the
# board reconcile reads an unmarked comment as Vas's answer.
export DOZER_COMMENT_BY="dozer-engine"

cfg() { grep -E "^$1:" "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true; }
POLL_SECONDS="${POLL_SECONDS:-30}"
FANOUT="${FANOUT:-$(cfg fanout)}"; FANOUT="${FANOUT:-1}"; (( FANOUT < 1 )) && FANOUT=1
LOCK_DIR="${LOCK_DIR:-$HOME/.dozers/locks}"; mkdir -p "$LOCK_DIR"

# ── Per-team crew-slot caps (GSAI-169) ─────────────────────────────────────────
# `fanout` is a GLOBAL cap, and a global cap is won by whoever greenlights the most.
# That is how the factory ends up building the factory: the 2026-09-20 audit found 57%
# of the Ollama allowance going to GSAI housekeeping — engine chores, monitors, registry
# hygiene — while CFW, the team with actual customers, queued behind them. Every one of
# those tasks was legitimately greenlit; none was worth half the fleet.
#
# So slots are budgeted per GROUP of teams (org/config.yaml → fanout_by_group), and
# drain() never claims an issue whose group already holds its cap in live crew locks —
# it skips PAST it to the next eligible issue from another group. A saturated group
# costs that group throughput and nobody else's.
#
# This changes only WHO may be claimed right now, never the ORDER: the queue is still
# sorted by KR date then priority (GSAI-172/105), and drain still walks it top-down.
#
# GROUP_TEAMS[i] is the group's team list, space-padded (" CFW GSAI ") so a match is
# whole-word; GROUP_SLOTS[i] is its cap. Parallel indexed arrays rather than an
# associative one — this file is deliberately readable bash, and the arrays are tiny.
# A team in no group falls into ONE shared default group, index ${#GROUP_SLOTS[@]},
# with DEFAULT_GROUP_SLOTS (1) — so a newly added team can never quietly take the whole
# fleet before somebody budgets it.
GROUP_TEAMS=(); GROUP_SLOTS=()
DEFAULT_GROUP_SLOTS="${DEFAULT_GROUP_SLOTS:-1}"

load_groups() {
  local cfgf="$ROOT/org/config.yaml" line teams slots sum=0
  # A tiny targeted parser, not a YAML dependency: this repo ships no package manager on
  # purpose, and cfg() (a grep for `^key:`) cannot read a list. Reads the flow-style
  # `- { teams: [A, B], slots: N }` rows under `fanout_by_group:` and stops at the next
  # top-level key.
  while IFS= read -r line; do
    teams="$(sed -n 's/.*teams:[[:space:]]*\[\([^]]*\)\].*/\1/p' <<<"$line")"
    slots="$(sed -n 's/.*slots:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$line")"
    [[ -n "$teams" && -n "$slots" ]] || continue
    teams="$(tr ',' ' ' <<<"$teams" | tr -s ' ' | sed 's/^ *//; s/ *$//')"
    [[ -n "$teams" ]] || continue
    GROUP_TEAMS+=(" $teams "); GROUP_SLOTS+=("$slots"); sum=$(( sum + slots ))
  done < <(awk '/^fanout_by_group:/{f=1;next} f&&/^[^[:space:]#-]/{exit} f&&/^[[:space:]]*-/{print}' "$cfgf" 2>/dev/null || true)
  # A sum over fanout cannot over-subscribe the engine (fanout still caps globally) but
  # it makes these numbers a fiction — the groups would race for a pool smaller than
  # their budgets, which is the lottery the caps exist to end. Say so, loudly.
  if (( ${#GROUP_SLOTS[@]} && sum > FANOUT )); then
    echo "[dozer] WARNING: fanout_by_group slots sum to $sum but fanout is $FANOUT — the caps are a fiction until one of the two is fixed (org/config.yaml)." >&2
  fi
}

team_of() { printf '%s' "${1%%-*}"; }   # CFW-237 -> CFW (an id with no dash is its own team)

group_index() {  # <team> -> the group's array index, or ${#GROUP_SLOTS[@]} = the default group
  local team="$1" i
  for (( i = 0; i < ${#GROUP_TEAMS[@]}; i++ )); do
    [[ "${GROUP_TEAMS[i]}" == *" $team "* ]] && { printf '%s' "$i"; return 0; }
  done
  printf '%s' "${#GROUP_SLOTS[@]}"
}

group_cap() {  # <group index> -> its slot cap
  local gi="$1"
  if (( gi < ${#GROUP_SLOTS[@]} )); then printf '%s' "${GROUP_SLOTS[gi]}"
  else printf '%s' "$DEFAULT_GROUP_SLOTS"; fi
}

# Live crew locks per group, one count per index (groups, then the default group last).
# Counts LOCKS, not $CREWS: the lock dir is the cross-drain, cross-process truth, and a
# crew launched by an earlier drain holds no pid in this shell's CREWS array anyway. Same
# three exclusions as inflight_count — a Director's mutex, an owner-less lock, and a lock
# whose owner pid is dead (a crashed crew is the reaper's problem, and counting it would
# starve a group of a slot nothing is using).
group_live_counts() {
  # `gn`, not `n`: inflight_count above uses `n` as a scalar, and one name meaning two
  # shapes in one file is a shellcheck warning and a reader's trap.
  local -a gn=(); local IFS=' '; local i lock pid id
  for (( i = 0; i <= ${#GROUP_SLOTS[@]}; i++ )); do gn[i]=0; done
  shopt -s nullglob
  for lock in "$LOCK_DIR"/*.lock; do
    case "${lock##*/}" in director-*.lock) continue ;; esac
    [[ -f "$lock/owner" ]] || continue
    pid="$( { grep -E '^pid=' "$lock/owner" 2>/dev/null || true; } | head -1 | cut -d= -f2-)"
    { [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; } || continue
    id="$( { grep -E '^task=' "$lock/owner" 2>/dev/null || true; } | head -1 | cut -d= -f2-)"
    [[ -n "$id" ]] || id="$(basename "$lock" .lock)"
    i="$(group_index "$(team_of "$id")")"
    gn[i]=$(( ${gn[i]:-0} + 1 ))
  done
  shopt -u nullglob
  printf '%s' "${gn[*]}"
}

load_groups
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
#
# CREW locks only (GSAI-76). $LOCK_DIR is shared with the DIRECTORS: every awake pass
# takes a `director-<role>.lock` there as its own single-pass mutex
# (~/ecosystem/scripts/director-awake.sh), storing a bare `pid` file, never an `owner`.
# Counting them made the beacon publish `inflight = crews + live Director passes`, and
# the watchdog gates on that number. Observed 2026-09-08 23:24Z: the beacon said
# `inflight=4` while exactly ONE crew was running (BRD-82), and heartbeat-check alarmed
# on the fiction. The dangerous direction is the mirror: three Director locks plus two
# stuck crews reach `fanout=5`, the not-dispatching gate `inflight < FANOUT` goes false,
# and a REAL stall reports nothing.
#
# GSAI-96 added a second, more general exclusion alongside the name match: skip any
# lock with no `owner` file, not only ones literally named `director-*.lock`. That
# survives a foreign mutex under a different name; keeping BOTH guards (rather than
# swapping one for the other) also covers the case GSAI-76's original comment worried
# about — a `director-*.lock` that someday grows an `owner` file — since the name match
# still excludes it even then. It is also now SAFE to rely on the owner-file guard,
# because run_one() no longer tolerates a failed `owner` write (it fails the run and
# drops the lock instead); the old "owner-less lock could still be one of OURS, mid-race"
# case this file used to hedge against cannot happen post-GSAI-96.
#
# So three exclusions, all at the source rather than at the reader:
#   · `director-*.lock` by name — not a crew, never was.
#   · no `owner` file at all — not a crew lock (a Director's, or any other holder's).
#   · an `owner` file whose pid is dead — a crashed crew is the reaper's problem, not
#     in-flight work; counting it holds the beacon high long after the work stopped.
inflight_count() {
  local n=0 lock pid; shopt -s nullglob
  for lock in "$LOCK_DIR"/*.lock; do
    case "${lock##*/}" in director-*.lock) continue ;; esac
    [[ -f "$lock/owner" ]] || continue
    # The || true is load-bearing (GSAI-76 review): this script runs under
    # `set -euo pipefail`, so a no-match grep would fail the whole pipeline through
    # the trailing cut, fail the assignment, and abort the shell. Verified live: with
    # an owner-less lock present, the unguarded line exits 2 with no output. In the
    # ticker subshell that failure is SILENT (stderr discarded), the beacon freezes,
    # and the watchdog false-alarms engine-stalled — the exact failure class this fix
    # exists to kill.
    pid="$( { grep -E '^pid=' "$lock/owner" 2>/dev/null || true; } | head -1 | cut -d= -f2-)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then n=$((n+1)); fi
  done
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
  # Same pipefail guard as inflight_count: a missing beacon or a beacon without
  # a poll= line makes grep exit 1, and under set -e the failed assignment would
  # abort the whole beacon path (ticker AND the main-loop beat at every poll).
  [[ -z "$tick" ]] && tick="$( { grep -E '^poll=' "$HEARTBEAT_FILE" 2>/dev/null || true; } | head -1 | cut -d= -f2)"
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

# Names by which THIS checkout may legitimately be labelled: its directory name and
# its origin-URL basename. Derived, never hardcoded — the engine repo can be renamed or
# forked and this still answers correctly. Only used to let a `repo:dozers` task work on
# the engine on purpose, while any other id that resolves here is refused.
is_engine_alias() {
  local want; want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  local origin; origin="$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null || true)"
  local a
  for a in "$(basename "$ROOT")" "$(basename "${origin%.git}")"; do
    a="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
    [[ -n "$a" && "$a" == "$want" ]] && return 0
  done
  return 1
}

# True when two paths are the same directory on disk (symlinks and ".." resolved), so
# a symlinked or aliased path cannot slip past the engine-repo guard below.
same_dir() {
  local a b
  a="$(cd "$1" 2>/dev/null && pwd -P || true)"
  b="$(cd "$2" 2>/dev/null && pwd -P || true)"
  [[ -n "$a" && "$a" == "$b" ]]
}

# Resolve a task's working dir from the CANONICAL registry (~/ecosystem/ecosystem.yaml),
# most-specific first:
#   1) repo:<id> hint on the task   2) the task's Linear TEAM/org   3) config workdir_default
# repo:<id> matches BOTH registry lists — projects: and infrastructure: (GSAI-17) — so
# infra repos (paperclip, openclaw, gbrain-source) route like any product repo.
# Paths live ONLY in ecosystem.yaml — never hardcoded here or in a label.
#
# ── Fail fast; never guess a repo (GSAI-131) ──────────────────────────────────
# This used to swallow the resolver's stderr (`2>/dev/null || true`) and then fall
# through THREE silent fallbacks onto $ROOT — the repo that holds the engine itself.
# Caught live on BRD-85 (2026-09-15): two runs, identical labels (`repo:mr-growth-guide`),
# two different working dirs — the second landed in ~/Code/dozers, where a crew spent
# ~2 min writing a brand repo's test suite into the engine and cut dozer/BRD-85 off the
# ENGINE's develop. Resolving by hand worked, so the miss was transient: ecosystem.yaml
# is read on every resolve and is edited live by other crews and Directors, so a
# momentary parse failure is expected and will recur. The defect is the fallback, not
# the flake. Three rules now hold:
#   1. An explicit repo:<id> is resolved ALONE. The resolver's own repo->team fallback
#      is the same class of bug — a task that names its repo must never be quietly
#      demoted into the team's default repo.
#   2. The resolver's stderr is captured and reported, never discarded, so the block
#      comment says WHY routing failed instead of leaving a cwd= line nobody reads.
#   3. A task that carries an identity — a repo: label OR a team — is never routed by
#      a fallback at all: it resolves through the registry or it blocks. So the engine's
#      own checkout is unreachable by a foreign task. The configured workdir_default
#      (and its "." = here) survives for exactly one case: a task that names neither a
#      repo nor a team, i.e. the zero-config files-backend mode where the Dozer works
#      on the repo it ships in. Nothing about such a task points anywhere else, so that
#      is a configured answer, not a guess.
# Prints the path on stdout and returns 0. On failure prints the reason on stderr and
# returns 1; run_one blocks the task before any crew — and so any worktree — exists.
resolve_workdir() {
  local hint="$1" team="$2" cfgf="$ROOT/org/config.yaml"
  local path="" src="" err="" rc=0 errf
  errf="$(mktemp "${TMPDIR:-/tmp}/dozer-workdir.XXXXXX" 2>/dev/null)" || errf="/tmp/dozer-workdir.$$"

  if [[ -n "$hint" ]]; then
    # Canonical source: ecosystem.yaml (repo id -> local). NO --team here, on purpose:
    # the resolver falls back repo->team internally, and a named repo silently becoming
    # the team's default repo is the same defect wearing a smaller hat.
    src="repo:$hint"
    path="$(python3 "$ROOT/tasks/ecosystem_workdir.py" --repo "$hint" 2>"$errf")" || rc=$?
    err="$(head -c 1000 "$errf" 2>/dev/null || true)"; rm -f "$errf" 2>/dev/null || true
    if (( rc != 0 )) || [[ -z "$path" ]]; then
      printf 'repo:%s does not resolve to a checkout in ~/ecosystem/ecosystem.yaml (resolver rc=%s).%s Refusing to substitute a different repo — register the id there (or fix the registry), then re-greenlight.\n' \
        "$hint" "$rc" "${err:+ Resolver said: ${err//$'\n'/ }}" >&2
      return 1
    fi
  elif [[ -n "$team" ]]; then
    # No repo: label, but the task belongs to a team — so the registry DOES claim an
    # org repo for it. Failing to find it is drift, not an invitation to improvise.
    src="team:$team"
    path="$(python3 "$ROOT/tasks/ecosystem_workdir.py" --team "$team" 2>"$errf")" || rc=$?
    err="$(head -c 1000 "$errf" 2>/dev/null || true)"; rm -f "$errf" 2>/dev/null || true
    if (( rc != 0 )) || [[ -z "$path" ]]; then
      printf 'team %s has no live default repo in ~/ecosystem/ecosystem.yaml (resolver rc=%s).%s Label the task repo:<id> or give the org a live project entry, then re-greenlight.\n' \
        "$team" "$rc" "${err:+ Resolver said: ${err//$'\n'/ }}" >&2
      return 1
    fi
  else
    # The task names NOTHING that points at another repo — no repo: label, no team.
    # Only here is the configured default in play, and only here can "." (the engine's
    # own checkout) be the answer: that is the zero-config/files-backend mode, where
    # the Dozer works on the repo it ships in. A task carrying an identity can never
    # reach this branch, so the engine repo stays unreachable by a foreign task.
    rm -f "$errf" 2>/dev/null || true
    src="workdir_default"
    path="${WORKDIR_DEFAULT:-$(grep -E '^workdir_default:' "$cfgf" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true)}"
    [[ -z "$path" || "$path" == "." ]] && path="$ROOT"
  fi
  path="${path/#\~/$HOME}"

  # Every branch above either returned or produced a non-empty path, so from here the
  # only question left is whether that path is really a checkout on this box.
  if [[ ! -d "$path" ]]; then
    printf '%s resolved to "%s", which is not a directory on this box — the registry entry points at a checkout that is not here.\n' "$src" "$path" >&2
    return 1
  fi
  # Backstop for rule 4: a task that named ANOTHER repo may never land in the engine's
  # own checkout, even if the registry says so — a mistyped `local:` on someone else's
  # entry would otherwise reproduce BRD-85 through the "correct" path.
  if [[ -n "$hint" ]] && same_dir "$path" "$ROOT" && ! is_engine_alias "$hint"; then
    printf 'repo:%s resolves to the Dozer engine repo itself (%s), which is not what that label names — the registry entry is almost certainly mistyped. Refusing to build a foreign repo inside the engine (GSAI-131).\n' \
      "$hint" "$ROOT" >&2
    return 1
  fi
  printf '%s' "$path"
}

# Always invoked backgrounded (own subshell), so the EXIT trap + lock are scoped.
run_one() { # <id> <lane> <title> [priority] [kr-due]
  local id="$1" lane="$2" title="$3" prio="${4:-}" kr="${5:-}"
  # atomic local mutex so parallel Dozers never double-grab the same task
  local lock="$LOCK_DIR/${id//\//_}.lock"
  if ! mkdir "$lock" 2>/dev/null; then echo "  ~ #$id locked locally, skipping"; return 0; fi
  trap 'rm -rf "$lock" 2>/dev/null || true' EXIT
  # Liveness beacon: record the worker PID so the reaper can tell a live run from a
  # crashed one (dead PID => stale lock => the task gets requeued). See dozers/reaper.sh.
  # The write is NOT best-effort: LOCK_DIR is shared with other holders (the Directors'
  # `director-<role>.lock`), and the reaper uses "has an owner file" to tell a run-lock
  # of ours from someone else's mutex (GSAI-96). An owner-less lock here would be both
  # invisible to the reaper and unreapable forever, so fail the run instead.
  if ! printf 'pid=%s\nhost=%s\ntask=%s\nlane=%s\nts=%s\n' \
    "$BASHPID" "$(hostname -s 2>/dev/null || echo local)" "$id" "$lane" \
    "$(date -u +%FT%TZ 2>/dev/null || date)" > "$lock/owner" 2>/dev/null; then
    echo "  x could not write $lock/owner - releasing lock, skipping #$id" >&2; return 1
  fi

  local lane_dir
  case "$lane" in dev) lane_dir="dev-lane";; marketing) lane_dir="mktg-lane";; *) lane_dir="$lane-lane";; esac
  local crew="$ROOT/dozers/$lane_dir/crew.sh" persona="$ROOT/dozers/$lane_dir/dozer.md"
  # Where this lane's crew leaves its artifacts (.artifacts/<dir>/<id>.*). The marketing
  # crew writes to `mktg`, not `marketing` — the engine used to read the latter, so a
  # marketing summary/fail reason never reached the task comment (found in GSAI-33).
  local art_dir; case "$lane" in marketing) art_dir="mktg";; *) art_dir="$lane";; esac
  local art="$ROOT/.artifacts/$art_dir"
  [[ -x "$crew" ]] || { echo "  x no crew for lane '$lane' ($lane_dir) - skipping #$id" >&2; return 0; }

  if ! task_claim "$id"; then echo "  ~ #$id already claimed, skipping" >&2; return 0; fi
  task_comment "$id" "Dozer claimed - lane:$lane. Starting now; will post a summary on finish."
  # GSAI-105 / GSAI-172: log the SORT KEY the pick was ordered by, so a drain log reads
  # as a plan, not a lottery — the KR's target date (the commitment the fleet is racing)
  # and then the issue priority (the tiebreak inside that KR's window). Either field is
  # empty when the backend/issue carries no such value.
  echo "  -> #$id [$lane]${prio:+ p$prio}${kr:+ kr-due:$kr} $title"

  # Routing is a PREFLIGHT (GSAI-131): a task that cannot be routed to a repo is
  # blocked here, with the resolver's real error, before a crew — and therefore before
  # a worktree, a branch or a commit — exists anywhere. The engine never guesses.
  local hint team workdir wd_err wd_errf
  hint="$(task_repo "$id" 2>/dev/null || true)"
  team="$(task_team "$id" 2>/dev/null || true)"
  wd_errf="$(mktemp "${TMPDIR:-/tmp}/dozer-route.XXXXXX" 2>/dev/null)" || wd_errf="/tmp/dozer-route.$BASHPID"
  if ! workdir="$(resolve_workdir "$hint" "$team" 2>"$wd_errf")"; then
    wd_err="$(head -c 2000 "$wd_errf" 2>/dev/null || true)"; rm -f "$wd_errf" 2>/dev/null || true
    [[ -n "$wd_err" ]] || wd_err="workdir resolution failed without a reason"
    task_block "$id"
    task_comment "$id" "$(printf 'Dozer blocked BEFORE any work - could not resolve a working directory, so no crew ran, no worktree was created and no branch was cut.\n  repo hint: %s\n  team: %s\nReason: %s' "${hint:-<none>}" "${team:-<none>}" "$wd_err")"
    echo "  x #$id unroutable: $wd_err" >&2
    return 0
  fi
  rm -f "$wd_errf" 2>/dev/null || true
  echo "    cwd -> $workdir  ${team:+[team:$team]}${hint:+ (repo:$hint)}"

  # The crew leaves up to THREE artifacts: <id>.summary on success, <id>.fail (the
  # reason) on failure — the latter goes into the block comment so a Director never has
  # to read loop.err.log to learn why (GSAI-26 #3) — and optionally <id>.handoff, the
  # crew's note for the reviewer (GSAI-33: it belongs in the task comment, never in the
  # staged deliverable).
  local summary_file="$art/$id.summary" fail_file="$art/$id.fail" handoff_file="$art/$id.handoff"
  # The merge receipt (GSAI-119) rides with the other artifacts: a STALE receipt from a
  # previous run must never vouch for this one, so it is deleted up front like the rest.
  local merge_file="$art/$id.merge"
  # <id>.meta (GSAI-170): the crew-profile facts, same stale-artifact discipline.
  local meta_file="$art/$id.meta"
  rm -f "$summary_file" "$fail_file" "$handoff_file" "$merge_file" "$meta_file" 2>/dev/null || true

  # The brief (GSAI-7): the task's description, handed to the crew as a FILE so a lane
  # can route on what the Director wrote — the marketing lane treats a `production:`
  # line as a video brief. Best-effort: a backend without task_description, or a
  # fetch that fails, leaves an empty brief and the crew runs on the title alone.
  local brief_file="$art/$id.brief"
  mkdir -p "$(dirname "$brief_file")" 2>/dev/null || true
  if declare -F task_description >/dev/null 2>&1; then
    task_description "$id" > "$brief_file" 2>/dev/null || : > "$brief_file"
  else
    : > "$brief_file"
  fi

  # The crew-profile facts (GSAI-170): the issue's PROJECT and its LABELS, fetched
  # here because this is the one place that speaks to the backend adapter. The crew
  # makes the DECISION (dozers/dev-lane/crew.sh) from this file plus DOZER_LANE.
  # Best-effort, exactly like the brief: a backend with no task_crew_meta, or a fetch
  # that fails, leaves the file EMPTY — and an empty file is no signal, which the
  # crew reads as the full trio. A backend that cannot answer must never be able to
  # quietly downgrade a code task to a single uncritiqued pass.
  : > "$meta_file"
  if declare -F task_crew_meta >/dev/null 2>&1; then
    task_crew_meta "$id" > "$meta_file" 2>/dev/null || : > "$meta_file"
  fi

  if WORKDIR="$workdir" DOZER_PERSONA="$persona" REPO_ROOT="$ROOT" DOZER_BRIEF="$brief_file" \
     DOZER_LANE="$lane" DOZER_CREW_META="$meta_file" "$crew" "$id" "$title"; then
    local verb VERIFY_PROOF=""
    if [[ "$lane" == "marketing" ]]; then
      task_review "$id"; verb="staged for review"
    elif [[ "$lane" == "dev" ]]; then
      # GSAI-119: label on PROOF, not the exit code. Crew success and merge success are
      # two different facts — an exit-0 with no merge behind it used to earn
      # dozer:merged-develop and a fake PROMOTE row on the Ship gate with nothing to
      # promote (CFW-215/CFW-252, git-verified 2026-09-14; CFW-141 twice on 2026-09-08).
      # Only the receipt the crew wrote after its green-gate — a merge SHA that IS an
      # ancestor of the integration branch in the task's own repo — earns the label.
      # Unverifiable -> block with the git evidence, NEVER label merged.
      local vout vrc=0
      # REPO_ROOT is passed EXPLICITLY: a leaked env REPO_ROOT would point the proof
      # step at the wrong artifacts dir — the exact silent-fallback class this fix kills.
      vout="$(REPO_ROOT="$ROOT" "$ROOT/dozers/verify-merge.sh" "$id" "$workdir" 2>&1)" || vrc=$?
      if (( vrc != 0 )); then
        task_block "$id"
        task_comment "$id" "$(printf 'Dozer blocked AFTER the crew reported success — the claimed merge could NOT be verified against %s, so the issue is NOT labeled dozer:merged-develop (GSAI-119).\n\nReason: %s' "$workdir" "$vout")"
        echo "  x #$id crew succeeded but the merge did not verify — blocked: ${vout%%$'\n'*}" >&2
        return 0
      fi
      echo "    verify-merge: $vout"
      task_merged "$id"; verb="merged to develop"
      # The proof rides the merged comment — "merged to develop" without it is the
      # exact claim that could not be trusted before.
      VERIFY_PROOF="$vout"
    else
      task_merged "$id"; verb="merged to develop"
    fi
    local body
    if [[ -s "$summary_file" ]]; then body="$(head -n 10 "$summary_file")"; else body="- completed via lane:$lane"; fi
    if [[ -n "${VERIFY_PROOF:-}" ]]; then body="$(printf 'Merge verified (GSAI-119): %s\n\n%s' "$VERIFY_PROOF" "$body")"; fi
    # the handoff note rides the same comment (capped so a runaway note can't flood it)
    if [[ -s "$handoff_file" ]]; then body="$(printf '%s\n\nHandoff note from the crew:\n%s' "$body" "$(head -c 4000 "$handoff_file")")"; fi
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

# ── Slots, not waves (GSAI-37) ─────────────────────────────────────────────────
# `drain` used to launch up to FANOUT crews and then `wait` on ALL of them before it
# could touch the next task — and `loop` could not poll again until drain returned. So
# the slowest crew set the pace of the whole wave, and one that never finished stalled
# the engine outright. Observed live 2026-09-07: `inflight=1` against `fanout=5`, four
# slots idle, `poll` frozen for 45+ minutes while ~30 greenlit issues waited behind a
# single asleep test command.
#
# Now crews are SLOTS that outlive a poll. CREWS holds the pid of every running crew;
# `drain` reaps the ones that finished, fills the free slots from the ready list, and
# RETURNS — it never waits for a crew. `loop` then naps until the poll interval passes
# OR a crew finishes (`wait -n`), whichever is first, so a freed slot is refilled at
# once rather than a poll later. The invariant: idle capacity and queued greenlit work
# never coexist. A slow crew now costs exactly one slot. (The time bound that stops a
# crew hanging in the first place lives in dozers/timebox.sh.)
CREWS=()

reap_crews() {  # drop finished crews from CREWS (collect their status); keep the live ones
  local -a live=(); local pid
  for pid in "${CREWS[@]}"; do
    # bash reaps an exited background child on SIGCHLD, so `kill -0` fails the moment a
    # crew is gone; `wait` then just hands back the status bash already saved.
    if kill -0 "$pid" 2>/dev/null; then live+=("$pid"); else wait "$pid" 2>/dev/null || true; fi
  done
  CREWS=("${live[@]}")
}

drain() {  # fill the free slots from the ready list; returns immediately, never waits on a crew
  reap_crews
  # The ready list arrives in claim order (GSAI-172: the KR's target date, then backend
  # priority, then oldest first — see tasks/adapter.sh); claiming top-down orders the fleet.
  local free=$(( FANOUT - ${#CREWS[@]} )) launched=0 queued=0 seen=0 capped=0
  local id lane title prio kr team gi cap
  # GSAI-169: per-group live counts, taken ONCE at the top of the drain and then
  # incremented as this drain launches, because a crew's lock is written by the
  # backgrounded subshell and is not guaranteed to exist yet when the next row is read.
  local -a gcount gskip=(); read -r -a gcount <<<"$(group_live_counts)"
  while IFS=$'\t' read -r id lane title prio kr; do
    [[ -z "$id" ]] && continue; seen=$((seen+1))
    # Already in flight on this host (its crew holds a slot): the backend just hasn't
    # caught up. Don't burn a slot on a crew that would only say "locked, skipping".
    [[ -d "$LOCK_DIR/${id//\//_}.lock" ]] && continue
    if (( launched >= free )); then queued=$((queued+1)); continue; fi
    # The group cap: skip PAST a saturated group to the next eligible issue rather than
    # blocking on it. Logged once per group per drain — the invariant is worth a line,
    # ten identical lines are not.
    team="$(team_of "$id")"; gi="$(group_index "$team")"; cap="$(group_cap "$gi")"
    if (( ${gcount[gi]:-0} >= cap )); then
      capped=$((capped+1))
      [[ -n "${gskip[gi]:-}" ]] || { gskip[gi]=1; echo "  ~ skip: group-cap $team ${gcount[gi]:-0}/$cap"; }
      continue
    fi
    run_one "$id" "$lane" "$title" "$prio" "$kr" &
    CREWS+=("$!"); launched=$((launched+1)); gcount[gi]=$(( ${gcount[gi]:-0} + 1 ))
  done < <(task_list_ready)
  if (( seen == 0 )); then echo "  (nothing ready)"
  else
    (( capped )) && echo "  ~ $capped ready but deferred by a group cap (started $launched this poll)"
    (( queued )) && echo "  ~ $queued ready but waiting: all $FANOUT slots busy (started $launched this poll)"
  fi
  return 0
}

# Sleep for up to $1 seconds, but wake early the moment any crew finishes, so its slot
# is refilled by the next drain instead of sitting idle until the poll interval elapses.
nap() {
  local sleeper; sleep "$1" & sleeper=$!
  if (( ${#CREWS[@]} )); then wait -n "$sleeper" "${CREWS[@]}" 2>/dev/null || true
  else wait "$sleeper" 2>/dev/null || true; fi
  kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true
}

# One-shot: keep filling slots as crews finish, return once every crew is done.
drain_all() {
  drain
  while (( ${#CREWS[@]} )); do wait -n "${CREWS[@]}" 2>/dev/null || true; drain; done
}

# Crash recovery: reclaim work stranded by a Dozer that died mid-task (stale locks +
# orphaned in-flight tasks). Idempotent; runs on startup and on a cadence in `loop`.
REAPER_ENABLED="${REAPER_ENABLED:-1}"
recover() { [[ "$REAPER_ENABLED" == 1 && -x "$ROOT/dozers/reaper.sh" ]] && "$ROOT/dozers/reaper.sh" "$@" || true; }

# Health view (a witness/doctor): what's in flight, is it alive, and orphans.
doctor() {
  echo "== dozer doctor =="
  echo "-- in-flight run-locks ($LOCK_DIR) --"
  shopt -s nullglob; local any=0 foreign=() lock id pid ts st
  for lock in "$LOCK_DIR"/*.lock; do
    # No owner file => someone else's mutex (a Director's), not a crew. Report it apart
    # so `director-chief` stops showing up here as a DEAD/stale run-lock (GSAI-96).
    if [[ ! -f "$lock/owner" ]]; then foreign+=("$lock"); continue; fi
    any=1
    id="$(grep -E '^task=' "$lock/owner" 2>/dev/null | cut -d= -f2)"; [[ -z "$id" ]] && id="$(basename "$lock" .lock)"
    pid="$(grep -E '^pid=' "$lock/owner" 2>/dev/null | cut -d= -f2)"
    ts="$(grep -E '^ts=' "$lock/owner" 2>/dev/null | cut -d= -f2)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then st="ALIVE pid=$pid"; else st="DEAD/stale pid=${pid:-?}"; fi
    printf '   %-14s %-22s since %s\n' "$id" "[$st]" "${ts:-?}"
  done
  (( any )) || echo "   (none)"
  if (( ${#foreign[@]} )); then
    echo "-- other holders' locks (not ours; never reaped) --"
    for lock in "${foreign[@]}"; do
      # `|| true` is not decoration: a foreign lock is defined as "no owner file" —
      # nothing guarantees it has a `pid` file either (pre-GSAI-96 residue, the
      # director-awake mkdir/pid race window, any future foreign holder). Without the
      # guard `head` exits 1 on the missing file, pipefail propagates it, the
      # assignment fails, and `set -e` kills `doctor` mid-report on exactly the
      # legacy state you'd run it to inspect (same class as failure #1 / hevery= above).
      pid="$( { head -1 "$lock/pid" 2>/dev/null || true; } | tr -dc '0-9')"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then st="ALIVE pid=$pid"; else st="not alive pid=${pid:-?}"; fi
      printf '   %-24s %s\n' "$(basename "$lock" .lock)" "[$st]"
    done
  fi
  shopt -u nullglob
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
  once)    echo "[dozer] recovering stranded work, then draining (fanout=$FANOUT)..."; recover; drain_all ;;
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
          echo "[dozer] $(date '+%H:%M:%S') poll (running=${#CREWS[@]}/$FANOUT)"; drain
          ticks=$((ticks+1)); heartbeat "$ticks"            # stamp the new tick (the ticker keeps ts fresh between these)
          (( REAPER_EVERY > 0 && ticks % REAPER_EVERY == 0 )) && recover
          nap "$POLL_SECONDS"                               # ...or sooner, the moment a crew frees its slot
        done ;;
  *) echo "usage: dozer.sh [once|loop|recover [--dry-run]|heartbeat [tick]|doctor]" >&2; exit 1 ;;
esac
