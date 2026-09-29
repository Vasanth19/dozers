# Design — GSAI-221: `lite` silently routes ALL factory-repair work to Haiku/25-turns

## The bug

`resolve_crew_profile()` in `dozers/dev-lane/crew.sh` (org/config.yaml `crews:`) picks
the `lite` profile — one BUILD pass, on `models.dev.small` (Haiku), capped at 25 turns —
whenever **any** of these holds:

- the issue's lane is in `crews.lite_when_lanes` (default `ops`)
- the issue carries `crews.lite_when_label` (default `crew:lite`)
- the issue's project is in `crews.lite_when_projects` (default
  `GSAI: Factory housekeeping`)

The lane and project signals are **unconditional and per-bucket, not per-issue**: every
issue filed under `lane:ops` or the `GSAI: Factory housekeeping` project is downgraded,
with no way for a Director to say "not this one." But that lane/project is exactly where
real factory-repair engineering lives (fixing the Dozer engine itself, the kind of work
this repo's own issues are) — it is not all label-renames and config tweaks. GSAI-215
was substantial enough to need more than 25 Haiku turns, hit the ceiling, and died in
118s.

Two compounding problems, both worth fixing:

1. **No per-issue escape hatch.** The only opt-in signal is `crew:lite` (add lite to an
   issue that wouldn't otherwise get it). There is no opt-*out* — no way to keep an
   issue in `lane:ops` / the housekeeping project while still running it on `full`.
   `DOZER_CREW=<profile>` exists, but it is a whole-run engine override, not a per-issue
   Linear label a Director can set when greenlighting one hard task.
2. **The failure is silent about its own cause.** When a `lite` build pass exhausts its
   turn cap, the CLI exits non-zero with its own "Reached max turns" text, but
   `run_model_pass` has no code path that recognizes this — it falls through to the
   generic `"$1 agent failed (worktree kept for resume)"`. Nothing in the failure names
   the crew profile, the turn ceiling, or how to get more of either. A Director sees a
   dead task and has to already know about `crews:` in `org/config.yaml` to connect the
   dots.

## Fix

Two additive, backward-compatible changes to `dozers/dev-lane/crew.sh` +
`org/config.yaml`. No change to `tasks/_linear_api.py` or `dozers/dozer.sh` — the label
facts a per-issue override needs already flow through `DOZER_CREW_META` /
`crew_meta_field label` (GSAI-170's `crew:lite` uses the same plumbing).

### 1. `crews.full_when_label` — a per-issue escape hatch (default `crew:full`)

New top-level key under `crews:` in `org/config.yaml`, read with the same `crews_get`
mechanism `lite_when_label` already uses (it is a plain top-level scalar under `crews:`,
so the existing awk parser needs no changes):

```yaml
crews:
  full_when_label: "crew:full"   # one label, on the issue itself — beats lane/project
                                  # lite signals; conflicts loudly with crew:lite (GSAI-221)
```

`resolve_crew_profile()` in `crew.sh` changes from a flat if/elif ladder to: gather both
label signals up front, then decide in this precedence order (DOZER_CREW still wins over
everything — unchanged):

1. `DOZER_CREW` env (forced for this run) — **unchanged**, highest precedence.
2. Both `crew:lite` and `crew:full` present on the same issue → **fail the crew**,
   naming both labels. A Director must resolve the contradiction, not have the engine
   silently pick a winner (fail-fast doctrine — same spirit as `BADPROFILE`).
3. `crew:full` present (and not case 2) → `full`, reason
   `"the issue carries crew:full (overrides lane/project lite signals)"`. This is the
   new escape hatch: a Director marks one hard ops/housekeeping issue and it gets the
   real trio regardless of lane or project.
4. `DOZER_LANE` in `lite_when_lanes` → `lite` — **unchanged**.
5. `crew:lite` present → `lite` — **unchanged**.
6. project in `lite_when_projects` → `lite` — **unchanged**.
7. else `full` — **unchanged**.

Implementation sketch (replaces the current body of `resolve_crew_profile`, keeps the
same globals `CREW_PROFILE` / `CREW_REASON` and the existing `_in_list` helper):

```bash
CREW_PROFILE=""; CREW_REASON=""
resolve_crew_profile() {
  if [[ -n "${DOZER_CREW:-}" ]]; then
    CREW_PROFILE="$DOZER_CREW"; CREW_REASON="DOZER_CREW=$DOZER_CREW (forced for this run)"; return 0
  fi
  local lanes label full_label projects proj l has_lite=0 has_full=0
  lanes="$(crews_get lite_when_lanes)";       lanes="${lanes:-ops}"
  label="$(crews_get lite_when_label)";       label="${label:-crew:lite}"
  full_label="$(crews_get full_when_label)";  full_label="${full_label:-crew:full}"
  projects="$(crews_get lite_when_projects)"; projects="${projects:-GSAI: Factory housekeeping}"

  while IFS= read -r l; do
    [[ "$l" == "$label" ]]      && has_lite=1
    [[ "$l" == "$full_label" ]] && has_full=1
  done < <(crew_meta_field label)

  if (( has_lite )) && (( has_full )); then
    fail "issue carries both '$label' and '$full_label' — conflicting crew-profile labels (org/config.yaml crews.lite_when_label / crews.full_when_label); remove one and re-greenlight"
  fi

  if (( has_full )); then
    CREW_PROFILE="full"; CREW_REASON="the issue carries $full_label (overrides lane/project lite signals)"; return 0
  fi
  if [[ -n "${DOZER_LANE:-}" ]] && _in_list "${DOZER_LANE}" "$lanes" ','; then
    CREW_PROFILE="lite"; CREW_REASON="lane:${DOZER_LANE} is a lite lane"; return 0
  fi
  if (( has_lite )); then
    CREW_PROFILE="lite"; CREW_REASON="the issue carries $label"; return 0
  fi
  proj="$(crew_meta_field project | head -1)"
  if [[ -n "$proj" ]] && _in_list "$proj" "$projects" '|'; then
    CREW_PROFILE="lite"; CREW_REASON="project '$proj' is a lite project"; return 0
  fi
  CREW_PROFILE="full"; CREW_REASON="no lite signal (lane/label/project)"
}
```

`FULL_WHEN_LABEL` (resolved value, defaulted) is also stashed in a global right after
`resolve_crew_profile` runs, so `run_model_pass`'s new turn-cap diagnostic (below) can
name the exact label to add without re-parsing config:

```bash
FULL_WHEN_LABEL="$(crews_get full_when_label)"; FULL_WHEN_LABEL="${FULL_WHEN_LABEL:-crew:full}"
```

### 2. A turn-cap death names itself, instead of "agent failed"

In `run_model_pass`, the pass log (`$_passlog`) is already captured and inspected once
for `_model_unreachable_reason` before it's deleted (~line 687-719). Add a second,
narrower check right beside it, kept alive across the `rm -f "$_passlog"` the same way
`_unreachable` already is:

```bash
local _turncap=""
if [[ -n "$_PASS_TURNS" ]] && [[ -s "$_passlog" ]]; then
  _turncap="$(_turn_cap_hit_reason "$_passlog")"
fi
rm -f "$_passlog"
```

New helper, alongside the other small `_*` helpers in `crew.sh` (not
`dozers/model-failure.sh` — turn-cap exhaustion is a crew-profile concept, not a
provider-availability one, and that file's whole doctrine is scoped to
available-vs-config provider failures; mixing in an unrelated failure class there would
blur it):

```bash
# _turn_cap_hit_reason: does this pass's own log show it ran out of turns? Matched on
# the CLI's own text (same discipline as model-failure.sh) so a build/review whose
# generated content merely QUOTES the phrase cannot trip it.
_turn_cap_hit_reason() {  # <logfile> → non-empty when the pass exhausted its turn cap
  grep -qiE 'reached max turns|max.?turns (reached|exceeded)|turn limit reached' "$1" \
    && { echo "hit its turn ceiling"; return 0; }
  printf ''
}
```

And a remedy-text helper, called from both places `run_model_pass` currently ends in
the generic `fail "$1 agent failed (worktree kept for resume)"` (the `changes:*` no-output
tail) and the `file:*` untouched-artifact tail:

```bash
# _turn_cap_remedy: appended to a failure message only when $_turncap fired for THIS
# pass. Tailored to the crew profile: `lite` points at the escape hatch (GSAI-221);
# `full` (or any other profile) points at the ordinary max_turns knobs, since there is
# no "more full than full" to fall back to.
_turn_cap_remedy() {  # $1 = pass name
  [[ -n "$_turncap" ]] || { printf ''; return 0; }
  if [[ "$CREW_PROFILE" == "lite" ]]; then
    printf ' — the %s profile capped this pass at %s turns; if this task is too large for lite, add the `%s` label and re-greenlight to run it as full (or DOZER_CREW=full for a one-off resume)' \
      "$CREW_PROFILE" "$_PASS_TURNS" "$FULL_WHEN_LABEL"
  else
    printf ' — this pass is capped at %s turns (DOZER_MAX_TURNS_DEV_%s / models.dev.%s.max_turns); raise the cap, or split the task, if it genuinely needs more' \
      "$_PASS_TURNS" "${1^^}" "$1"
  fi
}
```

Call sites (both existing `fail` calls gain a `$(_turn_cap_remedy "$1")` suffix; message
text unchanged when `$_turncap` is empty):

```bash
fail "$1 agent exited $rc and ${3#file:} is UNTOUCHED by this attempt \
— a stale artifact from an earlier run is not this pass's deliverable and will not be \
taken as its verdict (worktree kept for resume)$(_turn_cap_remedy "$1")"
...
fail "$1 agent failed (worktree kept for resume)$(_turn_cap_remedy "$1")"
```

This is deliberately a **message-only** change — it does not retry on `full`
automatically. An automatic profile escalation on turn-cap failure would be a second,
silent routing decision layered on top of the first (exactly what this issue is about
removing), and it would spend a second model pass without a Director's say-so. Naming
the cause and the exact fix is enough for a human to re-greenlight correctly; the crew
keeps failing fast, as `dozer.md` requires.

## Files touched

- `org/config.yaml` — add `crews.full_when_label: "crew:full"` (with the same style of
  comment `lite_when_label` already has), directly under `lite_when_label`.
- `dozers/dev-lane/crew.sh` — rewrite `resolve_crew_profile()` per above; add
  `FULL_WHEN_LABEL` global; add `_turn_cap_hit_reason` + `_turn_cap_remedy` helpers; wire
  `_turncap` capture into `run_model_pass` and append `_turn_cap_remedy` to both existing
  generic-failure `fail` call sites.
- `README.md` — update the "Crew profiles" section (~line 398-408): add the
  `crew:full` bullet, the conflict-fails-fast note, and mention the turn-cap failure
  message now names its cause.
- `tests/crew-profile-test.sh` — extend with the new cases (below).

No other file needs to change: `tasks/_linear_api.py`'s `crew_meta_field`/`crew-meta`
verb already emits every label on the issue (including a hypothetical `crew:full`) with
no filtering, and `dozers/dozer.sh` already writes the full label set to
`DOZER_CREW_META` — both are generic over label names today.

## Edge cases considered

- **`crew:full` on an issue with no lane/project lite signal at all.** Harmless no-op —
  the issue was going to resolve to `full` anyway; the reason string still correctly
  says "the issue carries crew:full" rather than claiming an override that didn't
  change anything. Not worth special-casing; the label is meant to be added
  defensively by a Director who isn't sure whether the issue's project would trip
  `lite_when_projects`.
- **`crew:full` + `DOZER_CREW=lite` (or vice versa) in the same run.** `DOZER_CREW`
  still wins outright (checked first, unchanged) — a deliberate one-off override beats
  a standing label, same as it already beats `crew:lite` today.
- **Both `crew:lite` and `crew:full` on the same issue.** Fails the crew immediately,
  before any model spend, naming both labels and where they're configured — consistent
  with `BADPROFILE`'s existing "no silent default" behavior for an unknown profile.
- **A repo with no `org/config.yaml` `crews:` block at all** (the zero-config path
  exercised by `NOSIGNAL`/plain test repos). `full_when_label` falls back to the
  hardcoded default `crew:full` in `resolve_crew_profile` itself, exactly like
  `lite_when_lanes`/`lite_when_label`/`lite_when_projects` already do — no behavior
  change for repos that never set `crews:` explicitly.
- **A turn-cap death on `full`.** `full` sets no crew-level `max_turns`, but an
  individual role can still carry one in config (e.g. today's `models.dev.build.max_turns:
  60`) — the remedy helper handles this branch (`CREW_PROFILE != "lite"`) by pointing at
  the role's own knobs instead of a label, since there's no "next tier up" from full.
- **A provider with no `--max-turns` flag (codex).** Already reported as
  `DOZER_MODEL_MAX_TURNS_UNSUPPORTED=1` and bounded by wall-clock instead
  (`turn_cap_wallclock_secs`); a wall-clock kill goes through `TIMEBOX_HIT`, which
  `run_model_pass` already handles in its own branch *before* reaching the
  `_turn_cap_hit_reason` check — unaffected by this change, since that log never
  contains "reached max turns" (the process was killed externally, not from exhausting
  its own turn count).
- **False-positive match on "reached max turns."** Same accepted risk
  `model-failure.sh` already carries for its own phrase-matching (documented there): a
  build or review whose generated file content happens to quote the exact phrase in a
  passing run is never at risk, because `_turn_cap_hit_reason` is only consulted on the
  **failure** tail, after every rescue path (proof-of-output, artifact-freshness) has
  already failed to save the pass.

## How this gets tested

Extend `tests/crew-profile-test.sh` (the existing GSAI-170 crew-profile suite) with
three cases, in its established idiom (throwaway repo + stub agent for the MODEL_CMD
bypass cases, stub `claude` on PATH for the routed case — same `SCRUB_ROUTE` /
`run_crew_routed` pattern `tests/dev-lane-model-prompt-test.sh` already uses):

- **FULLOVERRIDE** — `DOZER_LANE=ops` *and* meta label `crew:full` → selects `full`
  (three passes run — the stub's `LITE_STUB` unset), and the log line reads
  `crew profile: full (the issue carries crew:full …)`. Proves the escape hatch beats
  the lane signal.
- **LABELCONFLICT** — meta labels `crew:lite` and `crew:full` together (any lane/project)
  → the crew run fails (non-zero exit) before any stub-agent invocation
  (`$TMP/$ID.count` never created), and the log names both labels.
- **TURNCAPDIAG** — routed path (`run_crew_routed`-style: real `org/config.yaml`,
  `REPO_ROOT="$ROOT"`, stub `claude` on `PATH`, `SCRUB_ROUTE` env scrub), `DOZER_LANE=ops`
  (→ `lite`, 25-turn cap on `dev.small`). The stub `claude` prints
  `Reached max turns (25)` to stdout and exits 1 without committing anything. Assert
  the crew fails and the log contains both `hit its turn ceiling` and the literal label
  name (`crew:full`) as the suggested fix — proving the diagnostic actually reaches the
  Director instead of the generic `"build agent failed"`.

All three are pure additions to the existing suite; none of the current cases
(LABEL/OPSLANE/PLAINDEV/NOSIGNAL/FORCED/BADPROFILE/TURNCAP/SMALLROUTE/NOCAPFLAG) change
behavior, since `resolve_crew_profile`'s new branches only fire on labels/log text that
none of those existing fixtures set. Run via `bash tests/crew-profile-test.sh`.
