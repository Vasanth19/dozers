#!/usr/bin/env bash
# dozers/model.sh — the model-routing knob. Which brain does each ROLE run on?
#
#   dozers/model.sh env <role>            # print an eval-able export block for that role
#   dozers/model.sh show                  # table: role -> provider/model  (no secrets)
#   dozers/model.sh smoke <provider> [m]  # run the resolved model once, report pass/fail
#
# Routing lives in org/config.yaml under `models:` (role -> provider + model); an env
# override always wins:  DOZER_MODEL_<ROLE>="<provider>[:<model>]".
# Crews use it as:   eval "$(dozers/model.sh env dev)"   -> sets MODEL_CMD + provider env.
#
# FAIL FAST: a role routed to a provider with no usable credentials/model exits non-zero.
# There is no silent fallback to claude. Secrets are emitted only inside `env` output
# (consumed by eval into the process env) — never by `show`, never into a log.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT/tasks/model_route.py"
CONFIG="${DOZER_CONFIG:-$ROOT/org/config.yaml}"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1; }

case "${1:-}" in
  env)
    [[ $# -ge 2 ]] || usage
    exec python3 "$RESOLVER" "$2" --config "$CONFIG"
    ;;

  show)
    exec python3 "$RESOLVER" default --config "$CONFIG" --show
    ;;

  smoke)
    [[ $# -ge 2 ]] || usage
    provider="$2"; model="${3:-}"
    prompt="Reply with exactly: OK"
    # Resolve an ad-hoc route through the same code path the crews use: an unlisted
    # role falls to models.default, and the env override then pins it to what we asked.
    block="$(DOZER_MODEL_SMOKE="${provider}${model:+:$model}" python3 "$RESOLVER" smoke --config "$CONFIG")" \
      || { echo "smoke: resolver failed for $provider${model:+:$model}" >&2; exit 2; }
    eval "$block"
    echo "smoke: provider=$DOZER_MODEL_PROVIDER model=${DOZER_MODEL_NAME:-<provider default>} cmd=\"$MODEL_CMD\""
    start=$SECONDS
    # </dev/null: headless CLIs wait ~3s for piped stdin otherwise.
    if out="$(eval "$MODEL_CMD \"\$prompt\"" </dev/null 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
    dur=$(( SECONDS - start ))
    printf 'smoke: exit=%s latency=%ss\n' "$rc" "$dur"
    printf 'smoke: output ---\n%s\n--- end\n' "$out"
    if (( rc == 0 )) && [[ -n "${out//[[:space:]]/}" ]]; then
      echo "smoke: PASS ($provider${model:+/$model}, ${dur}s)"
    else
      echo "smoke: FAIL ($provider${model:+/$model}) — exit $rc" >&2
      exit 1
    fi
    ;;

  *) usage ;;
esac
