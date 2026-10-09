VERDICT: PASS

## Summary

This is the second review pass. The prior review (`63938ef`) failed the build because
`_forget_if_new` unconditionally `git branch -D`'d a freshly-DWIM'd `develop` ref on
cleanup, silently destroying the back-merge under `--no-push` the moment `develop`
had no local branch to begin with (exactly `fixture()`'s shape). Commit `4f4f21f` fixes
that gap, and the fix is sound: `_forget_if_new` (`directors/promote.sh:151-161`) now
only deletes a `newbranch`-kind ref when `HAS_ORIGIN` is true **and**
`refs/remotes/origin/<branch>` already contains that branch's tip
(`git merge-base --is-ancestor refs/heads/$br refs/remotes/origin/$br`) — i.e. only
once the branch has nothing origin lacks. Otherwise it leaves the ref in place with an
explicit `· leaving $br as a local ref …` message, matching the pre-GSAI-141 behavior
of never discarding unpublished commits.

## Verified by hand-tracing the exact repro from the FAIL review

Walked `nopush_newbranch` (test 18, `tests/promote-test.sh:390-408`) through the script:
`fixture()` clones only check out `main`, so `develop` exists solely as
`origin/develop`. Running `--no-push`, `_checkout_for(develop)` DWIMs a fresh local
`develop` (kind `newbranch`) in a throwaway worktree, the back-merge fast-forwards it
to the new `main` tip, `_publish()` is skipped (`--no-push`), and on exit
`_forget_if_new` removes the worktree but now checks: is local `develop` (at the
back-merge commit) an ancestor of `origin/develop` (still at the old tip)? No — so the
branch is **kept**, with the explanatory message. This is the exact inverse of the
previous FAIL, confirmed both by manual trace and by running the suite.

## Test run

```
bash tests/promote-test.sh
```
All 64 checks pass, including:
- the regression test added for this exact bug (test 18, `nopush_newbranch`) —
  local `develop` survives cleanup, `develop..main` is empty, `main` is an ancestor
  of `develop`, all under `--no-push` with a freshly-minted local branch.
- every pre-existing GSAI-141 test from the first build (happy path, idempotent
  rerun, sequential promotes, racey/late-develop, local-only, heal-drift,
  `--check`/`--dry-run` side-effect-free) still green — the fix did not regress any
  previously-passing behavior.
- the original GSAI-104 squash/divergence/dirty-checkout/no-origin coverage, untouched.

`promote-test.sh` is picked up automatically by `tests/run-all.sh`'s `tests/*-test.sh`
glob, so this regression test runs in CI without any separate wiring.

## Design-doc conformance

Matches `DOZER-DESIGN-GSAI-141.md`'s approach: back-merge placed between the forward
merge's post-check and `_publish()`, `_checkout_for` generalized across both branches,
full-promote atomicity via `_revert` unwinding both sides, self-heal extended into the
`AHEAD == 0` branch, and `--check`/`--dry-run` extended to report the reverse gap
without mutating anything. One deliberate, well-justified deviation: the design doc's
"Approach" code sketch shows `git merge --no-ff <new main tip>` for the back-merge, but
the implementation uses `--ff` instead (`directors/promote.sh:388-395`), with inline
reasoning that `--no-ff` would mint a brand-new commit on `develop` every single run —
which `main` would then be missing, recreating GSAI-141 in the opposite direction
forever. This is consistent with the design doc's own "Ordering and atomicity" section,
which describes the back-merge's possible outcomes as "produces `N` (or a
fast-forward)" — a `--no-ff` merge can never fast-forward, so the prose sketch and the
rest of the design doc were already in tension; the implementation resolves it
correctly, and the `sequential`/`racey` tests exercise both the fast-forward and the
real-merge-commit (`$FROM` moved on) paths.

## Everything else re-checked and still sound

- Forward merge, its post-checks, and invariant 2's stray-commit detection: unchanged
  from the already-proven GSAI-104 logic, still passing.
- Atomicity: `_revert()` unwinds both `$MW` (to `PREMERGE`) and `$FW` (to `FROMPRE`) on
  any failure after the forward merge lands, including every back-merge failure path.
- `_forget_if_new`'s unconditional `git worktree remove` is only ever reached for
  `CLEANUP_TO`/`CLEANUP_FROM` paths, which are only set when a branch's kind is `new`
  or `newbranch` (never `existing`) — the main repo's own checkout is never touched.
- Publish ordering: `_publish()` always runs (and would push a newly-created branch)
  before the `EXIT` trap's cleanup fires, so a `newbranch` that *was* successfully
  published is correctly deleted, and one that wasn't (push failure, or `--no-push`)
  is correctly preserved — verified by tracing both branches of `_publish`'s partial-
  failure cases (from→ok,to→fail and from→fail).
