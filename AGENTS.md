# Agents in dozers

Two tiers, one seam. **Directors decide; Dozers do.** The only thing that crosses
between them is the greenlight — a `ready` label + a lane. No greenlight, no run.

```
                     CHIEF                         directors/chief.md
              (governance · OKRs · priorities)
                       │ assigns objectives
        ┌──────────────┴───────────────┐
        ▼                              ▼
   DEV-DRIVER                     MKTG-DRIVER        directors/dev-driver.md
   (triage · spec · review)       (brief · review)  directors/mktg-driver.md
        │                              │
        │   ⚡ the greenlight = ready + lane  │            ← the only handoff
        ▼                              ▼
   DEV-DOZER                      MKTG-DOZER         dozers/dev-dozer.md
   architect→build→test→merge     produce→approval  dozers/mktg-dozer.md
```

## The tiers

| Tier | Who | Instruction file | Does |
|------|-----|------------------|------|
| **Director** (decide) | **Chief** | `directors/chief.md` | governance, keeps `org/OKRS.md` honest, sets priorities, assigns to lane-Directors. Governs the other Directors; never triages a task. |
| **Director** (decide) | **Dev-Director** | `directors/dev-driver.md` | triage → spec → review dev work; stamps `ready` + `lane:dev`. |
| **Director** (decide) | **Mktg-Director** | `directors/mktg-driver.md` | brief → review content; stamps `ready` + `lane:marketing`. |
| **Dozer** (do) | **Dev-Dozer** | `dozers/dev-dozer.md` | claims `lane:dev` → worktree → architect → build → test → merge. |
| **Dozer** (do) | **Mktg-Dozer** | `dozers/mktg-dozer.md` | claims `lane:marketing` → produce → stage for human approval. |
| — | **Keeper** (you) | — | file work in, approve what comes back. |

## The rules that never bend

1. **Directors decide, Dozers do — the two never overlap.** A Director that opens a
   worktree, or a Dozer that re-scopes a task, has broken the model.
2. **The label is the seam.** Nothing crosses from decide to do without
   `ready` + a lane (the greenlight).
3. **Everything ladders to an OKR.** Unlinked work is scope drift, not work.
4. **One Chief, few Directors, many Dozers.** You staff one Chief and one Director per
   lane; Dozers are disposable hands the engine spins up as needed.

## The tools the roles drive

- Directors act through **`directors/run.sh`** (`triage`, `ready <id> <lane>`, `note`).
- Dozers are run by **`dozers/dozer.sh`** (`once` / `loop`), which claims a greenlit
  task and hands it to the lane crew in **`dozers/lanes/<lane>.sh`**.

## Which model a role runs on

A Dozer's brain is configurable per **role** (today the lane name: `dev`, `marketing`),
not baked into the crew. `org/config.yaml` → `models:` maps each role to a `provider`
(`claude` | `ollama-cloud` | `ollama-local` | `codex`) and an optional model id;
`dozers/model.sh` resolves that into the crew's `MODEL_CMD` plus any provider env. Check
the current wiring with `dozers/model.sh show`, prove a provider works with
`dozers/model.sh smoke <provider> [model]`, and override a single run with
`DOZER_MODEL_<ROLE>="<provider>[:<model>]"` (e.g. `DOZER_MODEL_DEV=ollama-cloud:glm-5.2`).
Ship default is `claude` for every role. A route that can't be satisfied **fails the
crew** — there is no silent fallback to another model, because a run that quietly used a
different brain is a run you can't trust.

> Ops is a planned third lane (Ops-Director / Ops-Dozer / `lane:ops`) — not shipped
> yet. The system starts with **dev** and **marketing**.
