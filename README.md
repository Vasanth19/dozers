# dozers

A tiny, shareable operating system for one organization's AI work. **Directors
decide; Dozers do.** A single label — `ready` + a lane — is the greenlight that wakes a
Dozer: the only handoff between deciding and doing. No greenlight, no run.

It's deliberately small: clone it, change one config value, and you have a working
agent org. The task backend is a *plug* — GitHub Issues by default, a
zero-dependency local file board as the fallback, anything else via one adapter file.

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

## The layout

| Path | What it is |
|------|-----------|
| `directors/` | The deciders. `chief.md` / `dev-driver.md` / `mktg-driver.md` = the personas; `run.sh` = triage & stamp the greenlight. |
| `dozers/` | The doers. `dozer.sh` = the engine; `lanes/*.sh` = the crew per lane; `dev-dozer.md` / `mktg-dozer.md` = the crew personas. |
| `tasks/` | The pluggable backend. `adapter.sh` = the interface; `github-issues.sh` / `files.sh` = plugs. |
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
