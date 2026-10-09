# DOZER-DESIGN-GSAI-141

## Task

Promote has no back-merge — `develop` falls one commit behind `main` on every
promote, so every Dozer branch builds on a rotting base.

## Confirmed root cause

`directors/promote.sh` implements the promote as `git merge --no-ff $FROM` committed
*onto* `$TO` (main) — invariant 1 in its own header. That produces a 2-parent merge
commit `M` on `main` whose parents are `(old main tip, develop tip)`. The script
pushes `main` (and `develop`, if it was locally ahead) and stops. **Nothing ever
carries `M` back onto `develop`.** So after every single promote, `main` is exactly
one commit ahead of `develop` — and `develop` never catches up, because the next
promote only ever walks `develop → main`, never the reverse.

This is not hypothetical — it's the live state of this repo right now:

```
$ git rev-list --count origin/develop..origin/main   # commits on main, absent from develop
28
$ git rev-list --count --merges origin/develop..origin/main
28
$ git rev-list --count --no-merges origin/develop..origin/main
0
```

All 28 are merge commits — one per historical promote — and zero are content
commits, which confirms invariant 2 (main never carries stray *content*) is intact.
The bug is purely structural: `develop`'s tip is never updated to descend from the
promote merge commit that `main` just received.

**Why this matters beyond cosmetics:** `dozers/dev-lane/crew.sh` cuts every new
`dozer/<id>` worktree from local `develop` (`INTEG="${INTEGRATION_BRANCH:-$(cfg
integration_branch)}"`, defaulting to `develop`, crew.sh:462,1007). Because `develop`
never absorbs the promote merge commits, that base drifts further from `main` with
every promote cycle — the "rotting base" in the task title. Today it's cosmetically
safe (invariant 2 guarantees the drift is 100% merge-commit scaffolding, zero content),
but it's a landmine: `git log develop..main` grows forever, any future tooling that
assumes `main` content ⊆ `develop` history (ancestry, not just tree-equality) breaks
silently, and a human skimming `git log` sees main permanently "ahead" with no way to
tell if that's the harmless kind or a real divergence.

## Approach

Add a **back-merge step** to `directors/promote.sh`, run immediately after the
`develop → main` merge is committed (post-check-verified) and *before* anything is
published. Mechanically it's the mirror image of the existing merge:

```
git merge --no-ff <new main tip>   # run on develop's checkout, merging main INTO develop
```

### Why this is always conflict-free

`M`'s tree is identical to `$SRC`'s tree (the merge introduced zero new content —
invariant 2 guarantees `$TO` has no content `$SRC` lacks, so merging `$SRC` into
`$TO` is a content no-op that only adds the merge edge). `$SRC` is already an
ancestor of `develop`'s current tip (it *was* develop's tip when the promote script
read it, possibly a commit or more behind if the Dozer landed new work on `develop`
in the interim — see race case below). Three-way-merging `M` into `develop`'s current
tip therefore always has an empty diff against the `$SRC` merge-base: there is never
a conflict, only ever a fast-forward (if `develop` hasn't moved since) or a true
no-op content merge commit (if it has). `git merge --no-ff` handles both: it creates
the linking commit either way, and only refuses to create one if `develop` *already*
contains `M` (truly nothing to do).

### Where it runs

Reuse the exact worktree-location pattern the script already uses for `$TO`
(`directors/promote.sh:226-244`, the `_to_at` lookup + dirty-check + throwaway-worktree
fallback), generalized into a helper `_checkout_for <branch>` callable for both `$TO`
and `$FROM`:
- if `$FROM` is already checked out somewhere (likely — `dev-lane/crew.sh` comments
  confirm "the main checkout sits on develop" is a real, common layout), merge there,
  after confirming it's clean (same dirty-checkout hard-stop as invariant 4).
- otherwise, create a throwaway worktree on `$FROM`, same as the `$TO` path, cleaned
  up via the same `trap _cleanup EXIT`.

### Ordering and atomicity

Current order is: merge → post-check → publish. New order:

1. merge `$SRC` into `$TO` (unchanged) → produces `M`, post-checked (unchanged,
   invariants 1/2/4 as today).
2. **new:** back-merge `$TO`'s new tip into `$FROM`'s checkout → produces `N` (or a
   fast-forward). Post-check: confirm `$FROM`'s new tip now contains `M`
   (`git merge-base --is-ancestor <TO tip> <FROM tip>`), and confirm no non-merge
   commits were introduced on `$FROM` that didn't already exist on `$TO`'s merge (a
   mirror of invariant 2, run in the other direction — belt-and-suspenders, since the
   conflict-free argument above says this can't happen, but "can't happen" is exactly
   what invariant 2 already defends against on the other side).
3. **if step 2 fails for any reason** (dirty `$FROM` checkout, merge-base check
   fails, anything) — treat it as fatal to the *whole* promote: reset `main` back to
   `PREMERGE` (the existing `_revert` helper) and die, same as any other post-check
   failure today. This is the atomicity call: a promote that moves `main` but leaves
   `develop` behind would just be re-introducing GSAI-141 one promote at a time, so
   it's not an acceptable partial-success state. Nothing publishes until *both* sides
   are merged locally.
4. publish (`_publish`, mostly unchanged) — now pushes `$FROM`'s new tip (containing
   `N`/the fast-forward) in addition to `$TO`. `_publish`'s existing "push `$FROM` if
   locally ahead of `origin/$FROM`" branch already covers this correctly once `$FROM`'s
   local tip has moved — no separate push call needed, just confirm the ahead-count it
   reads is taken *after* the back-merge, not before.

### Self-healing existing drift

The no-op path (`AHEAD == 0`, directors/promote.sh:203-212 today) currently only
re-publishes an already-made-but-unpushed promote. Extend it: even when there's
nothing new to promote, check whether `$DST` (main) already contains commits `$FROM`
(develop) lacks (exactly this repo's 28-commit drift). If so, run the same back-merge
step there too, so the **next real promote on any already-drifted repo heals the
drift in the same pass that does new work** — no separate migration script, no manual
`git merge` by a Director. `--check`/`--dry-run` must still touch nothing: they should
*report* the existing gap (`git rev-list --count $SRC..$DST`) as part of their output
so a Director can see the drift coming, but only a real run performs the heal.

### Interaction with existing modes

- **`--no-push` / `LOCAL_ONLY` (no origin):** the back-merge is a local git operation
  — it runs exactly the same, it just doesn't get published. No special-casing needed
  beyond what `_publish` already does.
- **`--check`:** unchanged — exits after reporting, before any merge. Extend its
  report line to also surface the reverse gap (`$FROM` vs `$DST`) so a Director sees
  "28 commits to promote AND 1 commit develop is missing from a past promote" instead
  of just the forward count.
- **`--dry-run`:** extend the printed plan to mention the back-merge step
  (`... then merge $TO back into $FROM so develop never falls behind ...`).

### Known edge case — left as a documented limitation, not solved here

A Dozer dev-lane crew could be mid-merge into `develop`'s checkout at the exact
moment a Director runs a promote. The dirty-checkout hard stop (invariant 4, reused
for the back-merge) protects against clobbering a concurrent write that's already in
progress when the back-merge *starts*, but there's no lock preventing a crew from
starting a merge in the gap between promote.sh's dirty-check and its own merge
command. This repo has no cross-process lock on `develop`'s checkout today (the
existing forward merge has the identical exposure and nobody's filed it), so this
design doesn't add one either — flagging it here in case `GSAI-141`'s reviewer wants
a follow-up ticket for a `~/.dozers/locks/`-style mkdir lock around the whole
promote, forward and back merges both.

## Files to touch

1. **`directors/promote.sh`** — the fix. Specifically:
   - generalize the `_to_at` worktree-lookup block into a reusable helper for any
     branch name.
   - add the back-merge step + its post-check, between the existing post-check
     (line ~269) and `_publish()` (line ~278).
   - extend the `AHEAD == 0` no-op branch to detect and heal pre-existing reverse
     drift.
   - extend `--check` output and the `--dry-run` printed plan.
   - add invariant 7 to the header comment block (lines 18-36) documenting the
     back-merge guarantee, matching the style of invariants 1-6.
2. **`tests/promote-test.sh`** — regression coverage (see below). No other test file
   references promote mechanics directly.

No other file needs a code change. `directors/LINEAR.md` and `directors/dev-director.md`
already describe promote purely as "run `directors/promote.sh`, never hand-roll the
git" — that stays true and doesn't need editing.

## Tests

All added to `tests/promote-test.sh`, reusing its existing fixture helpers
(`fixture`, `fixture_localonly`, `on_develop`, `run`) plus two new assertion helpers:

- `gap_rev(d)` = `git -C "$d/origin.git" rev-list --count develop..main` — commits on
  `main` absent from `develop`. Must be **0** after any successful promote; this is
  the literal regression check for GSAI-141 (today it would read `1` after a single
  promote, growing by 1 each cycle).
- `is_ancestor(d, anc, desc)` = `git -C "$d/origin.git" merge-base --is-ancestor "$anc" "$desc"` —
  used to assert `main` is a real ancestor of `develop` post-promote, not just
  tree-equal.

Test additions:

1. **Extend the existing "happy path" test (case 1)** with `gap_rev` == 0 and
   `is_ancestor main develop` after the promote — this is the core fix, asserted
   right alongside the existing "2-parent merge commit" and "gap == 0" checks that
   are already there for the forward direction.
2. **Extend the existing idempotent-rerun test (case 2)** to also assert `gap_rev`
   stays 0 after the no-op second run (proves the back-merge commit itself doesn't
   somehow reopen the gap).
3. **New: sequential promotes stay caught up.** Two rounds of `on_develop` + `run`
   in the same fixture (mirrors "every promote" in the task title — this is the
   shape that actually accumulates drift today). Assert `gap_rev == 0` after each
   round, not just the first.
4. **New: develop moves between snapshot and back-merge (the race-adjacent case).**
   After the first `on_develop` commit but *before* running promote, there's no way
   to inject a commit mid-script without instrumenting the script, so this is
   approximated the practical way: run promote once, then `on_develop` a second
   commit, then run promote again. By the second run, `develop`'s tip has moved past
   what the first promote's back-merge linked — proving the back-merge logic handles
   "`$FROM` has advanced since the last back-merge" (a real no-ff merge, not a trivial
   fast-forward) rather than only ever being exercised in the fast-forward case.
5. **New: `--no-push` / `LOCAL_ONLY` still closes the gap locally.** Using
   `fixture_localonly`, assert `gap_rev` against the **local** clone (no
   `origin.git` exists in this fixture) is 0 after a `--no-push` promote, proving the
   back-merge isn't gated on publishing.
6. **New: pre-existing drift is healed by a later no-op promote.** Build a fixture
   where `main` already has one merge-commit of drift and `develop` has nothing new
   to offer (simulates this repo's actual 28-commit state, minted by the
   *unpatched* script before this fix ships): manually run the old two-step
   (`merge --no-ff` onto `main`, no back-merge) once to seed the drift, then call the
   *patched* `promote.sh` with nothing new on `develop`. Assert it takes the
   `AHEAD == 0` branch (still reports "nothing to promote") but still drives
   `gap_rev` to 0 — i.e., healing doesn't require there to be new work.
7. **New: `--check` and `--dry-run` remain side-effect-free** even when reverse
   drift exists (seed drift as in #6, run `--check` then `--dry-run`, assert
   `gap_rev` is still nonzero afterward and no commits/worktrees were created) —
   guards against the self-heal accidentally leaking into the read-only modes.

All new tests run against the same throwaway bare-origin-plus-clone fixtures already
in the file — no network, no Linear, no ecosystem registry involved, consistent with
the rest of the suite.
