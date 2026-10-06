#!/usr/bin/env bash
# tests/linear-write-verify-test.sh — regression: a "quiet" Linear-side rejection of
# the terminal write must surface like any other failure, never like success.
#
# GSAI-213 gap #1: gql() only ever raised on a transport exception or a GraphQL-level
# `errors` array. An HTTP-200 `{"issueUpdate":{"success": false}}` (a transient
# backend rejection, an optimistic-lock conflict) passed straight through —
# set_labels_and_state() discarded the mutation's own `success` field entirely, so
# merged()/review()/block() all reported success to their bash caller while the
# issue's labels never actually changed. This asserts the fix: a false `success`
# must die() exactly like a thrown exception would; a true `success` must still pass
# through cleanly, unaffected.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used python3 - <<'PY'
import importlib.util, io, contextlib, json
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py")
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)

def fake_issue(ident):
    return {"id": "uuid-" + ident, "identifier": ident, "title": "t",
            "team": {"id": "team-uuid", "key": "T"}, "state": {"type": "started"},
            "labels": {"nodes": [{"id": "dozer:in-progress", "name": "dozer:in-progress"},
                                  {"id": "lane:dev", "name": "lane:dev"}]}}
lin.issue = fake_issue
lin.ensure_label = lambda tid, name, color="#000": name
lin.state_id = lambda tid, type_: "state:" + type_

results = {}

def run(name, verb, success):
    calls = {"n": 0}
    def fake_gql(q, v=None):
        calls["n"] += 1
        return {"issueUpdate": {"success": success}}
    lin.gql = fake_gql
    outcome = "returned"
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            verb("X-1")
    except SystemExit:
        outcome = "died"
    results[name] = {"outcome": outcome, "calls": calls["n"]}

run("merged_false",  lin.merged,  False)
run("merged_true",   lin.merged,  True)
run("review_false",  lin.review,  False)
run("review_true",   lin.review,  True)
run("block_false",   lin.block,   False)
run("block_true",    lin.block,   True)

print(json.dumps(results))
PY
)"

j() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)" <<<"$out"; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

for verb in merged review block; do
  [[ "$(j "d['${verb}_false']['outcome']")" == "died" ]] \
    && ok "$verb() raises on issueUpdate success:false (quiet rejection surfaced, not swallowed)" \
    || bad "$verb() returned normally on success:false — the stranding bug is back"
  [[ "$(j "d['${verb}_true']['outcome']")" == "returned" ]] \
    && ok "$verb() passes through cleanly on issueUpdate success:true" \
    || bad "$verb() unexpectedly raised on success:true"
done

echo "linear-write-verify: $pass ✓, $fail ✗"; (( fail == 0 ))
