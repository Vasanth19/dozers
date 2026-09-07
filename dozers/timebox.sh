#!/usr/bin/env bash
# dozers/timebox.sh — time-bound a crew command (GSAI-37). Sourced by the lane crews.
#
# A crew runs shell commands it does not control: a repo's `npm test`, a lockfile
# install, the coding/content model itself. One of those hanging is enough to stall a
# slot forever — observed live 2026-09-07: a `pnpm test:db` asleep for 8 hours at 0.26s
# CPU, and nothing to reap it (the reaper only acts on a DEAD pid; a sleeping one looks
# alive). The repo's own suite already had this discipline (`TEST_TIMEOUT` in
# tests/run-all.sh); this applies it to every command a crew runs. A hang now costs one
# cleanly-failed issue, named as a timeout, instead of a stalled engine.
#
#   timebox <secs> <label> <dir> <cmd-string>
#     Runs `( cd <dir> && eval <cmd-string> )` with stdin from /dev/null, in its OWN
#     process group, and kills that whole group (TERM, then KILL 5s later) once <secs>
#     elapse. Returns the command's exit status, or 124 on a timeout (GNU timeout's
#     convention) with TIMEBOX_HIT=1 so a caller can name the timeout in its failure
#     text. <secs>=0 means "no bound" — a deliberate, visible opt-out, never a default.
#
#   timebox_secs <name> <default>
#     Resolves the bound for one kind of command: env DOZER_TIMEOUT_<NAME> wins, else
#     `timeout_<name>:` in org/config.yaml (TIMEBOX_CONFIG), else <default>. Echoes the
#     seconds. A value that is not a whole number is a config error and FAILS (exit 1,
#     reason on stderr) — no silent fallback to the default.
#
# Why a process group and not the pid: the hung command is usually a GRANDchild (`npm
# test` → vitest → node). Killing only the subshell would orphan exactly the process
# that hung. `set -m` for the one `&` gives the job its own group; `kill -- -<pgid>`
# takes every member. Pure bash — no coreutils `timeout`, which macOS lacks by default
# and which would silently disappear from a launchd PATH.
#
# Why stdin is /dev/null: a headless model CLI waits on a piped stdin (see model.sh
# smoke), and an unattended crew has nothing to type anyway.
#
# Caveat: never call `timebox` inside `$(...)` and then read TIMEBOX_HIT — a command
# substitution is a subshell, so the flag it sets never reaches you. Redirect the
# command's output in the <cmd-string> (or on the call) and read the flag afterwards.

TIMEBOX_HIT=0
TIMEBOX_KILL_GRACE="${TIMEBOX_KILL_GRACE:-5}"   # seconds between TERM and KILL

# Kill a process TREE: the process group when it has one, AND every descendant found
# by walking `pgrep -P` from the root (deepest first). Two mechanisms on purpose: the
# group catches anything that forks between the walk and the kill; the walk works even
# where `set -m` is silently a no-op — bash gives a subshell no job control, so inside
# a pipeline or `( … ) &` the "group" is just the caller's own, and a group-only kill
# would either miss the grandchild or (worse) take the caller down with it.
_timebox_tree() {  # <pid> → echoes descendants (deepest first) then the pid itself
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do _timebox_tree "$c"; done
  echo "$p"
}
_timebox_kill() {  # <SIGNAL> <root pid>
  local sig="$1" root="$2" pids
  pids="$(_timebox_tree "$root")"
  # Only signal the group when it really is the root's own (pgid == pid) — never the
  # caller's group, which is what `-$root` would name when job control was a no-op.
  [[ "$(ps -o pgid= -p "$root" 2>/dev/null | tr -d ' ')" == "$root" ]] && kill "-$sig" -- "-$root" 2>/dev/null || true
  # shellcheck disable=SC2086  # $pids is a whitespace-separated pid list by construction
  [[ -n "$pids" ]] && kill "-$sig" $pids 2>/dev/null || true
}

timebox() {  # <secs> <label> <dir> <cmd-string>
  local secs="$1" label="$2" dir="$3" cmd="$4" pid watchdog rc mark
  TIMEBOX_HIT=0
  [[ "$secs" =~ ^[0-9]+$ ]] || { echo "    [timebox] ✗ $label: bound '$secs' is not a whole number of seconds" >&2; return 2; }
  if (( secs == 0 )); then   # explicit opt-out: run unbounded, but say so
    echo "    [timebox] ⚠ $label: no time bound (0)" >&2
    ( cd "$dir" && eval "$cmd" ) </dev/null && return 0 || return $?
  fi
  mark="$(mktemp "${TMPDIR:-/tmp}/timebox.XXXXXX")"; rm -f "$mark"
  # Both the command AND the watchdog get their own process group (set -m). The
  # watchdog's group matters too: killing only the watchdog subshell would orphan its
  # `sleep <secs>`, which then lives on for the whole bound holding whatever stdout it
  # inherited — a crew piped into anything would wait an hour for EOF.
  set -m
  ( cd "$dir" && eval "$cmd" ) </dev/null & pid=$!
  (
    # The watchdog's own sleeps run as jobs it can name, and TERM is TRAPPED to take
    # the current one down. An instant command has us TERM this subshell within
    # milliseconds of its start; bash defers the signal to a safe point, which can be
    # AFTER it has forked the sleep — a plain `sleep <secs>` then outlives its parent
    # for the whole bound (seen live as 17 orphaned `sleep 3600`s after one suite run).
    # A trap runs only between commands, i.e. once `s` names the sleep, so it is exact.
    s=""; trap '[[ -n "$s" ]] && kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$secs" & s=$!; wait "$s" 2>/dev/null || true
    kill -0 "$pid" 2>/dev/null || exit 0        # finished in time — nothing to do
    : > "$mark"
    _timebox_kill TERM "$pid"
    sleep "$TIMEBOX_KILL_GRACE" & s=$!; wait "$s" 2>/dev/null || true
    _timebox_kill KILL "$pid"
  ) </dev/null >/dev/null 2>&1 & watchdog=$!
  set +m
  # `&& rc=0 || rc=$?` (not `; rc=$?`): callers run under `set -e`, and a bare failing
  # `wait` would exit THEIR script instead of returning the status to them.
  wait "$pid" 2>/dev/null && rc=0 || rc=$?    # 2>/dev/null: hide the shell's "Terminated" job notice
  _timebox_kill TERM "$watchdog"; wait "$watchdog" 2>/dev/null || true
  kill -TERM -- "-$watchdog" 2>/dev/null || true   # belt and braces: any straggler still in its group
  if [[ -e "$mark" ]]; then
    rm -f "$mark"; TIMEBOX_HIT=1
    echo "    [timebox] ✗ $label: exceeded ${secs}s — killed its process group (exit was $rc)" >&2
    return 124
  fi
  return "$rc"
}

timebox_secs() {  # <name> <default>  → echoes the bound in seconds
  local name="$1" def="$2" env_var="DOZER_TIMEOUT_${1^^}" val src
  val="${!env_var:-}"; src="env $env_var"
  if [[ -z "$val" && -n "${TIMEBOX_CONFIG:-}" && -f "$TIMEBOX_CONFIG" ]]; then
    val="$(grep -E "^timeout_${name}:" "$TIMEBOX_CONFIG" 2>/dev/null | head -1 \
           | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true)"
    src="timeout_${name} in $TIMEBOX_CONFIG"
  fi
  [[ -z "$val" ]] && { val="$def"; src="default"; }
  [[ "$val" =~ ^[0-9]+$ ]] || { echo "    [timebox] ✗ timeout for '$name' is '$val' ($src) — must be whole seconds" >&2; return 1; }
  printf '%s' "$val"
}
