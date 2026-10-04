# DOZER-DESIGN-GSAI-112 — per-repo crew cap at claim time

Task: `fanout: 5` is a global cap and the group caps (GSAI-169) are per team. Nothing
stops five crews from cutting `dozer/<id>` worktrees off the same repo's `develop` at
once. Live case: nine `repo:cfw-social` issues `dozer:ready`, all five slots filled from
one repo, and the stale-base merges that follow.

## Approach

Add a third claim-time gate in `drain()`, after the global slot check and the existing
group cap, before `run_one` is launched:

    in-flight skip → free slot → group cap (GSAI-169) → repo cap (GSAI-112) → launch

It is a skip, never a wait. The `while read` loop already walks the whole ready list
once with `continue`; a refused issue keeps its labels and is seen again on the next
poll. No `break`, no retry of the head, so the ordering trap does not apply.

### 1. Config

- `org/config.yaml`: top-level `max_per_repo: 2` next to `fanout`, with a comment.
- `dozer.sh`: `MAX_PER_REPO="${MAX_PER_REPO:-$(cfg max_per_repo)}"`, default 2 when the
  key is absent, same shape as `FANOUT`.
- Validation is fail-fast (CLAUDE.md doctrine), not the `FANOUT` clamp: a value that is
  not a positive integer prints the exact key and value to stderr and exits 1 before the
  loop starts. A silent clamp would hide a typo.
- `max_per_repo` only narrows `fanout`. It is checked after the global free-slot check,
  so it never adds a crew.

### 2. Repo identity — the resolved checkout path

The key is the **resolved checkout path**, not the `repo:` label string. Two routes can name
one checkout (`repo:cfw-social` and the team default for CFW). The cap is about the shared
`develop`, so the path is the right unit. The display name is `basename(path)`.

A new helper `repo_key_of <id>` in `dozer.sh`:

    hint="$(task_repo "$id" 2>/dev/null || true)"
    team="$(task_team "$id" 2>/dev/null || true)"
    # no identity → empty key (uncapped; see Edge cases)
    [[ -n "$hint$team" ]] || return 0
    workdir="$(resolve_workdir "$hint" "$team" 2>/dev/null)" || return 0   # unresolvable → uncapped
    printf '%s' "$workdir"

It reuses `resolve_workdir` so the rule is the same one `run_one` uses (`repo:` alone, then
team default, never a silent fallback). It calls the backend's `task_team`, **not**
`team_of "$id"`. For the files backend the id prefix is not a team, and the resolver would
fail on it. Resolver stderr is discarded here on purpose: `run_one` re-resolves and blocks
the issue with the real reason, so the error is reported once, in the place that owns it.

Cost: for each candidate that reaches this gate, one `task_repo`, one `task_team` and one
`ecosystem_workdir.py` call. These run only after the free-slot and group checks pass, so
the `queued` and `capped` issues cost nothing extra. Each candidate is looked up at most
once per drain.

### 3. Live count — `repo=` in the lock owner file

`run_one` already writes `$lock/owner` before anything else. The key is known in `drain()`
before the launch, so it is passed as a sixth argument and written into the same first
write:

    pid=…  host=…  task=…  lane=…  ts=…  repo=<resolved path>

Counting then needs no Linear or resolver calls. `repo_live_counts` mirrors
`group_live_counts` exactly (same exclusions: `director-*.lock`, no `owner`, dead pid), and
groups the live locks by their `repo=` value. The reaper reads only `pid=` and `task=`, so
one more line does not change it.

Two details:

- **In-drain increments.** `drain()` snapshots the per-repo counts once and increments them
  as it launches, like `gcount` does today. This covers the window before a backgrounded
  crew has written its owner file.
- **Legacy locks.** A lock from before this change has no `repo=` line. Its key is taken as
  `repo_key_of "$task"` (the same resolver call), and the lock is counted only if it is live.
  This runs only for locks that existed across a deploy, so it is a short-lived path.

### 4. The gate and the log

    if [[ -n "$rkey" ]] && (( ${rcount:-0} >= MAX_PER_REPO )); then
      echo "  ~ repo cap: ${rkey##*/} at ${rcount}/${MAX_PER_REPO}, skipping $id"
      continue
    fi

- Logged per skip, as the spec asks: `  ~ repo cap: cfw-social at 2/2, skipping CFW-214`.
- The skipped issue takes no slot and does not touch the group count. A group count is
  incremented only on a real launch.
- Repo counts live in two parallel indexed arrays (`RKEYS`, `RCOUNT`), not an associative
  array. `dozer.sh` already avoids `declare -A`, and macOS `/bin/bash` is 3.2.

### 5. Crash recovery

No change. `recover` (reaper) runs before `drain` in `once` and at the top of each `loop`
tick. A stranded `dozer:in-progress` with no live lock is requeued, and its repo count drops
on the next `repo_live_counts` snapshot because only live pids are counted.

## Files to touch

| File | Change |
|---|---|
| `org/config.yaml` | `max_per_repo: 2` beside `fanout`, with the comment block |
| `dozers/dozer.sh` | `MAX_PER_REPO` load + validation; `repo_key_of`; `repo_live_counts`; `drain()` gate; `run_one` takes arg 6 and writes `repo=` into the owner file; header comment (config list) |
| `tests/dozer-repo-cap-test.sh` (new) | regression, modelled on `dozer-group-cap-test.sh` |
| `tests/run-all.sh` | none expected — it globs `tests/*-test.sh` |

Not touched: `tasks/*` (no adapter change, no new backend verb), `fanout`, `fanout_by_group`,
the poll and nap logic (GSAI-110), the merge path, labels, and Linear state.

## Edge cases

1. **Zero identity** (no `repo:` and no team; the files-backend default). Uncapped. The repo
   is the engine's own checkout, so there is no shared `develop` for a stampede to hit, and
   `fanout` plus the group caps still bound it. This keeps `dozer-group-cap-test.sh` and
   `dozer-fanout-test.sh` valid, because their tasks have no identity and their 4-crew
   expectations stay true. Without this exemption, two-per-repo would collapse the whole
   files-backend fleet to two crews.
2. **Unresolvable identity** (`repo:` names no registry entry, or the team has no default).
   Uncapped at this gate. `run_one` then blocks it before any crew or worktree exists, as it
   does today. The cap never hides a routing error.
3. **Two labels, one checkout.** Keyed by path, so they share a cap. Intended.
4. **Mixed queue** (9 cfw-social + 1 gsai ready, fanout 5). Walk order is KR date then
   priority. The cfw-social issues fill two slots, the gsai issue takes a third, and the rest
   are skipped with a log line. Other repos are never blocked by a full one.
5. **Repo cap and group cap both apply.** Checked in that order. The cheap group check runs
   first, so a group-capped issue never costs a Linear or resolver call.
6. **`MAX_PER_REPO` ≥ `fanout`.** Harmless, since the global check comes first. Not warned.
7. **Log volume.** While a backlog sits behind the cap, every 30 s poll prints one line per
   skipped issue. With 7 skipped that is about 840 lines/hour, which is noisy. The spec asks
   for one line per skip, so I am following it. If that is too loud, the change is a one-line
   switch to once-per-repo-per-drain, as the group cap does. **Decision for the Director to confirm.**

## How it gets tested

New `tests/dozer-repo-cap-test.sh`. It runs the real `dozer.sh` on the files backend from a
throwaway copy, with a `nap` lane, the same way `dozer-group-cap-test.sh` does. A fake
registry comes in through `ECOSYSTEM_REGISTRY` (the seam `dozer-workdir-routing-test.sh`
already uses). Fake repo dirs live under the temp dir. Tasks carry `repo:` frontmatter, which
`task_repo` reads on the files backend.

Invariants:

1. **Capped.** Six ready issues on `repo:alpha` with `MAX_PER_REPO=2` → exactly 2 live crews
   with `repo=…/alpha`, however long the drain runs.
2. **Not blocking.** Two ready issues on `repo:beta` sit at the bottom of the queue. They are
   claimed in the same drain that refuses the fourth alpha issue. The global fanout (5) is
   not reached, so the other repos still get slots.
3. **Unchanged labels.** Skipped alpha issues stay in `ready/` with their frontmatter intact.
4. **Logged.** One `  ~ repo cap: alpha 2/2, skipping <ID>` line per skip, with the right ID.
5. **Progress.** `once` finishes every task. The cap throttles concurrency, not completion.
6. **Zero identity uncapped.** Tasks with no `repo:` run up to `fanout`, unchanged.
7. **Unresolvable uncapped and blocked.** `repo:ghost` (not in the registry) is blocked by
   `run_one` with the resolver reason, and it does not consume a repo slot.
8. **Legacy lock.** A live lock with no `repo=` line counts toward its resolved repo.
9. **Config fail-fast.** `max_per_repo: banana` makes the engine exit 1 with the key named.
10. **Crash recovery.** A stranded `in-progress` with no live lock is requeued, and its repo
    count drops, so the next poll claims again.

Regression: `dozer-group-cap-test.sh`, `dozer-fanout-test.sh` and
`dozer-workdir-routing-test.sh` must stay green unchanged. The full suite is `make test`.

Unit-level: `repo_key_of` for hint-only, team-only, both (hint wins), neither (empty), and
unresolvable (empty), against a fixture registry.

## Open questions

- Log volume (edge 7). I am following the spec's one-line-per-skip wording. Confirm, or ask
  for the once-per-repo-per-drain form.
- Default `max_per_repo: 2`. Taken from the spec. It is tunable in config.
