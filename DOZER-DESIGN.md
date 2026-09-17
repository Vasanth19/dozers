# GSAI-148 — design: per-issue pass artifacts — two tasks in one repo must not collide on DOZER-DESIGN.md

**The bug.** Every dev-lane crew tells its ARCHITECT pass to "write DOZER-DESIGN.md at
the worktree root" and its REVIEW pass to "write DOZER-REVIEW.md at the worktree root"
(`dozers/dev-lane/crew.sh`, the three heredoc prompts), and the crew's backstops commit
those exact paths. The path is FIXED — it does not name the task — so any two tasks in
the same repo write the same two files. The moment one lands on the integration branch,
every other in-flight task in that repo holds a branch whose rebase (resume, GSAI-70)
or merge replays an add/add conflict on those paths:

- **resume:** `git rebase "$base"` replays the task's "design (architect pass)" commit
  onto a base that now contains another task's DOZER-DESIGN.md → add/add → rebase
  aborted → "stale base: … CONFLICTS" → blocked, worktree parked.
- **merge:** `git merge --no-ff` conflicts the same way; the fallback `git rebase
  "$INTEG"` in the task worktree conflicts again → "merge conflict — sent back".

This repo is the live proof: the root `DOZER-DESIGN.md` this pass was told to overwrite
is GSAI-154's design, and root `DOZER-REVIEW.md` is GSAI-154's review — each task
silently destroys the previous one's record, and GSAI-148/149 could not both land.

The twist that makes it pure waste: these files are **not deliverables**. The no-commit
gate's `branch_has_output` already excludes them (`':(exclude)DOZER-DESIGN.md'
':(exclude)DOZER-REVIEW.md'`) — a branch whose only diff is the design file FAILS. So
the collision blocks real, gated, test-green work on files the lane itself declares
worthless as merge content.

**The fix — name the artifacts after the issue.** One change of shape, applied
everywhere: the artifact paths become per-issue —
`DOZER-DESIGN-$ID.md` and `DOZER-REVIEW-$ID.md` (e.g. `DOZER-DESIGN-GSAI-148.md`).
Two tasks in one repo then never touch the same path, so neither the resume rebase nor
the merge can conflict on them. Rounds *within* one issue (rebuild after a FAILed
review, resume attempts) keep writing the same file — same branch, sequential
commits, which rebase and merge handle as ordinary same-path edits.

## Approach

1. **Single source of truth in `crew.sh`.** Right after `ID="$1"` is validated,
   derive a filename-safe id and the two artifact names:

   ```bash
   ART_ID="$(printf '%s' "$ID" | sed -E 's/[^A-Za-z0-9._-]/-/g')"   # GSAI-148 → GSAI-148
   DESIGN_FILE="DOZER-DESIGN-$ART_ID.md"
   REVIEW_FILE="DOZER-REVIEW-$ART_ID.md"
   ```

   Every other reference uses the variables. No second place spells the names out —
   that is the whole bug class closed by construction.

2. **Replace every literal, site by site in `dozers/dev-lane/crew.sh`:**
   - `ARCH_PROMPT` heredoc — "write `$DESIGN_FILE` at the worktree root"; the resume
     preamble's "If DOZER-DESIGN.md is already committed" → "If `$DESIGN_FILE` is
     already committed".
   - `BUILD_PROMPT` — "Implement the design in `$DESIGN_FILE`".
   - REVIEW-prompt heredoc in `review_once` — "write `$REVIEW_FILE` … whose FIRST
     LINE…", and "DOZER-DESIGN.md is the architect pass's plan" → `$DESIGN_FILE`.
   - `run_model_pass` proof arguments: `file:DOZER-DESIGN.md` → `file:"$DESIGN_FILE"`,
     `file:DOZER-REVIEW.md` → `file:"$REVIEW_FILE"` (the proof parser `${3#file:}` is
     already name-agnostic; the "is on disk" rescue line prints the real name).
   - architect backstop: `-s "$WT/DOZER-DESIGN.md"` → `"$WT/$DESIGN_FILE"`;
     `git add DOZER-DESIGN.md` → `git add "$DESIGN_FILE"`; the "architect produced
     no DOZER-DESIGN.md" fail text names `$DESIGN_FILE`.
   - review backstop in `review_once`: `git add "$REVIEW_FILE"`, the awk verdict scan
     reads `"$WT/$REVIEW_FILE"`, and both `_notes="$(cat …)"` reads (rebuild prompt +
     double-FAIL fail text) read `$REVIEW_FILE`.
   - `branch_has_output` excludes **both schemes**:
     `':(exclude)DOZER-DESIGN.md' ':(exclude)DOZER-REVIEW.md'
     ':(exclude)'"$DESIGN_FILE" ':(exclude)'"$REVIEW_FILE"`. The legacy pair stays so a
     pre-fix resumed branch (whose committed artifacts carry the old names) is still
     correctly scored "design is not a deliverable" — dropping the legacy exclusions
     would let such a branch pass the gate on a design file alone.
   - `DRY_RUN` stub block: `printf … > "$WT/$DESIGN_FILE"` / `"$WT/$REVIEW_FILE"`
     (`git add -A` downstream already commits whatever the names are).

3. **Docs/comment touch-up (no behavior):** the `models:` comment in `org/config.yaml`
   (lines ~137–138, "dev.architect (plan -> DOZER-DESIGN.md)") names the per-issue
   scheme. `dozers/dev-lane/dozer.md` needs no change — it says "a short design note"
   without naming a file; the crew prompt is the contract.

4. **No migration of in-flight branches.** A pre-fix branch carrying a committed
   legacy-path design that genuinely conflicts on rebase still fails loudly as
   "stale base" — a one-time residue the Director resolves by re-greenlighting a
   fresh attempt; the new code does not (and should not) silently rewrite old
   commits. The legacy *exclusions* (point 2) are the only look backwards.

## This task's own artifacts — the transition, one time only

The crew running THIS task predates the fix, so this design and this task's review
land at the legacy root paths — the old backstops and verdict scan require it, and
the merge stays clean because develop has not touched those files since this
branch's base (our side simply wins). From the next task onward no crew ever writes
those paths, and the two root files freeze on `develop` as inert history (git
history keeps every past overwrite; a future ops task may prune them — not this one,
mid-run, where the gates still read those names).

## Files to touch

| File | Change |
|---|---|
| `dozers/dev-lane/crew.sh` | `ART_ID`/`DESIGN_FILE`/`REVIEW_FILE` + every literal listed above |
| `org/config.yaml` | comment-only: name the per-issue artifact scheme |
| `tests/dev-lane-model-prompt-test.sh` | stub writes `"$DESIGN_FILE"`/`"$REVIEW_FILE"` (derive from a `TASK_ID` the runner already knows — export it in `run_crew`/`run_crew_routed` env) |
| `tests/dev-lane-model-exit-test.sh` | same stub change + the asserted rescue lines (`⚠ architect agent exited 3 but DOZER-DESIGN-<id>.md is on disk`, review ditto, ×2/×1 counts) |
| `tests/dev-lane-no-commit-gate-test.sh` | stub writes the per-ID design; the design-only-must-fail cases keep failing via the exclusion; add one case proving a **legacy-named** design-only diff is also excluded (pre-fix resume honesty) |
| `tests/dev-lane-artifact-collision-test.sh` (**new**) | the regression test below |

`tests/run-all.sh` globs `tests/*-test.sh` — the new test is picked up with no
registration. `Makefile` untouched.

## Edge cases

- **ID sanitization** — Linear keys (`GSAI-148`) are already filename-safe; the `sed`
  guard exists for any exotic key, and both files derive from the same `ART_ID`, so a
  weird id degrades to an ugly-but-consistent name, never a split brain.
- **Same issue, multiple attempts** — same `$DESIGN_FILE` across resumes/rebuilds;
  rebase replays same-path commits cleanly; the resume preamble wording still works.
- **Two concurrent crews, same repo, different issues** (the actual incident) —
  disjoint artifact paths; the resume rebase and the serial merge both land. The
  per-project merge lock already serializes the merges; this removes the *content*
  collision the lock cannot.
- **`MODEL_CMD` bypass** — the `file:` proof and "is on disk" lines print `$DESIGN_FILE`
  verbatim; tests assert the new names, so the bypass path is covered by the same
  suite.
- **`DRY_RUN`** — stub writes the per-ID files; nothing else in that path names them.
- **Review verdict scan (GSAI-155)** — awk logic unchanged, only the file it reads.
- **`.artifacts/dev/` summaries and the merge receipt** — already per-ID (`$ID.md`,
  `$ID.merge`); untouched.

## How it gets tested

1. **New regression test `tests/dev-lane-artifact-collision-test.sh`** (idiom of
   `dev-lane-model-prompt-test.sh` — throwaway repo on `main`+`develop`, stub agent,
   `MODEL_CMD` bypass):
   - Run crew for task **A** (id `TEST-AC-A`): stub architect writes
     `DOZER-DESIGN-TEST-AC-A.md`, build commits a real change, review writes
     `VERDICT: PASS` into `DOZER-REVIEW-TEST-AC-A.md`. Assert exit 0 and A merged.
   - **Stage the collision:** while `develop` still sits at its pre-A tip, hand-create
     B's worktree at `$WORKTREE_ROOT/<slug>-TEST-AC-B` on branch `dozer/TEST-AC-B`
     with a committed `DOZER-DESIGN-TEST-AC-B.md` plus a small code change (exactly
     the interleaving that produced the incident: B branched before A merged).
   - Run crew for task **B**: it takes the RESUME path, sees `develop` moved, and
     rebases. Assert, in the log: the "base moved — rebased" line, **no** "CONFLICTS"
     and **no** "merge conflict"; assert exit 0; assert `develop` now holds **both**
     design files (`DOZER-DESIGN-TEST-AC-A.md` AND `DOZER-DESIGN-TEST-AC-B.md`).
     On the unpatched crew this scenario dies at the rebase with `DOZER-DESIGN.md`
     named in the conflict list — that is the mechanical repro of the task title.
2. **Updated suites** — prompt-test, exit-test, no-commit-gate-test rewritten to the
   per-ID names (their stubs receive the task id via env), plus the new legacy-name
   exclusion case. The INJECTION/ROUND-TRIP/ROUTED payload assertions in
   prompt-test are filename-agnostic and must keep passing byte-identical.
3. **Full gate** — `make test` (run-all.sh, scrubbed env) green end-to-end, in-crew
   included: the suite is the repo's own test command, so the green-gate proves it.

**Out of scope, deliberately:** moving artifacts into a per-issue directory (same
collision fix, more path churn, no added safety); not committing the artifacts at all
(breaks the resume "already committed" contract and the audit trail the review pass
reads); pruning the frozen legacy root docs (ops follow-up, not a mid-run edit).