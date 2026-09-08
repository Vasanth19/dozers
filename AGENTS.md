# Agents in dozers

Two tiers, one seam. **Directors decide; the Dozer does.** The only thing that crosses
between them is the greenlight — a `ready` label + a lane. No greenlight, no run.

```
                     CHIEF                         directors/chief.md
              (governance · OKRs · priorities)
                       │ assigns objectives
        ┌──────────────┼───────────────┐
        ▼              ▼               ▼
   DEV-DIRECTOR   MKTG-DIRECTOR   OPS-DIRECTOR     directors/dev-director.md
   (triage·spec)  (brief·review)  (infra·hygiene)  directors/mktg-director.md
        │              │                          directors/ops-director.md
        │  ⚡ the greenlight = ready + lane │           ← the only handoff
        ▼              ▼
   DEV LANE       MKTG LANE                        dozers/dev-lane/dozer.md
   build→test→merge  produce→approval              dozers/mktg-lane/dozer.md
```

## The tiers

| Tier | Who | Instruction file | Does |
|------|-----|------------------|------|
| **Director** (decide) | **Chief** | `directors/chief.md` | governance, keeps `org/OKRS.md` honest, sets priorities, assigns to lane-Directors. Governs the other Directors; never triages a task. |
| **Director** (decide) | **Dev-Director** | `directors/dev-director.md` | triage → spec → review dev work; stamps `ready` + `lane:dev`. |
| **Director** (decide) | **Mktg-Director** | `directors/mktg-director.md` | brief → review content; stamps `ready` + `lane:marketing`. |
| **Director** (decide) | **Ops-Director** | `directors/ops-director.md` | infra, housekeeping, monitors, registry/vault hygiene; stamps `ready` + `lane:ops`. |
| **Dozer** (do) | **dev lane** | `dozers/dev-lane/dozer.md` (+ `crew.sh`) | claims `lane:dev` → worktree → build → test → merge. |
| **Dozer** (do) | **mktg lane** | `dozers/mktg-lane/dozer.md` (+ `crew.sh`) | claims `lane:marketing` → produce → stage for human approval. |
| — | **Keeper** (you) | — | file work in, approve what comes back. |

Every Director inherits the shared **`directors/LINEAR.md`** — the exact label move for
every board operation, plus the **board protocol**: an `@Vas` comment + `board:to_review`,
one `#now` ping, and a reconcile at the top of every wake that swaps in `board:responded`.

## The rules that never bend

1. **Directors decide, the Dozer does — the two never overlap.** A Director that opens a
   worktree, or a lane crew that re-scopes a task, has broken the model.
2. **The label is the seam.** Nothing crosses from decide to do without
   `ready` + a lane (the greenlight).
3. **Everything ladders to an OKR.** Unlinked work is scope drift, not work.
4. **One Chief, few Directors, many crews.** You staff one Chief and one Director per
   lane; lane crews are disposable hands the engine spins up as needed.

## The tools the roles drive

- Directors act through **`directors/run.sh`** (`triage`, `ready <id> <lane>`, `note`);
  their prompts are assembled by **`directors/build-prompt.sh <role> <runtime>`**
  (runtimes in `directors/runtimes/`).
- The Dozer is run by **`dozers/dozer.sh`** (`once` / `loop`), which claims a greenlit
  task and hands it to the lane crew in **`dozers/<lane>-lane/crew.sh`**.

## Which model a role runs on

A crew's brain is configurable per **role** (today the lane name: `dev`, `marketing`),
not baked into the crew. `org/config.yaml` → `models:` maps each role to a `provider`
(`claude` | `ollama-cloud` | `ollama-local` | `codex`) and an optional model id;
`dozers/model.sh` resolves that into the crew's `MODEL_CMD` plus any provider env. Check
the current wiring with `dozers/model.sh show`, prove a provider works with
`dozers/model.sh smoke <provider> [model]`, and override a single run with
`DOZER_MODEL_<ROLE>="<provider>[:<model>]"` (e.g. `DOZER_MODEL_DEV=ollama-cloud:glm-5.2`).
Ship default is `claude` for every role. A route that can't be satisfied **fails the
crew** — there is no silent fallback to another model, because a run that quietly used a
different brain is a run you can't trust.

> **Ops lane status:** the Ops-Director and the `lane:ops` label exist, but there is **no
> `dozers/ops-lane/` crew yet** and `org/config.yaml → lanes:` lists only `dev` and
> `marketing`. `lane:ops` today marks work the Ops-Director owns and drives itself — the
> Dozer will not pick it up until an ops crew ships.
