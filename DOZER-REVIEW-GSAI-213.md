VERDICT: PASS

# Review — GSAI-213: finished issue stranded at dozer:in-progress when the Linear write fails

Reviewed `dozer/GSAI-213` (develop..HEAD) against the spec and `DOZER-DESIGN-GSAI-213.md`.

## What I ran

All under the worktree, nothing edited except this file:

- `tests/linear-write-verify-test.sh` — 6/6 pass
- `tests/linear-terminal-retry-test.sh` — all pass (PASS)
- `tests/linear-finish-repair-test.sh` — 10/10 pass
- `tests/dev-lane-terminal-write-test.sh` — all pass (PASS)
- `tests/dozer-lock-counts-unbound-test.sh` — all pass (PASS); defect not reproduced
- `tests/reaper-test.sh` — all pass (PASS)
- `tests/linear-inflight-test.sh` — 9/9 pass
- `bash -n` on `dozer.sh`, `reaper.sh`, `dev-lane/crew.sh`, `linear.sh`; `py_compile` on `_linear_api.py` — clean

## Against the spec

1. **Quiet Linear rejection is no longer success.** `set_labels_and_state()` now checks `issueUpdate.success` and `die()`s on false. `gql()` returns `r["data"]`, so the check reads the right object. Every `_relabel` caller goes through it.
2. **Terminal writes retry, bounded.** `_linear_write_retry` makes 3 attempts with 5 s backoff, read from `org/config.yaml`. It covers merged, review and block only. Claim and requeue are not wrapped, as designed. `block()` is idempotent through `ensure_budget_ask`, so a retry after a write that actually landed is safe.
3. **A failed terminal write is recorded, not silently dropped.** `_terminal_write` in `dozer.sh` returns non-zero, writes `$art/$id.linear-write-failed` (verb, workdir, merge_sha, stderr), and logs to stderr. All six bare terminal calls in `run_one` now go through it with `|| return 0` or `|| echo`. The `set -e` concern is handled: the `&& … ; rc=$?` form is correct.
4. **The reaper proves before it requeues.** `_prove_terminal_write` reads the marker or the `.merge` receipt. For a merge it re-runs `verify-merge.sh` against git. Only a proven merge is retried. A failed proof, or no proof, falls through to the existing requeue. Only `reaper.sh` requeues: I grepped `dozers/` and `tasks/`, and there is no second requeue path in the Dozer's drain. A stranded merge therefore cannot bypass the proof check.
5. **Legacy receipts are held, not requeued.** A receipt without `workdir=` is held in-progress with one comment, guarded by a sentinel file. This is the design's choice, and it avoids the BRD-96 failure.
6. **Receipt carries its repo.** `crew.sh:1376` writes `workdir=$WORKDIR`. `WORKDIR` is defined at `crew.sh:75`, so no unbound-variable risk under `set -u`.
7. **Stale off-ramp repair.** `finish_repair` strips only `dozer:in-progress`. `list_stale_offramp` returns the exact MERGED-2 shape. Both are skipped for live locks. The label parse matches `_lane_of`, which returns `dev`, not `lane:dev`.
8. **Unbound-variable item handled as designed.** The test sources the real functions and runs them under `set -euo pipefail` on empty, pid-only, owner-less, live and dead lock layouts, plus a reaper dry run. All pass. No code change was made, which is what the design asked for when the defect does not reproduce.
9. **The GSAI-252 budget sweep survives the reaper merge.** The `task_budget_sweep` block is still at the bottom of `reaper.sh`.

## Non-blocking gaps (follow up, do not block merge)

- **`run_one` is not driven by any test.** The design's BRD-96 end-to-end case asked for `run_one` to end with the marker written and no `ok` line. `dev-lane-terminal-write-test.sh` tests the helper and the reaper, and its header says so. I checked the wiring by reading (`dozer.sh:654–696`): `|| return 0` is in the right places and the verb is set only on success. Still, the exact BRD-96 shape through `run_one` is unproven by a test. Add it, or cover it in the build pass's engine smoke test.
- **Reaper §0 swallows Linear errors.** `task_list_stale_offramp 2>/dev/null || true` (`reaper.sh:196`) hides a failed Linear list, so the repair silently does nothing. §1 already has the same pattern (pre-existing), so this matches current code. It still runs against the fail-fast rule. Log the failure to stderr.
- **Marker is not written atomically.** The design said "written atomically". `_terminal_write` writes straight to the final path (`dozer.sh:~517`). A kill mid-write leaves a partial marker. The verb line is written first, so the reaper still reads the verb. Write to a temp file and `mv` to close the gap.
- **`verify_proof=` is written multi-line.** `$vout` can span lines, and only the first line gets the `verify_proof=` prefix. Nothing reads that field, so it is cosmetic. Flatten it or drop it.
- **Claim-side quiet rejection logs as "already claimed".** `claim()` now exits 1 on `success:false`, and `dozer.sh:560–568` logs that as "already claimed, skipping". The issue stays `dozer:ready` and is re-polled. This is the old exit-1 meaning applied to a new failure, and it reads wrong in the log. A dedicated exit code would fix it.
- **Branch hygiene.** HEAD is `wip(GSAI-213): preserve uncommitted crew output (GSAI-157)`, a crew-rescue commit. Squash it into the code commit before merge so the history reads as one change.
- **Legacy stranded issues need a manual repair.** Already-stranded BRD-96-shaped issues whose receipts lack `workdir=` will be held by design and need a Director to act. The design calls this a deploy note. Make sure it is on the deploy checklist.

## Conclusion

The spec is met. Each failure mode from the BRD-96 log is covered by code I read and tests I ran. The reaper cannot requeue a git-verified merge. The build followed the design's shape and build order. The gaps above are wiring coverage, log hygiene and cosmetics; none of them strands an issue or requeues finished work.
