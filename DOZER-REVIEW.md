VERDICT: FAIL

# GSAI-96 — review

One blocking defect, in `dozer.sh doctor`'s new foreign-locks section. The core
of the task — the reaper — is correct, well-tested, and matches the design; the
merge superset with GSAI-76 (`inflight_count` / `live_crews`) is also correct.
But the diff reintroduces, in a path it touches, the exact failure class this
task exists to kill, and contradicts two explicit claims in DOZER-DESIGN.md.

## Blocking: `doctor` aborts mid-report on a foreign lock with no `pid` file

`dozers/dozer.sh:474`:

```bash
pid="$(head -1 "$lock/pid" 2>/dev/null | tr -dc '0-9')"
```

`dozer.sh` runs under `set -euo pipefail`. A foreign lock is defined as "no
`owner` file" — nothing guarantees it has a `pid` file. When it doesn't,
`head` exits 1, `pipefail` propagates it through `tr` (exit 0), the assignment
fails, and `set -e` kills `doctor` mid-report.

**Reproduced on this branch** (temp LOCK_DIR with `director-chief.lock` carrying
a pid, plus `legacy-crew.lock` — no `owner`, no `pid`):

```
-- other holders' locks (not ours; never reaped) --
   director-chief           [not alive pid=12345]
doctor RC=1          <- legacy-crew never printed; heartbeat, worktrees,
                        and backend-in-flight sections all lost
```

This is precisely the `_field`-aborts-the-sweep bug the design documents as
failure #1 — missing-file read under `pipefail` → failed assignment → `set -e`
abort — and the same function already condemns this class three lines below
(`hevery=` comment: "the health command dying on the exact legacy state you'd
run it to inspect").

The state is not hypothetical; three ways to reach it:

1. **Pre-GSAI-96 residue** — an owner-less run-lock from the old best-effort
   `owner` write (`> "$lock/owner" 2>/dev/null || true`) has no `pid` file
   either. This diff's own reaper now classifies that residue as `foreign` and
   (correctly, per the design) never reaps it — so it can sit in LOCK_DIR
   indefinitely, and `doctor` dies on it every time it's run.
2. **director-awake.sh race window** — `mkdir "$LOCK"` (line 103) succeeds
   before `echo "$$" > "$LOCK/pid"` (line 111); a `doctor` run in that window
   aborts.
3. **Any future foreign holder** without a `pid` file — the design's own
   edge-case row ("A future non-Director foreign holder in LOCK_DIR — same
   rules apply — the boundary is 'has no owner'").

It contradicts the design twice:

- Edge-case table: "set -e / pipefail on any missing-file read — **Every field
  read is non-fatal; absence reads as empty, never as an abort.**" This one is
  fatal.
- Approach section: "`doctor` … no longer aborts on them for the same `set -e`
  reason as failure #1." It does — for exactly the foreign locks most likely to
  be the residue of the bug being fixed.

Note the reaper already solved this correctly: `_lock_pid`
(`dozers/reaper.sh:72`) guards with `[[ -f "$lock/pid" ]]` before reading. The
fix is one line — e.g.
`pid="$( { head -1 "$lock/pid" 2>/dev/null || true; } | tr -dc '0-9')"` —
plus ideally a `doctor` test row with a pid-less foreign lock (the current
`reaper-test.sh` only stages Director locks that carry a pid, which is why the
suites stay green despite the bug).

## What is sound — verified, no changes needed

- **reaper.sh** — `_field` non-fatal (`|| true`), `_lock_foreign` boundary,
  `_lock_pid` dual-layout read, `_reap_lock` refusing foreign locks before any
  kill/`rm -rf`, the `foreign` verdict in `_lock_state` (in-flight tasks left
  alone, not requeued — requeue under a standing lock would loop, matching the
  design), and the `foreign-skipped=N` counter. All match the design.
- **run_one's owner write is now fatal-on-failure** — lock released via the
  EXIT trap, task stays `ready` and is retried next poll; loud message. This is
  what makes the "no owner ⇒ not ours" invariant safe, as designed.
- **inflight_count / live_crews dual guards** (name match + owner-file check)
  — the GSAI-76 merge superset, defense in depth, as designed.
- **Test results on this branch:** `tests/reaper-test.sh` PASS (all 10 rows,
  including live-Director-lock preservation and the Director process left
  running), `tests/heartbeat-test.sh` PASS, `tests/heartbeat-check-test.sh`
  PASS. Director lock layout claim verified against
  `~/ecosystem/scripts/director-awake.sh` (bare `pid`, no `owner`).
- One accepted tradeoff, fine as designed: pre-GSAI-96 owner-less residue is
  now permanently `foreign` and never reaped — but it is *reported* every
  sweep (`foreign-skipped` / "left alone" lines), so it's visible, not silent.

## Verdict

The reaper fix is the task and it is done right. But this branch ships a new
instance of the bug class the task was cut to eliminate, in the health
command, on states this bug's own residue creates — and the design explicitly
claims that's fixed. One-line fix plus a test row; then this is a PASS.