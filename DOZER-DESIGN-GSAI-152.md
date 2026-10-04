# GSAI-152 — design: a resumed task's dirty worktree is snapshotted before the stale-base rebase, never refused by it

**The bug.** A resumed task whose worktree holds uncommitted output dies at the
stale-base rebase. `dozers/dev-lane/crew.sh:797` runs `git -C "$WT" rebase "$base"` on a
dirty tree; git refuses (`cannot rebase: You have unstaged changes`). The `else` arm
(`crew.sh:800-810`) then reports it as `stale base: … CONFLICTS … worktree kept, sent
back`. Nothing conflicted: the base moved cleanly, and the rebase was blocked by the
*dirty* tree, not by the code. The task is unresumable until a human cleans the
worktree, which is exactly the state CFW-215, GSAI-73 and GSAI-144 (×2) were stuck in.

Reproduced in a scratch repo (2026-10-04, `/tmp`, removed after):

| Worktree state at resume | `git rebase develop` (base moved, no conflict) |
|---|---|
| tracked unstaged edit (`M task.txt`) | **rc=1** `cannot rebase: You have unstaged changes` |
| untracked file only | rc=0 (untracked files only block when the rebase would overwrite them) |
| tracked edit + `rebase --autostash` | rc=0, clean reapply, stash stack left empty |

So the refusal is the tracked-edit case, the common shape of a resumed task.

**Why GSAI-157 did not already fix it.** GSAI-157's design (`DOZER-DESIGN-GSAI-157.md`,
"Rescue-before-resume") puts a `wip(<ID>)` snapshot ahead of the resume check and so
removes this refusal. That design was merged to `develop` as `fc5bad0`, but **only the
design doc** (`DOZER-DESIGN-GSAI-157.md`, 254 insertions) landed. `wt_unsaved`,
`wip_snapshot`, and the `dev-lane-uncommitted-rescue-test.sh` suite are not in the tree
(`rg wip_snapshot dozers/` is empty on `develop`). The design is sound; it was never
built. This task builds the part of it that the rebase needs.

## Approach

Snapshot the worktree's unsaved output into a `wip(<ID>)` commit **before** the
`RESUMING` decision, using the GSAI-157 helpers verbatim in shape. Then the rebase
sees a clean tree, and the existing resume machinery runs unchanged.

1. **Two helpers beside `branch_has_output`** (the lane's one "is there work here?"
   layer), per the GSAI-157 spec:
   - `wt_unsaved <dir>` — exit 0 when `git status --porcelain --untracked-files=normal`
     shows anything outside `DEP_ENTRIES` (`node_modules`, `.env*`). Fail-closed: a
     failing `git status` counts as dirty, never `|| true`.
   - `wip_snapshot <dir> <id>` — `add -A` with `DEP_ENTRIES` excluded at any depth
     (secrets never committed), `commit -m "wip(<id>): preserve uncommitted crew output
     (GSAI-157)"`, print the short SHA. `switch -c $BRANCH` first if the worktree is
     detached or on another branch. rc≠0 on any failure.

2. **Insert the rescue immediately before the `RESUMING` check (`crew.sh:~766`):**

   ```bash
   if [[ -d "$WT" ]] && wt_unsaved "$WT"; then
     if [[ "${WT_FORCE_REMOVE:-}" == 1 ]]; then
       echo "    [dev] ⚠ $WT holds uncommitted changes — WT_FORCE_REMOVE=1, removing anyway"
     elif _wip="$(wip_snapshot "$WT" "$ID")"; then
       echo "    [dev] ⚠ rescued uncommitted output in $WT as wip($ID) at $_wip — resuming from it"
     else
       fail "worktree $WT holds uncommitted changes that could not be snapshotted — NOT removing it; inspect and clean it deliberately, then re-greenlight"
     fi
   fi
   ```

   Once the snapshot lands, `git log $base..$BRANCH` is non-empty, so the existing
   resume branch fires. The rebase at `crew.sh:797` then runs on a clean tree. A
   conflicting rebase still aborts with its existing "stale base … CONFLICTS" message,
   and the `wip` commit stays on the branch, so nothing is lost.

3. **Keep the `wip` commit in the merged result.** The design decision is data safety
   over history tidiness (GSAI-157's stated trade-off). The alternative, squashing
   `wip` into the build commit, would rewrite history the Director may already have
   seen and complicate the `task_sha` ancestor check (`DOZER-DESIGN-GSAI-217.md`).

4. **Make the failure classification honest.** The `else` arm labels any failed rebase
   as "stale base … CONFLICTS" or "failed". After step 2 a dirty tree can no longer
   reach it, so the "cannot rebase: unstaged" misreport becomes unreachable. Keep the
   wording otherwise unchanged; the Director already keys on "stale base".

**Behavior change to flag for the Director.** The snapshot runs before the
fresh-start `else` branch as well. A dirty worktree with **no** committed work used to
be `worktree remove --force`d (the GSAI-157 destroy chain). It is now snapshotted, and
its `wip` commit makes it resume. This is the intended GSAI-157 effect, and it is
on-scope because the same insertion point decides it. The success-path guards
(merge-worktree keep, task-worktree snapshot on success) stay in GSAI-157 and are
**not** in this task.

## Alternatives rejected

- **`git rebase --autostash`.** Works for tracked edits in the scratch repo, but leaves
  a stash entry on the **shared** `refs/stash` stack if the reapply conflicts, and
  ignores untracked output (the GSAI-157 LL-20 shape). Violates the shared-stash rule.
- **`git stash push -u` around the rebase.** Same shared-stack problem, plus a
  conflicting `pop` strands work. Rejected.
- **`git checkout -- . && git clean -fd` before rebasing.** Destroys work. Rejected.
- **Skip the rebase when dirty.** Resumes on a stale base and merge-conflicts later.
  This is the GSAI-70 bug the rebase was added to fix. Rejected.

## Edge cases

- **Leftover rebase/merge in progress** (`.git/rebase-merge` from a crashed run):
  `wip_snapshot`'s commit fails. The crew fails closed and names the worktree; it does
  not auto-abort a rebase it did not start. The Director decides.
- **Dep symlinks / secrets:** `node_modules` and `.env*` excluded from both the check
  and the snapshot, so a linked-deps worktree is not "dirty", and no secret is
  committed. A crew-written file literally named `.env` stays uncommitted, on disk.
- **Detached / foreign-branch worktree:** `switch -c $BRANCH` at HEAD; if that fails,
  fail-closed.
- **`DRY_RUN`:** the rescue runs before the stub block, so a dirty dry-run worktree
  gets a `wip` commit and a truthful "resuming" line.
- **Snapshot succeeds, rebase conflicts:** the `wip` commit is preserved; the worktree
  is kept for a Director to resolve. The existing conflict list is still computed from
  porcelain (`--untracked-files=no`), which is accurate once the tree is clean.
- **`WT_FORCE_REMOVE=1`:** a deliberate, Director-set escape for a clean restart. It
  matches the `TEST_GATE` / `DEPS_INSTALL` knob style.

## How it gets tested

New `tests/dev-lane-dirty-resume-test.sh`, modeled on `tests/dev-lane-stale-base-test.sh`
(same `run_crew` harness, same counter that proves whether the model ran):

1. **A — dirty + base moved, no conflict (the bug).** Resume a task with a tracked
   unstaged edit and an untracked file, while `develop` advances on another file.
   Expect the `⚠ rescued … as wip(TEST-…)` line, the `base moved — rebased` line, **no**
   `cannot rebase` text, and a green merge. **Must fail on the unpatched crew** with
   `cannot rebase: You have unstaged changes`. That failure is the pre-fix proof.
2. **B — dirty + base moved, conflicting.** Expect a `stale base … CONFLICTS` failure
   that names the conflicting file, the `wip` commit still on `$BRANCH`, and the
   worktree kept. Nothing discarded (assert `git cat-file -t <wip-sha>` succeeds).
3. **C — dirty + base unmoved.** Expect rescue, then resume as-is with no rebase line.
4. **D — dirty, no committed work (fresh-start shape).** Expect snapshot and resume,
   with the worktree still present afterwards and the tracked edit present in `wip`.
   Confirms the destroy path is closed for this shape.
5. **E — `.env` and `node_modules` present.** Expect neither in the `wip` commit
   (`git show --stat`) and the worktree not treated as dirty for them.

`tests/run-all.sh` globs `tests/*-test.sh`, so no registration is needed.

Verification: `bash tests/dev-lane-dirty-resume-test.sh` must exit 0 post-fix and fail
on A pre-fix; then the full `tests/run-all.sh` must stay green, including the existing
`dev-lane-stale-base-test.sh` (its A/B/C scenarios use clean trees, so they must be
unchanged).

## Files

| File | Change |
|---|---|
| `dozers/dev-lane/crew.sh` | `wt_unsaved` + `wip_snapshot` helpers beside `branch_has_output`; rescue block before the `RESUMING` check |
| `tests/dev-lane-dirty-resume-test.sh` | new — scenarios A–E above |

Not touched: merge-worktree guards, success-path cleanup, `promote.sh`, the reaper
sweep, and `org/config.yaml`. Those are GSAI-157's remaining scope.

## Open question for the Director

Should the GSAI-157 success-path guards land with this change or stay separate? This
design keeps them separate so the rebase fix ships on its own, small and verifiable.
