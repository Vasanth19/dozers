VERDICT: PASS

# Review — GSAI-112 per-repo crew cap at claim time

Branch `dozer/GSAI-112` (2 commits on top of develop: design + build). Reviewed against the
spec in the task and the architect plan in `DOZER-DESIGN-GSAI-112.md`.

## Spec and design conformance

- **Gate order** matches the design: in-flight skip → free slot → group cap (GSAI-169) →
  repo cap (GSAI-112) → launch. The repo check is a `continue` (skip), not a wait or a
  `break`.
- **Config**: `max_per_repo: 2` beside `fanout` in `org/config.yaml`; `MAX_PER_REPO` loads via
  `cfg` with a default of 2 and fails fast (exit 1, names the key and value) on a non-positive-
  integer. Matches the design's "fail fast, not clamp" decision.
- **Identity**: `repo_key_of` keys on the resolved checkout path, uses `task_repo` + `task_team`
  (not `team_of`), reuses `resolve_workdir`, discards resolver stderr, and returns uncapped for
  no identity or an unresolvable identity. Matches design §2 and edge cases 1–2.
- **Live count**: `run_one` writes `repo=` as the sixth field of the owner file in the same
  first write; `repo_live_counts` uses the same three exclusions as `group_live_counts`; legacy
  locks re-derive their key from the task. In-drain increments via `repo_bump` after each
  launch. Matches design §3.
- **Bash 3.2**: parallel indexed arrays (`RKEYS`/`RCOUNT`), no `declare -A`. Verified the
  helper loops fall through correctly under `set -e` (the `&&` inside the `for` cannot abort).
- **Scope**: `tasks/*`, `fanout`, the group caps, the poll/nap logic and the merge path are
  untouched. The reaper reads only `pid=`/`task=`, so the extra line is safe.

## Verification (run in this worktree)

- `bash tests/dozer-repo-cap-test.sh` → **14 ✓, 0 ✗** (capped at 2, other repos not blocked,
  labels kept, log line, once completes all tasks, zero-identity uncapped, unresolvable blocked
  without a slot, team-routed issue shares the repo cap, legacy lock counted, dead lock
  requeued, bad config fails, shipped default is 2).
- `dozer-group-cap-test.sh` → 11 ✓, 0 ✗.
- `dozer-fanout-test.sh` → PASS.
- `dozer-workdir-routing-test.sh` → PASS.

## Non-blocking notes

1. **Unit-level tests from the design are only partly present.** The design asked for a
   `repo_key_of` unit check for hint-only, team-only, both (hint wins), neither and
   unresolvable. The suite covers hint-only (test 1), neither (test 6), unresolvable (test 7)
   and team-only (test 8) end-to-end, but nothing asserts that `hint` wins when both `repo:`
   and a team are present. Worth a one-line addition later; not a correctness gap in the code
   as written (`repo_key_of` checks `hint` first through `resolve_workdir`).
2. **Linear cost per poll.** On the Linear backend, every candidate that reaches the repo gate
   costs two `linear.sh` python calls plus one resolver call. A capped candidate is re-checked on
   every 30 s poll, so a long backlog behind a full checkout re-pays that each tick. The design
   accepts this (it is bounded to candidates past the cheap checks); flagging it so it is a known
   cost, not a surprise.
3. **Legacy-lock fail-open.** During the deploy window, a pre-change lock whose task cannot be
   resolved (e.g. Linear unreachable) counts as zero for its checkout, so the cap can briefly be
   exceeded by that crew. This is short-lived and matches the design's stated behaviour, but it is
   a silent fallback in the CLAUDE.md sense; a `dozer:` log line when `repo_key_of` returns empty
   for a live lock would make it visible.
4. **Log volume (design edge 7).** One `repo cap` line per skipped issue per 30 s poll. This is
   what the spec asked for; the design already flags a once-per-repo-per-drain switch for the
   Director to decide.

None of these blocks the merge. The implementation follows the architect plan, the spec's
invariants are exercised by the new test, and the existing regression suites stay green.
