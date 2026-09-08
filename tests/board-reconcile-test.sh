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
    ask, ans = lin.board_answers(comments)
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

echo "board-reconcile: $pass ✓, $fail ✗"; (( fail == 0 ))
