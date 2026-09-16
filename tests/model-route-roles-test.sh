#!/usr/bin/env bash
# tests/model-route-roles-test.sh — regression test for PER-ROLE model routing.
#
# Proves the dotted-role machinery on top of the lane-level routing (which
# model-route-test.sh already covers):
#   NESTED    — dev.architect/dev.build/dev.review resolve to their own routes
#   FLATLANE  — a role with no nested entry falls back to the shared flat lane entry
#   DEFAULT   — an unlisted dotted role falls back to models.default
#   OVERRIDE  — DOZER_MODEL_DEV_BUILD (dots -> _ in the role key) beats config
#   SMALL     — `small` (nested) / `small_model:` (flat) fill ANTHROPIC_SMALL_FAST_MODEL
#   NOSMALL   — unset small means small = main (the pre-roles behaviour)
#   NOKEYFILE — ollama-cloud with a missing vault path -> exit 2 with a clear message
#   BADPROV   — an unknown provider inside a nested role -> exit 2, no MODEL_CMD
#   SHOW      — `show` enumerates nested roles as their own rows
#
# Never touches the real org/config.yaml — every case runs against a temp config.
# Run:  bash tests/model-route-roles-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
CFG="$TMP/config.yaml"
VAULT="$TMP/ollama-cloud.env"
FAKE_KEY="fake-ollama-key-do-not-use-0000"

cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
has() { grep -qF "$2" <<<"$1"; }

printf 'OLLAMA_API_KEY=%s\n' "$FAKE_KEY" > "$VAULT"; chmod 600 "$VAULT"

# The fixture covers every case in one config: a nested dev lane (three roles + a
# lane-level `small`), a role with its own small_model, a flat lane with small_model,
# a flat lane without one, and a pinned claude default.
cat > "$CFG" <<YAML
models:
  default: { provider: claude, model: "claude-opus-5" }
  dev:
    architect: { provider: ollama-cloud, model: "glm-5.3:cloud", small_model: "glm-5.3-flash-mini:cloud" }
    build:     { provider: ollama-cloud, model: "kimi-k3:cloud" }
    review:    { provider: codex, model: "gpt-5-codex" }
    small:     "glm-5.3-flash:cloud"
  marketing: { provider: ollama-cloud, model: "glm-5.3:cloud", small_model: "glm-5.3-flash:cloud" }
  ops:       { provider: ollama-cloud, model: "glm-5.2" }
ollama_env: "$VAULT"
YAML

# Same scrub discipline as model-route-test.sh: nothing inherited can colour the route.
SCRUB_ENV=( -u OLLAMA_API_KEY -u MODEL_CMD
            -u DOZER_MODEL_DEV -u DOZER_MODEL_DEV_ARCHITECT -u DOZER_MODEL_DEV_BUILD
            -u DOZER_MODEL_DEV_REVIEW -u DOZER_MODEL_MARKETING
            -u DOZER_MODEL_PROVIDER -u DOZER_MODEL_NAME -u DOZER_MODEL_SOURCE
            -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL
            -u ANTHROPIC_SMALL_FAST_MODEL )

# route [VAR=val ...] <subcommand> [args]
route() {
  local -a envs=()
  while [[ "${1:-}" == *=* ]]; do envs+=("$1"); shift; done
  env "${SCRUB_ENV[@]}" DOZER_CONFIG="$CFG" ${envs[@]+"${envs[@]}"} \
      bash "$ROOT/dozers/model.sh" "$@"
}

echo "== per-role model routing =="

# ── NESTED: each dotted role resolves to its own provider/model ────────────────
out="$(route env dev.architect)"
if has "$out" "export DOZER_MODEL_PROVIDER=ollama-cloud" \
   && has "$out" "export ANTHROPIC_MODEL=glm-5.3:cloud" \
   && has "$out" "config:models.dev.architect"; then
  ok "NESTED dev.architect -> ollama-cloud/glm-5.3:cloud"
else no "NESTED dev.architect wrong; got: $out"; fi

out="$(route env dev.build)"
if has "$out" "export DOZER_MODEL_PROVIDER=ollama-cloud" \
   && has "$out" "export ANTHROPIC_MODEL=kimi-k3:cloud" \
   && has "$out" "config:models.dev.build"; then
  ok "NESTED dev.build -> ollama-cloud/kimi-k3:cloud"
else no "NESTED dev.build wrong; got: $out"; fi

out="$(route env dev.review)"
if has "$out" "export DOZER_MODEL_PROVIDER=codex" \
   && has "$out" "export MODEL_CMD='codex exec --model gpt-5-codex'" \
   && has "$out" "config:models.dev.review"; then
  ok "NESTED dev.review -> codex/gpt-5-codex (a role may use a different provider)"
else no "NESTED dev.review wrong; got: $out"; fi

# ── FLATLANE: a dotted role with no nested entry uses the shared flat entry ───
out="$(route env marketing.drafts)"
if has "$out" "export DOZER_MODEL_PROVIDER=ollama-cloud" \
   && has "$out" "export ANTHROPIC_MODEL=glm-5.3:cloud" \
   && has "$out" "config:models.marketing"; then
  ok "FLATLANE marketing.drafts -> the shared flat marketing entry"
else no "FLATLANE marketing.drafts should use the flat lane entry; got: $out"; fi

# ── DEFAULT: an unlisted dotted role (no entry anywhere) falls to default ─────
out="$(route env ops.audit)"
if has "$out" "export DOZER_MODEL_PROVIDER=ollama-cloud" \
   && has "$out" "export ANTHROPIC_MODEL=glm-5.2" \
   && has "$out" "config:models.ops"; then
  ok "FLATLANE ops.audit -> the shared flat ops entry"
else no "FLATLANE ops.audit should use the flat lane entry; got: $out"; fi
out="$(route env sales.research)"
if has "$out" "export DOZER_MODEL_PROVIDER=claude" \
   && has "$out" "export DOZER_MODEL_NAME=claude-opus-5" \
   && has "$out" "config:models.default"; then
  ok "DEFAULT unlisted dotted role falls back to models.default"
else no "DEFAULT sales.research should use models.default; got: $out"; fi

# ── OVERRIDE: DOZER_MODEL_DEV_BUILD (dots fold to _) beats the nested entry ────
out="$(route DOZER_MODEL_DEV_BUILD=ollama-local:qwen2.5:7b-instruct env dev.build)"
if has "$out" "export ANTHROPIC_BASE_URL=http://localhost:11434" \
   && has "$out" "export ANTHROPIC_MODEL=qwen2.5:7b-instruct" \
   && has "$out" "env:DOZER_MODEL_DEV_BUILD"; then
  ok "OVERRIDE DOZER_MODEL_DEV_BUILD wins over the nested dev.build entry"
else no "OVERRIDE env should win; got: $out"; fi

# ── SMALL: role-level small_model wins, else lane-level `small` ───────────────
out="$(route env dev.architect)"
has "$out" "export ANTHROPIC_SMALL_FAST_MODEL=glm-5.3-flash-mini:cloud" \
  && ok "SMALL role-level small_model beats the lane-level small" \
  || no "SMALL role-level small_model should win; got: $out"
out="$(route env dev.build)"
has "$out" "export ANTHROPIC_SMALL_FAST_MODEL=glm-5.3-flash:cloud" \
  && ok "SMALL lane-level \`small\` fills the fast model when the role has none" \
  || no "SMALL lane-level small should apply; got: $out"

# ── SMALL flat spelling: `small_model:` on a flat entry ───────────────────────
out="$(route env marketing)"
has "$out" "export ANTHROPIC_SMALL_FAST_MODEL=glm-5.3-flash:cloud" \
  && ok "SMALL flat \`small_model:\` fills ANTHROPIC_SMALL_FAST_MODEL" \
  || no "SMALL flat small_model should apply; got: $out"

# ── NOSMALL: no small set -> small = main (the pre-roles behaviour) ───────────
out="$(route env ops)"
has "$out" "export ANTHROPIC_SMALL_FAST_MODEL=glm-5.2" \
  && ok "NOSMALL unset small means small = main" \
  || no "NOSMALL should mirror the main model; got: $out"

# ── NOKEYFILE: ollama-cloutd route with a missing vault path -> exit 2 ────────
NOKEYCFG="$TMP/nokey.yaml"
sed "s|^ollama_env:.*|ollama_env: \"$TMP/does-not-exist.env\"|" "$CFG" > "$NOKEYCFG"
set +e
out="$(env "${SCRUB_ENV[@]}" DOZER_CONFIG="$NOKEYCFG" bash "$ROOT/dozers/model.sh" env dev.build 2>&1)"; rc=$?
set -e
if (( rc == 2 )) && has "$out" "OLLAMA_API_KEY"; then
  ok "NOKEYFILE missing vault path fails fast naming OLLAMA_API_KEY"
else no "NOKEYFILE should exit 2 with a clear message; rc=$rc out=$out"; fi
has "$out" "MODEL_CMD" && no "NOKEYFILE must not emit MODEL_CMD" \
  || ok "NOKEYFILE emits no MODEL_CMD (no silent fallback)"

# ── BADPROV: unknown provider inside a nested role -> exit 2 ──────────────────
BADCFG="$TMP/badprov.yaml"
sed 's|provider: ollama-cloud, model: "kimi-k3:cloud"|provider: gpt9-ultra, model: "x"|' "$CFG" > "$BADCFG"
set +e
out="$(env "${SCRUB_ENV[@]}" DOZER_CONFIG="$BADCFG" bash "$ROOT/dozers/model.sh" env dev.build 2>&1)"; rc=$?
set -e
if (( rc == 2 )) && has "$out" "unknown provider"; then
  ok "BADPROV nested unknown provider -> exit 2"
else no "BADPROV should exit 2; rc=$rc out=$out"; fi
has "$out" "MODEL_CMD" && no "BADPROV must not emit MODEL_CMD" \
  || ok "BADPROV emits no MODEL_CMD (no silent fallback)"

# ── SHOW: nested lanes render one row per role; no secret is printed ──────────
out="$(route show)"
miss=""
for want in "dev.architect" "dev.build" "dev.review" "marketing" "kimi-k3:cloud" "glm-5.3-flash:cloud"; do
  has "$out" "$want" || miss="$miss | $want"
done
[[ -z "$miss" ]] && ok "SHOW lists the nested role rows (dev.architect/build/review)" \
  || no "SHOW missing rows:$miss; got: $out"
# a nested lane must not also print a bare lane row that routes through default
grep -qE '^dev[[:space:]]' <<<"$out" \
  && no "SHOW must not print a bare 'dev' row for a nested lane; got: $out" \
  || ok "SHOW prints no bare 'dev' row for the nested lane"
! grep -qF "$FAKE_KEY" <<<"$out" && ok "SHOW prints no secret" \
  || no "SHOW leaked the key; got: $out"

(( fail )) && { echo "model-route-roles-test: FAIL" >&2; exit 1; }
echo "model-route-roles-test: PASS"
