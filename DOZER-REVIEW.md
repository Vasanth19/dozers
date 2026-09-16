VERDICT: PASS

**Issue:** GSAI-60 — board reconcile can auto-approve on an agent's own comment.
**Reviewed:** develop..HEAD (`5d2248b`), against DOZER-DESIGN.md (GSAI-60 architect pass).

## The build follows the design, layer by layer

1. **Write-side stamp (the primary fix)** — `_stamp_marker()` in
   `tasks/_linear_api.py` appends `<!-- board-note by:<DOZER_COMMENT_BY:-dozer-engine> -->`
   to any body with no `<!-- … -->` marker; `comment()` and `_comment_url()` are
   confirmed the **only two** `commentCreate` doors and both route through it
   (grep-verified; pinned by the new structure test, section 16). `os` was already
   imported. The three callers each export one identity line (`dozer.sh` →
   `dozer-engine`, `reaper.sh` → `dozer-reaper`, `run.sh` → `director-cli`) exactly
   as specified. Pre-marked paths (`alarm_raise`/`alarm_clear`/`board-mirror`) carry
   markers already, so they round-trip byte-identical — no double stamp, verified by
   `stamp_marked_byteidentical`.
2. **Read-side guard** — `AGENT_SIGNATURES` was checked against the **actual emitted
   openers at the real call sites**, not just the design's transcription: `Dozer
   claimed` (dozer.sh:248), `Dozer blocked BEFORE/AFTER/in lane` (:264,312,336),
   `Dozer merged to develop` / `Dozer staged for review` (verb printf :329 — both
   verbs match the anchored regex), `Director approved →` (run.sh:34), `♻️ Reaper
   requeued` (reaper.sh:85). All match. `board_answers()` returns a refused list,
   the CLI probe names each refusal on stderr and exits 3; `alarm_clear()` uses the
   same classifier. The mixed case (refused status line + Vas's later real answer →
   exit 0 with his line only) is pinned — a refusal cannot swallow a genuine answer.
3. **Docs** — LINEAR.md gains the self-stamp + refusal sentences; run.sh's exit-3
   message now names the refusal path. Director templates untouched, matching the
   design (the marker rule was already in all four; existing test case 12 pins it).
4. **Backends** — `files.sh` / `github-issues.sh` untouched, as specified.

## Tests — the repro is real

`tests/board-reconcile-test.sh` grew sections 13–16 exactly per the design (STAMP,
GUARD, ALARM, STRUCTURE PIN) in the file's existing python-harness idiom:
**50/50 green**, including all 12 pre-existing cases (the `answered()` helper was
correctly extended for the 3-tuple return). The `REFUSED:` line appears on stderr
in the guard_cli case, proving the refusal is visible, not silent. Full
`tests/run-all.sh`: **32/32 PASS** — nothing else in the repo pins comment bodies,
and no new test registration was needed (run-all.sh globs `tests/*-test.sh`).

## Minor notes (non-blocking, cosmetic)

- `is_human_answer()` is defined but never called — `board_answers()` and
  `alarm_clear()` inline the equivalent (marker check + signature check) instead.
  The design said the helper "replaces the bare check in both consumers"; the
  behavior is identical and test-pinned, but the exported helper is dead code and
  a future reader might assume it's load-bearing.
- The `alarm_clear` test case prints its `REFUSED:` stderr line to the terminal
  (not captured like the probe cases) — harmless noise in test output.
- Edge case handled implicitly rather than by test: a merged/staged comment whose
  crew summary embeds an HTML comment skips the stamp (marker present), but the
  signature guard still refuses that opener — the residual is covered by design's
  layering.

## Security judgment

The asymmetry is preserved and strengthened: over-refusing is visible (stderr +
the ask stays `board:to_review`) and recoverable by hand; under-refusing is what
GSAI-60 measured live (11/22 issues). The stamp makes new unmarked scripted
comments impossible at the only door they walk through; the guard catches the
residual (pre-fix comments, LLM-authored slips, bypassing posters). The
post-merge verification plan (reconcile dry-run over the 22 board issues) is
correctly left to the Dev-Director.

**Recommendation:** merge to develop. Suggest the Dev-Director, in a cleanup pass
or the next touch of this file, either wire `is_human_answer()` into the two
consumers or drop it, and wrap the alarm test's stderr.