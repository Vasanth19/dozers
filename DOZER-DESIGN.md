# GSAI-144 — design: `--no-push` must not require an `origin`

**Task:** promote.sh refuses a local-only promote — `--no-push` still requires an
origin, stranding GSAI-142 (`~/ecosystem`, no remote) and BRD-4
(`~/initiatives/brands/mr-growth-guide`, no remote).

**Repo:** dozers (main-only). **Files touched:** `directors/promote.sh`,
`tests/promote-test.sh`. Nothing else.

---

## The bug, precisely

`directors/promote.sh` enforces invariant 3 ("origin is the truth") *before* it ever
considers the `PUSH` flag:

- `directors/promote.sh:81` — dies when there is no `origin` remote, even under
  `--no-push`.
- `directors/promote.sh:89-91` — dies when `origin/$FROM` or `origin/$TO` is missing
  after fetch, even under `--no-push`.

So the one mode that provably needs no origin (merge local develop → local main,
publish nothing) is the one being refused. Every later stage of the script already
works fine on local refs — the refusal is purely at the front door.

## Approach — a `LOCAL_ONLY` mode, gated on BOTH "no origin" and "--no-push"

After args parsing and repo resolution (which stay untouched), replace the
unconditional origin block with:

```
HAS_ORIGIN: does `git remote get-url origin` succeed?
if no origin:
    PUSH  → die (the existing refusal, message updated to mention --no-push as the
             local-only escape hatch) — "Done when" #4, unchanged behavior
    !PUSH → LOCAL_ONLY=1; say "local-only promote — measured against LOCAL <TO>,
             never published" — and SKIP fetch + the origin-ref existence loop
else:
    fetch + origin-ref existence checks exactly as today (a repo WITH an origin
    behaves exactly as it does today — "Done when" #3)
```

`LOCAL_ONLY` is **only** reachable when the repo has no origin remote at all. It is
NOT a "skip the remote checks" flag: with an origin present, `--no-push` keeps the
current semantics (fetch still happens, `origin/$ref` must exist, `_effective` still
picks between local and origin tips). This keeps the spec's "no behaviour change for
repos with an origin" exactly true.

Then every remaining use of `origin/<branch>` is guarded so local-only mode never
touches a remote ref:

1. **`_effective()` (line 110)** — in local-only mode:
   - `refs/heads/$br` missing → `die "no local branch '$br' and no origin to fall
     back on — nothing to promote"` (a fresh clone with neither local develop nor a
     remote gets a clear refusal, not a confusing rev-parse error).
   - otherwise echo `"$br"` — local is the ONLY truth in this mode. No `_rel`
     comparison, no divergence adjudication (there is nothing to diverge from).

   Existing with-origin path byte-identical.

2. **UNPUSHED_SRC block (lines 125-130)** — guarded by `! LOCAL_ONLY`. In local-only
   mode every commit on develop is trivially "unpushed"; the informational lines and
   the internal sanity check at line 131 (`origin/$FROM ⊆ $SRC`) are skipped.

3. **No-op path (lines 174-181)** — the "origin is behind this machine, publishing
   the earlier promote" follow-up is guarded by `! LOCAL_ONLY`; local-only exits 0
   with "nothing to promote" and moves nothing. (In a no-origin repo there IS no
   earlier unpublished promote to finish — that concept doesn't exist.)

4. **`_publish()` (line 153)** — already returns early when `PUSH=0`; extend the
   early-return message to say, in local-only mode, that `<TO>` exists only on this
   machine and a future run after a remote exists is the publishing path. In
   with-origin `--no-push` mode the existing "push skipped (--no-push) — origin still
   lacks this promote" wording is kept.

5. **Header comment** — add invariant 6: "A repo with no `origin` can still promote
   under `--no-push`: local `<TO>` is both the base and the truth, and nothing is
   published. Without `--no-push` a missing origin stays fatal." Update the usage
   line's flag comment likewise.

**What is deliberately NOT changed:**

- The merge itself (line 226): still `git merge --no-ff` on a clean checkout or a
  throwaway worktree; 2-parent post-check, no-squash, no-rebase, never fast-forward.
- Dirty-tree refusal (line 201) — fires identically in local-only mode.
- The stray-commit check (line 138): in local-only mode `$DST`/`$SRC` are the local
  branches, so a hand-rolled hotfix or squash on local main is still refused as
  divergence. Invariant 2 survives the mode.
- Exit codes and idempotency (AHEAD==0 → clean no-op, exit 0).

## Edge cases

| Case | Behavior |
|---|---|
| No origin + no `--no-push` | Hard refusal (unchanged, message now points at `--no-push`) |
| No origin + `--no-push` + no local `develop` | Refused: "no local branch 'develop' and no origin to fall back on" |
| No origin + `--no-push` + no local `main` | Refused, same shape — there is nothing to merge into |
| No origin + `--no-push` + dirty `main` checkout | Refused by the existing dirty guard |
| No origin + `--no-push` + stray commit on local `main` | Refused by invariant 2 (local main vs local develop) |
| No origin + `--check` / `--dry-run` | Report the real gap, touch nothing |
| Second run after a local-only promote | Clean no-op ("nothing to promote", exit 0) |
| Origin present, any flags | Byte-identical to today (mode never engages) |
| Origin present but missing `origin/main` or `origin/develop`, `--no-push` | Unchanged: still fatal after fetch — fixing that is not in this spec |

One real-world nuance the fixture must honor: a plain clone of a bare origin only
has a local `main` — so whatever fixture shape is used, it must end up with a local
`develop` carrying real commits, mirroring `~/ecosystem` where the crew's merge left
a real local `develop` behind. The cleanest shape is a `fixture_localonly()` that
builds the repo **directly** — `git init`, commit base on `main`, branch `develop`,
commit local work, back to `main` — with **no bare origin, no clone, and no remote
ever existing**. That is the purest form of the "no origin" precondition (it matches
`~/ecosystem` and `mr-growth-guide`, where no remote ever existed rather than one
having been removed) and skips the cost of a clone on a slow disk. Do NOT build it
as a clone + `git remote remove origin` — that re-adds clone cost to say nothing the
pure form doesn't already say.

## How it gets tested

`tests/promote-test.sh` gains local-only cases next to the existing no-origin refusal
(test 11). The fixture helper is reused; the local-only variant builds local develop
work in the clone first, then `git remote remove origin`:

- **11b — no origin + `--no-push --check`**: exit 0, "promotable", origin untouched
  (n/a), and — the "Done when" #1 shape — the run reports the commit gap rather than
  refusing.
- **11c — no origin + `--no-push`**: exit 0; local `main` in the clone gains the
  2-parent merge; `git rev-list --count main..develop` == 0; output contains the
  local-only/"not published" line (the "Done when" #2 shape).
- **11d — no origin + `--no-push`, dirty `main` checkout**: exit 1, "dirty" in
  output, local `main` unmoved — the dirty guard is proven intact in the new mode.
- **11e — second run**: exit 0, "nothing to promote", no further movement
  (idempotency holds with no origin).
- **Test 11 (existing) tightened**: no origin without `--no-push` still exit 1 and
  now also asserts the message mentions `--no-push`.

All existing tests must keep passing untouched — they are the proof that
with-origin behavior is unchanged. The suite runs offline against throwaway fixtures
(bare origin + clone), consistent with the file's existing style; no new helpers
beyond a small `fixture_localonly()`-style block, reusing `run`, `parents`, and the
established ok/bad pattern.

## Risk

Low. The change is a guarded front-door + four `! LOCAL_ONLY` guards; the merge
machinery and every post-merge invariant are untouched. The main hazard is
accidentally engaging the mode for repos that DO have an origin — prevented by
gating on `HAS_ORIGIN=0` explicitly rather than on `--no-push` alone. Second hazard:
a silent `_rel`/`origin/…` rev-parse inside local-only mode would produce a
misleading "does not exist" refusal — mitigated by the dedicated missing-local-branch
die in `_effective`, which is the ONLY branch-tip resolution in that mode.

## Post-merge verification (for the Dev-Director, not this pass)

- `promote.sh ~/ecosystem --no-push --check` → reports the 2-commit GSAI-142 gap.
- `promote.sh ~/ecosystem --no-push --summary "GSAI-142"` → 2-parent merge on local
  `main` of `~/ecosystem`, explicit not-published line.
- Same for BRD-4 in `~/initiatives/brands/mr-growth-guide` (5 commits).
- Whether `~/ecosystem` should gain a remote at all stays a human board decision —
  this task unblocks the promote either way.