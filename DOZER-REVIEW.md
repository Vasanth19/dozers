VERDICT: PASS

# GSAI-96 — review (re-review after the FAIL at 9cb0b49)

The branch now carries the build (`bd336a0`), the architect's design (`88c896b`
+ the post-review correction `907c3aa`), the FAIL review (`9cb0b49`), the fix
(`7051b27`), and the build-pass verification (`1ce72e5`). The fix closes the
one blocking item the FAIL demanded — nothing more, nothing else. Verified in
the tree, probed live, and re-run from this worktree.

## The FAIL's blocking item — closed

**`doctor` aborting on a pid-less foreign lock** — fixed
(`dozers/dozer.sh`, foreign-locks section):

```bash
pid="$( { head -1 "$lock/pid" 2>/dev/null || true; } | tr -dc '0-9')"
```

This is exactly the FAIL's prescribed one-liner: the `|| true` sits inside the
brace group, so `head`'s exit-1 on a missing `pid` file can't propagate through
`pipefail`, and the in-code comment names the failure class and the three ways
the state is reached (pre-GSAI-96 owner-less residue, the director-awake
mkdir→pid race window, any future foreign holder). **Reproduced both sides
live** from this worktree:

- Post-fix `doctor`, staged with `director-chief.lock` (bare `pid`) plus
  `legacy-crew.lock` (no `owner`, no `pid`): **rc=0**, both locks reported
  (`[not alive pid=12345]`, `[not alive pid=?]`), and every later section —
  heartbeat, worktrees, backend in-flight — intact.
- The unguarded form, same state, under `set -euo pipefail`: still exits 2
  with no output — the bug was real and the guard is what carries the fix,
  not an accident of the test fixtures.

**The missing test row — added and green.** `tests/reaper-test.sh` now stages
`legacy-crew.lock` (pid-less foreign residue) alongside the Director locks and
asserts three things the FAIL called for: `doctor` completes (rc=0), reports
the lock by name, and keeps reporting past it (`-- engine heartbeat` still
present) — plus a fourth pinning that the reaper leaves the residue alone.

## Test evidence — run by this review

- `tests/reaper-test.sh`: **PASS** (14/14 rows, standalone re-run) — including
  "sweep completed despite a foreign lock" (the failure-#1 regression),
  "live Director lock preserved", "foreign lock never reaped", "Director
  process left running", and all four doctor rows.
- `tests/heartbeat-test.sh`: **PASS** — including its own `doctor` rows
  (doctor must survive both beacon formats), so both suites that exercise
  `doctor` are green.
- `tests/heartbeat-check-test.sh`: **PASS** — the reader-side GSAI-76
  superset guards (`director-*` name match + owner-file check in
  `live_crews`) remain pinned.
- Full suite: not re-run by this review (≈12 min; the build pass `1ce72e5`
  ran `make test` 32/33 with the single failure a known dev-lane-migration
  flake, zero code shared with this diff). The diff's blast radius since
  that run is zero — `7051b27`/`907c3aa`/`1ce72e5` touched no runtime code
  beyond the guarded read — and every suite that touches the changed paths
  was re-run green above.

## Scope and design conformance

- `7051b27` touches only `dozers/dozer.sh` (+8, the guarded read + comment)
  and `tests/reaper-test.sh` (+14, the doctor fixture + assertions). No
  scope creep; the FAIL's "one-line fix plus a test row" exactly.
- `907c3aa` corrects DOZER-DESIGN.md's provenance note to record that the
  `doctor` hardening landed in `7051b27` *after* the review caught its
  absence — the design document now matches the commit history, which is
  what a review pass should demand of the architect pass. The correction is
  accurate against the actual commits.
- Everything the FAIL review held correct stands unchanged and re-verified:
  the reaper lane boundary (`_lock_foreign`, `foreign` verdict,
  `_reap_lock` refusing foreign locks, `_lock_pid` dual-layout read,
  `_field` non-fatal, `foreign-skipped` counter), run_one's fatal-on-failure
  `owner` write, and the `inflight_count`/`live_crews` dual guards from the
  GSAI-76 merge superset.

## Notes (non-blocking)

- The `doctor` foreign-lock read now uses `head -1 pid` + `tr -dc '0-9'`
  while the reaper's `_lock_pid` guards with `[[ -f "$lock/pid" ]]` before
  reading — two idioms for the same "absence is data" rule. Both are correct;
  if the lock layout ever changes, both need the same eye (the design's
  stated residual risk, shared with GSAI-76's name/owner duality, and pinned
  by tests on both).
- Cosmetic only: the `7051b27` commit message says "14 rows" and the build
  pass says "17 assertions" for the same reaper run — the suite prints 14 `✓`
  rows; the 17 presumably counts sub-checks. No action needed.

The reaper never touches a lock the Dozer didn't write, the health command no
longer dies on the residue that rule creates, the design document tells the
truth about how it got there, and every claim is pinned by a test that this
review ran green. Ship it.