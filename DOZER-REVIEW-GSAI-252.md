VERDICT: PASS

# DOZER-REVIEW-GSAI-252 — review of the release-cap block-time ask

Spec: an issue can reach `release_budget` through a *block* with no board-ask, so it is
unanswerable forever. Design: `DOZER-DESIGN-GSAI-252.md` (architect pass).

## Verified

- **Test suites pass.** `tests/linear-budget-ask-test.sh` 16/16; `tests/linear-release-budget-test.sh` 24/24 (run from the worktree, hermetic state dir).
- **Root cause fixed at the right place.** `block()` (`tasks/_linear_api.py`) now calls `ensure_budget_ask()` before it sets labels. At the cap it posts the `by:dozer-budget` ask first, then sets `dozer:blocked` + `board:to_review` in one relabel. Under the cap it does the same plain relabel as before.
- **Count semantics checked.** `release_state()` counts `Dozer claimed` comments. The third claim is already on the record when the third block runs, so block-time sees `count == cap` without any reordering. The reason ordering matters only for the ask body (`BLOCKED_RE` reads `Dozer blocked … Reason:`).
- **Ordering in `dozers/dozer.sh` follows the design.** The three `task_comment` + `task_block` pairs (≈L553, L621, L645) now post the reason first. Each `task_block` has `|| echo … left in-progress for the reaper`, so a refused block leaves `dozer:in-progress` for the reaper to requeue, and the next claim raises the ask.
- **Ask first, labels second** in `ensure_budget_ask()`, shared by `block()`, `budget_check()` (claim) and `budget_sweep()`. Per-issue `mkdir` lock lives under `DOZER_STATE_DIR/budget-locks`, not `~/.dozers/locks`, so the reaper's `*.lock` sweep does not treat it as a foreign lock. Good call, and the comment says why.
- **Loud failure.** `_comment_url()` dies on `commentCreate.success == false`. `block()` dies on a busy lock. `budget_sweep()` exits 1 on any read or write failure and reports each issue.
- **Real API shapes match the stubs.** `_all_issues()` returns `identifier`, `state{type}`, `labels{nodes{name}}` — the fields the sweep reads. `issue()` returns `team`, `labels`, `state` — what `_relabel` and `_settled` need.
- **Wiring.** `tasks/adapter.sh` sources `linear.sh` for the reaper; `task_budget_sweep` is defined there. `tests/run-all.sh` globs `tests/*-test.sh`, so the new test is picked up without registration (the design's "register" step is unnecessary).
- **Verb contract.** `release-count` now prints `ask=none|outstanding|MISSING` and `board=yes|no`, per §2C of the design.

## Deviations from the design (all acceptable)

1. **Throttle added.** `budget_sweep()` runs at most once per `BUDGET_SWEEP_EVERY` (default 1800s) unless `--force`. The design did not ask for this; the reaper runs every 10 polls, so the throttle keeps the Linear budget sane. `--dry-run` is never throttled.
2. **Existing test touched.** `tests/linear-release-budget-test.sh` gained `DOZER_STATE_DIR="$TMP"` on its env line. The design said "kept as-is". The change is one env var and is needed so the claim path's lock files do not land in the live `~/.dozers`. Acceptable.
3. **`board=` column** was added, as the design recommended.

## Non-blocking findings

- **Ordering in `dozer.sh` is not under test.** `crew_fail()` in the new test replicates the comment-then-block order in the test itself; it does not exercise `dozers/dozer.sh`. If someone reverts the swap, the suite stays green. Consider a source-level structure check (like `board-reconcile-test.sh` does for `commentCreate`) that asserts the `task_comment` line precedes the `task_block` line at each of the three sites.
- **The reason comment is still a silent write.** `dozer.sh` posts the reason through `comment()` (`_linear_api.py` ~L844), which ignores `commentCreate.success`. Only `_comment_url()` got the loud-failure fix. If the reason write reports `success:false`, the block proceeds and the ask goes up without its reason. The ask still lands, so this is an evidence gap, not an invisible-issue gap. Worth one line of the same check in `comment()`.
- **Throttle stamp is written before the run.** `_sweep_due` stamps first, then the sweep runs. If Linear is down and the sweep fails, the next attempt is 30 minutes away, not on the next reaper tick. Acceptable given the reaper's loud `!` line, but stamp-after-success would be the cleaner contract.
- **Stale-lock takeover has a narrow TOCTOU.** Two writers can both see a >300s-old lock, one removes it and retakes it, and the other's `rmdir` then removes the fresh lock. Requires two writers on one issue after a crash; low severity.
- **Sweep `state_type=None` leaves state as-is.** On a `relabeled` outcome a blocked issue can stay in `started` (In Progress), which the poll does not see after a re-greenlight. Pre-existing shape, and the block path already resets to `unstarted`; a nit.

## Not verified here

- The **live dry-run** over the board (the expected 11-issue set) and the **backfill** were not run. The design makes both explicit post-review steps, and the backfill is outward-facing. The acceptance criterion "zero issues at cap without an ask" is therefore not yet met in production; that is expected at this stage, not a defect of the change.
- No live Linear calls were made by this review.

## Conclusion

The change implements the design. The CFW-345 shape (block at the cap) now raises the ask, the ask carries the block reason, failed writes fail loudly, and the sweep backstops every path with an idempotent, lock-guarded invariant. The findings above are hardening items; none blocks merge.
