# How Directors operate in Linear (shared cheat-sheet)

Every Director (Chief, Dev-Director, Mktg-Director) runs against **Linear**. This is
the concrete "how" — the labels/states are the contract; use whichever access you have
(**Linear MCP tools**, the **GraphQL API**, or the **`directors/run.sh` CLI**).

## The contract (labels + states)

| Meaning | In Linear |
|---|---|
| **Untriaged** (needs a decision) | issue with **no `lane:*` label** and **no `ready` label**, state not Done/Canceled |
| **Greenlit** (Dozer may run it) | labels **`ready`** + **`lane:dev`** or **`lane:marketing`** |
| Which repo (dev, multi-repo org) | label **`repo:<name>>`** e.g. `repo:cfw-social-v2` |
| **Claimed / running** | Dozer sets state **In Progress**, removes `ready` |
| **Needs your review** | label **`needs-review`** (marketing drafts staged; dev merged) |
| **Blocked** | label **`blocked`** |
| **Done** | state **Done** (dev after merge; marketing after you approve) |
| **OKR ladder** | issue belongs to a **Project** (Objective) + ideally a **Milestone** (KR), under an **Initiative** (Pillar) |

Team key = org: **CFW** = cfw-social, **LL** = learnloop.

## The operations (what you actually do)

- **Triage** → list your team's open issues; keep the ones with no lane + no ready.
- **Spec / brief** → write it into the issue **description** (this is your real work).
- **Ladder** → set the issue's **Project** (and Milestone) so it maps to an OKR.
  *No Project → do not greenlight; link it or drop it.*
- **Greenlight** → add labels `ready` + `lane:dev|lane:marketing` (+ `repo:` if dev).
- **Review** → read `needs-review` issues + the Dozer's summary comment / staged draft.
- **Approve** → remove `needs-review`, set state **Done**.
- **Send back** → add a comment with what's wrong; remove `ready` so it re-triages.
- **Escalate** → comment/assign to the **Chief** for anything above your authority.

## How to do each, by access method

**A) Linear MCP (Buzz-app agent's tools — preferred):** use the MCP's issue tools —
list/search issues (filter by team + labels), update an issue's labels, set its
Project/Milestone, set its workflow state, and create a comment. Map the operation
above to the matching MCP tool call.

**B) GraphQL API** (`https://api.linear.app/graphql`, header `Authorization: <key>`):
- greenlight: `issueUpdate(id, input:{ labelIds:[...] })` adding the `ready`+lane label ids
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
