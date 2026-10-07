#!/usr/bin/env bash
# tests/dev-lane-terminal-write-test.sh — GSAI-213: the BRD-96 shape, end to end.
#
# BRD-96 (2026-09-28): the dev crew merged to develop and verify-merge passed. Then the
# terminal merged() write hit a read timeout and a 503. The issue stayed at
# dozer:in-progress; the reaper later requeued it and a finished merge was re-run.
#
# This drives the two real pieces that decide the outcome:
#   - dozers/dozer.sh `_terminal_write` (extracted verbatim from the file), which runs the
#     terminal verb and, when it still fails, records a marker instead of reporting success
#   - dozers/reaper.sh (the real script), which must find that marker, re-prove the merge
#     against git, and retry the write rather than requeue the crew
#
# The Linear verb is stubbed to fail with a 503 and then with a timeout on every attempt;
# the reaper itself runs on the files backend, where the retry lands. A real throwaway
# git repo backs the merge, so verify-merge.sh's git checks are exercised, not stubbed.
#
# What this does NOT drive: run_one itself. It is a 200-line function with the whole
# crew, lock and backend stack behind it, so this test covers the helper it calls and
# the reaper that reads what the helper wrote. The `|| return 0` in run_one is checked by
# reading it, and by the engine smoke test in the build pass.
#
#   1. a terminal write that keeps failing makes _terminal_write return NON-zero, so the
#      caller does not post "merged" — it writes a marker naming the verb, the workdir and
#      the merge sha
#   2. a terminal write that lands returns 0 and leaves no marker
#   3. the reaper, given the marker and a finished merge, RETRIES the write (the issue lands
#      in done/), does NOT requeue it, and removes the marker once the retry lands
#
# Run:  bash tests/dev-lane-terminal-write-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="$ROOT/tasks/board"; mkdir -p "$BOARD"/{ready,wip,done,blocked}
ARTDIR="$ROOT/.artifacts/dev"; mkdir -p "$ARTDIR"
TMPLOCK="$(mktemp -d)"; GITREPO="$(mktemp -d)"; TMPFN="$(mktemp)"

cleanup() {
  rm -f "$BOARD"/wip/TWRITE-*.md "$BOARD"/ready/TWRITE-*.md "$BOARD"/done/TWRITE-*.md "$BOARD"/blocked/TWRITE-*.md 2>/dev/null || true
  rm -f "$ARTDIR"/TWRITE-*.merge "$ARTDIR"/TWRITE-*.linear-write-failed 2>/dev/null || true
  rm -rf "$TMPLOCK" "$GITREPO" "$TMPFN" 2>/dev/null || true
}
trap cleanup EXIT

# Guard: don't run against a board that holds real in-flight work.
if ls "$BOARD"/wip/*.md >/dev/null 2>&1; then
  echo "SKIP: tasks/board/wip is not empty — refusing to test against live work." >&2; exit 0
fi

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# ── a real merge in a throwaway repo: dozer/TWRITE-1 --no-ff merged into develop ──────
git -C "$GITREPO" init -q -b develop
gitc() { git -C "$GITREPO" -c user.email=test@test -c user.name=test "$@"; }
echo base > "$GITREPO/base.txt"; gitc add base.txt; gitc commit -q -m base
BASE_SHA="$(gitc rev-parse HEAD)"
gitc checkout -q -b dozer/TWRITE-1
echo feature > "$GITREPO/feature.txt"; gitc add feature.txt; gitc commit -q -m "TWRITE-1: feature"
TASK_SHA="$(gitc rev-parse HEAD)"
gitc checkout -q develop
gitc merge -q --no-ff -m "merge dozer/TWRITE-1" dozer/TWRITE-1
MERGE_SHA="$(gitc rev-parse HEAD)"
# The receipt the crew writes after its green gate, in the current format (workdir= too).
printf 'branch=develop\nmerge_sha=%s\npremerge_sha=%s\ntask_sha=%s\ndesign_only=0\nworkdir=%s\n' \
  "$MERGE_SHA" "$BASE_SHA" "$TASK_SHA" "$GITREPO" > "$ARTDIR/TWRITE-1.merge"

# ── 1+2. the real _terminal_write, extracted from dozer.sh ──────────────────────────────
sed -n '/^_terminal_write() {/,/^}/p' "$ROOT/dozers/dozer.sh" > "$TMPFN"
[[ -s "$TMPFN" ]] || { echo "could not extract _terminal_write from dozers/dozer.sh" >&2; exit 1; }
# shellcheck disable=SC1090
source "$TMPFN"

# The stub Linear verb, failing the way BRD-96 failed: a 503, then a read timeout.
STUB_N=0
task_merged() {
  STUB_N=$((STUB_N+1))
  if (( STUB_N % 2 == 1 )); then echo "HTTP 503 Service Unavailable" >&2; else echo "read timed out" >&2; fi
  return 1
}

MARKER="$ARTDIR/TWRITE-1.linear-write-failed"
VOUT="ok $(git -C "$GITREPO" rev-parse --short "$MERGE_SHA") is on develop"
if _terminal_write TWRITE-1 task_merged "merged to develop" "$ARTDIR" "$VOUT" "$GITREPO" >/dev/null 2>&1; then
  no "a terminal write that keeps failing returned success — run_one would post 'merged'"
else
  ok "a terminal write that keeps failing returns non-zero, so the caller does not post 'merged'"
fi
[[ -s "$MARKER" ]] && ok "the failure left a write-failure marker" || no "no marker written for the failed write"
grep -qx 'verb=task_merged' "$MARKER" 2>/dev/null && ok "the marker names the verb that failed (task_merged)" \
  || no "marker does not name task_merged: $(cat "$MARKER" 2>/dev/null)"
grep -qx "workdir=$GITREPO" "$MARKER" 2>/dev/null && ok "the marker records the workdir the work landed in" \
  || no "marker has no workdir=: $(cat "$MARKER" 2>/dev/null)"
grep -qx "merge_sha=$MERGE_SHA" "$MARKER" 2>/dev/null && ok "the marker records the merge sha from the receipt" \
  || no "marker has no merge_sha=: $(cat "$MARKER" 2>/dev/null)"
(( STUB_N == 1 )) && ok "_terminal_write made one call; the retry budget lives in tasks/linear.sh" \
  || no "_terminal_write called the verb $STUB_N times, expected 1"

rm -f "$MARKER"
task_merged() { return 0; }
if _terminal_write TWRITE-1 task_merged "merged to develop" "$ARTDIR" "$VOUT" "$GITREPO" >/dev/null 2>&1 && [[ ! -e "$MARKER" ]]; then
  ok "a terminal write that lands returns 0 and leaves no marker"
else
  no "a successful terminal write did not return 0 cleanly, or left a marker"
fi

# ── 3. the real reaper finds the marker and retries the write, never requeues ───────────
# Put the issue where a stranded in-progress issue sits: in wip, with no live lock.
printf 'title: BRD-96 shape\nlane: dev\n' > "$BOARD/wip/TWRITE-1.md"
# The marker from the failed write (a real one, from the step above, re-created here since
# the success step removed it): the verb that failed, and the workdir + sha it landed at.
printf 'verb=task_merged\nlabel=merged to develop\nts=now\nrc=1\nworkdir=%s\nmerge_sha=%s\n--- stderr ---\nHTTP 503\n' \
  "$GITREPO" "$MERGE_SHA" > "$MARKER"

set +e
OUT="$(BACKEND=files LOCK_DIR="$TMPLOCK" bash "$ROOT/dozers/reaper.sh" 2>&1)"; RC=$?
set -e
[[ $RC == 0 ]] && ok "the reaper completed" || no "the reaper aborted (rc=$RC): $OUT"
[[ -f "$BOARD/done/TWRITE-1.md" ]] && ok "the reaper retried the merged write — the issue landed in done/" \
  || no "the issue was not retried into done/: $(ls "$BOARD"/*/TWRITE-1.md 2>/dev/null || echo missing) | $OUT"
[[ ! -f "$BOARD/ready/TWRITE-1.md" ]] && ok "the finished merge was NOT requeued (the crew did not re-run)" \
  || no "the finished merge was requeued to ready/ — the BRD-96 failure"
[[ ! -e "$MARKER" ]] && ok "the marker was removed once the retry landed" \
  || no "the marker survived a successful retry"

if (( fail == 0 )); then echo "dev-lane-terminal-write: PASS"; else echo "dev-lane-terminal-write: FAIL" >&2; exit 1; fi
