VERDICT: PASS

# GSAI-254 — review: install decision follows lockfile drift, not node_modules presence

## Evidence (re-run in this pass)

- `bash tests/dev-lane-deps-drift-test.sh` → `dev-lane-deps-drift-test: PASS` (23/23 assertions, scenarios 1–6).
- `bash tests/run-all.sh` → `run-all: PASS — 47/47 in 876s`, exit 0.

## Prior blocker is resolved

The previous review (`859000b`) failed the branch for an out-of-scope `org/config.yaml` focus change. Commit `da65478` drops it: `org/config.yaml` is byte-identical to `develop` at HEAD. Nothing else in the diff is out of scope; the files touched are the design doc, the two review/design docs, `dozers/dev-lane/crew.sh`, and the new regression test.

## Spec vs. implementation (against DOZER-DESIGN-GSAI-254.md)

1. **The bug (spec item 1).** `install_deps` no longer returns early on any `node_modules` entry. A dangling or drifted link is removed in the worktree (`rm -f`, no trailing slash, so the host target is not followed), then the install runs in `$d`. Scenario 1 passes: `npm ci` runs in the task worktree and in `$MW`, and the gate resolves the develop-only dependency.
2. **Fast path (spec item 2).** A live link with unchanged `package.json` and lockfiles returns 0 before any log line or install. Scenario 2 passes.
3. **Isolation (spec item 3).** Host `node_modules` tree and marker are byte-identical after the run (scenarios 1, 5). Nested package links are removed before the install and the install does not write through them (scenario 5).
4. **Suite green (spec item 4).** `tests/run-all.sh` passes 47/47.

Design conformance in `dozers/dev-lane/crew.sh`: `deps_drifted` compares the four inputs with `cmp -s`, counting present-vs-absent as drift; `deps_stamp` and `.dozer-deps-stamp` implement the post-build re-check; `unlink_nested_deps` uses the `find` shape from `link_deps` with `-type l`; a stamp-write failure fails the install; `DEPS_INSTALL=off` removes nothing and logs the same line.

## Non-blocking notes (follow-ups, not failures)

- **Agent-write risk (documented in the design).** While a worktree still holds the host symlink, a build agent that runs `npm install` writes into the host `node_modules`. The stamp check reinstalls afterwards, so the gate result is correct, but the host checkout was mutated. Flagged as a follow-up in the design.
- **Test coverage gaps versus the design.** Scenario 3 does not assert that a sibling worktree's link still points at the host. Scenario 4 checks that a post-build `npm ci` ran in the task worktree, but not that there were exactly two calls. Neither gap hides a defect in the code paths I read.
- **Drifted or dangling link with no worktree lockfile.** The "no lockfile, not installing" branch returns before link removal, so the stale link stays and the log says "not installing" even though a link exists. The design text asked for removal first. Cosmetic: the gate runs against the same modules it did before this change.
- **Stamp and pnpm.** `pnpm install` does not wipe `node_modules`, so an old stamp can survive a failed in-place install. It still mismatches the new inputs, so the next call reinstalls. The design's claim that "npm ci / pnpm install remove node_modules first" holds only for `npm ci`.

## Verdict

PASS. The `crew.sh` change follows the design, the regression test passes 23/23, and the full suite passes 47/47. The notes above are follow-ups, not blockers.
