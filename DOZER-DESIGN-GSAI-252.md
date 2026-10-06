# DOZER-DESIGN-GSAI-252 — the release cap must always raise a board-ask

Task: GSAI-252 — an issue can reach `release_budget` with no board-ask, so it is unanswerable forever.
Lane: dev · repo: dozers · architect pass (design only; no code in this commit).

## 1. Root cause (verified, not assumed)

The spec's three "likely causes" are checked against the code and the live record.

**The cap is enforced only at claim time, so it goes silent at block time.**

- `budget_check()` runs only inside `claim()` (`tasks/_linear_api.py`, `claim()` → `budget_check()`).
- `budget_refuse()` — the only function that posts the budget board-ask and adds `board:to_review` — runs only when a *fourth* claim is refused.
- The crew's failure path is `dozers/dozer.sh` ≈ L642: `task_block` then `task_comment "Dozer blocked … Reason: …"`. Nothing in that path reads the count.

So the third dispatch that fails leaves the issue at `releases == cap`, `dozer:blocked`, and **no ask, ever**, unless someone greenlights it again. `mark_ready()` (the Director's greenlight) does not consult the budget, so that re-greenlight is the only thing that would surface the ask — and it only does so one dispatch later.

**Live evidence — CFW-345 comment timeline (read-only query, 2026-10-06):**

| When (UTC) | Event |
|---|---|
| 10-02 01:54 | Dozer claimed (release 1) |
| 10-02 02:59 | Dozer blocked |
| 10-02 06:03 | Dozer claimed (release 2, after Director re-greenlight) |
| 10-02 06:18 | Dozer blocked |
| 10-04 02:14 | Director marked ready → Dozer claimed (release 3, allowed: count 2 < cap 3) |
| 10-04 02:27 | Dozer blocked → **count is now 3/3, no ask is raised** |

The cap-handler did not "fail" on CFW-345; it **never ran**. The gap is that a block at the cap is not treated as a cap event.

Mapping to the spec's causes:

1. *Cap-handler's ask step fails or is skipped on some path* — **confirmed in shape, different mechanism**: the handler is only reached on claim #4, so every block at claim #3 skips it by construction.
2. *A later pass strips `board:to_review`* — **not supported by code**. The only strips are `board_answer()` (on a real human answer → `board:responded`) and the `board-clear` path (`_linear_api.py` ≈ L1036–1061, which is the alarm/outage flow, not budget issues). The CFW-345 record shows no strip. The sweep in §3 heals this regardless, so it is covered either way.
3. *Ask lost by relabel/edit* — **ruled out**: asks are comments, and no code path edits or deletes comments. Covered by the sweep anyway.

**Secondary defects found on the same path (must be fixed in this change):**

- `budget_refuse()` writes labels (`_relabel`) and *then* the ask (`_comment_url`). If the comment write fails after the label write, the issue has `board:to_review` with no marker → the probe returns rc=2 forever. This is the "half-lands" shape Guzz described.
- `_comment_url()` ignores `commentCreate.success`. A `success: false` response is returned as an empty URL and treated as success.
- `gql()` dies via `sys.exit` on any error. In `budget_refuse()` that means the label write can succeed and the ask can be skipped with a silent exit. (The caller sees a non-zero exit, but the state is already half-written.)

**Test gap that let this ship:** `tests/linear-release-budget-test.sh` §2–4 drives *claim()* past the cap (three CLAIM+BLK pairs, then claim → exit 4). No test drives a *block* at the cap. The bug is invisible to the existing suite by construction.

## 2. Approach

Three layers, each closing a different path. Layer A is the fix; Layer B is the guarantee; Layer C is observability.

### A. Raise the ask at the block that reaches the cap

Introduce one shared routine, used by every path that can leave an issue frozen:

`ensure_budget_ask(iss, reasons-from-current-comments)`:

1. `count, outstanding, reasons = release_state(_issue_comments(ident))` (fail-loud on read error — see §4).
2. If `cap <= 0` or `count < cap` → return (no-op; gate invisible under the cap).
3. If `outstanding is None` → post the budget ask (`_budget_ask_body` + `board-ask … by:dozer-budget`) via a *checked* writer. Ask first.
4. Then one `_relabel` that ensures `dozer:blocked` + `board:to_review` present and `board:responded` absent.

Call sites:
- `block()` (failure off-ramp) — after the reason comment exists (see ordering fix below).
- `budget_refuse()` — refactored onto the same routine (same ordering: ask, then labels).
- the sweep (Layer B).

**Ordering: ask first, labels second.** Why: two Linear mutations cannot be atomic, so one of them can land alone. Ask-first means the only half-state is "marker present, label missing", which the sweep repairs and which fails safe (the issue is still `dozer:blocked` and visible to the Directors). Label-first is the current bug.

**Ordering fix in `dozer.sh`.** The reason is posted *after* `task_block` (L642–643 and the verify-merge block ≈ L617–619). If `block()` ran the ask, the ask body would miss the reason that caused the block. Swap to comment-then-block at those call sites (the three `task_block` + `task_comment` pairs at ≈ L550, L618, L642). A crash between the two leaves `dozer:in-progress`, which the reaper requeues; the claim-time gate then refuses and asks. Self-healing; no new state.

**Loud failure.** `_comment_url()` checks `success` and dies with the exact GraphQL error when it is false. `block()` exits non-zero if the ask cannot be posted, so the crew reports it instead of silently blocking an issue with no ask.

### B. Reconciling sweep — the guarantee for every path

New verb `budget-sweep [--dry-run]` in `tasks/_linear_api.py` (+ `OPS` entry, + `task_budget_sweep` in `tasks/linear.sh`).

Candidate set: `_all_issues()` filtered to not completed/canceled and carrying `dozer:blocked`. For each candidate, compute `release_state` and enforce the spec invariant:

> at `count >= cap` with `dozer:blocked`, the issue must have BOTH an outstanding `by:dozer-budget` ask AND `board:to_review`.

Per candidate:

| State | Action |
|---|---|
| count < cap | skip |
| ask present, label present | ok |
| ask present, label missing (stripped) | add `board:to_review`, remove `board:responded`; **no new comment** |
| no ask, label anything | post ask, then ensure labels (same routine as A) |

Properties:
- **Idempotent.** The ask is keyed on the outstanding-ask check in `release_state`. A second sweep finds the ask and posts nothing. Dedupe does not depend on timing.
- **Respects the human re-grant.** After Vasanth comments (unmarked), `release_state` resets the count, so the issue is no longer at cap and the sweep leaves it alone. The Directors' board reconcile then swaps `board:to_review` → `board:responded` as today.
- **Respects `release_budget: 0`.** Gate disabled → sweep is a no-op and says so on stderr.
- **Per-issue lock against double-ask.** Block-time and sweep can race on the same issue. Guard with an atomic `mkdir` lock `~/.dozers/locks/budget-<ID>.lock` (same pattern the Dozer already uses), held across read-check-post. If the lock is held, skip this issue and report it.
- **Dry-run.** `--dry-run` prints the exact set it would ask and relabel, and changes nothing. Used for the backfill review (§5).

Where it runs: `dozers/reaper.sh` (the natural home; the spec asks for it). Call `task_budget_sweep` guarded by `declare -F`, the same way the reaper already calls `task_list_inflight`. The reaper runs from `recover()` on startup and every `REAPER_EVERY` loop ticks (`dozer.sh` ≈ L811–820), so the sweep is throttled by the existing cadence. Cost: one comment query per dozer:blocked issue (≈94 today, one `gql` each). Acceptable at that cadence; verify during build that `REAPER_EVERY` is not 1.

Scope note: the sweep only enforces the invariant. It does **not** change the cap value, the claim-time refusal, or any Director's authority.

### C. Make the gap visible — `release-count`

`release_count()` prints `ask=` with three values, not two:

| Condition | Output |
|---|---|
| count < cap (or cap ≤ 0) | `ask=none` (no ask needed) |
| count ≥ cap, outstanding ask | `ask=outstanding` |
| count ≥ cap, no outstanding ask | `ask=MISSING` |

Optional addition (flagged as a choice, not required by the spec): append `board=yes|no` so a label gap is also visible without reading the Board. I recommend adding it; it costs nothing (labels are already in `issue()`).

## 3. Files to touch

| File | Change |
|---|---|
| `tasks/_linear_api.py` | `ensure_budget_ask()` shared routine; `block()` calls it; `budget_refuse()` refactored onto it; `_comment_url()` checks `success`; `budget_sweep()` + `OPS` entry; `release_count()` emits `ask=MISSING`; per-issue `mkdir` lock helper |
| `tasks/linear.sh` | `task_budget_sweep()` wrapper |
| `tasks/adapter.sh` | document the optional `task_budget_sweep` verb in the backend contract header |
| `dozers/dozer.sh` | swap comment/block order at the three `task_block` + `task_comment` pairs (≈ L550, L618, L642) |
| `dozers/reaper.sh` | call `task_budget_sweep` (guarded by `declare -F`) |
| `tests/linear-budget-ask-test.sh` | **new** — the regression (§4) |
| `tests/run-all.sh` | register the new test |

Not touched: `org/config.yaml` (cap stays 3), `directors/`, `tests/linear-release-budget-test.sh` (kept as-is; it still covers claim-time behaviour — the new test adds the block-time path).

Not in this change: a backfill write. The backfill is run as a separate, explicit step after review (§5).

## 4. Edge cases

- **Two asks for one issue** — prevented by the outstanding-ask check plus the per-issue lock. Test: two concurrent-ish calls → one comment.
- **Ask posted, then label write fails** — issue is `dozer:blocked` and carries the marker; the sweep adds the label next pass. Test: stub label write to raise → exit non-zero; then sweep → label added, no second comment.
- **Ask write fails** — `block()` exits non-zero before touching labels. Issue stays `dozer:in-progress`; the reaper requeues; the next claim refuses and asks. Test: stub `commentCreate` `success:false` → non-zero, no `_relabel` call.
- **Human answer, then re-stripped label** — count reset → sweep skips. Test covers it.
- **Issue with >250 comments** — `_issue_comments` is `first:250` (pre-existing; `first:` returns the oldest). Undercounts, fails open, and the sweep inherits that. Not fixed here; noted as a known limit (existing comment in `_issue_comments` already says so).
- **Done/Canceled with `dozer:blocked`** — skipped. `done()` strips `BLOCKED` anyway.
- **Gate disabled (`release_budget: 0`)** — sweep and block-time ensure are both no-ops.
- **Read failure during sweep** — that issue is reported as `unreadable`, the sweep exits non-zero overall, and nothing is asked on that issue. Never fail-open for a *write*: a gate that cannot read must not stop the board from being told.
- **Crash between block comment and block label** (after the ordering swap) — leaves `dozer:in-progress`; reaper requeues. No orphan `dozer:blocked` without a reason.
- **Reasons ordering** — with the swap, the reason comment exists before the ask is computed, so the ask body includes the reason that caused the block. Test: the ask body contains the third BLK's reason text.

## 5. Testing

**Red first.** Add the failing regression before the fix: drive a *block* past the cap and assert the ask. It must fail on current `main` (proving the gap), then pass after the fix.

`tests/linear-budget-ask-test.sh` — hermetic, same stub pattern as `linear-release-budget-test.sh` (`issue`, `_issue_comments`, `_relabel`, `_comment_url` stubbed; `commentCreate` success flag injectable):

1. **The regression (CFW-345 shape).** Comments = CLAIM+BLK ×3, `dozer:in-progress` present. Run the crew's failure path (comment then `block`). Assert: one budget ask (`by:dozer-budget`) posted; labels carry `dozer:blocked` + `board:to_review` in the same relabel. Fails today; passes after.
2. **Ordering.** The ask body contains the third block's `Reason:` text.
3. **Ask write fails** (`success:false`) → `block()` exits non-zero; `_relabel` not called.
4. **Label write fails after ask** → non-zero exit; a second `budget-sweep` adds the label and posts **no** second ask.
5. **Idempotence.** `budget-sweep` twice → exactly one ask total.
6. **Stripped label, ask present** → sweep re-adds `board:to_review`, posts nothing.
7. **Under cap / Done / Canceled / cap 0** → sweep skips; no writes.
8. **Human re-grant** (unmarked comment after ask) → count resets → sweep skips.
9. **`release-count`** prints `ask=none` under cap, `ask=outstanding` with an ask, `ask=MISSING` at cap without one.
10. **`_comment_url` with `success:false`** → dies with the error (no silent empty URL).
11. **Claim-time path unchanged** → existing `tests/linear-release-budget-test.sh` still green.

Then the full suite: `bash tests/run-all.sh` (currently 47 tests per GSAI-254's review).

**Live verification (read-only first):**
- `tasks/_linear_api.py budget-sweep --dry-run` over the live board. Expected set: the 11 `ask=none` issues from Guzz's 2026-10-06 comment (CFW-345, 343, 330, 327, 319, 309; LL-20, LL-38; BRD-110; GSAI-157, GSAI-223, GSAI-72 — BRD-94 is excluded because it already has `ask=outstanding`). If the dry-run set differs, stop and report the difference before writing.
- **Backfill** = the real `budget-sweep` run after the dry-run is reviewed. It posts asks to Vasanth's board, so it is an outward-facing write: run it only with the dry-run list in hand, and report the list back.
- Post-backfill: `release-count` on each of the 12 exhausted issues → `ask=outstanding`; a second sweep → zero writes. Acceptance criterion from the spec: zero issues at cap without an ask.

## 6. Decisions I made (for the Dev-Director to redirect)

1. **Ask-first ordering** over label-first, because the surviving half-state is recoverable and the reverse is not.
2. **Sweep lives in the reaper** (spec's suggestion) and inherits its existing cadence, instead of a new timer.
3. **Per-issue `mkdir` lock** for block-vs-sweep races, not a Linear-side guard (Linear has no compare-and-set on comments).
4. **`ask=MISSING`** exactly as the spec words it; `board=yes|no` added as an optional column.
5. **No change to the cap value or the claim-time refusal** — the gap is the block path, not the threshold.

## 7. Out of scope / follow-ups

- The `first:250` comment limit (pre-existing, documented in code).
- Whether `mark_ready()` should refuse at cap instead of letting the next claim refuse. The sweep already makes that unnecessary; changing the greenlight path is a Director-facing change and not needed for this defect.
- The GSAI-231 budget decision itself (Vasanth's call; this change only makes the question reach him).
- Doctrine update in the brain (`knowledge/concepts/infra/dozers`) to say "the cap raises an ask at the block, not only at the next claim" — SOP text, not a work item; to be filed separately.
