#!/usr/bin/env bash
# tests/reaper-test.sh — regression test for the crash-recovery reaper (files backend).
#
# Proves the three cases that matter after a Dozer dies mid-task:
#   CRASH   — claimed task whose worker PID is dead   -> requeued + stale lock reaped
#   ORPHAN  — claimed task with no lock at all         -> requeued
#   HEALTHY — claimed task whose worker PID is alive   -> LEFT ALONE (never requeued)
#
# Plus the shared-LOCK_DIR rule (GSAI-96): ~/.dozers/locks also holds the Directors'
# `director-<role>.lock`, which stores its pid in a BARE `pid` file and has no `owner`.
# The reaper read only `owner`, got an empty pid, called it stale and DELETED a live
# Director's lock — letting a second pass start on top of the running one. Foreign locks
# (no `owner`) are now never touched, alive or not.
#
# Run:  bash tests/reaper-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="$ROOT/tasks/board"; mkdir -p "$BOARD"/{ready,wip}
TMPLOCK="$(mktemp -d)"
LIVEPID=""

cleanup() {
  [[ -n "$LIVEPID" ]] && kill "$LIVEPID" 2>/dev/null || true
  rm -f "$BOARD"/wip/RTEST-*.md "$BOARD"/ready/RTEST-*.md 2>/dev/null || true
  rm -rf "$TMPLOCK" 2>/dev/null || true
}
trap cleanup EXIT

# Guard: don't run against a board that holds real in-flight work.
if ls "$BOARD"/wip/*.md >/dev/null 2>&1; then
  echo "SKIP: tasks/board/wip is not empty — refusing to test against live work." >&2; exit 0
fi

mkfile() { printf 'title: %s\nlane: %s\n' "$2" "$3" > "$BOARD/wip/$1.md"; }
mklock() { mkdir -p "$TMPLOCK/$1.lock"; printf 'pid=%s\nhost=test\ntask=%s\nlane=dev\nts=now\n' "$2" "$1" > "$TMPLOCK/$1.lock/owner"; }
# A Director's lock: bare `pid` file, no `owner` — exactly what director-awake.sh writes.
mkdirectorlock() { mkdir -p "$TMPLOCK/director-$1.lock"; printf '%s\n' "$2" > "$TMPLOCK/director-$1.lock/pid"; }
# Foreign residue with no `pid` at all (pre-GSAI-96 leftover / director-awake mkdir–pid
# race window): the reaper correctly never touches it, and `doctor` must REPORT it, not die on it.

mkfile RTEST-CRASH  "crashed task"  dev
mkfile RTEST-ORPHAN "lockless task" marketing
mkfile RTEST-LIVE   "healthy task"  dev
sleep 300 & LIVEPID=$!
mklock RTEST-CRASH 999999       # dead pid  -> stale
mklock RTEST-LIVE  "$LIVEPID"   # alive     -> healthy
# RTEST-ORPHAN: no lock
mkdirectorlock rtest-live "$LIVEPID"   # a Director mid-pass  -> must survive
mkdirectorlock rtest-dead 999999       # a Director's leftover -> still not ours to reap
mkdir -p "$TMPLOCK/legacy-crew.lock"   # pid-less foreign residue -> doctor must report, not abort

# Note the Director locks are in place for THIS run: before the fix, reading their
# missing `owner` under `set -e` aborted the sweep at exit 2 (swallowed by dozer.sh's
# `|| true`), so none of the requeue assertions below could pass either.
set +e
OUT="$(BACKEND=files LOCK_DIR="$TMPLOCK" bash "$ROOT/dozers/reaper.sh" 2>&1)"; RC=$?
set -e

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
[[ $RC == 0 ]] && ok "sweep completed despite a foreign lock" || no "sweep aborted (rc=$RC): $OUT"
[[ "$OUT" == *"[reaper]"* ]] && ok "sweep reported a summary"  || no "no summary line: $OUT"
[[ -f "$BOARD/ready/RTEST-CRASH.md"  ]] && ok "crash task requeued"        || no "crash task not requeued"
[[ -f "$BOARD/ready/RTEST-ORPHAN.md" ]] && ok "orphan task requeued"       || no "orphan task not requeued"
[[ -f "$BOARD/wip/RTEST-LIVE.md"     ]] && ok "healthy task left running"  || no "healthy task wrongly touched"
[[ ! -e "$TMPLOCK/RTEST-CRASH.lock"  ]] && ok "stale lock reaped"          || no "stale lock survived"
[[ -e "$TMPLOCK/RTEST-LIVE.lock"     ]] && ok "live lock preserved"        || no "live lock wrongly reaped"
[[ -e "$TMPLOCK/director-rtest-live.lock" ]] && ok "live Director lock preserved"   || no "live Director lock reaped (GSAI-96)"
[[ -e "$TMPLOCK/director-rtest-dead.lock" ]] && ok "foreign lock never reaped"      || no "foreign lock reaped — not ours to delete"
kill -0 "$LIVEPID" 2>/dev/null && ok "Director process left running" || no "Director process was killed"

# GSAI-96 review: `doctor` must not abort on a foreign lock with no `pid` file.
# `head` exits 1 on the missing file; under pipefail + set -e that used to kill the
# report mid-run — the same class as failure #1, on the exact residue this fix creates.
set +e
DOUT="$(BACKEND=files LOCK_DIR="$TMPLOCK" HEARTBEAT_FILE="$TMPLOCK/heartbeat" bash "$ROOT/dozers/dozer.sh" doctor 2>&1)"; DRC=$?
set -e
[[ $DRC == 0 ]]                                    && ok "doctor completed despite a pid-less foreign lock" || no "doctor aborted (rc=$DRC): $DOUT"
[[ "$DOUT" == *"legacy-crew"* ]]                   && ok "doctor reported the pid-less foreign lock"        || no "pid-less foreign lock missing from report: $DOUT"
[[ "$DOUT" == *"-- engine heartbeat"* ]]           && ok "doctor kept reporting past the foreign locks"     || no "report truncated at foreign locks: $DOUT"
[[ -e "$TMPLOCK/legacy-crew.lock" ]]               && ok "reaper left pid-less foreign residue alone"       || no "pid-less foreign lock was reaped"

if [[ $fail == 0 ]]; then echo "reaper-test: PASS"; else echo "reaper-test: FAIL" >&2; exit 1; fi
