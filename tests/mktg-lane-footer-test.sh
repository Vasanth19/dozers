#!/usr/bin/env bash
# tests/mktg-lane-footer-test.sh — regression test for GSAI-33: the marketing crew's
# staged deliverable must never contain the harness output-style footer, and the crew's
# note for the reviewer must reach the task comment instead of the draft.
#
# Every case drives the REAL crew with a stub content model (no live model, no spend).
#
# Cases:
#   FOOTER     a trailing "👨 Daddy says" line is stripped from the draft, preserved in
#              the handoff note, and the crew logs that the backstop fired
#   FIRST      the footer as line 1 of the body (the CFW-43 case) is stripped too
#   HANDOFF    text after `=== HANDOFF ===` leaves the draft and lands in <id>.handoff;
#              the summary says so
#   CLEAN      a clean transcript: draft == asset, no backstop log, no handoff file
#   ONLYFOOTER a transcript that is nothing but the footer fails as an empty draft
#   CFGRE      `output_style_footer:` in org/config.yaml overrides the pattern
#   ISOLATE    when MODEL_CMD is the claude CLI the crew runs it with --safe-mode, and the
#              prompt asks for the handoff marker (routing default: claude)
#   NOFLAG     a claude CLI without --safe-mode fails the crew — it never runs unisolated
#   ENGINE     end to end on the files backend: the "staged for review" comment carries the
#              crew summary AND the handoff note, the draft carries neither footer nor note
#
# Run:  bash tests/mktg-lane-footer-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/mktg-lane/crew.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
hasre() { grep -qE -- "$2" "$1" 2>/dev/null; }

# A throwaway dozers root: real config, so artifacts never touch the repo's own.
REPO="$TMP/repo"; mkdir -p "$REPO/org" "$REPO/dozers" "$REPO/tasks"; cp "$ROOT/org/config.yaml" "$REPO/org/config.yaml"
ln -s "$ROOT/dozers/model.sh" "$REPO/dozers/model.sh"; ln -s "$ROOT/tasks/model_route.py" "$REPO/tasks/model_route.py"
ART="$REPO/.artifacts/mktg"
FOOTER='👨 Daddy says: Add a test so you catch mistakes early.'
ASSET=$'# Show HN: Dozers\n\nWe built a thing.\n\nTry it: https://example.com'

# stub content model: prints the file named in STUB_OUT, ignores the prompt
STUB="$TMP/model.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$1" > "${STUB_PROMPT:-/dev/null}"
cat "$STUB_OUT"
EOF
chmod +x "$STUB"

run_crew() { # <id> <transcript-file> [env...]  -> log in $TMP/<id>.log, workdir $TMP/wd-<id>
  local id="$1" out="$2"; shift 2
  local wd="$TMP/wd-$id"; mkdir -p "$wd"
  env -u DRY_RUN STUB_OUT="$out" MODEL_CMD="$STUB" WORKDIR="$wd" REPO_ROOT="$REPO" "$@" \
    bash "$CREW" "$id" "footer test $id" >"$TMP/$id.log" 2>&1
}
draft() { printf '%s' "$TMP/wd-$1/.dozers-review/$1.md"; }

# ── FOOTER ───────────────────────────────────────────────────────────────────
echo "== FOOTER"
printf '%s\n\n%s\n' "$ASSET" "$FOOTER" > "$TMP/t-footer.txt"
if run_crew FT-1 "$TMP/t-footer.txt"; then ok "FOOTER crew succeeded"; else no "FOOTER crew failed"; cat "$TMP/FT-1.log" >&2; fi
D="$(draft FT-1)"
has "$D" "Daddy says" && no "FOOTER draft still contains the footer" || ok "FOOTER draft has no output-style line"
[[ "$(cat "$D")" == "$ASSET" ]] && ok "FOOTER draft is exactly the asset" || { no "FOOTER draft differs from the asset"; cat "$D" >&2; }
has "$TMP/FT-1.log" "BACKSTOP FIRED" && ok "FOOTER backstop logged that it fired" || no "FOOTER backstop did not log"
has "$ART/FT-1.handoff" "$FOOTER" && ok "FOOTER footer preserved in the handoff note" || no "FOOTER handoff note lacks the footer text"
has "$ART/FT-1.summary" "Backstop stripped 1 output-style line" && ok "FOOTER summary reports the strip" || no "FOOTER summary silent about the strip"
has "$ART/FT-1.raw" "$FOOTER" && ok "FOOTER raw transcript kept intact" || no "FOOTER raw transcript missing the footer"

# ── FIRST (CFW-43: footer as line 1) ─────────────────────────────────────────
echo "== FIRST"
printf '%s\n%s\n' "$FOOTER" "$ASSET" > "$TMP/t-first.txt"
run_crew FT-2 "$TMP/t-first.txt" || no "FIRST crew failed"
D="$(draft FT-2)"
[[ "$(head -1 "$D")" == "# Show HN: Dozers" ]] && ok "FIRST draft starts with the asset" || { no "FIRST draft line 1: $(head -1 "$D")"; }
has "$D" "Daddy says" && no "FIRST draft still contains the footer" || ok "FIRST footer stripped"

# ── HANDOFF ──────────────────────────────────────────────────────────────────
echo "== HANDOFF"
NOTE=$'Could not verify the pricing page URL.\nOne yes/no from you: keep the CTA?'
printf '%s\n\n=== HANDOFF ===\n%s\n' "$ASSET" "$NOTE" > "$TMP/t-handoff.txt"
run_crew FT-3 "$TMP/t-handoff.txt" || no "HANDOFF crew failed"
D="$(draft FT-3)"
[[ "$(cat "$D")" == "$ASSET" ]] && ok "HANDOFF draft is exactly the asset" || { no "HANDOFF draft differs"; cat "$D" >&2; }
has "$D" "=== HANDOFF ===" && no "HANDOFF marker leaked into the draft" || ok "HANDOFF marker kept out of the draft"
[[ "$(cat "$ART/FT-3.handoff")" == "$NOTE" ]] && ok "HANDOFF note captured verbatim" || { no "HANDOFF note wrong"; cat "$ART/FT-3.handoff" >&2; }
has "$ART/FT-3.summary" "Handoff note for the reviewer: 2 line(s)" && ok "HANDOFF summary announces the note" || no "HANDOFF summary lacks the note line"
has "$TMP/FT-3.log" "BACKSTOP FIRED" && no "HANDOFF backstop fired on a clean asset" || ok "HANDOFF backstop stayed quiet"

# ── CLEAN ────────────────────────────────────────────────────────────────────
echo "== CLEAN"
printf '%s\n' "$ASSET" > "$TMP/t-clean.txt"
run_crew FT-4 "$TMP/t-clean.txt" || no "CLEAN crew failed"
[[ "$(cat "$(draft FT-4)")" == "$ASSET" ]] && ok "CLEAN draft == asset" || no "CLEAN draft altered"
[[ -e "$ART/FT-4.handoff" ]] && no "CLEAN wrote a handoff file with nothing to say" || ok "CLEAN no handoff file"
has "$TMP/FT-4.log" "BACKSTOP" && no "CLEAN backstop logged" || ok "CLEAN backstop silent"
has "$ART/FT-4.summary" "Backstop" && no "CLEAN summary mentions the backstop" || ok "CLEAN summary clean"

# ── ONLYFOOTER ───────────────────────────────────────────────────────────────
echo "== ONLYFOOTER"
printf '%s\n' "$FOOTER" > "$TMP/t-only.txt"
if run_crew FT-5 "$TMP/t-only.txt"; then no "ONLYFOOTER should fail"; else ok "ONLYFOOTER crew failed (nothing left to stage)"; fi
has "$ART/FT-5.fail" "empty draft" && ok "ONLYFOOTER fail reason recorded" || no "ONLYFOOTER no .fail reason"
[[ -e "$(draft FT-5)" ]] && no "ONLYFOOTER staged an empty draft" || ok "ONLYFOOTER staged nothing"

# ── CFGRE ────────────────────────────────────────────────────────────────────
echo "== CFGRE"
REPO2="$TMP/repo2"; mkdir -p "$REPO2/org"; cp "$ROOT/org/config.yaml" "$REPO2/org/config.yaml"
printf '\noutput_style_footer: "^🤖 Bot note:"\n' >> "$REPO2/org/config.yaml"
printf '%s\n🤖 Bot note: some harness line\n' "$ASSET" > "$TMP/t-cfg.txt"
env -u DRY_RUN STUB_OUT="$TMP/t-cfg.txt" MODEL_CMD="$STUB" WORKDIR="$TMP/wd-FT-6" REPO_ROOT="$REPO2" \
  bash "$CREW" FT-6 "cfg test" >"$TMP/FT-6.log" 2>&1 || no "CFGRE crew failed"
has "$TMP/wd-FT-6/.dozers-review/FT-6.md" "Bot note" && no "CFGRE custom pattern not applied" || ok "CFGRE custom pattern strips its line"
has "$TMP/FT-6.log" "BACKSTOP FIRED" && ok "CFGRE backstop logged" || no "CFGRE backstop silent"

# ── ISOLATE: a fake `claude` on PATH records how it was called ───────────────
echo "== ISOLATE"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then printf '  -p, --print\n  --safe-mode   Start with all customizations disabled\n'; exit 0; fi
printf '%s\n' "$@" > "$FAKE_ARGS"
# simulate a leak so the draft assertion is real
printf '# Asset\n\nbody\n\n👨 Daddy says: leaked anyway\n'
EOF
chmod +x "$FAKEBIN/claude"
WD7="$TMP/wd-FT-7"; mkdir -p "$WD7"
env -u DRY_RUN -u MODEL_CMD -u DOZER_MODEL_MARKETING -u DOZER_MODEL_DEFAULT PATH="$FAKEBIN:$PATH" FAKE_ARGS="$TMP/fake.args" \
  WORKDIR="$WD7" REPO_ROOT="$REPO" DOZER_CONFIG="$REPO/org/config.yaml" \
  bash "$CREW" FT-7 "isolation test" >"$TMP/FT-7.log" 2>&1 || { no "ISOLATE crew failed"; cat "$TMP/FT-7.log" >&2; }
has "$TMP/fake.args" "--safe-mode" && ok "ISOLATE claude ran with --safe-mode" || { no "ISOLATE no --safe-mode in claude args"; cat "$TMP/fake.args" >&2; }
has "$TMP/fake.args" "-p" && ok "ISOLATE still headless (-p)" || no "ISOLATE lost -p"
has "$TMP/fake.args" "=== HANDOFF ===" && ok "ISOLATE prompt asks for the handoff marker" || no "ISOLATE prompt lacks the handoff marker"
has "$TMP/fake.args" "Daddy" && no "ISOLATE prompt mentions the footer (should not need to)" || ok "ISOLATE prompt does not name the footer"
has "$TMP/FT-7.log" "isolation: claude --safe-mode" && ok "ISOLATE crew logs the isolation" || no "ISOLATE crew log lacks isolation line"
has "$ART/FT-7.summary" "safe-mode" && ok "ISOLATE summary records isolation" || no "ISOLATE summary lacks isolation"
has "$WD7/.dozers-review/FT-7.md" "Daddy says" && no "ISOLATE simulated leak reached the draft" || ok "ISOLATE simulated leak caught by the backstop"

# ── NOFLAG: an old claude without --safe-mode must not run unisolated ─────────
echo "== NOFLAG"
OLDBIN="$TMP/oldbin"; mkdir -p "$OLDBIN"
cat > "$OLDBIN/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then printf '  -p, --print\n'; exit 0; fi
printf '%s\n' "$@" > "$FAKE_ARGS"; echo "should never run"
EOF
chmod +x "$OLDBIN/claude"
set +e
env -u DRY_RUN -u MODEL_CMD -u DOZER_MODEL_MARKETING -u DOZER_MODEL_DEFAULT PATH="$OLDBIN:$PATH" FAKE_ARGS="$TMP/old.args" \
  WORKDIR="$TMP/wd-FT-8" REPO_ROOT="$REPO" DOZER_CONFIG="$REPO/org/config.yaml" \
  bash "$CREW" FT-8 "noflag test" >"$TMP/FT-8.log" 2>&1; rc=$?
set -e
(( rc != 0 )) && ok "NOFLAG crew refused to run" || no "NOFLAG crew ran unisolated"
has "$ART/FT-8.fail" "no --safe-mode" && ok "NOFLAG fail reason names --safe-mode" || { no "NOFLAG fail reason wrong"; cat "$TMP/FT-8.log" >&2; }
[[ -e "$TMP/old.args" ]] && no "NOFLAG claude was invoked anyway" || ok "NOFLAG claude never invoked"

# ── ENGINE: files backend, real engine, real crew, stub model ─────────────────
echo "== ENGINE"
ER="$TMP/engine"; mkdir -p "$ER/dozers"
ln -s "$ROOT/dozers/dozer.sh" "$ER/dozers/dozer.sh"
ln -s "$ROOT/dozers/mktg-lane" "$ER/dozers/mktg-lane"
ln -s "$ROOT/dozers/model.sh" "$ER/dozers/model.sh"
cp -R "$ROOT/tasks" "$ER/tasks"; cp -R "$ROOT/org" "$ER/org"; rm -rf "$ER/tasks/board"
mkdir -p "$ER/tasks/board/ready"
printf 'title: Show HN post\nlane: marketing\n\nWrite the Show HN post.\n' > "$ER/tasks/board/ready/ENG-1.md"
printf '%s\n\n=== HANDOFF ===\n%s\n\n%s\n' "$ASSET" "$NOTE" "$FOOTER" > "$TMP/t-engine.txt"
env -u DRY_RUN STUB_OUT="$TMP/t-engine.txt" MODEL_CMD="$STUB" BACKEND=files ADAPTER_QUIET=1 \
  LOCK_DIR="$TMP/locks" REAPER_ENABLED=0 FANOUT=1 \
  bash "$ER/dozers/dozer.sh" once >"$TMP/engine.log" 2>&1 || { no "ENGINE once failed"; cat "$TMP/engine.log" >&2; }
TASK="$ER/tasks/board/review/ENG-1.md"
[[ -f "$TASK" ]] && ok "ENGINE task moved to review" || { no "ENGINE task not in review/"; ls -R "$ER/tasks/board" >&2; cat "$TMP/engine.log" >&2; }
has "$TASK" "Dozer staged for review - lane:marketing" && ok "ENGINE staged comment posted" || no "ENGINE no staged comment"
has "$TASK" "- Picked up: Show HN post" && ok "ENGINE comment carries the crew summary (artifact dir fixed)" || no "ENGINE comment lacks the summary"
has "$TASK" "Handoff note from the crew:" && has "$TASK" "keep the CTA?" && ok "ENGINE comment carries the handoff note" || no "ENGINE comment lacks the handoff note"
has "$TASK" "$FOOTER" && ok "ENGINE stripped footer preserved in the comment" || no "ENGINE stripped footer missing from the comment"
ED="$ER/.dozers-review/ENG-1.md"
[[ -f "$ED" ]] && ok "ENGINE draft staged at $ED" || no "ENGINE no draft"
has "$ED" "Daddy says" && no "ENGINE draft contains the footer" || ok "ENGINE draft has no output-style line"
has "$ED" "keep the CTA?" && no "ENGINE draft contains the handoff note" || ok "ENGINE draft has no handoff note"
[[ "$(cat "$ED")" == "$ASSET" ]] && ok "ENGINE draft is exactly the asset" || { no "ENGINE draft differs"; cat "$ED" >&2; }

(( fail )) && { echo "mktg-lane-footer-test: FAIL" >&2; exit 1; }
echo "mktg-lane-footer-test: PASS"
