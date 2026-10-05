# DOZER-DESIGN GSAI-251 — commit backstop for the build pass

## Problem (confirmed in `dozers/dev-lane/crew.sh`)

The build pass can write real source, leave it uncommitted, and still reach the merge.
Three facts make that happen:

1. `branch_has_output()` (L538) diffs the **working tree** against the pinned base
   (`git diff --quiet "$2" -- .`). Uncommitted code therefore counts as build output.
2. The architect (~L1004) and review (~L1087) passes each `git add` + `commit` their
   artifact. The **build pass has no equivalent** — nothing commits its output.
3. `wt_unsaved()` / `wip_snapshot()` (L557, L567) run only at resume start (~L824). Nothing
   runs between the build and the refinery merge (~L1150), so the merge takes committed
   history only: the paperwork.

Result: the gates (`branch_has_output`, tests, review) all score the dirty tree as the
deliverable, then the merge ships `DOZER-DESIGN/REVIEW` commits and nothing else. The
green-gate correctly refuses it, but only after a full crew pass has been spent.

## Approach

Three changes in `crew.sh`, plus the one existing helper they reuse.

### A. Commit the build's output as a backstop, before anything reads it

Add `build_backstop()` and call it from `build_once()` immediately after
`run_model_pass build …` returns. It runs `wt_unsaved "$WT"`; when dirty it calls
`wip_snapshot "$WT" "$ID"` and logs:

    build pass left N uncommitted files; committed as wip(<ID>) before merge

Placing it **before** `install_deps` and `run_tests` is deliberate. The tests then run
on the exact committed tree that will merge, rather than on a working tree that differs
from it by one `git add`.

The same helper must also run on the non-zero-exit proof path inside `run_model_pass`
(the `changes:*` branch, ~L771). Otherwise a build that crashes after writing code, but
before committing, would fail on proof, costing a crew pass again. That is the exact
waste this issue is about.

### B. `branch_has_output()` scores committed output only

Change the comparison from the working tree to the branch tip:

    git -C "$1" diff --quiet "$2" HEAD -- . <same excludes>

Uncommitted changes are no longer "output". The dirty-tree question moves to its own
explicit check (`wt_unsaved`), which is already fail-closed. The two conditions are
then reported separately, as the spec asks.

Because the backstop (A) runs first, a legitimately written build is already committed
by the time `branch_has_output` judges it. Existing callers keep their meaning:
the no-commit gate in `build_once` (~L1048), and the `changes:` proof.

### C. Fail closed in the refinery, before the merge

Immediately before `git -C "$MW" merge --no-ff "$BRANCH"` (~L1150, after the merge lock
and before `PREMERGE`), add a dirty-tree check:

- `wt_unsaved "$WT"` true → `wip_snapshot "$WT" "$ID"`, same log line as (A). This is
  defence in depth for any path that reaches the merge without passing through
  `build_once` (for example the review-FAIL → rebuild loop exiting, or `lite` profile
  with review skipped).
- snapshot fails → `fail` with a named reason ("worktree … holds uncommitted changes
  that could not be snapshotted — …"). Never merge past it.

The refinery's `git -C "$WT" rebase` fallback also needs a clean tree; this check covers
that too.

### Helper change: surface why a snapshot failed

`wip_snapshot()` currently sends `git add` and `git commit` output to `/dev/null`, so a
pre-commit hook rejection or a missing git identity becomes an unexplained "could not
be snapshotted". Keep stderr on the failure path (write it to the same log the crew
already uses, or echo the trimmed message) so the named reason in (C) is actionable.
This does not change what gets committed.

## Files to touch

| File | Change |
|---|---|
| `dozers/dev-lane/crew.sh` | `branch_has_output` (B); new `build_backstop` called from `build_once` (A) and `run_model_pass` changes-proof (A); refinery pre-merge guard (C); `wip_snapshot` stderr on failure |
| `tests/dev-lane-no-commit-gate-test.sh` | extend: build writes an uncommitted source file → assert it is committed as `wip(...)` and the merge contains it, not only paperwork |
| `tests/dev-lane-dirty-resume-test.sh` | extend: the refinery pre-merge guard fires when the tree is dirty at merge time |

No other files. No change to `org/config.yaml`, no new label, no new state file.
GSAI-246 (where `DOZER-*.md` is written) is a different region and stays out of this change
(the spec says to sequence them, not bundle them).

## Edge cases

1. **Build writes nothing.** `wt_unsaved` is false; backstop is a no-op; the no-commit gate
   fails exactly as today ("build agent produced no commits").
2. **Only excluded paths dirty** (`node_modules`, `.env*`, the pass artifacts). Excluded by
   `DEP_PATHSPEC` both in `wt_unsaved` and in `wip_snapshot`'s `git add`. Nothing is committed.
   Secrets never enter a wip commit.
3. **Legacy names `DOZER-DESIGN.md` / `DOZER-REVIEW.md`.** `branch_has_output` excludes them
   (GSAI-148), but `DEP_PATHSPEC` does not. A stray legacy file would be snapshotted as
   "output". Fix: build one shared exclusion list and use it in both places. Required for (A)
   to be correct.
4. **Build crashes or times out after writing code, before committing.** The proof path
   (A, second site) snapshots first, then `branch_has_output` judges the committed tree, so
   the work is rescued rather than discarded. A timeout keeps today's behaviour: `timebox`
   sets `TIMEBOX_HIT` and the run is not rescued.
5. **Mid-rebase or mid-merge in the worktree.** `wip_snapshot` already refuses and returns 1.
   The guard fails closed with "a rebase or merge is already in progress". The Director
   decides; the crew does not finish or abort it.
6. **Pre-commit hook or missing git identity.** The commit fails, `wip_snapshot` returns 1,
   and the guard fails with the real git message (helper change above). No silent skip.
7. **Junk-only dirt** (e.g. a build leaves a log file). It is committed and passes
   `branch_has_output`, but tests and the green-gate still run on it. This matches how a
   committed junk file is treated today. Noted, not solved here: the spec asks for
   commit-or-fail, not content judgment.
8. **Review FAIL → rebuild.** `build_once` runs again, so the backstop runs again. Its
   commit lands on top of the first attempt's output, and the review sees committed code.
9. **Resume path.** Unchanged. The existing start-of-run `wt_unsaved` + `wip_snapshot`
   still runs first. (A) and (C) only add a second, later use of the same helper.
10. **Log line.** The exact text from the spec is printed on every commit made by the
    backstop, so this never happens silently again.

## How it gets tested

Use the existing harness in `tests/` (`run-all.sh`, `make test`). Extend the two files that
already cover no-commit gating and dirty resume. Do not add a new harness.

- **Regression (reproduces the bug before the fix):** fake `MODEL_CMD` for the build
  writes `src/feature.ts` and does not commit. Assert that after the crew:
  - `git log` on the merged integration branch includes `feature.ts`, and
  - the log contains "build pass left 1 uncommitted files; committed as wip(…)".
  Before the fix this run merges with only `DOZER-*.md`, so the assertion fails. That
  failure is the proof the test is testing the right thing.
- **Commit-or-fail:** force `wip_snapshot` to fail (pre-commit hook that exits 1). Assert
  the crew fails with a named reason, the merge does not happen, and the worktree is kept.
- **Excluded paths are not committed:** build leaves `.env.production` and `node_modules`
  dirty. Assert neither is in any commit.
- **Legacy names:** build leaves a `DOZER-DESIGN.md` at root. Assert it is not counted as
  output, and that a paperwork-only branch still fails the no-commit gate.
- **Proof path rescue:** build writes code and exits non-zero without committing. Assert the
  work is committed and `run_model_pass` continues, rather than failing.
- **Scoring is committed-only:** a unit-level check that `branch_has_output` returns false
  for an uncommitted-only tree (the bug's exact fingerprint).
- Run `make test` for the full regression suite. Red is not done.

## Risk and sequencing

- Behaviour change: `branch_has_output` no longer counts uncommitted work. Only the
  `changes:` proof path and the no-commit gate call it, and (A) commits first, so
  well-formed builds are unaffected.
- Known gap that stays open: the bug also exists on the lite profile. Covered by (C)
  because the guard sits on the merge path, not inside `build_once`.
- Sequence after GSAI-246 per the issue. Both edit `crew.sh`; keep the diffs separate.
