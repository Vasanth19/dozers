#!/usr/bin/env bash
# dozers/mktg-lane/crew.sh — the MARKETING lane crew.
#
# The engine has claimed the task and cd'd us into the project. Env in:
#   WORKDIR        the project checkout (we work here)
#   DOZER_PERSONA  this lane's persona (dozers/mktg-lane/dozer.md)
#   REPO_ROOT      the dozers repo root (artifacts + config)
#
# Pipeline: load brand voice → produce the asset → STAGE it for approval.
# It NEVER publishes — the human approval gate is the whole point. The engine
# then flips the task to needs-review (not done).
#
# Config/env: DRY_RUN=1 (placeholder draft, no model). Drafts are staged under
#   <workdir>/.dozers-review/<id>.md.
#
# Two kinds of brief (GSAI-7). The engine hands the issue description in as a file
# (DOZER_BRIEF). A brief whose description carries a `production:` line pointing at a
# `<brand>/creatives/productions/<MM.DD-slug>/` folder is a VIDEO brief and runs the
# HeyGen pipeline in dozers/mktg-lane/video.sh (match render → stale gate → download →
# compose → stage). Every other brief is a COPY brief and takes the path below,
# unchanged. Both end staged, never published.
#
# Model routing: the brain this lane runs on comes from org/config.yaml
#   `models.marketing` (provider + model), resolved by dozers/model.sh. Override
#   per-run with DOZER_MODEL_MARKETING="<provider>[:<model>]" (e.g. ollama-cloud:glm-5.2),
#   or bypass routing entirely by exporting MODEL_CMD. A route that can't be satisfied
#   FAILS the crew — no silent fallback.
#
# The artifact is NOT the transcript (GSAI-33). Three rules keep an operator's personal
# harness out of a publishable asset:
#   1. ISOLATION — when the content model is the claude CLI, it runs with --safe-mode:
#      no output styles, hooks, CLAUDE.md, plugins or MCP servers from the operator's
#      own config (auth, model and built-in tools still work). A claude without that
#      flag FAILS the crew rather than running unisolated.
#   2. SPLIT — the model's raw stdout lands in .artifacts/mktg/<id>.raw (the
#      transcript). Only the asset goes to .dozers-review/<id>.md. Anything the model
#      writes after a `=== HANDOFF ===` line is the note for the reviewer: it goes to
#      .artifacts/mktg/<id>.handoff, and the engine posts it inside the
#      "staged for review" task comment — never into the deliverable.
#   3. BACKSTOP — on stage, any line matching `output_style_footer:` (org/config.yaml;
#      default: the `👨 Daddy says` footer) is stripped from the asset, moved into the
#      handoff note, and LOGGED loudly — if it fires, isolation leaked and that is a bug.
set -euo pipefail
ID="$1"; TITLE="$2"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORKDIR="${WORKDIR:-.}"; DOZER_PERSONA="${DOZER_PERSONA:-}"
OUT="$REPO_ROOT/.artifacts/mktg"; mkdir -p "$OUT"
# fail: print the reason AND record it in $OUT/<id>.fail so the engine puts it in the
# block comment (GSAI-26 #3) — same contract as the dev lane.
fail() { echo "    [mktg] ✗ $*" >&2; printf '%s\n' "$*" > "$OUT/$ID.fail" 2>/dev/null || true; exit 1; }
rm -f "$OUT/$ID.fail" "$OUT/$ID.handoff" 2>/dev/null || true

cfg() { grep -E "^$1:" "$REPO_ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/"//g' || true; }
VOICE="$(grep -E '^[[:space:]]*voice:' "$REPO_ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*voice:[[:space:]]*//; s/"//g' || true)"; VOICE="${VOICE:-clear, warm, no hype}"

# ── Model routing (see dozers/model.sh). MODEL_CMD already in the env wins (legacy
# override); otherwise resolve this ROLE's route. Fail fast — a bad provider or a
# missing key stops the crew, it never silently falls back to claude.
DOZER_ROLE="${DOZER_ROLE:-marketing}"
if [[ -n "${MODEL_CMD:-}" ]]; then
  DOZER_MODEL_PROVIDER="${DOZER_MODEL_PROVIDER:-env}"; DOZER_MODEL_NAME="${DOZER_MODEL_NAME:-MODEL_CMD}"
else
  _route="$("$REPO_ROOT/dozers/model.sh" env "$DOZER_ROLE")" \
    || fail "model routing failed for role '$DOZER_ROLE'"
  eval "$_route"; unset _route
fi
MODEL_DESC="${DOZER_MODEL_PROVIDER:-claude}/${DOZER_MODEL_NAME:-default}"

# ── Harness isolation (GSAI-33 rule 1) ───────────────────────────────────────
# `claude -p` inherits the operator's global config — output style, hooks, CLAUDE.md,
# MCP — and every one of those can write into the reply that becomes the deliverable
# (24/24 staged drafts carried the "👨 Daddy says" footer). --safe-mode starts claude
# with all of that disabled while auth, model choice and built-in tools keep working.
# Applied by the command word, not the provider: the claude CLI is also how the
# ollama-* routes run, and a legacy MODEL_CMD="claude -p" gets it too. Done BEFORE the
# video branch so the compose step inherits it.
claude_isolate() {
  local first="${MODEL_CMD%% *}"
  [[ "$(basename -- "$first")" == "claude" ]] || return 0
  case " $MODEL_CMD " in *" --safe-mode "*) return 0;; esac
  "$first" --help 2>/dev/null | grep -q -- '--safe-mode' \
    || fail "claude CLI ('$first') has no --safe-mode flag — refusing to produce a publishable asset through the operator's personal harness config (upgrade claude, or route role '$DOZER_ROLE' to another provider)"
  MODEL_CMD="$MODEL_CMD --safe-mode"
  ISOLATED="claude --safe-mode (operator output style/hooks/CLAUDE.md/MCP off)"
}
ISOLATED=""; claude_isolate

cd "$WORKDIR" 2>/dev/null || true
echo "    [mktg] cwd=$(pwd)  voice=\"$VOICE\""
echo "    [mktg] model: $MODEL_DESC${ISOLATED:+  isolation: $ISOLATED}"
[[ -n "$DOZER_PERSONA" ]] && echo "    [mktg] persona: $DOZER_PERSONA" || true

REVIEW_DIR="$WORKDIR/.dozers-review"; mkdir -p "$REVIEW_DIR"
DRAFT="$REVIEW_DIR/$ID.md"

# ── route: video brief → the HeyGen pipeline (GSAI-7) ────────────────────────
# A `production:` line in the brief is the whole signal. The video script owns its
# own fail/summary artifacts (same contract), so we hand over completely.
DOZER_BRIEF="${DOZER_BRIEF:-}"
if [[ -n "$DOZER_BRIEF" && -f "$DOZER_BRIEF" ]] \
   && grep -qiE '^[[:space:]]*([-*][[:space:]]+)?(\*\*|__)?[[:space:]]*production[[:space:]]*(\*\*|__)?[[:space:]]*:' "$DOZER_BRIEF"; then
  echo "    [mktg] video brief (production: line) → dozers/mktg-lane/video.sh"
  export MODEL_CMD MODEL_DESC DOZER_MODEL_PROVIDER DOZER_MODEL_NAME DOZER_BRIEF WORKDIR REPO_ROOT
  exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/video.sh" "$ID" "$TITLE"
fi

# ── stage: transcript → deliverable + handoff (GSAI-33 rules 2 + 3) ──────────
HANDOFF_MARK="=== HANDOFF ==="
FOOTER_RE="$(cfg output_style_footer)"; FOOTER_RE="${FOOTER_RE:-^[[:space:]]*(👨[[:space:]]*)?Daddy says}"
RAW="$OUT/$ID.raw"; HANDOFF="$OUT/$ID.handoff"
BACKSTOP_NOTE=""; HANDOFF_NOTE=""
# split the raw transcript: everything before the marker is the asset, after it the note.
_asset()   { awk -v m="$HANDOFF_MARK" '{t=$0; gsub(/^[ \t]+|[ \t\r]+$/,"",t)} t==m{exit} {print}' "$1"; }
_handoff() { awk -v m="$HANDOFF_MARK" 'f{print} {t=$0; gsub(/^[ \t]+|[ \t\r]+$/,"",t)} t==m{f=1}' "$1"; }
# drop leading blank lines; trailing ones die in the $( ) capture.
_trim()    { sed '/./,$!d'; }
stage_draft() { # <raw transcript> → $DRAFT, and $HANDOFF if there is a note
  local raw="$1" body note stripped n
  body="$(_asset "$raw" | _trim)"
  note="$(_handoff "$raw" | _trim)"
  # backstop: an output-style line is never part of the asset. It is not thrown away —
  # the footers carried real reviewer notes — it moves to the handoff, and we shout.
  stripped="$(printf '%s\n' "$body" | grep -E -- "$FOOTER_RE" || true)"
  if [[ -n "$stripped" ]]; then
    n="$(printf '%s\n' "$stripped" | grep -c . || true)"
    body="$(printf '%s\n' "$body" | grep -Ev -- "$FOOTER_RE" | _trim || true)"
    echo "    [mktg] ⚠ BACKSTOP FIRED: stripped $n output-style line(s) from the draft (pattern: $FOOTER_RE). Isolation leaked — raw transcript kept at $raw" >&2
    note="${note:+$note
}Output-style line(s) removed from the asset by the stage backstop (kept here for the reviewer):
$stripped"
    BACKSTOP_NOTE="- ⚠ Backstop stripped $n output-style line(s) from the draft — harness isolation leaked; raw transcript: $raw"
  fi
  [[ -n "${body//[[:space:]]/}" ]] || fail "empty draft (nothing left of the transcript once the handoff/output-style lines were removed — see $raw)"
  printf '%s\n' "$body" > "$DRAFT"
  if [[ -n "${note//[[:space:]]/}" ]]; then
    printf '%s\n' "$note" > "$HANDOFF"
    HANDOFF_NOTE="- Handoff note for the reviewer: $(printf '%s\n' "$note" | grep -c .) line(s) → posted in this comment, kept out of the draft"
  fi
}

# ── produce the asset (staged, never published) ──────────────────────────────
if [[ "${DRY_RUN:-}" == "1" ]]; then
  cat > "$RAW" <<EOF
# DRAFT — needs approval — #$ID
brief: $TITLE
voice: $VOICE
---
[placeholder draft produced in DRY_RUN — real copy comes from the content model]
EOF
  stage_draft "$RAW"
  echo "    [mktg] DRY_RUN — wrote placeholder draft"
else
  read -r -d '' PROMPT <<EOF || true
You are a Dozer producing a marketing asset. Brand voice: $VOICE.
Persona/rules: $DOZER_PERSONA
Brief #$ID: $TITLE

Output ONLY the finished asset — no preamble, no commentary, no sign-off. It is written to a file and published as-is.
If you have notes for the human reviewer (open questions, a blocker, anything you could not verify), put them AFTER the asset on their own lines, following a line that is exactly:
$HANDOFF_MARK
Those notes reach the reviewer as a task comment and never enter the asset. If you have none, omit the marker.
EOF
  # </dev/null: headless CLIs wait on a piped stdin otherwise. stderr is kept for the
  # fail message (the old 2>/dev/null hid the real error).
  if ! eval "$MODEL_CMD \"\$PROMPT\"" </dev/null > "$RAW" 2>"$OUT/$ID.model.err"; then
    fail "content model failed: $(tail -c 600 "$OUT/$ID.model.err" 2>/dev/null | tr '\n' ' ')"
  fi
  [[ -s "$RAW" ]] || fail "empty draft (model produced no output)"
  stage_draft "$RAW"
  echo "    [mktg] produced draft via model"
fi

echo "    [mktg] staged for approval: $DRAFT  (NOT published)"
[[ -s "$HANDOFF" ]] && echo "    [mktg] handoff note → $HANDOFF (goes to the task comment, not the draft)" || true

cat > "$OUT/$ID.md" <<EOF
# MARKETING draft for #$ID  (awaiting approval)
brief: $TITLE
draft: $DRAFT
transcript: $RAW
handoff: ${HANDOFF_NOTE:+$HANDOFF}${HANDOFF_NOTE:-(none)}
status: NEEDS REVIEW — nothing publishes until a human approves
EOF

if [[ "${DRY_RUN:-}" == "1" ]]; then made="placeholder draft (dry-run)"; else made="draft via content model"; fi
{
  cat <<EOF
- Picked up: $TITLE
- model: $MODEL_DESC${ISOLATED:+ · $ISOLATED}
- Loaded brand voice: $VOICE
- Produced: $made
- Staged → $DRAFT (NOT published)
EOF
  [[ -n "$HANDOFF_NOTE" ]] && printf '%s\n' "$HANDOFF_NOTE"
  [[ -n "$BACKSTOP_NOTE" ]] && printf '%s\n' "$BACKSTOP_NOTE"
  echo "- Awaiting human approval"
} > "$OUT/$ID.summary"
echo "    [mktg] done #$ID (staged)"
