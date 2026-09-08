#!/usr/bin/env bash
# directors/build-prompt.sh <role> [runtime]  — print a paste-ready system prompt.
#
#   role     = chief | dev-director | mktg-director | ops-director
#   runtime  = buzz | claude   (optional — appends runtimes/<runtime>.md)
#
# One brain, no drift: the role playbook + shared Linear how-to live once; this merges
# them (plus an optional runtime adapter) into ONE self-contained block, fresh from
# source. Buzz agents only get pasted text, so for Buzz:
#
#   directors/build-prompt.sh dev-director buzz | pbcopy   # paste into the Buzz agent
set -euo pipefail
role="${1:?usage: build-prompt.sh <chief|dev-director|mktg-director|ops-director> [buzz|claude]}"
runtime="${2:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

persona="$here/$role.md"
[[ -f "$persona" ]] || { echo "no such role persona: $persona" >&2; exit 1; }

# Validate everything BEFORE emitting anything (fail fast — never print a partial prompt).
rfile=""
if [[ -n "$runtime" ]]; then
  rfile="$here/runtimes/$runtime.md"
  [[ -f "$rfile" ]] || { echo "no such runtime adapter: $rfile (expected buzz|claude)" >&2; exit 1; }
fi
[[ -f "$here/LINEAR.md" ]] || { echo "missing $here/LINEAR.md" >&2; exit 1; }

# Order: house voice → brain (playbook) → runtime adapter → commands.
[[ -f "$here/STYLE.md" ]] && { cat "$here/STYLE.md"; printf '\n\n---\n\n'; }
cat "$persona"; printf '\n\n---\n\n'
[[ -n "$rfile" ]] && { cat "$rfile"; printf '\n\n---\n\n'; }
cat "$here/LINEAR.md"
