VERDICT: PASS

## What I checked

- Read the full diff against `DOZER-DESIGN-GSAI-213.md`'s four-part approach.
- Traced the actual post-diff control flow in `dozers/dozer.sh` (`run_one`, `_terminal_write`,
  `_record_write_failure`) and `dozers/reaper.sh` (stale-off-ramp repair, proof-before-requeue)
  by reading the live files in the worktree, not just the diff hunks.
- Ran the tests most directly exercising this change:
  - `tests/reaper-test.sh` — 16/16 pass, including the new `RTEST-PROVEN` case (orphaned task
    with a leftover `.merge` receipt gets its terminal write retried, not requeued).
  - `tests/linear-write-verify-test.sh` — 11/11 pass (`success:false` and a disagreeing
    read-after-write both raise for `merged`/`review`/`block`/`claim`; a clean write doesn't).
  - `tests/linear-finish-repair-test.sh` — 10/10 pass (`finish_repair`/`list_stale_offramp`
    strip only `dozer:in-progress`, only when an off-ramp label is present, idempotent).
  - `tests/linear-kr-order-test.sh` fully stubs `task_merged/review/block`, so the new retry
    wrapper in `tasks/linear.sh` doesn't affect it. Grep confirmed no other test calls those
    functions against a real `backend: linear` path, so the retry-induced `sleep` can't add
    latency to the rest of the suite. Attempted a full `tests/run-all.sh`; it's long-running
    (dev-lane integration tests spin up real git repos) and didn't finish in the session, but
    the targeted tests above are the ones this diff can actually break.
- Cross-checked the artifact-dir naming convention (`marketing` -> `mktg`) is identical between
  `dozer.sh:460` (`art_dir`) and `reaper.sh`'s new `_art_dir_for_lane()`, and that `$art` is
  defined before the new `_terminal_write` call sites — both were the kind of "two places must
  agree" detail that's easy to drift.

## Verdict reasoning

The build follows the design's four numbered steps faithfully:
1. `set_labels_and_state()` now dies on `success:false` **and** on a read-after-write label-set
   mismatch — implemented as a single choke point (all `_relabel` calls route through it) rather
   than duplicated in `merged()`/`review()`/`block()` as the design sketched; that's a better
   version of the same intent (one round trip, one place to get right), not a deviation.
2. `tasks/linear.sh` wraps only the terminal writes in a bounded retry, reading
   `linear_write_retries`/`linear_write_backoff_s` from `org/config.yaml` with sane fallbacks;
   `task_claim` is correctly left unwrapped per the design's explicit carve-out.
3. `run_one()`'s `_terminal_write` never lets a write failure trip `set -e` — it records
   `$id.linear-write-failed` (verb, timestamp, merge proof, stderr) and logs loudly to stderr,
   then lets the lock release normally, exactly as specified.
4. `reaper.sh` gained the two-part reconciliation: strip a stale `dozer:in-progress` when an
   off-ramp label already landed, and retry (never requeue) the terminal write when local proof
   of completion exists ahead of the pre-existing orphan-requeue path. Both are lock-guarded the
   same way the existing sweep is.

One real gap, not severe enough to fail the review: in `run_one()`, `_terminal_write` always
returns 0 (by design, so `set -e` doesn't kill the background run), but the code immediately
downstream — the `task_comment "Dozer $verb..."` post and the `echo "  ok #$id $verb..."` log
line — runs unconditionally, regardless of whether the write actually succeeded. So on the
exhausted-retry failure path, Dozer still posts "Dozer merged to develop" to the issue and logs
"ok" to the loop log at the exact moment the label write failed — the same "comment trail
actively hides it" symptom the design's own root-cause section calls out is not actually
eliminated, just mitigated. In practice this doesn't reintroduce permanent stranding: the label
genuinely wasn't applied, so label-filtered views (Running, Ship gate) stay correct, a loud
stderr line is now written where before there was total silence, and the reaper's next sweep
finds the `.linear-write-failed` marker, retries the write, and posts its own follow-up comment
— so the issue self-heals rather than sitting stuck forever. It's a should-fix polish item
(gate the success comment/log on `_terminal_write`'s actual result) worth a follow-up issue, not
a reason to send this back — the spec's actual claim ("a finished issue can be stranded... when
the Linear write fails") is fixed: nothing stays permanently stuck at `dozer:in-progress` anymore.

No other correctness issues found. Config parsing, artifact-dir naming, and lock-liveness
guards are all consistent across the touched files.
