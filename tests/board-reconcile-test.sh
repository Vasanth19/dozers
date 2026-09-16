#!/usr/bin/env bash
# tests/board-reconcile-test.sh — regression for GSAI-41: the board reconcile must never
# read an agent's own comment as Vasanth's answer.
#
# The workspace has ONE Linear user, so every agent posts as Vas; authorship is told
# apart by marker. The old rule was "a later comment with no `board-*` marker is Vas's
# answer" — but the Directors write markers like `<!-- honey-preflight -->`, which do
# not start with `board-`. GSAI-29 (live, 2026-09-07): newest comment = Honey's
# `<!-- honey-preflight -->` → the next reconcile would have flipped the issue to
# board:responded and a question Vas never saw would count as answered.
#
# Contract now: an agent comment MUST carry a marker; an UNMARKED comment is Vas.
# No network: board_answers() is pure (takes the comment list); the CLI probe runs
# against a stubbed _issue_comments().
#
# GSAI-60 (sections 13-16): the contract above was only enforced on the READ side —
# every SCRIPTED comment (Dozer claim/blocked/merged, reaper requeue, Director-ready)
# was posted unmarked, so any of them after a board-ask auto-approved the issue.
# Measured live 2026-09-08: 11 of 22 board issues, 50 unmarked agent comments. The
# fix is two layers and both are pinned here: a WRITE-side stamp at the comment()
# choke point (`_stamp_marker` appends `<!-- board-note by:… -->` to any unmarked
# body) and a READ-side guard (is_human_answer refuses known agent signatures).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

# One python run prints a `<case>=<result>` line per scenario; assertions live in bash
# so a failing case names itself in the run-all log.
out="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used python3 - <<'PY'
import importlib.util, io, contextlib, sys
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py"); lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)

def c(t, body): return {"createdAt": t, "body": body, "url": "u"}
ASK_H = c("2026-09-08T03:56:11Z", "@Vas — how do you want to clear it — options: (a) … (b) …\n\n<!-- board-ask id:2026-09-08T03:55:50Z by:Honey -->")
def answered(comments):
    ask, ans, refused = lin.board_answers(comments)
    return ("noask" if ask is None else ("yes" if ans else "no"), [a["body"].splitlines()[0] for a in ans])

# 1. GSAI-29 as it stood on 2026-09-07 — Honey's own marked comments after her ask,
#    plus other Directors' asks and the ops-director's deliberately marked hold.
gsai29 = [
    c("2026-09-07T04:35:55Z", "🐝 Honey — the audit\n\n<!-- honey-board-triage -->"),
    c("2026-09-07T04:40:24Z", "🐝 Honey — pre-flighted the nine\n\n<!-- honey-preflight -->"),
    ASK_H,
    c("2026-09-08T03:57:08Z", "@Vas — one decision unlocks everything\n\n<!-- board-ask id:2026-09-07T22:57:08-05:00 by:Fizz -->"),
    c("2026-09-08T04:02:15Z", "🐝 Honey — amendment to the ask above\n\n<!-- board-ask id:2026-09-07T23:20:00Z by:Honey -->"),
    c("2026-09-08T04:06:59Z", "Ops-Director — holding this open.\n<!-- honey-preflight -->\n<!-- board-ask id:2026-09-07T23:25:00Z by:ops-director -->"),
]
print("gsai29=%s" % answered(gsai29)[0])

# 2. The exact regression: a `honey-preflight` comment posted AFTER a board-ask.
print("preflight_after_ask=%s" % answered([ASK_H, c("2026-09-08T05:00:00Z", "🐝 Honey — pre-flight notes\n\n<!-- honey-preflight -->")])[0])

# 3. Any `<name>-…` marker, any position in the body, any name — still an agent.
for name, body in [
    ("fizz_sweep",     "<!-- fizz-sweep -->\nFizz — swept all four teams."),
    ("guzz_note",      "Guzz — promoted develop→main. <!-- guzz-promote id:x -->"),
    ("hb_clear",       "🟢 recovered\n\n<!-- board-clear id:2026-09-08T05:00:00Z by:heartbeat-check human_answered:no -->"),
    ("multiline_mark", "Ops — holding.\n<!--\n  ops-director-hold\n-->"),
    ("bare_html_cmt",  "note to self <!-- todo --> more"),
]:
    print("%s=%s" % (name, answered([ASK_H, c("2026-09-08T05:00:00Z", body)])[0]))

# 4. The real answer: an unmarked comment after the ask → answered, and it is the one returned.
r = answered([ASK_H, c("2026-09-08T04:06:59Z", "Ops — holding.\n<!-- ops-director-hold -->"), c("2026-09-08T06:00:00Z", "(b) — delegate it, but I want the nine first.")])
print("vas_answer=%s|%s" % (r[0], r[1][0]))

# 5. A mirrored answer (`board-mirror`) is Vas's answer too — the protocol says so — but
#    it carries a marker, so board_answers() alone must NOT flag it. Document + pin: the
#    mirror step is the Director's own act, and it swaps the label itself at mirror time.
print("mirror_alone=%s" % answered([ASK_H, c("2026-09-08T06:00:00Z", "(via board/inbox) yes\n\n<!-- board-mirror src:inbox/GSAI-29.md -->")])[0])

# 6. Unmarked comment BEFORE the ask is not an answer; no ask at all → noask.
print("before_ask=%s" % answered([c("2026-09-08T01:00:00Z", "earlier chat from Vas"), ASK_H])[0])
print("no_ask=%s" % answered([c("2026-09-08T01:00:00Z", "just a note <!-- honey-preflight -->")])[0])

# 7. Only the NEWEST ask counts: an answer to an older ask, then a fresh ask → waiting.
print("re_ask=%s" % answered([ASK_H, c("2026-09-08T06:00:00Z", "(a)"), c("2026-09-08T07:00:00Z", "@Vas — follow-up?\n\n<!-- board-ask id:2026-09-08T07:00:00Z by:Honey -->")])[0])

# 8. Unsorted input is sorted before the ask/after split.
print("unsorted=%s" % answered([c("2026-09-08T06:00:00Z", "(a)"), ASK_H])[0])

# 9. The CLI probe: exit codes 0 / 3 / 2 against a stubbed comment fetch.
def probe(comments):
    lin._issue_comments = lambda ident: sorted(comments, key=lambda x: x["createdAt"])
    so, se = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(so), contextlib.redirect_stderr(se): lin.board_answer("GSAI-29")
        rc = 0
    except SystemExit as e: rc = e.code
    return rc, so.getvalue().strip(), se.getvalue().strip()
print("cli_waiting=%s" % probe(gsai29)[0])
rc, o, _ = probe(gsai29 + [c("2026-09-08T06:00:00Z", "(b) delegate it")])
print("cli_answered=%s|%s" % (rc, o))
print("cli_noask=%s" % probe([c("2026-09-08T01:00:00Z", "hi <!-- honey-preflight -->")])[0])

# 10. is_agent_comment on its own.
print("agent_plain=%s" % lin.is_agent_comment("plain text from Vas"))
print("agent_empty=%s" % lin.is_agent_comment(""))
print("agent_none=%s" % lin.is_agent_comment(None))
print("agent_marked=%s" % lin.is_agent_comment("x <!-- honey-preflight --> y"))
PY
)"
rc=$?
(( rc == 0 )) || { echo "python harness exited $rc" >&2; echo "$out" >&2; exit 1; }
get() { sed -n "s/^$1=//p" <<<"$out"; }
is() { local k="$1" want="$2" why="$3"; local got; got="$(get "$k")"; [[ "$got" == "$want" ]] && ok "$why" || bad "$why — $k: got '$got', want '$want'"; }

is gsai29              no    "GSAI-29 as found live: newest comment is Honey's honey-preflight → NOT answered (stays board:to_review)"
is preflight_after_ask no    "a <!-- honey-preflight --> comment after a board-ask does not count as Vas's answer"
is fizz_sweep          no    "any <name>-… marker at the top of the body is an agent comment"
is guzz_note           no    "a marker inline mid-body is an agent comment"
is hb_clear            no    "the watchdog's board-clear marker is an agent comment"
is multiline_mark      no    "a multi-line <!-- … --> marker is an agent comment"
is bare_html_cmt       no    "any HTML comment at all is treated as a marker (fail toward visible)"
is vas_answer          "yes|(b) — delegate it, but I want the nine first."  "an UNMARKED comment after the ask is Vas's answer, and it is the one returned"
is mirror_alone        no    "a board-mirror comment is marked — the mirror step swaps the label itself, the probe does not"
is before_ask          no    "an unmarked comment BEFORE the ask is not an answer"
is no_ask              noask "no board-ask on the issue → nothing to reconcile"
is re_ask              no    "only the newest ask counts — a fresh ask after an old answer is waiting again"
is unsorted            yes   "comments are sorted by createdAt before the split"
is cli_waiting         3     "CLI probe exits 3 on GSAI-29 (waiting)"
is cli_answered        "0|2026-09-08T06:00:00Z	(b) delegate it"  "CLI probe exits 0 and prints <createdAt><TAB><first line> when Vas answered"
is cli_noask           2     "CLI probe exits 2 when there is no board-ask"
is agent_plain         False "is_agent_comment: plain text is Vas"
is agent_empty         False "is_agent_comment: empty body is not a marker"
is agent_none          False "is_agent_comment: None body is safe"
is agent_marked        True  "is_agent_comment: a marker anywhere → agent"

# 11. alarm_clear (heartbeat) uses the same classifier: a Director's marked comment after
#     the watchdog's own ask must NOT hand the ball to board:responded.
out2="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py"); lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)
def c(t, body): return {"createdAt": t, "body": body, "url": "u"}
ask = c("2026-09-08T03:00:00Z", "🔴 Dozer down\n\n<!-- board-ask id:2026-09-08T03:00:00Z by:heartbeat-check -->")
calls = []
lin.issue = lambda i: {"id": "x", "identifier": i, "state": {"type": "unstarted"}, "labels": {"nodes": []}, "team": {"id": "t"}}
lin._relabel = lambda iss, add=(), remove=(), state_type=None: calls.append((tuple(add), tuple(remove)))
lin._comment_url = lambda i, b: "url"
for name, later in [("director_marked", [c("2026-09-08T04:00:00Z", "Ops — restarted it. <!-- ops-director-note -->")]),
                    ("vas_unmarked",    [c("2026-09-08T04:00:00Z", "restarted, carry on")]),
                    ("nothing",         [])]:
    calls.clear(); lin._issue_comments = lambda i, L=later: [ask] + L
    lin.alarm_clear("GSAI-38", "🟢 recovered")
    print("%s=%s" % (name, "responded" if calls and lin.BOARD_RESPONDED in calls[0][0] else "removed"))
PY
)"
get2() { sed -n "s/^$1=//p" <<<"$out2"; }
[[ "$(get2 director_marked)" == removed   ]] && ok "alarm_clear: a Director's marked comment after the watchdog's ask → flag removed, NOT board:responded" || bad "alarm_clear treated a marked comment as human: $(get2 director_marked)"
[[ "$(get2 vas_unmarked)"    == responded ]] && ok "alarm_clear: an unmarked comment after the ask → board:responded" || bad "alarm_clear missed Vas's unmarked answer: $(get2 vas_unmarked)"
[[ "$(get2 nothing)"         == removed   ]] && ok "alarm_clear: no later comment → flag removed" || bad "alarm_clear: $(get2 nothing)"

# 12. The contract sentence is in LINEAR.md, and no Director template carries a stray
#     `board-*`-only rule or invents a marker name outside the `<name>-<purpose>` shape.
grep -qF "an unmarked comment is Vas" "$ROOT/directors/LINEAR.md" && ok "LINEAR.md states the contract: an agent comment MUST carry a marker; an unmarked comment is Vas" || bad "LINEAR.md is missing the one-sentence contract"
grep -q 'no `board-\*` marker' "$ROOT/directors/LINEAR.md" && bad "LINEAR.md still carries the narrow 'no board-* marker' rule" || ok "LINEAR.md no longer scopes the reconcile rule to board-* markers"
for t in chief dev-director mktg-director ops-director; do
  f="$ROOT/directors/$t.md"
  grep -qF -- '-<purpose>' "$f" && ok "$t.md: every comment carries a <name>-<purpose> marker" || bad "$t.md: no marker rule"
  grep -Eo '<!--[^>]*-->' "$f" | grep -Ev '<!-- *(board-(ask|mirror|clear)|<(your-)?name>-<purpose>)' | grep -q . && bad "$t.md: stray marker literal: $(grep -Eo '<!--[^>]*-->' "$f" | tr '\n' ' ')" || ok "$t.md: no stray marker literals"
done

# 13/14/15. GSAI-60 — the incident's fix. STAMP: every scripted comment self-marks at
#      the commentCreate doors. GUARD: a pre-fix (still unmarked) agent status line
#      after a board-ask is REFUSED, never read as Vas's answer; the CLI probe exits 3
#      and names the refusal on stderr. ALARM: the watchdog's clear path uses the same
#      classifier. With the pre-fix code every GUARD case reads the status line as the
#      answer — these cases ARE the repro.
out3="$(cd "$ROOT/tasks" && LINEAR_API_KEY=test-not-used python3 - <<'PY'
import importlib.util, io, contextlib, os, sys
spec = importlib.util.spec_from_file_location("lin", "_linear_api.py"); lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)
os.environ.pop("DOZER_COMMENT_BY", None)

def c(t, body): return {"createdAt": t, "body": body, "url": "u"}
def answered(comments):
    ask, ans, refused = lin.board_answers(comments)
    return ("noask" if ask is None else ("yes" if ans else "no"), [a["body"].splitlines()[0] for a in ans])
def probe(comments):
    lin._issue_comments = lambda ident: sorted(comments, key=lambda x: x["createdAt"])
    so, se = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(so), contextlib.redirect_stderr(se): lin.board_answer("GSAI-60")
        rc = 0
    except SystemExit as e: rc = e.code
    return rc, so.getvalue().strip(), se.getvalue().strip()

# --- STAMP: capture the commentCreate bodies at both doors ------------------------
posted = []
lin.issue = lambda i: {"id": "x", "identifier": i, "state": {"type": "unstarted"}, "labels": {"nodes": []}, "team": {"id": "t"}}
def fake_gql(q, v=None):
    posted.append((v or {}).get("b"))
    return {"commentCreate": {"success": True, "comment": {"url": "u"}}}
lin.gql = fake_gql

lin.comment("GSAI-60", "Dozer claimed - lane:dev. Starting now; will post a summary on finish.")
print("stamp_gains_marker=%s" % posted[-1].endswith("\n\n<!-- board-note by:dozer-engine -->"))
print("stamp_keeps_text=%s" % posted[-1].startswith("Dozer claimed - lane:dev. Starting now;"))
marked = "the answer (via board/inbox)\n\n<!-- board-mirror src:inbox/GSAI-60.md -->"
lin.comment("GSAI-60", marked)
print("stamp_marked_byteidentical=%s" % (posted[-1] == marked))
os.environ["DOZER_COMMENT_BY"] = "dozer-reaper"
lin.comment("GSAI-60", "♻️ Reaper requeued this task: no live worker.")
print("stamp_by_honored=%s" % posted[-1].endswith("<!-- board-note by:dozer-reaper -->"))
os.environ.pop("DOZER_COMMENT_BY", None)
lin._comment_url("GSAI-60", "watchdog detail, forgot the marker")
print("stamp_comment_url=%s" % posted[-1].endswith("<!-- board-note by:dozer-engine -->"))
print("stamp_empty=%s" % (lin._stamp_marker("") == "\n\n<!-- board-note by:dozer-engine -->"))

# --- GUARD: the exact GSAI-60 incident shapes -------------------------------------
ask = c("2026-09-08T03:00:00Z", "@Vas — route? — options: (a) … (b) …\n\n<!-- board-ask id:2026-09-08T03:00:00Z by:Fizz -->")
claim = c("2026-09-08T04:00:00Z", "Dozer claimed - lane:marketing. Starting now; will post a summary on finish.")
reap  = c("2026-09-08T04:30:00Z", "♻️ Reaper requeued this task: its Dozer stopped without finishing (no live worker). It will be re-picked on the next poll.")
appr  = c("2026-09-08T05:00:00Z", "Director approved → lane:dev, marked ready.")
merged = c("2026-09-08T05:30:00Z", "Dozer merged to develop - lane:dev\n- done")
for name, cmt in [("guard_claim", claim), ("guard_reaper", reap), ("guard_director", appr), ("guard_merged", merged)]:
    print("%s=%s" % (name, answered([ask, cmt])[0]))
rc, o, se = probe([ask, claim])
print("guard_cli=%s|%s" % (rc, "REFUSED" in se and "Dozer (claimed|blocked|merged|staged)" in se))
rc, o, se = probe([ask, claim, c("2026-09-08T06:00:00Z", "(a) — ship it")])
print("guard_mixed=%s|%s|%s" % (rc, o, "REFUSED" in se))
# An unmarked comment matching NO signature still answers (fail toward visible, not paranoid).
print("guard_plain=%s" % answered([ask, c("2026-09-08T06:00:00Z", "yes — (a)")])[0])

# --- ALARM: alarm_clear uses the same classifier ----------------------------------
calls = []
lin._relabel = lambda iss, add=(), remove=(), state_type=None: calls.append((tuple(add), tuple(remove)))
lin._comment_url = lambda i, b: "url"
ask_hb = c("2026-09-08T03:00:00Z", "🔴 Dozer down\n\n<!-- board-ask id:2026-09-08T03:00:00Z by:heartbeat-check -->")
lin._issue_comments = lambda i: [ask_hb, c("2026-09-08T04:00:00Z", "Dozer blocked in lane:dev - needs a look.\nReason: crew died")]
lin.alarm_clear("GSAI-38", "🟢 recovered")
print("alarm_guard=%s" % ("responded" if calls and lin.BOARD_RESPONDED in calls[0][0] else "removed"))
PY
)"
rc=$?
(( rc == 0 )) || { echo "python harness exited $rc" >&2; echo "$out3" >&2; exit 1; }
get3() { sed -n "s/^$1=//p" <<<"$out3"; }
is3() { local k="$1" want="$2" why="$3"; local got; got="$(get3 "$k")"; [[ "$got" == "$want" ]] && ok "$why" || bad "$why — $k: got '$got', want '$want'"; }

is3 stamp_gains_marker        True  "STAMP: an unmarked scripted comment gains the board-note marker at the only door"
is3 stamp_keeps_text          True  "STAMP: the marker is appended — the original text is preserved"
is3 stamp_marked_byteidentical True "STAMP: an already-marked body round-trips BYTE-IDENTICAL (no double stamp)"
is3 stamp_by_honored          True  "STAMP: DOZER_COMMENT_BY names the caller (dozer.sh / reaper.sh / run.sh)"
is3 stamp_comment_url         True  "STAMP: _comment_url() (the watchdog's alarm door) stamps the same way"
is3 stamp_empty               True  "STAMP: an empty scripted comment is stamped too — still an agent comment"
is3 guard_claim               no    "GUARD (the incident): an unmarked 'Dozer claimed' after the ask is NOT Vas's answer"
is3 guard_reaper              no    "GUARD: an unmarked '♻️ Reaper requeued' after the ask is NOT Vas's answer"
is3 guard_director            no    "GUARD: an unmarked 'Director approved' after the ask is NOT Vas's answer"
is3 guard_merged              no    "GUARD: an unmarked 'Dozer merged to develop' after the ask is NOT Vas's answer"
is3 guard_cli                 "3|True" "GUARD: the CLI probe exits 3 AND the refusal is named on stderr"
is3 guard_mixed               "0|2026-09-08T06:00:00Z	(a) — ship it|True" "GUARD: a refused status line must not swallow Vas's later real answer — exit 0 returns his line only"
is3 guard_plain               yes   "GUARD: an unmarked comment matching no signature still answers (fail toward visible, not paranoid)"
is3 alarm_guard               removed "ALARM: an unmarked 'Dozer blocked' line after the watchdog's ask → flag removed, NOT board:responded"

# 16. STRUCTURE PIN: the only commentCreate MUTATION sites in _linear_api.py are
#     comment() and _comment_url(), and BOTH route the body through _stamp_marker. A
#     future raw poster cannot slip in unnoticed — add a third and this test goes red.
[[ "$(grep -c 'commentCreate(input:' "$ROOT/tasks/_linear_api.py")" == "2" ]] \
  && ok "structure: commentCreate mutations only in comment() + _comment_url() — no raw poster" \
  || bad "structure: a new commentCreate site appeared outside the stamped doors"
sed -n '/^def comment(/,/^$/p' "$ROOT/tasks/_linear_api.py" | grep -q '_stamp_marker' \
  && ok "structure: comment() routes its body through _stamp_marker" \
  || bad "structure: comment() posts un-stamped"
sed -n '/^def _comment_url(/,/^$/p' "$ROOT/tasks/_linear_api.py" | grep -q '_stamp_marker' \
  && ok "structure: _comment_url() routes its body through _stamp_marker" \
  || bad "structure: _comment_url() posts un-stamped"

echo "board-reconcile: $pass ✓, $fail ✗"; (( fail == 0 ))
