VERDICT: PASS

# Review — GSAI-251: commit backstop for the build pass

## What was checked

- Spec (issue #GSAI-251) and the architect plan `DOZER-DESIGN-GSAI-251.md` against the diff of `dozers/dev-lane/crew.sh`, `tests/dev-lane-no-commit-gate-test.sh`.
- `bash tests/dev-lane-no-commit-gate-test.sh` on this branch: PASS (all cases green, including the 5 new GSAI-251 cases).
- The same test against the pre-fix `crew.sh` (`develop`) in a temp copy: the UNCOMMITTED-BUILD, COMMIT-OR-FAIL, CRASH-RESCUE and REFINERY-GUARD cases FAIL. The bug reproduces as the issue describes ("merge ships paperwork only"), so the new tests test the right thing.
- Related dev-lane suites on this branch, all PASS: `dev-lane-dirty-resume`, `dev-lane-artifact-collision`, `dev-lane-gate-failclosed`, `dev-lane-model-exit`, `dev-lane-test-gate`, `dev-lane-stale-base`, `dev-lane-timeout`.

## The implementation follows the design

- **(B) Committed-only scoring.** `branch_has_output` now diffs `$2 HEAD` against `ARTIFACT_PATHSPEC`, not the working tree. The legacy root names stay excluded, and `ARTIFACT_PATHSPEC` is one shared list that also feeds `DEP_PATHSPEC`, as the design's edge case 3 requires.
- **(A) Build backstop.** `build_backstop` is called in `build_once` after `run_model_pass build` and before `install_deps`/`run_tests`, so the tests judge the tree that merges. It is also called on the `changes:*` proof path before `branch_has_output`. It is a no-op when `wt_unsaved` is false, and it logs the spec's exact line.
- **(C) Refinery guard.** `build_backstop` runs before `PREMERGE` and the merge. A failed commit fails closed with the git message. The guard covers the rebase fallback as well.
- **Helper change.** `wip_snapshot` keeps `git add` and `git commit` stderr and names the failing step, so the COMMIT-OR-FAIL reason is actionable. What gets committed is unchanged.
- **Edge cases.** Excluded paths (`.env*`, `node_modules`, pass artifacts) are not committed (tested). Legacy names are not counted or snapshotted (tested). A crashed build is rescued by committing first (tested). The timeout path is not rescued, as the design says; `timebox` still sets `TIMEBOX_HIT`.
- **Real review and architect passes** still commit only their own artifacts (`git -C "$WT" add "$REVIEW_FILE"`, `add "$DESIGN_FILE"`), so the test stub change is faithful to production.

## Deviations from the design (not blocking)

1. The design's file table asked for `tests/dev-lane-dirty-resume-test.sh` to be extended with the refinery pre-merge guard case. It was not. The same case lives as REFINERY-GUARD in `dev-lane-no-commit-gate-test.sh` instead. Coverage exists; the placement differs from the plan.
2. The design's "Scoring is committed-only" unit-level check (`branch_has_output` returns false for an uncommitted-only tree) is not present as a direct test. It is covered indirectly by UNCOMMITTED-BUILD and LEGACY-UNCOMMITTED, which go through the gate. A direct unit assertion would be cheap to add later.
3. The refinery guard reuses the log text "build pass left N uncommitted files". When it fires after review it is not the build pass, so the log wording is slightly misleading. The line is still the right signal.

## Concern for follow-up (not a blocker)

- The refinery guard commits anything dirty at merge time, which is after the tests and the review have run. Any such file ships without being tested or reviewed. The design accepts this as defence in depth, and the spec's commit-or-fail reading supports it. Today the only path to that state is an agent writing stray files during review, which is rare. If it ever becomes common, consider failing closed at the refinery instead of committing.

## Verdict

The spec's three requirements are met: uncommitted build output is committed before any gate reads it, gates score committed history only, and the merge fails closed rather than shipping paperwork. The new tests reproduce the bug on the pre-fix code and pass on this branch, and the related suites are green. The deviations above are test-placement and log-wording issues, not correctness defects.
