# DOZER-DESIGN-GSAI-217

## Task

`dozers/verify-merge.sh` (GSAI-119) only checks that the receipt's `merge_sha` exists
and is an ancestor of the integration branch. That is necessary but not sufficient, and
on 2026-09-28 it rubber-stamped two different non-merges within one hour:

- **Hatch 1 (GSAI-211):** the proof line named a sha that was already on `develop`
  *before the crew ran* (`git merge --no-ff` found nothing to merge — "Already up to
  date" — and never created a commit). "Is this sha on develop?" is trivially true for
  any pre-existing sha, so a no-op pass (the agent committed nothing) passes.
- **Hatch 2 (GSAI-213):** a real merge commit landed, but its entire diff was
  `DOZER-DESIGN-*.md` + `DOZER-REVIEW-*.md` — the crew's own paperwork, not the task's
  code. The branch was deleted on cleanup, so the real work (if any was ever written)
  is unrecoverable. The verifier confirms a merge *exists*; it never looks at *what's
  in it*.

Both landed as PROMOTE rows on Vasanth's Ship gate.

## Root cause

`verify-merge.sh`'s receipt (`branch=`, `merge_sha=`) only records the *destination*
fact ("this sha is reachable from this branch"), never the *delta* fact ("this sha is
new, and here's what it changed"). Both hatches are the same gap from two angles: the
verifier has no notion of "before" (hatch 1) or "contents" (hatch 2).

## Approach

### 1. Receipt carries the delta, not just the destination (`dozers/dev-lane/crew.sh`)

Today (around the merge in §3 of the refinery, ~line 1113-1182):
```
PREMERGE="$(git -C "$MW" rev-parse HEAD)"
git -C "$MW" merge --no-ff "$BRANCH" -m "..."
...
MERGE_SHA="$(git -C "$MW" rev-parse HEAD)"
printf 'branch=%s\nmerge_sha=%s\n' "$INTEG" "$MERGE_SHA" > "$OUT/$ID.merge"
```
`PREMERGE` already exists as a local var — it's just never captured anywhere
persistent. Add one more capture right before the merge:
```
TASK_TIP="$(git -C "$WT" rev-parse HEAD)"     # tip of dozer/<ID> at merge time
```
and extend the receipt to four fields:
```
printf 'branch=%s\nmerge_sha=%s\npremerge_sha=%s\ntask_sha=%s\n' \
  "$INTEG" "$MERGE_SHA" "$PREMERGE" "$TASK_TIP" > "$OUT/$ID.merge"
```
`premerge_sha` is $INTEG's tip *before* this pass touched it; `task_sha` is the
`dozer/<ID>` branch's tip at merge time (the branch itself is deleted on cleanup a few
lines later, so this is the only surviving reference to "what this pass actually
built"). Both are facts the crew already has in hand — no new git calls, no new
spend.

**Design-only opt-out** (spec requirement: "never by default"). Immediately before
writing the receipt, resolve whether this issue is allowed to ship docs-only:
```
DESIGN_ONLY=0
[[ "${DESIGN_ONLY:-0}" == "1" ]] && DESIGN_ONLY=1        # explicit env override, one run
dlabel="$(crews_get design_only_label)"; dlabel="${dlabel:-design-only}"
while IFS= read -r l; do [[ "$l" == "$dlabel" ]] && DESIGN_ONLY=1; done \
  < <(crew_meta_field label)
printf 'design_only=%s\n' "$DESIGN_ONLY" >> "$OUT/$ID.merge"
```
This reuses the exact `crew_meta_field label` / `crews_get` pattern already used for
`lite_when_label` (crew.sh ~L417-452) — same data source (`DOZER_CREW_META`, which
`dozer.sh` already populates with `label\t<name>` lines), same config convention
(`org/config.yaml` → `crews: design_only_label:`, defaulting to `design-only`), no new
plumbing between the engine and the crew.

### 2. `verify-merge.sh` checks the delta, not just the destination

After the existing ancestor check (ok today), add two new checks, in order:

**Hatch 1 — reject a sha that isn't new:**
```
PREMERGE="$(grep -E '^premerge_sha=' "$RECEIPT" | head -1 | cut -d= -f2)"
TASK_SHA="$( grep -E '^task_sha='    "$RECEIPT" | head -1 | cut -d= -f2)"
[[ -n "$PREMERGE" && -n "$TASK_SHA" ]] || { echo "receipt missing premerge_sha/task_sha — cannot confirm this merge is NEW, not a pre-existing sha (GSAI-211 no-op signature); re-greenlight to get a receipt in the current format"; exit 1; }
```
then, after confirming `SHA` exists and `cat-file -e` succeeds (reuse the existing
checks — no duplicate logic):
```
[[ "$SHA" != "$PREMERGE" ]] \
  || { echo "receipt claims merge $SHA, but that is $BRANCH's PRE-EXISTING tip (GSAI-211): the crew's merge was a no-op — \`git merge --no-ff\` found nothing to merge because the pass committed no changes. Not labeling merged."; exit 1; }
git -C "$WORKDIR" merge-base --is-ancestor "$PREMERGE" "$SHA" 2>/dev/null \
  || { echo "receipt's premerge_sha ($PREMERGE) is not an ancestor of merge_sha ($SHA) — the receipt is internally inconsistent, refusing to trust it"; exit 1; }
git -C "$WORKDIR" cat-file -e "$SHA^{commit}" 2>/dev/null \
  && [[ "$(git -C "$WORKDIR" rev-list --min-parents=2 --max-count=1 "$SHA" 2>/dev/null)" == "$SHA" ]] \
  || { echo "merge_sha $SHA is not a 2-parent merge commit — cannot confirm it is the merge this pass performed"; exit 1; }
git -C "$WORKDIR" merge-base --is-ancestor "$TASK_SHA" "$SHA" 2>/dev/null \
  || { echo "receipt's task_sha ($TASK_SHA, the dozer/$ID branch tip) is not an ancestor of merge_sha ($SHA) — the merge does not actually contain this pass's branch"; exit 1; }
```
Together these require: the sha is on the branch (existing check), it's distinct from
and strictly ahead of the pre-merge tip, it's a genuine merge commit, and it actually
contains the recorded task-branch tip as an ancestor. A reused/pre-existing sha
(GSAI-211's exact shape) fails the second check immediately.

**Hatch 2 — reject a merge whose only content is Dozer's own paperwork:**
```
DESIGN_ONLY="$(grep -E '^design_only=' "$RECEIPT" | head -1 | cut -d= -f2)"
if [[ "${DESIGN_ONLY:-0}" != "1" ]]; then
  changed="$(git -C "$WORKDIR" diff --name-only "$PREMERGE" "$SHA" 2>/dev/null)"
  non_paperwork="$(printf '%s\n' "$changed" | grep -vE '^DOZER-(DESIGN|REVIEW)-.*\.md$' || true)"
  if [[ -z "$(printf '%s' "$non_paperwork" | tr -d '[:space:]')" ]]; then
    echo "merge $SHA changes ONLY Dozer paperwork (DOZER-DESIGN-*.md / DOZER-REVIEW-*.md) — no task code shipped (GSAI-213). Not labeling merged. If this issue genuinely ships only docs, opt in with the 'design-only' label (or DESIGN_ONLY=1 for one run) and re-run."
    exit 1
  fi
fi
```
`$PREMERGE` here is the verified genuine pre-merge tip from the hatch-1 checks above —
diffing against it (not `$SHA^1`/`$SHA^2`) is correct regardless of which parent order
`git merge` used.

**Proof line** (spec: "names the new merge sha and its dozer/<ID> second parent, and
states the pre-merge tip it moved from"):
```
echo "ok $(git -C "$WORKDIR" rev-parse --short "$SHA") is on $BRANCH (tip $(git -C "$WORKDIR" rev-parse --short "$BRANCH")), moved from $(git -C "$WORKDIR" rev-parse --short "$PREMERGE") — task tip $(git -C "$WORKDIR" rev-parse --short "$TASK_SHA")"
```

### 3. `dozers/dozer.sh` — no change in shape, just inherits the stricter verdict

`run_one()` already treats any nonzero `verify-merge.sh` exit as "block, never label
merged" (dozer.sh:538-543) and prints the verifier's own message verbatim in the block
comment. Both new hatches reuse that exact path — no new branch needed in `dozer.sh`.
(The spec's "set `dozer:failed`" is this codebase's existing `task_block` /
`dozer:blocked` off-ramp — there is no separate `dozer:failed` label implemented here;
`_linear_api.py`'s own comment maps `failed -> dozer:blocked`. The block comment text
distinguishes the two reasons clearly, which is what actually matters to a Director
reading the Ship gate.)

## Files to touch

- `dozers/dev-lane/crew.sh` — capture `TASK_TIP` before the merge; extend the receipt
  with `premerge_sha=` / `task_sha=` / `design_only=`; resolve the design-only opt-in
  via the existing `crew_meta_field label` / `crews_get` helpers.
- `dozers/verify-merge.sh` — add the hatch-1 (new-sha / 2-parent / task_sha-ancestor)
  and hatch-2 (paperwork-only diff) checks; update the proof line to name the pre-merge
  tip and task tip.
- `org/config.yaml` — document `crews: design_only_label:` (default `design-only`),
  next to the existing `lite_when_label`.
- `tests/merge-verify-test.sh` — extend with the two new fixtures (below); update
  case 1's expected receipt/proof-line assertions for the new fields.
- `tests/dev-lane-greengate-test.sh` / other receipt-reading tests (grep first) —
  check for any other consumer of `.artifacts/dev/<id>.merge` that assumes the
  2-field format and would break on the extra lines (append-only, so should be
  backward-compatible for anything that just greps `^branch=`/`^merge_sha=`).

## Edge cases

- **Old receipts from before this fix** (in-flight at deploy time): missing
  `premerge_sha`/`task_sha` → the new "receipt missing" check fires → blocked, not
  silently passed. Safe-by-default, matches GSAI-119's existing posture (any
  ambiguity blocks). These are re-greenlit and get a current-format receipt.
- **A genuinely legitimate no-op** (e.g. a task to verify something is already true,
  no code change intended): still correctly fails — if nothing changed, nothing
  should merge. The Director re-scopes it as a no-code task if that was really the
  intent (e.g. a Linear-only or research task, which shouldn't be `lane:dev` at all).
- **A real merge that happens to ALSO touch only docs but isn't Dozer paperwork**
  (e.g. a legitimate `README.md` update task) — the glob is deliberately narrow
  (`DOZER-DESIGN-*.md` / `DOZER-REVIEW-*.md` only), so a real docs task that edits
  `README.md` or anything else is unaffected. Only the crew's own scratch artifacts
  trip the gate.
- **A task that legitimately ships ONLY a design/review doc** (rare, but the spec
  calls it out) — opt in via the `design-only` label on the issue, or `DESIGN_ONLY=1`
  for one deliberate run, mirroring the existing `DOZER_CREW=`/`TEST_GATE=off`
  single-run-override convention.
- **`task_sha` ancestor check and merge commits from a rebase-then-merge path**
  (crew.sh's rebase fallback ~line 1114-1121, `git -C "$WT" rebase "$INTEG"`): after a
  rebase, `$WT`'s HEAD (captured as `TASK_TIP` right before the merge call, i.e. after
  any rebase already happened) is the rebased tip, which IS what gets merged — no
  ordering bug, the capture point is already correct relative to the rebase.
- **Lite-profile issues** (no ARCHITECT/REVIEW pass, so no `DOZER-DESIGN-*`/
  `DOZER-REVIEW-*` files are ever written) — hatch 2's check still works correctly
  for them: if a lite pass's diff is non-empty and not purely those paperwork
  filenames (which it never writes anyway), it passes normally.
- **Multiple round trips within one issue** (crew.sh's resume path reuses the same
  branch across attempts) — `premerge_sha`/`task_sha` are captured fresh on the
  attempt that actually performs the merge, so they always describe the final,
  real merge, not an earlier aborted one.

## How it gets tested

Extend `tests/merge-verify-test.sh` (the existing GSAI-119 regression suite, same
stub-agent/mkproj fixtures already defined there):

- **Case 1 update**: assert the receipt now also contains `premerge_sha=` and
  `task_sha=` lines, and that `verify-merge.sh`'s proof line reports the moved-from
  tip.
- **New case — hatch 1 (GSAI-211 shape)**: build a receipt where `merge_sha` equals
  `branch`'s current tip with `premerge_sha` set to that SAME sha (reconstructing the
  exact "no-op merge" signature: `git merge --no-ff` found nothing new). Assert
  `verify-merge.sh` exits 1 and the message names it a no-op / pre-existing sha, not a
  generic "unreadable receipt".
- **New case — hatch 2 (GSAI-213 shape)**: build a real merge commit whose diff is
  exactly `DOZER-DESIGN-GSAI-TEST.md` + `DOZER-REVIEW-GSAI-TEST.md` (mirroring the
  real GSAI-213 diff), with a correct `premerge_sha`/`task_sha`. Assert
  `verify-merge.sh` exits 1 and the message names the paperwork-only diff.
- **New case — design-only opt-out**: same paperwork-only diff, but receipt carries
  `design_only=1`. Assert `verify-merge.sh` passes.
- **New case — legitimate docs change is unaffected**: a merge whose diff is
  `README.md` only (not a `DOZER-*` filename). Assert `verify-merge.sh` passes.
- **Engine-level (case 3 in the existing file)**: add a sub-case feeding the phantom
  crew stub a no-op merge (checkout develop, `git merge --no-ff` a branch identical to
  develop) and confirm the issue lands in `blocked/`, never `done/`, with the GSAI-211
  reason in the block comment.
- Run via `bash tests/run-all.sh` (picks up `tests/*-test.sh` automatically, per the
  existing convention noted in DOZER-DESIGN-GSAI-213.md).
- **Spec's explicit acceptance bar**: "re-running the verifier against GSAI-211 and
  GSAI-213's pass-1 state would have failed both" — the two new fixtures above are
  built to reconstruct exactly those two real incidents' receipt/diff shapes, so
  passing them is the direct proof.
