#!/usr/bin/env bash
# tests/linear-inflight-test.sh — regression: the reaper may only requeue CLAIMED work.
# 2026-09-04 incident: list-inflight treated any `started` issue with a lane: label as a
# stranded Dozer task and requeued director-owned / merged-develop / blocked issues.
# In-flight == state started + dozer:in-progress + a lane, and not at an off-ramp.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used python3 - <<'PY'
import importlib.util, io, contextlib
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py"); lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)
def iss(ident, state, *labels):
    return {"identifier": ident, "title": "t", "state": {"type": state}, "labels": {"nodes": [{"name": l} for l in labels]}}
lin._all_issues = lambda: [
    iss("CLAIMED-1",   "started",   "dozer:in-progress", "lane:dev", "repo:x"),   # the ONE true orphan candidate
    iss("DIRECTOR-1",  "started",   "lane:dev", "repo:x"),                        # orchestrator/director-owned, never claimed
    iss("MERGED-1",    "started",   "dozer:merged-develop", "dozer:blocked", "lane:dev"),
    iss("MERGED-2",    "started",   "dozer:in-progress", "dozer:merged-develop", "lane:dev"),  # lingering label, still finished
    iss("REVIEW-1",    "started",   "dozer:in-progress", "dozer:needs-review", "lane:marketing"),
    iss("BLOCKED-1",   "started",   "dozer:in-progress", "dozer:blocked", "lane:dev"),
    iss("READY-1",     "unstarted", "dozer:ready", "lane:dev"),
    iss("DONE-1",      "completed", "dozer:in-progress", "lane:dev"),
    iss("NOLANE-1",    "started",   "dozer:in-progress"),
]
buf = io.StringIO()
with contextlib.redirect_stdout(buf): lin.list_inflight()
print(buf.getvalue().strip())
PY
)"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { fail=$((fail+1)); echo "  ✗ $1" >&2; }
[[ "$out" == $'CLAIMED-1\tdev\tt' ]] && ok "only the claimed (dozer:in-progress) task is in-flight" || bad "unexpected in-flight set: $(printf '%q' "$out")"
for id in DIRECTOR-1 MERGED-1 MERGED-2 REVIEW-1 BLOCKED-1 READY-1 DONE-1 NOLANE-1; do
  grep -q "^$id" <<<"$out" && bad "$id must NOT be in-flight" || ok "$id excluded"
done
echo "linear-inflight: $pass ✓, $fail ✗"; (( fail == 0 ))
