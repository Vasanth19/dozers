#!/usr/bin/env bash
# tests/linear-kr-order-test.sh — regression for GSAI-172 (the KR's due date drives
# claim order).
#
# GSAI-105 made the greenlit queue a plan instead of a lottery by sorting it on Linear
# priority. But priority is a per-ISSUE knob, and the thing the factory is actually
# racing is a per-KR DEADLINE: under the old key a P1 hung off a Key Result due in 90
# days outranked every issue under a KR due next week, so a Director could only defend
# a near-term commitment by hoarding greenlights — the exact lever GSAI-105 removed,
# grown back one level up. The invariant this test pins down:
#
#   1. SORT KEY — _priority_key orders on (KR targetDate ascending, undated LAST),
#      THEN Linear priority, THEN oldest createdAt. A dated KR always beats an undated
#      one, and an issue with NO milestone at all sorts after both.
#   2. LIST — list_ready emits that order, and carries the KR date in a 5th column so
#      the drain log can show the key the pick was made on.
#   3. ENGINE — dozer.sh reads the 5th column and logs it (`kr-due:<date>`) without
#      disturbing the priority tag it already printed.
#
# Run:  bash tests/linear-kr-order-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

# ── 1 + 2. the sort key and the list it produces ──────────────────────────────
out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used LINEAR_TEAMS=T python3 - <<'PY'
import importlib.util, io, contextlib, json, datetime
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py")
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)

today = datetime.date(2026, 9, 20)
def due(days):
    return (today + datetime.timedelta(days=days)).isoformat()

def iss(ident, prio, created, kr, *labels):
    """kr: a targetDate string, "" for a milestone with no date, or None for NO milestone."""
    ms = None if kr is None else {"id": f"m-{ident}", "name": f"KR {ident}",
                                  "targetDate": (kr or None)}
    return {"identifier": ident, "title": "t", "team": {"key": "T"},
            "state": {"type": "unstarted"}, "priority": prio, "createdAt": created,
            "projectMilestone": ms,
            "labels": {"nodes": [{"name": l} for l in labels]}}

R, L = "dozer:ready", "lane:dev"
# Deliberately shuffled, and deliberately adversarial: the ONLY thing that could put
# NEAR-NOPRIO ahead of FAR-P1 is the KR date, because every other field favours FAR-P1
# (priority 1 vs none, and it is the older issue).
fixtures = [
    iss("FAR-P1",        1,    "2026-01-01T09:00:00Z", due(90),  R, L),   # urgent, far KR
    iss("UNDATED-P1",    1,    "2026-01-02T09:00:00Z", "",       R, L),   # KR with no date
    iss("NEAR-NOPRIO",   None, "2026-09-19T09:00:00Z", due(10),  R, L),   # no priority, near KR
    iss("NEAR-P3",       3,    "2026-09-19T10:00:00Z", due(10),  R, L),   # same KR window
    iss("MID-P4",        4,    "2026-02-01T09:00:00Z", due(30),  R, L),
    iss("NO-KR",         1,    "2026-01-03T09:00:00Z", None,     R, L),   # not laddered at all
]
lin._all_issues = lambda: list(fixtures)

# (1) the raw sort key, independent of any gate that may filter the list later
key_order = [i["identifier"] for i in sorted(fixtures, key=lin._priority_key)]

# (2) what list_ready actually emits
buf = io.StringIO()
with contextlib.redirect_stdout(buf): lin.list_ready()
lines = [l for l in buf.getvalue().splitlines() if l]
print(json.dumps({"key_order": key_order, "lines": lines,
                  "near": due(10), "far": due(90)}))
PY
)"

j() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)" <<<"$out"; }

want="NEAR-P3 NEAR-NOPRIO MID-P4 FAR-P1 UNDATED-P1 NO-KR"
[[ "$(j '" ".join(d["key_order"])')" == "$want" ]] \
  && ok "sort key: nearest KR first; undated KR then no-KR sort LAST" \
  || bad "sort key order was: $(j '" ".join(d["key_order"])') (want: $want)"

# The headline acceptance, stated on its own so a failure names the real rule.
kidx() { python3 -c "import json,sys; print(json.loads(sys.stdin.read())['key_order'].index('$1'))" <<<"$out"; }
(( $(kidx NEAR-NOPRIO) < $(kidx FAR-P1) )) \
  && ok "a no-priority issue under a KR due in 10 days outranks a P1 under a KR due in 90" \
  || bad "FAR-P1 still outranks NEAR-NOPRIO — priority is still beating the deadline"
(( $(kidx NO-KR) > $(kidx FAR-P1) && $(kidx NO-KR) > $(kidx NEAR-NOPRIO) )) \
  && ok "an issue with no milestone sorts after both" \
  || bad "the un-laddered issue did not sort last: $(j '" ".join(d["key_order"])')"
(( $(kidx NEAR-P3) < $(kidx NEAR-NOPRIO) )) \
  && ok "inside one KR window Linear priority still breaks the tie (P3 over no-priority)" \
  || bad "same-KR-window order broke: $(j '" ".join(d["key_order"])')"

# list_ready emits the same order (GSAI-171 may later gate NO-KR out of it; every other
# row is unaffected, so assert on the dated ones only).
listed="$(j '" ".join(l.split(chr(9))[0] for l in d["lines"])')"
[[ "$listed" == "NEAR-P3 NEAR-NOPRIO MID-P4 FAR-P1 UNDATED-P1"* ]] \
  && ok "list_ready emits the KR-date order" \
  || bad "list_ready order was: $listed"
[[ "$(j '" ".join((l.split(chr(9))[4] if len(l.split(chr(9)))>4 else "?") or "-" for l in d["lines"])')" \
   == "$(j 'd["near"]') $(j 'd["near"]') 2026-10-20 $(j 'd["far"]') - -" ]] \
  && ok "the 5th column carries the KR target date (empty when there is none)" \
  || bad "KR column wrong: $(j 'd["lines"]')"

# ── 3. the engine logs the key it picked on ──────────────────────────────────
# The files backend carries no KR, so the 5th column is genuinely absent there — which
# is the case that must NOT regress: an absent field may never shift the priority tag.
FAKE="$(mktemp -d)/root"; trap 'rm -rf "$(dirname "$FAKE")" 2>/dev/null || true' EXIT
mkdir -p "$FAKE/dozers/nap-lane" "$FAKE/tasks" "$FAKE/org"
cp -R "$ROOT/dozers/." "$FAKE/dozers/"
for f in "$ROOT"/tasks/*; do [[ -f "$f" ]] && cp "$f" "$FAKE/tasks/"; done
cp "$ROOT/org/config.yaml" "$FAKE/org/config.yaml"
cat > "$FAKE/dozers/nap-lane/crew.sh" <<'EOS'
#!/usr/bin/env bash
ID="$1"; mkdir -p "$REPO_ROOT/.artifacts/nap"; printf -- '- ok\n' > "$REPO_ROOT/.artifacts/nap/$ID.summary"
EOS
chmod +x "$FAKE/dozers/nap-lane/crew.sh"

# A stub backend that speaks the FIVE-column contract, so the engine's read is exercised
# with a real KR date in play.
cat > "$FAKE/tasks/files.sh" <<'EOS'
#!/usr/bin/env bash
BOARD="$ROOT/tasks/board"; mkdir -p "$BOARD"/{ready,wip,done}
# Stateful on purpose: a claimed row must leave the list, or drain_all re-fills its
# slot from the same two rows forever and `once` never returns.
task_list_ready() {
  [[ -f "$BOARD/wip/KR-NEAR" ]] || printf 'KR-NEAR\tnap\tnear task\t3\t2026-09-30\n'
  [[ -f "$BOARD/wip/KR-NONE" ]] || printf 'KR-NONE\tnap\tundated task\t\t\n'
}
task_list_untriaged() { :; }
task_mark_ready() { :; }
task_claim() { [[ -f "$BOARD/wip/$1" ]] && return 1; : > "$BOARD/wip/$1"; }
task_done() { :; }
task_merged() { :; }
task_review() { :; }
task_block() { :; }
task_comment() { :; }
task_repo() { :; }
task_team() { :; }
task_description() { :; }
task_list_inflight() { :; }
task_requeue() { :; }
EOS
LOG="$(mktemp)"
env -u DOZER_MODEL_DEV -u MODEL_CMD BACKEND=files ADAPTER_QUIET=1 REAPER_ENABLED=0 \
    FANOUT=2 POLL_SECONDS=1 HEARTBEAT_SECONDS=1 LOCK_DIR="$(mktemp -d)" \
    HEARTBEAT_FILE="$(mktemp)" \
    bash "$FAKE/dozers/dozer.sh" once >"$LOG" 2>&1 \
  || { bad "engine: \`once\` exited non-zero"; sed 's/^/    | /' "$LOG" >&2; }
grep -qE '^  -> #KR-NEAR \[nap\] p3 kr-due:2026-09-30 near task$' "$LOG" \
  && ok "engine: the drain log names the KR date the pick was ordered by" \
  || { bad "engine: no kr-due tag on the pick line: $(grep -E '^  -> #' "$LOG")"; }
grep -qE '^  -> #KR-NONE \[nap\] undated task$' "$LOG" \
  && ok "engine: a row with no KR date logs no tag (a 4-column backend is unchanged)" \
  || bad "engine: the undated pick line is wrong: $(grep -E '^  -> #KR-NONE' "$LOG")"
rm -f "$LOG"

echo "linear-kr-order: $pass ✓, $fail ✗"; (( fail == 0 ))
