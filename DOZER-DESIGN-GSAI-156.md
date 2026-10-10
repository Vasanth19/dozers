# DOZER-DESIGN-GSAI-156

## Task

> audit-merged.sh cannot see a phantom that was relabelled — CFW-160 hid behind
> dozer:blocked and the audit reported 0 phantom.

## Root cause

`dozers/audit-merged.sh` has exactly one entry point into Linear:
`lin list-merged-dev`, which calls `list_merged_dev()`
(`tasks/_linear_api.py:761`):

```python
def list_merged_dev():
    for i in _all_issues():
        labels = i["labels"]["nodes"]
        if not _has(labels, MERGEDDEV):
            continue
        ...
```

This is a **snapshot of the current label**, not a record of what the issue has
ever claimed. The whole audit is built to catch issues where `dozer:merged-develop`
was written without a real merge behind it (GSAI-119) — but it can only catch that
for issues that are *still wearing the label* at the moment the audit happens to
run. If anything relabels the issue away from `dozer:merged-develop` before the
next audit pass — a Director's manual edit in the Linear UI, a human noticing
something looks wrong and hand-moving it to `dozer:blocked`, or any future code
path that touches labels on a merged-develop issue without going through
`audit_requeue()`/`audit_strip()` — the issue vanishes from the candidate set
entirely. The phantom doesn't get fixed; it just stops being visible. CFW-160 is
exactly this: it carries `dozer:blocked` today, has no `dozer:merged-develop`
label, so `list-merged-dev` never emits a row for it, so `audit-merged.sh` reports
0 phantoms while CFW-160 sits unverified and unrequeued in the Directors'
`dozer:blocked` queue — a queue nobody treats as an audit target, since by
doctrine it's "the Directors' repair queue, never your [Vasanth's] to-do list."

Two smaller, adjacent bugs compound this once an issue *is* caught:

- `audit_requeue()` (`tasks/_linear_api.py:777`) strips `MERGEDDEV` and `INPROG`
  but **not** `BLOCKED`. If a phantom is ever found on an issue that also carries
  `dozer:blocked` (today's only route: an issue that still has both labels at
  once), the repair leaves it with `dozer:ready` **and** `dozer:blocked`
  simultaneously — a label combination `mark_ready()`'s own contract says should
  never exist ("a greenlight now means one thing — queued, nothing else in
  flight").
- There is currently no test covering any of this — `tests/merge-verify-test.sh`
  case 4/4b cover the existing (label-present) phantom path, but nothing exercises
  a relabelled-away phantom.

## Approach

Make the candidate set resilient to relabelling by adding a **second, narrowly
scoped sweep** that targets exactly the blind spot named in the bug: issues
currently sitting on `dozer:blocked` whose Linear label *history* shows
`dozer:merged-develop` was added at some point. This reuses 100% of the existing
verification and repair machinery (`merge_found_in`, `audit_requeue`,
`resolve_repo`) — the only new piece is the candidate-discovery query, which has
to look at history instead of the live label set because that's the one thing
relabelling can't erase.

Deliberately **not** doing a blanket history-scan of every issue in the
workspace: that's unbounded cost (every issue, every history page) for a blind
spot nobody has reported outside this one off-ramp. Scoping to
`dozer:blocked` issues only matches the reported failure mode, keeps the query
count bounded by the existing "Blocked" pile (currently ~100 issues per the
Factory pulse — a few hundred extra GraphQL round trips in a periodic, human-rate
sweep is fine; it is explicitly *not* in the Dozer's hot polling loop). If a
future incident shows the same hide-the-label trick happening via
`dozer:needs-review` or via stripping the label with no replacement at all, that
widens the scope of this same mechanism — noted below as a follow-up, not bundled
into this fix.

### New Linear verb: `list-relabelled-blocked`

In `tasks/_linear_api.py`, next to `list_merged_dev()`:

```python
def list_relabelled_blocked():
    """Every OPEN issue on dozer:blocked whose label HISTORY shows
    dozer:merged-develop was added at some point — the CFW-160 shape (GSAI-156):
    a phantom merge-develop label that got relabelled away before the audit ever
    saw it. Excludes issues that still carry dozer:merged-develop today (those
    already surface via list_merged_dev() — kept disjoint so a row is never
    repaired twice). Row format matches list_merged_dev(): identifier \t team \t
    repo hint \t state type \t lane."""
    label_ids_by_team = {}
    for i in _all_issues():
        labels = i["labels"]["nodes"]
        if not _has(labels, BLOCKED) or _has(labels, MERGEDDEV):
            continue
        tid = i["team"]["id"]
        if tid not in label_ids_by_team:
            label_ids_by_team[tid] = _team_labels(tid).get(MERGEDDEV)
        mdev_id = label_ids_by_team[tid]
        if not mdev_id or not _label_ever_added(i["id"], mdev_id):
            continue
        hint = next((n["name"][len("repo:"):] for n in labels if n["name"].startswith("repo:")), "-")
        print(f'{i["identifier"]}\t{i["team"]["key"]}\t{hint}\t{i["state"]["type"]}\t{_lane_of(labels) or "-"}')
```

`_label_ever_added(issue_id, label_id)` is a small new helper that pages
`issue.history` and checks `addedLabelIds`:

```python
def _label_ever_added(issue_id, label_id):
    cursor = None
    while True:
        d = gql('query($i:String!,$c:String){ issue(id:$i){ history(first:50, after:$c){ '
                'pageInfo{ hasNextPage endCursor } nodes{ addedLabelIds } } } }',
                {"i": issue_id, "c": cursor})
        page = d["issue"]["history"]
        if any(label_id in (n.get("addedLabelIds") or []) for n in page["nodes"]):
            return True
        if not page["pageInfo"]["hasNextPage"]:
            return False
        cursor = page["pageInfo"]["endCursor"]
```

**Implementation note to confirm during the build pass:** `addedLabelIds` /
`removedLabelIds` on `IssueHistory` is the field shape Linear's public schema
documents today. If introspection at build time shows a different field name
(schema drift), that's a one-line fix inside `_label_ever_added` only — nothing
else in this design depends on the exact field name.

Register it in the verb dispatch table (same file, near
`"list-merged-dev": lambda a: list_merged_dev()`):

```python
"list-relabelled-blocked": lambda a: list_relabelled_blocked(),
```

### audit-merged.sh: second pass over the new rows

After the existing loop over `lin list-merged-dev` rows (unchanged), add a second
loop over `lin list-relabelled-blocked` rows, reusing `merge_found_in` and
`resolve_repo` as-is:

```bash
rows2="$(lin list-relabelled-blocked)" || { echo "audit-merged: could not list $LIN list-relabelled-blocked" >&2; exit 1; }

relabelled_ok=0; relabelled_phantom=0
while IFS=$'\t' read -r id team hint state lane; do
  [[ -z "$id" ]] && continue
  repo="$(resolve_repo "$hint" "$team")" || repo=""
  if [[ -z "$repo" || ! -d "$repo" ]]; then
    printf '  ? %-9s UNRESOLVED repo (hint=%s team=%s state=%s) — relabelled-blocked, label left alone, resolve by hand\n' "$id" "$hint" "$team" "$state"
    unresolved=$((unresolved+1)); continue
  fi

  if merge_found_in "$repo" "$id"; then
    printf '  ~ %-9s blocked but merge IS verified on %s (%s) — relabelled away from dozer:merged-develop; leave to the Director, not a phantom\n' "$id" "$(integration_ref "$repo")" "$repo"
    relabelled_ok=$((relabelled_ok+1)); continue
  fi

  printf '  ✗ %-9s PHANTOM (relabelled) — was dozer:merged-develop at some point, now hiding behind dozer:blocked, no merge of %s/%s on %s in %s — strip + requeue%s\n' \
    "$id" "$PREFIX" "$id" "$(integration_ref "$repo" 2>/dev/null || echo '?')" "$repo" \
    "$([[ $DRY == 1 ]] && echo ' [dry-run]')"
  if [[ $DRY == 0 ]]; then
    lin audit-requeue "$id"
    lin comment "$id" "Audit (GSAI-156): this issue carried dozer:merged-develop at some point in its label history, then was relabelled to dozer:blocked before a merge was ever verified — the audit's old pass only scanned issues CURRENTLY wearing dozer:merged-develop, so this phantom hid behind the relabel and was reported as 0 phantom. No merge of ${PREFIX}/${id} exists on $(basename "$repo")'s integration branch. Label stripped, task requeued so the work is actually done.

<!-- dozer-audit by:audit-merged -->"
  fi
  relabelled_phantom=$((relabelled_phantom+1))
done <<< "$rows2"
```

Fold `relabelled_phantom` into the existing `requeued` counter (it's the same
repair action) and report `relabelled_ok` only if nonzero, so the summary line
stays stable for the common case:

```bash
requeued=$((requeued+relabelled_phantom))
...
printf 'audit-merged: %s checked — %s verified, %s phantom requeued, %s closed stripped, %s unresolved%s%s\n' \
  "$total" "$ok" "$requeued" "$stripped" "$unresolved" "$([[ $DRY == 1 ]] && echo ' [DRY RUN]')" \
  "$([[ $relabelled_ok -gt 0 ]] && printf ' (%s relabelled-but-merged left for the Director)' "$relabelled_ok")"
```

### Fix the adjacent label-hygiene gap in `audit_requeue()`

`tasks/_linear_api.py:777` — add `BLOCKED` to the strip list so a repaired
relabelled-phantom never ends up carrying `dozer:ready` + `dozer:blocked` at
once:

```python
def audit_requeue(identifier):
    _relabel(issue(identifier), add=[READY], remove=[MERGEDDEV, INPROG, BLOCKED], state_type="unstarted")
    print(f"{identifier} -> {READY} (phantom {MERGEDDEV} stripped, requeued)")
```

Removing a label that isn't present is already a no-op in `_relabel` (it's an
idempotent set operation elsewhere in this file), so this is safe for the
existing call site too.

## Files to touch

- `tasks/_linear_api.py` — add `_label_ever_added()`, `list_relabelled_blocked()`,
  register `"list-relabelled-blocked"` in the verb table, add `BLOCKED` to
  `audit_requeue()`'s remove list.
- `dozers/audit-merged.sh` — second pass over `list-relabelled-blocked`, update
  the header comment's state-table to mention the relabelled-blocked case, fold
  `relabelled_phantom` into the `requeued` counter, append the
  `relabelled_ok`-left-for-Director note to the summary line.
- `tasks/linear.sh` — add `task_list_relabelled_blocked() { python3 "$_LIN" list-relabelled-blocked; }`
  next to `task_list_merged_dev()`, for consistency with how every other verb is
  exposed (not strictly required by audit-merged.sh, which calls `lin` directly,
  but every other verb has one and a future caller will look for it there).
- `tests/merge-verify-test.sh` — extend case 4's `LINSTUB` to also dispatch
  `list-relabelled-blocked` from a new fixture file, and add a case 4c (see
  Testing below). No new test file — the audit's existing tests already live
  inside this file (case 3/4), not in a standalone `audit-merged-test.sh`.

## Edge cases

- **Issue has both `dozer:blocked` and `dozer:merged-develop` today** (the
  non-relabelled double-label state, possible today because `block()` doesn't
  strip `MERGEDDEV` and `merged()` doesn't strip `BLOCKED`): stays on the
  existing `list-merged-dev` path only — `list_relabelled_blocked()` explicitly
  excludes rows that still carry `MERGEDDEV`, so it's never double-repaired by
  both passes.
- **History shows `dozer:merged-develop` added and later removed by a legitimate
  `done()` close** (Director promoted to main, then closed): `done()` sets state
  to `completed`, which isn't `dozer:blocked`, so this issue was never a
  candidate for the new pass in the first place — only issues currently sitting
  on `dozer:blocked` are scanned.
- **Blocked issue's history shows `dozer:merged-develop` was added, and the merge
  genuinely IS on the integration branch** (e.g. blocked for an unrelated reason
  — budget cap, a later test failure — after a real merge landed): reported as
  `~ ... blocked but merge IS verified`, no mutation. Auto-stripping `dozer:blocked`
  here would silently route around whatever blocked it for the *other* reason —
  fail-fast says report it and let the Director decide, not guess.
- **Issue never had `dozer:merged-develop` in its history at all, just blocked for
  an ordinary crew failure** (the overwhelming majority of the ~100 blocked
  issues today): `_label_ever_added` returns `False`, no row emitted. This is the
  case the bounded blocked-only scope exists to avoid flagging.
- **`_label_ever_added` paginates** — an issue with a long history (many
  relabels, comments, assignee changes) needs more than one page; the helper
  loops on `hasNextPage` the same way `_fetch_team_issues` already does, so it
  doesn't silently truncate the way the pre-GSAI-75 unpaginated issue list did.
- **Team has never had the `dozer:merged-develop` label created** (brand-new
  team, `ensure_label` never ran for it): `_team_labels(tid).get(MERGEDDEV)`
  returns `None`; the loop skips history lookups for that team's issues rather
  than crashing on a missing id.
- **GraphQL schema check**: if Linear's `IssueHistory` doesn't expose
  `addedLabelIds` the way expected (schema drift), `_label_ever_added` is the
  only function that needs to change — confirm via introspection before wiring
  it in, per this file's "fail fast, no silent fallback" rule: a query that comes
  back empty because of a wrong field name must error loudly, not report "no
  history" as if it were a real negative.

## Testing

Extend `tests/merge-verify-test.sh` case 4 rather than adding a new file, since
that's where `audit-merged.sh`'s own tests already live:

1. **Stub update** — `LINSTUB` gets a new case:
   ```
   list-relabelled-blocked) cat "$TMP/audit.blocked.rows" ;;
   ```
2. **Case 4c — relabelled phantom (the CFW-160 shape)**: a fixture row
   `AM-8  CFW  r-real  unstarted  dev` in `audit.blocked.rows`, with repo `r-real`
   having no merge commit for `AM-8` anywhere in its history (same repo fixture
   `$RA` already built for case 4, which has a real merge only for `AM-1`).
   Assert:
   - the log contains `✗ AM-8 *PHANTOM (relabelled)`
   - `audit-requeue AM-8` was called (same `$CALLS` sink already used for AM-2)
   - a `comment AM-8` call was recorded, and its body mentions `relabelled`
3. **Case 4d — relabelled-but-actually-merged**: a fixture row
   `AM-9  CFW  r-real  unstarted  dev`, with a real merge commit for `AM-9`
   added to `$RA` (`git merge --no-ff -m "merge dozer/AM-9 into develop — #AM-9 real"`).
   Assert:
   - the log contains `~ AM-9 *blocked but merge IS verified`
   - **no** `audit-requeue AM-9` or `audit-strip AM-9` call was recorded (no
     mutation on an issue legitimately blocked for some other reason)
4. **Dry-run**: re-run with `--dry-run` over the same fixtures, assert the
   `PHANTOM (relabelled)` line still appears with `[dry-run]` and `$CALLS` stays
   empty — mirrors the existing dry-run assertions for the label-present phantom
   path.
5. **Disjointness**: a fixture row present in BOTH `audit.rows` (still carrying
   `dozer:merged-develop`) and would-be `audit.blocked.rows` is never constructed
   as a test case directly (the production query makes this state unreachable by
   excluding `MERGEDDEV`-carrying issues) — instead assert indirectly: AM-2
   (already covered by case 4, phantom via the *label-present* path) produces
   exactly one `audit-requeue AM-2` call, not two, even with the new pass wired
   in.

No live Linear or network access is needed for any of this — same stub-file
pattern (`AUDIT_LINEAR_API` / `AUDIT_RESOLVER` env seams) the existing tests
already use; `_label_ever_added`'s GraphQL call is inside `tasks/_linear_api.py`,
which the test never invokes directly (it invokes the bash `LINSTUB`, not
Python), so no history-query stubbing is needed at the test level at all — the
history lookup is entirely hidden behind the `list-relabelled-blocked` verb the
stub already fakes with a flat fixture file.

## Out of scope (follow-up, not bundled here)

- Widening the history-scan beyond `dozer:blocked` to cover a phantom that got
  relabelled to `dozer:needs-review`, `dozer:ready`, or stripped to no
  `dozer:*` label at all. Not reported, not bounded the same cheap way (scanning
  *every* issue's history instead of just the blocked pile is a much bigger
  query budget) — raise a follow-up issue if that shape is ever actually seen
  live, same as how GSAI-119 → GSAI-211 → GSAI-213 → GSAI-217 → GSAI-156 each
  added one more verified real-world phantom shape rather than guessing at all
  of them up front.
- Auto-resolving the "blocked but actually merged" sub-case. Left as a reported,
  unmutated line for a Director to triage by hand.
