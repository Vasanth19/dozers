VERDICT: FAIL

# GSAI-254 — review: install decision follows lockfile drift, not node_modules presence

## Evidence

- `bash tests/dev-lane-deps-drift-test.sh` → `dev-lane-deps-drift-test: PASS` (23/23 assertions, scenarios 1–6). Re-run in this pass.
- The full `tests/run-all.sh` suite was not re-run in this pass; the prior review's 47/47 claim is unverified here.

## Blocking: out-of-scope change to `org/config.yaml`

The branch changes `org/config.yaml` (the `focus:` block: `until` and `note`). It has nothing to do with the spec and the design says the opposite:

> "No changes to `org/config.yaml`, `ecosystem.yaml`, the director templates, or the lane prompts."  (DOZER-DESIGN-GSAI-254.md, "Files to touch")

The edit also rewrites another actor's decision. It moves the focus window from `2026-10-13` (Fizz's extension, #now thread 99b4c192) back to `2026-10-06`, and replaces the note with a different rationale. Merging it would change what the factory works on, through a dev-lane merge that does not own that decision. The prior review (`f58fb01`) passed the branch without flagging this; that pass missed it.

Required fix: drop the `org/config.yaml` hunk from this branch (restore it to `develop`'s content) and re-review. Nothing else in the diff needs to change for this verdict.

## Spec vs. implementation (against DOZER-DESIGN-GSAI-254.md)

1. **The bug (spec item 1).** `install_deps` no longer returns early on any `node_modules` entry. A dangling or drifted link is removed in the worktree (`rm -f`, no trailing slash, so the host target is not followed), then the install runs in `$d`. Scenario 1 passes: `npm ci` runs in the task worktree and in `$MW`, and the gate resolves the develop-only dependency.
2. **Fast path (spec item 2).** A live link with unchanged `package.json` + lockfiles returns 0 before any log or install. Scenario 2 passes.
3. **Isolation (spec item 3).** Host `node_modules` tree and marker are byte-identical after the run (scenarios 1, 5). Nested package links are removed before the install and the install does not write through them (scenario 5).
4. **Suite green (spec item 4).** Not verified in this pass (see Evidence).

Design conformance in `dozers/dev-lane/crew.sh`: `deps_drifted` compares the four inputs with `cmp -s`, with present-vs-absent counted as drift; `deps_stamp` and `.dozer-deps-stamp` implement the post-build re-check; `unlink_nested_deps` uses the `find` shape from `link_deps` with `-type l`; a stamp-write failure fails the install; `DEPS_INSTALL=off` removes nothing and logs the same line.

## Non-blocking notes (follow-ups, not failures)

- **Residual agent-write risk (documented in the design).** While a worktree still holds the host symlink, a build agent that runs `npm install` writes into the host `node_modules`. The stamp check then reinstalls, so the gate result is correct, but the live host checkout was mutated. The design flags this as a follow-up.
- **Drifted or dangling link with no worktree lockfile.** The "no lockfile, not installing" branch returns before link removal, so the stale link stays and the log says "not installing" even though a link exists. The design text asked for removal first. Cosmetic: tests run against the host modules as they did before this change.
- **Stamp and pnpm.** `pnpm install` does not wipe `node_modules`, so an old stamp can survive a failed in-place install. It still mismatches the new inputs, so the next call reinstalls. The design's claim that "npm ci / pnpm install remove node_modules first" holds only for `npm ci`.

## Verdict

FAIL on the out-of-scope `org/config.yaml` change, which the design explicitly excludes and which rewrites another actor's focus decision. The `crew.sh` change and the regression test meet the spec and pass. Re-review after the config hunk is removed.
