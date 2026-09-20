#!/usr/bin/env bash
# tests/linear-kr-gate-test.sh — regression for GSAI-171 (no Key Result, no run).
#
# "Every issue must ladder to a Project/Milestone" was doctrine, and the Directors'
# precheck already computed `leak:no-kr` — but it only REPORTED. An un-laddered issue
# that carried the greenlight still ran, so the ladder was advice and the label pair was
# the whole gate. The engine now REFUSES. The invariants this test pins down:
#
#   1. NEVER CLAIMED — list_ready omits an issue with no `projectMilestone`, whatever
#      its labels, priority or age say. A KR with no target date is still a KR and runs.
#   2. SAID ONCE, ON THE ISSUE — the first skip posts exactly one Linear comment,
#      `Dozer refuses to run this until it is laddered to a Milestone (Key Result).`,
#      carrying the idempotency marker `<!-- dozer-no-kr -->`. A second pass that sees
#      that marker posts nothing — even from a cold cache, because the marker (not the
#      cache) is what guarantees it.
#   3. LOGGED ONCE A DAY — `skip: no-kr <ID>` goes to stderr on the first skip and is
#      deduped by an on-disk set under $DOZER_STATE_DIR, so a 30s poll does not reprint
#      it forever. The set is keyed by date and prunes other days.
#   4. THE WATCHDOG AGREES — count_ready counts what list_ready would dispatch, so an
#      un-laddered queue does not hold the "alive but not dispatching" alarm high forever.
#
# Hermetic: the Linear I/O (`_all_issues`, `_issue_comments`, `comment`) is stubbed.
#
# Run:  bash tests/linear-kr-gate-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"; trap 'rm -rf "$STATE" 2>/dev/null || true' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

# Hermetic against the LIVE config too (GSAI-176): list_ready reads org/config.yaml
# for the weekly focus window, and an active focus would filter these fixtures — which
# would fail this suite on the repo's own config. DOZER_CONFIG=/dev/null = no focus.
out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used LINEAR_TEAMS=T \
      DOZER_CONFIG=/dev/null DOZER_STATE_DIR="$STATE" python3 - <<'PY'
import importlib.util, io, contextlib, json, os
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py")
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)

def iss(ident, kr, *labels):
    """kr: a targetDate string, "" for a Milestone with no date, None for NO Milestone."""
    ms = None if kr is None else {"id": f"m-{ident}", "name": "KR", "targetDate": kr or None}
    return {"identifier": ident, "title": "t", "team": {"key": "T"},
            "state": {"type": "unstarted"}, "priority": 1, "createdAt": "2026-09-01T00:00:00Z",
            "projectMilestone": ms,
            "labels": {"nodes": [{"name": l} for l in labels]}}

R, L = "dozer:ready", "lane:dev"
lin._all_issues = lambda: [
    iss("HAS-KR",     "2026-10-01", R, L),   # laddered + dated  -> runs
    iss("KR-NO-DATE", "",           R, L),   # laddered, undated -> still runs
    iss("NO-KR-1",    None,         R, L),   # urgent, greenlit, un-laddered -> REFUSED
    iss("NO-KR-2",    None,         R, "lane:marketing"),
]

# --- stubbed Linear I/O: a per-issue comment store -----------------------------------
store = {"HAS-KR": [], "KR-NO-DATE": [], "NO-KR-1": [], "NO-KR-2": []}
posts = []
lin._issue_comments = lambda ident: [{"body": b, "createdAt": "2026-09-02T00:00:00Z"}
                                     for b in store.get(ident, [])]
def fake_comment(ident, body):
    posts.append((ident, body)); store.setdefault(ident, []).append(body)
lin.comment = fake_comment

def run():
    o, e = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
        lin.list_ready()
    return [l for l in o.getvalue().splitlines() if l], e.getvalue().splitlines()

lines1, err1 = run()          # first poll: refuses, logs, comments
lines2, err2 = run()          # second poll, warm cache: silent
seen_file = lin._no_kr_seen_path()
os.makedirs(os.path.dirname(seen_file), exist_ok=True)
stale = os.path.join(os.path.dirname(seen_file), "no-kr-seen-1999-01-01")
open(stale, "w").write("OLD-1\n")
# Third poll from a COLD cache: the day's set is wiped, so it logs again — but the
# MARKER is in the store, so it must still not post a second comment.
os.remove(seen_file)
lines3, err3 = run()
stale_pruned = not os.path.exists(stale)

cbuf = io.StringIO()
with contextlib.redirect_stdout(cbuf): lin.count_ready()

print(json.dumps({
    "lines1": [l.split("\t")[0] for l in lines1],
    "lines2": [l.split("\t")[0] for l in lines2],
    "err1": err1, "err2": err2, "err3": err3,
    "posts": posts, "count": cbuf.getvalue().strip(),
    "stale_pruned": stale_pruned,
    "marker": lin.NO_KR_MARKER, "body": lin.NO_KR_BODY,
}))
PY
)" || { echo "  ✗ the python harness itself failed" >&2; echo "$out" >&2; exit 1; }

j() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)" <<<"$out"; }

# ── 1. never claimed ─────────────────────────────────────────────────────────
[[ "$(j '" ".join(d["lines1"])')" == "HAS-KR KR-NO-DATE" ]] \
  && ok "an issue with no Milestone is never listed (a KR with no date still runs)" \
  || bad "list_ready returned: $(j '" ".join(d["lines1"])')"
[[ "$(j '" ".join(d["lines2"])')" == "HAS-KR KR-NO-DATE" ]] \
  && ok "...and stays out on every later poll, not just the first" \
  || bad "second poll returned: $(j '" ".join(d["lines2"])')"

# ── 2. said once, on the issue ───────────────────────────────────────────────
[[ "$(j 'len(d["posts"])')" == "2" ]] \
  && ok "exactly one comment per un-laddered issue (2 issues, 2 posts)" \
  || bad "posted $(j 'len(d["posts"])') comments, want 2: $(j 'd["posts"]')"
[[ "$(j '" ".join(sorted(p[0] for p in d["posts"]))')" == "NO-KR-1 NO-KR-2" ]] \
  && ok "the comment lands on the refused issues only" \
  || bad "comments landed on: $(j '" ".join(p[0] for p in d["posts"])')"
[[ "$(j 'd["body"]')" == "Dozer refuses to run this until it is laddered to a Milestone (Key Result). $(j 'd["marker"]')" ]] \
  && ok "the body is the exact refusal text + the <!-- dozer-no-kr --> marker" \
  || bad "body is: $(j 'd["body"]')"
[[ "$(j 'all(d["marker"] in p[1] for p in d["posts"])')" == "True" ]] \
  && ok "every posted body carries the idempotency marker" \
  || bad "a posted body is missing the marker: $(j 'd["posts"]')"
# The cold-cache pass is the real idempotency proof: nothing but the marker stopped it.
[[ "$(j 'len(d["err3"])')" != "0" && "$(j 'len(d["posts"])')" == "2" ]] \
  && ok "a cold cache re-logs but does NOT re-comment — the marker, not the cache, is the guarantee" \
  || bad "cold-cache pass: err3=$(j 'd["err3"]') posts=$(j 'len(d["posts"])')"

# ── 3. logged once a day ─────────────────────────────────────────────────────
[[ "$(j '" ".join(sorted(d["err1"]))')" == "skip: no-kr NO-KR-1 skip: no-kr NO-KR-2" ]] \
  && ok "the first skip logs \`skip: no-kr <ID>\` once per issue, on stderr" \
  || bad "first-poll stderr was: $(j 'd["err1"]')"
[[ "$(j 'd["err2"]')" == "[]" ]] \
  && ok "the next poll logs nothing — deduped by id, not reprinted every 30s" \
  || bad "second poll still logged: $(j 'd["err2"]')"
[[ "$(j 'd["stale_pruned"]')" == "True" ]] \
  && ok "the seen-set resets daily: another day's file is pruned" \
  || bad "a stale no-kr-seen-* file survived"

# ── 4. the watchdog counts the same thing ────────────────────────────────────
[[ "$(j 'd["count"]')" == "2" ]] \
  && ok "count_ready counts only claimable work (an un-laddered queue cannot alarm forever)" \
  || bad "count_ready=$(j 'd["count"]'), want 2"

# stdout must stay the clean tab-separated contract — the refusal talks on stderr only.
grep -q "no-kr" <<<"$(j '" ".join(d["lines1"])')" \
  && bad "the skip notice leaked into the ready list on stdout" \
  || ok "the refusal never pollutes the stdout row contract"

echo "linear-kr-gate: $pass ✓, $fail ✗"; (( fail == 0 ))
