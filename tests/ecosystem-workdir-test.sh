#!/usr/bin/env bash
# tests/ecosystem-workdir-test.sh — regression test for GSAI-17.
#
# tasks/ecosystem_workdir.py used to search only `projects:`. Infra repos (paperclip,
# openclaw, gbrain-source) live under `infrastructure:` in ecosystem.yaml, so a
# `repo:<infra-id>` label never resolved and no fix in those repos could be greenlit
# (GSAI-43 was stuck on exactly this). This pins the resolver's contract:
#   INFRA     — repo:<id> resolves an infrastructure: entry (id, folder name, repo URL)
#   PROJECT   — projects: entries still resolve, unchanged
#   SHADOW    — on an id collision the projects: entry wins (searched first)
#   NOTDIR    — an infra entry whose `local` is a file (ollama binary) does NOT resolve
#   FLAG      — --flag reads per-repo settings off an infrastructure: entry too
#   TEAM      — --team still walks projects: only (infra entries carry no org)
#   LIVE      — against the REAL registry, repo:paperclip / repo:openclaw resolve
#
# Hermetic: builds a fixture registry in a tempdir and points ECOSYSTEM_REGISTRY at it.
# Run:  bash tests/ecosystem-workdir-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT/tasks/ecosystem_workdir.py"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

mkdir -p "$TMP/proj/app" "$TMP/proj/shadow-project" "$TMP/infra/paperclip" \
         "$TMP/infra/openclaw" "$TMP/infra/gbrain" "$TMP/infra/shadow-infra"
touch "$TMP/infra/ollama-bin"

cat > "$TMP/ecosystem.yaml" <<YAML
orgs:
  acme:
    linear_team: ACME
projects:
  - id: app
    org: acme
    local: $TMP/proj/app/
    repo: https://github.com/acme/app-v2
  - id: shadow
    org: acme
    local: $TMP/proj/shadow-project/
infrastructure:
  - id: paperclip
    local: $TMP/infra/paperclip/
    repo: https://github.com/paperclipai/paperclip
    role: control-plane
  - id: openclaw
    local: $TMP/infra/openclaw/
    repo: https://github.com/openclaw/openclaw
  - id: gbrain-source
    local: $TMP/infra/gbrain/
    no_test_gate: true
  - id: shadow
    local: $TMP/infra/shadow-infra/
  - id: ollama-cloud
    local: $TMP/infra/ollama-bin
YAML

resolve() { ECOSYSTEM_REGISTRY="$TMP/ecosystem.yaml" python3 "$RESOLVER" "$@" 2>/dev/null; }
expect() { # expect <label> <want> -- <resolver args>
  local label="$1" want="$2"; shift 3
  local got; got="$(resolve "$@")"; local rc=$?
  if [[ $rc -eq 0 && "$got" == "$want" ]]; then ok "$label -> $got"
  else no "$label expected '$want' got '$got' (rc=$rc)"; fi
}
expect_miss() { # expect_miss <label> -- <resolver args>
  local label="$1"; shift 2
  local got; got="$(resolve "$@")"; local rc=$?
  if [[ $rc -ne 0 && -z "$got" ]]; then ok "$label misses (rc=$rc)"
  else no "$label should NOT resolve, got '$got' (rc=$rc)"; fi
}

# ── INFRA: id, folder basename, repo-URL basename all hit the infrastructure: entry ──
expect "INFRA repo:paperclip (id)"        "$TMP/infra/paperclip" -- --repo paperclip
expect "INFRA repo:openclaw (id)"         "$TMP/infra/openclaw"  -- --repo openclaw
expect "INFRA repo:gbrain (folder name)"  "$TMP/infra/gbrain"    -- --repo gbrain
expect "INFRA repo:gbrain-source (id)"    "$TMP/infra/gbrain"    -- --repo gbrain-source

# ── PROJECT: the old behaviour is untouched ───────────────────────────────────
expect "PROJECT repo:app (id)"            "$TMP/proj/app"        -- --repo app
expect "PROJECT repo:app-v2 (repo URL)"   "$TMP/proj/app"        -- --repo app-v2

# ── SHADOW: projects: is searched first, so it wins a name collision ──────────
expect "SHADOW repo:shadow -> projects: entry" "$TMP/proj/shadow-project" -- --repo shadow

# ── NOTDIR: an infra `local` that is a file (a binary) is not a workdir ───────
expect_miss "NOTDIR repo:ollama-cloud (local is a file)" -- --repo ollama-cloud
expect_miss "NOTDIR repo:nope (unknown)"                 -- --repo nope

# ── FLAG: --flag reads settings off infra entries too ─────────────────────────
got="$(resolve --flag no_test_gate --path "$TMP/infra/gbrain")"; rc=$?
[[ $rc -eq 0 && "$got" == "true" ]] && ok "FLAG no_test_gate read off infrastructure: entry -> $got" \
                                    || no "FLAG expected 'true' got '$got' (rc=$rc)"
resolve --flag no_test_gate --path "$TMP/infra/paperclip" >/dev/null && no "FLAG unset key should exit non-zero" \
                                                                     || ok "FLAG unset key on infra entry exits non-zero"

# ── TEAM: team resolution ignores infrastructure: (no org there) ──────────────
expect "TEAM --team ACME -> first live project of the org" "$TMP/proj/app" -- --team ACME
expect "TEAM repo miss + team fallback" "$TMP/proj/app" -- --repo nope --team ACME

# ── LIVE: the real registry, the spec's own "done when" ───────────────────────
# Skipped (not failed) only when the registry or the checkout is absent on this box —
# that is an environment gap, not a resolver regression.
REAL="${HOME}/ecosystem/ecosystem.yaml"
if [[ -f "$REAL" ]]; then
  for id in paperclip openclaw; do
    local_path="$(python3 - "$REAL" "$id" <<'PY'
import sys, os, yaml
reg = yaml.safe_load(open(sys.argv[1]))
for p in reg.get("infrastructure") or []:
    if p.get("id") == sys.argv[2]:
        print(os.path.expanduser(str(p.get("local") or "")).rstrip("/")); break
PY
)"
    if [[ -z "$local_path" ]]; then
      no "LIVE $id is not listed under infrastructure: in the real registry"
    elif [[ ! -d "$local_path" ]]; then
      echo "  - LIVE repo:$id skipped — $local_path is not on disk"
    else
      got="$(python3 "$RESOLVER" --repo "$id" 2>/dev/null)"; rc=$?
      [[ $rc -eq 0 && "$got" == "$local_path" ]] && ok "LIVE repo:$id -> $got" \
                                                 || no "LIVE repo:$id expected '$local_path' got '$got' (rc=$rc)"
    fi
  done
else
  echo "  - LIVE skipped — no $REAL on this box"
fi

echo
(( fail == 0 )) && { echo "ecosystem-workdir-test: PASS"; exit 0; }
echo "ecosystem-workdir-test: FAIL" >&2; exit 1
