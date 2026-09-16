VERDICT: PASS

Reviewed GSAI-155: the review-pass verdict parse scored a PASS review FAIL
whenever a markdown title sat above the verdict (`head -n1` only — rejected
CFW-254 twice).

## Build followed the design

`dozers/dev-lane/crew.sh` `review_once` (656–667) implements the design's awk
scan byte-for-byte: per-line CR strip, ``` fence toggle, first
`^[ \t]*VERDICT:[ \t]*PASS|FAIL[ \t]*$` match (upcased) wins, strict token
(nothing else on the line), `|| true` + canonical `case` preserving set -e
safety. Section comment at 625 updated as specified. Everything the design
listed "not touched" is untouched in the diff: the review prompt still demands
FIRST LINE, the `MODEL_CMD` bypass is intact, and no other scripts changed —
the diff touches only `crew.sh`, the test file, and `DOZER-DESIGN.md`.

## Tests

- `tests/dev-lane-model-exit-test.sh`: stub `if/else` → `case` with
  `titled`/`titled-fail` (CRLF) exactly per design; TITLED-VERDICT asserts the
  end-to-end regression (exit 0, merge landed, `review verdict: PASS` proves the
  parse scored it not the bypass, exactly 1 rescue line, 3 stub passes = no
  rebuild); TITLED-VERDICT-FAIL proves the tolerance doesn't smuggle FAILs
  (blocked, `review failed TWICE`, 2 parsed FAILs, 5 stub passes, develop
  untouched); GARBLED-VERDICT unchanged.
- **Targeted suite: PASS** — all cases green including the four new ones.
- **`make test`: 33/33 PASS in 1119s** — no regressions anywhere.
- Manual awk sanity checks: titled+CRLF → PASS; quoted `VERDICT: FAIL` inside a
  ``` fence skipped, own `VERDICT: PASS` wins; this branch's GSAI-96
  DOZER-REVIEW.md (verdict on line 1) still parses PASS.

## Judgment

The invariant is preserved, not loosened: a missing, garbled, or decorated
verdict still FAILs; the fix only widens *where* a well-formed verdict line may
sit, and the fence skip prevents a quoted previous-round FAIL from beating the
review's own conclusion. First-match-wins is safe because the prompt still
demands the verdict first. macOS awk (BWK) compatible — no GNU-isms. Edge
behavior on unclosed fences / indented fences fails safe (toward FAIL or toward
skipping quoted text, both the correct direction). Low risk, well-pinned by
tests on the routed (production) path.