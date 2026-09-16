#!/usr/bin/env bash
# tests/dev-lane-model-prompt-test.sh — regression test for GSAI-150.
#
# run_model_pass built the model command as a string handed to timebox, whose
# `( cd dir && eval <cmd> )` (eval #1) expanded $_PASS_PROMPT INTO the string, and the
# inner `eval "$MODEL_CMD \"$_PASS_PROMPT\""` (eval #2) then parsed that text as SHELL
# CODE. The prompt is untrusted: the review prompt embeds `git diff "$base"` (written
# by the BUILD pass — itself model-authored), and every prompt embeds the task title.
# So on EVERY review of EVERY task, any $( … ) or backtick in the diff EXECUTED with
# the crew's permissions, and a stray " silently mangled the prompt the judge received.
# The fix is one character class: `\$_PASS_PROMPT`, so the prompt expands exactly once,
# inside double quotes, at the second eval's parse — one byte-identical argv, inert
# metacharacters (the same shape the mktg lane and model.sh smoke already use).
#
# Cases (in the idiom of dev-lane-model-exit-test.sh — throwaway repo + stub agent):
#   INJECTION  (MODEL_CMD bypass) — the build stub commits a file whose DIFF lines
#              contain `$(touch <marker>)` and a backtick `touch`. The review stub
#              captures the prompt it actually received. Assert: no marker files, the
#              payload lines arrive VERBATIM in the received prompt, and the crew still
#              merges. On the unpatched crew the markers appear (mechanical proof).
#   ROUND-TRIP (bypass) — a task TITLE carrying `$(echo hi)`, and a diff line with a
#              lone `"`. Assert the architect prompt carries `$(echo hi)` literally and
#              the review prompt carries the quote line literally — the prompt-mangling
#              half of the bug.
#   ROUTED     — INJECTION again with MODEL_CMD scrubbed and a stub `claude` on PATH
#              (same SCRUB_ROUTE discipline as dev-lane-model-exit-test.sh), so the fix
#              is proven on the route-block path (`eval "$_PASS_BLOCK"`) too.
#
# Run:  bash tests/dev-lane-model-prompt-test.sh   (exits non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() {
  rm -f "$ROOT"/.artifacts/dev/TEST-MP* 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# A throwaway repo on `main` + `develop` with a fast, always-green test command.
mkproj() {  # $1 = dir
  local d="$1"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    printf '{"name":"p","version":"1.0.0","scripts":{"test":"bash t.sh"}}\n' > package.json
    printf 'exit 0\n' > t.sh
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m init
    git branch develop )
}

# Stub coding agent. Counts invocations in $COUNT_FILE; invocation 1 is the architect
# pass, then build/review alternate (2=build, 3=review, …). Each pass CAPTURES the
# prompt it actually received (the last argv element — `claude -p "<prompt>"` on the
# routed path, bare `"<prompt>"` on the bypass) into $CAP_DIR/<pass>.txt. The build
# pass commits injected.sh whose payload lines are what the REVIEW prompt's embedded
# diff will carry: a $(touch …) substitution and a backtick touch. QUOTE_LINE=1 adds a
# lone quote on top (the mangling proof) — kept OUT of the injection runs because a
# quote-shift makes the unpatched eval fail to PARSE at all, which would mask the
# execution proof behind a syntax error.
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$COUNT_FILE"
if   (( n == 1 )); then pass=architect
elif (( n % 2 == 0 )); then pass=build
else pass=review; fi
last=""; for a in "$@"; do last="$a"; done
printf '%s' "$last" > "$CAP_DIR/$pass.txt"
case "$pass" in
  architect)
    printf '# design\n' > DOZER-DESIGN.md
    git add -A && git commit -q -m design ;;
  build)
    # Unquoted heredoc: \$ and \` stay literal, $MARKER_DIR bakes the abs path in —
    # so the committed file (and therefore the review DIFF) carries live metacharacters.
    cat > injected.sh <<INNER
echo "sha \$(touch $MARKER_DIR/pwned-by-review)"
echo bkt \`touch $MARKER_DIR/pwned-too\`
INNER
    [[ "${QUOTE_LINE:-0}" == 1 ]] && printf 'echo "never closed quote on this line\n' >> injected.sh
    git add -A && git commit -q -m "add injected.sh" ;;
  review)
    printf 'VERDICT: PASS\nok\n' > DOZER-REVIEW.md
    git add -A && git commit -q -m review || true ;;
esac
exit 0
EOS
chmod +x "$STUB"

BOUND=15   # nothing here hangs; headroom over `npm test` startup (see dev-lane-model-exit-test.sh)

# MODEL_CMD bypass path: all three passes run the stub through the bypass branch.
run_crew() {  # $1 = proj dir, $2 = task id, $3 = log, $4 = title, $5.. = extra KEY=VAL
  local proj="$1" id="$2" log="$3" title="$4"; shift 4
  mkdir -p "$TMP/cap-$id" "$TMP/mark-$id"
  env COUNT_FILE="$TMP/$id.count" CAP_DIR="$TMP/cap-$id" MARKER_DIR="$TMP/mark-$id" TIMEBOX_KILL_GRACE=1 \
      DOZER_TIMEOUT_TEST="$BOUND" DOZER_TIMEOUT_MODEL="$BOUND" DOZER_TIMEOUT_DEPS="$BOUND" \
      REPO_ROOT="$TMP" WORKDIR="$proj" WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
      MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" "$@" \
      bash "$CREW" "$id" "$title" >"$log" 2>&1
}

# Routed path (no MODEL_CMD): resolves the passes' routes for real, landing on a stub
# `claude` earlier in PATH. The SCRUB matters: this suite is run by run-all.sh from
# inside a REAL Dozer crew, where MODEL_CMD and the DOZER_MODEL_* routing block are
# already exported — an inherited MODEL_CMD would silently take the bypass branch and
# the route-block eval would never be exercised (same failure class as the GSAI-30
# scrub in run-all.sh).
SCRUB_ROUTE=( -u MODEL_CMD -u DOZER_MODEL_PROVIDER -u DOZER_MODEL_NAME -u DOZER_MODEL_SOURCE
              -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL
              -u ANTHROPIC_SMALL_FAST_MODEL -u OLLAMA_API_KEY -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC )
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"; cp "$STUB" "$BINDIR/claude"; chmod +x "$BINDIR/claude"
run_crew_routed() {  # same args as run_crew
  local proj="$1" id="$2" log="$3" title="$4"
  mkdir -p "$TMP/cap-$id" "$TMP/mark-$id"
  env "${SCRUB_ROUTE[@]}" PATH="$BINDIR:$PATH" \
      COUNT_FILE="$TMP/$id.count" CAP_DIR="$TMP/cap-$id" MARKER_DIR="$TMP/mark-$id" TIMEBOX_KILL_GRACE=1 \
      DOZER_TIMEOUT_TEST="$BOUND" DOZER_TIMEOUT_MODEL="$BOUND" DOZER_TIMEOUT_DEPS="$BOUND" \
      REPO_ROOT="$ROOT" WORKDIR="$proj" WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
      DOZER_MODEL_DEV_ARCHITECT="claude:claude-opus-5" \
      DOZER_MODEL_DEV_BUILD="claude:claude-opus-5" \
      DOZER_MODEL_DEV_REVIEW="claude:claude-opus-5" \
      PUSH="false" DOZER_PERSONA="test" \
      bash "$CREW" "$id" "$title" >"$log" 2>&1
}

dev_head()     { git -C "$1" log -1 --format=%s develop 2>/dev/null || true; }
no_markers() {  # $1 = marker dir, $2 = case label
  if [[ -z "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    ok "$2: no marker files — the diff's \$(…) and backticks did NOT execute"
  else
    no "$2: MARKERS PRESENT ($(ls "$1" 2>/dev/null | tr '\n' ' ')) — the review prompt was executed as shell"
  fi
}

# ── INJECTION: the diff's $(…) and backticks must never execute ───────────────
PA="$TMP/inject"; mkproj "$PA"; MID="TEST-MP-A"; LOG="$TMP/a.log"; rc=0
run_crew "$PA" "$MID" "$LOG" "prompt injection test" || rc=$?
n1="sha \$(touch $TMP/mark-$MID/pwned-by-review)"
n2="bkt \`touch $TMP/mark-$MID/pwned-too\`"
no_markers "$TMP/mark-$MID" "INJECTION"
[[ -f "$TMP/cap-$MID/review.txt" ]] \
  && grep -Fq "$n1" "$TMP/cap-$MID/review.txt" \
  && ok "INJECTION: \$(touch …) payload arrived VERBATIM in the review prompt" \
  || { no "INJECTION: payload missing/mangled in the review prompt"; dump "$TMP/cap-$MID/review.txt" 2>/dev/null || true; }
grep -Fq "$n2" "$TMP/cap-$MID/review.txt" 2>/dev/null \
  && ok "INJECTION: backtick payload arrived VERBATIM in the review prompt" \
  || { no "INJECTION: backtick payload missing/mangled in the review prompt"; dump "$TMP/cap-$MID/review.txt" 2>/dev/null || true; }
[[ $rc -eq 0 && "$(dev_head "$PA")" == merge*"$MID"* ]] \
  && ok "INJECTION: crew still completes and merges (the fix changes no gate)" \
  || { no "INJECTION: crew exited $rc; develop HEAD '$(dev_head "$PA")'"; dump "$LOG"; }

# ── ROUND-TRIP: title metacharacters + a lone quote arrive byte-identical ─────
PB="$TMP/roundtrip"; mkproj "$PB"; RID="TEST-MP-B"; LOG="$TMP/b.log"; rc=0
run_crew "$PB" "$RID" "$LOG" 'round trip $(echo hi) title' QUOTE_LINE=1 || rc=$?
no_markers "$TMP/mark-$RID" "ROUND-TRIP"
grep -Fq '$(echo hi)' "$TMP/cap-$RID/architect.txt" 2>/dev/null \
  && ok "ROUND-TRIP: the title's \$(echo hi) reached the architect prompt literally" \
  || { no "ROUND-TRIP: title metacharacters executed/mangled"; dump "$TMP/cap-$RID/architect.txt" 2>/dev/null || true; }
grep -Fq 'echo "never closed quote on this line' "$TMP/cap-$RID/review.txt" 2>/dev/null \
  && ok "ROUND-TRIP: the lone-quote diff line reached the review prompt literally" \
  || { no "ROUND-TRIP: quote-shift mangled the review prompt"; dump "$TMP/cap-$RID/review.txt" 2>/dev/null || true; }
[[ $rc -eq 0 && "$(dev_head "$PB")" == merge*"$RID"* ]] \
  && ok "ROUND-TRIP: crew still completes and merges" \
  || { no "ROUND-TRIP: crew exited $rc; develop HEAD '$(dev_head "$PB")'"; dump "$LOG"; }

# ── ROUTED: same injection through the route-block path (eval "$_PASS_BLOCK") ──
PC="$TMP/routed"; mkproj "$PC"; XID="TEST-MP-R"; LOG="$TMP/r.log"; rc=0
run_crew_routed "$PC" "$XID" "$LOG" "routed injection test" || rc=$?
n3="sha \$(touch $TMP/mark-$XID/pwned-by-review)"
no_markers "$TMP/mark-$XID" "ROUTED"
grep -Fq "$n3" "$TMP/cap-$XID/review.txt" 2>/dev/null \
  && ok "ROUTED: \$(touch …) payload arrived VERBATIM through the route-block path" \
  || { no "ROUTED: payload missing/mangled on the routed path"; dump "$TMP/cap-$XID/review.txt" 2>/dev/null || true; }
[[ $rc -eq 0 && "$(dev_head "$PC")" == merge*"$XID"* ]] \
  && ok "ROUTED: crew still completes and merges on the routed path" \
  || { no "ROUTED: crew exited $rc; develop HEAD '$(dev_head "$PC")'"; dump "$LOG"; }

if [[ $fail == 0 ]]; then echo "dev-lane-model-prompt-test: PASS"
else echo "dev-lane-model-prompt-test: FAIL" >&2; exit 1; fi
