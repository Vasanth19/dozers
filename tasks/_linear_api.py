#!/usr/bin/env python3
"""Linear backend for Dozers — the real GraphQL logic behind tasks/linear.sh.

Scoped to ONE team or MANY (multi-team mode). Ids in/out are Linear's human
identifiers (e.g. "CFW-9"), not UUIDs, so the CLI stays readable.

Env it reads:
  LINEAR_API_KEY   personal API key (or OAuth app token)          — required
  LINEAR_TEAMS     comma list of team keys, e.g. "CFW,LL"          — multi-team
  LINEAR_TEAM      a single team key, e.g. "CFW"                   — single-team
                   (LINEAR_TEAMS wins if both are set)

Label lifecycle (dozer:* = execution; lane:/repo: = routing):
  greenlight -> dozer:ready + lane:<name>          (a Director sets both)
  claimed    -> dozer:in-progress, state started    (drops dozer:ready)
  dev done   -> dozer:merged-develop                (Director then promotes -> director:merged-main)
  mktg done  -> dozer:needs-review                  (human approval gate)
  failed     -> dozer:blocked
Each mutation resolves the *issue's own* team, so multi-team ops are correct.
"""
import json, os, sys, urllib.request

API = "https://api.linear.app/graphql"
KEY = os.environ.get("LINEAR_API_KEY")
TEAM_KEYS = [k.strip() for k in
             (os.environ.get("LINEAR_TEAMS") or os.environ.get("LINEAR_TEAM") or "").split(",")
             if k.strip()]


def die(msg):
    print(f"linear: {msg}", file=sys.stderr)
    sys.exit(1)


def gql(query, variables=None):
    if not KEY:
        die("set LINEAR_API_KEY (e.g. `source ~/ecosystem/vault/linear.env`)")
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(API, data=body,
                                 headers={"Authorization": KEY, "Content-Type": "application/json"})
    try:
        r = json.load(urllib.request.urlopen(req))
    except Exception as e:
        die(f"API call failed: {e}")
    if "errors" in r:
        die(r["errors"][0].get("message", str(r["errors"])))
    return r["data"]


# --- team / label / state resolution -----------------------------------------

def teams():
    """List of {id,key} for every configured team."""
    if not TEAM_KEYS:
        die("set LINEAR_TEAM or LINEAR_TEAMS (team key(s), e.g. CFW or CFW,LL)")
    d = gql('query($k:[String!]){ teams(filter:{key:{in:$k}}){ nodes{ id key } } }',
            {"k": TEAM_KEYS})
    nodes = d["teams"]["nodes"]
    if not nodes:
        die(f"no teams matching {TEAM_KEYS}")
    return nodes


def _team_labels(tid):
    d = gql('query($t:String!){ team(id:$t){ labels(first:100){ nodes{ id name } } } }', {"t": tid})
    return {n["name"]: n["id"] for n in d["team"]["labels"]["nodes"]}


def ensure_label(tid, name, color="#6b7688"):
    labels = _team_labels(tid)
    if name in labels:
        return labels[name]
    d = gql('mutation($n:String!,$t:String!,$c:String!){ issueLabelCreate(input:{name:$n,teamId:$t,color:$c}){ issueLabel{ id } } }',
            {"n": name, "t": tid, "c": color})
    return d["issueLabelCreate"]["issueLabel"]["id"]


def state_id(tid, type_):
    d = gql('query($t:String!){ team(id:$t){ states(first:50){ nodes{ id type } } } }', {"t": tid})
    for n in d["team"]["states"]["nodes"]:
        if n["type"] == type_:
            return n["id"]
    die(f"team has no workflow state of type '{type_}'")


# --- issue helpers ------------------------------------------------------------

def issue(identifier):
    d = gql('query($i:String!){ issue(id:$i){ id identifier title '
            'team{ id key } state{ type } labels{ nodes{ id name } } } }', {"i": identifier})
    iss = d["issue"]
    if not iss:
        die(f"no issue '{identifier}'")
    return iss


def _fetch_team_issues(tid):
    d = gql('query($t:ID!){ issues(first:200, filter:{team:{id:{eq:$t}}}){ nodes{ '
            'identifier title team{ key } state{ type } labels{ nodes{ name } } } } }', {"t": tid})
    return d["issues"]["nodes"]


def _all_issues():
    for t in teams():
        for i in _fetch_team_issues(t["id"]):
            yield i


def _lane_of(labels):
    for n in labels:
        if n["name"].startswith("lane:"):
            return n["name"][len("lane:"):]
    return None


def _has(labels, name):
    return any(n["name"] == name for n in labels)


# --- dozer:* execution-lifecycle labels (lane:/repo: are routing, unchanged) --
READY = "dozer:ready"               # greenlight (a Director sets this + a lane:)
INPROG = "dozer:in-progress"        # claimed, being worked
NEEDSREVIEW = "dozer:needs-review"  # mktg staged for human approval
MERGEDDEV = "dozer:merged-develop"  # dev merged to develop (Director then promotes)
BLOCKED = "dozer:blocked"           # failure off-ramp
_COLOR = {READY: "#16a05a", INPROG: "#fbca04", NEEDSREVIEW: "#d876e3",
          MERGEDDEV: "#0e8a16", BLOCKED: "#b60205"}


def set_labels_and_state(iss, label_ids, state_id_=None):
    inp = {"labelIds": label_ids}
    if state_id_:
        inp["stateId"] = state_id_
    gql('mutation($id:String!,$in:IssueUpdateInput!){ issueUpdate(id:$id,input:$in){ success } }',
        {"id": iss["id"], "in": inp})


def _relabel(iss, add=(), remove=(), state_type=None):
    """Add/remove labels by name (resolving/creating ids in the issue's own team)."""
    rm = set(remove)
    keep = [n["id"] for n in iss["labels"]["nodes"] if n["name"] not in rm]
    for name in add:
        lid = ensure_label(iss["team"]["id"], name, _COLOR.get(name, "#6b7688"))
        if lid not in keep:
            keep.append(lid)
    sid = state_id(iss["team"]["id"], state_type) if state_type else None
    set_labels_and_state(iss, keep, sid)


# --- the verbs (all multi-team aware) ----------------------------------------

def list_untriaged():
    for i in _all_issues():
        if i["state"]["type"] in ("completed", "canceled"):
            continue
        labels = i["labels"]["nodes"]
        if _lane_of(labels) is None and not _has(labels, READY):
            print(f'{i["identifier"]}\t{i["title"]}')


def list_ready():
    for i in _all_issues():
        if i["state"]["type"] not in ("backlog", "unstarted", "triage"):
            continue
        labels = i["labels"]["nodes"]
        lane = _lane_of(labels)
        if _has(labels, READY) and lane:
            print(f'{i["identifier"]}\t{lane}\t{i["title"]}')


def mark_ready(identifier, lane):
    iss = issue(identifier)
    ensure_label(iss["team"]["id"], f"lane:{lane}", "#d98419")
    _relabel(iss, add=[READY, f"lane:{lane}"])
    print(f"{identifier} -> {READY} + lane:{lane}")


def claim(identifier):
    iss = issue(identifier)
    if not _has(iss["labels"]["nodes"], READY):
        sys.exit(1)  # already claimed (dozer:ready is gone)
    _relabel(iss, add=[INPROG], remove=[READY], state_type="started")


def merged(identifier):      # dev lane: merged to develop (Dozer terminal; Director promotes)
    _relabel(issue(identifier), add=[MERGEDDEV], remove=[INPROG])


def review(identifier):      # mktg lane: staged for human approval
    _relabel(issue(identifier), add=[NEEDSREVIEW], remove=[READY, INPROG])


def block(identifier):       # failure off-ramp
    _relabel(issue(identifier), add=[BLOCKED], remove=[INPROG])


def done(identifier):        # fully done (e.g. a Director after develop->main promotion)
    _relabel(issue(identifier), remove=[READY, INPROG, MERGEDDEV, NEEDSREVIEW, BLOCKED],
             state_type="completed")


def repo(identifier):
    for n in issue(identifier)["labels"]["nodes"]:
        if n["name"].startswith("repo:"):
            print(n["name"][len("repo:"):]); return


def _is_inflight(i):
    """Claimed-but-not-finished — the ONLY thing a reaper may requeue.

    A claim (claim()) is exactly: dozer:in-progress + state started. So in-flight
    requires that label — a started issue with just a lane: label is a Director's or
    a human's own work, NOT a stranded Dozer (2026-09-04 incident: the reaper
    requeued GSAI-21/23/24/25 — director-owned, merged-develop and blocked issues —
    because this filter only looked at state + lane). Anything already at an
    off-ramp (needs-review, merged-develop, blocked) is finished Dozer work, not
    in flight, even if the in-progress label lingers.
    """
    labels = i["labels"]["nodes"]
    if i["state"]["type"] != "started":
        return False
    if not _has(labels, INPROG) or _has(labels, READY):
        return False
    if any(_has(labels, off) for off in (NEEDSREVIEW, MERGEDDEV, BLOCKED)):
        return False
    return bool(_lane_of(labels))


def list_inflight():
    # These are what the reaper checks for a live worker; the ones without one get
    # requeued. See _is_inflight for the (deliberately strict) definition.
    for i in _all_issues():
        if _is_inflight(i):
            print(f'{i["identifier"]}\t{_lane_of(i["labels"]["nodes"])}\t{i["title"]}')


def requeue(identifier):
    # Undo a claim: re-add dozer:ready, drop in-progress, back to unstarted so
    # list_ready() picks it up again. The lane label is preserved.
    _relabel(issue(identifier), add=[READY], remove=[INPROG], state_type="unstarted")
    print(f"{identifier} -> requeued ({READY} + unstarted)")


def team(identifier):
    print(issue(identifier)["team"]["key"])


def description(identifier):
    # The issue description IS the brief (GSAI-7): the engine hands it to the crew so a
    # lane can route on what the Director wrote (e.g. a `production:` line marks a video
    # brief), not just the title. Empty description -> prints nothing, exit 0.
    d = gql('query($i:String!){ issue(id:$i){ description } }', {"i": identifier})
    iss = d["issue"]
    if not iss:
        die(f"no issue '{identifier}'")
    sys.stdout.write(iss.get("description") or "")


def comment(identifier, text):
    iss = issue(identifier)
    gql('mutation($id:String!,$b:String!){ commentCreate(input:{issueId:$id,body:$b}){ success } }',
        {"id": iss["id"], "b": text})


# --- engine alarm surface (dozers/heartbeat-check.sh, GSAI-31) -------------------
# The watchdog's alarm is a LABEL, not a comment. The Board view filters on exactly
# {"labels":{"name":{"eq":"board:to_review"}}}, and LINEAR_API_KEY authenticates as the
# workspace's only human, so a comment alone notifies nobody (Linear never notifies you
# about your own comment). Apply the label first; the comment is the detail.
# Authorship is told apart by marker comments, never by author — every write here
# carries `by:heartbeat-check`, and a later comment WITHOUT it is a human's answer.
BOARD_REVIEW = "board:to_review"
BOARD_RESPONDED = "board:responded"
HB_BY = "by:heartbeat-check"


def _now_iso():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _issue_comments(identifier):
    d = gql('query($i:String!){ issue(id:$i){ comments(first:100){ nodes{ body createdAt url } } } }',
            {"i": identifier})
    iss = d["issue"]
    if not iss:
        die(f"no issue '{identifier}'")
    return sorted(iss["comments"]["nodes"], key=lambda c: c["createdAt"])


def _comment_url(identifier, body):
    iss = issue(identifier)
    d = gql('mutation($id:String!,$b:String!){ commentCreate(input:{issueId:$id,body:$b}){ success comment{ url } } }',
            {"id": iss["id"], "b": body})
    return (d["commentCreate"].get("comment") or {}).get("url") or ""


def alarm_probe(identifier):
    """Can the alarm reach its surface? Resolves the tracking issue and reports it —
    a real round-trip with the real key, so `creds` proves delivery, not just presence."""
    iss = issue(identifier)
    flagged = _has(iss["labels"]["nodes"], BOARD_REVIEW)
    print(f'{iss["identifier"]}\t{iss["state"]["type"]}\t{"flagged" if flagged else "clear"}\t{iss["title"]}')


def alarm_raise(identifier, body):
    """Flag the tracking issue: board:to_review on, reopened if closed, then the detail."""
    iss = issue(identifier)
    reopen = iss["state"]["type"] in ("completed", "canceled")
    _relabel(iss, add=[BOARD_REVIEW], remove=[BOARD_RESPONDED],
             state_type="unstarted" if reopen else None)
    marked = f"{body}\n\n<!-- board-ask id:{_now_iso()} {HB_BY} -->"
    url = _comment_url(identifier, marked)
    print(f'{identifier} -> {BOARD_REVIEW}{" (reopened)" if reopen else ""} {url}')


def alarm_clear(identifier, body):
    """The outage ended. If a human commented since the alarm, hand the ball back to the
    Director (board:responded); otherwise just take the flag down. Never leave a stale
    flag on the Board."""
    iss = issue(identifier)
    comments = _issue_comments(identifier)
    last_ask = None
    for c in comments:
        if "board-ask" in c["body"] and HB_BY in c["body"]:
            last_ask = c["createdAt"]
    human = any(c["createdAt"] > last_ask and HB_BY not in c["body"]
                for c in comments) if last_ask else False
    if human:
        _relabel(iss, add=[BOARD_RESPONDED], remove=[BOARD_REVIEW])
    else:
        _relabel(iss, remove=[BOARD_REVIEW])
    marked = f"{body}\n\n<!-- board-clear id:{_now_iso()} {HB_BY} human_answered:{'yes' if human else 'no'} -->"
    url = _comment_url(identifier, marked)
    print(f'{identifier} -> {BOARD_RESPONDED if human else "flag removed"} {url}')


def count_ready():
    """How many greenlit (dozer:ready + lane:) issues are queued across the configured
    teams — the third alarm row (alive but not dispatching) needs the number, not the list."""
    n = 0
    for i in _all_issues():
        if i["state"]["type"] not in ("backlog", "unstarted", "triage"):
            continue
        labels = i["labels"]["nodes"]
        if _has(labels, READY) and _lane_of(labels):
            n += 1
    print(n)


OPS = {
    "list-untriaged": lambda a: list_untriaged(),
    "list-ready": lambda a: list_ready(),
    "mark-ready": lambda a: mark_ready(a[0], a[1]),
    "claim": lambda a: claim(a[0]),
    "merged": lambda a: merged(a[0]),
    "review": lambda a: review(a[0]),
    "block": lambda a: block(a[0]),
    "done": lambda a: done(a[0]),
    "comment": lambda a: comment(a[0], a[1]),
    "repo": lambda a: repo(a[0]),
    "team": lambda a: team(a[0]),
    "description": lambda a: description(a[0]),
    "list-inflight": lambda a: list_inflight(),
    "requeue": lambda a: requeue(a[0]),
    "alarm-probe": lambda a: alarm_probe(a[0]),
    "alarm-raise": lambda a: alarm_raise(a[0], a[1]),
    "alarm-clear": lambda a: alarm_clear(a[0], a[1]),
    "count-ready": lambda a: count_ready(),
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in OPS:
        die(f"usage: _linear_api.py <{'|'.join(OPS)}> [args]")
    OPS[sys.argv[1]](sys.argv[2:])
