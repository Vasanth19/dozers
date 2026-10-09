# GSAI-257 — design: a hygiene preflight for the host-checkout merge target

**The bug.** When the integration branch is already checked out somewhere other than a
throwaway worktree (GSAI-26 — e.g. the main `cfw-social` checkout sits on `develop`),
the crew merges and green-gates **inside that live, human-used checkout**
(`dozers/dev-lane/crew.sh:1289-1309`). The only thing standing between "trust this
checkout" and "merge and test in it" is one line:

```sh
if [[ -n "$(git -C "$_integ_at" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  fail "integration branch $INTEG is checked out dirty at $_integ_at; ..."
fi
MW="$_integ_at"; MW_OWNED=0
```

That is a **dirty check**, not a **hygiene preflight**, and it has three blind spots:

1. **`2>/dev/null` turns "couldn't tell" into "clean".** If `git status` itself fails
   (lock contention from a crashed `git` process, a mid-write index, a permissions
   blip), the command substitution is empty and the `if` reads it as spotless. The one
   signal that would say "I don't know" is thrown away — the exact failure mode
   `gate_read()` (`crew.sh:393-420`) was built to close for the migration gate: *"a gate
   that cannot see the diff must stop — never wave the change through."* This check
   never got that treatment.
2. **No in-progress-operation check.** `wip_snapshot()` (`crew.sh:668-671`) already
   knows a worktree can be mid-rebase or mid-merge with an otherwise clean tree, and
   refuses to touch it. That same check exists ONLY for the task worktree. The host
   checkout — the one a human actually uses, and the one most likely to be left
   mid-rebase or mid-cherry-pick after Vasanth steps away from it — gets no such check
   at all.
3. **`--untracked-files=no` is scoped to "would a human lose work", not "is this
   checkout safe to test in".** That scope was the right call for GSAI-26 (don't block a
   merge on a gitignored `node_modules`), but this same checkout is about to have
   `npm test`/`make test` run in it for the green-gate (`crew.sh:1339-1371`). Untracked
   scratch files, half-finished edits, or leftover build/test output from a prior
   session in that checkout are invisible to this check and ride straight into the
   test run that is supposed to answer "is `$INTEG` still green" — the merge gate is
   answering a question about a tree that isn't purely `$INTEG`'s committed history.

Title's framing: **host-checkout state poisons the merge gate** (point 3, and point 1's
false-clean) **because there is no hygiene preflight** (point 2, and the missing
read-failure handling in point 1) — only a narrow dirty check. "3 dev lanes sealed
2026-10-05" is this gap in production: three issues targeting a repo whose host
checkout carried exactly this kind of invisible-to-the-check state each had their merge
go in, each got judged against a poisoned tree, and each came back blocked with no way
to see *why* — because nothing in the crew's own output could have named the real
cause.

## Approach

Add a `host_checkout_hygiene <dir>` preflight, run in place of the current one-line
dirty check, **only on the "merge in the existing checkout" path**
(`crew.sh:1298-1303`). The throwaway-worktree path (`crew.sh:1304-1309`) is always
freshly created from `$INTEG`/`$base` and can never carry this kind of leftover state,
so it is untouched.

`host_checkout_hygiene` runs four checks in order, fails closed and names the exact
problem on the first one that fails (same doctrine as every other gate in this file —
`migration_gate`, `resolve_test_cmd`, `gate_read`):

1. **Git-dir sanity.** `git -C "$dir" rev-parse --absolute-git-dir` — captured, not
   discarded. A failure here means the checkout's git state cannot even be inspected;
   fail with the stderr, never assume clean.
2. **In-progress operation.** Same markers `wip_snapshot` already checks for the task
   worktree (`crew.sh:669`), applied here: `rebase-merge`, `rebase-apply`, `MERGE_HEAD`,
   `CHERRY_PICK_HEAD`, `BISECT_LOG` under the git-dir from step 1. Any present → fail,
   naming which one. (A paused rebase/cherry-pick can have a perfectly clean working
   tree, which is exactly why the existing check misses it.)
3. **Tracked dirtiness — unchanged.** The existing
   `git status --porcelain --untracked-files=no` check, kept byte-for-byte (same
   failure message text, so the existing regression test's assertions keep passing),
   but with its `git` invocation's stderr captured instead of redirected to
   `/dev/null`: a non-zero exit from `git status` itself is now a named hygiene
   failure ("could not read status"), not silent "clean".
4. **Untracked debris, allowlisted.** `git status --porcelain --untracked-files=normal
   -- . "${DEP_PATHSPEC[@]}"` — **reusing the exact pathspec `wt_unsaved` already
   builds** (`crew.sh:651-655`: `DEP_ENTRIES` — `node_modules`, `.env*` — plus the
   per-issue `$DESIGN_FILE`/`$REVIEW_FILE` and legacy artifact names). Anything left
   over after that exclusion is untracked-and-not-expected: fail, naming the paths.
   This is the one new piece of scope — everything DEP_PATHSPEC already calls benign
   (deps, env files, pass artifacts) stays benign here too, so the GSAI-26/GSAI-124
   node_modules story is untouched; anything else (a stray log, a half-written file, a
   build output dir nobody gitignored) now blocks instead of silently riding into the
   green-gate's test run.

Escape hatch, matching the shape every other gate in this file already uses
(`test_gate_waiver`, `MIGRATION_GATE=off`): `HYGIENE_GATE=off` for one deliberate run,
a `.dozers-no-hygiene-gate` marker file in the repo or worktree, or
`no_hygiene_gate: true` on the repo's `ecosystem.yaml` entry (same lookup
`ecosystem_flag` already does for `no_test_gate`). All three log plainly which waiver
fired; none of them are a default anyone can flip globally.

## Files to touch

- `dozers/dev-lane/crew.sh`:
  - new `host_checkout_hygiene <dir>` function (near `migration_gate`, same style:
    sets a `$HYGIENE_FAIL_MSG`-style message and returns 1, or the caller's `fail`
    directly — matching whether the caller has state to unwind yet; at this call site
    nothing has been touched, so a direct `fail "..."` is fine, unlike
    `install_deps`/`resolve_test_cmd`'s post-merge callers).
  - new `hygiene_gate_waiver <dir>` helper, same shape as `test_gate_waiver`
    (`crew.sh:350-357`).
  - call site `crew.sh:1298-1303`: replace the inline dirty check with
    `host_checkout_hygiene "$_integ_at"`.
  - header comment block above the merge-target section (`crew.sh:36-40`) gets a line
    describing the hygiene preflight, same convention as the other numbered doctrine
    comments in this file.
- `tests/dev-lane-host-hygiene-test.sh` — **new**, regression test (below).
- `tests/run-all.sh` — register the new test if it enumerates test files explicitly
  (check before editing, per the same note on GSAI-254's design).
- No changes to `org/config.yaml`, `ecosystem.yaml`'s schema (only a new optional
  per-repo key, same as `no_test_gate`), director templates, or lane prompts.

## Edge cases

- **Expected untracked state (node_modules, .env*, pass artifacts).** Allowlisted via
  the shared `DEP_PATHSPEC` — the common case (host checkout with installed deps)
  passes hygiene exactly as it merges today. Regression case 1 of
  `tests/dev-lane-merge-target-test.sh` must still pass unmodified.
- **Mid-rebase/mid-cherry-pick checkout with a clean tree.** Caught by check 2, named
  explicitly ("mid-rebase" / "mid-cherry-pick"), instead of silently passing as clean
  and then having `git merge --no-ff` run against a checkout that is not in `$INTEG`'s
  resting state. (If HEAD is also detached, `git worktree list --porcelain` won't
  report `branch refs/heads/$INTEG` for it at all, so this checkout wouldn't even be
  selected as `_integ_at` — check 2 only matters for the case where the branch is still
  attached, e.g. a rebase paused via `--onto` without detaching, or a merge left
  mid-flight.)
- **`git status` failing outright** (lock contention, corrupt index). Check 1 or the
  stderr capture in check 3 names the git error; the checkout is never treated as
  clean by default.
- **Stray scratch/log/build files from a human session or an earlier crashed crew
  run.** Named by check 4, merge refused, checkout left exactly as found (nothing is
  deleted — cleanup is a deliberate human/Director action, per the fail-fast doctrine:
  no silent workarounds).
- **A repo whose normal tooling leaves OTHER untracked artifacts at the root that
  aren't in DEP_ENTRIES** (e.g. a coverage/ dir some runners always produce and nobody
  gitignored). This will false-positive on check 4 until the repo either gitignores it,
  adds it to `DEP_ENTRIES`'s scope (a shared list, so that's a deliberate doctrine
  change, not a per-repo escape), or opts out with `HYGIENE_GATE=off` /
  `.dozers-no-hygiene-gate` / `no_hygiene_gate: true` — same trade-off TEST_GATE and
  MIGRATION_GATE already accept for their own false positives, flagged as residual
  risk below rather than solved further here.
- **The throwaway merge-worktree path.** Untouched — `git worktree add "$MW" "$INTEG"`
  always starts from `$INTEG`/`$base`, so it can never carry host debris; running
  hygiene there would be pure overhead for a case that cannot fail this way.
- **Locking/ordering.** Hygiene runs inside the already-held `$MLOCK` (merge lock,
  `crew.sh:1284-1287`), same as the existing dirty check, so two crews can't race on
  the same host checkout's hygiene state.

## Testing

**Regression — `tests/dev-lane-host-hygiene-test.sh`**, same harness as
`tests/dev-lane-merge-target-test.sh` (`mkproj` fixture, stub agent via `MODEL_CMD`,
the real crew driven end-to-end):

1. **Fast path unchanged.** Host checkout on `develop`, clean, `node_modules` present
   (the deliberate GSAI-26 case). Expect: merges exactly as
   `dev-lane-merge-target-test.sh` case 1 already asserts — this test asserts it again
   against the hygiene-checked path to prove no regression.
2. **Stray untracked file blocks the merge.** Host checkout clean of tracked changes,
   but with an extra untracked file at the root that is not `node_modules`/`.env*`
   (e.g. `scratch.txt`). Expect: crew fails, the reason names `scratch.txt`, `develop`
   is untouched, the task branch is kept for resume (mirrors case 2's assertions in the
   existing merge-target test).
3. **Mid-rebase checkout blocks the merge.** Fixture starts a `git rebase` in the host
   checkout and leaves it paused with a clean tree (e.g. `GIT_SEQUENCE_EDITOR=true git
   rebase -i HEAD~1` stopped via a conflict-free `edit`, or directly fabricate
   `.git/rebase-merge/` with the files `git rebase` itself would leave). Expect: crew
   fails, reason says "mid-rebase", nothing merged.
4. **`git status` forced to fail.** A wrapper `git` on `PATH` that fails only on
   `status` inside the fixture's directory (or a transient `.git/index.lock` placed
   before the crew runs). Expect: crew fails naming a status/read error — not "clean",
   not a silent pass.
5. **Escape hatches honored.** Same stray-file fixture as case 2, run once with
   `HYGIENE_GATE=off` and once with a `.dozers-no-hygiene-gate` marker in the repo.
   Expect: both merge successfully, and the log names which waiver fired (mirrors
   `test_gate_waiver`'s existing log line shape).

Also re-run `tests/dev-lane-merge-target-test.sh` unmodified — case 1/1b (clean +
node_modules fast path) and case 2 (tracked-dirty failure, exact message) must still
pass byte-for-byte, since check 3 keeps the old message text. Then the full
`tests/run-all.sh` for the rest of the dev-lane suite that touches this code path
(`dev-lane-greengate-test.sh`, `dev-lane-integration-fallback-test.sh`,
`dev-lane-stale-base-test.sh`).

## Out of scope / residual risk

- **No auto-clean.** Hygiene failures are reported, never remediated by the crew —
  consistent with "report the exact error, stop, ask how to proceed." A sealed lane
  still needs a human or a Director to look at the named checkout and clear it
  deliberately.
- **DEP_ENTRIES is a shared allowlist**, not configurable per repo. A repo that
  legitimately produces other untracked root-level artifacts needs the gate opt-out,
  not a per-repo allowlist — deliberate, to avoid two drifting definitions of "benign
  untracked state" the way `ARTIFACT_PATHSPEC`'s comment (`crew.sh:621-628`) already
  warns against.
- **Detached-HEAD mid-rebase hosts** still fall through to the generic "could not
  create merge worktree" failure from the `else` branch (check 2 never runs for them,
  since they're never selected as `_integ_at` in the first place) — not misdiagnosed,
  just not as sharply named as the attached-HEAD case this design covers. Flagged, not
  fixed, since it already fails closed today.
- **Does not change the green-gate's deps/test logic** (`install_deps`, `run_tests`,
  `link_deps`) at all — this is purely a preflight gate on whether the checkout is
  trustworthy before any of that runs.

## Choices made (for Guzz to redirect)

- Reused `DEP_PATHSPEC`/`DEP_ENTRIES` as the untracked-allowlist rather than inventing
  a second, parallel definition of "benign untracked state" — one list, shared with
  `wt_unsaved`, so the two checks can't silently drift apart.
- New escape-hatch name `HYGIENE_GATE` (+ `.dozers-no-hygiene-gate` marker +
  `no_hygiene_gate:` ecosystem.yaml key) rather than folding this into `TEST_GATE` —
  they gate different things (test-command presence vs. checkout trustworthiness) and
  a repo may need one waived without the other.
- Kept check 3's failure message text identical to today's, specifically so the
  existing `dev-lane-merge-target-test.sh` regression test needs no changes — only a
  new test file is added, nothing already green has to be touched.
- Did not add hygiene checking to the throwaway-worktree path — judged unnecessary
  (see edge cases) rather than "defense in depth"; flag for Guzz if that judgment
  should be more paranoid.
