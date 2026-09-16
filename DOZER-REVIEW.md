# VERDICT: FAIL

Reviewed the develop..HEAD diff (47608f0 + design pass d37a012) against the spec
(GSAI-76) and the architect's DOZER-DESIGN.md, re-verified every load-bearing
claim, and probed the emitter's failure mode directly.

## What is right (the bulk of the fix stands)

- **The diagnosis is correct and confirmed against reality:** Director awake passes
  take `director-<role>.lock` in the shared `~/.dozers/locks`
  (`~/ecosystem/scripts/director-awake.sh:58`), holding a bare `pid` file, no
  `owner` — and the live lock dir holds exactly such a lock right now
  (`director-dev-director.lock`). Crew locks do carry a live `pid=` in `owner`
  (`dozer.sh:255`, written by `run_one`), so the pid-verified count is sound.
- **Layer 1 (emitter):** `director-*.lock` skipped by name — correct.
- **Layer 2 (reader):** `live_crews()` skips `director-*.lock` by name (not by the
  missing-`owner` accident), and the not-dispatching gate now reads the local
  pid-verified `$crews` instead of the beacon's `inflight=` — this is the real fix
  for the silencing case, and the alarm detail carries both numbers
  (`crews=N of fanout=5 (beacon reports inflight=M)`) so drift stays visible.
- **Test intent is good:** both suites pin the two directions of the lie (false
  alarm + silencing) against the real lock scan, and the stale-beacon row too.

## Why it fails — a new crash path in the heartbeat, verified by probe

`dozer.sh` runs under `set -euo pipefail` (`dozer.sh:16`). In `inflight_count()`
(`dozer.sh:64`):

```bash
pid="$(grep -E '^pid=' "$lock/owner" 2>/dev/null | head -1 | cut -d= -f2-)"
```

Under `pipefail`, a no-match `grep` (missing/owner-less lock) makes the pipeline
exit non-zero **through** the trailing `cut`, the assignment fails, and `set -e`
aborts the shell. Verified directly:

- `set -euo pipefail` + owner-less lock → **abort, exit=2** (no output);
- `set -eu` (no pipefail) → survives, `pid=""`.

So the in-code comment ("pipe through cut … instead of tripping set -e") and the
design's edge-case row ("Owner-less / legacy lock in the emitter → yields "" → no
`set -e` trip, no crash in the heartbeat path") are both **empirically false**.
The same grep pattern pre-exists in `heartbeat()`'s tick read (line 86), but this
commit owns the new line: it sits in an unconditional loop body with no guard,
on the one path ("heartbeat") that must never die.

**Blast radius (this is why it's a FAIL, not a nit):**

- `beat_start`'s ticker subshell (`dozer.sh:117-121`) inherits `set -euo pipefail`
  and discards stderr — an owner-less non-director lock kills the ticker
  **silently**, the beacon freezes while the engine runs, and the watchdog
  false-alarms `engine-stalled`. That is the exact false-alarm class this task
  exists to kill, reintroduced by its own fix.
- Worse, the main loop calls `heartbeat "$ticks"` every poll (`dozer.sh:480`) —
  the same lock kills **the engine loop itself**, violating the invariant stamped
  ten lines above: "Best-effort — a failed write must never take down the poll
  loop" (`dozer.sh:78-79`).

**The trigger is not hypothetical:** `run_one` writes `owner` with
`> … 2>/dev/null || true` (line 255), so a tolerated write failure leaves a
permanent owner-less crew lock; there is also a mkdir→write race window on every
crew start; and any future non-Director actor in the shared dir (exactly what
the Directors were) that takes a lock without an `owner` file arms it. The only
reason nothing has crashed in production: the dir currently holds no owner-less
*non-director* lock.

**Why the suites miss it:** no row creates a non-director lock without an
`owner` file. Director locks are name-skipped *before* the grep; `HBT-DEAD` has
an owner with a dead pid. Both suites were re-run by this review and **PASS**
(all rows green, both directions of the Director-lock lie pinned) — they pass
*because* the crashing case is unexercised; the coverage gap is precisely the
bug.

## Required fix (small, at the source)

Make the read genuinely non-fatal under `set -euo pipefail`, e.g.:

```bash
pid="$( { grep -E '^pid=' "$lock/owner" 2>/dev/null || true; } | head -1 | cut -d= -f2-)"
```

(or append `|| true` to the pipeline inside the substitution / read the owner
without pipefail). Then add one emitter row: a non-director lock with **no**
`owner` file → `inflight` unchanged, and the heartbeat invocation **survives**.
The reader (`heartbeat-check.sh`) is unaffected — it runs `set -uo pipefail`
without `-e` (line 64), so its identical `field()` pattern cannot abort.

## Also worth fixing in the same pass (not blocking on its own)

`heartbeat()`'s tick read (line 86) has the same pipefail-shaped pattern; give
it the same `|| true` guard while there, so the beacon path is uniformly
crash-proof rather than crash-proof-by-accident.

Everything else in the branch (exclusions, gate, alarm wording, test rows,
comments documenting the 2026-09-08 incident) is correct and can stand as-is.
With the one-line guard and the missing test row added, this should flip to
PASS on re-review.