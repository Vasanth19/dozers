#!/usr/bin/env bash
# tasks/files.sh — the zero-dependency backend.
#
# Tasks are markdown files. Status is the folder they live in, so every state
# change is an atomic `mv`. No account, no API key, no network — runs offline.
# This is the fallback that always works, and the easiest way to demo the system.
#
# Board layout (created on first use):
#   tasks/board/inbox/   untriaged — the Director hasn't specced a lane yet
#   tasks/board/ready/   ready+lane — the Worker may pick these up
#   tasks/board/wip/     claimed — a Worker is running it
#   tasks/board/done/    finished

BOARD="$ROOT/tasks/board"
mkdir -p "$BOARD"/{inbox,ready,wip,done}

# frontmatter helper: read a `key: value` from a task file
_fm() { grep -E "^$2:" "$1" 2>/dev/null | head -1 | sed "s/^$2:[[:space:]]*//"; }

task_list_untriaged() {
  for f in "$BOARD"/inbox/*.md; do
    [[ -e "$f" ]] || continue
    printf '%s\t%s\n' "$(basename "$f" .md)" "$(_fm "$f" title)"
  done
}

task_list_ready() {
  for f in "$BOARD"/ready/*.md; do
    [[ -e "$f" ]] || continue
    printf '%s\t%s\t%s\n' "$(basename "$f" .md)" "$(_fm "$f" lane)" "$(_fm "$f" title)"
  done
}

task_mark_ready() { # <id> <lane>
  local id="$1" lane="$2" src
  src="$(ls "$BOARD"/inbox/"$id".md "$BOARD"/*/"$id".md 2>/dev/null | head -1 || true)"
  [[ -n "$src" ]] || { echo "files: task $id not found" >&2; return 1; }
  # ensure a lane line exists / is updated
  if grep -qE '^lane:' "$src"; then
    sed -i.bak "s/^lane:.*/lane: $lane/" "$src" && rm -f "$src.bak"
  else
    printf 'lane: %s\n' "$lane" >> "$src"
  fi
  mv "$src" "$BOARD/ready/$id.md"
}

task_claim() { # <id> — atomic: mv fails if another Worker already moved it
  local id="$1"
  mv "$BOARD/ready/$id.md" "$BOARD/wip/$id.md" 2>/dev/null || return 1
}

task_done() { # <id>
  local id="$1"
  mv "$BOARD/wip/$id.md" "$BOARD/done/$id.md" 2>/dev/null || true
}

task_comment() { # <id> <text>
  local id="$1"; shift
  local f; f="$(ls "$BOARD"/*/"$id".md 2>/dev/null | head -1 || true)"
  if [[ -n "$f" ]]; then printf '\n> %s\n' "$*" >> "$f"; fi
}
