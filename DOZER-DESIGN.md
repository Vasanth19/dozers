# GSAI-154 — design: the migration gate reads "my check failed" as "no override" — a transient read failure blocks a green change

**The bug.** `dozers/dev-lane/crew.sh` (`migration_gate`, ~lines 258–278) is fail-closed
by design: a schema change with no matching migration blocks the merge. Its one escape
hatch — `[skip-migration]` in a commit message — is checked like this:

```bash
if git -C "$wt" log --format=%B "$cmp".."$BRANCH" 2>/dev/null | grep -qF '[skip-migration]'; then
```

The pipeline cannot distinguish **"checked and the marker is absent"** from **"the check
itself failed"**. Any non-zero exit — `git log` erroring under transient system pressure,
`grep` dying, a fork/exec blip — is silenced by `2>/dev/null` and scored as *no
override*, so the LL-31 guardrail blocks a change that legitimately shipped the escape
hatch. There is a twin hole one line up: the diff read is
`changed="$(git -C "$wt" diff --name-only "$cmp"..."$BRANCH" 2>/dev/null || true)"` —
a transient diff failure there reads as *no changed files* and **waives the gate
silently** (fail-open). Both are silent-fallback bugs wearing a guardrail's clothes.

**Evidence — two in-crew false blocks on green changes** (`.artifacts/dev/GSAI-14{8,9}.fail`,
`~/.dozers/logs/loop.err.log` 27354/27706):

| run | result |
|---|---|
| GSAI-149 gate run, in-crew | `run-all: FAIL — 30/31; failures: dev-lane-migration-gate-test.sh` — only OVERRIDE ✗ |
| GSAI-148 gate run, in-crew | `run-all: FAIL — 33/34 in 623s; failures: dev-lane-migration-gate-test.sh` — only OVERRIDE ✗ |
| standalone (6+ runs, incl. 2 verified for this design) | 3/3 scenarios + OVERRIDE ✓ |

Both tasks were green (each task's build agent had already run the same suite green in
the same worktree minutes earlier) and neither touched the migration gate. The gate
code itself is unchanged since GSAI-24 (`git log -S "skip-migration"` → only 5da9065),
so the in-flight diffs are not the cause — this is a load-dependent flake in the base
code, and it can hit any real LL-31-gated task in production exactly the same way.

**Root cause by elimination.** In the OVERRIDE scenario the stub
(`tests/dev-lane-migration-gate-test.sh:79-80`) runs on **all three** model passes and
commits every time — verified for this design: `sed 's/prisma-client-js/prisma-client-js2/'`
re-matches the substring inside `prisma-client-js2`, so pass 2/3 produce `js22`/`js222`
and each pass's `git commit -m "tweak generator [skip-migration]"` succeeds. The stub
is the *only* committer on the fixture branch (every crew backstop is skipped under the
`MODEL_CMD` bypass), so a clean run always holds ≥3 commits carrying the marker — a
successful `git log` cannot legitimately miss it. The failing logs show the crew ran
cleanly through all three passes (no rescue `⚠` lines — byte-matched against a green
run captured for this design) and then the gate fired. Everything else is ruled out by
the log content itself: env leakage would print `migration gate: off` or a different
waiver reason (it prints the expected `TEST_GATE=off` line); shared temp state is
impossible (each scenario gets its own `mktemp` repo, `WORKTREE_ROOT`, and merge lock);
there is no sleep/async code between the diff and the log to race. What remains is the
one path that fits: **the override read pipeline exited non-zero — empty or partial
output swallowed by `2>/dev/null` — and the fail-closed branch read it as "no override".**
The exact transient trigger is unobservable post-hoc (the fixture `$TMP` is deleted and
stderr discarded), but "only in-crew, only under the launchd QoS throttle with 5 parallel
crews and disk at 93%" (GSAI-68) is the signature of a momentary fork/exec/EMFILE-class
failure — a blip that a gate must survive or name, never misdiagnose.

**The invariants to keep.**

- A schema change with no migration and no marker **still blocks**, with the failure
  text **byte-identical** to today's (the test greps `no matching migration`, and the
  text feeds the Director's block comment).
- `[skip-migration]` remains the only escape hatch, still matched strictly (`grep -qF`).
- Fail-fast doctrine: a check that cannot run is **never** silently scored either way —
  it is retried briefly, then fails **loudly with its own reason**, distinguishable from
  an LL-31 violation so a Director sees "infra flake", not "spec violation".

## Approach

Rework `migration_gate` so every evidence read is **captured, retried, and
failure-discriminating** — no pipelines, no `2>/dev/null`, no `|| true`:

1. **Diff read — no silent waiver.** Replace
   `changed="$(git diff --name-only … 2>/dev/null || true)"` with a captured read
   (`if ! changed="$(git -C "$wt" diff --name-only "$cmp"..."$BRANCH" 2>"$gerr")"; then …`).
   On failure: 3 attempts (1s apart), then
   `fail "migration gate could not diff $BRANCH against $cmp — git diff failed: <tail of $gerr> (worktree kept, sent back)"`.
   A gate that cannot see the diff must stop, not wave the change through.
2. **Override read — capture, retry, then verdict.** Replace the `git log | grep -qF`
   pipe with the same captured-read shape: `git -C "$wt" log --format=%B "$cmp".."$BRANCH"`
   into a temp file, 3 attempts 1s apart, each failed attempt logging a visible
   `⚠ migration gate: git log attempt N failed — retrying` line (reported, never
   masked — same discipline as the `run_model_pass` rescues). Persistent failure →
   `fail "migration gate could not read the commit messages on $BRANCH — git log failed: <tail> ; NOT scored as an LL-31 violation (worktree kept, sent back)"`.
   The marker check becomes `grep -qF '[skip-migration]' "$msgs"` on the captured file —
   **grep only ever runs on a successful read**, so "no match" now genuinely means
   "the marker is absent".
3. **No pipes left in the gate.** Both reads use if-captured command substitution;
   `set -e`/pipefail safety comes from `if/else`, the same convention the crew's own
   GSAI-155 comment documents for code that runs as a plain command.
4. **Retry is bound and cheap:** 3 attempts ≈ 2s worst case, hard-coded with a comment
   (a knob here buys nothing; a persistent git breakage must fail fast). Retry applies
   to the *read* only — never to the verdict: a successful read with no marker blocks
   exactly as before.

Shared shape (one small local helper inside the gate section, used by both reads):

```
gate_read <label> <git args…>   → stdout captured by the caller; 3 attempts;
                                persistent failure → fail "<label> — git failed: <stderr tail>"
```

Temp files via `mktemp` under `$TMPDIR`, `rm -f`'d on every exit path (the gate either
returns or `fail`s, both plain exits of the crew process).

**Why retry at all:** the observed failures are transient under load; absorbing a
one-shot blip is what actually meets "the suite passes in-crew across several
consecutive runs". Loud-fail alone would keep the suite red on a repeat — just with a
better message. Retry-then-loud gets both: blips absorbed, real breakage named.

**Not touched:**

- The genuine-block failure text and the `schema_hits` listing (byte-identical).
- Glob resolution (`SCHEMA_GLOBS` / `MIGRATION_GLOBS`), the `[skip-migration]` match
  string, `MIGRATION_GATE=off` early exit, and the gate's call site (~line 695).
- The other `2>/dev/null || true` sites elsewhere in the crew — same pattern class,
  different owners; out of scope (follow-up issue if the Directors want a sweep).
- `tests/run-all.sh` and its scrub list — the fix introduces no new env vars.

## Files to touch

| File | Change |
|---|---|
| `dozers/dev-lane/crew.sh` | `migration_gate` (~258–278): captured+retried diff and log reads, `gate_read` helper, loud distinct failure texts, no pipes/`2>/dev/null`/`|| true`; comment updated to name the GSAI-154 false-block |
| `tests/dev-lane-migration-gate-test.sh` | `run_crew` gains an optional 4th arg (PATH prepend); new `mkshim` builds a fault-injecting `git` wrapper; two new scenarios (5 READ-FAIL, 6 TRANSIENT — below); header comment updated |

## How it gets tested — the flake made deterministic

The environmental blip can't be summoned on demand, so the test **injects it** with a
`git` shim prepended to `PATH` for the crew under test. The shim matches ONLY the
gate's read (`git … log … --format=%B …` — scanning args, since the call is
`git -C <dir> log --format=%B <range>`), delegates everything else to `/usr/bin/git`
via `exec`, so worktree add / commit / merge all run real git. Modes:

- `fail-always`: exit 128 with `shim: injected git log failure` on stderr.
- `fail-once`: a counter file next to the shim fails the first matching call only.

Both modes only ever fire in the gate's read — in a fresh crew the `%B` log call
happens exactly there (resume checks use `--oneline`; the review-prompt diff is not a
log).

**Scenario 5 — READ-FAIL (the loud-discrimination contract):** OVERRIDE fixture +
stub + `fail-always` shim → crew must fail with the new "could not read the commit
messages" reason and must **not** contain `no matching migration` (the LL-31 block
text) — proving an infra failure can no longer masquerade as a spec violation.
Develop unchanged. Pre-fix this fails the scenario *wrongly*: the crew blocks with
the LL-31 message.

**Scenario 6 — TRANSIENT (the GSAI-148/149 repro, deterministic):** OVERRIDE fixture +
stub + `fail-once` shim → the gate's first read fails, the retry succeeds, the crew
must **exit 0** and land the merge on develop. Pre-fix (no retry) this is exactly the
false block: the single read fails → "escape hatch ignored" → crew exits 1. This is
the assertion that would have caught the flake — per the build discipline
(GSAI-155's), the build pass runs both new scenarios against the **unpatched** crew
first and must observe scenario 5 fail-with-wrong-message and scenario 6 false-block,
then apply the fix and watch both turn green.

**Unchanged guards:** BLOCK / ALLOW / OVERRIDE / NO-OP stay byte-for-byte as they are —
they pin the gate's verdicts; the new scenarios pin its *failure discrimination*.

**Commands:**

```bash
bash tests/dev-lane-migration-gate-test.sh          # 6 scenarios, ~20s standalone
bash tests/run-all.sh dev-lane-migration-gate-test.sh
make test                                          # full suite (34 files, the repo's own gate)
```

**In-crew verification** (the brief's "done when"): this task's own crew runs the
suite in-crew at both gates (task worktree + green-gate) — several consecutive green
runs *are* the in-crew evidence; the Director can additionally watch the next
dozers-repo tasks' gate runs. No loop/stress harness is added to the suite: the shim
scenarios make the rare blip deterministic, and a 20× loop would cost ~80s of suite
time for no extra contract.

## Edge cases

1. **Transient read failure (the bug)** → retried, absorbed, correct verdict — scenario 6.
2. **Persistent read failure** → loud, distinct "could not read" failure; worktree kept
   (same sent-back flow); never scored as LL-31 — scenario 5.
3. **Genuine no-marker schema change** → byte-identical LL-31 block — BLOCK stays green.
4. **Marker present** → allowed — OVERRIDE stays green.
5. **Diff read fails** → loud "could not diff" failure — closes the silent
   fail-open twin (a waived gate is worse than a false block).
6. **`git log` exits 0 with empty output** (branch fully merged into base) → grep
   finds nothing → blocks, same as today; unreachable with a non-empty three-dot diff,
   and fail-closed is the correct reading if it ever happens.
7. **MIGRATION_GATE=off** → unchanged early exit before any read.
8. **set -e / pipefail** → no pipelines remain in the gate; every read is
   `if !`-captured; `fail` calls sit in `else` branches, never as bare lists.
9. **Temp-file hygiene** → `mktemp` files `rm -f`'d on both the success and failure
   paths; nothing left in `$TMPDIR` beyond the crew's own lifetime.
10. **Large histories** → the log read goes to a file, not a bash variable or a live
    pipe, so a big branch can neither bloat memory nor resurrect the SIGPIPE-under-
    pipefail class (impossible at 3 commits, possible on a real repo).

**Provenance note:** the `DOZER-DESIGN.md` / `DOZER-REVIEW.md` at the worktree root
are the previous task's pass artifacts (GSAI-155, merged into develop and inherited by
this branch); this design overwrites the design file per the crew convention
(`branch_has_output` excludes both from the merge gate).