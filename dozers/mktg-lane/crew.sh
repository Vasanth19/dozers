#!/usr/bin/env bash
# dozers/mktg-lane/crew.sh — the MARKETING lane crew.
#
# The engine hands this an already-claimed task and, via env:
#   WORKDIR        the project checkout to work in (resolved from the repo: hint)
#   DOZER_PERSONA  path to this lane's persona (dozers/mktg-lane/dozer.md)
#   REPO_ROOT      the dozers repo root (for artifacts/summaries)
set -euo pipefail
ID="$1"; TITLE="$2"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORKDIR="${WORKDIR:-.}"; DOZER_PERSONA="${DOZER_PERSONA:-}"
OUT="$REPO_ROOT/.artifacts/mktg"; mkdir -p "$OUT"

# 0. Enter the project and load the agents.
cd "$WORKDIR" 2>/dev/null || true
echo "    [mktg] cwd=$(pwd)"
[[ -n "$DOZER_PERSONA" ]] && echo "    [mktg] persona: $DOZER_PERSONA"
[[ -f AGENTS.md ]] && echo "    [mktg] + project AGENTS.md"
[[ -f CLAUDE.md ]] && echo "    [mktg] + project CLAUDE.md"

echo "    [mktg] working #$ID: $TITLE"
# TODO: hand spec + persona + project agents + skills to your model here.

cat > "$OUT/$ID.md" <<EOF
# MARKETING result for #$ID
task: $TITLE
workdir: $(pwd)
built_by: dozers/mktg-lane/crew.sh
EOF

cat > "$OUT/$ID.summary" <<EOF
- Picked up: $TITLE
- Entered project: $(pwd)
- Loaded brand voice
- Produced draft; staged for approval (NOT published)
- Awaiting human review
EOF
