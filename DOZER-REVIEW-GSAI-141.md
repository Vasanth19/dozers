VERDICT: FAIL

## Summary

The forward-merge + back-merge mechanics, the atomicity/revert wiring, and the
self-heal path are all sound and match the design doc. All 59 existing/new tests in
`tests/promote-test.sh` pass. But the new `_forget_if_new` cleanup helper
(`directors/promote.sh:143-147`) introduces a genuine, reproducible data-loss bug: it
unconditionally `git branch -D`s a branch that was minted purely as merge scratch
space ("newbranch" kind) on `_cleanup`, with **no check that the branch's commits were
actually published first**. Combined with `--no-push`, this silently destroys the
exact guarantee GSAI-141 exists to provide, and the design doc explicitly promises
otherwise.

## Confirmed bug — back-merge survives only in memory, then gets deleted under `--no-push`

Design doc, "Interaction with existing modes": *"`--no-push` / `LOCAL_ONLY` (no
origin): the back-merge is a local git operation — it runs exactly the same, it just
doesn't get published."* This is a direct contract: local `$FROM` must end up
containing the back-merge, even with nothing pushed.

Repro (full output below), using the exact repo shape `fixture()` in the test suite
itself builds — a clone that only ever checked out `main`, with `develop` existing
solely as `origin/develop` (this is what a plain `git clone` produces; it is not an
exotic edge case):

```
[promote] ✓ back-merged main → develop (564e0c1) — develop will never fall behind main from this promote
[promote] · push skipped (--no-push) — origin still lacks this promote
[promote] ✓ promote complete — ...
rc=0

=== does local develop branch exist? ===
develop branch is GONE
```

What happens: `_checkout_for("develop")` finds no local `develop` branch
(`_has refs/heads/develop` is false — only `origin/develop` exists), so it DWIMs one
via `git worktree add $w develop` and returns kind `"newbranch"`. The back-merge
commits onto that branch correctly. `_publish()` is skipped (`--no-push`). On exit,
the trap runs `_forget_if_new("develop", "newbranch", $FW)`, which removes the
worktree **and then unconditionally runs `git branch -D develop`** — deleting the
only local ref that ever pointed at the back-merge, because kind `== newbranch` is
the sole condition checked (`directors/promote.sh:146`). The script had already
printed a success line claiming the opposite.

In this exact repro `main` happens to survive (it was an "existing" checkout, not
newly minted), so the promote commit itself is still reachable via `main` — but the
back-merge's entire purpose (develop catching up) is silently undone one line after
the script claimed it succeeded, and nothing is published to recover it. If `main`
*also* has no pre-existing local branch in a given repo (both sides DWIM'd fresh —
plausible for e.g. an automation-only clone that never checked out either branch),
the same unconditional delete removes **both** refs and the entire promote commit
becomes a dangling object with nothing pointing at it and nothing on origin — total,
silent loss of the promote under a documented, supported flag combination
(`--no-push` + `HAS_ORIGIN=1`, which `directors/promote.sh:160-172` explicitly keeps
distinct from `LOCAL_ONLY` and treats as fully supported).

This is a regression introduced by this diff, not a carried-over pre-existing issue:
the old code's cleanup (`git -C "$REPO" worktree remove --force "$MW" ... `) never
deleted a branch at all, so the old behavior in this same scenario just left a stray
local branch behind — annoying, never destructive. The new `_forget_if_new` adds the
destructive `branch -D` specifically to fix that staleness (per its own comment,
"GSAI-141 bit this exact way on the back-merge side under `--no-push`"), but the fix
has no check for "was this actually published before deleting it" — it should at
minimum skip the delete (or fall back to leaving the stray branch, like the old code
did) whenever `PUSH=0`/`LOCAL_ONLY=1` for that branch, or more generally whenever
`_count "<branch>" "^origin/<branch>"` is nonzero after the merge.

### Why the test suite didn't catch this

Every `--no-push` test in the suite (`tests/promote-test.sh` cases 9, 11b/11c, 12,
15) runs against `fixture_localonly`, where **both** `main` and `develop` are real
pre-existing local branches from the start — `_checkout_for` never takes the
`"newbranch"` path there, so `_forget_if_new` never reaches the branch-delete line in
any existing or new test. The one test that does exercise "no local main branch"
(case 10b, `nolocalmain`) runs **without** `--no-push`, so the branch gets published
before cleanup deletes the local ref — masking exactly the failure mode that matters.
None of the new GSAI-141 tests cross "`--no-push`" with "a branch `_checkout_for` had
to mint from nothing," which is the one combination that breaks.

## Everything else checked and found sound

- Forward merge (`$SRC` → `$TO`) and its post-checks: unchanged from the
  already-proven GSAI-104 logic.
- Back-merge direction/flag choice (`--ff`, not `--no-ff`) and its conflict-free
  reasoning: verified correct by hand-tracing the ancestor relationships `_effective`
  guarantees, and confirmed by the `racey`/`sequential` tests exercising both the
  fast-forward and the real-merge-commit paths.
- Atomicity: `_revert()` correctly unwinds both `$MW` (to `PREMERGE`) and `$FW` (to
  `FROMPRE`) on any failure after the forward merge lands, so a partial promote never
  leaves `$TO` moved while `$FROM` lags — matches the design doc's ordering/atomicity
  section.
- Self-heal path (`AHEAD == 0`, `REVGAP > 0`): correctly heals pre-existing drift
  (including this repo's real 28-commit gap, per test 16) without touching `$TO`, and
  `--check`/`--dry-run` report the drift without mutating anything (test 17).
- `--check`/`--dry-run` plan text updated to mention the back-merge, as specced.
- Invariant 7 documented in the header block, matching the style of invariants 1-6.

## Verdict rationale

This is exactly the class of bug the task exists to prevent — work silently vanishing
instead of loudly failing — just relocated from "develop falls behind main" to
"develop's catch-up silently reverts itself under `--no-push`." Per CLAUDE.md's
fail-fast rule, a false "✓" success message that's contradicted one line later is
worse than an explicit error: a Director trusting this output has no signal anything
went wrong. Fix: gate the `branch -D` in `_forget_if_new` on the branch actually being
present on `origin` (or simply never auto-delete a `newbranch` whose tip isn't on
`origin/<branch>` yet — leave it as a stray local ref, same as the pre-GSAI-141
behavior, with a `say` noting it should be published or cleaned up by hand), then add
a test crossing `--no-push` with a `fixture()`-style clone that has no local
`develop` branch.
