# GSAI-76 — design: heartbeat-check counts Director locks as crews — false alarms now, a silenced real stall later

**Task:** `$LOCK_DIR` (`~/.dozers/locks/`) is shared ground. Every Director awake
pass (`~/ecosystem/scripts/director-awake.sh`) takes a `director-<role>.lock`
there as its own single-pass mutex — a directory holding a bare `pid` file, no
`owner`. But the beacon emitter (`dozer.sh inflight_count()`) counted **every**
`*.lock` as in-flight work, and the watchdog's not-dispatching gate
(`heartbeat-check.sh`) gated on the beacon's `inflight=`. Together they counted a
Director pass as a claimed crew. It lied in **both** directions:

- **False alarm** (observed 2026-09-08 23:24Z): beacon said `inflight=4` while
  exactly ONE crew ran (BRD-82) — three of the "crews" were Director locks, and
  the watchdog paged on the fiction.
- **The dangerous mirror** (reproduced live while fixing): 4 real crews + 2
  Director locks → beacon `inflight=6` against `fanout=5`. The old gate
  `inflight < FANOUT` is false — a poll frozen 30 cycles with 6 greenlit issues
  queued reports **nothing**. A monitor that goes silent on a real outage is
  worse than no monitor.

**Repo:** dozers (main-only). **Files touched:** `dozers/dozer.sh`
(`inflight_count()`), `dozers/heartbeat-check.sh` (`live_crews()`, the stall gate
in `assess()`), `tests/heartbeat-test.sh`, `tests/heartbeat-check-test.sh`.

> **Provenance note:** the implementation for this task was already committed on
> this branch (`47608f0`) by the prior session before this design was written.
> This document records the design that commit embodies; review of the committed
> diff and a full test run found nothing that must change, so the code stands
> as-is.

---

## Approach — two fixes at two layers, both about who counts

**Layer 1 — the emitter stops over-reporting at the source.**
`dozer.sh inflight_count()` walks the shared lock dir but now applies two
exclusions, both with a reason:

1. `director-*.lock` → skipped by **name pattern**. Not a crew, never was.
2. A lock whose `owner` file's `pid` is **dead** (`kill -0` fails, or the lock
   carries no live pid at all) → not in-flight work. A crashed crew is the
   reaper's job; counting its corpse holds the beacon high long after the work
   stopped, which would mask the idle-capacity invariant from the other side.

The pid is read through `grep | head | cut` (never a bare `cat`) so a missing or
owner-less lock yields `""` instead of tripping `set -e`.

**Layer 2 — the reader stops trusting the beacon for the busy-slot count.**
`heartbeat-check.sh live_crews()` already counted locks by live owner pid
(`HB_ASSUME_CREWS` override retained for tests); it now also skips
`director-*.lock` by **name** — not merely by the accident that a Director lock
happens to carry no `owner` file today. The exclusion must survive a Director
lock that grows an `owner` file, because this count is what the stall gate
trusts.

The not-dispatching gate in `assess()` then compares **`$crews`** (the local,
pid-verified count) against `fanout` instead of the beacon's `inflight=`:

```
old: frozen && [ "$inflight" -lt "$FANOUT" ]        # trusted the emitter's tally
new: frozen && [ "$crews"  -lt "$FANOUT" ]          # counts the locks itself
```

The watchdog and the engine are on the same host, so the lock dir is just as
local as the beacon file — reading locks directly costs nothing extra and
removes the single point of fiction. **The beacon's `inflight=` still rides in
the alarm detail** — `crews=2 of fanout=5 (beacon reports inflight=5)` — so any
future drift between what the engine publishes and what the locks say is
visible *in the alarm itself* rather than inferred from its silence.

## Edge cases

| Case | Behavior |
|---|---|
| Director locks present, 0 real crews | `crews=0` — the not-dispatching alarm still fires (a Director pass is not a crew) |
| Director locks pushing the **beacon** to `fanout` | Gate reads `crews`, not `inflight` — a real stall still alarms; the beacon value is shown beside the real count |
| Dead-owner crew lock (crashed crew) | Excluded by both the emitter and the reader — the reaper owns it; counting it would buy the engine false silence |
| Director lock that someday grows an `owner` file | Still excluded — the skip is by **name** (`director-*.lock`), not by the missing-`owner` accident |
| Owner-less / legacy lock in the emitter | `grep\|head\|cut` yields `""` → not counted; no `set -e` trip, no crash in the heartbeat path |
| Full wave (crews == fanout, frozen poll) | Still legitimate → silent, unchanged |
| Stale beacon whose only "crews" are Director locks | `engine-stalled` still fires — Director locks don't buy silence on the staleness row either |
| `HB_ASSUME_CREWS` test override | Unchanged — still short-circuits `live_crews()` for rows that aren't about the lock scan |

## How it gets tested

Both suites were run on this branch after the fix — **PASS** (all green):

- `tests/heartbeat-test.sh` pins the **emitter**: 3 Director locks beside 2
  crews → `inflight=2`; a dead-owner lock → still 2; Director locks alone →
  `inflight=0`; plus every pre-existing row (atomic write, tick, mid-drain beat).
- `tests/heartbeat-check-test.sh` pins the **reader**, against the REAL lock
  scan (no `HB_ASSUME_CREWS`): Director locks + 0 crews still alarms (`crews=0`);
  Director locks pushing the beacon to `fanout` do **not** silence a real stall
  (`crews=2`); a stale beacon is not excused by Director locks
  (`engine-stalled` fires); and the alarm body carries
  `(beacon reports inflight=N)` beside the real count so drift stays visible.
  All pre-existing rows (alarm raise/clear/retry, Buzz hop, plist, creds)
  remain green.

## Risk

Low. Both changes narrow a count (skip Director locks, skip dead owners) — they
can only make the watchdog *more* sensitive to genuine idle capacity, never
less. The one behavior deliberately kept is silence on a **full wave**
(`crews == fanout`) with a frozen poll, which stays legitimate. The residual
risk is naming: if a future crew ever names its lock `director-*`, it would be
excluded — but crew locks are keyed by task id (e.g. `LIVE-A`), so the collision
would require a Linear issue literally named `director-*`, which the tests
would surface on the next run.