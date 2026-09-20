#!/usr/bin/env bash
# tests/linear-focus-gate-test.sh — regression for GSAI-176 (the weekly focus gate).
#
# Vasanth, 2026-09-20: "nail it down on only top three projects and make it meaningful
# for the next one week." The greenlight says a task MAY run; the focus says whether it
# is what we are doing THIS WEEK. The invariants this test pins down:
#
#   1. NO FOCUS = NO CHANGE — an empty list, a missing/garbled `until`, or a date that
#      has passed all leave list_ready() exactly as it was. The gate fails OPEN, on
#      purpose: a stale config must never be able to silently stop the factory.
#   2. ACTIVE FOCUS FILTERS — only issues whose Linear PROJECT is named in
#      focus.projects are listed. Everything else keeps its greenlight and waits.
#      Matching is EXACT: "MGG: Reels" is not "BRD: MGG Reels".
#   3. `focus:override` PASSES — the escape hatch for an outage or a Vasanth ask, and it
#      says so in the log (`focus: override <ID>`).
#   4. IT TALKS, BUT QUIETLY — one stderr line per out-of-focus issue per DAY (deduped
#      by the dated seen-set), one summary line per POLL, and NEVER a Linear comment:
#      hundreds of issues are out of focus in any week and the issue is not wrong, it is
#      merely not now.
#   5. THE WATCHDOG AGREES — count_ready counts what list_ready would dispatch, so a
#      queue full of deliberately-deferred work cannot hold the "alive but not
#      dispatching" alarm high for the whole focus window.
#   6. PRECEDENCE — the KR gate runs FIRST: an un-laddered issue is refused whether or
#      not it is in focus, and it is never counted as an out-of-focus skip.
#
# Hermetic: the Linear I/O (`_all_issues`, `_issue_comments`, `comment`) is stubbed and
# the config is a throwaway file (DOZER_CONFIG).
#
# Run:  bash tests/linear-focus-gate-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"; trap 'rm -rf "$STATE" 2>/dev/null || true' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used LINEAR_TEAMS=T \
      DOZER_STATE_DIR="$STATE" python3 - <<'PY'
import importlib.util, io, contextlib, json, os, datetime
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py")
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)
STATE = os.environ["DOZER_STATE_DIR"]

def iss(ident, project, *labels):
    return {"identifier": ident, "title": "t", "team": {"key": "T"},
            "state": {"type": "unstarted"}, "priority": 1, "createdAt": "2026-09-01T00:00:00Z",
            "projectMilestone": {"id": "m", "name": "KR", "targetDate": "2026-10-01"},
            "project": ({"name": project} if project else None),
            "labels": {"nodes": [{"name": l} for l in labels]}}

R, L = "dozer:ready", "lane:dev"
ISSUES = [
    iss("IN-1",   "CFW: Sellable V1",        R, L),
    iss("IN-2",   "MGG: Reels",              R, L),
    iss("OUT-1",  "GSAI: Housekeeping",      R, L),
    iss("OUT-2",  "BRD: MGG Reels",          R, L),   # near-miss name: NOT a match
    iss("OUT-3",  None,                      R, L),   # no project at all
    iss("OVER-1", "GSAI: Housekeeping",      R, L, lin.FOCUS_OVERRIDE),
]
lin._all_issues = lambda: list(ISSUES)

posts = []
lin._issue_comments = lambda ident: []
lin.comment = lambda ident, body: posts.append((ident, body))

TODAY = datetime.date.today()
def cfg(projects, until):
    """Write a throwaway org/config.yaml and drop the per-process focus cache."""
    path = os.path.join(STATE, "config.yaml")
    with open(path, "w") as fh:
        fh.write("backend: linear\n")
        fh.write("focus:\n")
        fh.write("  projects: [%s]\n" % ", ".join('"%s"' % p for p in projects))
        fh.write('  until: "%s"\n' % until)
        fh.write('  note: "top three, one week"\n')
        fh.write('workdir_default: "."\n')
    os.environ["DOZER_CONFIG"] = path
    lin._FOCUS = None

def run():
    o, e = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
        lin.list_ready()
    return ([l.split("\t")[0] for l in o.getvalue().splitlines() if l],
            e.getvalue().splitlines())

def count():
    b = io.StringIO()
    with contextlib.redirect_stdout(b): lin.count_ready()
    return b.getvalue().strip()

FOCUS = ["CFW: Sellable V1", "MGG: Reels"]
FUTURE = (TODAY + datetime.timedelta(days=7)).isoformat()
res = {}

# --- no focus at all ---------------------------------------------------------------
cfg([], "")
res["none_ids"], res["none_err"] = run()
res["none_count"] = count()
res["none_reason"] = lin.focus_config()["reason"]

# --- active focus ------------------------------------------------------------------
cfg(FOCUS, FUTURE)
res["on_ids"], res["on_err"] = run()
res["on_count"] = count()
res["on_days"] = lin.focus_config()["days"]
res["on_reason"] = lin.focus_config()["reason"]
# a second poll in the same day: per-issue lines are deduped, the summary is not
res["on2_ids"], res["on2_err"] = run()
# Snapshot BEFORE the KR-gate section below adds un-laddered issues: those do post a
# comment (GSAI-171), and this assertion is about the focus gate posting none.
res["posts_focus"] = list(posts)

# --- the KR gate still runs FIRST ---------------------------------------------------
ISSUES.append(iss("NO-KR", "CFW: Sellable V1", R, L)); ISSUES[-1]["projectMilestone"] = None
ISSUES.append(iss("NO-KR-OUT", "GSAI: Housekeeping", R, L)); ISSUES[-1]["projectMilestone"] = None
lin._FOCUS = None
res["kr_ids"], res["kr_err"] = run()
ISSUES[:] = ISSUES[:6]

# --- expired window -----------------------------------------------------------------
cfg(FOCUS, (TODAY - datetime.timedelta(days=1)).isoformat())
res["exp_ids"], res["exp_err"] = run()
res["exp_count"] = count()
res["exp_reason"] = lin.focus_config()["reason"]

# --- projects set, no date: configured but NOT enforced -----------------------------
cfg(FOCUS, "")
res["nodate_ids"], _ = run()
res["nodate_reason"] = lin.focus_config()["reason"]

# --- today is the last day: inclusive ------------------------------------------------
cfg(FOCUS, TODAY.isoformat())
res["last_ids"], _ = run()
res["last_active"] = lin.focus_config()["active"]

res["posts"] = posts
print(json.dumps(res))
PY
)" || { echo "  ✗ the python harness itself failed" >&2; echo "$out" >&2; exit 1; }

j() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)" <<<"$out"; }

# ── 1. no focus = no change ──────────────────────────────────────────────────
[[ "$(j '" ".join(d["none_ids"])')" == "IN-1 IN-2 OUT-1 OUT-2 OUT-3 OVER-1" ]] \
  && ok "an empty focus list changes nothing — every greenlit issue is still listed" \
  || bad "no-focus list was: $(j '" ".join(d["none_ids"])')"
[[ "$(j 'any("focus:" in l for l in d["none_err"])')" == "False" ]] \
  && ok "...and says nothing about focus in the poll log" \
  || bad "no-focus poll logged: $(j 'd["none_err"]')"
[[ "$(j 'd["none_count"]')" == "6" ]] && ok "count_ready is unfiltered with no focus" \
                                      || bad "count_ready=$(j 'd["none_count"]'), want 6"

# ── 2. active focus filters, exactly ─────────────────────────────────────────
[[ "$(j '" ".join(d["on_ids"])')" == "IN-1 IN-2 OVER-1" ]] \
  && ok "an active focus lists only the in-focus projects (+ the override)" \
  || bad "focused list was: $(j '" ".join(d["on_ids"])')"
[[ "$(j '"OUT-2" in d["on_ids"]')" == "False" ]] \
  && ok "the match is EXACT — 'BRD: MGG Reels' is not 'MGG: Reels'" \
  || bad "a near-miss project name passed the gate"
[[ "$(j 'd["on_count"]')" == "3" ]] \
  && ok "count_ready counts exactly what list_ready would dispatch" \
  || bad "count_ready=$(j 'd["on_count"]'), want 3"
[[ "$(j 'd["on_days"]')" == "7" ]] && ok "days-left is computed from the until date" \
                                   || bad "days left = $(j 'd["on_days"]'), want 7"
grep -q "FOCUS until" <<<"$(j 'd["on_reason"]')" \
  && ok "the focus line names the window, the projects and the note" \
  || bad "focus line was: $(j 'd["on_reason"]')"

# ── 3. the override passes, loudly ───────────────────────────────────────────
[[ "$(j 'any(l == "focus: override OVER-1" for l in d["on_err"])')" == "True" ]] \
  && ok "focus:override passes the gate and logs \`focus: override <ID>\`" \
  || bad "override not logged: $(j 'd["on_err"]')"

# ── 4. it talks, but quietly ─────────────────────────────────────────────────
[[ "$(j 'sorted(l for l in d["on_err"] if l.startswith("skip: out-of-focus"))')" \
   == "['skip: out-of-focus OUT-1 (GSAI: Housekeeping)', 'skip: out-of-focus OUT-2 (BRD: MGG Reels)', 'skip: out-of-focus OUT-3 (no project)']" ]] \
  && ok "each out-of-focus skip logs once, naming the project it is under" \
  || bad "skip lines were: $(j 'd["on_err"]')"
[[ "$(j 'any(l == "focus: 3 in-focus ready, 3 out-of-focus skipped" for l in d["on_err"])')" == "True" ]] \
  && ok "one summary line per poll: in-focus vs out-of-focus" \
  || bad "summary line missing: $(j 'd["on_err"]')"
[[ "$(j 'd["on2_ids"] == d["on_ids"]')" == "True" \
   && "$(j 'any(l.startswith("skip: out-of-focus") for l in d["on2_err"])')" == "False" \
   && "$(j 'any(l.startswith("focus: 3 in-focus") for l in d["on2_err"])')" == "True" ]] \
  && ok "the next poll re-prints the summary but not the per-issue lines (deduped for a day)" \
  || bad "second poll logged: $(j 'd["on2_err"]')"
[[ "$(j 'len(d["posts_focus"])')" == "0" ]] \
  && ok "an out-of-focus skip posts NO Linear comment — not wrong, just not now" \
  || bad "the focus gate commented on Linear: $(j 'd["posts_focus"]')"

# ── 5. precedence: the KR gate first ─────────────────────────────────────────
[[ "$(j '"NO-KR" in d["kr_ids"]')" == "False" \
   && "$(j 'any("skip: no-kr NO-KR" in l for l in d["kr_err"])')" == "True" ]] \
  && ok "an un-laddered issue is refused by the KR gate even when it IS in focus" \
  || bad "KR precedence broke: ids=$(j 'd["kr_ids"]') err=$(j 'd["kr_err"]')"
[[ "$(j 'any("skip: out-of-focus NO-KR-OUT" in l for l in d["kr_err"])')" == "False" ]] \
  && ok "...and an un-laddered out-of-focus issue is counted once, by the KR gate only" \
  || bad "an un-laddered issue also reported as out-of-focus: $(j 'd["kr_err"]')"

# ── 6. the window expires on its own ─────────────────────────────────────────
[[ "$(j '" ".join(d["exp_ids"])')" == "IN-1 IN-2 OUT-1 OUT-2 OUT-3 OVER-1" ]] \
  && ok "a past \`until\` stops filtering — the focus expires by itself" \
  || bad "expired focus still filtered: $(j '" ".join(d["exp_ids"])')"
[[ "$(j 'd["exp_count"]')" == "6" ]] && ok "count_ready is unfiltered once the window has passed" \
                                     || bad "count_ready=$(j 'd["exp_count"]'), want 6"
grep -q "has passed" <<<"$(j 'd["exp_reason"]')" \
  && ok "an expired window says so out loud (never silently ignored)" \
  || bad "expired reason was: $(j 'd["exp_reason"]')"
[[ "$(j '" ".join(d["nodate_ids"])')" == "IN-1 IN-2 OUT-1 OUT-2 OUT-3 OVER-1" ]] \
  && ok "projects with no \`until\` are NOT enforced (a focus with no expiry is not a focus)" \
  || bad "a dateless focus filtered: $(j '" ".join(d["nodate_ids"])')"
grep -q "not an ISO date" <<<"$(j 'd["nodate_reason"]')" \
  && ok "...and the reason names the missing date" || bad "reason was: $(j 'd["nodate_reason"]')"
[[ "$(j 'd["last_active"]')" == "True" && "$(j '" ".join(d["last_ids"])')" == "IN-1 IN-2 OVER-1" ]] \
  && ok "\`until\` is INCLUSIVE — the last day still binds" \
  || bad "the last day did not bind: active=$(j 'd["last_active"]') ids=$(j 'd["last_ids"]')"

echo "linear-focus-gate: $pass ✓, $fail ✗"; (( fail == 0 ))
