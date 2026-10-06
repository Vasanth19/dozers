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
task_claim()          { python3 "$_LIN" claim "$1"; }      # 1 = already claimed, 4 = release budget exhausted (GSAI-184)
task_done()           { python3 "$_LIN" done "$1"; }
task_comment()        { local id="$1"; shift; python3 "$_LIN" comment "$id" "$*"; }

task_repo()          { python3 "$_LIN" repo "$1"; }   # repo:<name> hint, or empty
task_team()          { python3 "$_LIN" team "$1"; }   # the task's Linear team key
task_milestone()     { python3 "$_LIN" milestone "$1"; }   # KR name (Milestone), or empty (GSAI-173)
task_project()       { python3 "$_LIN" project "$1"; }     # Objective name (Project), or empty (GSAI-173)
task_description()   { python3 "$_LIN" description "$1"; }   # the issue body — the brief (GSAI-7)
task_crew_meta()     { python3 "$_LIN" crew-meta "$1"; }  # project + labels, for the crew-profile pick (GSAI-170)

# GSAI-213: bounded retry around the TERMINAL writes only — merged()/review()/block()
# run after a crew's real, expensive, (for dev) git-verified work. A transient blip on
# the one write that matters most used to either strand the issue at dozer:in-progress
# (set_labels_and_state's success check now closes the quiet-rejection half) or trip
# `set -e` and vanish the run with no retry at all (dozer.sh's _terminal_write closes
# the loud-exception half). This loop is the highest-leverage fix for the common case:
# a network blip right after a merge usually just needs attempt 2.
#
# task_claim/task_requeue are DELIBERATELY not wrapped: claim() is cheap and safe to
# fail outright (nothing expensive has happened yet), and wrapping requeue would make
# the reaper's own repair path retry-inside-a-retry.
if [[ -z "${LINEAR_WRITE_RETRIES:-}" ]]; then
  LINEAR_WRITE_RETRIES="$(grep -E '^[[:space:]]*linear_write_retries:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*linear_write_retries:[[:space:]]*//; s/#.*//; s/[[:space:]]//g')"
fi
LINEAR_WRITE_RETRIES="${LINEAR_WRITE_RETRIES:-3}"
if [[ -z "${LINEAR_WRITE_BACKOFF_S:-}" ]]; then
  LINEAR_WRITE_BACKOFF_S="$(grep -E '^[[:space:]]*linear_write_backoff_s:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*linear_write_backoff_s:[[:space:]]*//; s/#.*//; s/[[:space:]]//g')"
fi
LINEAR_WRITE_BACKOFF_S="${LINEAR_WRITE_BACKOFF_S:-5}"

_linear_write_retry() {  # <verb> <id> — bounded retry around `python3 _LIN <verb> <id>`
  local verb="$1" id="$2" attempt=1 rc=0
  while true; do
    # `&& return 0` then `rc=$?`, NOT `if …; then return 0; fi; rc=$?`: when the `if`'s
    # condition fails and no branch runs, the `if` itself exits 0 — that would make the
    # final attempt's failure return 0 to the caller, i.e. report a dead write as success.
    python3 "$_LIN" "$verb" "$id" && return 0
    rc=$?
    if (( attempt >= LINEAR_WRITE_RETRIES )); then return "$rc"; fi
    echo "  ! linear $verb $id failed (attempt $attempt/$LINEAR_WRITE_RETRIES, rc=$rc) - retrying in ${LINEAR_WRITE_BACKOFF_S}s" >&2
    sleep "$LINEAR_WRITE_BACKOFF_S"
    attempt=$((attempt+1))
  done
}

task_review()        { _linear_write_retry review "$1"; }   # mktg: stage for human approval (dozer:needs-review)
task_merged()        { _linear_write_retry merged "$1"; }   # dev: merged to develop (dozer:merged-develop)
task_block()         { _linear_write_retry block "$1"; }    # failure off-ramp (dozer:blocked)

# recovery verbs (used by dozers/reaper.sh)
task_list_inflight() { python3 "$_LIN" list-inflight; }  # claimed (started), not needs-review/done
task_requeue()       { python3 "$_LIN" requeue "$1"; }   # re-add ready + back to unstarted

# stranded-finish repair (GSAI-213, used by dozers/reaper.sh's pre-step)
task_list_stale_offramp() { python3 "$_LIN" list-stale-offramp; }  # in-progress + an off-ramp label together
task_finish_repair()      { python3 "$_LIN" finish-repair "$1"; }  # strip the stale dozer:in-progress only

# audit verbs (used by dozers/audit-merged.sh, GSAI-119)
task_list_merged_dev() { python3 "$_LIN" list-merged-dev; }  # every issue on dozer:merged-develop
task_audit_requeue()   { python3 "$_LIN" audit-requeue "$1"; }  # phantom: strip label + back to ready
task_audit_strip()     { python3 "$_LIN" audit-strip "$1"; }    # hygiene: strip label off a closed issue

# board protocol (GSAI-41) — read-only reconcile probe: did Vas answer the newest board-ask?
# exit 0 = answered (prints `<createdAt>\t<first line>` per answer), 3 = waiting, 2 = no ask.
task_board_answer()  { python3 "$_LIN" board-answer "$1"; }

# release budget (GSAI-184) — read-only: how many times has this issue been dispatched
# on its current budget, what is the cap, and how did those passes die. The gate itself
# lives inside claim(); this is only the window onto it.
task_release_count() { python3 "$_LIN" release-count "$1"; }

# release-cap sweep (GSAI-252) — every dozer:blocked issue at the cap must carry a board-ask
# and board:to_review. Run by dozers/reaper.sh. --dry-run lists the set and writes nothing;
# --force bypasses the throttle (BUDGET_SWEEP_EVERY, default 1800s).
task_budget_sweep()  { python3 "$_LIN" budget-sweep "$@"; }

# weekly focus (GSAI-176) — one human line describing the active focus window. No Linear
# call: it reads org/config.yaml only, so dozer.sh can print it in its startup banner and
# once an hour without spending a round-trip. A backend with no notion of focus simply
# does not define this, and dozer.sh prints nothing.
task_focus_line()    { python3 "$_LIN" focus-line; }
