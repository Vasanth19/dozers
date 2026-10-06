#!/usr/bin/env bash
# tests/linear-budget-ask-test.sh — regression for GSAI-252 (the release cap must always
# raise a board-ask).
#
# CFW-345 reached the release cap (3/3) on a BLOCK, not a claim: the third dispatch failed,
# dozer:blocked went on, and no ask was ever posted. The cap was enforced only at claim
# time, so a block at the cap was silent and the issue sat unanswerable. The invariants:
#
#   1. A BLOCK AT THE CAP RAISES THE ASK — block() posts the budget board-ask and sets
#      dozer:blocked + board:to_review together. This is the CFW-345 shape.
#   2. THE ASK CARRIES THE BLOCK THAT CAUSED IT — the crew posts its reason before it
#      blocks, so the third failure's reason is on Vasanth's board.
#   3. ASK FIRST, LABELS SECOND — a failed ask writes no labels; a failed label write
#      leaves the ask standing, and the next claim sets the labels WITHOUT a second ask.
#   4. A LOUD FAILURE — commentCreate success:false dies with a message (never an empty URL
#      treated as success); block() exits non-zero rather than blocking an issue with no ask.
#   5. THE SWEEP HEALS THE STATE — budget-sweep asks for any blocked issue at the cap with
#      no outstanding ask, re-adds a stripped board:to_review, and is idempotent.
#   6. THE SWEEP RESPECTS THE HUMAN — an unmarked answer resets the count, so it is skipped.
#   7. THE SWEEP IS QUIET WHEN IT SHOULD BE — under the cap, Done/Canceled, cap 0, a
#      dry-run, a lock held by another writer, and inside its throttle window.
#   8. THE GAP IS VISIBLE — release-count prints ask=MISSING at the cap with no ask, and
#      board=yes|no says whether the label landed.
#
# Hermetic: the Linear layer is replaced by an in-memory World. Only commentCreate reaches
# the stubbed gql(); every read and label write goes through the stubbed helpers.
#
# Run:  bash tests/linear-budget-ask-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used LINEAR_TEAMS=T \
      DOZER_STATE_DIR="$TMP" DOZER_RELEASE_BUDGET=3 BUDGET_SWEEP_EVERY=0 \
      TMPDIR_T="$TMP" python3 - <<'PY'
import importlib.util, os, sys, io, contextlib, time
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py")
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)
TMP = os.environ["TMPDIR_T"]

pas = fai = 0
def check(name, fn):
    global pas, fai
    try:
        fn()
        pas += 1; print(f"  ✓ {name}")
    except Exception as e:
        fai += 1; print(f"  ✗ {name}  [{type(e).__name__}: {e}]", file=sys.stderr)

def expect(cond, msg):
    if not cond: raise AssertionError(msg)

# ── the in-memory Linear ──────────────────────────────────────────────────────
class World:
    def __init__(self):
        self.iss = {}; self.posts = []; self.relabels = []; self.t = 0
        self.fail_asks = False     # commentCreate returns success:false for a board-ask
        self.fail_relabel = False  # issueUpdate fails (raises like gql() does)
    def add(self, ident, labels, comments=(), state="unstarted"):
        self.iss[ident] = {"labels": list(labels), "state": state, "comments": []}
        for body in comments: self.say(ident, body)
    def ts(self):
        self.t += 1; return f"2026-10-02T{self.t // 60:02d}:{self.t % 60:02d}:00Z"
    def say(self, ident, body):
        c = {"body": body, "createdAt": self.ts(), "url": "u"}
        self.iss[ident]["comments"].append(c); return c
    def node(self, ident):
        d = self.iss[ident]
        return {"id": "uuid-" + ident, "identifier": ident, "team": {"id": "t"},
                "state": {"type": d["state"]},
                "labels": {"nodes": [{"id": "l-" + n, "name": n} for n in d["labels"]]}}
    def names(self, ident):
        return set(self.iss[ident]["labels"])
    def asks(self, ident):
        return sum(1 for c in self.iss[ident]["comments"] if lin.BUDGET_ASK_RE.search(c["body"]))

W = World()

def _issue(ident): return W.node(ident)
def _comments(ident):
    return sorted(W.iss[ident]["comments"], key=lambda c: c["createdAt"])
def _all():
    return [W.node(i) for i in W.iss]
def _relabel(iss, add=(), remove=(), state_type=None):
    ident = iss["identifier"]; d = W.iss[ident]
    if W.fail_relabel: raise SystemExit(1)   # gql() dies via sys.exit on a failed write
    d["labels"] = [n for n in d["labels"] if n not in set(remove)]
    for n in add:
        if n not in d["labels"]: d["labels"].append(n)
    if state_type: d["state"] = state_type
    W.relabels.append((ident, list(add), list(remove), state_type))
def _gql(query, variables=None):
    if "commentCreate" not in query: raise RuntimeError("unexpected gql in this test")
    ident = variables["id"][len("uuid-"):]; body = variables["b"]
    if W.fail_asks and lin.BUDGET_ASK_RE.search(body):
        return {"commentCreate": {"success": False}}
    c = W.say(ident, body)
    W.posts.append((ident, body))
    return {"commentCreate": {"success": True, "comment": {"url": f"https://linear.app/c/{c['createdAt']}"}}}

lin.issue = _issue
lin._issue_comments = _comments
lin._all_issues = _all
lin._relabel = _relabel
lin.gql = _gql

CLAIM = "Dozer claimed - lane:dev. Starting now; will post a summary on finish.\n\n<!-- board-note by:dozer-engine -->"
def BLK(r): return f"Dozer blocked in lane:dev - needs a look.\nReason: {r}\n\n<!-- board-note by:dozer-engine -->"
ASK = "budget exhausted\n\n<!-- board-ask id:2026-10-01T00:00:00Z by:dozer-budget -->"
VAS = "go ahead, I re-specced the description"
# two failed dispatches already on the record; the third claim is the one in flight
TWO = [CLAIM, BLK("tests failed after 641s"), CLAIM, BLK("stale base: develop advanced"), CLAIM]
# the crew's failure path, in the order dozer.sh runs it: reason comment, THEN block
def crew_fail(ident, reason):
    lin.comment(ident, f"Dozer blocked in lane:dev - needs a look.\nReason: {reason}")
    lin.block(ident)
def lock_path(ident):
    return os.path.join(TMP, "budget-locks", f"{ident}.lock")
def reset():
    global W
    W = World(); W.iss.clear()
    lin.BUDGET_LOCK_WAIT_S = 0
    os.environ["DOZER_RELEASE_BUDGET"] = "3"
    os.environ["BUDGET_SWEEP_EVERY"] = "0"
    import shutil; shutil.rmtree(os.path.join(TMP, "budget-locks"), ignore_errors=True)
    try: os.remove(os.path.join(TMP, "budget-sweep.stamp"))
    except OSError: pass
def capture(fn):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        fn()
    return out.getvalue(), err.getvalue()

# ── 1/2. the CFW-345 shape: a block at the cap raises the ask ─────────────────
def t_block_at_cap_asks():
    reset(); W.add("CFW-345", ["dozer:in-progress", "lane:dev"], TWO, state="started")
    crew_fail("CFW-345", "review failed TWICE")
    expect(W.asks("CFW-345") == 1, f"expected one budget ask, got {W.asks('CFW-345')}")
    expect({"dozer:blocked", "board:to_review"} <= W.names("CFW-345"),
           f"labels {sorted(W.names('CFW-345'))}")
    expect("dozer:in-progress" not in W.names("CFW-345"), "still in-progress")
    last = [r for r in W.relabels if "dozer:blocked" in r[1]]
    expect(len(last) == 1 and "board:to_review" in last[0][1],
           "dozer:blocked and board:to_review were not set in one relabel")
check("a block at the cap raises the budget ask (CFW-345 shape)", t_block_at_cap_asks)

def t_ask_carries_block_reason():
    reset(); W.add("CFW-345", ["dozer:in-progress", "lane:dev"], TWO, state="started")
    crew_fail("CFW-345", "review failed TWICE")
    body = [b for i, b in W.posts if lin.BUDGET_ASK_RE.search(b)][0]
    expect("review failed TWICE" in body and "tests failed after 641s" in body,
           "ask body is missing the block reasons")
    expect("3 time(s)" in body, "ask body is missing the count")
check("the ask carries the reason of the block that reached the cap", t_ask_carries_block_reason)

def t_under_cap_block_unchanged():
    reset(); W.add("CFW-11", ["dozer:in-progress", "lane:dev"], [CLAIM], state="started")
    crew_fail("CFW-11", "tests failed")
    expect(W.asks("CFW-11") == 0, "a block under the cap must not ask")
    expect(W.names("CFW-11") == {"dozer:blocked", "lane:dev"}, f"labels {sorted(W.names('CFW-11'))}")
    expect(W.iss["CFW-11"]["state"] == "unstarted", "block must reset state to unstarted")
check("a block under the cap is unchanged (no ask, plain block)", t_under_cap_block_unchanged)

# ── 3. ask first, labels second ──────────────────────────────────────────────
def t_failed_ask_writes_no_labels():
    reset(); W.add("CFW-345", ["dozer:in-progress", "lane:dev"], TWO, state="started")
    W.fail_asks = True
    try:
        crew_fail("CFW-345", "review failed TWICE")
        raise AssertionError("block() must exit non-zero when the ask cannot be posted")
    except SystemExit as e:
        expect(e.code not in (0, None), "exit code must be non-zero")
    expect(not [r for r in W.relabels if "dozer:blocked" in r[1]],
           "no label may be written when the ask failed")
    expect("dozer:in-progress" in W.names("CFW-345"), "issue must stay in-progress for the reaper")
check("a failed ask exits non-zero and writes no labels", t_failed_ask_writes_no_labels)

def t_failed_label_then_claim_no_second_ask():
    reset(); W.add("CFW-345", ["dozer:in-progress", "lane:dev"], TWO, state="started")
    W.fail_relabel = True
    try:
        crew_fail("CFW-345", "review failed TWICE")
        raise AssertionError("block() must exit non-zero when the label write fails")
    except SystemExit:
        pass
    expect(W.asks("CFW-345") == 1, "the ask must have landed before the label write")
    # the reaper requeues the orphaned in-progress issue (ready, unstarted)...
    W.fail_relabel = False
    W.iss["CFW-345"]["labels"] = ["dozer:ready", "lane:dev"]; W.iss["CFW-345"]["state"] = "unstarted"
    # ...and the next claim is refused by the gate, which finds the ask standing
    try:
        lin.claim("CFW-345"); raise AssertionError("claim should be refused at the cap")
    except SystemExit as e:
        expect(e.code == 4, f"expected exit 4, got {e.code!r}")
    expect(W.asks("CFW-345") == 1, f"a second ask was posted ({W.asks('CFW-345')} total)")
    expect({"dozer:blocked", "board:to_review"} <= W.names("CFW-345"),
           f"claim did not set the labels: {sorted(W.names('CFW-345'))}")
check("a failed label write leaves one ask; the next claim sets labels, no second ask",
      t_failed_label_then_claim_no_second_ask)

# ── 4. loud failure ──────────────────────────────────────────────────────────
def t_comment_url_success_false_dies():
    reset(); W.add("CFW-9", ["lane:dev"], [])
    W.fail_asks = True
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            lin._comment_url("CFW-9", "budget\n<!-- board-ask id:x by:dozer-budget -->")
        raise AssertionError("success:false must not read as an empty URL")
    except SystemExit:
        pass
    expect("success=false" in err.getvalue(), f"stderr: {err.getvalue()!r}")
check("_comment_url dies on commentCreate success:false", t_comment_url_success_false_dies)

def t_block_busy_lock_refuses():
    reset(); W.add("CFW-345", ["dozer:in-progress", "lane:dev"], TWO, state="started")
    os.makedirs(lock_path("CFW-345"))
    try:
        crew_fail("CFW-345", "review failed TWICE")
        raise AssertionError("block must not proceed while another writer holds the lock")
    except SystemExit:
        pass
    expect(W.asks("CFW-345") == 0 and not W.relabels, "nothing may be written under a held lock")
check("block() refuses (non-zero) while another writer holds the issue's lock", t_block_busy_lock_refuses)

# ── 5. the sweep heals the state ─────────────────────────────────────────────
def t_sweep_asks_and_is_idempotent():
    reset(); W.add("LL-20", ["dozer:blocked", "lane:dev"], TWO)
    lin.budget_sweep(force=True)
    expect(W.asks("LL-20") == 1, f"sweep should ask once, asks={W.asks('LL-20')}")
    expect({"dozer:blocked", "board:to_review"} <= W.names("LL-20"), "labels not set")
    n_relabels = len(W.relabels)
    lin.budget_sweep(force=True)
    expect(W.asks("LL-20") == 1, f"second sweep posted again ({W.asks('LL-20')} asks)")
    expect(len(W.relabels) == n_relabels, "second sweep wrote labels again")
check("budget-sweep asks once for an exhausted blocked issue, and is idempotent",
      t_sweep_asks_and_is_idempotent)

def t_sweep_restores_stripped_label():
    reset(); W.add("GSAI-72", ["dozer:blocked", "lane:dev", "board:responded"], TWO + [ASK])
    before = len(W.posts)
    lin.budget_sweep(force=True)
    expect(len(W.posts) == before, "a stripped label must not post a second ask")
    expect("board:to_review" in W.names("GSAI-72") and "board:responded" not in W.names("GSAI-72"),
           f"labels {sorted(W.names('GSAI-72'))}")
check("a stripped board:to_review is re-added with no new comment", t_sweep_restores_stripped_label)

# ── 6/7. the sweep leaves alone what it should ───────────────────────────────
def t_sweep_skips():
    reset()
    W.add("BRD-94", ["dozer:blocked", "lane:dev"], [CLAIM, BLK("x"), CLAIM, BLK("y")])   # under cap
    W.add("CFW-1", ["dozer:blocked", "lane:dev"], TWO, state="completed")                  # done
    W.add("CFW-2", ["dozer:in-progress", "lane:dev"], TWO, state="started")              # not blocked
    W.add("CFW-3", ["dozer:blocked", "lane:dev"], TWO + [ASK, VAS])                      # human re-grant
    before_posts, before_rel = len(W.posts), len(W.relabels)
    out, err = capture(lambda: lin.budget_sweep(force=True))
    expect(len(W.posts) == before_posts and len(W.relabels) == before_rel,
           f"sweep wrote where it should not have: posts={W.posts[before_posts:]} rel={W.relabels[before_rel:]}")
check("skips under-cap, Done, not-blocked, and human-re-granted issues", t_sweep_skips)

def t_sweep_cap_zero_disabled():
    reset(); W.add("CFW-4", ["dozer:blocked", "lane:dev"], TWO)
    os.environ["DOZER_RELEASE_BUDGET"] = "0"
    try:
        _, err = capture(lambda: lin.budget_sweep(force=True))
    finally:
        os.environ["DOZER_RELEASE_BUDGET"] = "3"
    expect(not W.posts and not W.relabels, "cap 0 must write nothing")
    expect("disabled" in err, "cap 0 must say so on stderr")
check("release_budget: 0 makes the sweep a no-op that says so", t_sweep_cap_zero_disabled)

def t_sweep_dry_run_changes_nothing():
    reset(); W.add("CFW-6", ["dozer:blocked", "lane:dev"], TWO)
    W.add("CFW-7", ["dozer:blocked", "lane:dev"], [CLAIM])
    out, _ = capture(lambda: lin.budget_sweep(dry_run=True))
    expect(not W.posts and not W.relabels, "dry-run wrote something")
    expect("CFW-6" in out and "would-ask" in out, f"dry-run set: {out!r}")
    expect("CFW-7" not in out, "dry-run listed an under-cap issue")
check("--dry-run prints the exact set and writes nothing", t_sweep_dry_run_changes_nothing)

def t_sweep_held_lock_skips():
    reset(); W.add("CFW-5", ["dozer:blocked", "lane:dev"], TWO)
    os.makedirs(lock_path("CFW-5"))
    _, err = capture(lambda: lin.budget_sweep(force=True))
    expect(W.asks("CFW-5") == 0 and not W.relabels, "a held lock must not be written through")
    expect("locked by another writer" in err, f"stderr: {err!r}")
    os.rmdir(lock_path("CFW-5"))
check("a lock held by another writer is skipped and reported", t_sweep_held_lock_skips)

def t_sweep_takes_over_stale_lock():
    reset(); W.add("CFW-5", ["dozer:blocked", "lane:dev"], TWO)
    os.makedirs(lock_path("CFW-5"))
    old = time.time() - 3600
    os.utime(lock_path("CFW-5"), (old, old))
    lin.budget_sweep(force=True)
    expect(W.asks("CFW-5") == 1, "a dead holder's lock must not block the sweep forever")
    expect(not os.path.exists(lock_path("CFW-5")), "the lock must be released")
check("a stale lock (dead holder) is taken over", t_sweep_takes_over_stale_lock)

def t_sweep_throttle():
    reset(); W.add("CFW-6", ["dozer:blocked", "lane:dev"], TWO)
    os.environ["BUDGET_SWEEP_EVERY"] = "1800"
    try:
        lin.budget_sweep()                       # first run: stamps and asks
        expect(W.asks("CFW-6") == 1, "first sweep should run")
        W.add("CFW-8", ["dozer:blocked", "lane:dev"], TWO)
        _, err = capture(lambda: lin.budget_sweep())
        expect(W.asks("CFW-8") == 0, "a sweep inside the window must not run")
        expect("throttled" in err, f"stderr: {err!r}")
        lin.budget_sweep(force=True)              # the manual backfill bypasses the window
        expect(W.asks("CFW-8") == 1, "--force must bypass the throttle")
    finally:
        os.environ["BUDGET_SWEEP_EVERY"] = "0"
check("the sweep is throttled to its window; force bypasses it", t_sweep_throttle)

# ── 8. the gap is visible ────────────────────────────────────────────────────
def t_release_count_states():
    reset()
    W.add("A-under", ["dozer:blocked", "lane:dev"], [CLAIM, BLK("x")])
    W.add("A-missing", ["dozer:blocked", "lane:dev"], TWO)
    W.add("A-asked", ["dozer:blocked", "lane:dev", "board:to_review"], TWO + [ASK])
    def line(i):
        out, _ = capture(lambda: lin.release_count(i)); return out.splitlines()[0]
    expect("ask=none" in line("A-under") and "board=no" in line("A-under"), line("A-under"))
    expect("ask=MISSING" in line("A-missing") and "board=no" in line("A-missing"), line("A-missing"))
    expect("ask=outstanding" in line("A-asked") and "board=yes" in line("A-asked"), line("A-asked"))
check("release-count says ask=none / MISSING / outstanding, and board=yes|no", t_release_count_states)

print(f"\nbudget-ask: {pas} passed, {fai} failed")
sys.exit(1 if fai else 0)
PY
)"; rc=$?
echo "$out"
exit $rc
