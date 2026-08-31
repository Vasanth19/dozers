#!/usr/bin/env bash
# demo.sh — watch one task flow through the whole system, offline, in 5 seconds.
# Forces the `files` backend so it runs with zero setup.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BACKEND=files
chmod +x "$ROOT"/directors/run.sh "$ROOT"/dozers/dozer.sh "$ROOT"/dozers/*/crew.sh 2>/dev/null || true

BOARD="$ROOT/tasks/board"
rm -rf "$BOARD"; mkdir -p "$BOARD"/{inbox,ready,wip,done}

echo "① Someone files two tasks (they land untriaged)…"
cat > "$BOARD/inbox/101.md" <<'EOF'
title: Add health-check endpoint
EOF
cat > "$BOARD/inbox/102.md" <<'EOF'
title: Write the launch announcement
EOF

echo; echo "② Director triages — decides a lane for each:"
"$ROOT/directors/run.sh" triage
"$ROOT/directors/run.sh" ready 101 dev
"$ROOT/directors/run.sh" ready 102 marketing

echo; echo "③ Dozer drains everything that's ready+lane:"
"$ROOT/dozers/dozer.sh" once

echo; echo "④ What the Dozer produced:"
find "$ROOT/.artifacts" -type f 2>/dev/null | sed 's/^/   /'
echo; echo "   board now:"; ls "$BOARD/done" | sed 's/^/   done\/ /'
echo; echo "Done. Director decided, Dozer did. That's the whole system."
