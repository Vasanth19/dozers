#!/usr/bin/env bash
# tests/linear-release-budget-test.sh — regression for GSAI-184 (the release budget).
#
# Vasanth, 2026-09-24, on finding CFW-273 had been released six times: "this is crazy."
# CFW-273 took six passes in 36 hours; CFW-215 took eight over nine days. Neither failed
# on its spec — both were built on pass 1. Nothing in the engine counted releases, so the
# only brake was a Director's self-restraint, and that brake is on the record failing
# ("third and last release at this scope" → two more followed). The invariants here:
#
#   1. UNDER THE CAP IS UNTOUCHED — the gate is invisible until it binds.
#   2. AT THE CAP IT REFUSES — exit 4 (not 1: "already claimed" reads as a harmless
#      race), and it never reaches the in-progress relabel.
#   3. dozer:ready COMES OFF — block() alone does not remove it, and an issue left ready
#      would be re-polled 30s later into a tight loop. This is the bug that would make
#      the gate worse than no gate.
#   4. board:to_review GOES ON — the teeth. It is the one pile a Director cannot clear
#      itself, and mark_ready() does not strip it.
#   5. ONLY VASANTH RE-GRANTS IT — an unmarked human comment after the ask resets the
#      count. A MARKED comment does not, a board-mirror does not (deliberately: doctrine
#      lets a Director mirror an answer from #now, and honouring that here would hand the
#      reset back to the Directors — the exact hole this closes), and an unmarked comment
#      matching a known AGENT_SIGNATURE does not (GSAI-60).
#   6. IT DOES NOT DUPLICATE ITSELF — re-greenlit past the cap, it re-blocks with one
#      stderr line and posts NO second ask (GSAI-180: an alarm that duplicates stops
#      being read).
#   7. THE EVIDENCE TRAVELS — the ask carries how each pass died, so a bad spec is
#      distinguishable from three infrastructure bounces.
#   8. 0 DISABLES IT — an explicit, greppable off switch.
#   9. IT FAILS OPEN — a budget check that cannot read Linear allows the claim and says
#      so. A gate that cannot decide must never silently stop the factory.
#
# Hermetic: issue/_issue_comments/_relabel/_comment_url are stubbed; the cap comes from
# a throwaway DOZER_CONFIG.
#
# Run:  bash tests/linear-release-budget-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used LINEAR_TEAMS=T TMPDIR_T="$TMP" \
      python3 - <<'PY'
import importlib.util, os, sys, io, contextlib
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py")
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)
TMP = os.environ["TMPDIR_T"]

pas = fai = 0
def ok(m):
    global pas; pas += 1; print(f"  ✓ {m}")
def bad(m):
    global fai; fai += 1; print(f"  ✗ {m}", file=sys.stderr)

def cfg(cap):
    p = os.path.join(TMP, f"cfg-{cap}.yaml")
    with open(p, "w") as fh:
        fh.write(f"backend: linear\nrelease_budget: {cap}\n")
    os.environ["DOZER_CONFIG"] = p
    os.environ.pop("DOZER_RELEASE_BUDGET", None)

T = 0
def c(body, human_ts=None):
    """A comment at a monotonically increasing createdAt."""
    global T; T += 1
    return {"body": body, "createdAt": f"2026-09-23T00:{T:02d}:00Z", "url": "u"}

CLAIM   = "Dozer claimed - lane:dev. Starting now; will post a summary on finish.\n\n<!-- board-note by:dozer-engine -->"
def BLK(r): return f"Dozer blocked in lane:dev - needs a look. Reason: {r}\n\n<!-- board-note by:dozer-engine -->"
VAS     = "go ahead, I re-specced the description"          # unmarked, human
MIRROR  = "Vas said go\n\n<!-- board-mirror src:now -->"    # marked: never an answer
SIGNED  = "Dozer blocked in lane:dev - needs a look. Reason: x"   # unmarked BUT signed

# ── a harness that runs claim() against a stubbed backend ─────────────────────
class Run:
    def __init__(self, comments, labels=("dozer:ready", "lane:dev"), boom=False):
        self.comments = list(comments); self.posted = []; self.relabels = []
        self.labels = list(labels); self.boom = boom
        self.iss = {"id": "uuid", "identifier": "CFW-273", "team": {"id": "t"},
                    "state": {"type": "unstarted"},
                    "labels": {"nodes": [{"name": n} for n in self.labels]}}
    def __enter__(self):
        self._o = (lin.issue, lin._issue_comments, lin._relabel, lin._comment_url)
        lin.issue = lambda i: self.iss
        def _c(i):
            if self.boom: raise RuntimeError("linear unreachable")
            return self.comments
        lin._issue_comments = _c
        def _r(iss, add=(), remove=(), state_type=None):
            self.relabels.append({"add": list(add), "remove": list(remove), "state": state_type})
        lin._relabel = _r
        def _u(i, b):
            self.posted.append(b); return "https://linear.app/c/1"
        lin._comment_url = _u
        return self
    def __exit__(self, *a):
        lin.issue, lin._issue_comments, lin._relabel, lin._comment_url = self._o
    def claim(self):
        """Returns (exit_code_or_None, stderr)."""
        err = io.StringIO(); rc = None
        with contextlib.redirect_stderr(err):
            try: lin.claim("CFW-273")
            except SystemExit as e: rc = e.code
        return rc, err.getvalue()

cfg(3)

# ── 1. under the cap: invisible ───────────────────────────────────────────────
with Run([c(CLAIM), c(BLK("tests failed after 641s"))]) as r:
    rc, _ = r.claim()
    (ok if rc is None else bad)("under the cap the claim proceeds (2 releases, cap 3)")
    (ok if any("dozer:in-progress" in x["add"] for x in r.relabels) else bad)(
        "…and it reaches the in-progress relabel")
    (ok if not r.posted else bad)("…and posts nothing")

# ── 2/3/4. at the cap: refuse, exit 4, ready OFF, board flag ON ───────────────
three = [c(CLAIM), c(BLK("tests failed after 641s")),
         c(CLAIM), c(BLK("stale base: develop advanced")),
         c(CLAIM), c(BLK("review failed TWICE"))]
with Run(three) as r:
    rc, err = r.claim()
    (ok if rc == 4 else bad)(f"at the cap claim() exits 4 (got {rc!r})")
    (ok if not any("dozer:in-progress" in x["add"] for x in r.relabels) else bad)(
        "…and never marks it in-progress")
    rel = r.relabels[0] if r.relabels else {"add": [], "remove": []}
    (ok if "dozer:ready" in rel["remove"] else bad)(
        "…strips dozer:ready (or the refusal re-polls into a tight loop)")
    (ok if "board:to_review" in rel["add"] else bad)("…raises board:to_review")
    (ok if "dozer:blocked" in rel["add"] else bad)("…and dozer:blocked")
    body = r.posted[0] if r.posted else ""
    (ok if "by:dozer-budget" in body and "board-ask" in body else bad)(
        "…posts a board-ask marked by:dozer-budget")
    # 7. the evidence travels
    (ok if "stale base: develop advanced" in body and "review failed TWICE" in body else bad)(
        "…carrying how each pass died (spec vs infrastructure is visible)")
    (ok if "3 time(s)" in body else bad)("…and the count")

# ── 5. only an unmarked human comment re-grants the budget ────────────────────
ask = c("budget exhausted\n\n<!-- board-ask id:x by:dozer-budget -->")
with Run(three + [ask, c(VAS), c(CLAIM)]) as r:
    rc, _ = r.claim()
    (ok if rc is None else bad)("an unmarked comment from Vas re-grants the budget")
with Run(three + [ask, c(MIRROR), c(CLAIM)]) as r:
    rc, _ = r.claim()
    (ok if rc == 4 else bad)("a <!-- board-mirror --> does NOT re-grant it (deliberate)")
with Run(three + [ask, c(SIGNED), c(CLAIM)]) as r:
    rc, _ = r.claim()
    (ok if rc == 4 else bad)("an unmarked but agent-SIGNED comment does NOT re-grant it")

# ── 6. no duplicate asks ──────────────────────────────────────────────────────
with Run(three + [ask]) as r:
    rc, err = r.claim()
    (ok if rc == 4 and not r.posted else bad)("re-greenlit past the cap posts NO second ask")
    (ok if "still unanswered" in err else bad)("…and says why on stderr")

# ── 8. the off switch ─────────────────────────────────────────────────────────
cfg(0)
with Run(three) as r:
    rc, _ = r.claim()
    (ok if rc is None else bad)("release_budget: 0 disables the gate")
cfg(3)

# ── 9. fail open, loudly ──────────────────────────────────────────────────────
with Run(three, boom=True) as r:
    rc, err = r.claim()
    (ok if rc is None else bad)("a check that cannot read Linear allows the claim")
    (ok if "fail-open" in err else bad)("…and names itself on stderr")

# ── the counter itself, in isolation ──────────────────────────────────────────
n, outstanding, reasons = lin.release_state(three)
(ok if n == 3 else bad)(f"release_state counts 3 dispatches (got {n})")
(ok if outstanding is None else bad)("…with no outstanding ask")
(ok if len(reasons) == 3 else bad)(f"…and 3 failure reasons (got {len(reasons)})")
n2, _, _ = lin.release_state(three + [ask, c(VAS), c(CLAIM), c(CLAIM)])
(ok if n2 == 2 else bad)(f"…and counts only the 2 dispatches since Vas answered (got {n2})")

# a garbled cap must not read as "unlimited"
os.environ["DOZER_RELEASE_BUDGET"] = "yes"
err = io.StringIO()
with contextlib.redirect_stderr(err):
    capv = lin.release_budget()
(ok if capv == lin.DEFAULT_RELEASE_BUDGET and "not an integer" in err.getvalue() else bad)(
    "a non-integer cap falls back to the default and says so (never 'unlimited')")

print(f"\nrelease-budget: {pas} passed, {fai} failed")
sys.exit(1 if fai else 0)
PY
)"; rc=$?
echo "$out"
exit $rc
