# DOZER-DESIGN-GSAI-213

Architect pass, 2026-10-06. Supersedes the pass-1 design (same file, `b3e1c78`). Written against
`develop` at `aa0723f` (GSAI-252 merged). The pass-2 crew output is preserved at
`rescue/GSAI-213-wip-2026-10-06` (`0784ed8`); this design reuses most of it and corrects three things.

## Task
A finished issue can be stranded at `dozer:in-progress` when the Linear write fails. BRD-96 (2026-09-28)
merged and went green, then the terminal Linear write hit a read timeout and a 503. The issue stayed
`dozer:in-progress`, and the reaper later requeued it, which spent a release on already-merged work.

## What the code does today (verified on `aa0723f`)

**1. A quiet Linear rejection counts as success.** `set_labels_and_state()` (`tasks/_linear_api.py:191-196`)
sends `issueUpdate{ success }` and drops the value. HTTP 200 with `success:false` returns normally, so
`merged()`/`review()`/`block()` report success while the labels never changed.

**2. A loud failure kills the run silently.** `gql()` (`_linear_api.py:47-59`) calls `die()`, which is
`sys.exit(1)`, on a timeout, a 503 or a GraphQL error. Nothing retries it. `run_one()` in `dozers/dozer.sh`
calls `task_merged` / `task_review` as bare statements under `set -euo pipefail`. The backgrounded run exits
on the first failed write. There is no `ok` line, no comment and no marker. Only the EXIT trap runs. This
matches the BRD-96 log: `done #BRD-96` and `verify-merge: ok` appear, then the Linear errors, and no `ok` line.

**3. The reaper cannot tell finished work from a crash.** `reaper.sh` §1 requeues every `_is_inflight()`
issue with no live lock (`_linear_api.py:720`). An issue stranded at `started` + `dozer:in-progress` with no
off-ramp label matches that, so a finished merge gets requeued and the whole crew reruns. Its git receipt is
never consulted. The crew writes that receipt at `.artifacts/dev/<id>.merge` (`dev-lane/crew.sh:1376`) with
`branch=`, `merge_sha=`, `premerge_sha=`, `task_sha=`, and no workdir.

**4. The "unbound variable" defect is NOT reproduced.** The BRD-96 log shows `lock: unbound variable`.
I ran the real code under `set -euo pipefail` with two fixtures, an empty `LOCK_DIR` and a lock dir holding
only a `pid` file. `group_live_counts`, `inflight_count` and `repo_live_counts` (`dozers/dozer.sh`) all return
cleanly in both cases. A real `dozers/reaper.sh --dry-run` also exits cleanly on both fixtures (no
`LINEAR_API_KEY`, so the Linear list was not exercised). The `lock` reads are all inside loop bodies, and
`group_live_counts`/`repo_live_counts` were added later (GSAI-112, GSAI-169). The line is probably from an
older engine, but I did not bisect that. Per the spec's "confirm which before fixing", this design does not
invent a fix for it. See Approach §5.

## Verified against the rescue commit
- `git merge-tree --write-tree --merge-base 0784ed8~1 HEAD 0784ed8` (read-only dry run of cherry-picking the
  rescue onto `develop`): **one conflict, `dozers/reaper.sh`**. The other seven files auto-merge.
- The auto-merged `tasks/_linear_api.py` keeps `import ... time` in the merged tree. GSAI-252's budget lock
  still calls `time.monotonic()` and `time.time()`, so the merge does not break it.
- The rescue's reaper trusts `.merge` alone. It never checks that `merge_sha` is on the integration branch.
  That is the GSAI-119 failure this task must not repeat.

## Approach

### 1. Self-verifying Linear write (`tasks/_linear_api.py`) — keep from rescue
`set_labels_and_state()` checks `d["issueUpdate"]["success"]` and calls `die()` when it is falsy. Every
`_relabel()` caller goes through it, so claim, merged, review, block, requeue, done, mark_ready and finish_repair
all get the check. No read-back round trip: Linear's `success:true` is trusted, and the quiet-rejection case is
what the check exists to catch.

### 2. Bounded retry for the terminal writes only (`tasks/linear.sh`) — keep from rescue
`task_merged` / `task_review` / `task_block` call `_linear_write_retry`: 3 attempts total, 5 s apart, read from
`org/config.yaml` (`linear_write_retries`, `linear_write_backoff_s`). `task_claim` and `task_requeue` are not
wrapped. Retry is safe on the terminal writes:
- `merged()`/`review()` are set-label calls, so a second attempt after a timed-out write that actually landed
  is a no-op.
- `block()` goes through `ensure_budget_ask`, which is idempotent by ask marker.

### 3. Record a failed terminal write with its proof (`dozers/dozer.sh`, `run_one`)
Replace the bare `task_merged` / `task_review` calls with a `_terminal_write` helper (rescue version), called as
`_terminal_write <id> <verb-fn> <label> "$art" "$vout"` followed by `|| return 0`. The new behaviour, versus the
rescue, is this: the marker also records `workdir=` and `merge_sha=`. `run_one` already holds `$workdir`, and
`$vout` carries the verified SHA. The marker lives at `$art/$id.linear-write-failed` and is written atomically.
On a failed write the helper logs to `loop.err.log` and returns the rc. The lock is released as before. A marker
is evidence, not a verdict. The reaper still re-proves the work from git.

### 4. Receipt carries its repo (`dozers/dev-lane/crew.sh:1376`)
Add `workdir=<the checkout the merge landed in>` to the `.merge` receipt. This is one extra `printf` field. It
lets the reaper verify a merge without moving `resolve_workdir` out of `dozer.sh`. Legacy receipts (written
before this change) have no `workdir=` line. See Edge cases.

### 5. Reconcile before requeue (`dozers/reaper.sh`) — rescue's shape, git-verified
Insert a new **§0** before the existing orphan sweep, and tighten §1 as follows.

**§0 — stale off-ramp labels.** `task_list_stale_offramp` (in-progress plus merged-develop, needs-review or blocked)
feeds `task_finish_repair`, which strips `dozer:in-progress` and nothing else. It only runs when `_lock_state(id)`
is not `live`. Same as the rescue.

**§1 — proof before requeue.** For each in-flight issue with no live lock, `_proof_verb_for`:
1. Reads the marker, or the receipt if no marker exists. It gets the verb (`task_merged`, `task_review`,
   `task_block`) and the `workdir`.
2. **Verifies the proof against git before trusting it.** For a dev receipt it runs
   `REPO_ROOT="$ROOT" dozers/verify-merge.sh <id> <workdir>`, which checks that `merge_sha` is an ancestor of the
   integration branch and that `premerge_sha` / `task_sha` are consistent. This is the same gate `run_one`
   uses. Only if it passes does the reaper retry the recorded verb and post a comment.
3. A failed verification, a missing marker and a missing receipt all fall through to today's `task_requeue`.
   A merge that did not land is still requeued, which is correct.
4. A receipt with no `workdir=` (legacy) is **not** requeued. The reaper posts one comment saying it cannot
   verify the merge and leaves the issue in-progress. A Director resolves it. A silent requeue is the BRD-96
   failure, so it is not an option here.

The marker, when present, names the verb to retry. The receipt alone (crash after the merge, before run_one wrote
anything) means the verb is `task_merged` and the receipt is the proof. This covers the kill -9 window that no
marker can cover.

Marketing lane: no receipt exists. A marker with `verb=task_review` is the only trigger, and it is retried only
when the staged file `<workdir>/.dozers-review/<id>.md` is also present. Otherwise it requeues as before.

### 6. The unbound-variable defect — test first, fix only if it reproduces
Write `tests/dozer-lock-counts-unbound-test.sh`. It sources the real `group_live_counts`, `inflight_count`,
`repo_live_counts`, the doctor loop and `reaper.sh` (dry run), and runs each under `set -euo pipefail` against
an empty `LOCK_DIR`, a pid-only lock and an owner-less lock. It asserts no `unbound variable` on stderr and
the correct in-flight count. If it passes on the branch, the build pass says so in the review: the defect was
not reproduced on `develop` at `aa0723f`, and no code change is made for it. If it fails, fix only the line
that fails and say which one.

## Files to touch
- `tasks/_linear_api.py` — `set_labels_and_state()` success check; `finish_repair()`, `list_stale_offramp()`,
  and the OPS dispatch entries for both. (Rescue has these.)
- `tasks/linear.sh` — `_linear_write_retry`; the retry wrappers for merged/review/block; `task_finish_repair`
  and `task_list_stale_offramp`. (Rescue has these.)
- `org/config.yaml` — `linear_write_retries: 3`, `linear_write_backoff_s: 5`. (Rescue has these.)
- `dozers/dozer.sh` — `_terminal_write` (rescue, plus `workdir=` and `merge_sha=` in the marker); `run_one`'s
  terminal calls go through it.
- `dozers/dev-lane/crew.sh` — one `workdir=` field in the `.merge` receipt, line ~1376.
- `dozers/reaper.sh` — `_proof_verb_for` (**rewritten**: verify before trusting; legacy receipt case); §0
  finish-repair; §1 proof-before-requeue. Rescue's `reaper.sh` is the one file that conflicts on cherry-pick. Resolve it by
  keeping **both** GSAI-252's `task_budget_sweep` block and this issue's §0/§1.
- Tests (new, stub-module style of `tests/linear-*-test.sh`, `tests/run-all.sh` picks them up):
  - `tests/linear-write-verify-test.sh` — `success:false` makes `set_labels_and_state()` exit non-zero.
  - `tests/linear-terminal-retry-test.sh` — stubbed python fails twice (503, then timeout) then succeeds ⇒
    3 attempts, rc 0. Always failing ⇒ rc non-zero after exactly 3 attempts. `LINEAR_WRITE_BACKOFF_S=0`.
  - `tests/linear-finish-repair-test.sh` (rescue) — strips only `dozer:in-progress`; idempotent on a clean issue.
  - `tests/dev-lane-terminal-write-test.sh` — the BRD-96 end-to-end case. Stub `merged` fails 503 then timeout on
    every attempt. `run_one` ends with the marker written, `ok` not printed, and the issue never left at
    `dozer:in-progress` without a marker or receipt. Then a reaper pass with the stub listing the issue as in-flight
    and a real receipt: the reaper calls `task_merged` (the verb from the marker), does not requeue, and the
    `merged` stub is called with the id.
  - `tests/reaper-test.sh` (extend) — receipt + `verify-merge` pass ⇒ retry, no requeue; receipt + verify fail ⇒
    requeue (existing behaviour); no receipt ⇒ requeue (existing); legacy receipt (no `workdir=`) ⇒ no requeue,
    one comment; §0 strips in-progress only.
  - `tests/dozer-lock-counts-unbound-test.sh` — §6 above.
- `tests/linear-inflight-test.sh` — no change. Its `MERGED-2` fixture is still the rule: the reaper may **relabel** a
  finished issue but never **requeue** it.

## Edge cases
- **Retry plus a write that actually landed.** The second attempt is a no-op. The label set is the same.
- **Block failure during a budget cap** (GSAI-252). `block()` raises the ask before the labels, and the retry is
  idempotent by ask marker. The marker path records `task_block`, and the reaper retries `block`, not `merged`.
- **Marker says `task_merged` but verify-merge fails.** The merge did not land, so requeue. This is the one case
  where the marker is wrong about the work, and the git check catches it.
- **Receipt from a previous run.** `run_one` deletes `.merge` at the start of every claim, so a receipt only exists
  for the run that wrote it. The verify step still runs, because a receipt can name a SHA that was reverted.
- **Finish-repair racing a live crew.** Guarded by `_lock_state(id) != live`, as in the orphan sweep. Claim order
  already takes the lock before claim, so a freshly re-claimed issue is never stripped.
- **`.artifacts/` is host-local.** The proof check only works on the host that ran the crew, which is the same
  limit as today. A cross-host stranding falls through to a requeue (current behaviour). Noted, not fixed.
- **Legacy stranded issues (BRD-96-shaped, already in production).** Their receipts have no `workdir=`. They need
  a one-time manual repair by a Director, or one Director comment with the workdir. Listing them: `list-stale-offramp`
  covers the in-progress + off-ramp shape. A pure in-progress + legacy-receipt issue is found by grepping
  `.artifacts/dev/*.merge` for the id and has to be done by hand. This is a deploy note, not code.
- **Marketing lane.** The marker alone is the trigger, gated on the staged file. Everything else is unchanged.

## How it gets tested
- Stub-module tests in the `linear-*-test.sh` style (`LINEAR_API_KEY=test-not-used`, no network).
- The BRD-96 shape end-to-end, with a stubbed Linear and a real `verify-merge.sh` against a throwaway git repo
  (a merge commit on a branch, plus a receipt that names it). A real repo is needed so the git check is exercised,
  not stubbed.
- Full gate: `make test` (or `tests/run-all.sh`) green before merge. Known risk: the full `repo:dozers` suite
  already ran 1804 s against `timeout_test` 1800 s (see GSAI-213 comment, 2026-10-04). If it times out again, the
  build pass runs the scoped new tests plus `reaper-test.sh`, and reports the timeout. It does not raise the
  timeout silently.
- Manual check before promote: `dozers/reaper.sh --dry-run` against the live board. Expect `[dry] would retry
  terminal write` for any BRD-96-shaped issue, and no requeue of a verified merge.

## Build order (for the build pass)
1. `git cherry-pick 0784ed8`. Resolve `dozers/reaper.sh` (keep both sides). Stage and commit the resolution
   as its own commit.
2. Apply §3 (`workdir=`/`merge_sha=` in the marker), §4 (crew.sh receipt) and the §5 reaper rewrite.
3. Write the new tests first for §6 (unbound) and the BRD-96 end-to-end case, and confirm they fail or pass as
   described above.
4. Run the full gate. Commit the code. The merge diff must contain `dozers/*.sh` and `tasks/*` changes, not only
   `DOZER-*.md` (the pass-1 failure mode).

## Open choices (for Guzz / Vasanth to confirm; the build pass proceeds on the defaults marked ✓)
- ✓ Receipt gets `workdir=` (crew.sh) rather than moving `resolve_workdir` out of `dozer.sh`. Cheaper and keeps the
  routing code in one place.
- ✓ A legacy receipt with no `workdir=` is left in-progress with a comment, never requeued. The alternative is to move
  `resolve_workdir` into a shared file so the reaper can resolve it. That is a bigger change to routing code.
- ✓ The unbound-variable item is a test plus a report, with no code change unless the test fails.
- Pass-2 rescue commit is 27 commits behind `develop` at the time of writing. The cherry-pick is clean except
  `reaper.sh`, so the build pass rebases nothing and starts from current `develop`.
