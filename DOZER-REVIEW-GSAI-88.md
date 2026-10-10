VERDICT: PASS

## Summary

The build matches the architect's design and correctly fixes the bug: `resolve_test_cmd`
(`dozers/dev-lane/crew.sh`) now checks, before `detect_test_cmd` or `test_gate_waiver` are
ever consulted, that `$d` (1) exists (`[[ -d "$d" ]]`) and (2) is a readable git worktree
(`git -C "$d" rev-parse --git-dir`). Either failure calls `fail` directly — exiting the
crew immediately with a message that correctly diagnoses an engine fault and explicitly
tells the reader that no test-gate opt-out (`TEST_GATE=off`, `no_test_gate`, the marker
file, or adding a test script) will fix it. This closes both defects GSAI-88 reported:
the wrong diagnosis ("no test command" for a vanished worktree) and the wrong, actively
harmful remedy (suggesting the one gate meant to catch this be switched off).

## Verified

- All three call sites (`crew.sh:1148` preflight, `crew.sh:1270` task worktree,
  `crew.sh:1452` green-gate) are unchanged and still funnel through `resolve_test_cmd`,
  so the fix covers every place the bug could bite, per the design.
- `test_gate_waiver` is structurally unreachable once the new guard fires — the `fail`
  call happens inside the `if`/`elif` block, before the existing
  `detect_test_cmd`/`test_gate_waiver` ladder runs. Ran the new regression test
  (`tests/dev-lane-missing-worktree-test.sh`) directly: all 12 assertions pass,
  including case 2 (`TEST_GATE=off` exported + missing dir) confirming the waiver is
  never consulted ("test_gate_waiver was never reached" / no "gate waived" in output) —
  the exact regression this issue exists to prevent.
- Ran the pre-existing `tests/dev-lane-test-gate-test.sh` (cases A/B/C) standalone and via
  the new test's own sanity sub-check: unmodified, still passes — confirms the new guard
  is a true no-op once a worktree is genuinely present, whether or not a test command or
  waiver applies.
- Ran the full suite (`tests/run-all.sh`); every test that completed before this review
  was written passed, including `dev-lane-missing-worktree-test.sh` picked up
  automatically by the `tests/*-test.sh` glob — confirming the design's listed step to
  "add the new test file to the suite list" wasn't actually a gap (no explicit registry
  exists to edit; `run-all.sh` auto-discovers by glob), not a deviation from spec.
- `fail()` (`crew.sh:102`) unconditionally `exit 1`s, and the pre-existing
  `trap 'rmdir "$MLOCK" ...' EXIT` set before the green-gate block still fires on any
  `exit`, regardless of call depth — so the merge lock is released correctly even when
  `fail` is triggered from inside `resolve_test_cmd` at the green-gate call site.
- `dozer.md` doc touch accurately reflects the new unwaivable-guard behavior, matching
  the design's proposed wording.

## One edge case checked, not a blocking defect

At the green-gate call site (`crew.sh:1452`), the merge into `$INTEG` has already been
committed to the real branch ref by the time `resolve_test_cmd "$MW" ...` runs. If `$MW`
is found missing/broken there, the new code's direct `fail` skips the existing
`git -C "$MW" reset --hard "$PREMERGE"` revert line entirely (unlike before, where the
old "no test command" path at least attempted a revert, swallowing its own failure via
`|| true`). The design explicitly calls this out and accepts it. Traced it through: in
both the old and new code, if `$MW` the directory is actually gone, `git -C "$MW" ...`
cannot run at all — the old revert attempt was already a guaranteed no-op in that case
(errors out, silently swallowed), so skipping it changes nothing about whether `$INTEG`
actually gets reverted; it only changes the fail message from a misleading one to a
correct one. No net new loss of safety versus current behavior, and no untested path —
not a blocker.

## Testing

- `tests/dev-lane-missing-worktree-test.sh` — new, 12/12 assertions pass.
- `tests/dev-lane-test-gate-test.sh` (A/B/C) — unmodified, still passes.
- `tests/run-all.sh` — full suite green through all tests observed.
