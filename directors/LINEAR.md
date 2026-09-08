# How Directors operate in Linear (shared cheat-sheet)

## Your org context comes from the channel canvas (Buzz)

You are **neutral** — not tied to any one org. In Buzz you run **one channel per org**,
and that channel's **canvas** holds the org's config. **Read the canvas first, every
time**, to learn who you're working for:

| Canvas field | You use it to… |
|---|---|
| `org` | know the org name |
| `linear_team` | the **Linear team key** you operate on (e.g. `LL`) — touch only this team |
| `lanes` | which lanes this org runs (dev / marketing) |
| `repos` | repo names for dev `repo:<name>` hints |
| `brand_voice` | write on-voice marketing briefs |
| `okr` | where this org's OKRs live (Linear Initiative → Projects → Milestones) |
| `escalate_to` | who to escalate above your authority |

If the canvas is missing or unclear, **ask in the channel** — do not guess the team.

## Where work that needs a human goes (Buzz)

Anything that needs a human's attention — a draft to review, a decision, a blocker —
is **posted in the matching Buzz channel**, brand/topic-scoped. Resolve the channel
**live** from `~/ecosystem/ecosystem.yaml` → `buzz.channels` — match the issue's
team/brand to the channel whose `org`/`brand` field points at it. Never hardcode a
channel name; the org/brand list changes. DMs only for 1:1. A file in `OUTBOX/`,
`board/review/`, or any folder is **unmonitored** — it is storage, never the
notification. If you didn't post it in the right channel, it does not have their
attention. Post the **actual thing** (full draft inline), not a pointer to it.

## Board protocol — how Vas's answers come back

Linear is the truth; Buzz `#now` and `~/ecosystem/board/` are mirrors. The workspace has **one Linear user
(Vasanth) — every agent posts as him** — so tell authors apart by **marker text, never by author**. Vas watches
the shared views **Board** (`board:to_review`, https://linear.app/hyphenlabs/view/f849a4eaf123) and
**Board · responded** (https://linear.app/hyphenlabs/view/80bf520dbb90).

**To ASK Vas** (only a real decision/approval — never a status ping): comment on the issue, first line
`@Vas <question> — options: (a) … (b) …`, last line the marker `<!-- board-ask id:<ISO-8601> by:<your name> -->`.
Add label **`board:to_review`**. Then one line in `#now` (Buzz runtime: post via your channel tools; Claude
runtime: the CLI, your own key from `~/ecosystem/vault/buzz.env`):
`buzz messages send --channel f7ce192b-e3b7-45de-8381-2655be88e16a --content "@Vas <ID> needs you: <10 words> https://linear.app/hyphenlabs/issue/<ID>" --mention 1f8aa6ede67072da16118b2886c60bbd999624ba5da61364e2398ce804c4d3ae`
An **artifact to judge** also gets `ln -s <abs-path> ~/ecosystem/board/review/<ID>-<slug>`. Keep your marker id — it is how you find the answer.

**Every awake, reconcile FIRST — before triage.** For each issue you own with `board:to_review`:
1. Read its comments. Find your newest `board-ask` marker. Any **later** comment carrying **no `board-*` marker**
   is Vas's answer → swap `board:to_review` → **`board:responded`**, post one ack line in `#now`,
   `rm -f ~/ecosystem/board/review/<ID>-*` and `mv ~/ecosystem/board/inbox/*<ID>*.md ~/ecosystem/board/inbox/_done/`.
2. No later unmarked comment → leave it alone. Never re-ping, never re-ask.

**Pull in answers he typed elsewhere** (same awake, run before step 1):
- `buzz messages get --channel f7ce192b-… --since <last awake>` → each message from **Vas** (`1f8aa6ed…`) matching
  `[A-Z]{2,5}-[0-9]+` becomes a Linear comment on that issue: `(via Buzz #now) <text>` + `<!-- board-mirror src:buzz/<event-id> -->`.
- Each `~/ecosystem/board/inbox/*.md` whose front matter has `issue: <ID>` becomes `(via board/inbox) <body>` +
  `<!-- board-mirror src:inbox/<filename> -->`, then `mv` the card into `board/inbox/_done/`.
- **Idempotent:** skip anything whose `src:` already appears in the issue's comments — never mirror twice. A mirrored comment counts as Vas's answer → run the swap in step 1.

**Act on every `board:responded` issue you own in the same awake** — progress it, re-greenlight the Dozer, or ask
again (fresh `board-ask` + `board:to_review`) — then **remove `board:responded`**. Nothing may sit there across two awakes.

---


Every Director (Chief, Dev-Director, Mktg-Director) runs against **Linear**. This is
the concrete "how" — the labels/states are the contract; use whichever access you have
(**Linear MCP tools**, the **GraphQL API**, or the **`directors/run.sh` CLI**).

## The contract (labels + states)

| Meaning | In Linear |
|---|---|
| **Untriaged** (needs a decision) | issue with **no `lane:*` label** and **no `dozer:ready` label**, state not Done/Canceled |
| **Greenlit** (Dozer may run it) | labels **`dozer:ready`** + **`lane:dev`**, **`lane:marketing`** or **`lane:ops`** |
| Which repo (dev, multi-repo org) | label **`repo:<name>>`** e.g. `repo:cfw-social-v2` |
| **Claimed / running** | Dozer swaps `dozer:ready` → **`dozer:in-progress`**, state In Progress |
| **Dev merged to develop** | **`dozer:merged-develop`** (Dozer's terminal; you then promote) |
| **Needs your review** | label **`dozer:needs-review`** (marketing drafts staged; dev merged) |
| **Blocked** | label **`dozer:blocked`** |
| **Done** | state **Done** — dev after **you promote develop→main (`director:merged-main`)**; marketing after you approve |
| **Your decision labels** | `director:triaged`, `director:changes-requested`, `director:merged-main` |
| **Waiting on Vas** | label **`board:to_review`** — see *Board protocol* above; shows in the shared **Board** view |
| **Vas answered** | label **`board:responded`** — you must act on it in the same awake, then remove it |
| **OKR ladder** | issue belongs to a **Project** (Objective) + ideally a **Milestone** (KR), under an **Initiative** (Pillar) |

Team keys (live in Linear): **CFW** = cfw-social · **LL** = learnloop · **BRD** = brands ·
**GSAI** = gsai/agency · **DLY** = delivery (some docs still say "DEL" — the live key is `DLY`).

## The operations (what you actually do)

- **Triage** → list your team's open issues; keep the ones with no `lane:*` + no `dozer:ready`.
- **Spec / brief** → write it into the issue **description** (this is your real work).
- **Ladder** → set the issue's **Project** (and Milestone) so it maps to an OKR.
  *No Project → do not greenlight; link it or drop it.*
- **Greenlight** → add labels `dozer:ready` + `lane:dev|lane:marketing|lane:ops` (+ `repo:` if it touches a repo).
- **Review** → read `dozer:needs-review` issues + the Dozer's summary comment / staged draft.
- **Approve (mktg)** → remove `dozer:needs-review`, set state **Done**.
- **Promote (dev)** → after `dozer:merged-develop`, merge develop→main, set `director:merged-main` → **Done**.
- **Send back** → comment what's wrong, set `director:changes-requested`, remove `dozer:ready` so it re-triages.
- **Escalate** → comment/assign to the **Chief** for anything above your authority.

## How to do each, by access method

**A) Linear MCP (Buzz-app agent's tools — preferred):** use the MCP's issue tools —
list/search issues (filter by team + labels), update an issue's labels, set its
Project/Milestone, set its workflow state, and create a comment. Map the operation
above to the matching MCP tool call.

**B) GraphQL API** (`https://api.linear.app/graphql`, header `Authorization: <key>`):
- greenlight: `issueUpdate(id, input:{ labelIds:[...] })` adding the `dozer:ready`+lane label ids
- set project/milestone: `issueUpdate(id, input:{ projectId, projectMilestoneId })`
- set state: `issueUpdate(id, input:{ stateId })`   • comment: `commentCreate(input:{ issueId, body })`
- find untriaged: `issues(filter:{ team:{key:{eq:"CFW"}} })` then filter labels client-side

**C) `directors/run.sh` CLI** (if you have this repo checked out + `LINEAR_API_KEY`):
- `directors/run.sh triage` — list untriaged
- `directors/run.sh ready <ISSUE-ID> dev|marketing` — greenlight
- `directors/run.sh note <ISSUE-ID> "<text>"` — comment

## The rule that never bends

You **decide and label**; you never execute. Greenlighting an issue is a Dozer's cue
to run it — so only greenlight what's specced and laddered to an OKR.
