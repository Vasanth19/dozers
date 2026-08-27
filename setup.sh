#!/usr/bin/env bash
# setup.sh — make the repo runnable. Safe to re-run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "→ making scripts executable"
chmod +x "$ROOT"/setup.sh "$ROOT"/demo.sh \
         "$ROOT"/director/run.sh "$ROOT"/worker/worker.sh \
         "$ROOT"/worker/lanes/*.sh "$ROOT"/tasks/*.sh 2>/dev/null || true

backend="$(grep -E '^\s*backend:' "$ROOT/org/config.yaml" | head -1 | sed 's/.*backend:\s*//; s/#.*//; s/[[:space:]]//g')"
echo "→ backend = $backend"

if [[ "$backend" == "github" ]]; then
  command -v gh >/dev/null || { echo "✗ install GitHub CLI (gh) and run: gh auth login"; exit 1; }
  repo="$(grep -E '^\s*repo:' "$ROOT/org/config.yaml" | head -1 | sed 's/.*repo:\s*//; s/#.*//; s/[[:space:]]//g')"
  if [[ "$repo" == "OWNER/REPO" || -z "$repo" ]]; then
    echo "✗ set 'repo: owner/name' in org/config.yaml first"; exit 1
  fi
  echo "→ creating labels on $repo"
  gh label create ready               --repo "$repo" --color 16a05a --description "Director approved" --force
  gh label create lane:dev            --repo "$repo" --color d98419 --description "Code lane"          --force
  gh label create lane:marketing      --repo "$repo" --color cf5a80 --description "Content lane"       --force
  gh label create status:wip          --repo "$repo" --color 5b57e0 --description "Worker running"     --force
  gh label create status:done         --repo "$repo" --color 6b7688 --description "Worker finished"    --force
  echo "✓ ready. Open an issue, then: director/run.sh triage"
else
  echo "✓ ready (files backend, zero deps). Try: ./demo.sh"
fi
