#!/usr/bin/env bash
# tests/model-route-test.sh — regression test for per-role model routing.
#
# Proves the knob that decides WHICH BRAIN a role runs on behaves, and above all that
# it FAILS FAST instead of quietly falling back to claude:
#   DEFAULT   — shipped config routes every role to claude -p (nothing changed on merge)
#   OVERRIDE  — DOZER_MODEL_<ROLE>=ollama-cloud:<model> emits the proven ANTHROPIC_* env
#   VAULT     — the key is read from the configured env file, never printed by `show`
#   NOKEY     — ollama-cloud with no key anywhere -> exit 2 with a clear message
#   BADPROV   — an unknown provider -> exit 2, no MODEL_CMD emitted
#   LOCAL     — ollama-local without a model -> exit 2 (no host-independent default)
#   CODEX     — codex routes to `codex exec` (+ --model)
#   CREW      — a pre-set MODEL_CMD is respected by the crew (legacy override wins),
#               and a crew with an unroutable role fails instead of running claude
#
# Never touches the real org/config.yaml — every case runs against a temp copy.
# Run:  bash tests/model-route-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
CFG="$TMP/config.yaml"
VAULT="$TMP/ollama-cloud.env"
FAKE_KEY="fake-ollama-key-do-not-use-0000"

cleanup() { rm -rf "$TMP" 2>/dev/null || true; rm -f "$ROOT/.artifacts/mktg/MRT-"* 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
has() { grep -qF "$2" <<<"$1"; }

cp "$ROOT/org/config.yaml" "$CFG"
printf 'OLLAMA_API_KEY=%s\n' "$FAKE_KEY" > "$VAULT"; chmod 600 "$VAULT"
# Point the temp config's vault path at the temp key file (no real secret in this test).
python3 - "$CFG" "$VAULT" <<'PY'
import re, sys
p, vault = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r'(?m)^ollama_env:.*$', 'ollama_env: "%s"' % vault, s)
open(p, 'w').write(s)
PY

# Every invocation below is scoped to the temp config. Also scrub any inherited
# OLLAMA_API_KEY / DOZER_MODEL_* so the host's environment can't colour the result.
# route [VAR=val ...] <subcommand> [args]
route() {
  local -a envs=()
  while [[ "${1:-}" == *=* ]]; do envs+=("$1"); shift; done
  env -u OLLAMA_API_KEY -u DOZER_MODEL_DEV -u DOZER_MODEL_MARKETING -u DOZER_MODEL_SMOKE \
      DOZER_CONFIG="$CFG" ${envs[@]+"${envs[@]}"} bash "$ROOT/dozers/model.sh" "$@"
}

echo "== model routing =="

# ── DEFAULT: shipped config = claude for every role ────────────────────────────
out="$(route env dev)"
if has "$out" "export MODEL_CMD='claude -p'" && has "$out" "export DOZER_MODEL_PROVIDER=claude"; then
  ok "DEFAULT dev -> claude -p"; else no "DEFAULT dev should route to claude -p; got: $out"; fi
out="$(route env marketing)"
has "$out" "export MODEL_CMD='claude -p'" && ok "DEFAULT marketing -> claude -p" \
  || no "DEFAULT marketing should route to claude -p; got: $out"
# an unlisted role falls back to models.default
out="$(route env sales)"
has "$out" "config:models.default" && ok "DEFAULT unlisted role falls back to models.default" \
  || no "unlisted role should use models.default; got: $out"

# ── OVERRIDE: env wins, and emits the proven ollama-cloud recipe ───────────────
out="$(route DOZER_MODEL_DEV=ollama-cloud:glm-5.2 env dev)"
miss=""
for want in \
  "unset ANTHROPIC_API_KEY" \
  "export ANTHROPIC_BASE_URL=https://ollama.com" \
  "export ANTHROPIC_MODEL=glm-5.2" \
  "export ANTHROPIC_SMALL_FAST_MODEL=glm-5.2" \
  "export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" \
  "export DOZER_MODEL_PROVIDER=ollama-cloud" \
  "export MODEL_CMD='claude -p'"
do has "$out" "$want" || miss="$miss | $want"; done
[[ -z "$miss" ]] && ok "OVERRIDE ollama-cloud emits the full ANTHROPIC_* recipe" \
  || no "OVERRIDE missing exports:$miss"
# the Bearer token must be ANTHROPIC_AUTH_TOKEN (x-api-key 401-hangs on ollama)
has "$out" "export ANTHROPIC_AUTH_TOKEN=$FAKE_KEY" \
  && ok "VAULT key read from ollama_env into ANTHROPIC_AUTH_TOKEN" \
  || no "expected ANTHROPIC_AUTH_TOKEN from the vault file; got: $out"
# ollama-cloud with no explicit model uses the provider default
out="$(route DOZER_MODEL_DEV=ollama-cloud env dev)"
has "$out" "export ANTHROPIC_MODEL=glm-5.2" && ok "OVERRIDE bare ollama-cloud uses the provider default model" \
  || no "bare ollama-cloud should pick a provider default; got: $out"

# ── VAULT: `show` must never leak the token ────────────────────────────────────
python3 - "$CFG" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('dev:       { provider: claude, model: "" }',
              'dev:       { provider: ollama-cloud, model: "glm-5.2" }')
open(p, 'w').write(s)
PY
out="$(route show)"
if has "$out" "ollama-cloud" && ! grep -qF "$FAKE_KEY" <<<"$out"; then
  ok "SHOW lists the route and prints no secret"
else no "SHOW leaked the key or lost the route; got: $out"; fi
has "$out" "present" && ok "SHOW reports key presence without the value" || no "SHOW should report key presence"
# config-level route (not just env) resolves too
out="$(route env dev)"
has "$out" "config:models.dev" && has "$out" "export ANTHROPIC_MODEL=glm-5.2" \
  && ok "CONFIG models.dev route resolves" || no "config route failed; got: $out"

# ── NOKEY: ollama-cloud with no key anywhere -> exit 2, clear message ──────────
rm -f "$VAULT"
set +e
out="$(route env dev 2>&1)"; rc=$?
set -e
if (( rc == 2 )) && has "$out" "OLLAMA_API_KEY"; then
  ok "NOKEY fails fast (exit 2) naming OLLAMA_API_KEY"
else no "NOKEY should exit 2 with a clear message; rc=$rc out=$out"; fi
has "$out" "MODEL_CMD" && no "NOKEY must not emit MODEL_CMD" || ok "NOKEY emits no MODEL_CMD (no silent fallback)"
printf 'OLLAMA_API_KEY=%s\n' "$FAKE_KEY" > "$VAULT"

# ── BADPROV: unknown provider -> exit 2 ────────────────────────────────────────
set +e
out="$(route DOZER_MODEL_DEV=gpt5-turbo env dev 2>&1)"; rc=$?
set -e
if (( rc == 2 )) && has "$out" "unknown provider"; then ok "BADPROV unknown provider -> exit 2"
else no "BADPROV should exit 2; rc=$rc out=$out"; fi

# ── LOCAL: ollama-local needs an explicit model; with one it targets localhost ─
set +e
out="$(route DOZER_MODEL_DEV=ollama-local env dev 2>&1)"; rc=$?
set -e
(( rc == 2 )) && ok "LOCAL bare ollama-local -> exit 2 (explicit model required)" \
  || no "LOCAL bare ollama-local should exit 2; rc=$rc out=$out"
out="$(route DOZER_MODEL_DEV='ollama-local:qwen2.5:7b-instruct' env dev)"
if has "$out" "export ANTHROPIC_BASE_URL=http://localhost:11434" \
   && has "$out" "export ANTHROPIC_MODEL=qwen2.5:7b-instruct"; then
  ok "LOCAL with a model targets localhost:11434"
else no "LOCAL route wrong; got: $out"; fi

# ── CODEX: routes to the codex CLI, headless ──────────────────────────────────
out="$(route DOZER_MODEL_DEV=codex env dev)"
has "$out" "export MODEL_CMD='codex exec'" && ok "CODEX -> codex exec" || no "CODEX route wrong; got: $out"
out="$(route DOZER_MODEL_DEV=codex:gpt-5-codex env dev)"
has "$out" "export MODEL_CMD='codex exec --model gpt-5-codex'" \
  && ok "CODEX with a model appends --model" || no "CODEX --model wrong; got: $out"

# ── CREW: MODEL_CMD in the env wins; an unroutable role fails the crew ────────
WD="$TMP/proj"; mkdir -p "$WD"
crew() { # <extra env...>  — run the mktg crew in DRY_RUN against a temp workdir
  env -u OLLAMA_API_KEY -u DOZER_MODEL_MARKETING DOZER_CONFIG="$CFG" DRY_RUN=1 \
    WORKDIR="$WD" REPO_ROOT="$ROOT" "$@" bash "$ROOT/dozers/mktg-lane/crew.sh" MRT-1 "routing smoke"
}
set +e
out="$(crew MODEL_CMD='echo stub' DOZER_MODEL_MARKETING=totally-bogus 2>&1)"; rc=$?
set -e
if (( rc == 0 )) && has "$out" "model: env/MODEL_CMD"; then
  ok "CREW respects a pre-set MODEL_CMD (bypasses routing entirely)"
else no "CREW should honour a pre-set MODEL_CMD; rc=$rc out=$out"; fi
grep -qF "model: env/MODEL_CMD" "$ROOT/.artifacts/mktg/MRT-1.summary" 2>/dev/null \
  && ok "CREW records the model in the task summary" \
  || no "CREW summary should carry a 'model:' line"
set +e
out="$(crew DOZER_MODEL_MARKETING=totally-bogus 2>&1)"; rc=$?
set -e
if (( rc != 0 )) && has "$out" "model routing failed"; then
  ok "CREW fails fast on an unroutable role (no silent claude fallback)"
else no "CREW should fail on a bad route; rc=$rc out=$out"; fi

(( fail )) && { echo "model-route-test: FAIL" >&2; exit 1; }
echo "model-route-test: PASS"
