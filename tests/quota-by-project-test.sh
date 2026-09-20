#!/usr/bin/env bash
# tests/quota-by-project-test.sh — acceptance suite for scripts/quota-by-project.sh
# (GSAI-175).
#
# Drives the REAL script against a synthetic ~/.claude/projects tree and a synthetic
# Dozer loop log, with a static registry + issue->project map fixture
# (tests/fixtures/quota-by-project-{ecosystem.yaml,map.tsv}).
#
# The transcripts are BUILT HERE rather than checked in, because every assertion about
# the --days window depends on the timestamps being relative to "now" — a static ISO
# date in a fixture would drift out of every window and the suite would go quietly
# green-then-wrong. The registry and the map have no dates, so those stay static.
#
# Cases:
#   A. bucket assignment — a Dozer worktree lands on its Linear project, an
#      orchestrator worktree on its project too, a /<role>-awake pass on
#      "Director: <role>", a Buzz tick on "Director: <role> (buzz)", a plain repo cwd
#      on "interactive: <repo>" with the team the registry gives it, and an
#      unmapped issue on "(no project)".
#   B. pricing arithmetic — one bucket with an exactly-known token mix must come out
#      at the hand-computed dollar figure and token total.
#   C. provider split — ollama models count as REQUESTS, never dollars; claude models
#      count as dollars; <synthetic> counts as neither.
#   D. team rollup — per-team dollars are the sum of that team's buckets.
#   E. loop-log precedence — a bucket with GSAI-173 requests= in the window reports
#      those (src=log) INSTEAD OF its transcript count, never the sum.
#   F. --days window, --json shape, and fail-fast on bad arguments.
#
# Run:  bash tests/quota-by-project-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/quota-by-project.sh"
ECO="$ROOT/tests/fixtures/quota-by-project-ecosystem.yaml"
MAP="$ROOT/tests/fixtures/quota-by-project-map.tsv"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

fail=0
ok() { echo "  ✓ $1"; }
no() { echo "  ✗ $1" >&2; fail=1; }
dump()  { while IFS= read -r l; do echo "      | $l"; done <<<"$1" >&2; }
has()   { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else no "$1 — expected to find: $2"; dump "$3"; fi; }
lacks() { if grep -qF -- "$2" <<<"$3"; then no "$1 — expected NOT to find: $2"; dump "$3"; else ok "$1"; fi; }
hasre() { if grep -qE -- "$2" <<<"$3"; then ok "$1"; else no "$1 — expected to match: $2"; dump "$3"; fi; }
lacksre() { if grep -qE -- "$2" <<<"$3"; then no "$1 — expected NOT to match: $2"; dump "$3"; else ok "$1"; fi; }
fails() { if "$@" >/dev/null 2>&1; then return 1; else return 0; fi; }

[[ -x "$SCRIPT" ]] || { echo "quota-by-project-test: $SCRIPT is not executable" >&2; exit 1; }
[[ -r "$ECO" && -r "$MAP" ]] || { echo "quota-by-project-test: missing fixtures" >&2; exit 1; }

PROJ="$TMP/projects"
mkdir -p "$PROJ"

iso() { # iso <seconds-ago>
  python3 -c "
import sys
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=int(sys.argv[1]))).isoformat().replace('+00:00','Z'))" "$1"
}

RECENT="$(iso 3600)"        # 1h ago — inside every window
ANCIENT="$(iso $((30*86400)))"  # 30d ago — outside the default 7d window

# msg <file> <id> <model> <ts> <input> <output> <cache_read> <cache_create>
msg() {
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
    "$4" "$2" "$3" "$5" "$6" "$7" "$8" >> "$1"
}

# ── the synthetic transcript tree ───────────────────────────────────────────────
# 1. Dozer worktree on a MAPPED issue -> "CFW: Sellable V1".
#    Token mix chosen so the dollar figure is hand-checkable (case B):
#      claude-opus-5 = $5/MTok in, $25/MTok out; cache read 0.1x in, cache write 1.25x in
#      input 1,000,000        -> 1.0 * 5.00            = $5.00
#      output   200,000       -> 0.2 * 25.00           = $5.00
#      cache_read 2,000,000   -> 2.0 * 5.00 * 0.10     = $1.00
#      cache_create 400,000   -> 0.4 * 5.00 * 1.25     = $2.50
#                                              TOTAL   = $13.50
#      tokens = 1,000,000 + 200,000 + 2,000,000 + 400,000 = 3,600,000 = "3.6M"
d="$PROJ/-Users-vasanth--dozers-worktrees-cfw-social-CFW-901"; mkdir -p "$d"
msg "$d/s1.jsonl" m1 claude-opus-5 "$RECENT" 1000000 200000 2000000 400000
# a duplicate message id — the same API response replayed in the transcript. Must be
# counted ONCE, or every resumed session double-bills.
msg "$d/s1.jsonl" m1 claude-opus-5 "$RECENT" 1000000 200000 2000000 400000
# an ollama-routed call in the SAME transcript (org/config.yaml routes dev roles to
# ollama-cloud through ANTHROPIC_BASE_URL) -> a request, never a dollar.
msg "$d/s1.jsonl" m2 "kimi-k3:cloud" "$RECENT" 500000 50000 0 0
# harness-local text, no API call at all -> neither.
msg "$d/s1.jsonl" m3 "<synthetic>" "$RECENT" 999999 999999 0 0
# outside the 7d window -> excluded by default, included at --days 40.
msg "$d/s1.jsonl" m4 claude-opus-5 "$ANCIENT" 4000000 4000000 0 0

# 2. Orchestrator worktree (~/.claude-worktrees) on a mapped issue -> its project too.
d="$PROJ/-Users-vasanth--claude-worktrees-dozers-GSAI-902"; mkdir -p "$d"
msg "$d/s1.jsonl" o1 claude-sonnet-5 "$RECENT" 1000000 100000 0 0   # $2.00 + $1.00 = $3.00

# 3. Dozer worktree on an UNMAPPED issue -> "(no project)", team from the prefix.
d="$PROJ/-Users-vasanth--dozers-worktrees-cfw-social-CFW-999"; mkdir -p "$d"
msg "$d/s1.jsonl" u1 claude-sonnet-5 "$RECENT" 500000 0 0 0          # $1.00

# 4. A launchd Director pass: `claude -p /<role>-awake` out of ~/ecosystem.
d="$PROJ/-Users-vasanth-ecosystem"; mkdir -p "$d"
printf '{"type":"user","message":{"role":"user","content":"<command-name>/dev-director-awake</command-name>"}}\n' > "$d/s1.jsonl"
msg "$d/s1.jsonl" dd1 claude-opus-5 "$RECENT" 200000 20000 0 0       # $1.00 + $0.50 = $1.50
# …and a plain interactive ~/ecosystem session, same dir, no slash command.
msg "$d/s2.jsonl" ec1 claude-opus-5 "$RECENT" 100000 0 0 0           # $0.50

# 5. A Buzz-hosted Director tick out of ~/.buzz (the other Director runtime).
d="$PROJ/-Users-vasanth--buzz"; mkdir -p "$d"
printf '{"type":"user","message":{"role":"user","content":"It'"'"'s your scheduled Chief tick. Do ONE sweep, then stop."}}\n' > "$d/s1.jsonl"
msg "$d/s1.jsonl" bz1 claude-opus-5 "$RECENT" 400000 0 0 0           # $2.00

# 6. A plain interactive repo cwd. The encoded dirname is ambiguous ("…-cfw-cfw-social"
#    could split as cfw/cfw-social or cfw-cfw/social) — the registry must resolve it to
#    cfw-social / team CFW, not to "social" / no team.
d="$PROJ/-Users-vasanth-initiatives-cfw-cfw-social"; mkdir -p "$d"
msg "$d/s1.jsonl" iv1 claude-haiku-4-5 "$RECENT" 1000000 0 0 0       # $1.00

# ── the synthetic loop log ──────────────────────────────────────────────────────
# One GSAI-173 finish line for LL: Growth, inside the window. That bucket has NO
# transcript at all, so it exists only because of the log.
now="$(date +%s)"
LOG="$TMP/loop.out.log"
{
  printf '  ok #LL-903 merged to develop  team=LL milestone="Signups" project="LL: Growth" profile=full ts=%s duration_s=120 requests=77\n' "$((now - 3600))"
  # Ancient line — outside the 7d window, must not be counted.
  printf '  ok #LL-903 merged to develop  team=LL milestone="Signups" project="LL: Growth" profile=full ts=%s duration_s=120 requests=5000\n' "$((now - 30*86400))"
  # A pre-GSAI-173 line with none of the fields — must be ignored, not crash.
  printf '  ok #CFW-901 merged to develop\n'
} > "$LOG"

run() { "$SCRIPT" --projects "$PROJ" --map "$MAP" --ecosystem "$ECO" --log "$LOG" "$@" 2>&1; }

echo "── A/B/C: buckets, pricing, provider split ──"
OUT="$(run --days 7)"
has "dozer worktree -> its Linear project"      "CFW: Sellable V1" "$OUT"
has "orchestrator worktree -> its project"      "GSAI: Housekeeping" "$OUT"
has "unmapped issue -> (no project)"            "(no project)" "$OUT"
has "launchd director pass -> role bucket"      "Director: dev-director" "$OUT"
has "buzz tick -> role bucket, marked buzz"     "Director: chief (buzz)" "$OUT"
has "ambiguous cwd resolves via the registry"   "interactive: cfw-social" "$OUT"
lacks "…and NOT by the last-dash guess"         "interactive: social" "$OUT"
has "pricing: hand-computed dollars"            "\$13.50" "$OUT"
has "pricing: hand-computed token total"        "3.6M" "$OUT"
hasre "the ollama call is 1 request on the project row" 'CFW: Sellable V1.*\|  *1 \|' "$OUT"
lacksre "<synthetic> counted as neither dollars nor requests" 'CFW: Sellable V1.*999' "$OUT"
has "sonnet pricing on the orchestrator row"    "\$3.00" "$OUT"
has "haiku pricing on the interactive row"      "\$1.00" "$OUT"
has "ecosystem session that is not a Director"  "interactive: ecosystem" "$OUT"

echo "── D: team rollup ──"
# CFW = 13.50 (Sellable V1) + 1.00 (no project) + 1.00 (interactive: cfw-social) = 15.50
has "CFW team rollup sums its buckets"          "\$15.50" "$OUT"
has "GSAI team rollup"                          "\$3.00" "$OUT"
has "Directors roll up as unattributed"         "(unattributed)" "$OUT"

echo "── E: loop-log precedence, never summed ──"
has "a log-only bucket appears"                 "LL: Growth" "$OUT"
hasre "log requests= wins and is marked src=log" 'LL: Growth.*\|  *77 \|  *log' "$OUT"
lacks "the ancient log line is outside the window" "5000" "$OUT"

echo "── F: window, json, fail-fast ──"
WIDE="$(run --days 40)"
# the ancient message adds 4M in ($20) + 4M out ($100) to the $13.50 row -> $133.50
has "--days 40 pulls in the ancient message"    "\$133.50" "$WIDE"
lacks "…which the 7d window excluded"           "\$133.50" "$OUT"

J="$(run --days 7 --json)"
if python3 - "$J" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["days"] == 7, d["days"]
assert d["totals"]["claude_usd"] > 0
b = {r["bucket"]: r for r in d["buckets"]}
assert b["CFW: Sellable V1"]["claude_usd"] == 13.50, b["CFW: Sellable V1"]
assert b["CFW: Sellable V1"]["claude_tokens"] == 3_600_000, b["CFW: Sellable V1"]
assert b["CFW: Sellable V1"]["ollama_requests"] == 1, b["CFW: Sellable V1"]
assert b["CFW: Sellable V1"]["team"] == "CFW"
assert b["LL: Growth"]["ollama_requests"] == 77 and b["LL: Growth"]["ollama_source"] == "log"
assert b["Director: chief (buzz)"]["team"] == ""
teams = {t["team"]: t for t in d["teams"]}
assert teams["CFW"]["claude_usd"] == 15.50, teams["CFW"]
assert 0 <= d["top3_claude_usd_share_pct"] <= 100
PY
then ok "--json parses and carries the expected shape"; else no "--json shape"; fi

if fails run --days notanumber; then ok "--days notanumber fails loudly"; else no "--days notanumber should fail"; fi
if fails run --bogus-flag;      then ok "unknown flag fails loudly";      else no "an unknown flag should fail"; fi
if fails "$SCRIPT" --projects "$TMP/nope"; then ok "missing --projects dir fails loudly"; else no "a missing projects dir should fail"; fi

EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
E="$("$SCRIPT" --projects "$EMPTY" --map "$MAP" --ecosystem "$ECO" --log "$TMP/absent.log" --days 7 2>&1)"
has "an empty tree says so instead of crashing" "no model usage found" "$E"

echo
if (( fail )); then echo "quota-by-project-test: FAILED" >&2; exit 1; fi
echo "quota-by-project-test: all green"
