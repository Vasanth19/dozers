#!/usr/bin/env bash
# directors/build-prompt.sh <role>  — print a paste-ready Buzz system prompt.
#
# Buzz agents only get pasted text (a linked file isn't auto-loaded), so this merges
# the role persona + the shared Linear how-to into ONE self-contained block, always
# fresh from source (no duplicated files to drift).
#
#   directors/build-prompt.sh dev-director | pbcopy   # then paste into the Buzz agent
set -euo pipefail
role="${1:?usage: build-prompt.sh <chief|dev-director|mktg-director>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
persona="$here/$role.md"
[[ -f "$persona" ]] || { echo "no such role persona: $persona" >&2; exit 1; }
cat "$persona"; printf '\n\n---\n\n'; cat "$here/LINEAR.md"
