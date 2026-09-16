#!/usr/bin/env bash
# dozers/audit-merged.sh — the one-shot phantom-merge audit (GSAI-119), safe to re-run.
#
# dozer:merged-develop used to be written from the dev crew's exit code ALONE
# (dozer.sh), so issues carried "merged" with no commit behind them and surfaced as
# fake PROMOTE rows on the Ship gate (CFW-215/CFW-252 verified 2026-09-14, with zero
# commits; CFW-141 twice on 2026-09-08). This audit walks every issue on that label
# and repairs the lie:
#
#   merge verified on the integration branch  -> keep the label            (ok)
#   open issue, no merge found                -> strip + requeue + comment (requeued)
#   closed issue with the label, merge or not -> strip the label           (stripped)
#   repo unresolvable                         -> leave alone, list loudly  (unresolved)
#
# Verification matches on the merge-commit SUBJECT for the task's branch —
#   "^merge <prefix>/<ID> into "   (first-parent log of the integration branch)
# NEVER a bare grep for the ID: old Paperclip-era commits collide with today's IDs
# ("Merge CFW-252 (ab-scheduler parallel batch)") and would pass a loose match.
#
#   dozers/audit-merged.sh            # repair live (Linear labels move, comments post)
#   dozers/audit-merged.sh --dry-run  # report only, mutate nothing
#
# Requires LINEAR_API_KEY (e.g. `source ~/ecosystem/vault/linear.env`). Repo paths
# resolve from ~/ecosystem/ecosystem.yaml via tasks/ecosystem_workdir.py — never
# hardcoded. Test seams: AUDIT_LINEAR_API / AUDIT_RESOLVER point the script at stubs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
LIN="${AUDIT_LINEAR_API:-$ROOT/tasks/_linear_api.py}"
RESOLVER="${AUDIT_RESOLVER:-$ROOT/tasks/ecosystem_workdir.py}"
PREFIX="${BRANCH_PREFIX:-$(grep -E '^branch_prefix:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g')}"
PREFIX="${PREFIX:-dozer}"
CLOSED="completed canceled"

# LIN/RESOLVER dispatch: real backends are python; test stubs are bash.
lin() { if [[ "$LIN" == *.py ]]; then python3 "$LIN" "$@"; else "$LIN" "$@"; fi }
res() { if [[ "$RESOLVER" == *.py ]]; then python3 "$RESOLVER" "$@"; else "$RESOLVER" "$@"; fi }

# The integration branch this repo would have merged onto: `develop` when it exists,
# else the repo's default (origin/HEAD -> main). Mirrors dev-lane/crew.sh's ladder.
integration_ref() {  # $1 = repo path -> echo a rev (local branch or origin/*), rc 1 if none
  local p="$1" d
  if   git -C "$p" rev-parse --verify -q refs/heads/develop         >/dev/null 2>&1; then echo "develop"
  elif git -C "$p" rev-parse --verify -q "refs/remotes/origin/develop" >/dev/null 2>&1; then echo "origin/develop"
  else
    d="$(git -C "$p" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; d="${d#origin/}"
    if   [[ -n "$d" ]] && git -C "$p" rev-parse --verify -q "refs/heads/$d" >/dev/null 2>&1; then echo "$d"
    elif git -C "$p" rev-parse --verify -q refs/heads/main >/dev/null 2>&1; then echo "main"
    else return 1; fi
  fi
}

# Did the task branch's merge land on the integration branch? Exact-anchored subject
# match on the first-parent history — see the header for why the ID alone is a trap.
# The log is captured BEFORE grep: `git log | grep -q` under pipefail is a false-negative
# machine — grep exits on the first match, git dies to SIGPIPE (141) on any repo with
# history after the match, and pipefail reports 141 as "not found". (Caught by the
# audit's own dry-run against the real dozers repo during GSAI-119.)
merge_found_in() {  # $1 = repo path, $2 = task id
  local p="$1" id="$2" ref log
  ref="$(integration_ref "$p")" || return 1
  log="$(git -C "$p" log --first-parent --format='%s' "$ref" 2>/dev/null)"
  grep -qE "^merge ${PREFIX}/${id} into " <<< "$log"
}

resolve_repo() {  # $1 = repo:<id> hint or -, $2 = team -> echo path, rc 1 on failure
  local hint="$1" team="$2"
  if [[ -n "$hint" && "$hint" != "-" ]]; then
    res --repo "$hint" 2>/dev/null
  elif [[ -n "$team" && "$team" != "-" ]]; then
    res --team "$team" 2>/dev/null
  else
    return 1
  fi
}

rows="$(lin list-merged-dev)" || { echo "audit-merged: could not list $LIN list-merged-dev" >&2; exit 1; }

ok=0; requeued=0; stripped=0; unresolved=0; total=0
while IFS=$'\t' read -r id team hint state lane; do
  [[ -z "$id" ]] && continue
  total=$((total+1))
  repo="$(resolve_repo "$hint" "$team")" || repo=""
  if [[ -z "$repo" || ! -d "$repo" ]]; then
    printf '  ? %-9s UNRESOLVED repo (hint=%s team=%s state=%s) — label left alone, resolve by hand\n' "$id" "$hint" "$team" "$state"
    unresolved=$((unresolved+1)); continue
  fi

  closed=0; for s in $CLOSED; do [[ "$state" == "$s" ]] && closed=1; done

  if (( closed )); then
    # Ship-gate hygiene (GSAI-119 DoD #4): a Done/canceled issue must not retain
    # dozer:merged-develop regardless of whether the merge exists (CFW-251).
    printf '  - %-9s closed (%s) — strip label%s\n' "$id" "$state" "$([[ $DRY == 1 ]] && echo ' [dry-run]')"
    if [[ $DRY == 0 ]]; then
      lin audit-strip "$id"
      lin comment "$id" "Audit (GSAI-119): removed dozer:merged-develop from this closed issue — a terminal issue must not sit on the Ship gate as a PROMOTE row.

<!-- dozer-audit by:audit-merged -->"
    fi
    stripped=$((stripped+1)); continue
  fi

  if merge_found_in "$repo" "$id"; then
    printf '  ✓ %-9s merge verified on %s (%s)\n' "$id" "$(integration_ref "$repo")" "$repo"
    ok=$((ok+1)); continue
  fi

  printf '  ✗ %-9s PHANTOM — no merge of %s/%s on %s in %s — strip + requeue%s\n' \
    "$id" "$PREFIX" "$id" "$(integration_ref "$repo" 2>/dev/null || echo '?')" "$repo" \
    "$([[ $DRY == 1 ]] && echo ' [dry-run]')"
  if [[ $DRY == 0 ]]; then
    lin audit-requeue "$id"
    lin comment "$id" "Audit (GSAI-119): this issue carried dozer:merged-develop, but no merge of ${PREFIX}/${id} exists on $(basename "$repo")'s integration branch ($(integration_ref "$repo" 2>/dev/null || echo '?')) — the claimed merge never landed. Label stripped, task requeued so the work is actually done. The engine now git-verifies the merge before labelling, so a phantom cannot recur.

<!-- dozer-audit by:audit-merged -->"
  fi
  requeued=$((requeued+1))
done <<< "$rows"

echo
printf 'audit-merged: %s checked — %s verified, %s phantom requeued, %s closed stripped, %s unresolved%s\n' \
  "$total" "$ok" "$requeued" "$stripped" "$unresolved" "$([[ $DRY == 1 ]] && echo ' [DRY RUN]')"
