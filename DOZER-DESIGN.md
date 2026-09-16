# GSAI-96 — design: reaper deletes live Director locks — `director-*.lock` has no `owner`, so its pid reads empty

**Task:** `~/.dozers/locks/` is a shared namespace. Besides the Dozer's run-locks
it holds the Directors' `director-<role>.lock`, written by
`ecosystem/scripts/director-awake.sh` — a directory with a **bare `pid` file and no
`owner` at all**. The reaper (`dozers/reaper.sh`) read the owning pid only from
`owner`, so a Director lock read as an empty pid. Two distinct failures came out
of that, and the worse one was not the reported one:

1. **The sweep died before it started.** `_field` was
   `grep … | head -1 | cut …`; grep on a *missing* file exits 2, `pipefail`
   propagates it, and under `set -e` the assignment
   `local_id="$(_field "$lock/owner" task)"` aborted the whole script at exit 2 —
   a failure swallowed by dozer.sh's `recover() … || true`. So for as long as ANY
   Director held a lock, every reaper run was a no-op: no orphan requeue, no
   stale-lock reaping. **Crash recovery was silently off.** Reproduced: one
   `director-*.lock` in LOCK_DIR makes the pre-fix reaper exit 2 having done
   nothing.
2. **It deleted live Director locks.** Make `_field` tolerant on its own — the
   obvious one-line fix — and the sweep now reaches those locks with an empty
   pid, `_alive ""` is false, so it calls a mid-pass Director "stale" and
   `rm -rf`s its mutex. The next launchd fire then starts a second pass on top
   of the running one. Verified by test: a `_field`-only patch passes the abort
   assertions and fails the preservation ones.

**Repo:** dozers. **Files touched:** `dozers/reaper.sh`,
`dozers/dozer.sh` (run_one's `owner` write, `inflight_count`, `doctor`),
`dozers/heartbeat-check.sh` (`live_crews`), `tests/reaper-test.sh`.

> **Provenance note:** the implementation for this task was already committed on
> this branch (`bd336a0`) by the prior session before this design was written.
> This document records the design that commit embodies. A later merge from
> develop (`f325eb0`) carried GSAI-76's overlapping work on
> `inflight_count`/`live_crews`; the resolution is a **superset** of both
> designs (name-skip *and* owner-file guard) and review of the merged code plus
> a full `tests/reaper-test.sh` run (PASS) found nothing that must change.

---

## Approach — a lane boundary, not a pid-parsing tweak

The bug is not "we parsed the wrong file"; it is "we forgot the lock dir is
shared ground." Tolerating a missing `owner` would have shipped failure #2 as a
fix for failure #1. The design therefore separates **whose lock is this?** from
**is its holder alive?** and refuses the first question before answering the
second.

**In `reaper.sh`:**

- `_lock_foreign <lock>` — a lock with **no `owner` file is not ours**. Never
  killed, never removed, only reported; its holder does its own stale recovery
  (director-awake.sh already probes `kill -0` and clears). This is the load-
  bearing invariant: *every* Dozer run-lock writes `owner`, so "no owner" means
  "not a run-lock."
- `_lock_state` gains a **`foreign`** verdict beside `live|stale|none`; an
  in-flight task whose lock is foreign is left alone with a report line —
  requeueing while the lock stands would just loop (drain skips locked ids).
- `_reap_lock` refuses foreign locks outright (`return 1`), before any kill or
  `rm -rf`.
- `_lock_pid` reads the pid from **either** layout (`owner`'s `pid=` field, or
  the bare `pid` file) — purely so the *report* tells the truth about a foreign
  holder's liveness; the verdict never depends on it.
- `_field` can no longer be fatal: `… || true` so a missing file is an empty
  answer, not an abort. Absence is data.
- New `foreign-skipped=N` counter in the summary line, so foreign locks are
  visible in routine output instead of being silently ignored.

**In `dozer.sh`:**

- run_one's `owner` write is **no longer best-effort**. That file is the
  reaper's *proof* the lock is ours; a failed write now releases the lock and
  skips the task (`return 1`) instead of creating a run-lock that is invisible
  to the reaper and unreapable. This is what makes "no owner ⇒ not ours" safe
  to rely on — there is no mid-race window where one of OUR locks lacks
  `owner`.
- `inflight_count` counts run-locks only (skip `director-*.lock` by name, skip
  owner-less locks, skip dead owners) — Director locks were inflating the
  beacon by up to 4.
- `doctor` lists other holders' locks in their own section rather than as
  DEAD/stale run-locks — and no longer aborts on them for the same `set -e`
  reason as failure #1.

**In `heartbeat-check.sh`:** `live_crews` skips owner-less locks explicitly —
same behavior, now intentional rather than incidental. (Post-GSAI-76 merge it
also skips `director-*.lock` by name; the two guards are deliberate defense in
depth, see Edge cases.)

## Edge cases

| Case | Behavior |
|---|---|
| Live Director mid-pass (`director-*.lock`, pid alive) | `foreign` — never killed, never reaped, reported; holder process untouched |
| Leftover Director lock (holder pid dead) | Still `foreign` — still not ours to reap; the Directors' own awake script clears it |
| In-flight Linear task whose lock is foreign | Reported, **not** requeued — requeueing under a standing lock loops (drain skips locked ids) |
| One of OUR locks whose `owner` write just failed | run_one releases the lock and skips the task — no owner-less run-lock can exist, so the foreign rule never strands our own work |
| Runaway own worker (alive but over `REAPER_MAX_AGE`) | Unchanged: killed then lock reaped — the watchdog path only ever touches locks WITH an `owner` |
| `director-*.lock` that someday grows an `owner` file | Excluded from crew counts by **name** (GSAI-76's guard), and would be treated as ours by the reaper — but crew locks are keyed by task id (e.g. `LIVE-A`), so a real collision requires a Linear issue literally named `director-*` |
| A future non-Director foreign holder in LOCK_DIR | Same rules apply — the boundary is "has no `owner`," not a hardcoded Directors list |
| `set -e` / `pipefail` on any missing-file read | Every field read is non-fatal; absence reads as empty, never as an abort |

## How it gets tested

`tests/reaper-test.sh` stages Director locks (live + dead-pid leftover) beside
the normal crew fixtures for the **whole run**, so every pre-existing
requeue/reap assertion doubles as the failure-#1 regression (the sweep must
reach its verdicts with foreign locks present). It asserts: rc=0 and a summary
line (the pre-fix script exits 2 with no output), both foreign locks preserved,
and the Director holder process still running. Run on this branch after the
GSAI-76 merge: **PASS** — including "live Director lock preserved",
"foreign lock never reaped", "Director process left running".

Related suites that pin the same boundary elsewhere:
`tests/heartbeat-test.sh` and `tests/heartbeat-check-test.sh` (GSAI-76) pin
`inflight_count`/`live_crews` against Director locks; `make test` at commit
time was 19/21 with the two failures pre-existing and unrelated (fanout timing
assertion; ecosystem-workdir registry drift).

## Risk

Low, and asymmetrically safe: every change either *narrows* who the reaper may
touch (foreign locks become untouchable) or makes a read non-fatal (absence is
an answer, not an abort). The one new hard edge — run_one failing a task when
the `owner` write fails — is strictly better than the alternative it replaces
(a lock the reaper can neither see nor reap), and it surfaces loudly ("could
not write $lock/owner") instead of silently. The residual risk is the name/
owner duality shared with GSAI-76: both guards must stay in sync if the lock
layout ever changes, and both test suites pin exactly that.