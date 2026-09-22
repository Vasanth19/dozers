#!/usr/bin/env bash
# dozers/model-failure.sh — classify a model pass's failure, and route around the
# one class that is worth routing around.
#
#   model_failure_reason      <log>   → short human reason, or empty
#   model_failure_transient   <log>   → exit 0 when the provider was AVAILABLE-failing
#   model_fallback_block              → eval-able export block for `models.fallback`,
#                                       or empty when no fallback is configured
#   model_fallback_desc               → "provider/model" for the fallback, or empty
#
# WHY THIS EXISTS (GSAI-160 follow-on, Vasanth 2026-09-21)
# -------------------------------------------------------
# `tasks/model_route.py` says, deliberately: "There is NO silent fallback to claude —
# a misconfigured route" must fail. That rule is right and is NOT relaxed here. What
# it was protecting against is a TYPO silently costing Claude money forever: a bad
# model id or a dead key that nobody ever notices because something else quietly
# picks up the work.
#
# A provider that is out of credits is a different animal. The route is correct, the
# credentials are correct, the model id is correct — the account is simply empty, and
# it stays empty for a rolling four weeks (see brain: "A provider 429 mid-build
# destroys the crew's work AND reports success"). Failing every task for a month is
# not fail-fast; it is an outage with extra steps.
#
# So the split this file draws is between:
#
#   TRANSIENT — out of credits, 429/overloaded, cannot reach the endpoint.
#               The route is right and the provider is unavailable. Fall back, LOUDLY.
#
#   CONFIG    — unrecognized model id, rejected credentials.
#               The route is WRONG. Falling back would hide the bug forever, which is
#               exactly what model_route.py's no-fallback rule exists to prevent.
#               These keep failing hard, unchanged.
#
# The fallback is never silent: every caller prints which provider failed, why, and
# what it re-ran on, and records it in the crew's pass rows so it reaches the issue.
# "No silent fallbacks" is the doctrine — this one announces itself every time.

MF_ROOT="${MF_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Matched on the PROVIDER's own error text, so a diff or a review that merely quotes
# one of these phrases cannot trip it — these are the shapes the CLI emits, not prose.
# Consulted ONLY on a non-zero exit, so it can never fail a passing run.
model_failure_reason() {  # <logfile> → reason string, or empty
  local f="$1"
  grep -qiE 'reached your monthly usage limit|add usage credits' "$f" && { echo "provider out of credits (ollama-cloud monthly usage limit)"; return 0; }
  grep -qiE '\[claude-code:unrecognized_model\]|isn.t described by this version.s model catalog' "$f" && { echo "the configured model id was rejected by the CLI as unrecognized"; return 0; }
  grep -qiE '"type"[[:space:]]*:[[:space:]]*"(authentication_error|permission_error)"|invalid[_ ]api[_ ]key|401 Unauthorized|403 Forbidden' "$f" && { echo "provider rejected our credentials"; return 0; }
  grep -qiE '429 Too Many Requests|"type"[[:space:]]*:[[:space:]]*"rate_limit_error"|overloaded_error' "$f" && { echo "provider rate-limited or overloaded the request"; return 0; }
  grep -qiE 'ECONNREFUSED|Connection refused|Could not connect|getaddrinfo|network error|fetch failed' "$f" && { echo "could not connect to the provider endpoint"; return 0; }
  printf ''
}

# Availability failure (fall back) vs configuration failure (keep failing).
# Order matters: the config shapes are checked FIRST, so a log that somehow carries
# both is treated as the config bug it is rather than being routed around.
model_failure_transient() {  # <logfile> → exit 0 when safe to retry elsewhere
  local f="$1"
  grep -qiE '\[claude-code:unrecognized_model\]|isn.t described by this version.s model catalog' "$f" && return 1
  grep -qiE '"type"[[:space:]]*:[[:space:]]*"(authentication_error|permission_error)"|invalid[_ ]api[_ ]key|401 Unauthorized|403 Forbidden' "$f" && return 1
  grep -qiE 'reached your monthly usage limit|add usage credits' "$f" && return 0
  grep -qiE '429 Too Many Requests|"type"[[:space:]]*:[[:space:]]*"rate_limit_error"|overloaded_error' "$f" && return 0
  grep -qiE 'ECONNREFUSED|Connection refused|Could not connect|getaddrinfo|network error|fetch failed' "$f" && return 0
  return 1
}

# `models.fallback` resolves through model_route.py's ordinary FLAT-LANE path — a
# lane named "fallback" whose entry carries provider/model. No resolver change was
# needed for this; if the key is absent the resolver falls to `models.default`, which
# would make "the fallback" mean "the default" and route around a failure with the
# same brain that is usually the expensive one. So absence is detected here, by
# asking the config directly, and an unconfigured fallback disables the behaviour
# entirely rather than guessing.
model_fallback_configured() {  # → exit 0 when models.fallback exists in config
  local cfg="${DOZER_CONFIG:-$MF_ROOT/org/config.yaml}"
  python3 - "$cfg" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit(1)
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    sys.exit(1)
m = (cfg.get("models") or {})
e = m.get("fallback") if isinstance(m, dict) else None
sys.exit(0 if isinstance(e, dict) and "provider" in e else 1)
PY
}

# $1 (optional) = the turn cap the ORIGINAL pass ran under. It is carried across
# deliberately: `models.fallback` is one entry shared by every role, so it cannot
# know that dev.build is capped at 60 turns — and an uncapped build loop on a Claude
# route is precisely the spend GSAI-170 capped in the first place. DOZER_MAX_TURNS
# beats config for every role (tasks/model_route.py), so the cap survives the switch.
model_fallback_block() {  # [max_turns] → eval-able export block, or empty
  model_fallback_configured || { printf ''; return 0; }
  if [[ -n "${1:-}" ]]; then
    DOZER_MAX_TURNS="$1" "$MF_ROOT/dozers/model.sh" env fallback 2>/dev/null || printf ''
  else
    "$MF_ROOT/dozers/model.sh" env fallback 2>/dev/null || printf ''
  fi
}

model_fallback_desc() {  # → "provider/model", or empty
  local block; block="$(model_fallback_block)"
  [[ -n "$block" ]] || { printf ''; return 0; }
  ( eval "$block" >/dev/null 2>&1; printf '%s/%s' "${DOZER_MODEL_PROVIDER:-?}" "${DOZER_MODEL_NAME:-default}" )
}
