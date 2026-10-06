#!/usr/bin/env bash
# tests/linear-finish-repair-test.sh — regression: a finished issue stranded at
# dozer:in-progress (an off-ramp label already landed, but the in-progress label
# never cleared — the MERGED-2 shape tests/linear-inflight-test.sh already asserts
# the reaper must never REQUEUE) must be repairable by stripping ONLY the stale
# in-progress label — never touching the off-ramp label, never touching state, never
# inventing a receipt. GSAI-213.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used LINEAR_TEAMS=T python3 - <<'PY'
import importlib.util, io, contextlib, json
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py")
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)

def iss(ident, *labels):
    return {"identifier": ident, "title": "t", "team": {"key": "T"},
            "state": {"type": "started"},
            "labels": {"nodes": [{"name": l} for l in labels]}}

lin._all_issues = lambda: [
    iss("MERGED-2",  "dozer:in-progress", "dozer:merged-develop", "lane:dev"),   # the stranded shape
    iss("REVIEW-2",  "dozer:in-progress", "dozer:needs-review",   "lane:marketing"),
    iss("BLOCKED-2", "dozer:in-progress", "dozer:blocked",        "lane:dev"),
    iss("CLEAN-1",   "dozer:merged-develop", "lane:dev"),                        # no stale label: no-op
    iss("WIP-1",     "dozer:in-progress", "lane:dev"),                          # genuinely in-flight: not this verb's job
]

# --- list_stale_offramp(): exactly the in-progress + off-ramp shape -----------
buf = io.StringIO()
with contextlib.redirect_stdout(buf): lin.list_stale_offramp()
stale = [l.split("\t")[0] for l in buf.getvalue().strip().splitlines() if l]

# --- finish_repair(): strips ONLY dozer:in-progress, nothing else -------------
writes = {}
def fake_issue(ident):
    LABELS = {
        "MERGED-2":  ["dozer:in-progress", "dozer:merged-develop", "lane:dev"],
        "CLEAN-1":   ["dozer:merged-develop", "lane:dev"],
    }[ident]
    return {"id": "uuid-" + ident, "identifier": ident, "title": "t",
            "team": {"id": "team-uuid", "key": "T"}, "state": {"type": "started"},
            "labels": {"nodes": [{"id": n, "name": n} for n in LABELS]}}
lin.issue = fake_issue
lin.ensure_label = lambda tid, name, color="#000": name
lin.state_id = lambda tid, type_: "state:" + type_
lin.set_labels_and_state = lambda i, ids, sid=None: writes.setdefault(i["identifier"], {}).update(labels=sorted(ids), state=sid)

with contextlib.redirect_stdout(io.StringIO()): lin.finish_repair("MERGED-2")
with contextlib.redirect_stdout(io.StringIO()): lin.finish_repair("CLEAN-1")   # no stale label: must be a no-op

print(json.dumps({"stale": stale, "writes": writes}))
PY
)"

j() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)" <<<"$out"; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

stale="$(j '" ".join(d["stale"])')"
for id in MERGED-2 REVIEW-2 BLOCKED-2; do
  grep -qw "$id" <<<"$stale" && ok "$id (in-progress + off-ramp) is flagged stale" \
    || bad "$id must be flagged stale (stale=$stale)"
done
for id in CLEAN-1 WIP-1; do
  grep -qw "$id" <<<"$stale" && bad "$id must NOT be flagged stale (stale=$stale)" \
    || ok "$id correctly excluded"
done

merged2_labels="$(j "d['writes'].get('MERGED-2', {}).get('labels')")"
[[ "$merged2_labels" != "None" ]] || { bad "finish_repair(MERGED-2) never wrote anything"; merged2_labels="[]"; }
grep -q "dozer:in-progress" <<<"$merged2_labels" \
  && bad "finish_repair left dozer:in-progress on MERGED-2: $merged2_labels" \
  || ok "finish_repair stripped dozer:in-progress from MERGED-2"
grep -q "dozer:merged-develop" <<<"$merged2_labels" \
  && ok "finish_repair left dozer:merged-develop untouched on MERGED-2" \
  || bad "finish_repair touched the off-ramp label on MERGED-2: $merged2_labels"
grep -q "lane:dev" <<<"$merged2_labels" \
  && ok "finish_repair kept the lane label on MERGED-2" || bad "lane label lost on MERGED-2"
[[ "$(j "d['writes'].get('MERGED-2', {}).get('state')")" == "None" ]] \
  && ok "finish_repair never touches state" || bad "finish_repair touched state on MERGED-2"

[[ "$(j "d['writes'].get('CLEAN-1')")" == "None" ]] \
  && ok "finish_repair on an issue with no stale in-progress label is a true no-op" \
  || bad "finish_repair wrote to CLEAN-1, which carried no stale dozer:in-progress"

echo "linear-finish-repair: $pass ✓, $fail ✗"; (( fail == 0 ))
