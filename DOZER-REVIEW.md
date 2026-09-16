VERDICT: PASS

Re-review after the FAIL (c7f0541). The branch now carries the build (47608f0),
the architect's design (d37a012), that FAIL, and the fix commit (d0c8f69) —
which closes every item the FAIL demanded, and nothing else. Verified the fix
in the tree, probed the crash path directly, and re-ran the tests from this
worktree.

## Prior FAIL — closed, item by item

1. **Required fix (the `set -euo pipefail` abort in `inflight_count`)** — done
   (dozer.sh:71): `pid="$( { grep -E '^pid=' "$lock/owner" 2>/dev/null || true; } | head -1 | cut -d= -f2-)"`.
   The guard is exactly the FAIL's suggested shape, and its in-code comment
   documents *why* it is load-bearing (silent ticker death → frozen beacon →
   watchdog false-alarm — the failure class this task exists to kill).
2. **Required test row (non-director lock, no `owner`)** — added and green:
   `heartbeat-test.sh` now creates `HBT-NO-OWNER.lock`, asserts the beat
   SURVIVES and `inflight` stays 2. This was the exact coverage gap the FAIL
   identified ("they pass because the crashing case is unexercised").
3. **The companion suggestion (same guard on `heartbeat()`'s tick read,
   dozer.sh:96)** — also done, so the beacon path is uniformly crash-proof
   rather than crash-proof-by-accident, as the FAIL asked.

The fix commit touches only `dozers/dozer.sh` (+16) and `tests/heartbeat-test.sh`
(+22) — no scope creep, nothing else disturbed.

## Independent verification (not just trusting the diff)

- **Re-probed the crash path live:** under `set -euo pipefail`, the unguarded
  `grep | head | cut` on an owner-less lock still exits 2 (the FAIL's claim
  reproduces), and the guarded form survives with `pid=""` — the fix is real,
  not cosmetic.
- **Reader immunity re-confirmed:** `heartbeat-check.sh` runs `set -uo pipefail`
  without `-e` (line 64), so its identical `field()` pattern cannot abort it.
- **Both directions of the Director-lock lie stay pinned** in the tree: emitter
  (3 Director locks beside 2 crews → `inflight=2`; dead owner excluded;
  owner-less lock survives; Director-only → 0) and reader (Director locks + 0
  crews still alarms `crews=0`; Director locks pushing the beacon to `fanout`
  do NOT silence a real stall `crews=2`; a stale beacon is not excused by
  Director locks). The gate reads the local pid-verified `$crews`, and the alarm
  carries `(beacon reports inflight=N)` beside the real count for drift
  visibility — matching the design's Layer 1 / Layer 2 verbatim.
- **No collateral exposure:** of the other suites, only `dozer-fanout-test.sh`
  asserts on beacon `inflight` — with real live crews, which the pid-verified
  count still counts. `reaper-test.sh`'s dead-pid locks are the reaper's own
  fixture, untouched.

## Test evidence — run by this review

- `tests/heartbeat-test.sh`: **PASS** (20/20 rows, standalone re-run).
- `tests/heartbeat-check-test.sh`: **PASS** (46/46 rows, standalone re-run).
- `tests/run-all.sh`: **32/33 in 697s**. The single failure,
  `dev-lane-timeout-per-repo-test.sh` ("grandchild sleep survived"), is a
  kill-race flake in dev-lane timeout group-kill logic — zero code shared with
  this diff — and **passes cleanly on immediate re-run** (all rows green,
  including the one that failed). Not a branch defect; worth a flake-retry
  discussion in the repo someday, not here.

## Notes (non-blocking)

- **DOZER-DESIGN.md's mechanism sentence is now slightly stale:** it still says
  the pid is "read through `grep | head | cut` … instead of tripping `set -e`"
  (lines 44-45, and the matching edge-case row). Pre-fix, that claim was
  empirically false — which is precisely why d0c8f69 added `|| true`. The
  *behavior* the design promises (owner-less lock → `""`, no crash) now holds,
  so this is a wording drift in a frozen process document, not a defect; the
  in-code comment in dozer.sh records the true mechanism.
- The emitter's own `mklock` fixtures now use live pids (`$$`) where they
  previously used fake dead ones (111111/222222) — a correctness upgrade the
  dead-owner exclusion forced, since a fixture with a dead pid would have
  silently tested nothing under the new logic.

Everything the FAIL review held correct (exclusions, gate, alarm wording, test
rows, incident comments) stands unchanged and verified. The one blocking defect
is fixed at the source, pinned by the test row that was missing. Ship it.