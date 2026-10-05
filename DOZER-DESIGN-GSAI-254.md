# GSAI-254 — design: the install decision follows lockfile drift, not the mere presence of `node_modules`

**The bug.** `link_deps()` (`dozers/dev-lane/crew.sh:176`) symlinks the host checkout's
`node_modules` into every task worktree and every merge worktree. `install_deps()`
(`crew.sh:213`) then returns early on `[[ -e "$d/node_modules" ]]`. So the host's
`node_modules` permanently suppresses the install, and that `node_modules` belongs to
whatever branch the host checkout happens to sit on — not to `develop`, and not to the
branch under test. A dependency added on the integration branch can never be installed
into a worktree: `Cannot find module 'heic-convert'` on every cfw-social dev task
(CFW-347, CFW-348 held behind it).

## Approach

Make the install decision depend on **drift between the worktree's install inputs and
the host's**, not on whether a `node_modules` entry exists.

1. **Drift predicate — `deps_drifted <dir>`** (new, beside `install_deps`). Returns 0 when
   any install input at `$d` differs from the same relative path under `$WORKDIR`:
   - the lockfile chosen by the existing precedence (`pnpm-lock.yaml` →
     `package-lock.json` → `yarn.lock`), and
   - `package.json`.
   "Differs" includes *present on one side, absent on the other*. Compare with
   `cmp -s` on the two files; a missing file on both sides is equal. Reference is
   `$WORKDIR` (the same source `link_deps` uses), never the branch name.
   Package.json is compared too (spec names the lockfile only): a `package.json` change
   with an unchanged lockfile is cheap to reinstall, and skipping it would reproduce the
   bug for workspace manifests. This is a judgment call — see "Choices".

2. **`install_deps` decision order** (today's order kept wherever the behaviour is
   unchanged):
   1. no `package.json` → return 0 (unchanged).
   2. `DEPS_INSTALL=off` → log `deps install off`, return 0 (unchanged — the symlink is
      left alone, nothing is written).
   3. `node_modules` is a **live symlink** (`-L` and `-e`) and `deps_drifted` is false →
      return 0. **This is the common fast path; it must run no install and log nothing new.**
   4. `node_modules` is a **symlink that is dangling or drifted** → remove the link
      *in this worktree only* (`rm -f "$d/node_modules"` — no trailing slash, no `-r`, so
      the host target is never followed), log one explicit line naming the reason and
      the host path, and fall through to the install.
   5. `node_modules` is a **real directory** → return 0 *unless* its install stamp says
      the inputs changed since it was installed (see step 4 below). Real dirs are the
      worktree's own; the host's `node_modules` is never a real dir inside a worktree
      because `link_deps` only ever creates links.
   6. install as today (`pnpm install --frozen-lockfile --prefer-offline` / `npm ci` /
      `yarn install --frozen-lockfile`), timeboxed by `$T_DEPS`, log to `$OUT/$ID.deps-<stage>.log`.
      The install runs in `$d`, so it writes only inside its own worktree.

3. **Nested package symlinks.** `link_deps` also links `packages/*/node_modules` into the
   worktree. When the root install is replaced, a stale nested link into the host would
   let the workspace install write through the symlink into the live host checkout, and
   the tests would still see the host's packages. So step 4 also removes every nested
   `node_modules` **symlink** under `$d` (same `find` shape as `link_deps`, `-type l`
   filter, `-maxdepth 5`, never descending into a `node_modules` or `.git`). Real nested
   dirs are left alone.

4. **Stamp — re-decide after the build pass.** The build pass can change the lockfile, and
   the crew calls `install_deps` again after it (`crew.sh:1031`). Once step 4 has
   replaced the link with a real dir, step 5 would return 0 and the post-build call would
   test against stale modules. So a successful install writes
   `$d/node_modules/.dozer-deps-stamp` containing `cat package.json <lockfile> | cksum`
   (`cksum` is POSIX on darwin and linux). Step 5 compares the current inputs' checksum
   with the stamp: match → return 0; mismatch → reinstall in place. A real dir with **no**
   stamp (agent-installed, or a dir from before this change) keeps today's behaviour:
   return 0. The stamp is written only after a successful install, and never into
   `$WORKDIR` (install_deps is only ever called on worktrees).

5. **Call sites — no change required.** `crew.sh:921` (pre-build), `:1031` (post-build,
   stamp check does the work), `:1207` (green-gate on the post-merge `$MW`) all go through
   `install_deps`. `link_deps "$MW"` at `:1194` already runs after the merge, so the
   merge worktree's lockfile is the post-merge one. The green-gate's failure path is
   unchanged: an install failure still reverts the merge and reports the install.

## Files to touch

- `dozers/dev-lane/crew.sh` — add `deps_drifted`; change `install_deps` (steps 1–6 above);
  add the nested-symlink removal helper; comments updated where they describe the old
  "symlink suppresses install" behaviour (`crew.sh:163–176`, `:199–212`).
- `tests/dev-lane-deps-drift-test.sh` — **new**, regression test (below).
- `tests/run-all.sh` — register the new test if it enumerates explicitly rather than globbing
  (check before editing).

No changes to `org/config.yaml`, `ecosystem.yaml`, the director templates, or the lane prompts.

## Edge cases

- **Host on any branch.** The reference is `$WORKDIR`'s files at the same paths; the
  host's branch name is never consulted, so the fix is independent of Vasanth's checkout.
- **Host has no lockfile at the path; worktree adds one** → present-vs-absent counts as
  drift → real install. Host has the file and worktree deleted it → drift → install
  (the lockfile-less branch then hits the existing "no lockfile, not installing" log).
- **Dangling host symlink** (`node_modules` target removed) → treated as drifted: link
  removed, install runs. Today `[[ -e ]]` is false and the install runs with the dead link
  still present, which `npm ci` may trip over; the explicit removal avoids that.
- **`DEPS_INSTALL=off`** → nothing removed, nothing installed, same log as today.
- **Post-build lockfile change on a fast-path symlink** → step 3 re-runs `deps_drifted`
  against the host, so it still triggers.
- **Stamp write failure** (disk full mid-install) → the install failed, so no stamp is
  written and the next call reinstalls. A stale stamp cannot survive a failed install
  because `npm ci` / `pnpm install` remove `node_modules` first and the stamp lives inside it.
- **Host `node_modules` is not a symlink target of this worktree** (e.g. the host is itself
  the worktree, `d == WORKDIR`) → `link_deps` returns early; the real dir has no stamp and
  returns 0, as today.

## Testing

**Regression — `tests/dev-lane-deps-drift-test.sh`**, same harness as
`tests/dev-lane-greengate-deps-test.sh`: throwaway repo, fake `npm` on `PATH`, the real
crew driven through `run_crew`. The fake `npm ci` writes `node_modules/.installed` and,
only when the lockfile names `heic-convert`, `node_modules/heic-convert.marker`; it also
appends each invocation to `$TMP/npm-calls.log`. The stub test script requires
`node_modules/heic-convert.marker`, so it fails exactly like a missing module.

Scenarios (each asserts the **gate passes**, plus the specific claim):

1. **The bug (spec item 1).** Host checkout on branch A (lockfile without the package,
   `node_modules` with `.installed` only). Worktree branch B adds the package to
   `package.json` + lockfile. Expect: `npm ci` ran in the task worktree and in `$MW`,
   the marker exists in the worktree, the gate resolves it and the merge lands. Today this
   fails at the test gate.
2. **Unchanged lockfile keeps the fast path (spec item 2).** Host and worktree share the
   lockfile. Expect: `node_modules` is still a symlink to the host afterwards, the
   `npm-calls.log` is empty, and the log has no `drift` line.
3. **Isolation (spec item 3).** Snapshot the host `node_modules` tree (`find … | cksum`)
   and the host lockfile before the run and after it; they are byte-identical. A sibling
   worktree's `node_modules` link still points at the host and its tree is unchanged. Also
   assert the install ran with cwd inside the task worktree (the fake `npm` records `pwd`).
4. **Post-build drift.** The stub agent changes the lockfile during the build pass (adds
   the package on a branch whose host already matches develop). Expect: pre-build install
   from the old lockfile, then a second `npm ci` after the build (`npm-calls.log` has two
   lines for the task worktree), and the post-build test passes.
5. **Nested package symlink.** A monorepo fixture (`packages/web/node_modules` symlinked
   from the host) where the root lockfile drifts. Expect: the nested symlink is gone
   before the install and the install did not write through it (host's
   `packages/web/node_modules` is unchanged).
6. **`DEPS_INSTALL=off`.** Drifted lockfile, `DEPS_INSTALL=off`. Expect: symlink left
   intact, no `npm` call, log `deps install off`, as before.

Also run the whole existing dev-lane suite — `dev-lane-greengate-deps-test.sh`,
`dev-lane-monorepo-deps-test.sh`, `dev-lane-merge-target-test.sh`,
`dev-lane-greengate-test.sh`, `dev-lane-test-gate-test.sh` — because they exercise
`install_deps` and `link_deps` on the same paths. "Repo test suite stays green" (spec
item 4) means `tests/run-all.sh` passes.

## Out of scope / residual risk

- **An agent-run install through an unchanged-lockfile symlink can still write the host.**
  If the build agent changes the lockfile and runs `npm install` while `node_modules` is
  still the host symlink, that write lands in the host `node_modules`. The stamp check
  only detects the lockfile change afterwards. The fix would be to replace every
  symlink before the build pass, which costs the fast path. Flagged as a follow-up, not
  fixed here; the spec's regression scenario is covered.
- Which branch the host checkout sits on (spec: out of scope).
- Re-greenlighting CFW-347 / CFW-348 (spec: held until this lands).

## Choices made (for Guzz to redirect)

- Drift inputs = `package.json` **and** the lockfile (spec named the lockfile only).
- Stamp file for the post-build re-check — beyond the spec's four criteria, but without
  it the post-build call silently tests stale modules for any task that adds a dep.
- Nested `node_modules` symlinks are removed on a replaced root install (not in the spec).
- The residual agent-write risk above is documented, not fixed.
