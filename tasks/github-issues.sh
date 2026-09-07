#!/usr/bin/env bash
# tasks/github-issues.sh — the default, shareable backend.
#
# GitHub Issues IS the task store. Labels carry the state, so your model maps 1:1:
#   ready gate  -> label  ready
#   lanes       -> labels lane:dev, lane:marketing
#   claimed     -> label  status:wip  (removes `ready` so no double-run)
#   done        -> issue closed
#
# Needs the GitHub CLI, authenticated once:  gh auth login
# The board UI comes free via GitHub Projects. Others adopt it with
# "Use this template" — zero extra infra.
#
# Set the repo in org/config.yaml (repo: owner/name) or the GH_REPO env var.

_repo() {
  local r="${GH_REPO:-}"
  [[ -z "$r" ]] && r="$(grep -E '^[[:space:]]*repo:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*repo:[[:space:]]*//; s/#.*//; s/[[:space:]]//g; s/"//g; s/'"'"'//g')"
  [[ -n "$r" ]] || { echo "github: set 'repo: owner/name' in org/config.yaml" >&2; return 1; }
  printf '%s' "$r"
}
_gh() { gh "$@" --repo "$(_repo)"; }

task_list_untriaged() {
  # open issues with NO lane label and NOT yet ready
  _gh issue list --state open --json number,title,labels \
    --jq '.[] | select((.labels|map(.name)|any(startswith("lane:"))|not) and (.labels|map(.name)|index("ready")|not)) | "\(.number)\t\(.title)"'
}

task_list_ready() {
  _gh issue list --state open --label ready --json number,title,labels \
    --jq '.[] | . as $i | (.labels|map(.name)|map(select(startswith("lane:")))[0] // "lane:none") as $lane | "\($i.number)\t\($lane|ltrimstr("lane:"))\t\($i.title)"'
}

task_mark_ready() { # <id> <lane>
  local id="$1" lane="$2"
  _gh issue edit "$id" --add-label "lane:$lane" --add-label "ready" >/dev/null
}

task_claim() { # <id> — take it: drop `ready`, add `status:wip`.
  # NOTE: best-effort, not atomic — GitHub has no label compare-and-swap, so this
  # re-checks then edits (two calls). Safe under one worker/runner; if you ever run
  # workers concurrently, add a real lock (e.g. assign the issue and verify assignee).
  local id="$1"
  # Re-check it's still ready; if `ready` is already gone, someone else claimed it.
  _gh issue view "$id" --json labels --jq '.labels|map(.name)|index("ready")' | grep -q '^[0-9]' || return 1
  _gh issue edit "$id" --remove-label "ready" --add-label "status:wip" >/dev/null
}

task_done() { # <id>
  local id="$1"
  _gh issue edit "$id" --remove-label "status:wip" --add-label "status:done" >/dev/null 2>&1 || true
  _gh issue close "$id" >/dev/null 2>&1 || true
}

task_comment() { # <id> <text>
  local id="$1"; shift
  _gh issue comment "$id" --body "$*" >/dev/null
}

task_repo() { # <id> - repo:<name> hint label, or empty
  _gh issue view "$1" --json labels --jq '(.labels|map(.name)|map(select(startswith("repo:")))|.[0]//"")|sub("^repo:";"")'
}
task_team() { printf ""; }   # GitHub has no teams; workdir falls back to default/repo hint
task_description() { _gh issue view "$1" --json body --jq '.body // ""'; }   # the issue body — the brief (GSAI-7)
task_review() { # <id> - add needs-review label, do NOT close
  _gh issue edit "$1" --add-label "needs-review" --remove-label "status:wip" >/dev/null 2>&1 || true
}

# --- recovery verbs (used by dozers/reaper.sh) --------------------------------
task_list_inflight() { # open issues claimed (status:wip) but NOT awaiting human review
  _gh issue list --state open --label "status:wip" --json number,title,labels \
    --jq '.[] | select((.labels|map(.name)|index("needs-review"))|not) | . as $i | (.labels|map(.name)|map(select(startswith("lane:")))[0] // "lane:none") as $lane | "\($i.number)\t\($lane|ltrimstr("lane:"))\t\($i.title)"'
}
task_requeue() { # <id> - put a stranded wip issue back to ready (keeps its lane label)
  _gh issue edit "$1" --remove-label "status:wip" --add-label "ready" >/dev/null 2>&1 || return 1
}
