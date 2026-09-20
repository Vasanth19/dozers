#!/usr/bin/env bash
# tests/linear-priority-order-test.sh — regression for GSAI-105 (claim order is a plan,
# not a lottery).
#
# 22 issues were greenlit fleet-wide on 2026-09-09 and the Dozer claimed them in
# whatever order the GraphQL query returned — a Director's only "build this first"
# lever was hoarding greenlights, which is exactly what Guzz did to protect the
# urgent dev-failures issue. The invariant this test pins down:
#
#   1. LINEAR BACKEND — list_ready returns ready issues sorted by Linear priority
#      (urgent=1 first … low=4, no-priority LAST), tiebreak oldest createdAt first,
#      with the priority carried in a 4th column so the drain log shows the pick.
#      Priority NEVER trumps the greenlight: a non-ready urgent issue is not listed.
#   2. FILES BACKEND — mirrors the sort via `priority:` frontmatter (1..4, absent
#      last), tiebreak filename (a file task has no createdAt).
#   3. ENGINE — the real dozer.sh, fanout=1, claims the highest-priority task first
#      and logs the pick with its pN tag. drain() itself is unchanged: ordering
#      happens entirely at list time.
#
# Run:  bash tests/linear-priority-order-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

# ── 1. the Linear backend sorts by priority, then age ─────────────────────────
out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used LINEAR_TEAMS=T python3 - <<'PY'
import importlib.util, io, contextlib, json
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py")
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)

def iss(ident, prio, created, *labels):
    # GSAI-171 refuses an issue with no Milestone, so every fixture carries one — and
    # they all carry the SAME targetDate on purpose: GSAI-172 sorts on that date first,
    # so an identical date is what isolates this test on the priority tiebreak it is
    # actually about.
    return {"identifier": ident, "title": "t", "team": {"key": "T"},
            "state": {"type": "unstarted"}, "priority": prio, "createdAt": created,
            "projectMilestone": {"id": "m1", "name": "KR one", "targetDate": "2026-12-01"},
            "labels": {"nodes": [{"name": l} for l in labels]}}

R, L = "dozer:ready", "lane:dev"
# Deliberately shuffled: if the output matches the input order, the sort is a no-op.
lin._all_issues = lambda: [
    iss("NONE-NULL", None, "2026-09-05T09:00:00Z", R, L),
    iss("LOW-NEW",   4,    "2026-09-10T09:00:00Z", R, L),
    iss("HIGH-NEW",  2,    "2026-09-12T09:00:00Z", R, L),
    iss("URGENT-2",  1,    "2026-09-13T09:00:00Z", R, L),
    iss("HIGH-OLD",  2,    "2026-09-01T09:00:00Z", R, "lane:marketing"),
    iss("URGENT-1",  1,    "2026-09-11T09:00:00Z", R, L),
    iss("NONE-1",    0,    "2026-09-01T09:00:00Z", R, "lane:marketing"),
    # urgent and OLD, but never greenlit — priority must never trump the gate:
    iss("TEMPT-1",   1,    "2026-08-01T09:00:00Z", L),
    # greenlit but already claimed — in flight, not ready:
    iss("CLAIMED-1", 1,    "2026-08-02T09:00:00Z", R, "dozer:in-progress", L),
]
buf = io.StringIO()
with contextlib.redirect_stdout(buf): lin.list_ready()
# splitlines, not strip().splitlines(): strip() would eat the trailing tabs — which is
# exactly the empty 4th column this test asserts on.
lines = [l for l in buf.getvalue().splitlines() if l]
buf = io.StringIO()
with contextlib.redirect_stdout(buf): lin.count_ready()
print(json.dumps({"lines": lines, "count": buf.getvalue().strip()}))
PY
)"

j() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)" <<<"$out"; }

[[ "$(j '" ".join(l.split("\t")[0] for l in d["lines"])')" == "URGENT-1 URGENT-2 HIGH-OLD HIGH-NEW LOW-NEW NONE-1 NONE-NULL" ]] \
  && ok "linear: urgent > high > low > no-priority; oldest first inside a priority" \
  || bad "linear: wrong claim order: $(j '" ".join(d["lines"])')"
[[ "$(j '" ".join((l.split("\t")[3] if len(l.split("\t"))>3 else "?") or "-" for l in d["lines"])')" == "1 1 2 2 4 - -" ]] \
  && ok "linear: the 4th column carries the priority (empty when none)" \
  || bad "linear: priority column wrong: $(j 'd["lines"]')"
[[ "$(j 'd["count"]')" == "7" ]] \
  && ok "linear: count_ready still counts exactly what list_ready would dispatch" \
  || bad "linear: count_ready=$(j 'd["count"]'), want 7"
grep -q "TEMPT-1" <<<"$(j '" ".join(d["lines"])')" \
  && bad "linear: an un-greenlit urgent issue jumped the queue" \
  || ok "linear: priority never trumps the greenlight (un-greenlit urgent stays out)"
grep -q "CLAIMED-1" <<<"$(j '" ".join(d["lines"])')" \
  && bad "linear: an in-flight issue re-entered the ready list" \
  || ok "linear: claimed work stays out of the ready list"

# ── 2. the files backend mirrors the sort from `priority:` frontmatter ────────
FAKE_FILES="$(mktemp -d)"; FAKE_ENGINE=""
trap 'rm -rf "$FAKE_FILES" ${FAKE_ENGINE:+"$FAKE_ENGINE"} 2>/dev/null || true' EXIT
BOARD="$FAKE_FILES/tasks/board"
fseed() { # $1 = id, $2 = priority ("" = none)
  mkdir -p "$BOARD/ready"
  { echo "title: $1 the task"; echo "lane: dev"; [[ -n "$2" ]] && echo "priority: $2"; } > "$BOARD/ready/$1.md"
}
fseed "Z-URGENT" 1; fseed "Q-HIGH-LATE-NAME" 2; fseed "B-HIGH-EARLY-NAME" 2
fseed "A-LOW" 4; fseed "C-NONE" ""
# Filename order ≠ priority order on purpose: glob order alone would give
# A-LOW, B-HIGH-EARLY-NAME, C-NONE, Q-HIGH-LATE-NAME, Z-URGENT.
forder="$(cd "$ROOT" && ROOT="$FAKE_FILES" bash -c 'source tasks/files.sh; task_list_ready')"
[[ "$(cut -f1 <<<"$forder" | tr '\n' ' ')" == "Z-URGENT B-HIGH-EARLY-NAME Q-HIGH-LATE-NAME A-LOW C-NONE " ]] \
  && ok "files: priority order beats filename order; same-priority ties break by name" \
  || bad "files: wrong claim order: $(cut -f1 <<<"$forder" | tr '\n' ' ')"
[[ "$(awk -F'\t' '{print ($4 == "" ? "-" : $4)}' <<<"$forder" | tr '\n' ' ')" == "1 2 2 4 - " ]] \
  && ok "files: the 4th column carries the priority (empty when none)" \
  || bad "files: priority column wrong: $(awk -F'\t' '{print ($4 == "" ? "-" : $4)}' <<<"$forder" | tr '\n' ' ')"

# ── 3. the real engine claims in priority order (fanout=1, files backend) ─────
FAKE_ENGINE="$(mktemp -d)/root"
mkdir -p "$FAKE_ENGINE/dozers/nap-lane" "$FAKE_ENGINE/tasks" "$FAKE_ENGINE/org"
cp -R "$ROOT/dozers/." "$FAKE_ENGINE/dozers/"
for f in "$ROOT"/tasks/*; do [[ -f "$f" ]] && cp "$f" "$FAKE_ENGINE/tasks/"; done
cp "$ROOT/org/config.yaml" "$FAKE_ENGINE/org/config.yaml"
cat > "$FAKE_ENGINE/dozers/nap-lane/crew.sh" <<'EOS'
#!/usr/bin/env bash
# the nap lane: sleep for the seconds in the title ("... sleep=N"), then report
ID="$1"; TITLE="$2"; secs="${TITLE##*sleep=}"; secs="${secs%% *}"
sleep "$secs"
mkdir -p "$REPO_ROOT/.artifacts/nap"; printf -- '- slept %ss\n' "$secs" > "$REPO_ROOT/.artifacts/nap/$ID.summary"
EOS
chmod +x "$FAKE_ENGINE/dozers/nap-lane/crew.sh"
EBOARD="$FAKE_ENGINE/tasks/board"
eseed() { # $1 = id, $2 = priority
  mkdir -p "$EBOARD/ready"
  printf 'title: nap sleep=0\nlane: nap\npriority: %s\n' "$2" > "$EBOARD/ready/$1.md"
}
# Glob order (A, M, Z) is the exact REVERSE of claim order (Z=p1 first).
eseed "NAP-A-THIRD" 3; eseed "NAP-M-SECOND" 2; eseed "NAP-Z-FIRST" 1
LOG="$(mktemp)"
env -u DOZER_MODEL_DEV -u MODEL_CMD BACKEND=files ADAPTER_QUIET=1 REAPER_ENABLED=0 \
    FANOUT=1 POLL_SECONDS=1 HEARTBEAT_SECONDS=1 LOCK_DIR="$(mktemp -d)" \
    HEARTBEAT_FILE="$(mktemp)" \
    bash "$FAKE_ENGINE/dozers/dozer.sh" once >"$LOG" 2>&1 \
  || { bad "engine: \`once\` exited non-zero"; sed 's/^/    | /' "$LOG" >&2; }
# fanout=1 makes claims strictly sequential, so the log's pick lines ARE the order.
eorder="$(grep -E '^  -> #' "$LOG" | sed -E 's/^  -> #([^ ]+) .*$/\1/' | tr '\n' ' ')"
[[ "$eorder" == "NAP-Z-FIRST NAP-M-SECOND NAP-A-THIRD " ]] \
  && ok "engine: the highest-priority task is claimed first (not glob order)" \
  || { bad "engine: claim order was: $eorder"; sed 's/^/    | /' "$LOG" >&2; }
grep -qE '^  -> #NAP-Z-FIRST \[nap\] p1 ' "$LOG" \
  && ok "engine: the drain log shows the priority each pick was ordered by" \
  || bad "engine: pick lines carry no priority tag: $(grep -E '^  -> #' "$LOG")"
[[ $(ls "$EBOARD"/done/*.md 2>/dev/null | wc -l | tr -d ' ') == "3" ]] \
  && ok "engine: every task still reaches done/ (ordering changed nothing else)" \
  || bad "engine: done/ has $(ls "$EBOARD"/done/*.md 2>/dev/null | wc -l) of 3 tasks"
rm -f "$LOG"

echo "linear-priority-order: $pass ✓, $fail ✗"; (( fail == 0 ))
