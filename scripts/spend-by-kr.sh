#!/usr/bin/env bash
# scripts/spend-by-kr.sh — roll the Dozer loop log up by Key Result (GSAI-173).
#
# Every run's claim/finish line in dozer.sh's run_one() (see GSAI-173) now carries
# `team=<KEY> milestone="<name>" project="<name>" profile=<full|lite> ts=<epoch>`, and
# the finish line adds `duration_s=<n> requests=<n-or-empty>`. This script aggregates
# the FINISH lines (`  ok #ID ...` / `  x #ID ...` — one per completed attempt, success
# or fail) over the last N days into a table: how much spend went to each KR (Project's
# Milestone), so a KR silently eating the budget shows up before it becomes a surprise.
#
# No LLM, no network — pure text processing over a local file.
#
# Usage:
#   scripts/spend-by-kr.sh [--days N] [--log PATH]
#     --days N   how many days back to include (default 7)
#     --log PATH which loop log to read (default ~/.dozers/logs/loop.out.log)
#
# Metric column: "requests (or seconds if requests empty)" — a TABLE-WIDE choice, not
# per row, so every row in one table means the same unit. If ANY matched line carries a
# non-empty requests=, the whole table reports requests; only when NONE do (e.g. every
# matched line predates GSAI-173, or came from a lane/path that never wrote the count —
# see dozer.sh's run_log_requests) does it fall back to summed duration_s (suffixed
# `s`) so the table still says something rather than nothing.
#
# Backward compatible with the pre-GSAI-173 log format: a finish line with none of the
# new fields (no `profile=` token) has no team/milestone at all — it still counts as a
# run, contributing zero to the metric (its true cost is simply unknown), and lands in
# the same catch-all row as any post-GSAI-173 line whose milestone is empty (an issue
# with no KR linked). That row is always printed LAST, unsorted — it is not a KR to
# rank, it is the "spend we can't attribute" bucket the Chief should be shrinking.
set -euo pipefail

DAYS=7
LOG="$HOME/.dozers/logs/loop.out.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="${2:?--days needs a value}"; shift 2 ;;
    --days=*) DAYS="${1#*=}"; shift ;;
    --log) LOG="${2:?--log needs a value}"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "spend-by-kr.sh: unknown argument '$1' (see --help)" >&2; exit 1 ;;
  esac
done

[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "spend-by-kr.sh: --days must be a non-negative integer, got '$DAYS'" >&2; exit 1; }
[[ -r "$LOG" ]] || { echo "spend-by-kr.sh: cannot read log '$LOG'" >&2; exit 1; }

CUTOFF=$(( $(date +%s) - DAYS * 86400 ))
UNKNOWN_KEY=$'\x01NO-MILESTONE\x01'   # a byte no real "team · milestone" string can contain

# Pass 1 (awk): parse every finish line, bucket by "team · milestone" (or the unknown
# key), and print ONE tsv row per bucket: key<TAB>runs<TAB>req_sum<TAB>dur_sum<TAB>had_req
# (had_req is 1 if at least one line in the bucket carried a non-empty requests=). A
# trailing summary row `__META__<TAB>any_req_anywhere` decides the table-wide metric.
RAW="$(awk -v cutoff="$CUTOFF" -v unk="$UNKNOWN_KEY" '
  function extract(line, key,   pat, m) {
    pat = key "=\"[^\"]*\""
    if (match(line, pat)) {
      m = substr(line, RSTART, RLENGTH)
      sub("^" key "=\"", "", m); sub("\"$", "", m)
      return m
    }
    pat = key "=[^ ]*"
    if (match(line, pat)) {
      m = substr(line, RSTART, RLENGTH)
      sub("^" key "=", "", m)
      return m
    }
    return "\x02MISSING\x02"
  }
  /^  (ok|x) #/ {
    line = $0
    key = ""; req = ""; dur = ""
    if (index(line, "profile=") == 0) {
      # pre-GSAI-173 line: none of the new fields exist at all.
      key = unk
    } else {
      ts = extract(line, "ts")
      if (ts != "\x02MISSING\x02" && (ts + 0) < cutoff) next   # has a real date; outside the window
      team = extract(line, "team");           if (team == "\x02MISSING\x02") team = ""
      milestone = extract(line, "milestone"); if (milestone == "\x02MISSING\x02") milestone = ""
      dur = extract(line, "duration_s");      if (dur == "\x02MISSING\x02") dur = ""
      req = extract(line, "requests");        if (req == "\x02MISSING\x02") req = ""
      key = (milestone == "") ? unk : (team " · " milestone)
    }
    runs[key]++
    if (req != "") { reqsum[key] += req; had_req[key] = 1; any_req = 1 }
    if (dur != "") { dursum[key] += dur }
  }
  END {
    for (k in runs) {
      printf "%s\t%d\t%s\t%s\n", k, runs[k], (k in reqsum ? reqsum[k] : 0), (k in dursum ? dursum[k] : 0)
    }
    printf "__META__\t%s\n", (any_req ? "requests" : "seconds")
  }
' "$LOG")"

if [[ -z "$RAW" ]]; then
  echo "spend-by-kr.sh: no runs found in the last ${DAYS} day(s) in $LOG"
  exit 0
fi

METRIC_LABEL="$(printf '%s\n' "$RAW" | awk -F'\t' '$1=="__META__"{print $2}')"
DATA="$(printf '%s\n' "$RAW" | awk -F'\t' '$1!="__META__"')"

if [[ -z "$DATA" ]]; then
  echo "spend-by-kr.sh: no runs found in the last ${DAYS} day(s) in $LOG"
  exit 0
fi

# metric per row = requests if METRIC_LABEL is requests, else duration_s.
METRIC_COL=3
[[ "$METRIC_LABEL" == "seconds" ]] && METRIC_COL=4

TOTAL="$(printf '%s\n' "$DATA" | awk -F'\t' -v c="$METRIC_COL" '{t+=$c} END{print t+0}')"

echo "Spend by Key Result — last ${DAYS}d (${LOG})"
printf '%-58s | %6s | %10s | %7s\n' "KR (team · milestone)" "runs" "$METRIC_LABEL" "share %"
printf '%s\n' "-----------------------------------------------------------------------------------"

fmt_row() {  # <key> <runs> <metric>
  local key="$1" runs="$2" metric="$3" share label="$1"
  [[ "$key" == "$UNKNOWN_KEY" ]] && label="(no milestone / unknown)"
  if [[ "$TOTAL" -gt 0 ]]; then
    share="$(awk -v m="$metric" -v t="$TOTAL" 'BEGIN{printf "%.1f", (m/t)*100}')"
  else
    share="0.0"
  fi
  local disp="$metric"
  [[ "$METRIC_LABEL" == "seconds" ]] && disp="${metric}s"
  printf '%-58s | %6s | %10s | %6s%%\n' "$label" "$runs" "$disp" "$share"
}

# Real KRs (excludes the unknown/no-milestone bucket), sorted by share desc — i.e. by
# metric desc, since share is a monotonic function of metric for a fixed total.
printf '%s\n' "$DATA" | awk -F'\t' -v k="$UNKNOWN_KEY" -v c="$METRIC_COL" '$1!=k{printf "%s\t%s\t%s\n",$c,$1,$2}' \
  | sort -t $'\t' -k1,1 -rn \
  | while IFS=$'\t' read -r metric key runs; do
      fmt_row "$key" "$runs" "$metric"
    done

# The catch-all row — always last, never part of the ranking.
printf '%s\n' "$DATA" | awk -F'\t' -v k="$UNKNOWN_KEY" -v c="$METRIC_COL" '$1==k{printf "%s\t%s\t%s\n",$c,$1,$2}' \
  | while IFS=$'\t' read -r metric key runs; do
      fmt_row "$key" "$runs" "$metric"
    done
