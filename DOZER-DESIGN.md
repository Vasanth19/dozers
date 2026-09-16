# DOZER-DESIGN — #GSAI-149: the no-commit gate asks "did this attempt add commits" instead of "is the branch ahead of base"

## The bug

`build_once` (dozers/dev-lane/crew.sh:492-509) anchors at the *current* HEAD
immediately before the build pass and fails when the branch did not advance past
it:

```bash
anchor="$(git -C "$WT" rev-parse HEAD)"
run_model_pass build "$prompt" "commits:$anchor"
...
if git -C "$WT" diff --quiet "$anchor" -- 2>/dev/null; then
  fail "build agent produced no commits on $BRANCH"
fi
```

On a **resume whose work is already complete** the build agent correctly adds
nothing — there is nothing left to write — so the diff is quiet and the crew
fails a task that holds finished, tested work ahead of the base (GSAI-144:
attempt 4; BRD-88). The script contradicts itself: the resume path reuses the
worktree precisely *because* `git log "$base..$BRANCH"` is non-empty, then the
gate fails the same task for not producing *more*. A completed task can never
finish; each attempt burns a full architect+build+review cycle to rediscover the
work is done.

The GSAI-147 `commits:$anchor` proof argument inside `run_model_pass` has the
same blind spot: on a resume, a build flake (non-zero exit, not a timeout) with
nothing new committed fails the whole crew *before* the gate could judge — a
finished branch is unrescuable too.

## Approach

The gate's question changes from **"did this attempt add commits?"** to **"does
the branch hold anything to merge?"** — one definition, shared by the gate and
the build pass's proof artifact (spec point 5: no two versions of "the build did
something").

### Why not the spec's literal `git log "$base..$BRANCH"`

The spec's point 2 claims a first attempt with a no-op build "naturally" has an
empty `$base..$BRANCH`. That is wrong on the production (routed) path: the
architect backstop (crew.sh:481-482) commits `DOZER-DESIGN.md` to the branch
*before* the build runs, so the log is non-empty even when the build wrote
nothing. A literal log-based gate would pass a no-op first build and only block
it two review passes later — violating the spec's own "must still fail with a
clear message". The gate therefore asks a **diff** question instead:

> Does the branch differ from the integration base in anything **other than the
> pass artifacts** (`DOZER-DESIGN.md`, `DOZER-REVIEW.md`)?

This satisfies both sides at once:

- resume, work complete, nothing added → feature diff vs base is non-empty →
  **pass** (the headline fix), logging a plain resume line;
- first attempt, no-op build → the only diff is the design file → excluded →
  **fail**, exactly as today;
- first attempt with real output → non-empty → pass, as today.

Diff (not log) keeps one parity with the old gate: uncommitted working-tree
changes count as output, just as they did against `$anchor`.

### The base must be a pinned SHA, not the `$base` ref name

`base` is the literal string `HEAD` when the integration branch has no *local*
ref (develop remote-only — crew.sh:344). A `git -C "$WT" diff HEAD …` at gate
time resolves HEAD **inside the worktree** to the branch tip — diff always
empty — which would fail every build on such repos (a regression the anchor
didn't have). So one SHA is pinned in `$WORKDIR` **after** the isolate/resume
block (after crew.sh:387), where:

- a resume just rebased onto `$base`'s current tip → `BASE_SHA` is exactly that
  tip → the diff is exactly the task's commits;
- a fresh worktree was created off `$base` → `BASE_SHA` is its creation commit;
- `base="HEAD"` resolves in the main checkout to the very commit the worktree
  was built from (same resolution `git worktree add` used).

`$base` the *name* keeps its existing roles (resume detection, rebase, merge);
only the gate/proof comparisons move to `BASE_SHA`.

### The change

1. **`branch_has_output <dir> <sha>`** — new tiny helper next to
   `run_model_pass`: `! git -C "$dir" diff --quiet "<sha>" -- . \
   ':(exclude)DOZER-DESIGN.md' ':(exclude)DOZER-REVIEW.md'`. One definition of
   "the build did something", shared by the gate and the proof.
2. **`BASE_SHA`** pinned after the isolate block (see above).
3. **`run_model_pass`**: the `commits:<sha>` proof form is **replaced** by
   `changes:<sha>` (branch holds diff beyond the pass artifacts vs that sha).
   The rescue line keeps the `⚠ <pass> agent exited <rc> but … — continuing`
   shape so the GSAI-147 test's prefix assertion still matches. Timeout
   precedence (TIMEBOX_HIT before any proof) is untouched.
4. **`build_once`**:
   - proof argument becomes `changes:$BASE_SHA` (consistency, spec point 5);
   - the gate becomes `if branch_has_output "$WT" "$BASE_SHA"; then … else
     fail "build agent produced no commits on $BRANCH"; fi`;
   - when the branch passes **but** this attempt added nothing
     (`git diff --quiet "$anchor"`), log the spec's plain line:
     `build pass added nothing — branch already N commits ahead of <base>,
     continuing to test+merge` (N via `rev-list --count "$base..$BRANCH"`).
     `$anchor` survives only to distinguish "added nothing" for that line.
5. **Nothing downstream changes.** Tests still run and still gate the merge;
   a test failure still blocks; a timeout still fails; the review verdict
   contract (GSAI-147) is untouched. Note the order inside `build_once` is
   already tests → no-commit gate, so "a resume whose tests fail still fails"
   holds by construction — the gate is only reached on green tests.

The fail message stays byte-identical ("build agent produced no commits on
$BRANCH") — it is still literally true when it fires (no commits, and no diff,
beyond the artifacts).

## Files to touch

- `dozers/dev-lane/crew.sh` — `branch_has_output` helper; `BASE_SHA` pin;
  `run_model_pass` `commits:`→`changes:` form (+ its doc comment); `build_once`
  gate + proof argument + resume info line; comment blocks at crew.sh:266-280
  and 492-494 rewritten to state the new question.
- `tests/dev-lane-no-commit-gate-test.sh` — new regression test (below).

`tests/dev-lane-model-exit-test.sh` needs **no edit** — its build-rescue
assertion is a prefix (`⚠ build agent exited 3 but`) that the new message
keeps — but it must stay green under `make test` (it pins that the GSAI-147
rescue still fires when the build *did* deliver commits, and that timeout
precedence survives).

## Edge cases

1. **First attempt, routed, no-op build** — design commit sits ahead of base, so
   a naive log gate would pass it; the artifact-excluding diff fails it
   (TESTED, case FIRST-ATTEMPT-NOOP — this pins the spec's point-2 protection,
   which the literal log check would NOT deliver).
2. **Resume, work complete, build adds nothing** — passes with the plain resume
   line, proceeds to tests and merges (TESTED, case RESUME-FINISHED).
3. **Resume whose tests fail** — blocks at the test gate, which runs *before*
   the no-commit gate; the new gate never weakens it (TESTED, case
   RESUME-TESTS-FAIL).
4. **Build flake on a resume** (non-zero exit, non-timeout, nothing new) — the
   `changes:$BASE_SHA` proof now rescues where `commits:$anchor` killed the
   crew; after the rescue the gate itself passes on the prior work.
5. **Timeout** — TIMEBOX_HIT is checked before any proof; still always fails
   (pinned by dev-lane-model-exit-test).
6. **Rebuild after a FAILed review where the build judges nothing needs
   fixing** — commits nothing; the gate now passes it to the re-review instead
   of failing "no commits". The verdict gate still decides — arguably the old
   behavior was wrong here too, and this is strictly more faithful to "review
   judges, gate only guarantees there is something to judge".
7. **`base="HEAD"`** (develop remote-only) — resume was already impossible there
   (pre-existing); `BASE_SHA` keeps first attempts working where a by-name
   worktree diff would have broken them.
8. **Stale base + rebase on resume** — `BASE_SHA` is pinned after the rebase, so
   the diff is exactly the task's commits, not "old base..branch" noise.
9. **Uncommitted changes count as output** — parity with the old anchor diff;
   merges still only carry commits, review still sees the working-tree diff
   (its prompt diffs `$base`, unchanged).
10. **Branch differing from base only in the artifacts** — fails (a design file
    is not a deliverable to merge). Exclusions are the exact top-level names
    `DOZER-DESIGN.md` / `DOZER-REVIEW.md`.
11. **DRY_RUN** — bypasses `build_once` entirely; unaffected.

## How it gets tested

New `tests/dev-lane-no-commit-gate-test.sh`, in the idiom of
`dev-lane-model-exit-test.sh`: throwaway repo on `main`+`develop` (`mkproj`),
a stub agent driven through the **routed** path (stub `claude` on PATH +
`SCRUB_ROUTE`, because the garbled-review trick and the verdict parse need the
non-bypass branch; the crew's design backstop commit — the case-1 pin — also
only exists there). The stub counts invocations (1=architect, then
build/review alternate) with `BUILD_MODE=work|nothing` and
`REVIEW_MODE=pass|garbled`.

- **RESUME-FINISHED (headline):** run 1 with `REVIEW_MODE=garbled` → two garbled
  reviews → blocked "review failed TWICE", worktree **kept** holding design +
  build commits. Run 2 (resume) with `BUILD_MODE=nothing REVIEW_MODE=pass`:
  the build adds nothing. Assert: crew exits 0; the log carries `build pass
  added nothing — branch already … commits ahead`; the merge landed on develop;
  the GSAI-119 receipt is written and verifiable.
- **FIRST-ATTEMPT-NOOP:** fresh project, `BUILD_MODE=nothing`: the architect
  commits the design, the build writes nothing, tests are green. Assert:
  blocked with exactly `build agent produced no commits on dozer/TEST-…`,
  develop untouched, worktree kept — a naive log-based gate would have passed
  this (the design-commit hole).
- **RESUME-TESTS-FAIL:** same run-1 construction as above; between runs, commit
  a failing `t.sh` onto the kept task branch (setup, simulating prior work that
  is not green). Run 2 with `BUILD_MODE=nothing`: the gate passes on the
  existing feature diff, tests run and fail. Assert: blocked with `tests
  failed — not merging (worktree kept for resume)`, develop untouched.

Then: `make test` (`tests/run-all.sh` auto-discovers the new file). The whole
existing suite must stay green unchanged — in particular
`dev-lane-model-exit-test.sh` (GSAI-147 rescue + timeout precedence) and
`dev-lane-stale-base-test.sh` (resume/rebase path the `BASE_SHA` pin lives in).

**Verified in the wild** (the spec's last done-when, post-merge): the
Dev-Director re-greenlights GSAI-144 — its 4-attempt worktree resumes, the
build adds nothing, and the crew reaches `ok #GSAI-144 merged to develop`
without hand intervention, unblocking the promote chain (GSAI-66, GSAI-142,
BRD-4).

## Risk

Low and contained. One function + its call sites in `crew.sh`; every downstream
gate (test gate, migration gate, green-gate, merge receipt, review verdict,
timeout precedence) is untouched, and the gate only *loosens* one thing: a
resume with complete work stops failing. The one true sharp edge — `base="HEAD"`
repos, where a by-name diff in the worktree would have broken every build — is
handled by pinning `BASE_SHA` in the main checkout, and the fail case keeps its
exact old message so existing failure text consumers are unaffected.