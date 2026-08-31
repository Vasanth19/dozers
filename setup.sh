#!/usr/bin/env bash
# setup.sh — make the repo runnable. Safe to re-run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "→ making scripts executable"
chmod +x "$ROOT"/setup.sh "$ROOT"/demo.sh \
         "$ROOT"/directors/run.sh "$ROOT"/dozers/dozer.sh \
         "$ROOT"/dozers/lanes/*.sh "$ROOT"/tasks/*.sh 2>/dev/null || true

backend="$(grep -E '^[[:space:]]*backend:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*backend:[[:space:]]*//; s/#.*//; s/[[:space:]]//g; s/"//g; s/'"'"'//g' || true)"
echo "→ backend = $backend"

if [[ "$backend" == "github" ]]; then
  command -v gh >/dev/null || { echo "✗ install GitHub CLI (gh) and run: gh auth login"; exit 1; }
  repo="$(grep -E '^[[:space:]]*repo:' "$ROOT/org/config.yaml" 2>/dev/null | head -1 | sed 's/.*repo:[[:space:]]*//; s/#.*//; s/[[:space:]]//g; s/"//g; s/'"'"'//g' || true)"
  if [[ "$repo" == "OWNER/REPO" || -z "$repo" ]]; then
    echo "✗ set 'repo: owner/name' in org/config.yaml first"; exit 1
  fi
  echo "→ creating labels on $repo"
  gh label create ready               --repo "$repo" --color 16a05a --description "Director approved" --force
  gh label create lane:dev            --repo "$repo" --color d98419 --description "Code lane"          --force
  gh label create lane:marketing      --repo "$repo" --color cf5a80 --description "Content lane"       --force
  gh label create status:wip          --repo "$repo" --color 5b57e0 --description "Dozer running"     --force
  gh label create status:done         --repo "$repo" --color 6b7688 --description "Dozer finished"    --force
  echo "✓ ready. Open an issue, then: directors/run.sh triage"
else
  echo "✓ ready (files backend, zero deps). Try: ./demo.sh"
fi
