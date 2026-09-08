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
   ║  THE DOZER  (one process, all teams, `fanout` parallel crews, atomic-locked)   ║
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
the tests, serial-merges to `develop` (green-gated; on a main-only repo it merges to
`main` instead — the crew detects the branch, never imposes one), and comments a summary on the issue.

### Run it as a supervised service (survives crashes, logout, reboot)

`dozers/dozer.sh loop` in a terminal dies silently — a crash, a closed lid, a logout —
and nothing brings it back. Hand it to the OS supervisor so it **auto-restarts**:

```bash
# put secrets/config where the service can source them (never baked into the unit):
echo 'export LINEAR_API_KEY=lin_api_...' >> ~/.dozers/dozer.env

dozers/service.sh install     # macOS → launchd KeepAlive · Linux → systemd Restart=always
dozers/service.sh status      # is it running? + the engine heartbeat
dozers/service.sh logs        # tail the loop's log (a silent death is now visible here)
dozers/service.sh uninstall   # stop + remove

# ...and something that NOTICES when the engine stops beating, so you don't have to look
dozers/heartbeat-check.sh creds     # can it actually shout? (a real round-trip to the tracking issue)
dozers/heartbeat-check.sh install   # a launchd agent that alarms on a stalled/non-dispatching engine
dozers/heartbeat-check.sh status    # the current verdict, no alarm
# The alarm is a LABEL: `board:to_review` on the standing issue in `alarm_issue:` (org/config.yaml),
# which is exactly what the Linear Board view filters on. Buzz is an optional second hop.
```

If the loop dies for any reason the supervisor relaunches it (throttled 10s so a
start-up crash can't hot-loop), and every line it prints lands in `~/.dozers/logs/` —
so a silent death becomes a visible, diagnosable one.

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
     worktree dozer/<id>  →  test-gate PREFLIGHT (NO tests = stop, before any spend)
        →  coding agent implements + tests + commits
        →  test gate (red = stop; NO tests = stop too)
        →  serial-merge to develop (green-gated)
        →  Director promotes develop → main

  lane:marketing  ────────────────────────────────────────────────────────
     load brand voice  →  content agent produces the asset
        →  STAGE it to .dozers-review/  (never auto-published)
        →  issue flips to dozer:needs-review  →  a human approves

  lane:marketing, VIDEO brief (a `production:` line in the issue description)
     match the human-submitted HeyGen render by title  (no render = blocked
        with the exact submit ask — Avatar III, 2 credits)
        →  STALE gate: script hash vs the render's record (changed = blocked)
        →  download raw-avatar.mp4 + ffprobe-assert  →  compose with the brand's
           current recipe  →  STAGE mp4 + cover + captions + the posts/quick
           payload it WOULD send  →  dozer:needs-review. Never publishes.
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
   repo:<id> label   →  that repo's path (searched in projects: then infrastructure:)
   task's team/org    →  the org's default repo (projects: only — infra has no org)
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
  │  The loop also keeps a heartbeat beacon fresh (ts + pid + LIVE       │
  │  in-flight count + its own beat cadence) on a ticker independent of  │
  │  the drain — so it keeps beating THROUGH a long crew run instead of  │
  │  freezing until the drain ends. The ticker dies with the engine, so  │
  │  a beacon can never outlive the process it vouches for.              │
  │  `dozers/heartbeat-check.sh` is the other half: a launchd agent that │
  │  reads the beacon and alarms when it stops — silent when a stale     │
  │  beacon is just a long task, loud when nothing is running at all,    │
  │  and loud when the loop beats but stops claiming (poll= frozen with  │
  │  idle slots and greenlit work queued). The alarm is the              │
  │  `board:to_review` label on a standing Linear issue — the Board view │
  │  is the surface; the flag comes down by itself on recovery.          │
  └─────────────────────────────────────────────────────────────────────┘

  ┌── Seance (resume) ─────────────────────────────────────────────────┐
  │  A crashed dev task's worktree persists with its committed work. On  │
  │  the next run the Dozer RESUMES it — continues from the prior commits│
  │  instead of restarting from scratch (saves time + tokens).           │
  └─────────────────────────────────────────────────────────────────────┘

  ┌── Refinery (green-gated merge queue) ──────────────────────────────┐
  │  Merges to develop are serialized per project (a merge lock), and    │
  │  each merge is re-tested ON develop. A merge that breaks it — or that │
  │  leaves nothing to run — is reverted and the task sent back, so        │
  │  develop stays genuinely green under fan-out.                          │
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
linear_teams: "CFW,LL,BRD,GSAI,DLY"   # every team, one process
fanout: 5                              # 5 crews at once
push: "false"                          # merges stay on the local integration branch —
                                       # nothing is pushed to origin until you say otherwise
```

Each parallel crew works in its own worktree; a per-project merge lock keeps `develop`
safe. A task from any team routes to that org's repo automatically.

---

## Model routing — which brain each role runs on

Every crew launches a headless coding/content agent. **Which** agent is a per-role knob,
not a hardcoded command: point the dev lane at a cheap open model and keep marketing on
Claude, or flip either back, without touching a crew.

```yaml
# org/config.yaml
models:
  default:   { provider: claude, model: "" }      # fallback for any role not listed
  dev:       { provider: claude, model: "" }      # "" = the provider's default model
  marketing: { provider: claude, model: "" }
ollama_env: "~/ecosystem/vault/ollama-cloud.env"  # where OLLAMA_API_KEY lives (vault-first)
```

A **role** is the lane name today (`dev`, `marketing`); `default` catches anything else.

| Provider | Runs | Model id | Notes |
|---|---|---|---|
| `claude` | `claude -p` | any Claude model (`--model`) | the default; uses your normal Claude Code auth |
| `ollama-cloud` | `claude -p` against `https://ollama.com` | `glm-5.2` (default), `kimi-k2.7-code`, `deepseek-v4-flash`, `deepseek-v3.2`, `minimax-m3`, `kimi-k2.6` | Anthropic-compatible endpoint; Bearer `OLLAMA_API_KEY` |
| `ollama-local` | `claude -p` against `http://localhost:11434` | required, e.g. `qwen2.5:7b-instruct` | **best-effort.** The daemon does speak `/v1/messages`, but Claude Code as its client is unproven — a 7B model did not finish a headless turn in 5 min. No default model on purpose. |
| `codex` | `codex exec` | any Codex model (`--model`) | OpenAI Codex CLI, non-interactive |

**Override for one run** — env always beats config:

```bash
DOZER_MODEL_DEV="ollama-cloud:glm-5.2"        dozers/dozer.sh once
DOZER_MODEL_MARKETING="claude:claude-opus-4-6" dozers/dozer.sh once
DOZER_MODEL_<ROLE>="<provider>[:<model>]"      # the general form
```

Setting `MODEL_CMD` directly still works and bypasses routing entirely (the legacy
escape hatch, as does the flat `model_cmd:` in config).

**Inspect and test it:**

```bash
dozers/model.sh show                      # role -> provider/model table (prints no secrets)
dozers/model.sh env dev                   # the eval-able export block a crew uses
dozers/model.sh smoke ollama-cloud glm-5.2  # one tiny real call; pass/fail + latency
```

Each crew logs `[dev] model: <provider>/<model>` and puts the same line in the task
summary, so the comment the Dozer posts back says which brain did the work.

**Fail fast, always.** A role pointed at a provider whose key or model is missing stops
the crew with a non-zero exit and a message naming what's absent. It never quietly falls
back to `claude` — a silently-swapped brain is worse than a failed run. The key is read
from the vault only inside the resolver; it is never logged, echoed, or printed by `show`.

---

## Repo layout

| Path | What it is |
|------|-----------|
| `dozers/dozer.sh` | The engine — poll → claim → route → run → report (`once` / `loop` / `doctor` / `recover` / `heartbeat`). |
| `dozers/reaper.sh` | Crash-recovery watchdog (stale locks, orphan requeue, runaway kill). |
| `dozers/heartbeat-check.sh` | Liveness watchdog — reads the engine's beacon and alarms (Linear `board:to_review` on `alarm_issue`, Buzz optional) when it stops beating or stops dispatching (`check` / `status` / `creds` / `install` / `uninstall` / `plist`). |
| `dozers/service.sh` | Run the loop as a supervised service — launchd `KeepAlive` (macOS) / systemd `Restart=always` (Linux) auto-restart (`install` / `status` / `logs` / `uninstall`). |
| `dozers/dev-lane/` · `dozers/mktg-lane/` | Each lane's `crew.sh` + `dozer.md` persona. |
| `directors/` | The deciders: `chief.md` / `dev-director.md` / `mktg-director.md` / `ops-director.md` (infra + housekeeping, `lane:ops`), shared `STYLE.md` + `LINEAR.md`, `runtimes/`, `build-prompt.sh`, `org-canvas.template.md`, `run.sh`. |
| `directors/LINEAR.md` | The board contract every Director inherits — the exact label move per operation, plus the **board protocol**: `@Vas` + `board:to_review` → one `#now` ping → reconcile-first next wake → `board:responded`. |
| `tasks/` | Pluggable backend: `adapter.sh` interface; `linear.sh` (default) / `github-issues.sh` / `files.sh`; `ecosystem_workdir.py`. |
| `dozers/model.sh` · `tasks/model_route.py` | Per-role model routing — `show` / `env <role>` / `smoke <provider>`. |
| `org/config.yaml` | Teams, lanes, fan-out, integration branch, per-role model routing. |
| `tests/` · `Makefile` | The regression suite. `make test` runs `tests/run-all.sh`, which runs every `tests/*-test.sh`. |
| `AGENTS.md` · `BUZZ-SETUP.md` | The role map + the Buzz/Codex/Claude run guide. |

## Tests

```bash
make test                                  # the whole suite (this is the repo's test command)
bash tests/run-all.sh tests/reaper-test.sh # one test
TEST_TIMEOUT=300 make test                 # per-test watchdog, default 240s
```

Each test drives the *real* engine, crews and gates against throwaway repos and a stub
agent — no model call, no network, no writes outside `mktemp`. Add one as
`tests/<thing>-test.sh` and the runner picks it up; nothing to register.

The runner **scrubs the environment** before every test (`MODEL_CMD`, `DOZER_MODEL_*`,
`DOZER_PERSONA`, the `ANTHROPIC_*` routing block, the lane knobs, `LINEAR_API_KEY`).
That matters because the dev lane runs this very command *from inside a crew*, where
all of those are exported: without the scrub, tests that drive the crews would assert
on the inherited route instead of the one under test, and the suite would pass in your
shell but fail in the harness.

This repo is deliberately **not** opted out of its own test gate — `make test` exists so
the harness that blocks ungated merges can clear its own gate honestly.

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
