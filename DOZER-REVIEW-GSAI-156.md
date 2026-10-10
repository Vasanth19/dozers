VERDICT: FAIL

## Summary

The build follows the design's shape closely (new `list-relabelled-blocked` verb,
`_label_ever_added()` history walk, second pass in `audit-merged.sh`, `BLOCKED` added to
`audit_requeue()`'s strip list, tests for the open-issue phantom/verified-but-blocked
cases). But the second pass is missing a state-type guard that the FIRST pass already
has, and that guard is not optional — this codebase has an existing, deliberate
precedent proving closed-but-still-`dozer:blocked` is a real reachable state. As shipped,
the new sweep can reopen a legitimately closed issue.

## Blocking issue: the relabelled-blocked sweep can resurrect a closed issue

`list_merged_dev()`'s consumer (`audit-merged.sh`'s FIRST loop, lines 99–112) explicitly
branches on `state` before doing anything else:

```bash
closed=0; for s in $CLOSED; do [[ "$state" == "$s" ]] && closed=1; done
if (( closed )); then
  ...
  lin audit-strip "$id"      # label-only, state untouched
  stripped=$((stripped+1)); continue
fi
```

`audit_strip()` only removes the label — it never touches state, specifically *because*
a completed/canceled issue must never be reopened (that's the whole Ship-gate hygiene
point the comment at `tasks/_linear_api.py:826-831` makes).

The new SECOND pass (`tasks/_linear_api.py:794` `list_relabelled_blocked()` +
`dozers/audit-merged.sh:136-160`) has no equivalent branch. Its docstring claims "Every
**OPEN** issue on dozer:blocked" but the code never checks `i["state"]["type"]` — it
only checks `_has(labels, BLOCKED)` and label history. And the consuming loop in
`audit-merged.sh` has exactly two outcomes: merge found (report only) or merge not found
→ unconditional `lin audit-requeue "$id"`. `audit_requeue()`
(`tasks/_linear_api.py:816-823`) calls `_relabel(..., state_type="unstarted")`, which
`set_labels_and_state` applies unconditionally regardless of the issue's current state.

So: a canceled/completed issue that still carries `dozer:blocked` (never cleaned up
because it was closed by hand rather than through `done()`) and whose history shows
`dozer:merged-develop` was added at some point gets caught by the new sweep, found
phantom (no merge — that's exactly why it's a phantom), and `audit_requeue()`d: label set
to `dozer:ready`, **state forced back to `unstarted`**. A deliberately closed/dead issue
is silently reopened and requeued into the Dozer's live pipeline.

This is not a hypothetical corner case invented for this review — the codebase already
defends against exactly this state elsewhere. `tasks/_linear_api.py:1501-1502`
(budget-sweep's blocked-issue walk):

```python
for node in _all_issues():
    if node["state"]["type"] in ("completed", "canceled") or not _has(node["labels"]["nodes"], BLOCKED):
        continue
```

That filter only makes sense if closed-but-still-`dozer:blocked` issues are a real,
observed state in this Linear workspace. The design doc's own edge-case list
("History shows merged-develop added and later removed by a legitimate `done()`
close... isn't `dozer:blocked`, so never a candidate") only covers the case where the
engine's own `done()` closed the issue — `done()` does strip `BLOCKED` too
(`tasks/_linear_api.py:721-723`). It does not cover an issue closed by hand in the Linear
UI (exactly the CFW-160 vector this whole task is about — a human/Director relabelling
outside the engine's contracts) while `dozer:blocked` is left in place. That path is
real, precedented in this same file, and unhandled by the new code.

**Fix shape** (small, same pattern as the first loop): either exclude closed issues in
`list_relabelled_blocked()`'s query (mirror the budget-sweep guard), or add the same
`closed` branch to the second `while` loop in `audit-merged.sh` and call `audit-strip`
instead of `audit-requeue` for a closed+blocked+ever-merged-dev row. No test in
`tests/merge-verify-test.sh` case 4c/4d exercises a closed state for the blocked sweep,
so this gap shipped unnoticed.

## Other observations (not blocking)

- `addedLabelIds` on Linear's `IssueHistory` type is the schema the design assumed and
  the build didn't add any introspection check to confirm it against the live API before
  wiring it in, despite the design's own note that this should be "confirmed via
  introspection before wiring it in." Low risk — if wrong, it's an isolated one-line fix
  inside `_label_ever_added()` exactly as scoped — but worth a live smoke-test before this
  ships to a real Dozer run, since nothing in the test suite touches the real Linear API.
- Everything else matches the design closely and is well-covered: disjointness between
  the two passes (AM-2 requeued exactly once), the relabelled-but-actually-merged
  reporting path (AM-9, left alone), dry-run making no mutations, and the `BLOCKED` strip
  added to `audit_requeue()`. The `_fetch_team_issues` / `_all_issues` plumbing change
  (adding `id` and `team{id}`) is correct and doesn't disturb any other caller.
