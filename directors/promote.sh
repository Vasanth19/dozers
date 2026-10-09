#!/usr/bin/env bash
# directors/promote.sh — the ONE way a Director promotes develop → main. (GSAI-104)
#
#   directors/promote.sh <repo-id|path> [--from develop] [--to main]
#                        [--check] [--dry-run] [--no-push] [--summary "<text>"]
#         (--no-push = merge locally, publish nothing — and the ONLY mode that works
#          in a repo with no origin remote at all; see invariant 6)
#
# WHY THIS IS A SCRIPT AND NOT A SENTENCE
# The Director docs used to say "promote develop→main" with no mechanics, so every
# Director hand-rolled the git. On 2026-09-09 one of them squashed: cfw-social's
# `fa85bddc` promote landed on main as a SINGLE-PARENT commit. A squash writes new
# hashes onto main that develop has never seen, so from that commit on `origin/main`
# and `origin/develop` share no recent history — every gap check, cherry-check and
# future promote reports phantom divergence. Cleaning that up cost CFW-250. Prose
# cannot hold an invariant; this script can.
#
# THE INVARIANTS (all enforced, all fatal)
#   1. A promote is `git merge --no-ff <from>` into <to>. Never --squash, never
#      rebase, never a bare fast-forward. The result is a 2-parent merge commit.
#   2. <to> only ever receives commits that already exist on <from>. A commit that
#      reached main another way (a squash, a hotfix, a release branch merged straight
#      to main) is divergence — we refuse and say how to reconcile.
#   3. We fetch first and never trust a stale local branch: for each side we take
#      whichever tip CONTAINS the other (the Dozer runs push:"false", so a local
#      develop legitimately holds work origin has not seen), and stop if the two have
#      genuinely diverged. Pushing is part of the promote — <from> is published first.
#   4. Nothing runs on a dirty checkout, and a merge whose result fails the post-check
#      is reset back to where it started — main is never left mid-promote.
#   5. Idempotent: with nothing on <from> that <to> lacks, it is a clean no-op (exit 0).
#   6. A repo with no origin can still promote under --no-push: local <to> is both
#      the base and the truth, and nothing is published. Without --no-push a missing
#      origin stays fatal.
#   7. <to>'s new tip is always carried straight back into <from> in the same run
#      (GSAI-141) — a mirror-image `git merge --ff <to>` committed onto <from> (a
#      fast-forward, almost always — a real merge commit only if <from> moved on in
#      the interim), never published until BOTH sides are merged locally. Without
#      this, <from> falls one merge commit further behind <to> on every promote, forever —
#      and every future worktree the Dozer cuts from <from> builds on that rotting
#      base. A pre-existing gap (a repo promoted before this invariant existed) is
#      healed the same way, even on an otherwise-no-op run — no separate migration.
#
# Exit codes:  0 promoted (or already promoted / check passed) · 1 refused, nothing
# changed · 2 usage error. Anything non-zero means main was NOT moved.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die()  { echo "[promote] ✗ $*" >&2; exit 1; }
usage(){ echo "usage: directors/promote.sh <repo-id|path> [--from develop] [--to main] [--check] [--dry-run] [--no-push] [--summary \"<text>\"]" >&2; exit 2; }
say()  { echo "[promote] $*"; }

# ── args ────────────────────────────────────────────────────────────────────
TARGET=""; FROM=""; TO="main"; PUSH=1; DRY=0; CHECK=0; SUMMARY=""
while (( $# )); do
  case "$1" in
    --from)    FROM="${2:?--from needs a branch}"; shift 2 ;;
    --to)      TO="${2:?--to needs a branch}"; shift 2 ;;
    --summary) SUMMARY="${2:?--summary needs text}"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    --push)    PUSH=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --check)   CHECK=1; shift ;;          # preflight only: report state, touch nothing
    -h|--help) usage ;;
    -*)        echo "[promote] unknown flag: $1" >&2; usage ;;
    *)         [[ -n "$TARGET" ]] && { echo "[promote] one repo at a time (got '$TARGET' and '$1')" >&2; usage; }
               TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || usage

# Source branch default = the same integration branch the Dozer merges into, read from
# org/config.yaml so the two halves of the pipeline can never disagree.
if [[ -z "$FROM" ]]; then
  FROM="$(grep -E '^[[:space:]]*integration_branch:' "$ROOT/org/config.yaml" 2>/dev/null \
          | head -1 | sed 's/.*integration_branch:[[:space:]]*//; s/#.*//; s/[[:space:]]//g; s/"//g; s/'"'"'//g')"
  FROM="${FROM:-develop}"
fi
[[ "$FROM" != "$TO" ]] || die "--from and --to are both '$TO' — a branch cannot promote into itself"

# ── where ───────────────────────────────────────────────────────────────────
# A path is a path; anything else is a registry id (ecosystem.yaml is the only map —
# never hardcode a repo path). Fail loud on a miss; never guess a repo (GSAI-131).
if [[ -d "$TARGET" ]]; then
  REPO="$(cd "$TARGET" && pwd)"
else
  REPO="$(python3 "$ROOT/tasks/ecosystem_workdir.py" --repo "$TARGET" 2>/dev/null || true)"
  [[ -n "$REPO" && -d "$REPO" ]] \
    || die "'$TARGET' is neither a directory nor a repo id in ~/ecosystem/ecosystem.yaml — register it or pass a path"
fi
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $REPO"
say "repo $REPO   promote $FROM → $TO"

# ── fetch (invariant 3: origin is the truth — when there is one) ────────────
# LOCAL_ONLY (invariant 6): a repo with NO origin remote can still promote under
# --no-push — local $TO is both the base and the truth, and nothing is published.
# The mode is gated on BOTH "no origin" AND "--no-push": with an origin present,
# --no-push keeps exactly today's semantics (fetch runs, origin/<ref> must exist,
# local/origin adjudication still decides each side's tip).
_has()  { git -C "$REPO" rev-parse --verify -q "$1^{commit}" >/dev/null 2>&1; }
_count(){ git -C "$REPO" rev-list --count "$@" 2>/dev/null || echo 0; }

# ── where a branch's merge happens: its own checkout, or a throwaway worktree ──
# Shared by the forward merge (onto $TO) and the back-merge (onto $FROM, GSAI-141) —
# a branch can be checked out in only one worktree, so the same lookup serves both.
# Never calls die(): a caller mid-promote (after $TO already moved) needs to revert
# $TO before dying, which die() can't do for it. Prints one of three first words on
# success — "existing <path>" (merge there, touch nothing else after), "new <path>"
# (a throwaway worktree on a branch that already existed, just wasn't checked out
# anywhere), or "newbranch <path>" (there was no local branch AT ALL — git's checkout
# DWIM just minted one tracking origin/<branch>). The newbranch case matters on
# cleanup: a branch we invented purely as merge scratch space must not survive the
# run, or it becomes a local-only ref that can silently diverge from origin the next
# time something else pushes to the same branch (GSAI-141 bit this exact way on the
# back-merge side under --no-push — see _forget_if_new below). On failure, prints the
# "[promote] ✗ ..." line itself and returns 1 with nothing on stdout.
_checkout_for() {   # _checkout_for <branch>
  local br="$1" at
  at="$(git -C "$REPO" worktree list --porcelain 2>/dev/null \
        | awk -v b="refs/heads/$br" '/^worktree /{w=$2} $0=="branch "b{print w; exit}')"
  if [[ -n "$at" ]]; then
    if [[ -n "$(git -C "$at" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
      echo "[promote] ✗ $br is checked out dirty at $at — commit or stash there, then re-run" >&2
      return 1
    fi
    echo "existing $at"; return 0
  fi
  local hadbranch=0; _has "refs/heads/$br" && hadbranch=1
  local w werr
  w="$(mktemp -d "${TMPDIR:-/tmp}/promote-$br.XXXXXX")"
  rmdir "$w"
  if ! werr="$(git -C "$REPO" worktree add "$w" "$br" 2>&1 >/dev/null)"; then
    echo "[promote] ✗ could not create a promote worktree on $br: ${werr:-unknown git error}" >&2
    return 1
  fi
  if (( hadbranch )); then echo "new $w"; else echo "newbranch $w"; fi
}
# A branch _checkout_for minted from nothing (kind "newbranch") is forgotten once its
# throwaway worktree is removed — it existed only as merge scratch space and was never
# there before this run, so keeping it around risks exactly the GSAI-141 regression:
# a dangling local ref that looks "ahead" of origin today and genuinely diverges the
# moment origin moves on before the next promote. A branch that already existed (kind
# "new") or is still checked out somewhere ("existing") is untouched either way.
_forget_if_new() {   # _forget_if_new <branch> <kind> <worktree-path>
  local br="$1" kind="$2" wt="$3"
  git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  [[ "$kind" == newbranch ]] && git -C "$REPO" branch -D "$br" >/dev/null 2>&1 || true
}
# Both worktrees this script may open, cleaned up unconditionally on exit — set once
# here so the trap is safe no matter which code path (self-heal, back-merge, neither)
# ends up using them.
MW=""; FW=""; CLEANUP_TO=0; CLEANUP_FROM=0; TO_KIND=""; FROM_KIND=""; PREMERGE=""; FROMPRE=""
_cleanup() {
  (( CLEANUP_TO ))   && _forget_if_new "$TO"   "$TO_KIND"   "$MW"
  (( CLEANUP_FROM )) && _forget_if_new "$FROM" "$FROM_KIND" "$FW"
}
trap _cleanup EXIT

HAS_ORIGIN=0; git -C "$REPO" remote get-url origin >/dev/null 2>&1 && HAS_ORIGIN=1
LOCAL_ONLY=0
if (( ! HAS_ORIGIN )); then
  if (( PUSH )); then
    die "no 'origin' remote in $REPO — a promote is measured against origin/$TO, and this checkout has none (for a local-only promote that publishes nothing, re-run with --no-push)"
  fi
  LOCAL_ONLY=1
  say "local-only promote — measured against LOCAL $TO, never published"
else
  _ferr="$(git -C "$REPO" fetch --prune origin 2>&1 >/dev/null)" \
    || die "git fetch origin failed in $REPO: ${_ferr:-unknown git error}"
  for ref in "origin/$FROM" "origin/$TO"; do
    _has "$ref" || die "$ref does not exist after fetch — is '$ref' the right branch name?"
  done
fi

# ── which tip of each branch is the real one: local or origin? ─────────────
# Both directions are legitimate here and neither may be guessed:
#   • The Director's clone is routinely STALE — the "scary 70 behind" that is really an
#     un-fetched branch. Then origin is the truth.
#   • The Dozer merges to a LOCAL develop and does not push (org/config.yaml
#     push: "false"), so origin/develop is behind by design and the work to promote
#     exists only on this machine. Then local is the truth.
# So: take whichever tip CONTAINS the other. If they have diverged — each holding
# commits the other lacks — stop; that is a human call, not a merge to improvise.
_rel() {   # relationship of $1 to $2: same | ahead | behind | diverged
  [[ "$(git -C "$REPO" rev-parse "$1")" == "$(git -C "$REPO" rev-parse "$2")" ]] && { echo same; return; }
  local ab ba; ab="$(_count "$1" "^$2")"; ba="$(_count "$2" "^$1")"
  if   (( ab > 0 && ba > 0 )); then echo diverged
  elif (( ab > 0 ));           then echo ahead
  else                              echo behind; fi
}
UNPUSHED_SRC=0
_effective() {   # print the ref to use for branch $1 (local or origin/<1>)
  local br="$1"
  if (( LOCAL_ONLY )); then   # no origin at all: local is the ONLY truth, no adjudication
    _has "refs/heads/$br" || die "no local branch '$br' and no origin to fall back on — nothing to promote"
    echo "$br"; return 0
  fi
  if ! _has "refs/heads/$br"; then echo "origin/$br"; return 0; fi
  case "$(_rel "$br" "origin/$br")" in
    same|behind) echo "origin/$br" ;;
    ahead)       echo "$br" ;;
    diverged)
      echo "[promote] ✗ local $br and origin/$br have DIVERGED — each holds commits the other lacks:" >&2
      echo "[promote]     local-only : $(_count "$br" "^origin/$br")   origin-only: $(_count "origin/$br" "^$br")" >&2
      die "refusing — reconcile $br with origin/$br yourself (merge, never force), then re-run" ;;
  esac
}
SRC="$(_effective "$FROM")" || exit 1     # what we merge
DST="$(_effective "$TO")"   || exit 1     # what we measure against, and merge into

if (( ! LOCAL_ONLY )); then   # with no origin, "unpushed" is everything — these lines and checks are n/a
  if [[ "$SRC" == "$FROM" ]]; then
    UNPUSHED_SRC="$(_count "$FROM" "^origin/$FROM")"
    say "local $FROM is $UNPUSHED_SRC commit(s) ahead of origin/$FROM (the Dozer merges locally, push: false)"
    (( PUSH )) && say "   → $FROM will be published first, so origin/$TO never gets a commit origin/$FROM lacks"
  fi
  [[ "$DST" == "$TO" ]] && say "local $TO is $(_count "$TO" "^origin/$TO") commit(s) ahead of origin/$TO (an earlier promote that was never pushed)"
  (( $(_count "origin/$FROM" "^$SRC") == 0 )) || die "internal: $SRC does not contain origin/$FROM"
fi

# ── invariant 2: $TO must not already carry commits absent from $FROM ───────
# Merge commits are excluded — a proper promote leaves a 2-parent merge on main that
# develop legitimately does not have. What must be empty is the NON-merge set: a
# squashed promote, a hotfix committed straight to main, a release branch merged to
# main without going through develop. Any of those is the divergence bug itself.
STRAY="$(git -C "$REPO" rev-list --no-merges "$DST" "^$SRC" 2>/dev/null || true)"
if [[ -n "$STRAY" ]]; then
  echo "[promote] ✗ $DST carries $(wc -l <<<"$STRAY" | tr -d ' ') commit(s) that do not exist on $SRC:" >&2
  git -C "$REPO" log --oneline --no-merges "$DST" "^$SRC" 2>/dev/null | head -20 | sed 's/^/      /' >&2
  echo "[promote]   That is branch divergence — usually a SQUASHED promote (1 parent) or work" >&2
  echo "[promote]   committed straight to $TO. Reconcile first: merge $TO back into $FROM" >&2
  echo "[promote]   (git merge --no-ff $DST on $FROM), then re-run this script." >&2
  exit 1
fi

# ── publishing: the promote is not finished until origin has it ─────────────
# Pushing is part of the promote, not a separate errand: $FROM goes FIRST when this
# machine held the only copy of it, because publishing main while origin/$FROM stays
# behind puts commits on origin/$TO that origin/$FROM has never seen — the same
# divergence, arriving by a different door.
_publish() {
  if (( ! PUSH )); then
    if (( LOCAL_ONLY )); then
      say "· nothing published — there is no origin; $TO moved only on this machine (when a remote exists, re-run to publish)"
    else
      say "· push skipped (--no-push) — origin still lacks this promote"
    fi
    return 0
  fi
  local pushed=0
  if (( $(_count "$FROM" "^origin/$FROM") > 0 )); then
    _serr="$(git -C "$REPO" push origin "$FROM" 2>&1 >/dev/null)" \
      || die "publishing $FROM failed — the merge is safe locally; push $FROM then $TO by hand:
    ${_serr:-unknown git error}"
    say "✓ published $FROM to origin"; pushed=1
  fi
  if (( $(_count "$TO" "^origin/$TO") > 0 )); then
    _perr="$(git -C "$REPO" push origin "$TO" 2>&1 >/dev/null)" \
      || die "the merge is committed locally but pushing $TO failed — fix the remote and run: git -C $REPO push origin $TO
    ${_perr:-unknown git error}"
    say "✓ pushed $TO to origin"; pushed=1
  fi
  (( pushed )) || say "· origin already has it — nothing to push"
  return 0
}

# GSAI-141: commits $DST (main) already holds that $SRC (develop) has never absorbed
# — every past promote's merge commit, before this invariant existed to back-merge
# them. Computed up front so --check/--dry-run can report it either way below.
REVGAP="$(_count "$DST" "^$SRC")"

AHEAD="$(_count "$SRC" "^$DST")"
if (( AHEAD == 0 )); then
  say "✓ nothing to promote — $DST already contains every commit on $SRC (no-op)"
  # ...but an earlier promote may have been made and never published. Finishing that is
  # still this script's job — otherwise the only way to complete it is hand-rolled git.
  if (( ! LOCAL_ONLY )) && (( $(_count "$FROM" "^origin/$FROM") > 0 || $(_count "$TO" "^origin/$TO") > 0 )); then
    say "origin is behind this machine — publishing the earlier promote"
    _publish
  fi
  if (( REVGAP > 0 )); then
    if (( CHECK || DRY )); then
      say "note: $FROM is $REVGAP commit(s) behind $TO from a past promote (GSAI-141 drift) — a real run would heal this into $FROM"
    else
      say "healing $REVGAP pre-existing commit(s) that $FROM is missing from a past promote (GSAI-141)"
      git -C "$REPO" worktree prune >/dev/null 2>&1 || true
      _co="$(_checkout_for "$FROM")"; rc=$?
      (( rc == 0 )) || die "self-heal: could not check out $FROM (see above) — no changes were made"
      read -r FROM_KIND FW <<<"$_co"
      [[ "$FROM_KIND" != existing ]] && CLEANUP_FROM=1
      if (( ! LOCAL_ONLY )) && (( $(_count "$DST" "^$FROM") > 0 )); then
        git -C "$FW" merge --ff-only "$DST" >/dev/null 2>&1 \
          || die "self-heal: could not fast-forward $FROM to $DST in $FW — no changes were made"
      fi
      if ! _hmerr="$(git -C "$FW" merge --ff --no-edit "$DST" -m "promote: back-merge $TO → $FROM (heal GSAI-141 drift)" 2>&1 >/dev/null)"; then
        git -C "$FW" merge --abort >/dev/null 2>&1 || true
        die "self-heal back-merge $TO → $FROM conflicted (should be impossible — see GSAI-141 design): ${_hmerr:-conflict}"
      fi
      say "✓ healed — $FROM now contains $TO's drift ($(git -C "$FW" rev-parse --short HEAD))"
      if (( PUSH )) && (( $(_count "$FROM" "^origin/$FROM") > 0 )); then
        _serr="$(git -C "$REPO" push origin "$FROM" 2>&1 >/dev/null)" \
          || die "healed $FROM locally but publishing it failed — push by hand: git -C $REPO push origin $FROM
    ${_serr:-unknown git error}"
        say "✓ published $FROM to origin"
      fi
    fi
  fi
  exit 0
fi
say "$AHEAD commit(s) to promote:"
git -C "$REPO" log --oneline "$DST..$SRC" | head -30 | sed 's/^/      /'
(( REVGAP > 0 )) && say "note: $DST already holds $REVGAP commit(s) that $SRC lacks from an earlier, pre-GSAI-141 promote — this run's back-merge will absorb those too"

if (( CHECK )); then say "✓ check only — $TO is promotable, nothing changed"; exit 0; fi
if (( DRY )); then
  say "✓ dry run — would run: git merge --no-ff $SRC (on $TO), then merge $TO back into $FROM so $FROM never falls behind (GSAI-141)$( (( PUSH )) && echo ", then push origin $FROM and $TO")"
  exit 0
fi

# ── where the merge happens ─────────────────────────────────────────────────
# A branch can be checked out in only ONE worktree. If $TO is already checked out
# somewhere, merge THERE when it is clean (a dirty one is a hard stop — invariant 4);
# otherwise use a throwaway worktree so we never switch anybody's branch.
git -C "$REPO" worktree prune >/dev/null 2>&1 || true
_co="$(_checkout_for "$TO")" || exit 1
read -r TO_KIND MW <<<"$_co"
if [[ "$TO_KIND" != existing ]]; then CLEANUP_TO=1; say "merging in a throwaway worktree ($MW)"
else say "merging in the existing $TO checkout at $MW"; fi

# Local $TO may be behind origin/$TO — fast-forward it so the merge lands on the real
# tip, not a stale one. (When local $TO is the more advanced side, $DST *is* it: no-op.)
if (( $(_count "$DST" "^$TO") > 0 )); then
  git -C "$MW" merge --ff-only "$DST" >/dev/null 2>&1 || die "could not fast-forward $TO to $DST in $MW"
fi
PREMERGE="$(git -C "$MW" rev-parse HEAD)"

# ── invariant 1: the merge, and only this shape of merge ────────────────────
MSG="promote: $FROM → $TO"
[[ -n "$SUMMARY" ]] && MSG="$MSG — $SUMMARY"
if ! _merr="$(git -C "$MW" merge --no-ff --no-edit "$SRC" -m "$MSG" 2>&1 >/dev/null)"; then
  git -C "$MW" merge --abort >/dev/null 2>&1 || true
  die "merge conflict promoting $FROM → $TO: ${_merr:-conflict} — resolve on $FROM, push, re-run"
fi

# ── post-check: reset and fail rather than leave a bad main ─────────────────
# Also unwinds the back-merge side (FW/FROMPRE) if that step has already started by
# the time something fails — a reverted promote must never leave $FROM half-merged.
_revert() {
  git -C "$MW" reset --hard "$PREMERGE" >/dev/null 2>&1 || true
  [[ -n "$FROMPRE" ]] && git -C "$FW" reset --hard "$FROMPRE" >/dev/null 2>&1 || true
}
NPARENTS=$(( $(git -C "$MW" rev-list --parents -n1 HEAD | wc -w) - 1 ))
if (( NPARENTS != 2 )); then
  _revert; die "the promote commit has $NPARENTS parent(s), expected 2 — that is a squash/fast-forward, not a merge. Nothing changed."
fi
if (( $(git -C "$MW" rev-list --count "$SRC" "^HEAD") != 0 )); then
  _revert; die "after merging, $TO still lacks commits from $SRC — nothing changed."
fi
INTRODUCED="$(git -C "$MW" rev-list --no-merges "$PREMERGE..HEAD" "^$SRC" 2>/dev/null || true)"
if [[ -n "$INTRODUCED" ]]; then
  _revert
  die "the merge would introduce commit(s) absent from $FROM — nothing changed: $(tr '\n' ' ' <<<"$INTRODUCED")"
fi
say "✓ merged $SRC → $TO as a 2-parent merge ($(git -C "$MW" rev-parse --short HEAD))"

# ── back-merge: carry $TO's new tip straight back into $FROM (GSAI-141, invariant 7) ─
# Always conflict-free: the merge above introduced zero content $SRC lacked (invariant
# 2), and $SRC is already an ancestor of $FROM's tip, so three-way-merging $TO's new
# tip into $FROM is either a fast-forward or a true no-op content merge — never a real
# conflict. A failure anywhere here is fatal to the WHOLE promote, not a partial
# success (a promote that moves $TO but leaves $FROM behind just re-introduces
# GSAI-141 one promote at a time) — so every failure path resets $TO back to
# PREMERGE via _revert before dying, same as the post-checks above.
#
# Deliberately --ff here, NOT --no-ff: $FROM typically hasn't moved since $SRC was
# read, and $TO's new tip IS a descendant of $FROM's current tip in that case (one of
# its two parents), so the right outcome is $FROM's ref simply moving to it — zero new
# commits. Forcing --no-ff here (as the forward merge must, for invariant 1) would
# mint a brand-new, never-before-seen commit on $FROM on EVERY run, which $TO would
# then be missing — recreating this exact bug in the opposite direction forever. --ff
# (not bare `merge`, which some configs override via merge.ff=false) still correctly
# falls back to a real merge commit on the race-case path, where $FROM has moved on.
NEWTO="$(git -C "$MW" rev-parse HEAD)"
_co="$(_checkout_for "$FROM")"; rc=$?
if (( rc != 0 )); then
  _revert
  die "back-merge $TO → $FROM could not start (see above) — $TO was reset, nothing changed"
fi
read -r FROM_KIND FW <<<"$_co"
if [[ "$FROM_KIND" != existing ]]; then CLEANUP_FROM=1; say "back-merging $TO into a throwaway worktree on $FROM ($FW)"
else say "back-merging $TO into the existing $FROM checkout at $FW"; fi

# $FROM's local tip may be behind origin/$FROM — same staleness story as $TO above.
if (( ! LOCAL_ONLY )) && (( $(_count "$SRC" "^$FROM") > 0 )); then
  git -C "$FW" merge --ff-only "$SRC" >/dev/null 2>&1 \
    || { _revert; die "could not fast-forward $FROM to $SRC in $FW — $TO was reset, nothing changed"; }
fi
FROMPRE="$(git -C "$FW" rev-parse HEAD)"

if ! _bmerr="$(git -C "$FW" merge --ff --no-edit "$NEWTO" -m "promote: back-merge $TO → $FROM" 2>&1 >/dev/null)"; then
  git -C "$FW" merge --abort >/dev/null 2>&1 || true
  _revert
  die "back-merge $TO → $FROM conflicted (should be impossible — see GSAI-141 design): ${_bmerr:-conflict}. $TO was reset, nothing changed."
fi

# mirror of invariant 1/2, run in the other direction.
if ! git -C "$FW" merge-base --is-ancestor "$NEWTO" HEAD; then
  _revert; die "back-merge $TO → $FROM did not actually carry $TO forward — $TO was reset, nothing changed."
fi
BACK_INTRODUCED="$(git -C "$FW" rev-list --no-merges "$FROMPRE..HEAD" "^$NEWTO" 2>/dev/null || true)"
if [[ -n "$BACK_INTRODUCED" ]]; then
  _revert
  die "back-merge $TO → $FROM would introduce commit(s) absent from $TO — $TO was reset, nothing changed: $(tr '\n' ' ' <<<"$BACK_INTRODUCED")"
fi
say "✓ back-merged $TO → $FROM ($(git -C "$FW" rev-parse --short HEAD)) — $FROM will never fall behind $TO from this promote"

# ── publish ─────────────────────────────────────────────────────────────────
_publish

say "✓ promote complete — set director:merged-main on the issues in this batch:"
git -C "$MW" log --oneline "$PREMERGE..HEAD" | sed 's/^/      /'
