# DOZER-DESIGN-GSAI-213

## Task
A finished issue can be stranded at `dozer:in-progress` when the Linear write fails.

## Root cause (two distinct gaps, same symptom)

**1. `gql()` doesn't verify the mutation actually applied.**
`tasks/_linear_api.py:47-59` — `gql()` only raises on a transport exception or a
GraphQL-level `errors` array. It never inspects the mutation's own `success` field.
`set_labels_and_state()` (`_linear_api.py:191-196`) fires
`issueUpdate(id:$id,input:$in){ success }` and discards the returned `success` value
entirely. If Linear answers HTTP 200 with `{"issueUpdate":{"success": false}}` (a
transient backend rejection, a stale/conflicting revision, whatever), `gql()` returns
normally, `_relabel()` returns normally, and `merged()`/`review()`/`block()` all report
success to their bash caller — even though the issue's labels never changed. In
`dozers/dozer.sh:545/550` (`task_merged "$id"; verb="merged to develop"`), the engine
then posts a "Dozer merged to develop" comment and logs `ok #$id merged to develop`
while Linear still shows `dozer:in-progress`, state `started`, no off-ramp label. There
is no second look — the issue is stranded, and the comment trail actively hides it
("the task looks finished, why is it still in Running?").

**2. A write that genuinely throws is handled by `set -e`, not by a plan.**
`dozers/dozer.sh` runs under `set -euo pipefail`. `run_one()` (the same function) calls
`task_merged "$id"` / `task_review "$id"` / `task_block "$id"` as bare statements
(dozer.sh:525, 545, 550, 557, 563) with no `if`/`||` around them. When the underlying
`python3 _linear_api.py merged <id>` call genuinely fails (network blip, 30s timeout,
GraphQL error — `_linear_api.py:54-59`), that nonzero return trips `set -e` and
`run_one()` (running in the background per task, `dozers/dozer.sh:621`) exits
immediately via its `EXIT` trap, which only removes the local lock
(`dozers/dozer.sh:406`). Nothing retries the write, nothing records that the crew
already did the (expensive, verified) work, and no comment is posted — the run just
vanishes from the log.
What happens next depends entirely on `dozers/reaper.sh`'s `_is_inflight()`
(`_linear_api.py:690-708`), which is intentionally strict: an issue that already
carries an off-ramp label (`dozer:merged-develop` / `dozer:needs-review` /
`dozer:blocked`) is treated as finished, full stop — `tests/linear-inflight-test.sh`'s
`MERGED-2` fixture (`dozer:in-progress` **and** `dozer:merged-develop` together) is
already asserted to be excluded from reaping, on purpose (GSAI-119 history: the reaper
must never re-run already-merged work). That is the correct call for *not re-running
the crew*, but nothing today ever goes back and strips the lingering
`dozer:in-progress` label in that state, so the issue sits in the `Running` Linear view
forever even though it is done. And if the write failure left *no* off-ramp label at
all (case 1's `success:false`, or a genuine exception before any label changed), the
issue *is* still `_is_inflight()`-true — but the crew already completed real work
(a verified git merge, per `dozers/verify-merge.sh` and its `.artifacts/dev/<id>.merge`
receipt), so blindly `task_requeue`-ing it means the ENTIRE crew (architect → build →
test → merge) reruns on a task that is already merged: wasted spend at best, a bogus
second merge attempt or a false `dozer:blocked` (verify-merge finds no *new* commit) at
worst.

Net: the failure mode isn't one bug, it's a missing verify-and-repair step for the one
write that matters most — the terminal state transition after real work has already
happened.

## Approach

### 1. Make the Linear write self-verifying (`tasks/_linear_api.py`)
- `set_labels_and_state()`: capture the mutation's return value and `die()` if
  `success` is falsy — a "quiet" Linear-side rejection must surface exactly like a
  network exception does today. This alone closes gap #1: `task_merged` can no longer
  return 0 unless Linear actually shows the new label.
- Add a cheap read-after-write assertion in `merged()`/`review()`/`block()`: after
  `_relabel()` returns, use the label set `_relabel` computed (not a fresh fetch — no
  extra round trip needed for the common case) to confirm the target label is in
  `keep`. This is defense-in-depth for the case where `success:true` is returned but
  the field-level change didn't apply (seen with optimistic-lock races on other Linear
  objects) — same "label on PROOF, not the API's optimism" principle already used for
  merges (GSAI-119).

### 2. Bounded retry around the terminal write only (`tasks/linear.sh` / `dozer.sh`)
Add `task_merged`/`task_review`/`task_block` retry INSIDE the adapter (not the crew):
wrap the existing `python3 "$_LIN" <verb> "$id"` call in a small retry loop (3
attempts, short backoff — mirrors the `timeout_*` convention already in
`org/config.yaml`, so add `linear_write_retries: 3` / `linear_write_backoff_s: 5`
there). This is the highest-leverage fix for the common case (a transient network
blip right after a real merge) — most "stranded" issues never even reach the harder
reconciliation path below if the write just succeeds on attempt 2.
`dozer.sh` itself does not need new retry logic; it keeps calling `task_merged` once
and the adapter absorbs the retry.

### 3. Explicit handling in `run_one()` for a write that still fails after retries
Replace the bare `task_merged "$id"; verb=...` / `task_review "$id"; verb=...` /
`task_block "$id"` statements (dozer.sh:525, 545, 550, 557, 563) with an explicit
check. On failure of the *terminal* write (crew already succeeded, merge already
verified):
- Do **not** let `set -e` silently kill the run — catch the nonzero return.
- Write a durable local marker next to the existing merge receipt:
  `$art/$id.linear-write-failed` containing the verb attempted, the verify-merge
  proof, and the adapter's stderr. This is the same artifact-first discipline the
  engine already uses for `.merge`/`.fail`/`.handoff`.
- Log loudly to `~/.dozers/logs/loop.err.log` with the id, verb, and reason (fail-fast:
  report the exact error, never a silent drop).
- Still release the lock normally (nothing to gain by holding it — the git work is
  already safely merged and won't be redone by a Linear-side requeue as long as step 4
  is in place).

### 4. Reconciliation instead of blind requeue (extend `dozers/reaper.sh`)
Add a small pre-step to the reaper, run before the existing orphan-requeue sweep:
- **Stale off-ramp label**: for every issue carrying an off-ramp label
  (`dozer:merged-develop` / `dozer:needs-review` / `dozer:blocked`) **and** still
  carrying `dozer:in-progress` (the `MERGED-2`-shaped state the reaper already
  refuses to requeue) — call a new adapter verb, `finish_repair(id)`
  (`_linear_api.py`), which is exactly `audit_strip()`'s pattern generalized: strip
  `dozer:in-progress` only, touch nothing else. No git work, no state change beyond
  the one stray label.
- **Genuine in-flight with local proof of completion**: for every issue
  `_is_inflight()` reports with no live lock (today's orphan case), check for a
  leftover `$art/$id.merge` receipt or the new `.linear-write-failed` marker for that
  id *before* calling `task_requeue`. If a receipt exists, retry only the label write
  (`task_merged`/`task_review`/`task_block`, whichever the marker recorded) instead of
  requeuing — never re-run the crew when git already proves the work is done. Fall
  back to the existing `task_requeue` path only when no such proof exists (the
  genuine-crash case this reaper already handles correctly).
- Both repairs post a comment on the issue (`task_comment`, stamped
  `DOZER_COMMENT_BY="dozer-reaper"` as the reaper already does) so the fix is visible
  in the task's own history, not just the loop log.

## Files to touch
- `tasks/_linear_api.py` — `set_labels_and_state()` success check; read-after-write
  assertion in `merged`/`review`/`block`; new `finish_repair()` verb; OPS dispatch
  entry.
- `tasks/linear.sh` — retry wrapper around `task_merged`/`task_review`/`task_block`;
  new `task_finish_repair()` wrapper.
- `dozers/dozer.sh` — explicit (non-bare-`set -e`) handling of the terminal write in
  `run_one()`; write the `$id.linear-write-failed` marker artifact.
- `dozers/reaper.sh` — new pre-step: stale-off-ramp-label repair, and
  proof-before-requeue check ahead of the existing orphan sweep.
- `org/config.yaml` — `linear_write_retries` / `linear_write_backoff_s` (documented
  next to `timeout_*`).
- Tests (new, following the existing `tests/linear-*-test.sh` stub-module pattern):
  - `tests/linear-write-verify-test.sh` — a fake `gql`/`urlopen` returning
    `success:false` must make `merged()`/`review()`/`block()`/`claim()` raise, not
    return 0.
  - `tests/linear-finish-repair-test.sh` — `finish_repair()` on an issue carrying both
    `dozer:in-progress` and an off-ramp label strips only `dozer:in-progress`; leaves
    an issue with just the off-ramp label untouched (no-op, idempotent).
  - `tests/reaper-test.sh` (extend existing) — add a case: an inflight issue with a
    leftover `.merge` receipt gets its label write retried, not requeued; an inflight
    issue with no receipt still requeues (existing behavior, must not regress).
  - `tests/linear-inflight-test.sh` — no change needed; its `MERGED-2` fixture already
    documents the state this design repairs — it stays the proof that the reaper must
    never *requeue* that shape, only *relabel* it.

## Edge cases
- **`finish_repair()` racing a live crew**: guarded the same way the orphan sweep
  already is — only acts when `_lock_state(id)` is not `live` (no worker currently
  holds the id).
- **Both a stale in-progress label and a genuinely unverifiable merge** (label lingers
  but there's no `.merge` receipt at all — e.g. `dozer:blocked` was reached without
  ever attempting a merge): `finish_repair()` only strips the label; it never invents
  a receipt or asserts a merge happened, so this case is still just hygiene, matching
  `audit_strip()`'s existing "never touch state" contract.
- **Retry exhaustion during `claim()`**: `claim()` is cheap and safe to fail outright
  (nothing expensive has happened yet) — it is deliberately excluded from the retry
  wrapper; a claim failure should keep behaving exactly as today (falls through to
  "already claimed"/budget-exhausted handling), not attempt writes-retry machinery
  meant for the *terminal* transition.
- **Multi-team / multi-host races**: `finish_repair()` and the proof-check reuse the
  same `LOCK_DIR`/`_lock_state` liveness probe the reaper already trusts across hosts
  (it's a shared filesystem namespace, per `reaper.sh`'s existing comments), so no new
  cross-host assumption is introduced.
- **`.artifacts/` is host-local**: the proof-before-requeue check only works on the
  same Dozer host that ran the crew. A truly cross-host stranding (crew ran on host A,
  reaper runs on host B) still falls back to `task_requeue` today — that gap is
  pre-existing (the whole `.artifacts` scheme is host-local) and out of scope for this
  fix; noting it rather than silently pretending it's solved.

## How it gets tested
- Unit-level, module-import style exactly like the existing `tests/linear-*-test.sh`
  (stub `lin._all_issues`/`gql` via `importlib`, no real network/API key needed;
  `LINEAR_API_KEY=test-not-used` is already the convention).
- `tests/run-all.sh` picks up the new `tests/*-test.sh` files automatically (matches
  existing naming), so no harness change needed beyond adding the files.
- Manual/integration check before merge: run `dozers/reaper.sh --dry-run` against a
  hand-built fixture issue carrying `dozer:in-progress` + `dozer:merged-develop` and
  confirm the dry-run reports the intended `finish_repair` action without mutating
  anything (mirrors how `dozers/audit-merged.sh --dry-run` is already verified).
