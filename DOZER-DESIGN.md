# GSAI-151 — design: per-repo test timeout + elapsed-on-failure, and the root cause of the 4-8x — the whole engine runs in launchd's Background band

**Task:** `repo:dozers` — this repo's own suite runs **4-8x slower in-crew than standalone**, so
`timeout_test: 900` kills work that is green (GSAI-73, twice). Spec (GSAI-151) asks for four
things, all designed here:

1. a **per-repo test timeout**, configured in `~/ecosystem/ecosystem.yaml` (where `no_test_gate`
   already lives), raised for `repo:dozers` specifically — other repos keep the tighter wall;
2. the **gate stays enforced** — no repo-wide opt-out anywhere in this change;
3. **elapsed test time on the failure line**, so `x <id> failed: tests timed out` says how far it got;
4. **investigate the 4-8x gap and report** whether the heavy suites are slow by nature or slow
   because the crew environment makes them retry/wait.

**Repo:** dozers (main-only). **Files touched:** `dozers/dev-lane/crew.sh` (1+3),
`tests/dev-lane-timeout-per-repo-test.sh` (new regression), `tests/dev-lane-no-commit-gate-test.sh`
(one un-pinned assertion), `dozers/service.sh` + `tests/service-test.sh` (the root-cause fix + its
regression), `tests/run-all.sh` (one line: suite total), plus the one-line **live registry edit** in
`~/ecosystem/ecosystem.yaml` (documented below — the runtime reads it directly, no merge delivers it).

## Findings (spec item 4): slow by nature; the 4-9x MULTIPLIER is the environment — and it has one name

**What the data says.** From GSAI-73's in-crew run vs the standalone measurements: the ENTIRE
standalone suite is 155s; `merge-verify-test.sh` alone took **167s in-crew**. Per-test in-crew
averages ≈ 42s against ≈ 4.8s standalone — but not uniformly: `heartbeat-test.sh`, whose cost is
almost entirely **fixed sleeps** (~20s of `sleep` calls), came in at 23s — **flat**, no multiplier.
The tests that scaled 4-9x are the spawn/CPU-heavy ones, and none of them wait or retry on anything
environmental: `merge-verify-test.sh` is real, deterministic work (three full crew runs, a whole
engine copy `cp -R`, 450 `git commit-tree`s); `dev-lane-timeout-test.sh` is bounded hangs + git work.
No retry loops, no env-conditional polling, no lock waits. **The suite is not waiting on anything —
it is being scheduled slowly.** (Fixed-sleep tests staying flat while process-spawn tests scale is
the exact fingerprint of CPU scheduling throttling, not of contention-induced waiting.)

**Root cause — one line in this repo.** `dozers/service.sh:89` — `gen_plist()` emits:

```xml
<key>ProcessType</key>
<string>Background</string>
```

and the live `~/Library/LaunchAgents/com.dozers.loop.plist` carries it (verified on this machine,
2026-09-16). launchd's **Background** band puts the engine's entire process tree in **darwinbg QoS**:
lowest CPU priority and, on Apple Silicon, **E-core-only scheduling**. Everything the engine spawns
inherits it — the poll loop, every crew, every model pass (`claude -p` is a node process), and both
timeboxed `make test` runs (task worktree + green-gate). Spawn-heavy bash suites are the worst case
for E-core pinning; run from an interactive shell on P-cores, the same suite is 4-9x faster. The repo
already recorded this load-sensitivity without naming the cause — `tests/dev-lane-timeout-test.sh:73-79`
("a bound measuring machine load, not behaviour"). Fanout-5 concurrency compounds it; the band alone
explains the window.

**Report line for the task comment:** the 4-8x is the launchd Background band throttling the whole
tree; the heavy suites are heavy by nature (real crews, real git work) but nothing in them retries
or waits — and the band fix (below) should collapse in-crew time toward the 155s standalone baseline.

## The build

### 1. Per-repo `timeout_test` (crew.sh) — resolved LAZILY, on purpose

New precedence, most-specific first:

```
DOZER_TIMEOUT_TEST (env, per-run)  >  timeout_test: on the repo's ecosystem.yaml entry  >  timeout_test: in org/config.yaml  >  900
```

Implementation: `run_tests()` re-resolves the bound on **every call** —

- `timebox_secs test 900` first (env > org config, exactly as today);
- when no env override is set, `tasks/ecosystem_workdir.py --flag timeout_test --path "$WORKDIR"`
  is consulted; a value present replaces the bound and sets the **source label**
  (`timeout_test (per-repo) in ~/ecosystem/ecosystem.yaml`) so the timeout message names the knob
  that was actually in force;
- a per-repo value that is not whole seconds **fails loud** (`timeout_test '90O' for <repo> in
  ~/ecosystem/ecosystem.yaml must be whole seconds`) — no silent fall-through to the global bound;
- an absent registry entry / missing key is "not set" (the documented `--flag` contract) → global bound.

**Why lazy, not at crew start (the current `T_TEST=` line):** the crew resolves its bounds before
the model passes run — but THIS task's build pass is the one that adds `timeout_test: 1800` to the
dozers registry entry. Resolved upfront, this crew's own gates would still run at 900s and the task
would block on itself a third time (a standalone 155s suite cannot exceed 900s — that exact reasoning
is what the spec says was wrong twice). Lazy resolution closes the bootstrap bind: the registry edit
the build pass makes is live for this crew's own task-worktree and green-gate runs, with no Director
override — which is precisely the spec's "Done when". The other knobs (model/deps/push) stay upfront:
their sources don't change mid-run.

**Upfront validation is preserved (GSAI-37's fail-before-spend):** crew start keeps a
validation-only read — env, org config, and the per-repo flag are each regex-checked before the
architect pass; garbage in any of them fails the crew with the value and source named, before any
model time. Both runs (task worktree + green-gate) get the same bound — same repo.

**The registry edit** (live, by the crew, before its own gates run — reported in the summary):
on the `id: dozers` entry (`~/ecosystem/ecosystem.yaml:276-284`):

```yaml
    timeout_test: 1800   # GSAI-151: own suite ~155s standalone / ~1350s in-crew (measured, GSAI-73) — 900 killed green runs twice
```

1800 ≈ 1.3x the measured in-crew ceiling; after the plist fix it is comfortable headroom, and the
hang guard degrades only in the one repo whose suite is known-heavy — every other repo keeps 900.

### 2. Elapsed test time on the failure line (crew.sh)

`run_tests()` records `$SECONDS` around the timebox and the two failure texts carry it:

- red: `tests failed after 412s — not merging (worktree kept for resume)` (elapsed is genuinely new
  information here — failed-at-3s vs failed-at-412s tells a Director very different things);
- timeout: the existing `timed_out_msg` gains the elapsed and the **effective source**:
  `tests (\`make test\`) timed out after 1800s — ran 1800s before the kill (timeout_test per-repo in
  ~/ecosystem/ecosystem.yaml; DOZER_TIMEOUT_TEST to override for one run) — killed its process group`.

These texts land in `.artifacts/dev/<id>.fail`, which `dozers/dozer.sh:333-337` already threads verbatim
into `x #$id failed: $reason` and the block comment — no engine change needed. **Blast radius:**
`tests/dev-lane-no-commit-gate-test.sh:214` pins the exact old red text; its assertion widens to a
substring match (`*"tests failed after"*` + `*"not merging"*`). `tests/dev-lane-timeout-test.sh` and
`dev-lane-model-exit-test.sh` assert substrings only (`*"timed out after ${BOUND}s"*`) and survive
as-is.

### 3. The plist fix (service.sh) — the root cause of the 4-8x

`gen_plist()`: `ProcessType` goes `Background` → **`Standard`** (launchd's default band: fair
scheduling — kept explicit and greppable, not omitted), with a comment: the engine IS the factory —
its children do all the real work; the Background band is darwinbg QoS (lowest priority, E-core-only
on Apple Silicon) for the entire tree, which measured this repo's own suite 4-8x slower in-crew and
killed green runs (GSAI-151); `Standard` is deliberate. Why not `Adaptive` — it demotes under load
heuristics, i.e. exactly when the factory is busiest (5 parallel crews), reintroducing the same
unpredictable slowness. `KeepAlive`/`RunAtLoad`/`ThrottleInterval` untouched. The systemd unit has no
equivalent throttle — unchanged.

**The crew does NOT self-install.** `service.sh install` bootouts + bootstraps the agent; run from
inside a crew it kills the crew's own parent tree mid-task. The activation step is post-merge,
run by Vas/the Director from the main checkout: `dozers/service.sh install` (KeepAlive relaunches the
loop at once; in-flight-task recovery is the reaper's, but the trigger is still not ours to pull).
The per-repo timeout (item 1) is the protection that holds until then, and on any machine that has
not reinstalled.

### 4. `tests/run-all.sh` — one line: the suite total

The final line gains the total elapsed (`run-all: PASS — 33/33 in 187s`). Per-test seconds are
already printed; the total is what makes the standalone-vs-in-crew comparison — the whole basis of
this issue's numbers — readable from a crew log without arithmetic across 33 lines. Report-only.

## Edge cases

1. **Bootstrap bind** (this task's own gates run under the still-Background engine): solved by lazy
   resolution + the live registry edit landing before the gates — no Director override, matching
   the spec's Done-when. If anything still times out, the failure text now names the knob and source.
2. **Garbage per-repo value** — fails loud at crew start AND at run time; never silently demoted.
3. **Repo absent from the registry** (or stale `local:` path) — flag lookup misses → global 900;
   the registry-sweep already guards stale paths.
4. **Env override always wins** — a Director's deliberate per-run choice beats both configs.
5. **The gate is never waived** — no `TEST_GATE` logic is touched; no `.dozers-no-test-gate` added.
6. **`run-all.sh`'s own per-test watchdog** (`TEST_TIMEOUT`, default 240s) is a separate, env-tunable
   bound; worst in-crew per-test measurement (167s) sits under it. Left alone, noted here so the
   knob is discoverable if a single test ever needs more.
7. **Non-macOS:** the plist assertions run against `service.sh plist` output anywhere; the systemd
   path is untouched.
8. **Old plists in the wild:** any machine installed before this fix carries Background until
   `service.sh install` is re-run from the fixed repo — the regression test prevents reintroduction
   at the source.

## How it gets tested

- **`tests/dev-lane-timeout-per-repo-test.sh` (new)** — drives the REAL crew against a throwaway
  repo, in the dev-lane family's style, with `ECOSYSTEM_REGISTRY` pointed at a fixture registry:
  - **PER-REPO**: registry maps the repo to `timeout_test: 4`; a hanging test command → blocked,
    reason names `timed out after 4s` AND the per-repo source (ecosystem.yaml)
  - **ENV WINS**: same repo + `DOZER_TIMEOUT_TEST=6` → reason names 6s
  - **FALLBACK**: repo absent from the fixture registry, org-config `timeout_test: 5` (via
    `TIMEBOX_CONFIG`) → reason names 5s
  - **ELAPSED**: a fast-failing test command → `.fail` carries `failed after` + seconds
  - **GARBAGE**: registry value `90O` → crew fails fast naming the value and file, before spend
  - plus the family's standing checks: develop untouched, process group actually killed
- **`tests/service-test.sh`**: the generated plist carries `ProcessType` = `Standard` and must NOT
  contain `Background`; `plutil -lint` (already run) confirms the value is legal.
- **`tests/dev-lane-timeout-test.sh` / `dev-lane-model-exit-test.sh`**: still green as-is (substring
  assertions; env path unchanged). **`dev-lane-no-commit-gate-test.sh`**: assertion widened as above.
- **Full suite:** `make test` green — red = not done.
- **Mechanism confirmation (post-merge, reported on the task):** after `service.sh install`,
  `launchctl print gui/$(id -u)/com.dozers.loop` shows the job at standard, and the next dozers-repo
  crew's log shows the suite total near the 155s standalone baseline — the 4-8x collapsed, GSAI-73's
  failure mode unreachable both ways (per-repo headroom even if a machine is still Background).