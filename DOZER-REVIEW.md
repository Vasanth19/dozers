VERDICT: PASS

# GSAI-148 — review: per-issue pass artifacts verified end-to-end

**The build followed the design.** Every point of the architect's plan is in the diff,
and I re-verified the load-bearing claims against the working tree and by re-running
the affected suites — not just by reading the commit message.

## Design conformance (checked site by site)

1. **Single source of truth** — `ART_ID` / `DESIGN_FILE` / `REVIEW_FILE` derived once
   right after `ID="$1"` (crew.sh:56 → :70–72; ordering verified — no empty-ID bug).
   `grep` over crew.sh finds ZERO remaining artifact-name literals outside comments,
   the variable definitions, the *intentional* legacy exclusions, and the DRY_RUN
   printf content. Every prompt, backstop, proof arg, and scan flows through the
   variables — the bug class is closed by construction, as designed.
2. **Every site converted:** ARCH_PROMPT + resume preamble, BUILD_PROMPT, REVIEW
   prompt in `review_once`, `file:"$DESIGN_FILE"` / `file:"$REVIEW_FILE"` proofs
   (parser `${3#file:}` confirmed name-agnostic; the ⚠ rescue line prints the real
   name), architect backstop (`-s` check, `git add`, fail text), review backstop
   (`git add`, awk verdict scan, both `_notes` reads), DRY_RUN stub — all per-issue.
3. **`branch_has_output` excludes BOTH schemes** — legacy root names kept so a
   pre-fix resumed branch is still scored "design is not a deliverable" (design
   point 2's only look backwards), plus the per-issue names.
4. **`org/config.yaml`** — comment-only change naming the per-issue scheme; no
   behavior touched.
5. **No in-flight-branch migration** — nothing rewrites old commits; correct per
   design point 4.

## Tests — re-run by this review, all green

| Suite | Result |
|---|---|
| `dev-lane-artifact-collision-test.sh` (new) | PASS — 11/11 ✓ |
| `dev-lane-model-prompt-test.sh` | PASS — incl. new PER-ISSUE-NAMES pins |
| `dev-lane-model-exit-test.sh` | PASS — rescue lines assert per-issue names, ×2/×1 counts |
| `dev-lane-no-commit-gate-test.sh` | PASS — incl. new LEGACY-EXCLUDED case |

The collision regression is the mechanical repro of the task title: task A merges,
B (branched pre-A with a committed design + disjoint code change) takes the RESUME
path, the "base moved — rebased" arm fires, no CONFLICTS / no merge-conflict lines,
and develop ends holding BOTH per-issue designs plus B's review and staged code. Good
test hygiene: B's code change lives in its own file (`b-code.txt`) so a feature.txt
overlap can't mask the artifact-collision signal. The LEGACY-EXCLUDED case also pins
that the legacy design file really was committed before asserting the gate still
blocks on it — the pin is exercised, not assumed.

## Soundness notes

- Rounds within one issue share one name → same-path sequential commits, which
  rebase/merge handle as ordinary edits; only *cross-task* paths are disjoint. Correct.
- The transition artifact placement is self-consistent: this crew ran the pre-fix
  code from memory, so THIS design and review land at the legacy root paths the
  running backstop and verdict scan still read — exactly the design's "transition,
  one time only" prediction, and the merge stays clean (develop hasn't moved those
  files since this branch's base; our side wins trivially).
- Out-of-scope items (per-issue directories, pruning frozen legacy root docs) were
  deliberately not done — matching the design, not omissions.

No spec violations, no silent fallbacks introduced, no gate weakened. The fix is
minimal in shape (rename-by-variable, everywhere at once) and pinned by a regression
test that fails on the pre-fix crew. PASS.