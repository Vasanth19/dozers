# director-worker

A tiny, shareable operating system for one organization's AI work. **One
Director decides; one Worker does.** A single label — `ready` + a lane — is the
only handoff between them. No label, no run.

It's deliberately small: clone it, change one config value, and you have a
working agent org. The task backend is a *plug* — GitHub Issues by default, a
zero-dependency local file board as the fallback, anything else via one adapter file.

```
              ┌─────────────────────────────────────────────┐
              │  YOU — file work, review what comes back      │
              └───────────────────────┬─────────────────────┘
                                      │
   ╔═════════════════ DECIDE ═════════▼══════════════════════╗
   ║   Director            reads org/OKRS.md                  ║
   ║   triage → spec → review          (judgment, never runs) ║
   ╚═══════════════════════════╤═════════════════════════════╝
                               │  stamps  ready + lane:<x>
                               ▼        ── the only handoff ──
   ╔═════════════════ DO ══════▼══════════════════════════════╗
   ║   Worker      polls ready+lane → claims → runs the crew   ║
   ║   ┌────────────────────┐   ┌───────────────────────────┐ ║
   ║   │ lane:dev           │   │ lane:marketing            │ ║
   ║   │ worktree→build→test│   │ produce → human approval  │ ║
   ║   └────────────────────┘   └───────────────────────────┘ ║
   ╚══════════════════════════════════════════════════════════╝

   task backend (the plug):  GitHub Issues  ·  local files  ·  your own
```

## See it work in 5 seconds (no setup)

```bash
./demo.sh
```

Runs the local file backend: files two tasks, the Director gives each a lane, the
Worker drains both and produces artifacts. That's the entire loop, offline.

## Use it for real (GitHub Issues)

1. Edit `org/config.yaml` → set `repo: your-owner/your-repo` (backend is already `github`).
2. `gh auth login` (once), then `./setup.sh` to create the labels.
3. Open an issue describing a task.
4. **Director** triages and approves:
   ```bash
   director/run.sh triage            # see untriaged work
   director/run.sh ready 42 dev       # approve #42 into the dev lane
   ```
5. **Worker** executes:
   ```bash
   worker/worker.sh once              # drain now
   # or worker/worker.sh loop          — keep draining
   # or let .github/workflows/worker.yml run it every 15 min in the cloud
   ```

## The layout

| Path | What it is |
|------|-----------|
| `director/` | Decides. `director.md` = the persona; `run.sh` = triage & stamp `ready`. |
| `worker/` | Does. `worker.sh` = the engine; `lanes/*.sh` = the crew per lane. |
| `tasks/` | The pluggable backend. `adapter.sh` = the interface; `github-issues.sh` / `files.sh` = plugs. |
| `org/` | `OKRS.md` = the north star; `config.yaml` = org, team, lanes, backend. |
| `.github/` | Labels (the state machine), issue template, optional cloud Worker. |

## Swap the backend

The Director and Worker only ever call five functions (`task_list_ready`,
`task_claim`, `task_done`, …). To move off GitHub, copy `tasks/files.sh`, implement
those five against Linear / a spreadsheet / your own store, and point
`backend:` at it. Nothing else changes.

## The three rules

1. **The label is the seam.** Nothing crosses from decide to do without `ready` + a lane.
2. **The Director never executes.** It only triages, specs, and reviews.
3. **Everything ladders to an OKR.** Unlinked work is scope drift, not work.

MIT licensed. Grow it later — more lanes, more teams — but it starts as one of each.
