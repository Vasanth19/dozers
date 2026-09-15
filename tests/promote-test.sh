#!/usr/bin/env bash
# tests/promote-test.sh — regression for GSAI-104: a promote is a --no-ff merge, or it
# does not happen.
#
# On 2026-09-09 a hand-rolled promote in cfw-social squashed develop into main
# (`fa85bddc`, ONE parent). New hashes landed on main that develop had never seen, so
# origin/main and origin/develop stopped sharing recent history and every subsequent
# gap check lied; CFW-250 was the cleanup. directors/promote.sh is the fix — this test
# is what keeps it true.
#
# Everything runs against throwaway fixture repos (a bare "origin" + a clone) — no
# network, no Linear, no ecosystem registry: the script is handed a path, not an id.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMOTE="$ROOT/directors/promote.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=dozer-test GIT_AUTHOR_EMAIL=dozer@test.local
export GIT_COMMITTER_NAME=dozer-test GIT_COMMITTER_EMAIL=dozer@test.local

# ── fixture: bare origin with main + develop, and a clone checked out on main ──
fixture() {
  local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git init -q "$d/src"
  git -C "$d/src" symbolic-ref HEAD refs/heads/main
  echo base > "$d/src/app.txt"
  git -C "$d/src" add -A && git -C "$d/src" commit -qm "base"
  git -C "$d/src" branch develop
  git -C "$d/src" remote add origin "$d/origin.git"
  git -C "$d/src" push -q origin main develop
  git -C "$d/origin.git" symbolic-ref HEAD refs/heads/main   # so the clone checks main out
  git clone -q "$d/origin.git" "$d/clone"
  echo "$d"
}
# add a commit on develop and publish it (the Dozer's merged-develop state)
on_develop() {   # on_develop <fixture-dir> <text>
  local d="$1" t="$2"
  git -C "$d/src" checkout -q develop
  echo "$t" >> "$d/src/app.txt"
  git -C "$d/src" add -A && git -C "$d/src" commit -qm "$t"
  git -C "$d/src" push -q origin develop
}
# fixture_localonly: a repo WITH local main + develop work and NO origin at all —
# mirrors ~/ecosystem (GSAI-142) and ~/initiatives/brands/mr-growth-guide (BRD-4),
# where no remote ever existed. Built directly (no bare origin, no clone, no
# `remote remove`) so the "no origin" precondition is the purest possible form and
# the fixture costs a fraction of a clone on a slow disk.
fixture_localonly() {
  local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d"
  git init -q "$d/clone"
  git -C "$d/clone" symbolic-ref HEAD refs/heads/main
  echo base > "$d/clone/app.txt"
  git -C "$d/clone" add -A && git -C "$d/clone" commit -qm "base"
  git -C "$d/clone" checkout -q -b develop
  echo "local work" >> "$d/clone/app.txt"
  git -C "$d/clone" add -A && git -C "$d/clone" commit -qm "local develop work"
  git -C "$d/clone" checkout -q main
  echo "$d"
}
omain()   { git -C "$1/origin.git" rev-parse main; }               # published main tip
parents() { echo $(( $(git -C "$1/origin.git" rev-list --parents -n1 "${2:-main}" | wc -w) - 1 )); }
gap()     { git -C "$1/origin.git" rev-list --count main..develop; }   # must be 0 after a promote
run()     { (cd "$1/clone" && "$PROMOTE" "$1/clone" "${@:2}" 2>&1); }

# ── 1. the happy path: develop ahead, main a strict ancestor ──────────────────
# A bare `git merge` here would FAST-FORWARD — no merge commit, nothing to revert, no
# record of the promote. The script must produce 2 parents anyway.
d="$(fixture happy)"; on_develop "$d" "feature-one"; before="$(omain "$d")"
out="$(run "$d" --summary "CFW-252, CFW-253")"; rc=$?
(( rc == 0 )) && ok "happy: exit 0" || bad "happy: exit $rc — $out"
[[ "$(omain "$d")" != "$before" ]] && ok "happy: main moved" || bad "happy: main did not move"
[[ "$(parents "$d")" == "2" ]] && ok "happy: 2-parent merge commit (not a squash, not a ff)" \
  || bad "happy: main tip has $(parents "$d") parent(s) — the GSAI-104 bug"
[[ "$(gap "$d")" == "0" ]] && ok "happy: origin/main..origin/develop empty" || bad "happy: gap is $(gap "$d")"
git -C "$d/origin.git" log -1 --format=%s main | grep -q "promote: develop → main — CFW-252, CFW-253" \
  && ok "happy: summary lands in the merge message" || bad "happy: message is '$(git -C "$d/origin.git" log -1 --format=%s main)'"

# ── 2. idempotent: running it again promotes nothing ──────────────────────────
before="$(omain "$d")"
out="$(run "$d")"; rc=$?
(( rc == 0 )) && [[ "$(omain "$d")" == "$before" ]] && grep -q "nothing to promote" <<<"$out" \
  && ok "second run is a clean no-op" || bad "second run: exit $rc, main moved=$([[ "$(omain "$d")" == "$before" ]] && echo no || echo yes) — $out"

# ── 3. the regression itself: a squashed promote is refused, not compounded ───
# Recreate fa85bddc — someone hand-rolls `merge --squash` onto main. main now carries a
# commit develop has never seen. The script must refuse and name the divergence.
d="$(fixture squashed)"; on_develop "$d" "feature-one"
git -C "$d/src" checkout -q main
git -C "$d/src" merge -q --squash develop >/dev/null && git -C "$d/src" commit -qm "promote: develop → main (squashed)"
git -C "$d/src" push -q origin main
before="$(omain "$d")"
on_develop "$d" "feature-two"
out="$(run "$d")"; rc=$?
(( rc == 1 )) && ok "squashed main: refused (exit 1)" || bad "squashed main: exit $rc — $out"
[[ "$(omain "$d")" == "$before" ]] && ok "squashed main: main untouched" || bad "squashed main: main was moved anyway"
grep -q "do not exist on origin/develop" <<<"$out" && ok "squashed main: names the divergence" || bad "squashed main: unhelpful message — $out"
grep -q "merge main back into develop" <<<"$out" && ok "squashed main: prints the reconcile step" || bad "squashed main: no reconcile hint — $out"

# ── 4. work committed straight to main (no squash, same disease) ─────────────
d="$(fixture hotfix)"; on_develop "$d" "feature-one"
git -C "$d/src" checkout -q main
echo hotfix >> "$d/src/app.txt"; git -C "$d/src" add -A && git -C "$d/src" commit -qm "hotfix on main"
git -C "$d/src" push -q origin main
before="$(omain "$d")"
out="$(run "$d")"; rc=$?
(( rc == 1 )) && [[ "$(omain "$d")" == "$before" ]] && ok "commit straight to main: refused, main untouched" \
  || bad "commit straight to main: exit $rc — $out"

# ── 5. a dirty main checkout is a hard stop ──────────────────────────────────
d="$(fixture dirty)"; on_develop "$d" "feature-one"; before="$(omain "$d")"
echo "uncommitted" >> "$d/clone/app.txt"
out="$(run "$d")"; rc=$?
(( rc == 1 )) && grep -qi "dirty" <<<"$out" && [[ "$(omain "$d")" == "$before" ]] \
  && ok "dirty checkout: refused, main untouched" || bad "dirty checkout: exit $rc — $out"

# ── 6. local main ahead of origin — never publish local-only work as a promote ─
d="$(fixture localahead)"; on_develop "$d" "feature-one"; before="$(omain "$d")"
echo local >> "$d/clone/app.txt"
git -C "$d/clone" add -A && git -C "$d/clone" commit -qm "local-only commit on main"
out="$(run "$d")"; rc=$?
(( rc == 1 )) && grep -q "do not exist on" <<<"$out" && [[ "$(omain "$d")" == "$before" ]] \
  && ok "local-only commit on main: refused, main untouched" || bad "local-only commit on main: exit $rc — $out"

# ── 7. a stale local main is fast-forwarded, not treated as divergence ───────
# The "scary 70 behind" case: the Director's clone never fetched. It must still promote.
d="$(fixture stale)"; on_develop "$d" "feature-one"
git -C "$d/src" checkout -q main
git -C "$d/src" merge -q --no-ff develop -m "earlier promote"
git -C "$d/src" push -q origin main                    # clone's main is now 2 behind
on_develop "$d" "feature-two"
out="$(run "$d")"; rc=$?
(( rc == 0 )) && [[ "$(gap "$d")" == "0" ]] && [[ "$(parents "$d")" == "2" ]] \
  && ok "stale local main: fast-forwarded then promoted" || bad "stale local main: exit $rc, gap $(gap "$d") — $out"

# ── 6b. the Dozer's reality: develop is merged LOCALLY and never pushed ─────
# org/config.yaml sets push: "false", so origin/develop is behind by design and the work
# to promote exists only on this machine. Promoting must still work — and must publish
# develop first, or origin/main ends up holding commits origin/develop has never seen.
d="$(fixture localdevelop)"
git -C "$d/clone" fetch -q origin
git -C "$d/clone" checkout -q -B develop origin/develop
echo "dozer merged this locally" >> "$d/clone/app.txt"
git -C "$d/clone" add -A && git -C "$d/clone" commit -qm "merge dozer/CFW-1 into develop"
git -C "$d/clone" checkout -q main
out="$(run "$d")"; rc=$?
(( rc == 0 )) && ok "local-only develop: promoted (exit 0)" || bad "local-only develop: exit $rc — $out"
[[ "$(parents "$d")" == "2" ]] && ok "local-only develop: 2-parent merge on main" || bad "local-only develop: $(parents "$d") parent(s)"
[[ "$(git -C "$d/origin.git" rev-parse develop)" == "$(git -C "$d/clone" rev-parse develop)" ]] \
  && ok "local-only develop: develop published before main" || bad "local-only develop: origin/develop left behind main"
[[ "$(gap "$d")" == "0" ]] && ok "local-only develop: origin/main..origin/develop empty" || bad "local-only develop: gap $(gap "$d")"

# ── 6c. --no-push leaves BOTH branches unpublished, never just one ──────────
d="$(fixture localdevelop_nopush)"
git -C "$d/clone" checkout -q -B develop origin/develop
echo local >> "$d/clone/app.txt"; git -C "$d/clone" add -A && git -C "$d/clone" commit -qm "local develop work"
git -C "$d/clone" checkout -q main
odev_before="$(git -C "$d/origin.git" rev-parse develop)"
out="$(run "$d" --no-push)"; rc=$?
(( rc == 0 )) && [[ "$(git -C "$d/origin.git" rev-parse develop)" == "$odev_before" ]] \
  && ok "--no-push: develop is not published either" || bad "--no-push: exit $rc, origin/develop moved — $out"

# ── 6d. an unpushed EARLIER promote on local main is resumable, not divergence ─
# Its extra commits are a merge plus develop's own work — nothing main-only. Promote on.
d="$(fixture unpushedpromote)"; on_develop "$d" "feature-one"
"$PROMOTE" "$d/clone" --no-push >/dev/null 2>&1
on_develop "$d" "feature-two"
out="$(run "$d")"; rc=$?
(( rc == 0 )) && [[ "$(gap "$d")" == "0" ]] && ok "unpushed earlier promote: resumes and promotes" \
  || bad "unpushed earlier promote: exit $rc, gap $(gap "$d") — $out"

# ── 6d-ii. an unpublished promote is FINISHED by re-running the script ──────
# Otherwise the only way to complete it is the hand-rolled git this script replaces.
d="$(fixture unpublished)"; on_develop "$d" "feature-one"
"$PROMOTE" "$d/clone" --no-push >/dev/null 2>&1
before="$(omain "$d")"
out="$(run "$d")"; rc=$?
(( rc == 0 )) && [[ "$(omain "$d")" != "$before" ]] && [[ "$(parents "$d")" == "2" ]] && [[ "$(gap "$d")" == "0" ]] \
  && ok "unpublished promote: re-running publishes it" || bad "unpublished promote: exit $rc — $out"
after="$(omain "$d")"; out="$(run "$d")"; rc=$?
(( rc == 0 )) && [[ "$(omain "$d")" == "$after" ]] && grep -q "nothing to promote" <<<"$out" \
  && ok "and then it is a true no-op" || bad "third run: exit $rc — $out"

# ── 6e. local and origin develop DIVERGED → a human call, never an improvised merge ─
d="$(fixture divergeddevelop)"; on_develop "$d" "pushed-work"
git -C "$d/clone" fetch -q origin
git -C "$d/clone" checkout -q -B develop origin/develop~1        # fork before the pushed commit
echo other >> "$d/clone/app.txt"; git -C "$d/clone" add -A && git -C "$d/clone" commit -qm "local-only develop work"
git -C "$d/clone" checkout -q main
before="$(omain "$d")"
out="$(run "$d")"; rc=$?
(( rc == 1 )) && grep -q "DIVERGED" <<<"$out" && [[ "$(omain "$d")" == "$before" ]] \
  && ok "develop diverged from origin: refused, main untouched" || bad "develop diverged: exit $rc — $out"

# ── 8. --check and --dry-run report without touching anything ────────────────
d="$(fixture readonly)"; on_develop "$d" "feature-one"; before="$(omain "$d")"
out="$(run "$d" --check)"; rc=$?
(( rc == 0 )) && [[ "$(omain "$d")" == "$before" ]] && grep -q "promotable" <<<"$out" \
  && ok "--check: reports promotable, changes nothing" || bad "--check: exit $rc — $out"
out="$(run "$d" --dry-run)"; rc=$?
(( rc == 0 )) && [[ "$(omain "$d")" == "$before" ]] && grep -q "dry run" <<<"$out" \
  && ok "--dry-run: changes nothing" || bad "--dry-run: exit $rc — $out"

# ── 9. --no-push merges locally and leaves origin alone ─────────────────────
out="$(run "$d" --no-push)"; rc=$?
(( rc == 0 )) && [[ "$(omain "$d")" == "$before" ]] && ok "--no-push: origin/main untouched" \
  || bad "--no-push: exit $rc, origin moved — $out"
[[ "$(git -C "$d/clone" rev-parse main)" != "$before" ]] \
  && [[ $(( $(git -C "$d/clone" rev-list --parents -n1 main | wc -w) - 1 )) == 2 ]] \
  && ok "--no-push: local main has the 2-parent merge" || bad "--no-push: local main did not get the merge"

# ── 10. no checkout of main in the repo → throwaway worktree, same guarantees ─
d="$(fixture detached)"; on_develop "$d" "feature-one"
git -C "$d/clone" checkout -q -B develop origin/develop      # main is checked out nowhere
out="$(run "$d")"; rc=$?
(( rc == 0 )) && [[ "$(parents "$d")" == "2" ]] && [[ "$(gap "$d")" == "0" ]] \
  && ok "main not checked out: promotes via a throwaway worktree" || bad "main not checked out: exit $rc — $out"
[[ -z "$(git -C "$d/clone" worktree list --porcelain | awk '/^worktree /{print $2}' | tail -n +2)" ]] \
  && ok "throwaway worktree is cleaned up" || bad "throwaway worktree left behind: $(git -C "$d/clone" worktree list)"

# ── 10b. no LOCAL main branch at all (a fresh clone that only ever saw develop) ──
d="$(fixture nolocalmain)"; on_develop "$d" "feature-one"
git -C "$d/clone" checkout -q -B develop origin/develop
git -C "$d/clone" branch -q -D main
out="$(run "$d")"; rc=$?
(( rc == 0 )) && [[ "$(parents "$d")" == "2" ]] && [[ "$(gap "$d")" == "0" ]] \
  && ok "no local main branch: promotes off origin/main" || bad "no local main branch: exit $rc — $out"

# ── 11. refusals that need no repo state ────────────────────────────────────
d="$(fixture noremote)"
git -C "$d/clone" remote remove origin
out="$(run "$d")"; rc=$?
(( rc == 1 )) && grep -q "no 'origin' remote" <<<"$out" && grep -q -- "--no-push" <<<"$out" \
  && ok "no origin remote: refused, points at --no-push" || bad "no origin: exit $rc — $out"

# ── 11b. no origin + --no-push --check: report the gap, refuse nothing ──────
d="$(fixture_localonly localonly_check)"
before="$(git -C "$d/clone" rev-parse main)"
out="$(run "$d" --no-push --check)"; rc=$?
(( rc == 0 )) && grep -q "commit(s) to promote" <<<"$out" && grep -q "promotable" <<<"$out" \
  && [[ "$(git -C "$d/clone" rev-parse main)" == "$before" ]] \
  && ok "local-only --check: reports the gap, changes nothing" || bad "local-only --check: exit $rc — $out"

# ── 11c. no origin + --no-push: the promote GSAI-142 and BRD-4 are blocked on ─
d="$(fixture_localonly localonly)"
out="$(run "$d" --no-push --summary "GSAI-142")"; rc=$?
(( rc == 0 )) && ok "local-only: promote exits 0" || bad "local-only: exit $rc — $out"
[[ $(( $(git -C "$d/clone" rev-list --parents -n1 main | wc -w) - 1 )) == 2 ]] \
  && ok "local-only: 2-parent merge on local main" || bad "local-only: local main is not a 2-parent merge"
[[ "$(git -C "$d/clone" rev-list --count main..develop)" == "0" ]] \
  && ok "local-only: local main..develop empty" || bad "local-only: gap $(git -C "$d/clone" rev-list --count main..develop)"
grep -q "never published" <<<"$out" && ok "local-only: says nothing is published" || bad "local-only: no not-published line — $out"

# ── 11d. no origin + --no-push + dirty main: the dirty guard is intact ──────
d="$(fixture_localonly localonly_dirty)"
before="$(git -C "$d/clone" rev-parse main)"
echo "uncommitted" >> "$d/clone/app.txt"
out="$(run "$d" --no-push)"; rc=$?
(( rc == 1 )) && grep -qi "dirty" <<<"$out" && [[ "$(git -C "$d/clone" rev-parse main)" == "$before" ]] \
  && ok "local-only dirty main: refused, main untouched" || bad "local-only dirty main: exit $rc — $out"

# ── 11e. a second local-only run is a clean no-op (idempotency, no origin) ──
d="$(fixture_localonly localonly_twice)"
"$PROMOTE" "$d/clone" --no-push >/dev/null 2>&1
before="$(git -C "$d/clone" rev-parse main)"
out="$(run "$d" --no-push)"; rc=$?
(( rc == 0 )) && grep -q "nothing to promote" <<<"$out" && [[ "$(git -C "$d/clone" rev-parse main)" == "$before" ]] \
  && ok "local-only: second run is a clean no-op" || bad "local-only second run: exit $rc — $out"

out="$("$PROMOTE" "$TMP/nope-not-a-repo-or-id" 2>&1)"; rc=$?
(( rc == 1 )) && ok "unknown repo id: refused (never guesses a repo)" || bad "unknown repo id: exit $rc — $out"

d="$(fixture samebranch)"
out="$(run "$d" --from main)"; rc=$?
(( rc == 1 )) && ok "--from == --to: refused" || bad "--from == --to: exit $rc — $out"

out="$("$PROMOTE" 2>&1)"; rc=$?
(( rc == 2 )) && ok "no args: usage (exit 2)" || bad "no args: exit $rc"

# ── 12. the script itself may never contain a squash or rebase promote ──────
grep -vE '^[[:space:]]*#' "$PROMOTE" | grep -qE '\-\-squash|rebase' \
  && bad "promote.sh has a --squash / rebase code path" \
  || ok "promote.sh has no --squash / rebase code path (comments aside)"

echo
if (( fail == 0 )); then echo "promote-test: PASS — $pass checks"; exit 0; fi
echo "promote-test: FAIL — $fail failed, $pass passed" >&2; exit 1
