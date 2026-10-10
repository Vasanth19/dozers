# DOZER-DESIGN-GSAI-88

## Title
A missing worktree is misreported as "no test command" — and the fix it suggests is to switch the test gate off

## Problem

The dev-lane test gate (`detect_test_cmd` / `resolve_test_cmd` /
`test_gate_waiver` in `dozers/dev-lane/crew.sh:347-394`, GSAI-27) decides
whether a merge can be safely verified by probing a directory for
`package.json`'s `"test"` script or a Makefile `test:` target:

```bash
detect_test_cmd() {  # $1 = dir → echoes the command; returns 1 when there is none
  local d="$1"
  if   [[ -f "$d/package.json" ]] && grep -q '"test"[[:space:]]*:' "$d/package.json"; then echo "npm test"
  elif [[ -f "$d/Makefile" ]] && grep -qE '^test:' "$d/Makefile"; then echo "make test"
  else return 1; fi
}
```

If `$d` does not exist at all — the task worktree (`$WT`) or merge worktree
(`$MW`) vanished, was never created, or is an empty/orphaned directory —
`[[ -f "$d/package.json" ]]` is simply `false` (bash raises no error for a
missing parent directory in a `-f` test). Control falls through to the
`else` branch exactly as it would for a real, present, untested repo.
`resolve_test_cmd` then treats "directory absent" identically to "directory
present, no test script": it reports the stage, calls `test_gate_waiver`,
and on no waiver produces:

```
<stage>: no test command detected in <dir> — refusing to merge ungated (GSAI-27).
    Add a `test` script to package.json (or a `test:` target in the Makefile),
    or opt this repo out deliberately: a .dozers-no-test-gate file in the repo,
    `no_test_gate: true` on its ecosystem.yaml entry, or TEST_GATE=off for one run.
```

This is actively wrong on two counts when the real cause is a missing
worktree:
1. **Wrong diagnosis.** The repo almost certainly has tests — the engine
   just isn't looking at them, because it isn't looking at anything.
2. **Wrong remedy.** The suggested fixes (`no_test_gate: true`,
   `TEST_GATE=off`, a `.dozers-no-test-gate` marker) permanently or
   per-run **disable the one gate whose entire job is to stop an unverified
   merge from landing** (GSAI-27's own regression). A Director or human
   acting on this message would blind the gate for a healthy, tested repo
   to paper over an unrelated filesystem/engine fault — the worst possible
   fix for this failure.

The same ladder is also reachable through `test_gate_waiver`'s *waiver*
check (`.dozers-no-test-gate` marker, `no_test_gate`, `TEST_GATE=off`) —
none of which should ever apply to "the worktree isn't there," since a
waiver's whole meaning is "this repo has no tests to run," not "the Dozer's
own working copy is broken." Today, if any of those waivers happen to be
set for the repo (a legitimate, intentional waiver for an actually-untested
repo), a missing worktree is silently waived too — the crew proceeds to
"merge" nothing meaningful, having run no tests, for a completely
different reason than the waiver was meant to cover.

### Where `$d` can actually go missing

- **`$WT` (task worktree).** Created fail-fast at
  `crew.sh:1086-1088` (`git worktree add ... || fail "could not create
  worktree ..."`), so it reliably exists going into the preflight check
  (`crew.sh:1127`, immediately after). The realistic exposure window is
  much later: `resolve_test_cmd "$WT" "task worktree"` at `crew.sh:1249`
  runs **after** the architect + build model passes — a wall-clock window
  of minutes — during which `$WT` can be removed out from under the
  running crew (a crash-recovery reaper race on a misjudged stale lock,
  someone manually cleaning `~/.dozers/worktrees/`, a disk/volume hiccup).
  This is the call site where the bug actually bites in practice.
- **`$MW` (merge worktree).** Settled right before use
  (`crew.sh:1374-1386`), but `resolve_test_cmd "$MW" "green-gate"`
  (`crew.sh:1431`) runs only after the merge, `link_deps "$MW"`, and
  `install_deps "$MW" "green-gate"` — the deps install alone can take real
  wall-clock time (`npm ci`/`pnpm install`), so the same class of race
  applies here too, just with a smaller window.
- **Preflight (`crew.sh:1127`).** Lowest risk — `$WT` was just created a
  few lines above with nothing else running in between — but the same
  fallback-to-"no test command" bug exists in the code it calls, so it's
  covered by the same fix for consistency and because "just created" is
  not a guarantee against an external actor.

### Adjacent, out-of-scope latent issues (noted, not fixed here)

The same "missing directory silently treated as a benign case" pattern
also exists in `install_deps` (`crew.sh:293`,
`[[ -f "$d/package.json" ]] || return 0` — a missing `$d` quietly "skips"
deps install instead of failing) and in `wt_unsaved`/`build_backstop`
(`crew.sh:735,777-788`, which treat a `git -C "$d"` failure as "nothing
unsaved" via `|| return 0`). These run *before* `resolve_test_cmd` at the
`crew.sh:1249` call site and would themselves silently no-op on a missing
`$WT` rather than erroring — but they don't produce a *wrong* diagnosis,
only *no* diagnosis, and execution falls through to `resolve_test_cmd`
moments later regardless. Fixing `resolve_test_cmd` alone is therefore
sufficient to correctly surface and correctly diagnose the fault described
in this issue. The adjacent silent-no-op behavior in those three functions
is real but is a separate finding — worth its own follow-up issue, not
bundled into this one, to keep this change minimal and reviewable.

## Approach

Add one guard, shared by all three call sites because all three already
funnel through `resolve_test_cmd`: check that `$d` is a **present, readable
git worktree** at the very top of `resolve_test_cmd`, before
`detect_test_cmd` and before `test_gate_waiver` are even consulted. On
failure, call `fail` directly — the same established idiom
`host_checkout_hygiene` already uses for its own unconditional hard-stops
(`crew.sh:493-528`, "nothing has been touched yet" / "cannot verify it is
safe") — rather than setting `NO_TEST_MSG` and returning 1 for the caller
to decorate.

Calling `fail` directly (which `exit 1`s immediately,
`crew.sh:102`) is deliberate, not incidental: each of the three call sites
appends its own stage-specific text after `$NO_TEST_MSG` today (e.g.
preflight's "re-greenlight it with TEST_GATE=bootstrap"; build_once's
"worktree kept for resume"). That boilerplate is written for the
*genuinely-no-test-command* case and would itself be misleading if
concatenated onto a *missing-worktree* message ("re-greenlight with
TEST_GATE=bootstrap" is nonsense when the problem is that the Dozer's own
working copy disappeared). Exiting from inside `resolve_test_cmd` for this
one new branch means none of that caller-side text can ever attach to it.

### Code change — `dozers/dev-lane/crew.sh`

```bash
# Sets $TEST_CMD for a dir, or explains why there is nothing to run. Returns 1 when
# the gate is ungated AND unwaived, so callers that must clean up first (the
# green-gate has already merged) can revert before failing; $NO_TEST_MSG holds the
# reason. Callers with nothing to undo just `|| fail "$NO_TEST_MSG"`.
#
# GSAI-88: a missing/broken worktree is NOT "no test command" and must never be
# waivable by TEST_GATE=off / no_test_gate / the marker file — those waivers mean
# "this repo has no tests," not "the Dozer's own working copy is gone." Checked
# FIRST, unconditionally, and fails straight through `fail` (never returns) so no
# call site's stage-specific "add a test script" / "TEST_GATE=bootstrap" / "worktree
# kept for resume" text — all written for the genuinely-untested-repo case — can
# ever attach to a message about a broken engine, not a broken test suite.
NO_TEST_MSG=""
resolve_test_cmd() {  # $1 = dir, $2 = stage label
  local d="$1" stage="$2" why gd
  TEST_CMD=""; NO_TEST_MSG=""
  if [[ ! -d "$d" ]]; then
    fail "$stage: worktree $d does not exist — this is a Dozer ENGINE fault, not a
      missing test command (GSAI-88). The repo most likely has tests; the worktree
      itself vanished or was never created (a crash-reaper race, manual cleanup
      under ~/.dozers/worktrees, or a disk/volume issue). TEST_GATE=off,
      no_test_gate, a .dozers-no-test-gate marker, or adding a test script will NOT
      fix this — they would only blind the gate for a healthy repo. Find out why
      $d is gone, then re-greenlight."
  elif ! gd="$(git -C "$d" rev-parse --git-dir 2>&1)"; then
    fail "$stage: $d exists but is not a readable git worktree ($gd) — this is a
      Dozer ENGINE fault, not a missing test command (GSAI-88). Same as a missing
      worktree: TEST_GATE=off / no_test_gate will NOT fix this. Investigate $d,
      then re-greenlight."
  fi
  if TEST_CMD="$(detect_test_cmd "$d")"; then echo "    [dev] $stage: test command \`$TEST_CMD\`"; return 0; fi
  TEST_CMD=""
  if why="$(test_gate_waiver "$d")"; then
    echo "    [dev] ⚠ $stage: no test command — gate waived for this repo ($why)"; return 0
  fi
  NO_TEST_MSG="$stage: no test command detected in $d — refusing to merge ungated (GSAI-27).
      Add a \`test\` script to package.json (or a \`test:\` target in the Makefile),
      or opt this repo out deliberately: a .dozers-no-test-gate file in the repo,
      \`no_test_gate: true\` on its ecosystem.yaml entry, or TEST_GATE=off for one run."
  return 1
}
```

`detect_test_cmd` itself is left untouched: it stays a pure, no-side-effect
probe ("does this *known-valid* dir have a detectable test command"), and
its contract (echo-or-return-1) doesn't fit a hard `fail`. Validity of `$d`
is now guaranteed by its one caller, `resolve_test_cmd`, before
`detect_test_cmd` is ever invoked — matching the comment already at
`crew.sh:376-379` describing `resolve_test_cmd` as the actual gate.

No change to any of the three call sites
(`crew.sh:1127`, `crew.sh:1249`, `crew.sh:1431`) — they keep calling
`resolve_test_cmd "$X" "<stage>" || fail "$NO_TEST_MSG ..."` exactly as
today. The new branch never returns to them; it exits the crew itself
before `NO_TEST_MSG` (left `""` by the function's own reset line) is ever
read.

### Doc touch — `dozers/dev-lane/dozer.md`

Lines 35-38 describe the test gate's opt-outs. Add one clause making the
"missing worktree is not waivable" distinction explicit for Directors
reading the gate's doctrine, so the fix is discoverable without reading
`crew.sh`:

> ...the **test gate** blocks when no test command can be detected at all
> (opt out per repo only — a `.dozers-no-test-gate` file, `no_test_gate:
> true` on the repo's ecosystem.yaml entry, or `TEST_GATE=off` for one
> deliberate run; **none of those waive a missing or broken worktree —
> that's an engine fault, reported as one, GSAI-88**) — and it is checked
> as a preflight...

## Files to touch

- `dozers/dev-lane/crew.sh` — `resolve_test_cmd()` (lines 380-394 today):
  add the existence/readability guard as the function's first act.
- `dozers/dev-lane/dozer.md` — one-clause addition to the test-gate
  paragraph (lines 35-38) noting the guard is unwaivable.
- `tests/dev-lane-missing-worktree-test.sh` (new) — regression test, see
  below.
- `tests/run-all.sh` — add the new test file to the suite list (same
  pattern as every other `tests/*-test.sh` entry).

## Edge cases

- **TEST_GATE=off / no_test_gate set for the repo, worktree also
  missing.** Must still hard-fail with the engine-fault message — the
  waiver check (`test_gate_waiver`) is never reached, because the new
  guard runs first and calls `fail` unconditionally. This is the central
  behavior this issue is asking for; the regression test below asserts it
  directly (case run WITH `TEST_GATE=off` exported).
- **`$d` exists but is an empty directory (orphaned worktree
  metadata).** `[[ -d "$d" ]]` passes, but `git -C "$d" rev-parse
  --git-dir` fails — caught by the second branch, same engine-fault
  framing, distinguishing "absent" from "present but not a git worktree"
  in the message text (useful for whoever investigates).
- **`$d` exists, is a git worktree, but legitimately has no test
  command.** Unchanged behavior — falls through both new checks (dir
  exists, git-dir resolves) into the existing `detect_test_cmd` /
  `test_gate_waiver` ladder exactly as before. Cases A/B/C of the existing
  `tests/dev-lane-test-gate-test.sh` must keep passing unmodified.
- **Green-gate call site (`$MW`) after a successful merge.** The merge has
  already landed in `$MW` and deps may already be installing by the time
  this guard would fire for `$MW`. If `$MW` vanishes in that narrow window,
  the crew still fails closed (via `fail`, `exit 1`) rather than attempting
  `git -C "$MW" reset --hard "$PREMERGE"` against a directory that no
  longer exists (which would itself error, but with a confusing raw git
  message rather than a diagnosed one). No special-casing needed: `fail`
  inside `resolve_test_cmd` exits before the existing
  `git -C "$MW" reset --hard` revert line is ever reached.
- **Symlinked or bind-mounted worktree root.** `[[ -d "$d" ]]` follows
  symlinks (bash test semantics), so a dangling symlink at `$d` correctly
  reports as "does not exist" (not a false positive).

## Testing

New file `tests/dev-lane-missing-worktree-test.sh`, same throwaway-repo /
real-crew-invocation harness `tests/dev-lane-test-gate-test.sh` already
uses (`mkproj`, a stub `MODEL_CMD` agent, `run_crew`, assertions on exit
code + `.artifacts/dev/<ID>.fail` contents):

- **D. Worktree vanishes between the model pass and the post-build test
  gate.** A throwaway repo *with* a real `test` script (so this is
  unambiguously the engine-fault path, not the already-covered
  no-test-command path). The stub agent script commits its change as
  usual, then — via the same `$EXTRA`-hook mechanism case C already uses
  to mutate state before the gate sees it — removes its own worktree root
  (`rm -rf "$PWD"`) right before exiting. Assert:
  - crew exits non-zero;
  - `develop` is untouched;
  - `.artifacts/dev/TEST-MW-D.fail` contains the worktree path and a
    phrase identifying it as an engine fault (e.g. "ENGINE fault", "does
    not exist");
  - `.fail` does **NOT** contain any of: `no_test_gate`, `TEST_GATE=off`,
    `.dozers-no-test-gate`, `add a` (the genuinely-no-test-command remedy
    text) — proving the wrong fix is no longer suggested.
- **E. Same as D, but with `no_test_gate: true` already set for the repo
  (or `TEST_GATE=off` exported for the run).** Assert the crew still
  fails exactly as in D — the waiver must not apply. This is the
  regression this issue exists to prevent: today, case E would currently
  **merge successfully** (gate waived) for the wrong reason.
- **F (sanity, no new behavior).** Re-run existing cases A/B/C from
  `tests/dev-lane-test-gate-test.sh` unmodified to confirm the new guard
  is a no-op when the worktree is genuinely present — these must keep
  passing byte-for-byte.
- Register the new file in `tests/run-all.sh`.

Manually verifying the green-gate's `$MW` branch end-to-end is impractical
(the window is a handful of lines inside one script execution); the
existing source-shape assertion style `tests/dev-lane-test-gate-test.sh`
case C already uses (`awk`/`grep` against `crew.sh` to confirm the
green-gate calls `resolve_test_cmd "$MW" ...` ahead of its revert) is
extended with one more `grep` confirming the new guard block
(`"this is a Dozer ENGINE fault"` or equivalent anchor text) appears
inside `resolve_test_cmd`'s body before the `detect_test_cmd` call — cheap
coverage that the shared function (and therefore every call site) carries
the fix, without needing to simulate the exact race.

## Risks / rollout

- **Behavior change is fail-closed, not fail-open** — strictly in
  keeping with the repo's own fail-fast doctrine (`AGENTS.md`, GSAI-27's
  own history of a "never merges red" claim that was silently false for
  ungated repos). No existing passing path changes.
- **No config surface added.** Deliberately — this is an engine
  correctness fix, not a new knob; adding an opt-out for "missing worktree
  tolerance" would recreate exactly the hole this issue reports.
- Low risk of false positives: `git -C "$d" rev-parse --git-dir` is the
  cheapest possible "is this a git worktree at all" check and is already
  used elsewhere in this file (`host_checkout_hygiene`, `crew.sh:500`) for
  the identical purpose.
