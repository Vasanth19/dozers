# DOZER-DESIGN — #GSAI-147: crew discards a PASSING review on session exit code

## The bug

`run_model_pass` (dozers/dev-lane/crew.sh:267) treats any non-zero status out of the
timeboxed model session as a dead pass:

```bash
if ! _PASS_BLOCK="$_PASS_BLOCK" _PASS_PROMPT="$2" timebox "$T_MODEL" "$1 agent" "$WT" \
     'eval "$_PASS_BLOCK"; eval "$MODEL_CMD \"$_PASS_PROMPT\""'; then
  (( TIMEBOX_HIT )) && fail "$(timed_out_msg ...)"
  fail "$1 agent failed (worktree kept for resume)"
fi
```

But the session's exit code is a **side-channel**, not the deliverable. A model CLI can
finish its work — write `DOZER-REVIEW.md` with `VERDICT: PASS`, commit it — and still
exit non-zero (crash on teardown, a final-turn API error, a sandbox violation reported
at exit). The crew then `fail`s and never reads the verdict that is already on disk.
Observed shape: a passing review is thrown away, the task re-runs from the resume
path (another three model runs of spend), or blocks outright on the re-run.

The same defect exists for the other two passes: an architect that wrote a
`DOZER-DESIGN.md` and a builder that committed its work are both discarded on exit
code. The review pass is the headline because its artifact is a *verdict the merge
decision consumes* — but the fix should cover all three.

## Approach

The pass's **artifact is the contract**; the exit code only decides *whether to look*.
`run_model_pass` gains an optional third argument — the pass's *proof artifact* —
consulted only when the session exited non-zero AND it was not a timeout:

1. Keep the `TIMEBOX_HIT` branch exactly as-is: a **timeout always fails**, artifact or
   not. A killed process may have left a truncated file; "hung = failed" (GSAI-37) is
   not negotiable.
2. On a plain non-zero exit with a proof artifact supplied: check the artifact. If it
   is present, **continue from the artifact** and log a loud ⚠ line naming the pass,
   the exit code, and the artifact — the failure is reported, never silently swallowed
   (fail-fast doctrine: no masking). Capture the status (`rc=0; timebox … || rc=$?`)
   so the warning can name it.
3. On a non-zero exit with the artifact **absent** (or no artifact check supplied),
   fail exactly as today. The rescue is earned by a deliverable, not by exit-code
   generosity.

Artifact spec (decoded inside `run_model_pass`, kept deliberately tiny):

| Form | Check | Used by |
|---|---|---|
| `file:<name>` | `[[ -s "$WT/<name>" ]]` | architect → `DOZER-DESIGN.md`, review → `DOZER-REVIEW.md` |
| `commits:<sha>` | branch advanced past `<sha>` (`! git -C "$WT" diff --quiet <sha>`) | build → the anchor `build_once` already computes |

Call-site changes:

- `run_model_pass architect "$ARCH_PROMPT" file:DOZER-DESIGN.md`
- `run_model_pass build "$prompt" commits:"$anchor"` (anchor is computed in
  `build_once` immediately before the call, so no reordering needed)
- `run_model_pass review "$_rev_prompt" file:DOZER-REVIEW.md`

**Why this is safe — it never grants a merge by itself:**

- **review:** the existing verdict parse in `review_once` (crew.sh:503-509) is the
  real gate and stays untouched. A rescued review with a garbled/absent `VERDICT:`
  first line is treated as FAIL → one rebuild → a second FAIL blocks. A truncated
  artifact therefore buys a rebuild, never a merge.
- **architect:** the artifact check (`-s DOZER-DESIGN.md`) is *exactly* the check the
  crew already runs right after the pass (crew.sh:447-448) — the rescue only reaches
  code that would have accepted the same file anyway.
- **build:** the `commits:<anchor>` check is the same no-op gate `build_once` already
  enforces (crew.sh:475-477); plus tests still run to green before any merge.
- The rescue happens **before** `fail`, so no resume/state machinery changes; the
  downstream gates (test gate, migration gate, green-gate, merge receipt) are all
  untouched.

## Files to touch

- `dozers/dev-lane/crew.sh` — `run_model_pass` signature + rescue branch; three call
  sites pass the artifact spec. No other function changes.
- `tests/dev-lane-model-exit-test.sh` — new regression test (below).

## Edge cases

1. **Timeout with artifact on disk** — stub writes the artifact then hangs: must still
   fail with the timeout reason (timeout precedence; tested).
2. **Non-zero exit, artifact present** — continue; the ⚠ line appears in the crew log;
   the merge (for review-PASS) still lands and the GSAI-119 receipt is still written.
3. **Non-zero exit, artifact absent** — fails exactly as today ("architect agent
   failed", worktree kept). The rescue is not a blanket exit-code pardon (tested).
4. **Rescued review with garbled verdict** (truncated mid-write) — verdict parse →
   FAIL → rebuild → still can never merge a half-written PASS (tested).
5. **`MODEL_CMD` bypass path** — run_model_pass is shared, so the rescue applies
   equally; `review_once`'s `REVIEW_VERDICT="PASS"` MODEL_CMD branch is unchanged
   (existing tests rely on it).
6. **DRY_RUN** — doesn't call `run_model_pass`; unaffected.
7. **resolve_pass failure / bad route** — unchanged; fails before any session runs.
8. **Empty vs missing file** — `-s` (non-empty) catches the zero-byte touch; for
   build, `diff --quiet` catches "committed nothing".

## How it gets tested

New `tests/dev-lane-model-exit-test.sh`, in the idiom of `dev-lane-timeout-test.sh`:
a throwaway repo on `main`+`develop` (`mkproj` clone), a stub agent driven by
`MODEL_CMD` that counts invocations and misbehaves per pass:

- **RESCUE (headline):** stub writes `DOZER-DESIGN.md` + commits, then exits 3 on the
  architect call; commits a change then exits 3 on build; writes `VERDICT: PASS` +
  commits then exits 1 on review. Assert: crew exits 0, develop HEAD is the merge
  commit, merge receipt (`$OUT/<id>.merge`) written, and the log contains the ⚠
  rescue line naming the review pass.
- **NO-ARTIFACT:** stub exits non-zero having written nothing (architect). Assert:
  crew blocked with "architect agent failed (worktree kept for resume)", develop
  untouched — the rescue requires the deliverable.
- **TIMEOUT-PRECEDENCE:** stub writes `DOZER-DESIGN.md` then hangs. Assert: blocked
  with the model-timeout reason (GSAI-37 text), worktree kept — an artifact does not
  rescue a timeout.
- **GARBLED-VERDICT:** review stub writes a truncated review (no `VERDICT:` line) and
  exits 1. Assert: verdict parse reads FAIL → the one rebuild runs (stub's next
  invocation is the rebuild) → second garbled review blocks with "review failed TWICE".
  Proves the rescue feeds the verdict gate, not around it.

Then: `make test` (the repo's own gate — `tests/run-all.sh`). The existing suite must
stay green unchanged; `dev-lane-timeout-test.sh` in particular pins that the
TIMEBOX_HIT branch still fails before any artifact is consulted.

## Risk

Low and contained. One function + three call sites in `crew.sh`; no gate, merge,
receipt, or resume logic is touched. The only behavior change is *fewer spurious
fails* on a non-timeout exit code with the deliverable provably on disk — and every
rescue is logged, so nothing fails quietly that used to fail loudly. The dangerous
half (timeout) is explicitly preserved and regression-pinned.