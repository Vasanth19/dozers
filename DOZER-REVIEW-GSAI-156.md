VERDICT: PASS

## Summary

This is a re-review after the prior pass (518d7e1) FAILed on a real defect: the new
relabelled-blocked sweep could force a hand-closed issue's state back to `unstarted`,
reopening dead work. Commit 99c0ac4 fixes it with two independent layers, both verified
by running the suite directly (`bash tests/merge-verify-test.sh`) — all cases pass,
including the new regression test for this exact shape.

## What changed since the FAIL

1. **Data-source level** (`tasks/_linear_api.py:803-806`) — `list_relabelled_blocked()`
   now skips any issue whose `state.type` is `completed` or `canceled` before it ever
   checks `BLOCKED`/`MERGEDDEV`. A closed+blocked+ever-merged-dev issue (the shape the
   FAIL review identified, precedented by the budget-sweep guard at
   `tasks/_linear_api.py:1505`) is never emitted as a row at all.
2. **Consumer level** (`dozers/audit-merged.sh:146-164`) — the second loop now has the
   same `closed` branch as the first loop: a closed row gets `audit-strip` + a comment,
   never `audit-requeue`. Since layer 1 already filters these out, this branch is
   defense-in-depth (matches the FAIL review's two suggested fix shapes — the build did
   both rather than choosing one, which is fine here).
3. **New test** — case 4e (`tests/merge-verify-test.sh:403-420`) feeds a fixture row
   `AM-10 CFW r-real completed dev` directly into `audit.blocked.rows` (bypassing the
   python-level filter, so it genuinely exercises the bash-level guard in isolation) and
   asserts `audit-strip` fires, `audit-requeue` never does, and state is left alone.

Ran the full suite locally: `merge-verify-test: PASS`, every case including 4c/4d/4e
green. The specific regression — "AM-10 was requeued — a closed issue would be
reopened" — does not fire.

## Non-blocking observation: the bash-level closed branch is effectively dead code with a cosmetic inaccuracy

Because layer 1 (the python filter) already excludes `completed`/`canceled` issues
before `list-relabelled-blocked` emits a row, the bash `closed` branch added at
`dozers/audit-merged.sh:148-164` can never actually run against real data — only
against a hand-built test fixture that bypasses the python query, as case 4e does. That
in itself is fine (harmless defense-in-depth).

But if it ever did run, it wouldn't do what its own message claims. `lin audit-strip`
→ `audit_strip()` (`tasks/_linear_api.py:822-825`) only removes `dozer:merged-develop`.
A row reaching this branch is, by construction, one that does **not** currently carry
`dozer:merged-develop` (that's what "relabelled away" means, and it's also the
disjointness filter against `list_merged_dev()`). So `audit_strip` on one of these rows
removes a label that was never there — a no-op write — and `dozer:blocked` (the label
actually printed as "strip label" in the log line) is never touched. The issue would
keep sitting on `dozer:blocked` forever. The `stripped` counter increments and a comment
posts, but nothing is actually stripped.

This doesn't cause harm — it correctly declines to reopen anything, which is the bug
this review cycle exists to fix — and it's unreachable in production today, so it's not
blocking. Worth a follow-up cleanup (either drop the now-redundant bash branch since the
python filter already handles it, or fix `audit_strip` to also remove `BLOCKED` for this
path) but not worth another FAIL cycle over.

## Other observations (carried forward, still accurate)

- `addedLabelIds` on Linear's `IssueHistory` schema is still unverified against the live
  API by introspection — same note as the prior review. Low risk, isolated to
  `_label_ever_added()` if wrong, but smoke-test before this runs against real Linear.
- Disjointness between the two passes, the relabelled-but-actually-merged reporting path
  (AM-9), dry-run making no mutations, and the `BLOCKED` strip added to
  `audit_requeue()` all remain correct and well-covered.
