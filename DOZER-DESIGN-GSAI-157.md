# GSAI-157 — design: uncommitted crew output is rescued, never destroyed — `wip(<ID>)` snapshot + guarded worktree removal

**The bug.** A dev crew's output can sit **uncommitted in its worktree with zero
commits on its branch** — proven live on `dozer/LL-20` (2026-09-16): the branch tip
*was* an integration commit (`git log develop..dozer/LL-20` empty) while
`~/.dozers/worktrees/learnloop-LL-20` held **5 modified + 8 untracked files — 1,382
insertions** of real source, tests, and a QA doc. In that state every branch-based
check scores the task **empty** (GSAI-119's audit, GSAI-156's phantom detection, the
DOC-ONLY check — all ask "what is on the branch?", none asks "is there unsaved work
on disk?"), and the standard cleanup **`git worktree remove --force` destroys the
work with no trace** — not in any commit, stash, or reflog.

The destroy chain lives in `dozers/dev-lane/crew.sh`:

- **the isolation else-branch (`crew.sh:519`)** — the Seance resume check
  (`crew.sh:484`) requires *committed* work (`git log $base..$BRANCH` non-empty).
  A worktree holding only uncommitted output fails it, so the fresh-start path
  runs `git worktree remove --force "$WT"` and erases the LL-20 state before
  `worktree add` rebuilds from scratch. The fail messages even *promise* "worktree
  kept for resume" — but no resume machinery can see uncommitted work.
- **success cleanup (`crew.sh:860-861`)** — after a verified merge, any residue the
  build never committed (untracked files, tracked edits the gates waved through
  because `branch_has_output` counts uncommitted diffs) is force-removed and the
  branch deleted, while the issue is labeled merged-develop on the commits alone.
- **a wedge inside the resume that does fire:** a resume whose worktree holds
  unstaged changes dies at the stale-base rebase ("cannot rebase: You have
  unstaged changes") — the task is unresumable forever while its work sits on disk.

And the standing guidance made it a *procedure*: the shared
`dozer-thrash-remove-worktree` memory (the Directors' runbook for stopping a
thrashing crew) recommended `worktree remove --force` — now amended 2026-09-16 with
a status-check-first warning, but the *tooling* must make the same promise true.

**The fix — one shape: judge the WORKTREE, not just the branch.** Before any
removal, the crew asks `git status --porcelain` (modified **and** untracked — the
LL-20 state was mostly untracked). Dirty → **commit a `wip(<ID>)` snapshot by
default and refuse the removal**; only an explicit force knob removes anyway. The
snapshot lands on the task branch, which means the **existing Seance machinery
takes over**: the resume check now sees the wip commit, the agent is told "prior
work is ALREADY committed — continue from there", and the rebase can no longer die
on unstaged changes. One insertion point, zero new state machines.

## Approach

1. **Two helpers in `crew.sh`, placed beside `branch_has_output`** (same layer —
   the lane's one definition of "is there work here?"):

   ```bash
   # wt_unsaved <dir> — exit 0 when the worktree holds output beyond the dep
   # symlinks the crew itself links (DEP_ENTRIES: node_modules, .env*).
   wt_unsaved() {  # prints the porcelain lines that matter, non-empty = unsaved
     git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null \
       | grep -vE '(^|/|/")(node_modules|\.env|\.env\.local|\.env\.development)(/|"?|$)' \
       | grep -q . && return 0 || return "${PIPESTATUS[0]:-1}"
   }
   ```

   - **Fail-closed:** a `git status` that fails (broken worktree registration,
     transient git blip) returns non-zero from the pipe, and `git status`'s own
     rc propagates — the caller treats "cannot prove clean" as "dirty" (refuse to
     remove). Never `|| true` here: that is the GSAI-154 fail-open class on a
     data-destruction path.
   - **Dep entries are excluded from BOTH the check and the snapshot** — they are
     crew-created symlinks, not crew output; and `.env` files are **secrets — the
     snapshot must never commit them** (Security rule #1). The exclusion list
     derives from the existing `DEP_ENTRIES` array (single source of truth).

   ```bash
   # wip_snapshot <dir> <id> — commit all unsaved output (minus DEP_ENTRIES) as
   # wip(<id>) on $BRANCH, creating the branch at HEAD if the worktree is
   # detached / on another branch. Refuses to run with a dirty-unprovable tree.
   wip_snapshot() {
     local d="$1" id="$2" excl=() e
     for e in "${DEP_ENTRIES[@]}"; do
       excl+=( ":(exclude,glob)$e" ":(exclude,glob)**/$e" )
     done
     [[ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] \
       || git -C "$d" switch -c "$BRANCH" || return 1
     git -C "$d" add -A -- . "${excl[@]}" || return 1
     git -C "$d" commit -q -m "wip($id): preserve uncommitted crew output (GSAI-157)" \
       || return 1
     git -C "$d" rev-parse --short HEAD
   }
   ```

   (Exact plumbing — glob-vs-plain pathspec magic, quoted-path handling — is the
   build pass's to verify against real git; the contract is: dep entries and
   secrets excluded, everything else committed, rc≠0 on any failure.)

2. **Rescue-before-resume — the LL-20 kill, closed.** In the isolate section,
   immediately before the `RESUMING` check (`crew.sh:483`), insert:

   ```bash
   if [[ -d "$WT" ]] && wt_unsaved "$WT"; then
     if [[ "${WT_FORCE_REMOVE:-}" == 1 ]]; then
       echo "    [dev] ⚠ $WT holds uncommitted changes — WT_FORCE_REMOVE=1, removing anyway"
     elif _wip="$(wip_snapshot "$WT" "$ID")"; then
       echo "    [dev] ⚠ rescued uncommitted output in $WT as wip($ID) at $_wip — resuming from it"
     else
       fail "worktree $WT holds uncommitted changes that could not be snapshotted — NOT removing it; inspect and clean it deliberately, then re-greenlight (WT_FORCE_REMOVE=1 removes anyway)"
     fi
   fi
   ```

   - The snapshot makes `git log $base..$BRANCH` non-empty → the existing resume
     branch fires → rebase check, resume prompts, attempt counter, gates all work
     unchanged. The wip commit is *real* output, so the downstream
     `branch_has_output` gate correctly counts it.
   - The force knob is `WT_FORCE_REMOVE=1` (style of `TEST_GATE`/`DEPS_INSTALL`):
   the deliberate escape for a Director who *wants* a clean restart.
   - Because the rescue runs first, the existing `worktree remove --force` at
     `crew.sh:519` now only ever sees worktrees whose content is fully committed
     — and the rescue+fail covers the unprovable case.

3. **The merge worktree (`$MW`), two sites, two semantics:**
   - **pre-creation (`crew.sh:780`)** — a leftover $MW holding unsaved changes is
     a crashed prior run's debris on the integration branch's checkout: snapshot
     is wrong there (it would pollute $INTEG), removal is data loss. Guard: if
     `wt_unsaved "$MW"` and not forced → `fail "merge worktree $MW holds
     uncommitted changes — kept; inspect, then re-greenlight"`. This is
     pre-merge, so nothing is lost and the task is sent back cleanly.
   - **post-merge success cleanup (`crew.sh:859`)** — the green-gate's tests may
     have left untracked debris (or, suspiciously, modified tracked files).
     Keep the worktree, log `⚠ merge worktree kept: uncommitted changes` — the
     merge is already verified by the receipt; the crew still exits 0. The
     reaper sweep (point 5) keeps it visible until a human cleans it.

4. **Success cleanup of the TASK worktree (`crew.sh:860-861`)** — if
   `wt_unsaved "$WT"`: `wip_snapshot "$WT" "$ID"`, then **keep both the worktree
   and the branch** (skip `git branch -D`), log the ⚠ naming the wip SHA, and
   append one line to `$OUT/$ID.summary` — e.g. `⚠ uncommitted residue preserved
   as wip($ID) <sha> — worktree dozer/$ID kept for inspection`. The task still
   reports success (the merge receipt stands); the Director sees the residue in
   the task comment instead of never. Visibility is the other half of
   preservation: LL-20's rescued commit sat on a branch nobody looks at.

5. **`directors/promote.sh:243` `_cleanup()`** — same guard, trap-safe: dirty $MW
   → skip the removal (including the `rm -rf` fallback, which is the *worse*
   variant of the same hazard), `echo` the warning, never fail the promote.

6. **Reaper sweep (`dozers/reaper.sh`) — report-only, spec point 3.** New section
   after the lock sweeps: resolve the worktree root exactly like the crew
   (`WORKTREE_ROOT` env → `worktree_root:` in `org/config.yaml` →
   `~/.dozers/worktrees`), then for every directory under it:
   `git rev-parse --is-inside-work-tree` (skip non-worktrees and `*.state` files
   silently), `git status --porcelain` filtered by the same DEP_ENTRIES exclusion
   (hardcoded there with a keep-in-sync-with-crew.sh comment), and report any
   non-empty one **regardless of branch state** (the empty-branch case is exactly
   the point):
   `! <dir> holds uncommitted changes (N entries: path, path, …) — preserved, not
   removed`. Count them in the summary line (`unsaved-worktrees=N`). A worktree
   whose git commands fail (broken registration) is reported as broken, never
   crashes the sweep — the `_field`/fail-soft idiom already in that file. The
   reaper still never removes anything; the sweep is the standing visibility for
   preserved residue.

7. **Runbook amendments, in-repo (spec point 4):** the shared
   `dozer-thrash-remove-worktree` memory already carries the 2026-09-16
   status-check-first warning — verified, no edit needed there. In-repo:
   - `README.md` Seance box: "persists with its committed work" → committed work
     resumes, **uncommitted output is wip-snapshotted and resumed, never
     destroyed**; the reaper reports worktrees holding unsaved work.
   - `dozers/reaper.sh` header: the "no worktree cleanup is needed here" comment
     gains the sweep sentence.
   - `dozers/dev-lane/dozer.md`: one line under Isolate — a worktree holding
     uncommitted changes is rescued as `wip(<id>)` and resumed; never
     `worktree remove --force` without `git status --porcelain` first
     (`WT_FORCE_REMOVE=1` is the deliberate override).

## Files to touch

| File | Change |
|---|---|
| `dozers/dev-lane/crew.sh` | `wt_unsaved` + `wip_snapshot` helpers; rescue-before-resume block; MW pre-creation guard; success-cleanup guards (MW keep+warn; WT snapshot+keep+summary line); `WT_FORCE_REMOVE` knob |
| `dozers/reaper.sh` | new unsaved-worktree sweep section + summary count; header comment |
| `directors/promote.sh` | `_cleanup()`: dirty $MW → keep + warn (never `rm -rf` over unsaved work) |
| `tests/dev-lane-uncommitted-rescue-test.sh` (**new**) | the regression suite below |
| `tests/reaper-test.sh` | add the unsaved-worktree sweep case (report-only assertions) |
| `README.md`, `dozers/dev-lane/dozer.md` | runbook amendments (point 7) |

`tests/run-all.sh` globs `tests/*-test.sh` — the new suite is picked up with no
registration. No `org/config.yaml` change (`worktree_root` already exists).

## Edge cases

- **Dep symlinks / secrets** — `node_modules`, `.env*` are excluded from both the
  dirty check and the snapshot at any depth (`**/`), so a linked-deps worktree is
  not "dirty" and a `.env` never lands in a wip commit. A genuinely crew-written
  new file named `.env` is (deliberately) not snapshotted — durability never buys
  a secret leak; it stays on disk in the kept worktree.
- **Snapshot failure → fail-closed** — bad git identity, lock, broken worktree:
  the crew fails naming the worktree; nothing is removed. A broken worktree
  (unprovable cleanliness) is treated as dirty, not waved through.
- **Detached / foreign-branch worktree** — `wip_snapshot` `switch -c $BRANCH`
  at HEAD so the rescue is resumable; if that fails, fail-closed as above.
- **Resume rebase (GSAI-70)** — the rescue commits BEFORE the stale-base check,
  so a moved base rebases the wip like any commit; the old "unstaged changes"
  rebase refusal is gone. A conflicting rebase still aborts and reports "stale
  base" with the wip intact — nothing discarded.
- **Existing gates untouched** — `branch_has_output` / proof semantics
  (GSAI-149) are byte-identical; the rescue merely converts uncommitted output
  into a commit the *existing* machinery already understands.
- **`DRY_RUN`** — the rescue runs before the stub block; a dirty dry-run worktree
  gets a wip commit and the DRY_RUN "resume" line, which is truthful, not a hazard.
- **Success-path debris trade-off** — a repo whose *tests* write unignored
  untracked files will keep its task worktree at success (snapshot + ⚠). Data
  safety over disk tidiness; the reaper sweep keeps the residue visible until
  cleaned, and `WT_FORCE_REMOVE=1` exists for a deliberate clean.
- **Concurrency** — worktrees are per-issue; the rescue only touches its own
  `$WT`. The reaper sweep is read-only. The per-project merge lock already
  serializes the merge path.

## How it gets tested

1. **New `tests/dev-lane-uncommitted-rescue-test.sh`** (idiom of
   `dev-lane-no-commit-gate-test.sh`: throwaway repo `main`+`develop`, routed
   stub `claude` on PATH, per-issue artifacts from `TASK_ID`):
   - **RESCUE-TO-RESUME (the headline):** run 1 — stub architect writes NO design
     but leaves a modified `feature.txt` + an untracked `rescued.txt`, exits 1 →
     crew blocks "architect produced no $DESIGN_FILE (worktree kept)". Assert
     the kept worktree is dirty with **zero commits ahead of develop** — the
     LL-20 shape, constructed by the real crew. Run 2 — stub behaves normally:
     assert the log shows the rescue ⚠ + "RESUMING", a `wip(TEST-…)` commit on
     the branch, crew exit 0, **the rescued marker present in `develop`**, and
     the wip commit in develop's merged history. **Against today's code this
     fails at run 2** — the fresh path force-removes the worktree and develop
     never sees the marker (the pre-fix repro the build pass must capture).
   - **SUCCESS-RESIDUE:** single run whose build commits its work AND leaves an
     untracked `residue.txt` → exit 0, merge receipt verifiable, **worktree +
     branch kept**, wip commit containing `residue.txt`, ⚠ line in the log, the
     preservation line in `<id>.summary`.
   - **FORCE:** run 1 as above; run 2 with `WT_FORCE_REMOVE=1` → the ⚠ override
     line, worktree rebuilt fresh, rescued marker absent from develop — the
     hatch does exactly what it says.
2. **`tests/reaper-test.sh`** gains the sweep case under a temp `WORKTREE_ROOT`:
   a clean worktree (not reported), an LL-20-shaped dirty one (modified +
   untracked, empty branch — **reported regardless of branch state**), a
   worktree whose only dirt is a `node_modules` symlink (not reported — the
   exclusion pinned), and a plain non-git directory (skipped, sweep still exits
   0, summary counts `unsaved-worktrees=1`).
3. **Existing suites stay green** — the dev-lane tests that re-run crews
   (timeout, model-exit, no-commit-gate, stale-base, collision) now pass through
   the rescue on their kept worktrees; where a stub deliberately leaves
   uncommitted residue, the rescue legitimately fires and any assertion that
   breaks is adjusted to the new truthful log — intent preserved. **Pre-fix
   repro recorded** (run the new suite against the unpatched `crew.sh`, capture
   the ✗), then **full gate**: `make test` (run-all.sh, scrubbed env) green
   end-to-end — in-crew included, which is the green-gate's own proof.

**Out of scope, deliberately:** reviewing/merging LL-20's rescued work (spec:
its real blocker is human on-device QA, unchanged); changing
`branch_has_output`/proof semantics to see untracked files *within* a run
(GSAI-149's contract — the rescue closes the loop across runs instead);
migrating or pruning stale worktrees (the sweep reports; cleanup stays human).