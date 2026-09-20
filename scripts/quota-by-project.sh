#!/usr/bin/env bash
# scripts/quota-by-project.sh — where the LLM quota actually went, by project (GSAI-175).
#
# The question this answers: "I don't know where all my quotas are going because there
# are so many projects." scripts/spend-by-kr.sh ranks Key Results by Dozer runs; this
# one ranks BUCKETS by the two quotas the factory actually burns — the Anthropic
# (Claude Code) cap and the Ollama Cloud request cap — in one table.
#
# ── The two sources, and why they are the only ones ─────────────────────────────
#
# 1. Claude Code session transcripts, ~/.claude/projects/<cwd-hash>/*.jsonl.
#    Every crew, every Director pass and every interactive session is a `claude -p`
#    (or interactive `claude`) run, and the ONLY durable per-message meter is the
#    transcript's assistant-message `usage` block. The crews throw the model's stderr
#    away (dev-lane/crew.sh, mktg-lane/crew.sh), so there is no other record.
#
#    Crucially the transcripts carry BOTH providers: org/config.yaml routes the dev
#    and marketing roles to provider `ollama-cloud`, which the crews reach by pointing
#    ANTHROPIC_BASE_URL at ollama.com. So one transcript can hold `claude-opus-5`
#    messages AND `kimi-k3:cloud` messages. We split them by model name:
#      * an Anthropic model  -> dollars against the Claude cap (list-price equivalent)
#      * anything else       -> ONE request against the Ollama monthly cap, which
#                               ollama.com meters as `request_count`, not tokens
#                               (GET https://ollama.com/api/usage -> limits.monthly).
#    `<synthetic>` messages are local harness text with no API call; they are skipped.
#
# 2. The Dozer loop log, ~/.dozers/logs/loop.out.log. Since GSAI-173 each finish line
#    carries `team= milestone="" project="" profile= duration_s= requests=`. That
#    `requests=` is the crew's own count of model calls for the run, and `project=` is
#    the exact Linear project — the strongest attribution there is. It is used ONLY
#    for buckets where it is present in the window; see "Never double-counted" below.
#
# ── The buckets, and the granularity ceiling ────────────────────────────────────
#
#   <Linear project>      a session in a worktree named <repo>-<ISSUE> — both the
#                         Dozer's ~/.dozers/worktrees/ and an orchestrator's
#                         ~/.claude-worktrees/. The ISSUE resolves to its Linear
#                         project through the map file (see --map). This is the only
#                         bucket that is a real project.
#   Director: <role>      a headless `claude -p /<role>-awake` pass out of
#                         ~/ecosystem (director-awake.sh). A Director pass spans
#                         every team it owns, so it is a ROLE, never a project.
#   interactive: <repo>   any other session, bucketed by the repo its cwd sat in.
#
#   *** THE CEILING: an interactive session maps to a REPO, and therefore to a team —
#   NOT to a single Linear project. Nothing in a Claude Code transcript says which
#   issue a human was thinking about. Only worktree-named sessions reach project
#   granularity. Do not read `interactive: <repo>` as "one project's spend". ***
#
#   (no project)          an issue-bearing session whose issue is not in the map.
#
# ── Never double-counted ────────────────────────────────────────────────────────
# Both sources meter the same Ollama calls. Per bucket the log wins when it has any
# data in the window, else the transcripts do — never the sum. The `src` column says
# which: `log` or `tx`. (Today every row is `tx`: the running loop predates GSAI-173,
# so no finish line carries `requests=` yet.)
#
# ── Usage ───────────────────────────────────────────────────────────────────────
#   scripts/quota-by-project.sh [--days N] [--json]
#     --days N          window, default 7
#     --json            machine output instead of the tables
#     --projects DIR    Claude Code transcript root (default ~/.claude/projects)
#     --log PATH        Dozer loop log (default ~/.dozers/logs/loop.out.log)
#     --map PATH        issue->project map (default ~/.dozers/cache/issue-project.tsv)
#     --ecosystem PATH  registry for repo->team (default ~/ecosystem/ecosystem.yaml)
#     --refresh-map     rebuild the map from Linear first (needs LINEAR_API_KEY)
#
# The map is a 3-column TSV `ISSUE<TAB>TEAM<TAB>PROJECT`. It is a CACHE: the report
# itself is offline and never calls Linear. Refresh it when projects change.
#
# Prices are Anthropic LIST price, so `$` reads as "how much of the subscription cap
# this ate", not an invoice. Rate table below, kept beside token-report.py's.
set -euo pipefail

DAYS=7
JSON=0
PROJECTS_DIR="$HOME/.claude/projects"
LOG="$HOME/.dozers/logs/loop.out.log"
MAP="$HOME/.dozers/cache/issue-project.tsv"
ECOSYSTEM="$HOME/ecosystem/ecosystem.yaml"
REFRESH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="${2:?--days needs a value}"; shift 2 ;;
    --days=*) DAYS="${1#*=}"; shift ;;
    --json) JSON=1; shift ;;
    --projects) PROJECTS_DIR="${2:?--projects needs a value}"; shift 2 ;;
    --projects=*) PROJECTS_DIR="${1#*=}"; shift ;;
    --log) LOG="${2:?--log needs a value}"; shift 2 ;;
    --log=*) LOG="${1#*=}"; shift ;;
    --map) MAP="${2:?--map needs a value}"; shift 2 ;;
    --map=*) MAP="${1#*=}"; shift ;;
    --ecosystem) ECOSYSTEM="${2:?--ecosystem needs a value}"; shift 2 ;;
    --ecosystem=*) ECOSYSTEM="${1#*=}"; shift ;;
    --refresh-map) REFRESH=1; shift ;;
    -h|--help)
      sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "quota-by-project.sh: unknown argument '$1' (see --help)" >&2; exit 1 ;;
  esac
done

[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "quota-by-project.sh: --days must be a non-negative integer, got '$DAYS'" >&2; exit 1; }
[[ -d "$PROJECTS_DIR" ]] || { echo "quota-by-project.sh: cannot read transcripts dir '$PROJECTS_DIR'" >&2; exit 1; }

# ── --refresh-map: one Linear GraphQL round-trip, issue identifier -> project name ──
# Deliberately separate from the report: the digest runs offline, and a report that
# silently reached the network would be a different thing than the one under test.
if (( REFRESH )); then
  : "${LINEAR_API_KEY:?--refresh-map needs LINEAR_API_KEY in the environment (source ~/ecosystem/vault/linear.env)}"
  mkdir -p "$(dirname "$MAP")"
  python3 - "$MAP" <<'PY'
import json, os, sys, urllib.request
out = sys.argv[1]
key = os.environ["LINEAR_API_KEY"]
q = """query($after:String){ issues(first:250, after:$after){
  pageInfo{ hasNextPage endCursor }
  nodes{ identifier team{ key } project{ name } } } }"""
rows, after = [], None
while True:
    req = urllib.request.Request(
        "https://api.linear.app/graphql",
        data=json.dumps({"query": q, "variables": {"after": after}}).encode(),
        headers={"Authorization": key, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as fh:
        d = json.load(fh)
    if "errors" in d:
        sys.exit("quota-by-project.sh: Linear refused the map query: %s" % d["errors"])
    page = d["data"]["issues"]
    for n in page["nodes"]:
        rows.append((n["identifier"], (n.get("team") or {}).get("key") or "",
                     (n.get("project") or {}).get("name") or ""))
    if not page["pageInfo"]["hasNextPage"]:
        break
    after = page["pageInfo"]["endCursor"]
tmp = out + ".tmp"
with open(tmp, "w") as fh:
    for r in rows:
        fh.write("\t".join(r) + "\n")
os.replace(tmp, out)
print("quota-by-project.sh: wrote %d issue->project rows to %s" % (len(rows), out), file=sys.stderr)
PY
fi

QBP_DAYS="$DAYS" QBP_JSON="$JSON" QBP_PROJECTS="$PROJECTS_DIR" QBP_LOG="$LOG" \
QBP_MAP="$MAP" QBP_ECOSYSTEM="$ECOSYSTEM" python3 - <<'PY'
import glob, json, os, re, sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

DAYS      = int(os.environ["QBP_DAYS"])
AS_JSON   = os.environ["QBP_JSON"] == "1"
PROJECTS  = os.environ["QBP_PROJECTS"]
LOG       = os.environ["QBP_LOG"]
MAPFILE   = os.environ["QBP_MAP"]
ECOSYSTEM = os.environ["QBP_ECOSYSTEM"]

now    = datetime.now(timezone.utc)
since  = now - timedelta(days=DAYS)
cutoff = since.timestamp()

# ── prices: $/MTok (input, output), Anthropic list. Cache write 5m = 1.25x input,
# 1h = 2x, cache read = 0.1x — the standard Anthropic multipliers. Same table as
# ~/ecosystem/scripts/token-report.py; keep the two in step.
PRICES = {
    "claude-fable-5-1": (10.0, 50.0), "claude-fable-5": (10.0, 50.0),
    "claude-opus-5": (5.0, 25.0), "claude-opus-4-8": (5.0, 25.0),
    "claude-opus-4-7": (5.0, 25.0), "claude-opus-4-6": (5.0, 25.0),
    "claude-sonnet-5": (2.0, 10.0), "claude-sonnet-4-6": (3.0, 15.0),
    "claude-sonnet-4-5": (3.0, 15.0), "claude-haiku-4-5": (1.0, 5.0),
}

def is_anthropic(model):
    return bool(model) and model.startswith("claude-")

def price(model):
    m = re.sub(r"-\d{8}$", "", model or "")
    if m in PRICES:
        return PRICES[m]
    for k, v in PRICES.items():
        if m.startswith(k):
            return v
    if "haiku" in m:  return PRICES["claude-haiku-4-5"]
    if "sonnet" in m: return PRICES["claude-sonnet-5"]
    if "opus" in m:   return PRICES["claude-opus-5"]
    return (0.0, 0.0)   # an unknown claude-* model: counted in tokens, $0 rather than a guess

# ── issue -> (team, project) map (a cache; see --refresh-map) ───────────────────
ISSUE_MAP = {}
if os.path.exists(MAPFILE):
    with open(MAPFILE, errors="replace") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3 and parts[0]:
                ISSUE_MAP[parts[0]] = (parts[1], parts[2])
else:
    # Not fatal — the report still stands up, every issue just lands in "(no project)",
    # which is the one failure mode that would make the table look like the factory has
    # no projects rather than like the map is missing. So say it out loud.
    print("quota-by-project.sh: no issue->project map at %s — every issue-bearing "
          "session will show as '(no project)'. Build it with --refresh-map." % MAPFILE,
          file=sys.stderr)

# ── repo -> team, from the registry (orgs[].linear_team + projects[].local) ─────
# Parsed with a tolerant line reader rather than PyYAML: the registry is a plain
# mapping/list file and the report must not depend on a pip install to run.
#
# REPO_TEAM maps a repo's basename to its Linear team. ENCODED is the same set keyed
# by the *encoded* cwd, because a ~/.claude/projects dirname is the cwd with every
# non-alphanumeric byte replaced by '-'. That encoding is LOSSY and ambiguous — both
# '/' and '-' become '-', so "…-cfw-cfw-social" could split as cfw/cfw-social or
# cfw-cfw/social. Guessing by the last '-' segment gets "social". Matching the
# longest known registry path instead gets "cfw-social", and with it the right team.
REPO_TEAM = {}
ENCODED = {}

def encode_path(p):
    return re.sub(r"[^A-Za-z0-9]", "-", p.rstrip("/"))
def load_registry(path):
    if not os.path.exists(path):
        return
    text = open(path, errors="replace").read()
    org_team, org, in_orgs = {}, None, False
    for line in text.splitlines():
        if re.match(r"^[A-Za-z_]", line):
            in_orgs = line.startswith("orgs:")
            continue
        if in_orgs:
            m = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
            if m:
                org = m.group(1); continue
            m = re.match(r"^\s+linear_team:\s*['\"]?([A-Za-z]+)", line)
            if m and org:
                org_team[org] = m.group(1)
    # projects: list entries, each with local: and org:
    cur = {}
    def flush(c):
        if not c.get("local"):
            return
        local = c["local"].rstrip("/")
        repo = os.path.basename(local)
        team = org_team.get(c.get("org", ""), "")
        REPO_TEAM.setdefault(repo, team)
        ENCODED.setdefault(encode_path(local), (repo, team))
    for line in text.splitlines():
        if re.match(r"^\s*-\s", line) or re.match(r"^[A-Za-z_]", line):
            flush(cur); cur = {}
        m = re.match(r"^\s*-?\s*local:\s*['\"]?([^'\"\s]+)", line)
        if m: cur["local"] = m.group(1)
        m = re.match(r"^\s*-?\s*org:\s*['\"]?([A-Za-z0-9_]+)", line)
        if m: cur["org"] = m.group(1)
    flush(cur)
load_registry(ECOSYSTEM)

# ── classify a ~/.claude/projects/<dirname> ────────────────────────────────────
# The dirname is the cwd with every '/' turned into '-', so a literal '-' in a path
# doubles. Worktree roots: ~/.dozers/worktrees (the Dozer) and ~/.claude-worktrees
# (orchestrator sessions) — both name their dirs <repo>-<ISSUE>.
WT_DOZER  = re.compile(r"^-Users-vasanth--dozers-worktrees-(.+)$")
WT_ORCH   = re.compile(r"^-Users-vasanth--claude-worktrees-(.+)$")
ISSUE_TAIL = re.compile(r"^(.*?)-([A-Z]{2,5}-\d+)$")
# A launchd Director pass (director-awake.sh) is `claude -p /<role>-awake` out of
# ~/ecosystem, and leaves the expanded slash command as a <command-name> block.
CMD = re.compile(r"<command-name>/((?:chief|dev-director|mktg-director|ops-director))-awake</command-name>")
# The OTHER Director runtime (WAYS-OF-WORKING §1): a Buzz-hosted agent, woken by an
# hourly heartbeat out of ~/.buzz. No slash command — its first user turn is the tick
# prompt. Same personas, a second meter; they are kept as separate rows on purpose,
# because two runtimes running the same Director is exactly the kind of duplicated
# spend this report exists to surface.
BUZZ_DIR  = "-Users-vasanth--buzz"
TICK = re.compile(r"scheduled\s+(Chief|Dev-Director|Mktg-Director|Ops-Director)\s+tick", re.I)
# Throwaway scratch/tmp cwds (render scratch, agent scratchpads, mktemp dirs). Each is
# a one-off directory name that will never be seen again, so they are rolled into one
# row rather than filling the table with noise.
SCRATCH = re.compile(r"^-(private-tmp|private-var-folders|tmp)\b")

def repo_of(dirname):
    """The repo a session's cwd sat in -> (repo, team).

    Longest known registry path first (exact, unambiguous); only if nothing in the
    registry matches does it fall back to the last '-' segment, which is a guess."""
    best = None
    for enc, (repo, team) in ENCODED.items():
        if dirname == enc or dirname.startswith(enc + "-"):
            if best is None or len(enc) > len(best[0]):
                best = (enc, repo, team)
    if best:
        return best[1], best[2]
    tail = dirname.split("-Users-vasanth-", 1)[-1] if dirname.startswith("-Users-vasanth-") else dirname
    guess = tail.split("-")[-1] or dirname
    return guess, REPO_TEAM.get(guess, "")

def classify_dir(dirname):
    """-> ('issue', ISSUE) | ('repo', (repo, team))."""
    for rx in (WT_DOZER, WT_ORCH):
        m = rx.match(dirname)
        if m:
            tail = m.group(1)
            mi = ISSUE_TAIL.match(tail)
            if mi:
                return ("issue", mi.group(2))
            # a worktree with no issue in its name: still just a repo checkout
            head = tail.split("-")[0]
            return ("repo", (tail, REPO_TEAM.get(tail) or REPO_TEAM.get(head, "")))
    return ("repo", repo_of(dirname))

def head_of(path):
    try:
        with open(path, errors="replace") as fh:
            return fh.read(200_000)
    except OSError:
        return ""

def bucket_for(dirname, path):
    kind, key = classify_dir(dirname)
    if kind == "issue":
        team, proj = ISSUE_MAP.get(key, ("", ""))
        if not team:
            team = key.split("-")[0]
        if proj:
            return (proj, team)
        return ("(no project)", team)
    if dirname == "-Users-vasanth-ecosystem":
        m = CMD.search(head_of(path))
        if m:
            return ("Director: " + m.group(1), "")
    if dirname == BUZZ_DIR or dirname.startswith(BUZZ_DIR + "-"):
        m = TICK.search(head_of(path))
        if m:
            return ("Director: " + m.group(1).lower() + " (buzz)", "")
        # A Buzz session whose tick prompt does not name a role — still the Buzz
        # agent runtime, still not a project, and too big to quietly call
        # "interactive". Named for what it is.
        return ("Buzz agents (role unlabelled)", "")
    if SCRATCH.match(dirname):
        return ("scratch/tmp cwds", "")
    repo, team = key
    return ("interactive: " + repo, team)

# ── scan the transcripts ───────────────────────────────────────────────────────
class Acc:
    __slots__ = ("team", "usd", "toks", "calls", "oll_tx", "oll_log", "sessions")
    def __init__(self):
        self.team = ""; self.usd = 0.0; self.toks = 0; self.calls = 0
        self.oll_tx = 0; self.oll_log = 0; self.sessions = set()

acc = defaultdict(Acc)

def scan(path):
    """Yield (model, usage) per unique assistant API response inside the window."""
    seen = set()
    try:
        fh = open(path, errors="replace")
    except OSError:
        return
    with fh:
        for line in fh:
            if '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") != "assistant":
                continue
            msg = d.get("message") or {}
            u = msg.get("usage")
            if not isinstance(u, dict):
                continue
            mid = msg.get("id") or d.get("requestId") or d.get("uuid")
            if mid in seen:
                continue
            seen.add(mid)
            ts = d.get("timestamp")
            if ts:
                try:
                    if datetime.fromisoformat(ts.replace("Z", "+00:00")) < since:
                        continue
                except Exception:
                    pass
            yield msg.get("model") or "unknown", u

for dirname in sorted(os.listdir(PROJECTS)):
    full = os.path.join(PROJECTS, dirname)
    if not os.path.isdir(full):
        continue
    for f in sorted(glob.glob(os.path.join(full, "*.jsonl"))):
        name, team = bucket_for(dirname, f)
        a = acc[name]
        if team and not a.team:
            a.team = team
        for model, u in scan(f):
            if model == "<synthetic>":
                continue          # local harness text, never an API call
            a.sessions.add(f)
            if is_anthropic(model):
                cc  = u.get("cache_creation") or {}
                inp = u.get("input_tokens", 0)
                out = u.get("output_tokens", 0)
                cw5 = cc.get("ephemeral_5m_input_tokens", 0)
                cw1 = cc.get("ephemeral_1h_input_tokens", 0)
                if not cc:
                    cw5 += u.get("cache_creation_input_tokens", 0)
                crd = u.get("cache_read_input_tokens", 0)
                pin, pout = price(model)
                a.usd += (inp * pin + cw5 * pin * 1.25 + cw1 * pin * 2.0
                          + crd * pin * 0.10 + out * pout) / 1e6
                a.toks += inp + out + cw5 + cw1 + crd
                a.calls += 1
            else:
                # ollama.com meters the monthly cap in requests, not tokens.
                a.oll_tx += 1

# ── the Dozer loop log: the strongest attribution when it is there ─────────────
# Same finish-line shape scripts/spend-by-kr.sh parses (GSAI-173).
FIN = re.compile(r"^  (?:ok|x) #")
def field(line, key):
    m = re.search(key + r'="([^"]*)"', line)
    if m: return m.group(1)
    # NOT [^ ]* — a negated class matches '\n' too, so the LAST field on the line
    # would come back as "77\n" and fail every numeric test. Callers strip the line,
    # but pin it here as well so this helper is correct on its own.
    m = re.search(key + r"=([^\s]*)", line)
    return m.group(1) if m else None

if os.path.exists(LOG):
    with open(LOG, errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not FIN.match(line) or "profile=" not in line:
                continue
            ts = field(line, "ts")
            if ts and ts.isdigit() and int(ts) < cutoff:
                continue
            req = field(line, "requests")
            proj = field(line, "project") or ""
            if not proj or not req or not req.isdigit():
                continue
            a = acc[proj]
            if not a.team:
                a.team = field(line, "team") or ""
            a.oll_log += int(req)

# Per bucket: the log wins when it has any data in the window, else the transcripts.
# Never the sum — both meter the same calls.
rows = []
for name, a in acc.items():
    src = "log" if a.oll_log else ("tx" if a.oll_tx else "-")
    oll = a.oll_log if a.oll_log else a.oll_tx
    if not (a.usd or a.toks or oll):
        continue
    rows.append({"bucket": name, "team": a.team, "claude_usd": round(a.usd, 2),
                 "claude_tokens": a.toks, "claude_calls": a.calls,
                 "ollama_requests": oll, "ollama_source": src,
                 "sessions": len(a.sessions)})

rows.sort(key=lambda r: (-r["claude_usd"], -r["ollama_requests"], r["bucket"]))

tot_usd = sum(r["claude_usd"] for r in rows)
tot_tok = sum(r["claude_tokens"] for r in rows)
tot_oll = sum(r["ollama_requests"] for r in rows)

teams = defaultdict(lambda: {"claude_usd": 0.0, "claude_tokens": 0, "ollama_requests": 0, "buckets": 0})
for r in rows:
    t = teams[r["team"] or "(unattributed)"]
    t["claude_usd"] += r["claude_usd"]; t["claude_tokens"] += r["claude_tokens"]
    t["ollama_requests"] += r["ollama_requests"]; t["buckets"] += 1
team_rows = sorted(teams.items(), key=lambda kv: (-kv[1]["claude_usd"], -kv[1]["ollama_requests"]))

top3 = rows[:3]
top3_usd = sum(r["claude_usd"] for r in top3)
top3_share = (top3_usd / tot_usd * 100) if tot_usd else 0.0

if AS_JSON:
    print(json.dumps({
        "days": DAYS, "generated_at": now.isoformat(),
        "sources": {"transcripts": PROJECTS, "loop_log": LOG, "issue_map": MAPFILE},
        "totals": {"claude_usd": round(tot_usd, 2), "claude_tokens": tot_tok,
                   "ollama_requests": tot_oll},
        "top3_claude_usd_share_pct": round(top3_share, 1),
        "buckets": rows,
        "teams": [{"team": k, "claude_usd": round(v["claude_usd"], 2),
                   "claude_tokens": v["claude_tokens"],
                   "ollama_requests": v["ollama_requests"], "buckets": v["buckets"]}
                  for k, v in team_rows],
    }, indent=2))
    sys.exit(0)

if not rows:
    print("quota-by-project.sh: no model usage found in the last %dd under %s" % (DAYS, PROJECTS))
    sys.exit(0)

def fm(n):
    for unit, div in (("B", 1e9), ("M", 1e6), ("K", 1e3)):
        if n >= div:
            return "%.1f%s" % (n / div, unit)
    return str(int(n))

print("Quota by project — last %dd" % DAYS)
print("%-40s | %-5s | %9s | %6s | %13s | %10s | %5s | %6s"
      % ("Bucket", "Team", "Claude $", "share", "Claude tokens", "Ollama req", "src", "share"))
print("-" * 118)
for r in rows:
    cs = (r["claude_usd"] / tot_usd * 100) if tot_usd else 0.0
    os_ = (r["ollama_requests"] / tot_oll * 100) if tot_oll else 0.0
    print("%-40s | %-5s | %9s | %5.1f%% | %13s | %10s | %5s | %5.1f%%"
          % (r["bucket"][:40], (r["team"] or "—")[:5],
             ("$%.2f" % r["claude_usd"]) if r["claude_usd"] else "—",
             cs, fm(r["claude_tokens"]) if r["claude_tokens"] else "—",
             r["ollama_requests"] or "—", r["ollama_source"], os_))
print("-" * 118)
print("%-40s | %-5s | %9s | %5.1f%% | %13s | %10s | %5s | %5.1f%%"
      % ("TOTAL", "", "$%.2f" % tot_usd, 100.0, fm(tot_tok), tot_oll, "", 100.0))

print()
print("By Linear team")
print("%-16s | %9s | %6s | %13s | %10s | %7s" % ("Team", "Claude $", "share", "Claude tokens", "Ollama req", "buckets"))
print("-" * 76)
for k, v in team_rows:
    cs = (v["claude_usd"] / tot_usd * 100) if tot_usd else 0.0
    print("%-16s | %9s | %5.1f%% | %13s | %10s | %7d"
          % (k[:16], "$%.2f" % v["claude_usd"], cs, fm(v["claude_tokens"]),
             v["ollama_requests"] or "—", v["buckets"]))

print()
print("Top 3 buckets = %.0f%% of all Claude $ (%s)"
      % (top3_share, ", ".join(r["bucket"] for r in top3)))
over = [r for r in rows if tot_usd and r["claude_usd"] / tot_usd > 0.40]
for r in over:
    print("⚠ %s is %.0f%% of all Claude $ on its own — over the 40%% concentration line."
          % (r["bucket"], r["claude_usd"] / tot_usd * 100))
print()
print("src: `log` = Dozer loop log requests= (GSAI-173, exact per-run count); "
      "`tx` = counted from the transcripts. Never both — they meter the same calls.")
print("Ceiling: `interactive: <repo>` is repo-level, not project-level — a transcript "
      "does not record which issue a human had in mind.")
PY
