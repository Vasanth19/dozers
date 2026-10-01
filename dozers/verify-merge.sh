#!/usr/bin/env bash
# dozers/verify-merge.sh — prove a dev-lane merge actually LANDED before the engine
# labels the issue dozer:merged-develop (GSAI-119).
#
# The engine used to label from the crew's exit code alone, and an exit-0 with no
# merge (CFW-215, CFW-252, CFW-141) put a fake PROMOTE row on Vas's Ship gate with
# nothing behind it. Crew success and merge success are two different facts; this
# script checks the second one against the task's OWN repo.
#
# Ground truth is the crew's merge receipt (.artifacts/dev/<id>.merge): the branch
# and merge SHA the crew recorded the moment its green-gate passed. The claim is
# true iff that SHA exists in the repo AND is an ancestor of that branch. We never
# grep commit messages for the task id — old Paperclip-era commits collide with
# today's IDs (e.g. "Merge CFW-252 (ab-scheduler parallel batch)"), so message
# matching on the bare ID is a proven trap.
#
# GSAI-217: "is this sha on the branch" is the DESTINATION fact — it is necessary but
# not sufficient, and on 2026-09-28 it rubber-stamped two non-merges within an hour:
#   - GSAI-211: the sha named in the receipt was ALREADY on the branch before this
#     pass ran (`git merge --no-ff` found nothing to merge, so it committed nothing —
#     a no-op). Trivially "on the branch" for any pre-existing sha.
#   - GSAI-213: a real merge commit landed, but its entire diff was the crew's own
#     DOZER-DESIGN-*.md / DOZER-REVIEW-*.md paperwork — no task code.
# The receipt now also carries premerge_sha (the branch's tip BEFORE this pass) and
# task_sha (dozer/<id>'s own tip at merge time), which let this script check the
# DELTA, not just the destination: the sha must be NEW, must be a genuine 2-parent
# merge that contains task_sha, and its diff must be more than Dozer's own paperwork.
#
#   verify-merge.sh <id> <workdir>
#
# rc 0, stdout = one proof line   -> the label may be written.
# rc 1, stdout = the reason (with the git evidence) -> run_one puts it in the block
# comment verbatim. Nothing here mutates the repo or the task.
set -uo pipefail

ID="${1:-}"; WORKDIR="${2:-}"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RECEIPT="${RECEIPT:-$REPO_ROOT/.artifacts/dev/$ID.merge}"

if [[ -z "$ID" || -z "$WORKDIR" ]]; then
  echo "usage: verify-merge.sh <id> <workdir>" >&2
  exit 2
fi

if [[ ! -d "$WORKDIR" ]] || ! git -C "$WORKDIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "not a git repo: $WORKDIR — cannot verify any merge"
  exit 1
fi

if [[ ! -s "$RECEIPT" ]]; then
  echo "no merge receipt ($RECEIPT) — the dev crew exited 0 but recorded no merge. This is the phantom-merge signature (GSAI-119): a crew that merged and passed the green-gate always writes the receipt."
  exit 1
fi

BRANCH="$(grep -E '^branch=' "$RECEIPT"    | head -1 | cut -d= -f2)"
SHA="$(   grep -E '^merge_sha=' "$RECEIPT" | head -1 | cut -d= -f2)"
if [[ -z "$BRANCH" || -z "$SHA" ]]; then
  echo "unreadable merge receipt ($RECEIPT):"
  sed 's/^/  /' "$RECEIPT" 2>/dev/null
  exit 1
fi

PREMERGE="$(grep -E '^premerge_sha=' "$RECEIPT" | head -1 | cut -d= -f2)"
TASK_SHA="$( grep -E '^task_sha='    "$RECEIPT" | head -1 | cut -d= -f2)"
DESIGN_ONLY="$(grep -E '^design_only=' "$RECEIPT" | head -1 | cut -d= -f2)"
if [[ -z "$PREMERGE" || -z "$TASK_SHA" ]]; then
  echo "receipt missing premerge_sha/task_sha — cannot confirm this merge is NEW, not a pre-existing sha (GSAI-211 no-op signature); re-greenlight to get a receipt in the current format"
  exit 1
fi

if ! git -C "$WORKDIR" cat-file -e "$SHA^{commit}" 2>/dev/null; then
  echo "receipt claims merge $SHA on $BRANCH, but no such commit exists in $WORKDIR"
  exit 1
fi

if ! git -C "$WORKDIR" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null 2>&1; then
  echo "receipt claims a merge onto '$BRANCH', but $WORKDIR has no local branch '$BRANCH' (HEAD: $(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"
  exit 1
fi

# Hatch 1 (GSAI-211): the sha must be NEW — not the branch's pre-existing tip — and
# must be a genuine 2-parent merge that actually contains dozer/$ID's own tip.
if [[ "$SHA" == "$PREMERGE" ]]; then
  echo "receipt claims merge $SHA, but that is $BRANCH's PRE-EXISTING tip (GSAI-211): the crew's merge was a no-op — \`git merge --no-ff\` found nothing to merge because the pass committed no changes. Not labeling merged."
  exit 1
fi

if ! git -C "$WORKDIR" merge-base --is-ancestor "$PREMERGE" "$SHA" 2>/dev/null; then
  echo "receipt's premerge_sha ($PREMERGE) is not an ancestor of merge_sha ($SHA) — the receipt is internally inconsistent, refusing to trust it"
  exit 1
fi

if [[ "$(git -C "$WORKDIR" rev-list --min-parents=2 --max-count=1 "$SHA" 2>/dev/null)" != "$SHA" ]]; then
  echo "merge_sha $SHA is not a 2-parent merge commit — cannot confirm it is the merge this pass performed"
  exit 1
fi

if ! git -C "$WORKDIR" merge-base --is-ancestor "$TASK_SHA" "$SHA" 2>/dev/null; then
  echo "receipt's task_sha ($TASK_SHA, the dozer/$ID branch tip) is not an ancestor of merge_sha ($SHA) — the merge does not actually contain this pass's branch"
  exit 1
fi

if ! git -C "$WORKDIR" merge-base --is-ancestor "$SHA" "$BRANCH" 2>/dev/null; then
  TIP="$(git -C "$WORKDIR" rev-parse --short "$BRANCH" 2>/dev/null)"
  echo "receipt claims merge $SHA onto $BRANCH, but $SHA is NOT an ancestor of $BRANCH in $WORKDIR — the merge did not land (reverted or never happened).
  $BRANCH now: $TIP $(git -C "$WORKDIR" log -1 --format=%s "$BRANCH" 2>/dev/null)
  $BRANCH last 3 first-parent subjects:"
  git -C "$WORKDIR" log --first-parent -3 --format='    %h %s' "$BRANCH" 2>/dev/null
  exit 1
fi

# Hatch 2 (GSAI-213): reject a merge whose only content is Dozer's own paperwork —
# unless the issue explicitly opted into shipping design/review docs only.
if [[ "${DESIGN_ONLY:-0}" != "1" ]]; then
  changed="$(git -C "$WORKDIR" diff --name-only "$PREMERGE" "$SHA" 2>/dev/null)"
  non_paperwork="$(printf '%s\n' "$changed" | grep -vE '^DOZER-(DESIGN|REVIEW)-.*\.md$' || true)"
  if [[ -z "$(printf '%s' "$non_paperwork" | tr -d '[:space:]')" ]]; then
    echo "merge $SHA changes ONLY Dozer paperwork (DOZER-DESIGN-*.md / DOZER-REVIEW-*.md) — no task code shipped (GSAI-213). Not labeling merged. If this issue genuinely ships only docs, opt in with the 'design-only' label (or DESIGN_ONLY=1 for one run) and re-run."
    exit 1
  fi
fi

echo "ok $(git -C "$WORKDIR" rev-parse --short "$SHA") is on $BRANCH (tip $(git -C "$WORKDIR" rev-parse --short "$BRANCH")), moved from $(git -C "$WORKDIR" rev-parse --short "$PREMERGE") — task tip $(git -C "$WORKDIR" rev-parse --short "$TASK_SHA")"
