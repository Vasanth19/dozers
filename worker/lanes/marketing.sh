#!/usr/bin/env bash
# worker/lanes/marketing.sh — the MARKETING crew.
#
# In your real system this is: a persona-stamped content worker that produces the
# asset, then routes it to a human approval gate before anything ships. Here it's
# a working skeleton with the real shape and TODOs where you plug in your tools.
set -euo pipefail
ID="$1"; TITLE="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/.artifacts/marketing"; mkdir -p "$OUT"

echo "    [marketing] producing task #$ID: $TITLE"

# 1. Load persona / brand voice.  TODO: read org/config.yaml brand block
# 2. Produce the asset.           TODO: hand the brief to your content model
# 3. Stage for approval.          TODO: drop into an approval inbox, do NOT auto-publish

cat > "$OUT/$ID.md" <<EOF
# MARKETING draft for #$ID  (awaiting human approval)
brief: $TITLE
made_by: worker/lanes/marketing.sh
status: NEEDS REVIEW — nothing publishes until a human approves
EOF
echo "    [marketing] drafted $OUT/$ID.md — staged for approval"
