VERDICT: PASS

# GSAI-254 — review: install decision follows lockfile drift, not node_modules presence

## Evidence

- `bash tests/dev-lane-deps-drift-test.sh` → PASS (23/23 assertions across scenarios 1–6).
- `bash tests/run-all.sh` → `run-all: PASS — 47/47 in 784s`. `run-all.sh` globs `tests/*-test.sh`, so the new test is registered without editing it (the design's "check before editing" item needs no change).

## Spec vs. implementation (against DOZER-DESIGN-GSAI-254.md)

1. **The bug (spec item 1).** `install_deps` no longer returns early on any `node_modules` entry. A dangling or drifted link is removed in the worktree (`rm -f`, no trailing slash, so the host target is never followed) and the install runs in `$d`. Scenario 1 proves `npm ci` runs in the task worktree and in `$MW`, and the gate passes on a develop-only dependency.
2. **Fast path (spec item 2).** A live link with unchanged `package.json` + lockfiles returns 0 before any log or install. Scenario 2 checks the symlink survives, `npm-calls.log` is empty, and no deps line is logged.
3. **Isolation (spec item 3).** Host `node_modules` tree and host marker are byte-identical after the run (scenarios 1, 5). Nested package links are removed before the install and the install does not write through them (scenario 5). The install runs with cwd inside the task worktree (fake `npm` records `pwd`).
4. **Suite green (spec item 4).** 47/47.

Design conformance: `deps_drifted` compares the four inputs with `cmp -s`, missing-on-one-side counts as drift; `deps_stamp` + `.dozer-deps-stamp` implements the post-build re-check; `unlink_nested_deps` uses the `find` shape from `link_deps` with `-type l`; the stamp write failure fails the install; `DEPS_INSTALL=off` removes nothing and logs the same line. The post-build call sites (`:979`, `:1089`, `:1265`) are unchanged and go through `install_deps`, as the design says.

## Non-blocking notes (follow-ups, not failures)

- **Residual agent-write risk (documented in the design).** While a worktree still holds the live host symlink, a build agent that runs `npm install` writes into the host `node_modules`. The post-build stamp check then removes the link and reinstalls, so the gate's result is correct, but the live host checkout was mutated during the build. This is the exact flow that adds dependencies, so it is worth a follow-up. The design already flags it, and the four spec criteria are met, so I am not failing on it.
- **Drifted or dangling link with no worktree lockfile.** The "no lockfile, not installing" branch returns before the link-removal step, so the drifted link stays and the log says "not installing" even though a link exists. The design text suggested removal first. Nothing breaks, and tests run against the host's modules exactly as they did before this change. Cosmetic, but the log line is misleading.
- **Stamp is not removed by pnpm on a failed in-place install.** `pnpm install` does not wipe `node_modules`, so an old stamp can survive a failed install. It still mismatches the new inputs, so the next call reinstalls. The design's claim that "npm ci / pnpm install remove node_modules first" holds for `npm ci` only. Harmless, but the comment in the design is wrong for pnpm.
- **Comments at `crew.sh:163–176` / `:199–212`.** The design asked for these to be updated. They do not describe the old suppression behaviour, so nothing is stale. No change needed.

## Verdict

The implementation follows the architect's plan, meets the four spec criteria, and the full suite is green. The residual agent-write risk is explicitly accepted in the design as a follow-up.
