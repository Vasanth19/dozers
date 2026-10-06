VERDICT: PASS

# Review — GSAI-251: commit backstop for the build pass

## What I checked

- Spec (#GSAI-251) and `DOZER-DESIGN-GSAI-251.md` against the diff of `dozers/dev-lane/crew.sh` and `tests/dev-lane-no-commit-gate-test.sh`.
- Ran `bash tests/dev-lane-no-commit-gate-test.sh` on this branch: `dev-lane-no-commit-gate-test: PASS`. All 5 new GSAI-251 cases pass (UNCOMMITTED-BUILD, COMMIT-OR-FAIL, LEGACY-UNCOMMITTED, CRASH-RESCUE, REFINERY-GUARD), along with the earlier cases.
- Read the call sites directly:
  - The `changes:*` proof is used only by the build pass (`crew.sh:1071`). The architect and review passes use `file:` proofs, so the backstop on that path cannot sweep in their output.
  - The timeout check (`TIMEBOX_HIT`, ~L738) runs before the proof `case`, so a timed-out build is not rescued, as the design says.
  - `wt_unsaved` is fail-closed (a failing `git status` returns "unsaved"), so `build_backstop`'s `wt_unsaved || return 0` cannot silently skip a dirty tree.
- Not re-run in this pass: the other dev-lane suites and a pre-fix comparison. The earlier review file claims both; I did not verify them, so this verdict rests on the no-commit gate suite and the code reading above.

## The implementation follows the design

- **(B) Committed-only scoring.** `branch_has_output` diffs `$2 HEAD` against `ARTIFACT_PATHSPEC`. The legacy root names stay excluded. `ARTIFACT_PATHSPEC` is defined after `DESIGN_FILE`/`REVIEW_FILE` (L92–93) and feeds `DEP_PATHSPEC`, so one list serves both, as design edge case 3 requires.
- **(A) Build backstop.** `build_backstop` runs in `build_once` after `run_model_pass build` and before `install_deps`/`run_tests`, so the tests judge the tree that merges. It also runs on the `changes:*` proof before `branch_has_output`. It is a no-op on a clean tree and logs the spec's exact line.
- **(C) Refinery guard.** `build_backstop` runs after the merge worktree is prepared and before `PREMERGE` and the merge. A failed commit fails closed with git's message. The rebase fallback runs after it, so it gets a clean tree too.
- **Helper change.** `wip_snapshot` keeps `git add`/`git commit` stderr and names the failing step. What gets committed is unchanged.
- **Edge cases.** Excluded paths (`.env*`, `node_modules`, pass artifacts) are not committed (tested). Legacy-named files are neither snapshotted nor counted (tested). A crashed build is rescued by committing first (tested). A timed-out build is not rescued (as designed).

## Deviations from the design (not blocking)

1. The design asked for the refinery-guard case in `tests/dev-lane-dirty-resume-test.sh`. It lives in `dev-lane-no-commit-gate-test.sh` as REFINERY-GUARD instead. Coverage exists; the placement differs.
2. The design's direct unit check ("`branch_has_output` returns false for an uncommitted-only tree") is not a standalone assertion. UNCOMMITTED-BUILD and LEGACY-UNCOMMITTED cover it through the gate.
3. The refinery guard reuses the log text "build pass left N uncommitted files". When it fires after review, the wording is slightly off. The signal is still right.

## Follow-up concern (not a blocker)

- The refinery guard commits anything dirty at merge time, after tests and review have run, so such a file ships untested and unreviewed. The design accepts this as defence in depth. Today the only way to reach that state is a stray write during review, which should be rare. If it becomes common, fail closed at the refinery instead of committing.

## Verdict

The spec's requirements are met. Uncommitted build output is committed before any gate reads it, gates score committed history only, and the merge refuses to ship with uncommitted output rather than shipping paperwork alone. The no-commit gate suite passes on this branch, and the code reading confirms the call-site scoping above. The deviations are test placement and log wording, not correctness defects.
