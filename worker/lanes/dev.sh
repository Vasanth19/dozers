#!/usr/bin/env bash
# worker/lanes/dev.sh — the DEV crew.
#
# In your real system this is: create a worktree, run architect → dev → test,
# then serial-merge to a develop branch. Here it's a working skeleton: it does
# the real shape (isolated dir + a produced artifact) so you can watch a task
# flow end-to-end, with the real steps marked TODO where you plug in your tools.
set -euo pipefail
ID="$1"; TITLE="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/.artifacts/dev"; mkdir -p "$OUT"

echo "    [dev] building task #$ID: $TITLE"

# 1. Isolate.        TODO: git worktree add ../wt/$ID  ab/$ID
# 2. Architect pass. TODO: hand spec to your planner/model, write a design note
# 3. Implement.      TODO: hand the design to your coding agent
# 4. Test.           TODO: run the project's test command; fail hard if red
# 5. Merge.          TODO: serial-merge the worktree back to develop

# skeleton artifact so the demo produces something visible:
cat > "$OUT/$ID.md" <<EOF
# DEV result for #$ID
task: $TITLE
built_by: worker/lanes/dev.sh
steps: worktree → architect → dev → test → merge (stubbed)
EOF
echo "    [dev] wrote $OUT/$ID.md"
