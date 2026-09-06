#!/usr/bin/env bash
# tests/repo-test-command-test.sh — regression test for GSAI-30.
#
# GSAI-27 made an undetectable test command FAIL the dev-lane crew. The dozers repo
# itself matched nothing on that ladder — no `test` script in a package.json, no
# `test:` target in a Makefile — so the harness could not clear its own gate: every
# task routed at this repo would have gone straight to dozer:blocked. Worse, the
# obvious escape (a .dozers-no-test-gate marker) would have left the repo that
# enforces the gate as the one repo exempt from it.
#
# This asserts the fix stays fixed, using the REAL detect_test_cmd out of crew.sh:
#   DETECT   — crew.sh's own ladder finds a command for this repo
#   NOWAIVER — and it's a real command, not an opt-out marker
#   RUNS     — the detected command is actually runnable (target exists)
#   COVERAGE — the runner runs every tests/*-test.sh, so a new test can't go unrun
#   SCRUB    — the runner unsets the engine's exported env, so the suite behaves the
#              same inside a Dozer crew as in a plain shell (that's where it runs)
#
# Run:  bash tests/repo-test-command-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"
RUNNER="$ROOT/tests/run-all.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# ── DETECT: lift the shipped function out of crew.sh and run it on this repo ──
DETECT_FN="$(awk '/^detect_test_cmd\(\) \{/,/^\}/' "$CREW")"
[[ -n "$DETECT_FN" ]] || { echo "  ✗ could not extract detect_test_cmd from $CREW" >&2; exit 1; }
CMD="$(eval "$DETECT_FN"; detect_test_cmd "$ROOT")" && [[ -n "$CMD" ]] \
  && ok "DETECT crew.sh finds a test command for this repo: \`$CMD\`" \
  || no "DETECT crew.sh finds NO test command for this repo — every dozers task blocks (GSAI-30)"

# ── NOWAIVER: the gate must be satisfied, never opted out ─────────────────────
if [[ -f "$ROOT/.dozers-no-test-gate" ]]; then
  no "NOWAIVER the repo that enforces the test gate has opted itself out of it"
else
  ok "NOWAIVER no .dozers-no-test-gate marker — this repo is gated like any other"
fi

# ── RUNS: the detected command resolves to something that exists ──────────────
case "$CMD" in
  "make test") ( cd "$ROOT" && make -n test >/dev/null 2>&1 ) \
                 && ok "RUNS \`make test\` resolves to a real target" \
                 || no "RUNS \`make test\` is not a runnable target" ;;
  "npm test")  ok "RUNS npm test (package.json script)" ;;
  *)           no "RUNS unexpected command '$CMD' — teach this test about it" ;;
esac
[[ -x "$RUNNER" ]] && ok "RUNS tests/run-all.sh exists and is executable" \
                   || no "RUNS tests/run-all.sh missing or not executable"

# ── COVERAGE: the runner's default set is every test file, none silently skipped ──
# The runner globs tests/*-test.sh. Anything else living in tests/ is therefore never
# run — so every .sh in there must either match that glob or be the runner itself.
missed=()
for f in "$ROOT"/tests/*.sh; do
  b="$(basename "$f")"
  [[ "$b" == "$(basename "$RUNNER")" || "$b" == *-test.sh ]] || missed+=( "$b" )
done
(( ${#missed[@]} == 0 )) \
  && ok "COVERAGE every script in tests/ is either the runner or a *-test.sh it runs" \
  || no "COVERAGE these live in tests/ but the runner's glob never picks them up: ${missed[*]}"
grep -q 'tests/\*-test\.sh' "$RUNNER" \
  && ok "COVERAGE runner globs tests/*-test.sh (no hand-maintained list to forget)" \
  || no "COVERAGE runner does not glob tests/*-test.sh — new tests can go unrun"
[[ "$(basename "$RUNNER")" != *-test.sh ]] \
  && ok "COVERAGE the runner itself is not matched by its own glob (no recursion)" \
  || no "COVERAGE the runner matches *-test.sh and would run itself forever"

# ── SCRUB: run a probe test THROUGH the runner from a deliberately polluted env ──
# This is the failure GSAI-30 would otherwise hand straight back: the gate runs the
# suite from inside a crew, where MODEL_CMD & friends are exported, and tests that
# drive the crews then assert on the inherited route.
PROBE="$TMP/env-probe-test.sh"
cat > "$PROBE" <<'EOP'
#!/usr/bin/env bash
rc=0
for v in MODEL_CMD DOZER_MODEL_PROVIDER DOZER_MODEL_NAME DOZER_MODEL_SOURCE \
         DOZER_PERSONA ANTHROPIC_BASE_URL LINEAR_API_KEY TEST_GATE; do
  if [[ -n "${!v+x}" ]]; then echo "leaked: $v" >&2; rc=1; fi
done
exit $rc
EOP
if MODEL_CMD='echo leak' DOZER_MODEL_PROVIDER=leak DOZER_MODEL_NAME=leak \
   DOZER_MODEL_SOURCE=leak DOZER_PERSONA=/leak ANTHROPIC_BASE_URL=http://leak \
   LINEAR_API_KEY=leak TEST_GATE=off \
   bash "$RUNNER" "$PROBE" >/dev/null 2>&1; then
  ok "SCRUB runner unsets the engine's exported env before each test"
else
  no "SCRUB engine env leaks into tests — the suite behaves differently inside a crew"
fi

if [[ $fail == 0 ]]; then echo "repo-test-command-test: PASS"; else echo "repo-test-command-test: FAIL" >&2; exit 1; fi
