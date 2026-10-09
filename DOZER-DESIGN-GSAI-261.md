# DOZER-DESIGN-GSAI-261

## Title
[ENG] Dev-lane test gate fails on every Next.js/Turbopack repo — symlinked worktree node_modules is rejected

## Root cause (confirmed)

`dozers/dev-lane/crew.sh` never installs dependencies fresh in a task/merge worktree
when the real checkout already has them. Instead `link_deps` / `link_deps_dir`
(crew.sh:177-197) symlink the host checkout's `node_modules` straight into the
worktree:

```
ln -s "$s/$x" "$t/$x"     # $x includes "node_modules"
```

Turbopack (`next dev --turbo` / `next build --turbopack`, default since Next.js 15)
refuses to resolve any file whose real path falls outside the project root it
auto-detects (nearest lockfile upward from cwd). A symlinked `node_modules` resolves
(via `realpath`) to the **real checkout**, which sits in a completely different
directory tree from the worktree (`~/.dozers/worktrees/<repo>-<issue>` vs. wherever
`ecosystem.yaml` points the project). Every module pulled through that symlink is
"outside the project root" from Turbopack's point of view, so it aborts before a
single test runs. This is not a flaky edge case — it fires on the first
`npm test`/`next build` call in **every** Next.js/Turbopack repo, every time,
confirmed independently against `org/config.yaml`'s own focus-gate note on DLY-7:
*"dies at the gate in 5s because Turbopack rejects the worktree node_modules symlink
(points outside the filesystem root)"* — the exact mechanism, already observed live,
already named as the same defect as this issue (GSAI-261) and blocking
`CFW: Sellable V1` too.

Turbopack has no env-var escape hatch for this — only a `next.config.js`
`turbopack.root` (legacy `experimental.turbo.root`) field, which lives in the
*target repo's own app code*. Requiring every onboarded Next.js repo to carry
Dozer-specific config just to tolerate the Dozer's worktree model is the wrong
layer for the fix (GSAI-261 is explicitly framed as an infra defect hitting *every*
repo of this type, not a per-repo config gap) and silently breaks the day someone
edits that file for an unrelated reason.

## Approach

Stop symlinking `node_modules` across the worktree boundary. Materialize it as a
**real, independent copy physically inside the worktree**, using an APFS
copy-on-write clone (`cp -Rc`) so it stays as cheap and instant as a symlink. Every
file Turbopack resolves through `node_modules` then has a real path *inside* the
worktree — the same root it already auto-detects from the worktree's own lockfile —
so the rejection never triggers, for Turbopack or any other tool that does the same
root-boundary check. This fixes the bug at the structural level instead of special
casing Next.js: a symlink that points a worktree's dependency tree outside that
worktree is the wrong model for *any* sandboxed resolver, Turbopack is just the
first one that enforces it.

`.env` / `.env.local` / `.env.development` stay plain symlinks (crew.sh:176,
`DEP_ENTRIES`) — they're single small files nothing does root-boundary resolution
through, so there's no bug to fix there and no reason to pay a copy cost for them.

### Why clone, not a real `npm ci`/`pnpm install` every time

The existing stamp/drift machinery (`deps_drifted`, `deps_stamp`,
`install_deps`, crew.sh:212-290) already exists precisely to avoid a real install
when nothing changed. The clone is the **fast path that feeds that machinery** —
it's the direct replacement for `ln -s`, not a replacement for `install_deps`.
`cp -Rc` on APFS is a metadata-only copy-on-write operation: no bytes are
duplicated on disk, and it costs roughly the time to walk the tree (low
single-digit seconds for a large `node_modules`), not the time to re-resolve and
re-install packages. It only runs once per worktree lifetime, from the same two
call sites that currently call `link_deps` (crew.sh:1133 for the task worktree,
crew.sh:1304 for the merge worktree) — not once per test run.

### Fallback when clonefile isn't available

`clonefile(2)` requires source and destination on the same APFS volume/container.
Worktrees and the real checkout are normally both under `~` on the same Mac, but
that isn't guaranteed (external volume, different container). `cp -Rc` fails loudly
(non-zero exit) when it can't clone — in that case fall back to a plain `cp -R`
(a real byte copy: slower and uses disk, but still correct, and still physically
inside the worktree so the Turbopack rejection still doesn't apply). Log which path
was taken once per repo per run, not per file. Never fall back to the old
symlink — that *is* the bug being fixed, so it is not an acceptable degrade path.

## Files to touch

### `dozers/dev-lane/crew.sh` (the only code change)

1. **`link_deps_dir` (crew.sh:192-197)** — for the `node_modules` entry specifically,
   replace `ln -s` with: skip if drifted from the source
   (reuse `deps_drifted`-equivalent logic against the source dir, see below), else
   `cp -Rc "$s/node_modules" "$t/node_modules"` with a `cp -R` fallback on failure.
   Immediately after a successful clone, write
   `deps_stamp "$s" > "$t/node_modules/.dozer-deps-stamp"` — the stamp records what
   was *actually cloned* (the source's inputs at clone time), so the existing
   drift check in `install_deps` (compares the stamp to the worktree's *own*
   current inputs) continues to mean exactly what it already means: "has $d's
   package.json/lockfiles changed since node_modules here was populated." This
   unifies the two previously-separate code paths (symlink-freshness-via-
   `deps_drifted`, real-dir-freshness-via-stamp) into one. `.env*` entries keep the
   existing `ln -s` behavior unchanged.
   - Before cloning, check drift the same way the old `-L` branch did (host vs.
     worktree inputs via `deps_drifted`): if already drifted at link time, skip the
     clone entirely and leave `node_modules` absent, so `install_deps` takes its
     existing "missing → run the lockfile install" branch instead of cloning stale
     bytes and then immediately invalidating them. This matches current behavior's
     end state, just skips a wasted clone.

2. **`install_deps` (crew.sh:245-290)** — remove the `[[ -L "$d/node_modules" ]]`
   branch (crew.sh:252-256, and the `elif [[ -L "$d/node_modules" ]]` arm at
   crew.sh:269-272). `node_modules` is never a symlink after this change, so the
   single remaining branch (`-e` + stamp comparison, crew.sh:257-261) is the only
   path — simplifies the function instead of growing it. The "missing" and "stale
   real dir" cases behave exactly as they do today.

3. **`unlink_nested_deps` (crew.sh:234-244)** — currently finds nested
   `node_modules` **symlinks** (`-type l`) to remove before a reinstall, so the
   installer doesn't write back through a link into the host. With clones there is
   no link to write through (a clone is a fully independent copy — if anything this
   makes the existing isolation guarantee *structurally* true instead of relying on
   this cleanup step), but stale nested clones from a prior drifted state still need
   clearing before a fresh install so they don't confuse hoisting. Change the
   detector from `-type l` to "nested `node_modules` dir carrying our
   `.dozer-deps-stamp` marker" (`find ... -name .dozer-deps-stamp -maxdepth 6`,
   then `rm -rf` its parent dir) — this still distinguishes "Dozer planted this" from
   "the worktree's own genuine install" (which never gets a stamp from
   `link_deps_dir`, only from a completed `install_deps` run), matching the
   existing comment's intent of leaving real, non-Dozer dirs alone.

4. **`link_deps` (crew.sh:177-191)** — no logic change; it already loops over
   every nested `node_modules` in the real checkout and calls `link_deps_dir` per
   package dir. That loop is reused as-is; only what `link_deps_dir` does with the
   `node_modules` entry changes.

No other function changes. `resolve_test_cmd`, `detect_test_cmd`,
`test_gate_waiver`, the migration gate, and the green-gate sequencing are untouched
— this is purely a dependency-materialization fix underneath the existing gate.

### Tests to update (existing assertions are symlink-specific and will fail as-is)

- **`tests/dev-lane-deps-drift-test.sh`** — case 2 asserts
  `wt-nm-link -> $P2/node_modules` (still a symlink at agent time) and case 6
  asserts "drifted link left intact." Both need to become "real dir" assertions:
  probe for `[[ -d node_modules && ! -L node_modules ]]` plus a marker file unique
  to the clone (e.g. presence of `.dozer-deps-stamp` with the expected content)
  instead of `readlink`. The behavioral claims under test (fast path skips install
  when unchanged; drift triggers reinstall; host tree never mutates; nested
  symlink removed before install; `DEPS_INSTALL=off` leaves things alone) all still
  need to hold and should be re-asserted against the new mechanism, not dropped.
  Case 5's "nested package symlink: removed before the install" becomes "nested
  package clone: removed before the install" (detector changes, guarantee doesn't).
- **`tests/dev-lane-monorepo-deps-test.sh`** — line 55/86 assert
  `[[ -L packages/web/node_modules ]]` / `web-nm-linked`. Change the probe to assert
  a real directory with the expected contents (the fake `vitest` binary must still
  be reachable at `packages/web/node_modules/.bin/vitest` after cloning — clonefile
  preserves relative symlinks like `.bin` entries unchanged, so this still resolves
  correctly). Line 92's "git-ignored" assertion is unaffected — `node_modules`
  with no trailing slash in `.gitignore` ignores a real dir exactly like it ignores
  a symlink.
- **`tests/dev-lane-greengate-deps-test.sh`** — no symlink assertions found; only
  exercises "node_modules missing → install runs." Should still pass unchanged,
  but run it to confirm (it fabricates node_modules via the fake `npm ci`, not via
  `link_deps`, so it isn't exercising the changed code path directly).

### New test

- **`tests/dev-lane-turbopack-deps-test.sh`** — reproduces the actual failure mode
  instead of only testing the mechanism in isolation. A fake `npm`/`next` stand-in
  that models Turbopack's real behavior: `test` resolves `node_modules` and FAILS
  the way Turbopack does when `realpath(node_modules)` is outside `pwd -P`
  (`[[ "$(cd node_modules 2>/dev/null && pwd -P)" != "$(pwd -P)"/node_modules ]] &&
  { echo "Error: ... outside of the project root"; exit 1; }` run against the
  *resolved* path, which is exactly what a symlink-based `node_modules` would fail
  and a cloned one would pass). Run the crew against a repo with a real checkout in
  one tmp dir and the worktree in a **different** tmp dir (so the test fails for
  the pre-fix code and passes for the post-fix code — the test must be proven red
  against the current crew.sh before the fix lands, then green after). This is the
  regression lock for GSAI-261 specifically; the drift/monorepo tests above cover
  the mechanism, this one covers the bug.

## Edge cases

- **Cross-volume worktrees** (real checkout and `~/.dozers/worktrees` on different
  APFS containers/volumes): `cp -Rc` fails with an unsupported-operation error;
  falls back to `cp -R`. Correct but slower — acceptable, and still fixes the gate
  (no symlink either way).
- **Huge `node_modules`** (large monorepo, tens of thousands of files): clonefile
  cost is per-file-metadata, not per-byte, so still fast, but not literally
  instant like a symlink — bounded by the existing `T_DEPS` timebox (900s default,
  crew.sh:107), same bound the real installer already runs under.
- **Repo has no `node_modules` on the host at all** (e.g. `cfw-website`, GSAI-26
  #2): `link_deps_dir`'s existing `[[ -e "$s/$x" ... ]]` guard (crew.sh:195) already
  skips entries that don't exist on the source — unchanged, `install_deps`'s
  lockfile-install path still handles this exactly as today.
- **Host's own `node_modules` has a stray `.dozer-deps-stamp`** (shouldn't happen —
  `install_deps` is never called on `$WORKDIR` itself — but if it ever did via a
  future code path): harmless, since `link_deps_dir` overwrites the stamp in the
  *clone* immediately after cloning, using the source's own current
  `deps_stamp`, not whatever byte happened to be copied over.
- **Drifted at link time** (task branch already changed lockfiles before
  `link_deps` ever runs): skip the clone entirely rather than cloning stale bytes
  and immediately invalidating them — `install_deps` takes the "missing" branch
  and installs fresh. Matches today's end state (a drifted symlink gets removed
  then reinstalled); this avoids the wasted clone that would precede it.
- **`.dockerignore`/`.gitignore` without trailing slash** (`tests/*deps*` repeatedly
  rely on `node_modules` with no trailing slash ignoring both a symlink and a real
  dir) — unaffected, a real cloned dir matches the same gitignore pattern a symlink
  did.
- **Nested workspace packages** (GSAI-67 monorepo case) — handled identically to
  root, just via the existing per-package loop in `link_deps`; `.bin` entries
  inside a cloned `node_modules` keep working because npm/pnpm/yarn's `.bin`
  symlinks are relative (`../<pkg>/bin.js`) and stay valid after the whole tree is
  cloned to a new location.
- **DEPS_INSTALL=off** — unaffected; that knob only gates whether `install_deps`'s
  `cmd` (`npm ci`/etc.) runs, not whether `link_deps`/clone runs. A drifted clone is
  still left in place exactly as a drifted symlink was (case 6 of the drift test),
  just needs its assertion updated to check for a real dir instead of a link.

## How this gets tested

1. `bash tests/dev-lane-deps-drift-test.sh` — updated to assert real-dir + stamp
   instead of symlink; must still prove: fast path skips reinstall when unchanged,
   drift at various points (pre-build, post-build) triggers a reinstall in the
   right worktree, host tree is never mutated, nested packages are handled,
   `DEPS_INSTALL=off` is honored.
2. `bash tests/dev-lane-monorepo-deps-test.sh` — updated to assert the nested
   package's `node_modules` is a real cloned dir with its `.bin/vitest` intact and
   runnable, root `node_modules` pruning behavior unchanged.
3. `bash tests/dev-lane-greengate-deps-test.sh` — run as-is to confirm no
   regression (exercises the "missing → install" path, not the clone path
   directly).
4. New `bash tests/dev-lane-turbopack-deps-test.sh` — proven red against
   unmodified crew.sh (reproduces the exact GSAI-261 symptom), green after the fix.
5. Full existing suite (`tests/dev-lane-*-test.sh`) — run to confirm nothing else
   implicitly depended on `node_modules` being a symlink (e.g. any gate that reads
   `readlink` output elsewhere). A targeted grep for `-L.*node_modules\|readlink` in
   `tests/` and `dozers/` beyond the files listed above should come back empty
   after the change; if it doesn't, that caller needs the same treatment.

## Out of scope

- No change to `next.config.js` or any app-level repo config — the fix is entirely
  in the Dozer's own dependency-materialization step, so it applies uniformly to
  every onboarded repo with zero per-repo opt-in, matching how `link_deps` already
  behaves today.
- No change to the test gate's detection logic (`detect_test_cmd`,
  `resolve_test_cmd`, `test_gate_waiver`) — the gate was never the problem; it
  correctly found `npm test` and ran it. The problem was what `npm test` then hit.
- No change to `.env*` handling — those stay symlinks; nothing resolves through
  them the way Turbopack resolves through `node_modules`.
