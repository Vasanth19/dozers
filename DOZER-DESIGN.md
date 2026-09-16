# GSAI-155 — design: a passing review scored FAIL because the verdict parse reads `head -n1` only

**The bug.** `dozers/dev-lane/crew.sh` (`review_once`, ~lines 647–655) scores the
review pass by reading exactly one line of `DOZER-REVIEW.md`:

```bash
vline="$(head -n1 "$WT/DOZER-REVIEW.md" 2>/dev/null | tr -d '\r' || true)"
case "$vline" in
  "VERDICT: PASS") REVIEW_VERDICT="PASS" ;;
  "VERDICT: FAIL") REVIEW_VERDICT="FAIL" ;;
  *)               REVIEW_VERDICT="FAIL" ;;
esac
```

The review prompt demands the verdict as the FIRST line, but models sometimes open
with a markdown title — `# Review of CFW-254` — before writing `VERDICT: PASS`.
`head -n1` then returns the title, the `case` falls to `*)`, and a PASSING review is
scored FAIL. Consequence: one pointless rebuild (model spend), a re-review, and a
second FAIL for the same cosmetic reason → **CFW-254 was rejected twice and blocked**.
The parse runs only on the routed path (non-`MODEL_CMD`), which is the production
path — the `MODEL_CMD` bypass auto-passes and every existing test that stubs via
`MODEL_CMD` never exercises it.

**The invariant to keep.** "A missing or garbled verdict IS a fail — no free pass to
merge." The fix widens WHERE the verdict line may sit; it does not loosen WHAT a
verdict line is. An absent, ambiguous, or malformed verdict still scores FAIL.

## Approach

Replace the `head -n1` read with a **tolerant scan** for the first verdict-shaped
line anywhere in the file, printed in canonical form:

```bash
# A missing or garbled verdict IS a fail — no free pass to merge. But the verdict
# need not be the literal first line: a markdown title above it is cosmetic, not a
# judgment (GSAI-155 — a titled PASS scored FAIL and rejected CFW-254 twice). Scan
# the file for the first line that is EXACTLY a verdict, skipping fenced code
# blocks (a review quoting the previous round's "VERDICT: FAIL" inside ``` is
# quoting, not concluding) — the prompt still demands the verdict first, so the
# model's own verdict is the first hit. CRLF, leading whitespace, and casing are
# tolerated; anything else on the line is still garbled.
vline="$(awk '
  { sub(/\r$/, "") }                                  # CRLF-proof every line first
  /^```/ { f = !f; next }                             # fence toggle; ```bash opens too
  f { next }                                          # inside a fence: quoted text
  toupper($0) ~ /^[ \t]*VERDICT:[ \t]*PASS[ \t]*$/ { print "PASS"; exit }
  toupper($0) ~ /^[ \t]*VERDICT:[ \t]*FAIL[ \t]*$/ { print "FAIL"; exit }
' "$WT/DOZER-REVIEW.md" 2>/dev/null || true)"
case "$vline" in
  PASS) REVIEW_VERDICT="PASS" ;;
  FAIL) REVIEW_VERDICT="FAIL" ;;
  *)    REVIEW_VERDICT="FAIL" ;;   # empty/missing file or no verdict line anywhere
esac
```

Notes on the shape:

- **First match wins**, and the prompt is left byte-identical — it still says "FIRST
  LINE is exactly VERDICT: PASS|FAIL". The scan is a backstop for models that add a
  title, not a license to bury the verdict; a compliant review's verdict precedes
  any quoted old verdicts, so first-match picks the model's own conclusion.
- **Fenced blocks are skipped.** A rebuild's review often quotes the previous FAIL
  (the rebuild prompt embeds its notes). A quoted `VERDICT: FAIL` inside ``` must not
  beat the review's own `VERDICT: PASS`. Two awk lines buy that; a plain
  `grep -m1` does not.
- **The verdict line itself stays strict** — `VERDICT:` + exactly `PASS`/`FAIL` +
  whitespace, nothing else. `VERDICT: PASS — LGTM` is still garbled → FAIL, by
  fail-fast doctrine: the tolerance covers the observed failure class (a title
  above the verdict), not every model flourish. Casing, leading indentation, and
  CRLF are the only further relaxations, all direction-neutral.
- **`|| true` + `case` on the canonical token** preserve the existing set -e /
  pipefail safety: awk on a missing file exits non-zero; empty output falls to `*)`
  and FAILs, exactly as the empty `head -n1` did.
- macOS awk (BWK) supports `toupper`, `[ \t]` classes, and `sub` — no GNU-isms.

**Not touched:**

- The review prompt text (lines ~634–635) — contract unchanged.
- The `MODEL_CMD` bypass (auto-PASS, line 657) and the DRY_RUN stub (line 561) —
  the stub already writes the verdict on line 1.
- The rescue path (`run_model_pass file:` proof) — a rescued review still feeds the
  same `review_once` parse, so it inherits the fix (that interplay is exactly what
  the new TITLED case exercises).
- `promote.sh` / `audit-merged.sh` / `verify-merge.sh` — their `head -n1` reads
  parse other things (config lines, receipts), not review verdicts. Out of scope.

## Files to touch

| File | Change |
|---|---|
| `dozers/dev-lane/crew.sh` | Replace the `head -n1` verdict read in `review_once` (~647–654) with the fence-aware scan above; update the section comment at ~625 ("first line VERDICT") to say "verdict line (tolerant scan, GSAI-155)" |
| `tests/dev-lane-model-exit-test.sh` | Extend the shared stub's `REVIEW_MODE` with `titled` / `titled-fail`; add the two cases below |

## Edge cases

1. **Title above the verdict** (the bug) → verdict found → correct score.
2. **CRLF line endings** → stripped per line in awk before matching.
3. **Indented verdict line** (`  VERDICT: PASS`) → matches.
4. **Lowercase** (`verdict: pass`) → matches via `toupper` (direction-neutral).
5. **No `VERDICT:` line anywhere** (the garbled/truncated case) → FAIL — unchanged
   behavior, still covered by the existing GARBLED-VERDICT case.
6. **Empty or missing file** → empty `vline` → FAIL — unchanged.
7. **Quoted old verdict inside a ``` fence** → skipped; the review's own verdict
   wins.
8. **Fence marker inside a longer line** (`use ``` fences` mid-prose) → does not
   toggle (anchored `^``` `); an indented fence also does not toggle — accepted
   imprecision, fail-safe direction (worst case: a quoted verdict inside an
   indented fence is *also* skipped, which is what we want anyway).
9. **`VERDICT: PASS` with trailing prose on the same line** → still FAIL (strict
   token; deliberate — see "invariant").
10. **UTF-8 BOM before a line-1 verdict** → no match → FAIL. Same as today
    (`head -n1` failed on it too); not a regression, not worth the escape-sequence
    gymnastics in awk.
11. **Verdict after a fenced block closes** → `f` toggles back on the closing
    fence, so trailing verdicts still match.

## How it gets tested

The parse is inline in `review_once`, so the test drives the real crew through the
routed path (`run_crew_routed` in `tests/dev-lane-model-exit-test.sh` — the same
harness the GARBLED-VERDICT case built, because the verdict parse is skipped under
the `MODEL_CMD` bypass).

**Stub change** — restructure the review branch's `if/else` into a `case`:

```bash
case "${REVIEW_MODE:-pass}" in
  garbled)    printf 'Reviewing the diff, but the write was truncated before any verdict line\n' > DOZER-REVIEW.md ;;
  titled)     printf '# Review — verdict behind a title\r\n\r\nVERDICT: PASS\r\nall good\r\n' > DOZER-REVIEW.md ;;
  titled-fail) printf '# Review — verdict behind a title\r\n\r\nVERDICT: FAIL\r\nnot good\r\n' > DOZER-REVIEW.md ;;
  *)          printf 'VERDICT: PASS\nall good\n' > DOZER-REVIEW.md ;;
esac
```

(`titled` uses CRLF so one case covers title + CRLF tolerance together; the file
format is cosmetic to the parser under test.)

**New case TITLED-VERDICT** (the CFW-254 regression, end-to-end):
`run_crew_routed … TEST-ME-E REVIEW_MODE=titled REVIEW_EXIT=1` — the non-zero exit
also exercises the rescue→parse interplay, mirroring how the real failure fired.
Assert:

- crew exits 0 and develop advanced to `merge*TEST-ME-E*` (pre-fix: FAIL → rebuild
  → re-FAIL → blocked);
- log contains `review verdict: PASS` (proof the parse scored it, not the bypass);
- exactly **1** `⚠ review agent exited 1 but DOZER-REVIEW.md is on disk` line;
- stub ran **3** times (arch, build, review — no rebuild; pre-fix: 5).

**New case TITLED-VERDICT-FAIL** (tolerance must not smuggle FAILs through):
`run_crew_routed … TEST-ME-F REVIEW_MODE=titled-fail REVIEW_EXIT=1`. Assert:

- crew blocked, reason contains `review failed TWICE`;
- log shows `review verdict: FAIL` twice;
- stub ran **5** times (the one rebuild);
- develop untouched (`init`).

**Unchanged guard:** GARBLED-VERDICT already proves "no verdict line anywhere →
FAIL → rebuild → FAIL → blocked"; it must stay green byte-for-byte (no-verdict is
a different failure class than titled-verdict).

**Commands:**

```bash
bash tests/run-all.sh dev-lane-model-exit-test.sh   # targeted, fast
make test                                           # full suite (the repo's own gate)
```

Plus a one-shot manual sanity check of the awk against the real CFW-254 shape
(`# <title>` then `VERDICT: PASS`) and the GSAI-96 DOZER-REVIEW.md at this worktree
root (verdict on line 1 — must still read PASS).

**Provenance note:** the DOZER-DESIGN.md / DOZER-REVIEW.md currently at the worktree
root are the previous task's pass artifacts, already merged into develop and
inherited by this branch; this design overwrites the design file per the crew
convention (`branch_has_output` excludes both from the merge gate).