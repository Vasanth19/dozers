VERDICT: PASS

## Design conformance

The build follows `DOZER-DESIGN-GSAI-257.md` closely:

- `host_checkout_hygiene <dir>` (crew.sh:493-528) replaces the old one-line dirty check
  at the "merge in the existing host checkout" call site (crew.sh:1378), runs the four
  checks in the designed order, and fails closed (via `fail`, which always `exit 1`s)
  on the first problem found, naming it:
  1. Git-dir sanity — `git -C "$d" rev-parse --absolute-git-dir` captured, not discarded.
  2. In-progress operation — rebase-merge/rebase-apply/MERGE_HEAD/CHERRY_PICK_HEAD/
     BISECT_LOG under that git-dir, reusing exactly the markers `wip_snapshot` already
     checks for the task worktree, plus the two new ones the design called for.
  3. Tracked dirtiness — byte-identical failure text to the original check, with
     `git status` stderr now captured (`2>&1`) instead of `2>/dev/null`, so a failing
     read is a named hygiene failure rather than silent "clean".
  4. Untracked debris — reuses the shared `DEP_PATHSPEC` array (crew.sh:730-734) that
     `wt_unsaved`/`wip_snapshot` already build, so node_modules/.env*/pass-artifacts
     stay benign and nothing new had to be invented.
- `hygiene_gate_waiver` (crew.sh:366-374) mirrors `test_gate_waiver`'s shape exactly:
  `HYGIENE_GATE=off`, a `.dozers-no-hygiene-gate` marker (repo or worktree), or
  `no_hygiene_gate: true` via `ecosystem_flag`. Checked first, logs which waiver fired.
- The throwaway-worktree merge path (crew.sh:1382-1386) is untouched, as designed —
  it always starts fresh from `$INTEG`/`$base` and can't carry host debris.
- Hygiene runs after the merge lock is acquired (crew.sh:1363-1366) and before any
  merge/install/test touches the checkout (crew.sh:1378, ahead of `build_backstop`
  and the actual `git merge`) — matches the "nothing to unwind yet, call `fail`
  directly" doctrine and the locking requirement in the design.
- Header comment (crew.sh:41-44) documents the new preflight alongside the existing
  numbered doctrine comments, as specified.
- No changes to `org/config.yaml`, `ecosystem.yaml`'s schema, director templates, or
  lane prompts — matches "Files to touch".
- `tests/run-all.sh` only gained `HYGIENE_GATE` in the env-scrub allowlist; the new
  test file needed no explicit registration since `run-all.sh` globs `tests/*-test.sh`
  (confirmed by reading it — the design flagged this as something to check first).

## Verification performed

Ran the actual test files against the real crew (not just read the diff):

- `tests/dev-lane-host-hygiene-test.sh` — all 5 cases pass (fast path, stray-untracked-
  file block, mid-rebase block, forced `git status` failure named as a read error
  rather than scored clean, both escape hatches).
- `tests/dev-lane-merge-target-test.sh` — passes unmodified/byte-for-byte, including
  case 2's exact dirty-checkout failure message and case 1's "(clean) — merging
  there" log line.
- `tests/dev-lane-greengate-test.sh`, `dev-lane-integration-fallback-test.sh`,
  `dev-lane-stale-base-test.sh` — all pass.
- Ran `tests/run-all.sh` for ~10 minutes (it timed out before the full long-running
  suite finished, but every test up through `dozer-fanout-test.sh`, including every
  dev-lane test, passed with no failures).
- `git status` in the worktree is clean — no test artifacts leaked.

## Minor, non-blocking observation

When the hygiene gate is waived (`HYGIENE_GATE=off` / marker / ecosystem flag) on a
checkout that actually has debris, the crew still logs `$INTEG is checked out at $MW
(clean) — merging there` — the word "clean" is technically inaccurate in that case.
This is pre-existing phrasing reused from the original check and the same pattern the
codebase already accepts for other waivers (e.g. the no-test-gate waiver still lets
downstream code proceed as if gated normally). Not a correctness defect and not worth
blocking on.
