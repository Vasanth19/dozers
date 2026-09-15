#!/usr/bin/env bash
# tests/linear-greenlight-test.sh — regression: a greenlit issue MUST be visible to the poll.
#
# GSAI-75 (factory throughput zero). Three independent leaks, all with the same symptom —
# an issue labelled dozer:ready + lane: that the Dozer never dispatches and never explains:
#   1. list_ready skipped any issue not in backlog/unstarted/triage, but claim() sets
#      `started` and merged()/review() leave it there — so re-greenlighting anything that
#      had run once produced a perfectly-labelled, permanently invisible task.
#   2. mark_ready only ADDED labels: no state reset, and the last run's dozer:* label
#      (in-progress / blocked / merged-develop / needs-review) stayed on the issue.
#   3. _fetch_team_issues was an unpaginated `first:200` that never checked hasNextPage —
#      past 200 issues a team's tail vanished from every verb (CFW held 240 on 2026-09-14).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used LINEAR_TEAMS=T python3 - <<'PY'
import importlib.util, io, contextlib, json
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py")
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)

def iss(ident, state, *labels):
    return {"identifier": ident, "title": "t", "team": {"key": "T"},
            "state": {"type": state}, "labels": {"nodes": [{"name": l} for l in labels]}}

# --- 1 + 2: what the poll sees -------------------------------------------------
lin._all_issues = lambda: [
    iss("FRESH-1",    "unstarted", "dozer:ready", "lane:dev"),
    iss("BACKLOG-1",  "backlog",   "dozer:ready", "lane:marketing"),
    iss("REGREEN-1",  "started",   "dozer:ready", "lane:dev"),               # leak 1: ran once, re-greenlit
    iss("REGREEN-2",  "started",   "dozer:ready", "dozer:merged-develop", "lane:dev"),
    iss("REGREEN-3",  "started",   "dozer:ready", "dozer:needs-review", "lane:marketing"),
    iss("UNBLOCK-1",  "started",   "dozer:ready", "dozer:blocked", "lane:dev"),
    iss("CLAIMED-1",  "started",   "dozer:in-progress", "lane:dev"),          # claimed: not ready
    iss("TORN-1",     "started",   "dozer:ready", "dozer:in-progress", "lane:dev"),  # torn claim: don't double-run
    iss("NOLANE-1",   "unstarted", "dozer:ready"),                            # no lane: cannot route
    iss("NOGREEN-1",  "unstarted", "lane:dev"),                               # no greenlight
    iss("CLOSED-1",   "completed", "dozer:ready", "lane:dev"),                # closed never runs
    iss("CANCEL-1",   "canceled",  "dozer:ready", "lane:dev"),
]
buf = io.StringIO()
with contextlib.redirect_stdout(buf): lin.list_ready()
ready = [l.split("\t")[0] for l in buf.getvalue().strip().splitlines() if l]
buf = io.StringIO()
with contextlib.redirect_stdout(buf): lin.count_ready()
count = buf.getvalue().strip()

# --- 2: mark_ready is a reset --------------------------------------------------
# Capture what mark_ready would write, without touching the network.
writes = {}
def fake_issue(ident):
    return {"id": "uuid-" + ident, "identifier": ident, "title": "t",
            "team": {"id": "team-uuid", "key": "T"},
            "state": {"type": STATE},
            "labels": {"nodes": [{"id": n, "name": n} for n in LABELS]}}
lin.issue = fake_issue
lin.ensure_label = lambda tid, name, color="#000": name          # label id == its name
lin.state_id = lambda tid, type_: "state:" + type_
lin.set_labels_and_state = lambda i, ids, sid=None: writes.update(labels=sorted(ids), state=sid)

cases = {}
for name, STATE, LABELS in [
    ("merged",      "started",   ["dozer:merged-develop", "lane:dev", "repo:x"]),
    ("blocked",     "unstarted", ["dozer:blocked", "lane:dev"]),
    ("inprogress",  "started",   ["dozer:in-progress", "lane:dev"]),
    ("needsreview", "started",   ["dozer:needs-review", "lane:marketing"]),
    ("closed",      "completed", ["lane:dev"]),
    ("backlog",     "backlog",   []),
]:
    writes.clear()
    with contextlib.redirect_stdout(io.StringIO()): lin.mark_ready("X-1", "dev")
    cases[name] = dict(writes)

# --- 3: pagination -------------------------------------------------------------
pages = [
    {"pageInfo": {"hasNextPage": True,  "endCursor": "c1"}, "nodes": [iss(f"P{i}", "unstarted") for i in range(250)]},
    {"pageInfo": {"hasNextPage": True,  "endCursor": "c2"}, "nodes": [iss(f"Q{i}", "unstarted") for i in range(250)]},
    {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [iss(f"R{i}", "unstarted") for i in range(11)]},
]
seen_cursors = []
def fake_gql(q, v=None):
    seen_cursors.append((v or {}).get("c"))
    return {"issues": pages[len(seen_cursors) - 1]}
lin.gql = fake_gql
fetched = lin._fetch_team_issues("team-uuid")

# --- teams() must not silently drop an unknown key -----------------------------
lin.TEAM_KEYS = ["CFW", "DEL"]
lin.gql = lambda q, v=None: {"teams": {"nodes": [{"id": "u", "key": "CFW"}]}}
err = io.StringIO()
try:
    with contextlib.redirect_stderr(err): lin.teams()
    teams_result = "returned"
except SystemExit:
    teams_result = "died"
teams_err = err.getvalue().strip()

print(json.dumps({"ready": ready, "count": count, "cases": cases,
                  "fetched": len(fetched), "cursors": seen_cursors,
                  "teams_result": teams_result, "teams_err": teams_err}))
PY
)"

j() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)" <<<"$out"; }

# --- 1: the poll is label-first, not state-first ------------------------------
ready="$(j '" ".join(d["ready"])')"
for id in FRESH-1 BACKLOG-1 REGREEN-1 REGREEN-2 REGREEN-3 UNBLOCK-1; do
  grep -qw "$id" <<<"$ready" && ok "$id is visible to the poll" \
    || bad "$id is greenlit but INVISIBLE to the poll (ready=$ready)"
done
for id in CLAIMED-1 TORN-1 NOLANE-1 NOGREEN-1 CLOSED-1 CANCEL-1; do
  grep -qw "$id" <<<"$ready" && bad "$id must NOT be dispatched (ready=$ready)" \
    || ok "$id correctly excluded"
done
[[ "$(j 'd["count"]')" == "6" ]] \
  && ok "count_ready agrees with list_ready (the watchdog counts what the poll dispatches)" \
  || bad "count_ready=$(j 'd["count"]') but list_ready has $(j 'len(d["ready"])')"

# --- 2: the greenlight resets -------------------------------------------------
for c in merged blocked inprogress needsreview; do
  stale="$(j "[l for l in d['cases']['$c']['labels'] if l.startswith('dozer:') and l != 'dozer:ready']")"
  [[ "$stale" == "[]" ]] && ok "greenlight over '$c' clears the stale dozer:* label" \
    || bad "greenlight over '$c' left $stale on the issue"
  grep -q "dozer:ready" <<<"$(j "d['cases']['$c']['labels']")" \
    && ok "greenlight over '$c' sets dozer:ready" || bad "greenlight over '$c' lost dozer:ready"
done
[[ "$(j "d['cases']['merged']['state']")" == "state:unstarted" ]] \
  && ok "greenlight over a started issue resets it to a pollable state" \
  || bad "started issue not reset: $(j "d['cases']['merged']['state']")"
[[ "$(j "d['cases']['closed']['state']")" == "state:unstarted" ]] \
  && ok "greenlight reopens a closed issue" || bad "closed issue not reopened"
[[ "$(j "d['cases']['backlog']['state']")" == "None" ]] \
  && ok "greenlight leaves an already-pollable Backlog issue where the Director put it" \
  || bad "backlog issue was yanked out of Backlog: $(j "d['cases']['backlog']['state']")"
grep -q "lane:dev" <<<"$(j "d['cases']['merged']['labels']")" \
  && ok "greenlight keeps the lane label" || bad "lane label lost"
grep -q "repo:x" <<<"$(j "d['cases']['merged']['labels']")" \
  && ok "greenlight keeps routing labels (repo:)" || bad "repo: routing label lost"

# --- 3: pagination drains the cursor ------------------------------------------
[[ "$(j 'd["fetched"]')" == "511" ]] \
  && ok "_fetch_team_issues drains every page (511 issues over 3 pages)" \
  || bad "_fetch_team_issues returned $(j 'd["fetched"]') of 511 — the tail is invisible"
[[ "$(j 'd["cursors"]')" == "[None, 'c1', 'c2']" ]] \
  && ok "each page is requested with the previous endCursor" \
  || bad "bad cursor sequence: $(j 'd["cursors"]')"

# --- teams(): an unknown key fails loudly -------------------------------------
[[ "$(j 'd["teams_result"]')" == "died" ]] \
  && ok "an unresolvable team key aborts instead of silently shrinking the factory" \
  || bad "teams() returned a partial team list for an unknown key — that team is invisible"
grep -q "DEL" <<<"$(j 'd["teams_err"]')" \
  && ok "the error names the offending key" || bad "error does not name the bad key: $(j 'd["teams_err"]')"

echo "linear-greenlight: $pass ✓, $fail ✗"; (( fail == 0 ))
