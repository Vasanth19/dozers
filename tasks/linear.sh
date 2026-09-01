#!/usr/bin/env bash
# tasks/linear.sh — the Linear backend.
#
# Linear IS the task store. It maps onto the dozers model with more *native*
# structure than any other backend: Initiative→Project→Milestone→Issue→Sub-issue
# is a real typed hierarchy (Pillar/Objective/KR/Task/Sub-task), and the greenlight is
# a label just like everywhere else:
#   ready gate -> label  ready
#   lanes      -> labels lane:<name>
#   claimed    -> issue moves to a `started` state (drops `ready`)
#   done       -> issue moves to a `completed` state
#
# Ids are Linear's human identifiers (e.g. CFW-9), so `ready CFW-9 dev` reads clean.
#
# Requires (export both before running — e.g. from your secrets vault):
#   LINEAR_API_KEY   personal API key or OAuth app token
#   LINEAR_TEAM      the team key, e.g. CFW   (also set in org/config.yaml)
#
# Real GraphQL logic lives in tasks/_linear_api.py; these are thin wrappers so the
# Directors/Dozers keep calling the exact same six verbs as every other backend.

# Team key: env wins, else read org/config.yaml (linear_team:).
if [[ -z "${LINEAR_TEAMS:-}" ]]; then
  export LINEAR_TEAMS="$(grep -E '^[[:space:]]*linear_teams:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*linear_teams:[[:space:]]*//; s/#.*//; s/[[:space:]]//g; s/"//g' || true)"
fi
if [[ -z "${LINEAR_TEAM:-}" ]]; then
  export LINEAR_TEAM="$(grep -E '^[[:space:]]*linear_team:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*linear_team:[[:space:]]*//; s/#.*//; s/[[:space:]]//g; s/"//g; s/'"'"'//g')"
fi

_LIN="$ROOT/tasks/_linear_api.py"

task_list_untriaged() { python3 "$_LIN" list-untriaged; }
task_list_ready()     { python3 "$_LIN" list-ready; }
task_mark_ready()     { python3 "$_LIN" mark-ready "$1" "$2"; }
task_claim()          { python3 "$_LIN" claim "$1"; }      # exits 1 if already claimed
task_done()           { python3 "$_LIN" done "$1"; }
task_comment()        { local id="$1"; shift; python3 "$_LIN" comment "$id" "$*"; }

task_repo()          { python3 "$_LIN" repo "$1"; }   # repo:<name> hint, or empty
task_team()          { python3 "$_LIN" team "$1"; }   # the task's Linear team key
task_review()        { python3 "$_LIN" review "$1"; }   # stage for human approval (not done)
