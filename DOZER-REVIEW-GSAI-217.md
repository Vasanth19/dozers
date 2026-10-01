VERDICT: PASS

## Summary

The build matches DOZER-DESIGN-GSAI-217.md closely and closes both escape hatches it set out to close.

## What I checked

1. **Receipt carries the delta (crew.sh).** `PREMERGE` is captured at line 1117, before the merge runs — confirmed by reading the file, not just the diff. `TASK_TIP` is captured at the documented point (right after the green-gate, before `$WT`/`$BRANCH` are deleted on cleanup), and the receipt is extended to `branch=/merge_sha=/premerge_sha=/task_sha=/design_only=`, exactly as designed.

2. **Design-only opt-out.** Reuses the real, pre-existing `crews_get` / `crew_meta_field label` helpers — same pattern as `lite_when_label`. The inbound `DESIGN_ONLY` env var is captured into `_design_only_env` before the same-named var is reset to `0`, so the one-run override actually takes effect instead of being clobbered by its own reset line. Config documented in `org/config.yaml` under `crews: design_only_label:` as planned.

3. **verify-merge.sh hatch 1 (GSAI-211 no-op).** Rejects when `SHA == PREMERGE` with the no-op message named explicitly. Also validates `premerge_sha` is an ancestor of `merge_sha`, that `merge_sha` is a genuine 2-parent merge commit, and that `task_sha` is an ancestor of `merge_sha` — matches the design's four-part check.

4. **verify-merge.sh hatch 2 (GSAI-213 paperwork-only).** Diffs `PREMERGE..SHA` (the verified real pre-merge tip, not `$SHA^1`/`$SHA^2`, which is correct regardless of merge parent order) and blocks only when every changed file matches `DOZER-(DESIGN|REVIEW)-*.md`. The `design_only=1` opt-out bypasses it. A real `README.md`-only change is correctly left alone (narrow glob, as designed).

5. **Old-format receipts.** Missing `premerge_sha`/`task_sha` → blocked with a clear re-greenlight message, not silently passed — matches the "safe-by-default" edge case called out in the design.

6. **Backward compatibility.** Checked other consumers of the `.merge` file (`dozer.sh`, `tests/dev-lane-model-exit-test.sh`, `tests/dev-lane-no-commit-gate-test.sh`) — they only grep `merge_sha=`/pass the file through, so the three appended lines don't break them, confirming the design's "append-only, backward-compatible" claim.

7. **Tests.** Ran `tests/merge-verify-test.sh` directly — all cases pass, including the two new fixtures reconstructing the exact GSAI-211 and GSAI-213 incident shapes (case 2d, 2e), the design-only opt-out (2f), the legitimate-docs-unaffected guard (2g), and the engine-level no-op reproduction (case 3's new sub-case, `block comment names the GSAI-211 no-op reason`). Final line: `merge-verify-test: PASS`.

## Minor notes (non-blocking)

- The design's "Files to touch" list mentions updating `tests/dev-lane-greengate-test.sh` / other receipt-reading tests if they assume the 2-field format; I independently verified the two actual consumers found by grep are unaffected, so this was correctly judged unnecessary rather than skipped.
- The full `tests/run-all.sh` suite did not finish within the available window (unrelated slow tests, e.g. real crew runs); the targeted `merge-verify-test.sh` suite — the one this change actually touches — passes completely, which is sufficient evidence for this review.
