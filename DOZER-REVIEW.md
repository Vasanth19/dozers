VERDICT: PASS

# GSAI-154 — review: the migration gate can no longer mis-score a failed read

## What I verified

**Build follows the design.** Every element of DOZER-DESIGN.md is present and faithful:

- `gate_read` (crew.sh:265–292) — captured read to a `mktemp` file under `$TMPDIR`, 3
  attempts 1s apart, visible `⚠ … attempt N failed — retrying` lines (same discipline
  as the `run_model_pass` rescues), persistent failure → loud `fail` with the distinct
  "could not read/diff" text and a stderr tail appended.
- The diff read no longer carries `|| true` (the silent fail-open twin is closed) and
  the override read no longer pipes through `grep -qF` — `grep` now only ever runs on
  a file from a *successful* read, so "no match" genuinely means "marker absent".
- No pipelines, `2>/dev/null`, or `|| true` remain in the gate; temp files `rm -f`'d
  on every path (success, marker, no-marker, persistent-failure).
- Not-touched list honored: genuine-block failure text byte-identical (BLOCK stays
  green on it), `[skip-migration]` still `grep -qF` strict, `MIGRATION_GATE=off` early
  exit and the call site (crew.sh:738) unchanged, scenarios 1–4 untouched.

**Subtle mechanics checked, not assumed:**

- `fail` (crew.sh:64) writes to **stderr** — so the loud message escapes the `$(…)`
  capture in the callers, and the `.fail` artifact is still written from inside the
  subshell. Plain assignment + `set -e` (crew.sh:55) propagates the death; the call
  site is a bare command, so the crew dies with the distinct reason, as designed.
- `gate_read` reads the caller's `$wt` via bash dynamic scoping — it works (and is
  commented), though it would break if `migration_gate` ever renamed the local.
- `_rc=$?` after the failed `if` condition correctly captures git's exit code.

**The flake made deterministic — and it really pins the bug.** I independently staged
the **pre-fix** crew (`git show develop:dozers/dev-lane/crew.sh`) plus the **new**
test in a scratch dir outside this worktree and ran it:

- READ-FAIL pre-fix: crew fails but with the **LL-31 text** — "an infra flake
  masqueraded as an LL-31 violation", exactly the false diagnosis the design names.
- TRANSIENT pre-fix: one blip → false block, crew exits 1, develop untouched —
  the deterministic repro of the GSAI-148/149 in-crew false blocks.

Both turn green against the fix. The shim is surgical: the gate's `git … log …
--format=%B` is the only `%B` log call in the crew (all others use `--oneline`,
crew.sh:467/498/581), so worktree add/commit/merge and resume checks all run real
git — the design's claim holds under inspection, not just in the passing run.

**Evidence, rerun by me in this worktree:**

- `tests/dev-lane-migration-gate-test.sh` — 6 scenarios, 14/14 assertions ✓.
- `make test` — **run-all: PASS — 33/33** (independently rerun, 1611s).

## Minor observations (non-blocking)

- `gate_read`'s contract ("do NOT wrap the caller's `$(…)` in `if`/`||`") is load-
  bearing and easy to break in a future edit; the comment says so, which is the
  right mitigation short of a larger refactor.
- The design's `gate_read <label> <git args…>` signature ended up with an extra
  `<persistent-failure text>` param — a benign deviation, and it keeps the failure
  texts at the call sites where they read in context.

The invariants hold: a real schema change with no marker still blocks byte-identically,
the escape hatch still matches strictly, and a read that cannot run is now retried
briefly then named loudly as an infra failure — never silently scored either way.