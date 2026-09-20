#!/usr/bin/env python3
"""Linear backend for Dozers — the real GraphQL logic behind tasks/linear.sh.

Scoped to ONE team or MANY (multi-team mode). Ids in/out are Linear's human
identifiers (e.g. "CFW-9"), not UUIDs, so the CLI stays readable.

Env it reads:
  LINEAR_API_KEY   personal API key (or OAuth app token)          — required
  LINEAR_TEAMS     comma list of team keys, e.g. "CFW,LL"          — multi-team
  LINEAR_TEAM      a single team key, e.g. "CFW"                   — single-team
                   (LINEAR_TEAMS wins if both are set)
  DOZER_COMMENT_BY identity stamped on every scripted comment's
                   `<!-- board-note by:… -->` marker (GSAI-60)     — default dozer-engine
  DOZER_STATE_DIR  where the engine's small ephemeral scratch lives — default ~/.dozers
                   (today: the daily `no-kr-seen-<date>` log-dedupe set, GSAI-171)

Label lifecycle (dozer:* = execution; lane:/repo: = routing):
  greenlight -> dozer:ready + lane:<name>          (a Director sets both) — and a RESET:
                the greenlight clears every other dozer:* label and returns a closed or
                started issue to a pollable state, so re-greenlighting always requeues
                (GSAI-75). The poll's gate is the labels, not the state.
  claimed    -> dozer:in-progress, state started    (drops dozer:ready)
  dev done   -> dozer:merged-develop                (Director then promotes -> director:merged-main)
  mktg done  -> dozer:needs-review                  (human approval gate)
  failed     -> dozer:blocked
Each mutation resolves the *issue's own* team, so multi-team ops are correct.

Board protocol (GSAI-41): `board-answer <ID>` is the read-only reconcile probe —
exit 0 = Vas answered (prints the answers), 3 = still waiting, 2 = no board-ask.
"""
import json, os, re, sys, urllib.request

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
    # GSAI-75: a key that resolves to nothing used to be dropped in silence — the filter
    # simply returned fewer nodes and every verb (list-ready, list-untriaged, poll) went
    # on believing it covered the whole factory. Live for weeks: the service env said
    # `LINEAR_TEAMS=CFW,LL,BRD,GSAI,DEL` and `DEL` is not a team, so all of DLY was
    # invisible to the Dozer with nothing anywhere saying so. A typo in a team key must
    # fail loudly (doctrine: no silent fallbacks), not quietly shrink the factory.
    found = {n["key"] for n in nodes}
    missing = [k for k in TEAM_KEYS if k not in found]
    if missing:
        # Point at the fix, not just the fault: TEAM_KEYS is env-wins, so the offending
        # value is almost always the service env file, while org/config.yaml still holds
        # the correct list. Naming both turns a hard stop into a one-line correction.
        hint = f"  Real team keys in this workspace: {sorted(k['key'] for k in _all_team_keys())}."
        die(f"unknown team key(s) {missing} — resolved only {sorted(found)}. "
            f"LINEAR_TEAMS/LINEAR_TEAM is env-wins, so check the service env "
            f"(~/.dozers/dozer.env) before org/config.yaml's linear_teams.\n{hint}\n"
            f"  Refusing to poll a partial factory: every issue in the missing team(s) "
            f"would be invisible to the Dozer with nothing to say why.")
    return nodes


def _all_team_keys():
    """Every team key the API key can see — only ever called to build an error message."""
    try:
        return gql('query{ teams(first:100){ nodes{ key } } }')["teams"]["nodes"]
    except SystemExit:
        return []


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


# Linear caps a page at 250; anything past it needs the cursor. GSAI-75: this used to be
# a single unpaginated `first:200` and nothing checked hasNextPage — so once a team passed
# 200 issues the tail silently vanished from EVERY verb that walks the board (list-ready,
# list-untriaged, list-inflight, count-ready). Measured on 2026-09-14: CFW held 240 issues,
# so 40 were unreachable — a greenlit issue landing in that tail could never be polled and
# would sit at dozer:ready forever with no error to explain it. Always drain the cursor.
_PAGE = 250


def _fetch_team_issues(tid):
    out, cursor = [], None
    while True:
        d = gql('query($t:ID!,$n:Int!,$c:String){ issues(first:$n, after:$c, '
                'filter:{team:{id:{eq:$t}}}){ pageInfo{ hasNextPage endCursor } nodes{ '
                'identifier title team{ key } state{ type } priority createdAt '
                'projectMilestone{ id name targetDate } '
                'labels{ nodes{ name } } } } }',
                {"t": tid, "n": _PAGE, "c": cursor})
        page = d["issues"]
        out.extend(page["nodes"])
        if not page["pageInfo"]["hasNextPage"]:
            return out
        cursor = page["pageInfo"]["endCursor"]


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


# A state the poll can see. Linear's five state types are backlog / unstarted / started /
# completed / canceled; the first three are where queued work legitimately sits.
POLLABLE_STATES = ("backlog", "unstarted", "triage")


def _is_ready(i):
    """Greenlit and free to dispatch — the poll's whole definition, label-first.

    GSAI-75: this used to be `state in POLLABLE_STATES and dozer:ready and a lane`, and
    the state half of that was quietly the stricter half. The greenlight IS the label
    pair (dozer:ready + lane:) — doctrine, `Nothing runs without the greenlight` — but an
    issue sitting in a `started` state was skipped no matter what its labels said. Every
    ordinary path leaves an issue `started`: claim() sets it, and merged()/review() leave
    it there. So a Director re-greenlighting anything that had already run once produced
    an issue labelled perfectly and dispatched never, with no error and nothing on the
    Board to show for it — it just fell into the `Leak - stalled` view.

    State is now consulted for one thing only: a closed issue never runs. dozer:in-progress
    still excludes, so a torn claim (label written, nothing else) is not dispatched twice.
    """
    if i["state"]["type"] in ("completed", "canceled"):
        return False
    labels = i["labels"]["nodes"]
    if not _has(labels, READY) or _has(labels, INPROG):
        return False
    return bool(_lane_of(labels))


def _priority_of(i):
    """Linear's raw priority: 1 urgent, 2 high, 3 normal, 4 low, 0 = no priority."""
    p = i.get("priority") or 0
    return p if isinstance(p, int) else 0


def _kr_of(i):
    """The issue's Milestone (Key Result) node, or None when it is not laddered to one."""
    return i.get("projectMilestone") or None


def _kr_due(i):
    """The KR's target date as Linear returns it — a TimelessDate string "YYYY-MM-DD",
    which sorts correctly as plain text. "" when there is no milestone or no date on it."""
    return (_kr_of(i) or {}).get("targetDate") or ""


def _priority_key(i):
    """Claim order, most significant field first:

      1. the KR's targetDate, ASCENDING, nulls LAST  (GSAI-172)
      2. Linear priority: urgent first, no-priority LAST (Linear's own ordering agrees)
      3. oldest createdAt first
      4. identifier, so the sort is total and the order is reproducible

    GSAI-105 put priority at the top and made the queue a plan instead of a lottery, but
    priority is a per-ISSUE knob and the thing the factory is actually racing is a per-KR
    DEADLINE. A P1 on a KR due in 90 days outranking anything under a KR due next week is
    the wrong fleet: the date is the commitment, the priority is only how a Director
    breaks ties inside one KR's window. So the date sorts first and priority sorts under
    it. An issue with no dated KR sorts after every dated one (GSAI-171 refuses to run one
    with no KR at all; a KR with no date is legal and simply carries no urgency claim).

    The list order IS the fleet's pick order — drain() claims top-down."""
    p = _priority_of(i)
    due = _kr_due(i)
    # (0, "2026-10-01") < (1, "") — a dated KR always precedes an undated one, and
    # within the dated set the earlier date wins.
    due_rank = (0, due) if due else (1, "")
    return (due_rank, p if 1 <= p <= 4 else 5, i.get("createdAt") or "", i["identifier"])


# --- GSAI-171: no Key Result, no run -----------------------------------------------
# The doctrine has always been "every issue must ladder to a Project/Milestone", and the
# Directors' precheck already computes `leak:no-kr` — but it only REPORTED. An un-laddered
# issue that carried the greenlight still ran, so the ladder was advice and the label pair
# was the whole gate. The engine now refuses: an issue with no Milestone is never claimed,
# and it says so once, on the issue, where the Director who greenlit it will see it.
#
# Two separate idempotency mechanisms, on purpose:
#   · the COMMENT is idempotent forever, by marker — `_no_kr_note` reads the issue's
#     comments and posts only when `<!-- dozer-no-kr -->` is absent. This is the real
#     guarantee; nothing else is trusted to prevent a duplicate.
#   · the LOG LINE is deduped for a DAY, by a small on-disk set under ~/.dozers. Without
#     it the poll reprints `skip: no-kr <ID>` every 30s forever and the loop log becomes
#     unreadable. The set is an advisory noise-damper and nothing more: if it cannot be
#     read or written, the worst case is a repeated log line and one extra comment-marker
#     check — never a duplicate comment, never a claimed issue. It is keyed by date in the
#     filename, so it "resets daily" by simply being a new file, and stale days are pruned.
NO_KR_MARKER = "<!-- dozer-no-kr -->"
NO_KR_BODY = ("Dozer refuses to run this until it is laddered to a Milestone (Key Result). "
              + NO_KR_MARKER)


def _has_kr(i):
    """Laddered to a Key Result. The gate is the Milestone's EXISTENCE — a KR with no
    target date is legal (it just carries no urgency claim; see _priority_key)."""
    return _kr_of(i) is not None


def _state_dir():
    """Where the engine keeps its small ephemeral scratch. DOZER_STATE_DIR exists so a
    test never writes into the live ~/.dozers."""
    return os.path.expanduser(os.environ.get("DOZER_STATE_DIR") or "~/.dozers")


def _no_kr_seen_path():
    import datetime
    return os.path.join(_state_dir(), f"no-kr-seen-{datetime.date.today().isoformat()}")


def _no_kr_seen_load(path):
    try:
        with open(path) as f:
            return {ln.strip() for ln in f if ln.strip()}
    except OSError:
        return set()


def _no_kr_seen_add(path, identifier):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # Prune the other days' sets: this is what makes "resets daily" true on disk
        # rather than only in the filename.
        base = os.path.basename(path)
        for name in os.listdir(os.path.dirname(path)):
            if name.startswith("no-kr-seen-") and name != base:
                try:
                    os.remove(os.path.join(os.path.dirname(path), name))
                except OSError:
                    pass
        with open(path, "a") as f:
            f.write(identifier + "\n")
    except OSError:
        pass  # advisory only — see the block comment above


def _no_kr_note(identifier):
    """Post the refusal comment, once ever. Idempotent by marker: a body already carrying
    NO_KR_MARKER means it has been said. Returns True when it actually posted."""
    for c in _issue_comments(identifier):
        if NO_KR_MARKER in (c.get("body") or ""):
            return False
    comment(identifier, NO_KR_BODY)   # already marked, so _stamp_marker is a no-op
    return True


def _refuse_no_kr(identifier):
    """Say it once a day in the log, once ever on the issue. Deliberately NOT wrapped in
    a try: a Linear call that fails here fails loudly like every other call in this file
    (doctrine: no silent fallbacks). The seen-set is written only AFTER the note lands, so
    a failed post is retried on the next poll rather than swallowed by the cache."""
    path = _no_kr_seen_path()
    if identifier in _no_kr_seen_load(path):
        return
    print(f"skip: no-kr {identifier}", file=sys.stderr)
    _no_kr_note(identifier)
    _no_kr_seen_add(path, identifier)


def list_ready():
    claimable = []
    for i in _all_issues():
        if not _is_ready(i):
            continue
        if not _has_kr(i):
            _refuse_no_kr(i["identifier"])   # logs + comments; never claimed (GSAI-171)
            continue
        claimable.append(i)
    for i in sorted(claimable, key=_priority_key):
        # Columns 4 and 5 carry the KEY the sort ran on, so dozer.sh can log WHY a task
        # was picked rather than just that it was: the priority ("" when the issue has
        # none) and the KR's target date ("" when there is no dated milestone). See the
        # contract in tasks/adapter.sh.
        p = _priority_of(i)
        prio = str(p) if 1 <= p <= 4 else ""
        print(f'{i["identifier"]}\t{_lane_of(i["labels"]["nodes"])}\t{i["title"]}\t{prio}\t{_kr_due(i)}')


def mark_ready(identifier, lane):
    """The greenlight. Resets the issue to queued — labels AND state.

    GSAI-75: this only ever ADDED dozer:ready + lane:, so re-greenlighting left whatever
    the last run wrote still on the issue — a `started` state the poll skipped, and a
    stale dozer:in-progress / blocked / merged-develop / needs-review label claiming the
    task was somewhere it wasn't. block() and requeue() already reset state for exactly
    this reason (see the 2026-09-05 note on block()); the greenlight itself did not, which
    is why the leak survived every off-ramp fix. A greenlight now means one thing —
    queued, nothing else in flight.

    A pollable state is left alone: an issue triaged in Backlog stays in Backlog rather
    than being yanked into Todo by a Director's approval.
    """
    iss = issue(identifier)
    ensure_label(iss["team"]["id"], f"lane:{lane}", "#d98419")
    reset = iss["state"]["type"] not in POLLABLE_STATES
    _relabel(iss, add=[READY, f"lane:{lane}"],
             remove=[INPROG, BLOCKED, MERGEDDEV, NEEDSREVIEW],
             state_type="unstarted" if reset else None)
    print(f"{identifier} -> {READY} + lane:{lane}{' (state reset to unstarted)' if reset else ''}")


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
    # 2026-09-05: also reset state to Todo (unstarted) — poll only sees dozer:ready
    # issues in backlog/unstarted/triage, so a re-greenlit issue stuck in "started"
    # (In Progress) is invisible until someone moves it back manually.
    _relabel(issue(identifier), add=[BLOCKED], remove=[INPROG], state_type="unstarted")


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


def list_merged_dev():
    """Every issue carrying dozer:merged-develop, ANY state (the audit's input).

    GSAI-119: this label used to mean only "the dev crew exited 0". The audit
    (dozers/audit-merged.sh) git-verifies each of these rows against the issue's
    repo. Row format: identifier \t team \t repo:<id> hint (or -) \t state type \t lane.
    Includes closed issues on purpose: Done + merged-develop pollutes the Ship gate
    view (CFW-251, 2026-09-14)."""
    for i in _all_issues():
        labels = i["labels"]["nodes"]
        if not _has(labels, MERGEDDEV):
            continue
        hint = next((n["name"][len("repo:"):] for n in labels if n["name"].startswith("repo:")), "-")
        print(f'{i["identifier"]}\t{i["team"]["key"]}\t{hint}\t{i["state"]["type"]}\t{_lane_of(labels) or "-"}')


def audit_requeue(identifier):
    """A phantom merge on an OPEN issue: strip the label, hand the task back to the
    queue (dozer:ready + unstarted, lane preserved) so the Dozer actually does the
    work this time. GSAI-119 — see dozers/audit-merged.sh."""
    _relabel(issue(identifier), add=[READY], remove=[MERGEDDEV, INPROG], state_type="unstarted")
    print(f"{identifier} -> {READY} (phantom {MERGEDDEV} stripped, requeued)")


def audit_strip(identifier):
    """Label hygiene ONLY (GSAI-119): a completed/canceled issue must not retain
    dozer:merged-develop — it pollutes the Ship gate view with an already-closed
    PROMOTE row. Drops the label, never touches state."""
    _relabel(issue(identifier), remove=[MERGEDDEV])
    print(f"{identifier} -> {MERGEDDEV} stripped (closed-issue hygiene)")


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
        {"id": iss["id"], "b": _stamp_marker(text)})


# --- board protocol: who wrote a comment? (GSAI-41) ------------------------------
# The workspace has ONE Linear user, so every agent comment is posted as Vasanth.
# Authorship is told apart by MARKER, never by author. The contract, in one sentence:
#
#   An agent comment MUST carry a marker; an unmarked comment is Vas.
#
# A marker is any HTML comment in the body — `<!-- board-ask id:… by:Honey -->`,
# `<!-- board-mirror src:… -->`, `<!-- honey-preflight -->`, `<!-- fizz-sweep -->` …
# The old rule ("no `board-*` marker ⇒ Vas") read a Director's own `<!-- honey-preflight -->`
# as his answer and silently flipped a live question to board:responded (GSAI-29).
# So the match is deliberately BROAD: any `<!-- … -->` at all means "an agent wrote this".
# Over-matching leaves a real answer un-swapped for one awake (visible, on the Board);
# under-matching loses the question for good (invisible). Fail toward visible.
#
# GSAI-60: GSAI-41 fixed the READ side, but the WRITE side relied on every scripted
# poster remembering to mark — and none of them did. The Chief's 2026-09-08 sweep
# measured it live: 11 of 22 board issues had unmarked agent comments (the Dozer's
# claim/blocked/merged lines, the reaper's requeue note, run.sh's approvals) sitting
# after the last board-ask — 50 comments, each one an auto-approval under the rule
# above. Two defenses now:
#
#   WRITE side — comment() and _comment_url() are the ONLY commentCreate doors, and
#   both route the body through _stamp_marker(): any scripted comment that forgot its
#   marker self-identifies as `<!-- board-note by:<DOZER_COMMENT_BY> -->` before
#   posting. Forgetting the marker is impossible at the only door they all walk
#   through.
#
#   READ side — is_human_answer() adds a signature guard on top of the marker rule:
#   an unmarked comment whose opener matches AGENT_SIGNATURES (a pre-fix comment, an
#   LLM-authored comment that forgot its marker, a poster that bypassed comment()) is
#   REFUSED as an answer, loudly. Same asymmetry as the marker rule: over-refusing is
#   visible and recoverable by hand; under-refusing loses the question for good.
MARKER_RE = re.compile(r"<!--.*?-->", re.S)
ASK_RE = re.compile(r"<!--\s*board-ask\b[^>]*-->")

# Anchored on the EXACT openers the engine's scripted call sites emit
# (dozers/dozer.sh claim/blocked/merged lines, directors/run.sh ready, dozers/reaper.sh).
AGENT_SIGNATURES = [
    re.compile(r"^Dozer (claimed|blocked|merged|staged)\b"),   # dozers/dozer.sh status lines
    re.compile(r"^Director approved\b"),                        # directors/run.sh ready
    re.compile(r"^♻️ Reaper requeued\b"),                        # dozers/reaper.sh
]


def is_agent_comment(body):
    """True when the body carries ANY `<!-- … -->` marker — i.e. an agent wrote it."""
    return bool(MARKER_RE.search(body or ""))


def _stamp_marker(body):
    """Append `<!-- board-note by:<DOZER_COMMENT_BY:-dozer-engine> -->` to any body
    that carries no `<!-- … -->` marker at all. An already-marked body (board-ask,
    board-mirror, board-clear, a Director's own note) passes through BYTE-IDENTICAL —
    never double-stamped. The `by:` is provenance, not security; the default covers a
    future call site that forgets to set it. Read at call time so the three callers
    (dozer.sh → dozer-engine, reaper.sh → dozer-reaper, run.sh → director-cli) can
    name themselves with one export each."""
    body = body or ""
    if MARKER_RE.search(body):
        return body
    return f"{body}\n\n<!-- board-note by:{os.environ.get('DOZER_COMMENT_BY') or 'dozer-engine'} -->"


def _matching_signature(body):
    """The first agent signature an UNMARKED body matches, or None."""
    return next((s for s in AGENT_SIGNATURES if s.search(body or "")), None)


def is_human_answer(body):
    """The only comment the reconcile may read as Vas's answer: no marker AND no
    known agent signature."""
    body = body or ""
    return not is_agent_comment(body) and _matching_signature(body) is None


def _latest_ask(comments):
    """The newest `board-ask` marker comment (comments sorted by createdAt), or None."""
    asks = [c for c in comments if ASK_RE.search(c.get("body") or "")]
    return asks[-1] if asks else None


def board_answers(comments):
    """Vas's answers to the newest ask: every comment AFTER the latest `board-ask` that
    carries NO marker and NO known agent signature. Pure — takes the sorted comment
    list, no I/O.
    Returns (ask, answers, refused): ask is None when there is no board-ask at all.
    refused is [(comment, signature_pattern)] — unmarked comments the guard excluded;
    consumers surface them on stderr so a refusal is never silent."""
    comments = sorted(comments, key=lambda c: c["createdAt"])
    ask = _latest_ask(comments)
    if ask is None:
        return None, [], []
    later = [c for c in comments if c["createdAt"] > ask["createdAt"]]
    answers, refused = [], []
    for c in later:
        body = c.get("body") or ""
        if is_agent_comment(body):
            continue
        sig = _matching_signature(body)
        if sig:
            refused.append((c, sig.pattern))
        else:
            answers.append(c)
    return ask, answers, refused


def board_answer(identifier):
    """CLI: did Vas answer the newest board-ask on <issue>?  Read-only.
    stdout: one line per answer `<createdAt>\t<first line>` ; exit 0 = answered,
    3 = still waiting (nothing unmarked-and-human after the ask), 2 = no board-ask.
    A Director swaps board:to_review -> board:responded ONLY on exit 0.
    GSAI-60: an unmarked comment matching a known agent signature is REFUSED and named
    on stderr — if it genuinely is his answer, eyeball it and swap by hand."""
    ask, answers, refused = board_answers(_issue_comments(identifier))
    if ask is None:
        print(f"{identifier}: no board-ask marker on this issue", file=sys.stderr)
        sys.exit(2)
    for c, sig in refused:
        print(f"REFUSED: comment at {c['createdAt']} matches agent signature '{sig}' — "
              "not read as Vas's answer", file=sys.stderr)
    if not answers:
        print(f"{identifier}: waiting — no unmarked human comment after the ask at {ask['createdAt']}",
              file=sys.stderr)
        sys.exit(3)
    for c in answers:
        first = (c.get("body") or "").strip().splitlines()[0] if (c.get("body") or "").strip() else ""
        print(f"{c['createdAt']}\t{first}")


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
            {"id": iss["id"], "b": _stamp_marker(body)})
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
    # GSAI-41: "human" = no marker AT ALL, not merely "not ours" — a Director's own
    # marked comment (`<!-- honey-preflight -->`, another board-ask) is never Vas.
    # GSAI-60: AND no known agent signature — an unmarked "Dozer blocked…" status line
    # after the watchdog's ask must not hand the ball to board:responded.
    human = False
    if last_ask:
        for c in comments:
            if c["createdAt"] <= last_ask or is_agent_comment(c.get("body")):
                continue
            sig = _matching_signature(c.get("body"))
            if sig:
                print(f"REFUSED: comment at {c['createdAt']} matches agent signature "
                      f"'{sig.pattern}' — not read as the human answer", file=sys.stderr)
            else:
                human = True
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
    # Same predicate as list_ready — the watchdog must count exactly what the poll would
    # dispatch, or "alive but not dispatching" fires on a queue the Dozer cannot see.
    # GSAI-171: that now includes the KR gate. An un-laddered greenlit issue is work the
    # engine REFUSES, not work it is failing to get to, so counting it would alarm the
    # watchdog forever on a queue no drain will ever shorten. Read-only on purpose: the
    # log line and the refusal comment belong to list_ready, not to a health probe.
    print(sum(1 for i in _all_issues() if _is_ready(i) and _has_kr(i)))


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
    "list-merged-dev": lambda a: list_merged_dev(),
    "audit-requeue": lambda a: audit_requeue(a[0]),
    "audit-strip": lambda a: audit_strip(a[0]),
    "alarm-probe": lambda a: alarm_probe(a[0]),
    "alarm-raise": lambda a: alarm_raise(a[0], a[1]),
    "alarm-clear": lambda a: alarm_clear(a[0], a[1]),
    "count-ready": lambda a: count_ready(),
    "board-answer": lambda a: board_answer(a[0]),
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in OPS:
        die(f"usage: _linear_api.py <{'|'.join(OPS)}> [args]")
    OPS[sys.argv[1]](sys.argv[2:])
