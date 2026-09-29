VERDICT: PASS

## Spec conformance

The build follows DOZER-DESIGN-GSAI-221.md closely, essentially verbatim:

- `org/config.yaml`: adds `crews.full_when_label: "crew:full"` right under
  `lite_when_label`, with the documented comment. Matches the design's "Files touched"
  section exactly.
- `dozers/dev-lane/crew.sh`: `resolve_crew_profile()` was rewritten to the exact
  precedence order specified — `DOZER_CREW` (unchanged, highest) → both labels present
  → fail fast, naming both → `crew:full` present → `full` → `DOZER_LANE` in
  `lite_when_lanes` → `lite` → `crew:lite` present → `lite` → project in
  `lite_when_projects` → `lite` → else `full`. Code matches the design's sketch
  line-for-line, including the `FULL_WHEN_LABEL` global stashed right after
  `resolve_crew_profile` runs.
- `_turn_cap_hit_reason` and `_turn_cap_remedy` helpers added as designed, placed in
  `crew.sh` (not `model-failure.sh`, per the design's explicit reasoning about scope),
  matching regex and message text from the design.
- `_turncap` capture wired into `run_model_pass` right where the design says (beside
  the existing `_model_unreachable_reason` check, kept alive across `rm -f
  "$_passlog"`), and both `fail` call sites (`file:*` untouched-artifact tail, and the
  generic `changes:*`/fallthrough tail) gained the `$(_turn_cap_remedy "$1")` suffix.
- README.md and the `crews:` comment block in `org/config.yaml` were updated to
  describe the escape hatch and the conflict-fails-fast behavior, as specced.
- `tests/crew-profile-test.sh` gained exactly the three cases the design named
  (FULLOVERRIDE, LABELCONFLICT, TURNCAPDIAG), same idiom as the existing suite.

## Soundness checks performed

- Read the full `resolve_crew_profile()` body: precedence, `fail` invocation, and label
  handling all correct. `fail()` calls `exit 1` immediately (confirmed at
  `crew.sh:98`), so LABELCONFLICT genuinely aborts before any stub-agent invocation —
  matches the test's assertion that `$TMP/$ID.count` is never created.
- `_PASS_TURNS` is a per-pass local-ish global set inside `run_model_pass` before the
  `_turncap` check runs, so the remedy message reports the correct cap for whichever
  pass (architect/build/review) actually died — not a stale value from an earlier
  pass.
- `CREW_PROFILE` and `FULL_WHEN_LABEL` are resolved once, globally, before any pass
  runs, so `_turn_cap_remedy`'s branch on `CREW_PROFILE == "lite"` is stable across all
  passes in the run.
- Ran the full test suite: `bash tests/crew-profile-test.sh` — all 21 assertions pass,
  including the three new GSAI-221 cases (FULLOVERRIDE selects `full` and runs the real
  trio; LABELCONFLICT fails pre-spend naming both labels; TURNCAPDIAG's routed stub
  `claude` producing literal "Reached max turns (25)" text triggers the diagnostic and
  names the `crew:full` escape hatch, not the generic "agent failed").

## Minor observations (non-blocking)

- The turn-cap regex (`reached max turns|max.?turns (reached|exceeded)|turn limit
  reached`) is a text match on provider output, same accepted-risk class as
  `model-failure.sh`'s own phrase matching — the design explicitly calls this out as an
  intentional, low-probability tradeoff (a passing run's generated file content would
  have to quote the exact phrase, and the check only fires on the failure tail after
  rescue paths already failed). Acceptable as designed.
- The fix is message-only, no auto-escalation to `full` on turn-cap failure — this is a
  deliberate design decision (avoids a second silent routing layer + second unbudgeted
  model spend) and is consistent with the repo's fail-fast doctrine elsewhere.

No discrepancies found between the design and the implementation. Tests are real
(exercise the actual resolver and the actual routed pass-log path, not just mocks of
the new helpers) and pass.
