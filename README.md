# dozers

A tiny, shareable operating system for one organization's AI work. **Directors
decide; Dozers do.** A single label — `ready` + a lane — is the greenlight that wakes a
Dozer: the only handoff between deciding and doing. No greenlight, no run.

It's deliberately small: clone it, change one config value, and you have a working
agent org. The task backend is a *plug* — **Linear by default** (native OKR tree),
with GitHub Issues or a zero-dependency local file board as alternatives.

```
              ┌─────────────────────────────────────────────┐
              │  YOU (the Keeper) — file work, review results │
              └───────────────────────┬─────────────────────┘
                                      │
   ╔═══════════════ DECIDE (Directors) ═▼══════════════════════╗
   ║   Chief          governs · OKRs · priorities            ║
   ║     ├─ Dev-Director     triage → spec → review  (lane:dev) ║
   ║     └─ Mktg-Director    brief  → review    (lane:marketing)║
   ╚═══════════════════════════╤═════════════════════════════╝
                               │  the greenlight:  ready + lane:<x>
                               ▼        ── the only handoff ──
   ╔═══════════════ DO (Dozers) ═══════▼══════════════════════╗
   ║   Dozer engine   polls ready+lane → claims → runs a crew  ║
   ║   ┌────────────────────┐   ┌───────────────────────────┐ ║
   ║   │ lane:dev           │   │ lane:marketing            │ ║
   ║   │ worktree→build→test│   │ produce → human approval  │ ║
   ║   └────────────────────┘   └───────────────────────────┘ ║
   ╚══════════════════════════════════════════════════════════╝

   task backend (the plug):  GitHub Issues  ·  local files  ·  your own
```

**Agent instructions** for every role live in [`AGENTS.md`](AGENTS.md) →
`directors/*.md` (the deciders) and `dozers/*.md` (the doers).

## See it work in 5 seconds (no setup)

```bash
./demo.sh
```

Runs the local file backend: files two tasks, a Director gives each a lane, the
Dozer drains both and produces artifacts. That's the entire loop, offline.

## Use it for real (GitHub Issues)

1. Edit `org/config.yaml` → set `repo: your-owner/your-repo` (backend is already `github`).
2. `gh auth login` (once), then `./setup.sh` to create the labels.
3. Open an issue describing a task.
4. A **Director** triages and approves:
   ```bash
   directors/run.sh triage            # see untriaged work
   directors/run.sh ready 42 dev       # approve #42 into the dev lane (the greenlight)
   ```
5. A **Dozer** executes:
   ```bash
   dozers/dozer.sh once              # drain now
   # or dozers/dozer.sh loop          — keep draining
   # or let .github/workflows/dozer.yml run it every 15 min in the cloud
   ```

## Run the deciders as AI agents (Buzz · Codex · Claude Code)

Two things run:

- **The Dozer** (does) is just a shell loop — run it anywhere:
  `"$DOZERS_HOME"/dozers/dozer.sh loop` (serve many orgs at once via `linear_teams`,
  run crews in parallel via `fanout`). It needs `LINEAR_API_KEY` exported.
- **The Directors** (decide) are AI agents — run **one per role/team**, each loaded
  with its persona **plus** [`directors/LINEAR.md`](directors/LINEAR.md), and given
  **Linear access** (Linear MCP, or `LINEAR_API_KEY`).

> Agents only get the text you paste in — a linked file isn't auto-loaded. So
> concatenate the two: `"$DOZERS_HOME"/directors/build-prompt.sh <role>`
> becomes the agent's system prompt.

**Set the repo location first** (agents run from anywhere, so use absolute paths):

```bash
export DOZERS_HOME=~/Code/dozers   # absolute path to this repo
export LINEAR_API_KEY=...                         # e.g. source your vault
```

### Buzz (heartbeat-driven, unattended)

Register each Director as a Buzz agent whose system prompt is the merged
persona + `LINEAR.md`, then let the heartbeat wake it to work its board:

```bash
BUZZ_ACP_HEARTBEAT_INTERVAL=1200
BUZZ_ACP_HEARTBEAT_PROMPT="You are the Director for your team. Check your board (the Linear team your Dozer drains): triage untriaged issues — spec them and greenlight ready+lane — and review anything labeled needs-review (approve, or send back with a note). Act per your persona and directors/LINEAR.md; never execute, only decide."
```

Run one Buzz Director per role/team (e.g. a Dev-Director scoped to team `CFW`). Point
a Dozer at the same teams (`dozers/dozer.sh loop`) and it drains what they greenlight.

### Codex / Claude Code (scripted or interactive)

Load a Director as a headless agent with the persona + `LINEAR.md` and Linear access,
on a timer (`cron`/`launchd`) or interactively:

```bash
# Claude Code — one triage+review pass for team CFW:
claude -p "$("$DOZERS_HOME"/directors/build-prompt.sh dev-director)

Do one pass now for Linear team CFW."

# Codex — same idea: feed both files as the system prompt, give it Linear MCP,
# and run it on a schedule.
```

## The layout

| Path | What it is |
|------|-----------|
| `directors/` | The deciders. `chief.md` / `dev-director.md` / `mktg-director.md` = personas; `LINEAR.md` = how they operate in Linear; `run.sh` = the CLI. |
| `dozers/` | The doers. `dozer.sh` = the engine (multi-team, fan-out); `dev-lane/` & `mktg-lane/` = each lane's `crew.sh` + `dozer.md`. |
| `tasks/` | The pluggable backend. `adapter.sh` = the interface; `linear.sh` (default) / `github-issues.sh` / `files.sh` = plugs. |
| `org/` | `OKRS.md` = the north star; `config.yaml` = org, team, lanes, backend. |
| `.github/` | Labels (the state machine), issue template, optional cloud Dozer. |
| `AGENTS.md` | The map of all roles and the rules that bind them. |

## Swap the backend

The Directors and Dozers only ever call the backend's handful of functions
(`task_list_ready`, `task_claim`, `task_done`, …). To move off GitHub, copy
`tasks/files.sh`, implement those against Linear / a spreadsheet / your own store,
and point `backend:` at it. Nothing else changes.

## The rules

1. **The label is the seam.** Nothing crosses from decide to do without `ready` + a lane (the greenlight).
2. **Directors never execute; Dozers never decide.** The two tiers do not overlap.
3. **Everything ladders to an OKR.** Unlinked work is scope drift, not work.
4. **One Chief, one Director per lane, many Dozers.** Start with dev + marketing; grow lanes and teams later (Ops is next).

MIT licensed. Grow it later — more lanes, more teams — but it starts as this.
