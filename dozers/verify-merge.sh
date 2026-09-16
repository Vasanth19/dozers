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

if ! git -C "$WORKDIR" cat-file -e "$SHA^{commit}" 2>/dev/null; then
  echo "receipt claims merge $SHA on $BRANCH, but no such commit exists in $WORKDIR"
  exit 1
fi

if ! git -C "$WORKDIR" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null 2>&1; then
  echo "receipt claims a merge onto '$BRANCH', but $WORKDIR has no local branch '$BRANCH' (HEAD: $(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"
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

echo "ok $(git -C "$WORKDIR" rev-parse --short "$SHA") is on $BRANCH (tip $(git -C "$WORKDIR" rev-parse --short "$BRANCH"))"
