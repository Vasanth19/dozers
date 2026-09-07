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
set -euo pipefail
ID="$1"; TITLE="$2"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORKDIR="${WORKDIR:-.}"; DOZER_PERSONA="${DOZER_PERSONA:-}"
OUT="$REPO_ROOT/.artifacts/mktg"; mkdir -p "$OUT"
# fail: print the reason AND record it in $OUT/<id>.fail so the engine puts it in the
# block comment (GSAI-26 #3) — same contract as the dev lane.
fail() { echo "    [mktg] ✗ $*" >&2; printf '%s\n' "$*" > "$OUT/$ID.fail" 2>/dev/null || true; exit 1; }
rm -f "$OUT/$ID.fail" 2>/dev/null || true

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

cd "$WORKDIR" 2>/dev/null || true
echo "    [mktg] cwd=$(pwd)  voice=\"$VOICE\""
echo "    [mktg] model: $MODEL_DESC"
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

# ── produce the asset (staged, never published) ──────────────────────────────
if [[ "${DRY_RUN:-}" == "1" ]]; then
  cat > "$DRAFT" <<EOF
# DRAFT — needs approval — #$ID
brief: $TITLE
voice: $VOICE
---
[placeholder draft produced in DRY_RUN — real copy comes from the content model]
EOF
  echo "    [mktg] DRY_RUN — wrote placeholder draft"
else
  read -r -d '' PROMPT <<EOF || true
You are a Dozer producing a marketing asset. Brand voice: $VOICE.
Persona/rules: $DOZER_PERSONA
Output ONLY the finished asset (no preamble). Brief #$ID: $TITLE
EOF
  eval "$MODEL_CMD \"\$PROMPT\"" > "$DRAFT" 2>/dev/null || fail "content model failed"
  [[ -s "$DRAFT" ]] || fail "empty draft"
  echo "    [mktg] produced draft via model"
fi

echo "    [mktg] staged for approval: $DRAFT  (NOT published)"

cat > "$OUT/$ID.md" <<EOF
# MARKETING draft for #$ID  (awaiting approval)
brief: $TITLE
draft: $DRAFT
status: NEEDS REVIEW — nothing publishes until a human approves
EOF

if [[ "${DRY_RUN:-}" == "1" ]]; then made="placeholder draft (dry-run)"; else made="draft via content model"; fi
cat > "$OUT/$ID.summary" <<EOF
- Picked up: $TITLE
- model: $MODEL_DESC
- Loaded brand voice: $VOICE
- Produced: $made
- Staged → $DRAFT (NOT published)
- Awaiting human approval
EOF
echo "    [mktg] done #$ID (staged)"
