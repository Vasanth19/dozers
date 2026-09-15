#!/usr/bin/env bash
# directors/promote.sh — the ONE way a Director promotes develop → main. (GSAI-104)
#
#   directors/promote.sh <repo-id|path> [--from develop] [--to main]
#                        [--check] [--dry-run] [--no-push] [--summary "<text>"]
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

# ── fetch (invariant 3: origin is the truth) ────────────────────────────────
git -C "$REPO" remote get-url origin >/dev/null 2>&1 \
  || die "no 'origin' remote in $REPO — a promote is measured against origin/$TO, and this checkout has none"
_ferr="$(git -C "$REPO" fetch --prune origin 2>&1 >/dev/null)" \
  || die "git fetch origin failed in $REPO: ${_ferr:-unknown git error}"

_has()  { git -C "$REPO" rev-parse --verify -q "$1^{commit}" >/dev/null 2>&1; }
_count(){ git -C "$REPO" rev-list --count "$@" 2>/dev/null || echo 0; }

for ref in "origin/$FROM" "origin/$TO"; do
  _has "$ref" || die "$ref does not exist after fetch — is '$ref' the right branch name?"
done

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

if [[ "$SRC" == "$FROM" ]]; then
  UNPUSHED_SRC="$(_count "$FROM" "^origin/$FROM")"
  say "local $FROM is $UNPUSHED_SRC commit(s) ahead of origin/$FROM (the Dozer merges locally, push: false)"
  (( PUSH )) && say "   → $FROM will be published first, so origin/$TO never gets a commit origin/$FROM lacks"
fi
[[ "$DST" == "$TO" ]] && say "local $TO is $(_count "$TO" "^origin/$TO") commit(s) ahead of origin/$TO (an earlier promote that was never pushed)"
(( $(_count "origin/$FROM" "^$SRC") == 0 )) || die "internal: $SRC does not contain origin/$FROM"

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
  (( PUSH )) || { say "· push skipped (--no-push) — origin still lacks this promote"; return 0; }
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

AHEAD="$(_count "$SRC" "^$DST")"
if (( AHEAD == 0 )); then
  say "✓ nothing to promote — $DST already contains every commit on $SRC (no-op)"
  # ...but an earlier promote may have been made and never published. Finishing that is
  # still this script's job — otherwise the only way to complete it is hand-rolled git.
  if (( $(_count "$FROM" "^origin/$FROM") > 0 || $(_count "$TO" "^origin/$TO") > 0 )); then
    say "origin is behind this machine — publishing the earlier promote"
    _publish
  fi
  exit 0
fi
say "$AHEAD commit(s) to promote:"
git -C "$REPO" log --oneline "$DST..$SRC" | head -30 | sed 's/^/      /'

if (( CHECK )); then say "✓ check only — $TO is promotable, nothing changed"; exit 0; fi
if (( DRY )); then
  say "✓ dry run — would run: git merge --no-ff $SRC   (on $TO)$( (( PUSH )) && echo ", then push origin$( (( UNPUSHED_SRC > 0 )) && echo " $FROM and") $TO")"
  exit 0
fi

# ── where the merge happens ─────────────────────────────────────────────────
# A branch can be checked out in only ONE worktree. If $TO is already checked out
# somewhere, merge THERE when it is clean (a dirty one is a hard stop — invariant 4);
# otherwise use a throwaway worktree so we never switch anybody's branch.
git -C "$REPO" worktree prune >/dev/null 2>&1 || true
MW=""; CLEANUP_WT=0
_to_at="$(git -C "$REPO" worktree list --porcelain 2>/dev/null \
          | awk -v b="refs/heads/$TO" '/^worktree /{w=$2} $0=="branch "b{print w; exit}')"
if [[ -n "$_to_at" ]]; then
  [[ -z "$(git -C "$_to_at" status --porcelain --untracked-files=no 2>/dev/null)" ]] \
    || die "$TO is checked out dirty at $_to_at — commit or stash there, then re-run"
  MW="$_to_at"
  say "merging in the existing $TO checkout at $MW"
else
  MW="$(mktemp -d "${TMPDIR:-/tmp}/promote-$TO.XXXXXX")"
  rmdir "$MW"
  _werr="$(git -C "$REPO" worktree add "$MW" "$TO" 2>&1 >/dev/null)" \
    || die "could not create a promote worktree on $TO: ${_werr:-unknown git error}"
  CLEANUP_WT=1
  say "merging in a throwaway worktree ($MW)"
fi
_cleanup() { (( CLEANUP_WT )) && { git -C "$REPO" worktree remove --force "$MW" >/dev/null 2>&1 || rm -rf "$MW"; }; }
trap _cleanup EXIT

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
_revert() { git -C "$MW" reset --hard "$PREMERGE" >/dev/null 2>&1 || true; }
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

# ── publish ─────────────────────────────────────────────────────────────────
_publish

say "✓ promote complete — set director:merged-main on the issues in this batch:"
git -C "$MW" log --oneline "$PREMERGE..HEAD" | sed 's/^/      /'
