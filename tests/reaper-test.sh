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
# GSAI-213: an orphaned (lockless) task whose work is ALREADY DONE — a leftover merge
# receipt, or a write-failure marker naming the exact verb that failed — must have
# that one write retried, never the whole crew requeued. ORPHAN (above) is the
# regression guard that a receipt-less orphan still requeues exactly as before.
#
# Run:  bash tests/reaper-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="$ROOT/tasks/board"; mkdir -p "$BOARD"/{ready,wip,done,blocked}
ARTDIR="$ROOT/.artifacts/dev"; mkdir -p "$ARTDIR"
TMPLOCK="$(mktemp -d)"
LIVEPID=""

cleanup() {
  [[ -n "$LIVEPID" ]] && kill "$LIVEPID" 2>/dev/null || true
  rm -f "$BOARD"/wip/RTEST-*.md "$BOARD"/ready/RTEST-*.md "$BOARD"/done/RTEST-*.md "$BOARD"/blocked/RTEST-*.md 2>/dev/null || true
  rm -f "$ARTDIR"/RTEST-*.merge "$ARTDIR"/RTEST-*.linear-write-failed "$ARTDIR"/RTEST-*.legacy-proof-noted 2>/dev/null || true
  rm -rf "$TMPLOCK" "${GITREPO:-}" 2>/dev/null || true
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
# GSAI-213: an orphan whose work is ALREADY DONE — a leftover merge receipt (the
# bare case, no write-failure marker at all) must retry task_merged instead of
# requeuing the whole crew. The reaper re-proves it against git first, so the merge is
# a REAL one in a throwaway repo: a task branch --no-ff merged into develop.
GITREPO="$(mktemp -d)"
git -C "$GITREPO" init -q -b develop
gitc() { git -C "$GITREPO" -c user.email=test@test -c user.name=test "$@"; }
echo base > "$GITREPO/base.txt"; gitc add base.txt; gitc commit -q -m base
BASE_SHA="$(gitc rev-parse HEAD)"
gitc checkout -q -b dozer/RTEST-PROOF
echo feature > "$GITREPO/feature.txt"; gitc add feature.txt; gitc commit -q -m "RTEST-PROOF: feature"
TASK_SHA="$(gitc rev-parse HEAD)"
gitc checkout -q develop
gitc merge -q --no-ff -m "merge dozer/RTEST-PROOF" dozer/RTEST-PROOF
MERGE_SHA="$(gitc rev-parse HEAD)"
# A receipt in the current format: branch, merge sha, premerge sha, task sha, and the
# workdir the merge landed in (written by dev-lane/crew.sh since GSAI-213).
receipt_for() {  # <id> <merge_sha> [workdir]
  printf 'branch=develop\nmerge_sha=%s\npremerge_sha=%s\ntask_sha=%s\ndesign_only=0\n' "$2" "$BASE_SHA" "$TASK_SHA" > "$ARTDIR/$1.merge"
  [[ -n "${3:-}" ]] && printf 'workdir=%s\n' "$3" >> "$ARTDIR/$1.merge"
  return 0
}
mkfile RTEST-PROOF  "finished but unlabeled" dev
receipt_for RTEST-PROOF "$MERGE_SHA" "$GITREPO"
# A receipt with NO workdir= is a legacy receipt: it can't be re-verified, so the
# reaper must HOLD it in-progress — never requeue it, never retry it.
mkfile RTEST-LEGACY "legacy receipt" dev
receipt_for RTEST-LEGACY "$MERGE_SHA"
# A receipt whose merge sha is not in the repo fails verify-merge: the merge did not
# land, so the ordinary requeue is correct.
mkfile RTEST-VFAIL  "receipt names a merge that never landed" dev
receipt_for RTEST-VFAIL "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$GITREPO"
# GSAI-213: an orphan carrying a write-failure marker that NAMES the verb that
# failed (task_block, here — the write that failed was a block, not a merge) must
# retry exactly that verb, not default to merged.
mkfile RTEST-WFAIL  "block write failed" dev
printf 'verb=task_block\nlabel=blocked\nts=now\nrc=1\n' > "$ARTDIR/RTEST-WFAIL.linear-write-failed"
sleep 300 & LIVEPID=$!
mklock RTEST-CRASH 999999       # dead pid  -> stale
mklock RTEST-LIVE  "$LIVEPID"   # alive     -> healthy
# RTEST-ORPHAN, RTEST-PROOF, RTEST-WFAIL: no lock
mkdirectorlock rtest-live "$LIVEPID"   # a Director mid-pass  -> must survive
mkdirectorlock rtest-dead 999999       # a Director's leftover -> still not ours to reap
mkdir -p "$TMPLOCK/legacy-crew.lock"   # pid-less foreign residue -> doctor must report, not abort

# GSAI-213 step 0: the stale-off-ramp pre-step (MERGED-2 shape — dozer:in-progress
# lingering next to an off-ramp label — tests/linear-inflight-test.sh's MERGED-2
# fixture is the standing proof this shape must never be REQUEUED). The files
# backend has no notion of this Linear-only shape, so it's exercised here by
# exporting stub task_list_stale_offramp/task_finish_repair functions that a real
# Linear backend would provide — files.sh never defines those names, so the stubs
# survive `source tasks/adapter.sh` untouched. One id is behind a live lock (must be
# skipped); one is not (must be repaired).
export REPAIRED_LOG="$(mktemp)"
task_list_stale_offramp() { printf 'STALE-LIVE\tdev\tt\nSTALE-DEAD\tdev\tt\n'; }
task_finish_repair() { echo "$1" >> "$REPAIRED_LOG"; }
export -f task_list_stale_offramp task_finish_repair
mklock STALE-LIVE "$LIVEPID"   # alive -> must be left alone, not touched by finish_repair
# STALE-DEAD: no lock -> not live -> must be repaired

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
# GSAI-213: a bare merge receipt (no write-failure marker) retries task_merged — the
# work is already done, so it must land in done/, never get requeued back to ready/.
[[ -f "$BOARD/done/RTEST-PROOF.md"   ]] && ok "proof-of-completion task retried merged (done/), not requeued" \
  || no "RTEST-PROOF was not retried via its merge receipt: $(ls "$BOARD"/*/RTEST-PROOF.md 2>/dev/null || echo missing)"
[[ ! -f "$BOARD/ready/RTEST-PROOF.md" ]] && ok "proof-of-completion task was NOT requeued (crew not re-run)" \
  || no "RTEST-PROOF was requeued despite a local merge receipt — the crew will re-run on finished work"
# GSAI-213: a legacy receipt (no workdir=) cannot be verified, so it is HELD — not
# retried, and not requeued. Requeueing it is the BRD-96 failure.
[[ -f "$BOARD/wip/RTEST-LEGACY.md" && ! -f "$BOARD/ready/RTEST-LEGACY.md" && ! -f "$BOARD/done/RTEST-LEGACY.md" ]] \
  && ok "legacy receipt (no workdir=) held in-progress: not requeued, not retried" \
  || no "RTEST-LEGACY was not held in-progress: $(ls "$BOARD"/*/RTEST-LEGACY.md 2>/dev/null || echo missing)"
[[ "$OUT" == *"RTEST-LEGACY held in-progress"* ]] && ok "legacy hold is logged with its reason" \
  || no "legacy hold not logged: $OUT"
# GSAI-213: a receipt whose merge did not land fails verify-merge, so it falls through
# to the ordinary requeue.
[[ -f "$BOARD/ready/RTEST-VFAIL.md" ]] && ok "receipt that fails verify-merge was requeued (the merge never landed)" \
  || no "RTEST-VFAIL was not requeued: $(ls "$BOARD"/*/RTEST-VFAIL.md 2>/dev/null || echo missing)"
# GSAI-213: a write-failure marker naming task_block must retry THAT verb, not
# default to merged — it lands in blocked/, not done/ and not ready/.
[[ -f "$BOARD/blocked/RTEST-WFAIL.md" ]] && ok "write-failure marker's recorded verb (task_block) was retried, not merged/requeued" \
  || no "RTEST-WFAIL was not retried via its recorded verb: $(ls "$BOARD"/*/RTEST-WFAIL.md 2>/dev/null || echo missing)"
[[ ! -f "$BOARD/ready/RTEST-WFAIL.md" ]] && ok "RTEST-WFAIL was NOT requeued" \
  || no "RTEST-WFAIL was requeued despite a local write-failure marker"
[[ ! -e "$TMPLOCK/RTEST-CRASH.lock"  ]] && ok "stale lock reaped"          || no "stale lock survived"
[[ -e "$TMPLOCK/RTEST-LIVE.lock"     ]] && ok "live lock preserved"        || no "live lock wrongly reaped"
[[ -e "$TMPLOCK/director-rtest-live.lock" ]] && ok "live Director lock preserved"   || no "live Director lock reaped (GSAI-96)"
[[ -e "$TMPLOCK/director-rtest-dead.lock" ]] && ok "foreign lock never reaped"      || no "foreign lock reaped — not ours to delete"
kill -0 "$LIVEPID" 2>/dev/null && ok "Director process left running" || no "Director process was killed"

# GSAI-213 step 0 assertions: the stale-off-ramp pre-step repaired the non-live id
# and left the live one alone — it must never race a worker that still holds the id.
REPAIRED="$(cat "$REPAIRED_LOG" 2>/dev/null)"; rm -f "$REPAIRED_LOG"
grep -qx "STALE-DEAD" <<<"$REPAIRED" && ok "MERGED-2-shaped (non-live) id was finish-repaired" \
  || no "STALE-DEAD was not finish-repaired: $REPAIRED"
grep -qx "STALE-LIVE" <<<"$REPAIRED" && no "finish-repair touched a LIVE id — must never race a running worker" \
  || ok "finish-repair correctly skipped the live id"

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
