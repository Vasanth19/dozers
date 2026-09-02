#!/usr/bin/env bash
# tests/reaper-test.sh — regression test for the crash-recovery reaper (files backend).
#
# Proves the three cases that matter after a Dozer dies mid-task:
#   CRASH   — claimed task whose worker PID is dead   -> requeued + stale lock reaped
#   ORPHAN  — claimed task with no lock at all         -> requeued
#   HEALTHY — claimed task whose worker PID is alive   -> LEFT ALONE (never requeued)
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

mkfile RTEST-CRASH  "crashed task"  dev
mkfile RTEST-ORPHAN "lockless task" marketing
mkfile RTEST-LIVE   "healthy task"  dev
sleep 300 & LIVEPID=$!
mklock RTEST-CRASH 999999       # dead pid  -> stale
mklock RTEST-LIVE  "$LIVEPID"   # alive     -> healthy
# RTEST-ORPHAN: no lock

BACKEND=files LOCK_DIR="$TMPLOCK" bash "$ROOT/dozers/reaper.sh" >/dev/null

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
[[ -f "$BOARD/ready/RTEST-CRASH.md"  ]] && ok "crash task requeued"        || no "crash task not requeued"
[[ -f "$BOARD/ready/RTEST-ORPHAN.md" ]] && ok "orphan task requeued"       || no "orphan task not requeued"
[[ -f "$BOARD/wip/RTEST-LIVE.md"     ]] && ok "healthy task left running"  || no "healthy task wrongly touched"
[[ ! -e "$TMPLOCK/RTEST-CRASH.lock"  ]] && ok "stale lock reaped"          || no "stale lock survived"
[[ -e "$TMPLOCK/RTEST-LIVE.lock"     ]] && ok "live lock preserved"        || no "live lock wrongly reaped"

if [[ $fail == 0 ]]; then echo "reaper-test: PASS"; else echo "reaper-test: FAIL" >&2; exit 1; fi
