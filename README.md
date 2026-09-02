# 🚜 Dozers

**A tiny, shareable operating system for an AI workforce. Directors decide; Dozers do.**

Dozers turns a task tracker (Linear, GitHub Issues, or a local file board) into an
autonomous work engine. A **Director** (an AI agent) reads your OKRs, writes a spec,
and **greenlights** a task with a label. A **Dozer** (a lean shell engine) claims it,
does the work in an isolated git worktree, and reports back — merging code or staging
content behind a human gate. No greenlight, no run.

It's deliberately small — a handful of bash + python files you can read in an
afternoon — but it does the real things: multi-project, parallel fan-out, crash
recovery, resume-after-crash, and a green-gated merge queue.

```
                        ┌───────────────────────────────────────────────┐
                        │  YOU  —  set OKRs, review, approve, promote     │
                        └───────────────────────┬───────────────────────┘
                                                │
   ╔══════════════════ DECIDE ═══════════════════▼════════════════════════════════╗
   ║  DIRECTORS  (AI agents — run in Buzz / Codex / Claude Code, one per org)       ║
   ║                                                                               ║
   ║     Chief ── governance, cross-team priorities, keeps the OKR tree honest     ║
   ║       ├── Dev-Director   triage → spec  → greenlight → review → promote        ║
   ║       └── Mktg-Director  triage → brief → greenlight → review staged draft     ║
   ╚═══════════════════════════════════╤═══════════════════════════════════════════╝
                                       │   the greenlight  =  dozer:ready + lane:<x>
                                       │   (the ONLY handoff — a label on the issue)
   ╔═══════════════════ CONTROL PLANE ═▼══════════════════════════════════════════╗
   ║  LINEAR   Initiative → Project → Milestone → Issue → Sub-issue                 ║
   ║  (Pillar)   (Objective)   (KR)     (Task)    (Sub-task)   · labels carry state ║
   ╚═══════════════════════════════════╤═══════════════════════════════════════════╝
                                       │   Dozer polls dozer:ready + lane, per team
   ╔═══════════════════ DO ════════════▼══════════════════════════════════════════╗
   ║  THE DOZER  (one process, all teams, ~8 parallel crews, atomic-locked)         ║
   ║                                                                               ║
   ║   lane:dev        worktree → agent → test → serial-merge (green-gated)         ║
   ║   lane:marketing  load voice → produce → stage draft → human approval gate     ║
   ║                                                                               ║
   ║   resilience:  reaper (crash recovery) · Seance (resume) · Refinery (merge Q)  ║
   ╚═══════════════════════════════════════════════════════════════════════════════╝

     backend plug:   Linear (default)   ·   GitHub Issues   ·   local files
```

---

## Why Dozers

Most agent frameworks either (a) run one clever agent that does everything, or (b) wake
agents on timers to "look for work" and burn tokens deciding. Dozers does neither:

- **Two tiers, one seam.** Deciding and doing never overlap. A Director *only* decides
  (and labels); a Dozer *only* executes (what's labeled). That single rule keeps the
  whole system easy to reason about — and cheap: **no LLM in the polling loop.**
- **Your tracker is the brain.** State lives in Linear (or GitHub) — the issue, its
  labels, its OKR links. No separate database to drift. Humans and agents see the same
  board.
- **You own it.** ~20 files of bash + python. No platform, no lock-in. Swap the backend
  by implementing a handful of functions.

---

## Quickstart

### See it work in 10 seconds (offline, zero setup)

```bash
git clone https://github.com/Vasanth19/dozers && cd dozers
./demo.sh
```

Uses the local file backend: files two tasks, a Director gives each a lane, the Dozer
drains both — a dev task through worktree→merge, a marketing task to a staged draft —
and prints what happened. That's the whole loop, offline, no API keys.

### Run it for real (Linear)

```bash
export LINEAR_API_KEY=lin_api_...            # or: source your secrets file
# edit org/config.yaml → linear_teams: "CFW,LL"  (your Linear team keys)

# 1) start the Dozer (the doer) — serves every configured team, in parallel:
dozers/dozer.sh loop

# 2) a Director greenlights work (or run one as a Buzz/Codex/Claude agent — see below):
directors/run.sh triage                       # see untriaged issues
directors/run.sh ready ENG-42 dev             # greenlight #ENG-42 into the dev lane
```

The Dozer picks up `ENG-42` within one poll, builds it in your repo's worktree, runs
the tests, serial-merges to `develop` (green-gated), and comments a summary on the issue.

---

## The core model

### The greenlight — the only handoff

Nothing runs until a Director puts **two labels** on an issue:

```
   dozer:ready   +   lane:dev            →   a Dozer will build it
   dozer:ready   +   lane:marketing      →   a Dozer will produce + stage it
```

That's it. A Director's entire power over a Dozer is that label. No spec, no ladder to
an OKR → no greenlight → no run.

### Two lanes, two crews

```
  lane:dev  ─────────────────────────────────────────────────────────────
     worktree dozer/<id>  →  coding agent implements + tests + commits
        →  test gate (red = stop)  →  serial-merge to develop (green-gated)
        →  Director promotes develop → main

  lane:marketing  ────────────────────────────────────────────────────────
     load brand voice  →  content agent produces the asset
        →  STAGE it to .dozers-review/  (never auto-published)
        →  issue flips to dozer:needs-review  →  a human approves
```

Add a lane by dropping a `dozers/<name>-lane/crew.sh` and greenlighting `lane:<name>`.

### OKR laddering

Every issue must ladder to a **Project** (Objective) / **Milestone** (KR) under an
**Initiative** (Pillar). Unlinked work is scope drift, not work — a Director won't
greenlight it.

### Workdir routing

The Dozer works *inside the target project's checkout*, resolved from your
`ecosystem.yaml` registry — most-specific first:

```
   repo:<id> label   →  that repo's path
   task's team/org    →  the org's default repo
   workdir_default    →  fallback
```

Paths live in one registry, never hardcoded in a label or in config.

---

## Resilience (the part that lets you walk away)

Dozers borrows the three patterns that make [gastown](https://github.com/gastownhall/gastown)
robust, kept lean:

```
  ┌── reaper / watchdog ───────────────────────────────────────────────┐
  │  A Dozer dies mid-task? Its lock goes stale; the reaper reclaims the │
  │  task (requeues it) and KILLS any runaway worker. `dozer.sh doctor`  │
  │  shows what's in-flight, alive or dead, and any orphaned worktrees.  │
  │  Every poll the loop also writes a heartbeat (last-poll ts + pid +   │
  │  in-flight count) so a watcher can see the engine is still looping.  │
  └─────────────────────────────────────────────────────────────────────┘

  ┌── Seance (resume) ─────────────────────────────────────────────────┐
  │  A crashed dev task's worktree persists with its committed work. On  │
  │  the next run the Dozer RESUMES it — continues from the prior commits│
  │  instead of restarting from scratch (saves time + tokens).           │
  └─────────────────────────────────────────────────────────────────────┘

  ┌── Refinery (green-gated merge queue) ──────────────────────────────┐
  │  Merges to develop are serialized per project (a merge lock), and    │
  │  each merge is re-tested ON develop. A merge that breaks it is        │
  │  reverted and the task sent back — develop stays green under fan-out. │
  └─────────────────────────────────────────────────────────────────────┘
```

---

## Directors — neutral AI agents, configured per org

The Director definitions are **org-neutral** — the *same* agent works for every org.
Each org gets its own **Buzz channel**, and that channel's **canvas** holds the org
config (`org`, `linear_team`, `lanes`, `repos`, `brand_voice`, `okr`). The Director
reads its canvas to learn which team to work. Add an org → new channel + canvas, **no
new agent code.**

```bash
# generate a paste-ready system prompt (persona + Linear how-to, always fresh):
directors/build-prompt.sh dev-director | pbcopy      # → paste into a Buzz/Codex/Claude agent
```

Run them in **Buzz** (heartbeat-driven, unattended), **Codex**, or **Claude Code** —
see [`BUZZ-SETUP.md`](BUZZ-SETUP.md) for the full runbook (heartbeat env, canvas, etc.).

---

## Label lifecycle

Directors and the Dozer coordinate entirely through labels on the issue:

```
 (untriaged)
     │  Director: spec it, ladder to a Project
     ▼
 dozer:ready + lane:*          ← the greenlight
     │  Dozer claims
     ▼
 dozer:in-progress
     ├── dev  ──► dozer:merged-develop ──► (Director) director:merged-main ──► Done
     ├── mktg ──► dozer:needs-review ─────► (human approves) ──────────────► Done
     └── fail ──► dozer:blocked   (Director fixes, re-greenlights)

 routing:  lane:dev · lane:marketing · repo:<id>
 director: director:triaged · director:changes-requested · director:merged-main
```

---

## Multi-team & fan-out

One Dozer process serves **all** your orgs and runs crews in parallel:

```yaml
# org/config.yaml
linear_teams: "CFW,LL,BRD,GSAI,DEL"   # every team, one process
fanout: 8                              # up to 8 crews at once
push: "false"                          # merges stay local until you say otherwise
```

Each parallel crew works in its own worktree; a per-project merge lock keeps `develop`
safe. A task from any team routes to that org's repo automatically.

---

## Repo layout

| Path | What it is |
|------|-----------|
| `dozers/dozer.sh` | The engine — poll → claim → route → run → report (`once` / `loop` / `doctor` / `recover` / `heartbeat`). |
| `dozers/reaper.sh` | Crash-recovery watchdog (stale locks, orphan requeue, runaway kill). |
| `dozers/dev-lane/` · `dozers/mktg-lane/` | Each lane's `crew.sh` + `dozer.md` persona. |
| `directors/` | The deciders: `chief.md` / `dev-director.md` / `mktg-director.md`, shared `LINEAR.md`, `build-prompt.sh`, `org-canvas.template.md`, `run.sh`. |
| `tasks/` | Pluggable backend: `adapter.sh` interface; `linear.sh` (default) / `github-issues.sh` / `files.sh`; `ecosystem_workdir.py`. |
| `org/config.yaml` | Teams, lanes, fan-out, integration branch, model command. |
| `AGENTS.md` · `BUZZ-SETUP.md` | The role map + the Buzz/Codex/Claude run guide. |

## Swap the backend

Directors and the Dozer only ever call a small set of functions
(`task_list_ready`, `task_claim`, `task_merged`, `task_review`, `task_block`,
`task_comment`, …). To move to Linear / a spreadsheet / your own store, implement those
in one file and point `backend:` at it. Nothing else changes.

---

## Status

Early but real. Marketing lane proven live on Linear; dev pipeline mechanics + all
resilience features (reaper, Seance, Refinery, doctor) tested. It succeeds an internal
scheduler on a Paperclip → Linear migration. Contributions and forks welcome.

## License

MIT.
