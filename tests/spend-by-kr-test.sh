#!/usr/bin/env bash
# tests/spend-by-kr-test.sh — acceptance suite for scripts/spend-by-kr.sh (GSAI-173).
#
# Drives the REAL script against a log built from a static, pre-GSAI-173 fixture
# (tests/fixtures/spend-by-kr-loop.log — old claim/finish lines with none of the new
# spend fields, so it never goes stale with the calendar) plus a handful of
# GSAI-173-format lines this test appends with `ts=` computed relative to "now" —
# static epoch seconds in a fixture would eventually fall outside every --days
# window and the test would silently start failing years from now.
#
# Cases:
#   A. mixed old+new format, two real KRs + one ancient (30d) run + old/no-milestone
#      lines all landing in the catch-all row — checks bucketing, share %, sort order,
#      the --days window (ancient excluded at 7d, included at 40d), and that the
#      catch-all row always prints LAST regardless of its share.
#   B. every matched line has requests="" (empty) — checks the table-wide fallback to
#      summed duration_s ("seconds"), since case A already covers the requests path.
#   C. bad --days / unreadable --log both fail loudly (fail-fast, not a silent 0-row
#      table).
#
# Run:  bash tests/spend-by-kr-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/spend-by-kr.sh"
FIXTURE="$ROOT/tests/fixtures/spend-by-kr-loop.log"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
has() { grep -qF "$2" <<<"$1" || { no "$1: expected to find: $2"; echo "$1" | sed 's/^/      | /' >&2; return 1; }; }
lacks() { grep -qF "$2" <<<"$1" && { no "$1: expected NOT to find: $2"; echo "$1" | sed 's/^/      | /' >&2; return 1; }; ok "$1"; }

now="$(date +%s)"
recent1=$(( now - 3600 ))    # 1h ago
recent2=$(( now - 7200 ))    # 2h ago
ancient=$(( now - 30*86400 )) # 30 days ago — outside the default 7-day window

# ── Case A: mixed old+new format ────────────────────────────────────────────────
LOG_A="$TMP/mixed.log"
cp "$FIXTURE" "$LOG_A"
{
  echo "  -> #GSAI-1 [dev] task A  team=GSAI milestone=\"KR: housekeeping\" project=\"GSAI: Spend discipline\" profile=full ts=$recent1"
  echo "  ok #GSAI-1 merged to develop  team=GSAI milestone=\"KR: housekeeping\" project=\"GSAI: Spend discipline\" profile=full ts=$recent1 duration_s=120 requests=3"
  echo "  x #GSAI-2 failed: build error  team=GSAI milestone=\"KR: housekeeping\" project=\"GSAI: Spend discipline\" profile=full ts=$recent2 duration_s=60 requests=2"
  echo "  ok #CFW-1 staged for review  team=CFW milestone=\"KR: ship v2\" project=\"CFW: Social V2\" profile=lite ts=$recent1 duration_s=30 requests=1"
  echo "  ok #GSAI-9 merged to develop  team=GSAI milestone=\"\" project=\"\" profile=full ts=$recent1 duration_s=45 requests=3"
  echo "  ok #BRD-9 merged to develop  team=BRD milestone=\"KR: ancient\" project=\"BRD: Legacy\" profile=full ts=$ancient duration_s=500 requests=5"
} >> "$LOG_A"

out7="$($SCRIPT --days 7 --log "$LOG_A")"; rc=$?
if [[ $rc -eq 0 ]]; then ok "A: exits 0"; else no "A: exit $rc"; fi

has "$out7" "requests"                          && ok "A@7d: metric column is requests (some lines carried it)"
has "$out7" "GSAI · KR: housekeeping"            && ok "A@7d: housekeeping KR row present"
has "$out7" "CFW · KR: ship v2"                  && ok "A@7d: ship v2 KR row present"
has "$out7" "55.6"                               && ok "A@7d: housekeeping share = 5/9 = 55.6%"
has "$out7" "11.1"                               && ok "A@7d: ship v2 share = 1/9 = 11.1%"
has "$out7" "33.3"                               && ok "A@7d: no-milestone/unknown share = 3/9 = 33.3%"
lacks "$out7" "KR: ancient"                       # outside the 7-day window

# sort order: housekeeping (55.6%) ranks above ship v2 (11.1%); the catch-all row
# is last no matter its share (33.3% > 11.1% but it must still trail ship v2).
hk_line=$(grep -n "housekeeping" <<<"$out7" | cut -d: -f1)
sv_line=$(grep -n "ship v2" <<<"$out7" | cut -d: -f1)
unk_line=$(grep -n "no milestone" <<<"$out7" | cut -d: -f1)
if [[ -n "$hk_line" && -n "$sv_line" && -n "$unk_line" && "$hk_line" -lt "$sv_line" && "$sv_line" -lt "$unk_line" ]]; then
  ok "A@7d: sorted by share desc, catch-all row last regardless of its own share"
else
  no "A@7d: expected order housekeeping < ship v2 < catch-all, got lines $hk_line/$sv_line/$unk_line"
fi

out40="$($SCRIPT --days 40 --log "$LOG_A")"
has "$out40" "KR: ancient"                       && ok "A@40d: --days widens the window to include the ancient run"

# ── Case B: every matched line has requests="" (empty) -> fall back to seconds ──
LOG_B="$TMP/seconds-only.log"
{
  echo "  ok #LL-1 staged for review  team=LL milestone=\"KR: only duration\" project=\"LL: Retention\" profile=lite ts=$recent1 duration_s=100 requests="
  echo "  ok #LL-2 staged for review  team=LL milestone=\"KR: only duration\" project=\"LL: Retention\" profile=lite ts=$recent2 duration_s=50 requests="
} > "$LOG_B"
outB="$($SCRIPT --days 7 --log "$LOG_B")"
has "$outB" "seconds"                            && ok "B: metric column falls back to seconds (no line carried requests)"
has "$outB" "150s"                               && ok "B: duration_s summed across the KR's two runs (100+50)"
has "$outB" "100.0"                              && ok "B: sole KR gets 100% share"

# ── Case C: fail-fast on bad input ──────────────────────────────────────────────
if $SCRIPT --days abc --log "$LOG_A" >/dev/null 2>&1; then no "C: --days abc should fail"; else ok "C: --days abc fails loudly"; fi
if $SCRIPT --days 7 --log "$TMP/does-not-exist.log" >/dev/null 2>&1; then no "C: missing --log should fail"; else ok "C: missing --log fails loudly"; fi

# ── existing-format smoke: the script must not choke on the fixture alone ──────
outFixtureOnly="$($SCRIPT --days 3650 --log "$FIXTURE" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "fixture alone: script runs on the pre-GSAI-173 format without crashing"
else no "fixture alone: exit $rc"; fi
has "$outFixtureOnly" "no milestone"             && ok "fixture alone: two old-format runs land under the catch-all row"

echo
if (( fail == 0 )); then echo "spend-by-kr-test: PASS"; else echo "spend-by-kr-test: FAIL" >&2; fi
exit "$fail"
