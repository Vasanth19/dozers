#!/usr/bin/env python3
"""Linear backend for Dozers — the real GraphQL logic behind tasks/linear.sh.

Scoped to ONE team or MANY (multi-team mode). Ids in/out are Linear's human
identifiers (e.g. "CFW-9"), not UUIDs, so the CLI stays readable.

Env it reads:
  LINEAR_API_KEY   personal API key (or OAuth app token)          — required
  LINEAR_TEAMS     comma list of team keys, e.g. "CFW,LL"          — multi-team
  LINEAR_TEAM      a single team key, e.g. "CFW"                   — single-team
                   (LINEAR_TEAMS wins if both are set)

State machine (mirrors the other backends' labels):
  greenlight  -> label  ready
  lanes       -> labels lane:<name>
  claimed     -> issue moves to a `started` state (removes `ready`)
  done        -> issue moves to a `completed` state
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


def set_labels_and_state(iss, label_ids, state_id_=None):
    inp = {"labelIds": label_ids}
    if state_id_:
        inp["stateId"] = state_id_
    gql('mutation($id:String!,$in:IssueUpdateInput!){ issueUpdate(id:$id,input:$in){ success } }',
        {"id": iss["id"], "in": inp})


# --- the verbs (all multi-team aware) ----------------------------------------

def list_untriaged():
    for i in _all_issues():
        if i["state"]["type"] in ("completed", "canceled"):
            continue
        labels = i["labels"]["nodes"]
        if _lane_of(labels) is None and not _has(labels, "ready"):
            print(f'{i["identifier"]}\t{i["title"]}')


def list_ready():
    for i in _all_issues():
        if i["state"]["type"] not in ("backlog", "unstarted", "triage"):
            continue
        labels = i["labels"]["nodes"]
        lane = _lane_of(labels)
        if _has(labels, "ready") and lane:
            print(f'{i["identifier"]}\t{lane}\t{i["title"]}')


def mark_ready(identifier, lane):
    iss = issue(identifier)
    tid = iss["team"]["id"]
    ready_id = ensure_label(tid, "ready", "#16a05a")
    lane_id = ensure_label(tid, f"lane:{lane}", "#d98419")
    have = {n["id"] for n in iss["labels"]["nodes"]} | {ready_id, lane_id}
    set_labels_and_state(iss, list(have))
    print(f"{identifier} -> ready + lane:{lane}")


def claim(identifier):
    iss = issue(identifier)
    labels = iss["labels"]["nodes"]
    if not _has(labels, "ready"):
        sys.exit(1)  # already claimed (ready is gone)
    keep = [n["id"] for n in labels if n["name"] != "ready"]
    set_labels_and_state(iss, keep, state_id(iss["team"]["id"], "started"))


def done(identifier):
    iss = issue(identifier)
    keep = [n["id"] for n in iss["labels"]["nodes"] if n["name"] != "ready"]
    set_labels_and_state(iss, keep, state_id(iss["team"]["id"], "completed"))


def repo(identifier):
    for n in issue(identifier)["labels"]["nodes"]:
        if n["name"].startswith("repo:"):
            print(n["name"][len("repo:"):]); return


def review(identifier):
    iss = issue(identifier)
    nr = ensure_label(iss["team"]["id"], "needs-review", "#d876e3")
    keep = [n["id"] for n in iss["labels"]["nodes"] if n["name"] != "ready"]
    if nr not in keep: keep.append(nr)
    set_labels_and_state(iss, keep)   # stays In Progress + needs-review; NOT done


def team(identifier):
    print(issue(identifier)["team"]["key"])


def comment(identifier, text):
    iss = issue(identifier)
    gql('mutation($id:String!,$b:String!){ commentCreate(input:{issueId:$id,body:$b}){ success } }',
        {"id": iss["id"], "b": text})


OPS = {
    "list-untriaged": lambda a: list_untriaged(),
    "list-ready": lambda a: list_ready(),
    "mark-ready": lambda a: mark_ready(a[0], a[1]),
    "claim": lambda a: claim(a[0]),
    "done": lambda a: done(a[0]),
    "comment": lambda a: comment(a[0], a[1]),
    "repo": lambda a: repo(a[0]),
    "team": lambda a: team(a[0]),
    "review": lambda a: review(a[0]),
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in OPS:
        die(f"usage: _linear_api.py <{'|'.join(OPS)}> [args]")
    OPS[sys.argv[1]](sys.argv[2:])
