VERDICT: PASS

Reviewed the develop..HEAD diff (commit 6c9faab) against the spec (GSAI-151) and the
architect pass's DOZER-DESIGN.md, then ran the repo's own full suite from this worktree.

## Spec, item by item

**1. Per-repo `timeout_test` in ecosystem.yaml — done, precedence correct.**
`run_tests()` re-resolves the bound on every call: `DOZER_TIMEOUT_TEST` > the repo's
`timeout_test:` registry entry (via `tasks/ecosystem_workdir.py --flag`, next to
`no_test_gate`) > org/config.yaml > 900. Lazy resolution is the right call and the
design's bootstrap argument holds: the crew that ADDS a repo's entry must not be locked
to the old bound for its own gates — verified live, the `dozers` entry at
`~/ecosystem/ecosystem.yaml:284` now carries `timeout_test: 1800` and this crew's own
green-gate picks it up. Only the `dozers` entry was touched; every other repo keeps
900. Garbage values fail loud BOTH upfront (before any model spend — the GARBAGE case
proves the stub never ran and no worktree was even built) and at run time.

**2. Gate stays enforced — confirmed.** No `TEST_GATE` logic, no waiver path, no
`.dozers-no-test-gate` anywhere in the diff; the only gate-adjacent changes are bound
resolution and failure text. The green-gate still runs both test passes (the GATE case
in dev-lane-timeout-test still passes as-is).

**3. Elapsed on the failure line — done, and slightly better than asked.** Both the red
line (`tests failed after Ns — not merging …`) and the timeout line (`timed out after Ns
— ran Ns before the kill (…source…)`) carry the elapsed; the timeout text also names the
effective source of the bound, so the knob actually in force is visible in
`.artifacts/dev/<id>.fail`. The one test that pinned the old red text byte-exactly was
widened to semantics, as designed.

**4. The 4-8x investigation — root cause found, named, and corroborated live.**
`dozers/service.sh` emits `ProcessType: Background` → darwinbg QoS pins the entire
engine tree (crews, model passes, both make-test runs) to E-core scheduling. The fix
(Background → Standard, kept explicit, with the reasoning in an XML comment) matches
the design; the crew correctly does NOT self-install (that would bootout its own parent
tree mid-task) — the live plist still says Background, as designed, until a post-merge
`service.sh install`. Independent corroboration from this review: the full suite took
**644s here — in-crew, as a child of the still-Background-banded engine — vs the ~155s
standalone baseline**, i.e. the ~4x environmental multiplier is real and the suite is
not retrying or waiting on anything. 1800s is ~2.8x the measured in-crew ceiling:
headroom without waiving anything.

## Test evidence

`make test` from this worktree: **run-all: PASS — 33/33 in 644s**, including:
- `dev-lane-timeout-per-repo-test.sh` (new, 52s): PER-REPO beats org-config, ENV beats
  per-repo, FALLBACK to org-config when the repo is absent, ELAPSED on red,
  GARBAGE fails before spend — all green, plus the family's standing checks (develop
  untouched, process group actually killed). The fixture bounds (8/10/12s) sit above
  npm's startup envelope, applying dev-lane-timeout-test's flake lesson rather than
  repeating it.
- `dev-lane-timeout-test.sh` (55s) and `dev-lane-model-exit-test.sh` pass unchanged —
  their substring assertions survive the new message shapes, as the design predicted.
- `dev-lane-no-commit-gate-test.sh` (41s) green with the widened assertion.
- `service-test.sh` green: ProcessType Standard present, `Background` absent,
  `plutil -lint` still clean (the XML comment is legal plist).
- `run-all.sh` prints the suite total (`in 644s`) — report-only, as designed.

Design fidelity is exact on files: `dozers/dev-lane/crew.sh`, `dozers/service.sh`,
`tests/run-all.sh`, one assertion widened in no-commit-gate, the new regression, and
nothing else in the repo.

## Residuals (noted, none blocking)

1. **Green-gate `fail` window (narrow).** `run_tests` can now `fail` mid-green-gate if
   the per-repo value turns garbage between the task-worktree run and the gate — after
   the merge, before the revert. Static garbage is caught upfront; the trigger requires
   a concurrent malformed registry edit inside a minutes-wide window, and the damage is
   contained: no merge receipt is written, so the issue blocks and is never labeled
   merged-develop (the GSAI-119 guard holds), and develop is recoverable by a hand
   reset. Fail-loud here is still the right trade vs silently demoting the bound.
2. **Reader errors degrade quietly.** `ecosystem_flag` suppresses all stderr and exit
   codes, so a missing `yaml` module or unreadable registry reads as "not set" → the
   global 900. This matches both the pre-existing `no_test_gate` idiom it was extracted
   from and the design's documented edge case 3 — consistent, but worth remembering if
   a per-repo bound ever silently fails to apply.
3. **Cosmetic.** The new test's header (lines 19, 53) says the fixture org-config
   carries `timeout_test: 5`; the actual value is 10. Comment drift only — the
   assertions and fixture agree with each other.
4. **The "~155s standalone" baseline is GSAI-73's measurement, not re-derived here** —
   no standalone opportunity in an in-crew pass. The 644s in-crew figure above is this
   review's own data point and lands inside the design's predicted window.

## Post-merge (for the Dev-Director, not this pass)

Re-run `dozers/service.sh install` from the main checkout to activate the Standard band
(KeepAlive relaunches the loop immediately), then confirm with
`launchctl print gui/$(id -u)/com.dozers.loop` and watch the next dozers-repo crew's
suite total collapse toward ~155s. Until then (and on any machine with an old plist),
the per-repo 1800s bound is the protection in force.