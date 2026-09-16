# GSAI-60 — design: board reconcile must not auto-approve on an agent's own comment

**Task:** the board reconcile reads "any later comment with no marker is Vas" —
but every *scripted* comment in the engine is posted unmarked. The Dozer's claim /
blocked / merged lines (`dozers/dozer.sh:245,261,309,326,333`), the reaper's requeue
note (`dozers/reaper.sh:82`), and `directors/run.sh`'s "Director approved" / `note`
lines (`directors/run.sh:31,36`) all land after a pending `board-ask` with **no
`<!-- … -->` marker**, so the next Director awake flips `board:to_review` →
`board:responded` and "acts on" a machine status line as if Vas had answered. The
Chief's 2026-09-08 sweep measured it live: **11 of 22 board issues** had unmarked
agent comments sitting after the last ask (50 comments total) — an auto-approval
path around the human gate that never fired only because Directors eyeballed the
text. The Chief backfilled `<!-- board-note by:agent -->` onto all 50 (the board is
safe *today*), and the fix decision is made: **invert to positive identification.**

**Repo:** dozers (main-only). **Files touched:** `tasks/_linear_api.py` (the fix),
`dozers/dozer.sh` + `dozers/reaper.sh` + `directors/run.sh` (one identity line each),
`directors/LINEAR.md` (the reconcile rule), `tests/board-reconcile-test.sh` (the
regression). Nothing else.

---

## Why the hole survived GSAI-41

GSAI-41 already fixed the *read* side: `is_agent_comment()` treats **any** HTML
comment as an agent's (`tasks/_linear_api.py:424-430`), and `board_answers()` returns
only unmarked later comments as Vas's answers. The contract — "an agent comment MUST
carry a marker; an unmarked comment is Vas" — is prose in LINEAR.md and all four
Director templates, and `tests/board-reconcile-test.sh` pins both.

The hole is the *write* side: the contract is only enforced on LLM-authored
comments. Every scripted `task_comment` call goes
`dozer.sh/reaper.sh/run.sh` → `tasks/linear.sh:37 task_comment` →
`_linear_api.py comment()` → `commentCreate` — **verbatim, no marker added**. The
engine posts five distinct unmarked comment shapes on ordinary runs, so the moment a
board issue also carries a pending ask (a re-greenlight while `board:to_review` is
still on, or a Dozer claim racing the ask), the probe's exit 0 is guaranteed and the
ask is auto-answered. As the Chief's data shows, it didn't need the race — it just
needed any unmarked agent comment after the ask.

## Approach — stamp at the choke point, guard at the probe

Three layers, matching the Chief's numbered decision exactly:

### 1. Write-side fix (the important one): every scripted comment self-stamps

`tasks/_linear_api.py comment()` is the single choke point every scripted Linear
comment passes through (`_comment_url()` is the second — the watchdog's
alarm path, whose callers pre-mark). A `_stamp_marker(body)` helper appends

```
<!-- board-note by:<DOZER_COMMENT_BY:-dozer-engine> -->
```

to any body that carries **no** `<!-- … -->` marker already (same `MARKER_RE`),
and leaves an already-marked body **byte-identical** — so `alarm_raise`/
`alarm_clear`/`board-mirror` comments (which pre-mark) are unchanged, and a
Director using `run.sh note` with a marked mirror text never gets a double stamp.
The marker name is the Chief's own backfill shape (`board-*`), so the read-side
classifier already treats it as an agent's.

The `DOZER_COMMENT_BY` identity is set at the three callers (one export line
each): `dozer.sh` → `dozer-engine`, `reaper.sh` → `dozer-reaper`, `run.sh` →
`director-cli`. This is provenance, not security — the default covers any future
call site that forgets to set it. **New scripted posters cannot recur the bug**:
forgetting the marker becomes impossible at the only door they all walk through.

The `files` and `github-issues` backends are untouched — their comments never reach
the Linear board reconcile (and the files backend's card files are local).

### 2. Read-side guard at the probe: refuse known agent signatures

The stamp protects the future; the **guard** protects against the residual — any
unmarked comment that still looks machine-authored (an old pre-fix comment, an
LLM-authored comment that forgot its marker, or a future poster bypassing
`comment()`). A small, anchored signature list of the engine's own stable comment
openers:

```python
AGENT_SIGNATURES = [
    r"^Dozer (claimed|blocked|merged|staged)\b",   # dozer.sh:245,261,309,326,333
    r"^Director approved\b",                        # run.sh:31
    r"^♻️ Reaper requeued\b",                        # reaper.sh:82
]
```

A shared `is_human_answer(body)` = unmarked **and** matches no signature replaces
the bare `not is_agent_comment(...)` in **both** consumers:

- `board_answers()` — the reconcile probe (`run.sh answer` / `board-answer`):
  signature-matching unmarked comments are **refused** — excluded from the
  answers, so the probe exits 3 (waiting) and the ask stays `board:to_review`.
  The CLI prints each refusal loudly to stderr — `REFUSED: comment at <ts>
  matches agent signature '<sig>' — not read as Vas's answer` — so the refusal is
  *visible*, and the exit-3 message in `run.sh answer` names the case.
- `alarm_clear()` (`_linear_api.py:533`) — same classifier, same refusal: an
  unmarked "Dozer blocked…" line after the watchdog's ask must not hand the ball
  to `board:responded`.

This is deliberately a *guard*, not the primary mechanism: it cannot enumerate
everything an agent might post, and it must **fail toward visible** (GSAI-41's
asymmetry: over-refusing leaves a real answer un-swapped for one awake — the
Director sees the stderr line and can swap manually after eyeballing; under-refusing
loses the question for good). If Vas genuinely quotes a status line as his answer,
the probe refuses, the Director reads the refusal, recognizes the answer, and swaps
by hand — the exact human-judgment path the protocol wants anyway.

### 3. The reconcile rule in LINEAR.md says all of this

`directors/LINEAR.md` §"Every awake, reconcile FIRST" gains two sentences:
scripted engine comments now self-stamp (a Director seeing `<!-- board-note … -->`
knows it's the engine), and the probe **refuses known agent signatures** — exit 3
with a stderr refusal line; if a refusal is genuinely Vas's answer, eyeball it and
swap manually. The one-sentence contract itself ("an agent comment MUST carry a
marker; an unmarked comment is Vas") is unchanged — the fix makes it *true*, not
different.

**Director templates need no edit** — all four already carry the every-comment-
carries-a-marker rule (chief.md:37, dev-director.md:63, mktg-director.md:85,
ops-director.md:47), and the existing test case 12 pins it.

## Edge cases

| Case | Behavior |
|---|---|
| Body already carries any `<!-- … -->` marker | Byte-identical, no double stamp (alarm/mirror paths unchanged) |
| Empty / whitespace body from a scripted site | Stamped — an empty agent comment is still an agent comment |
| Unmarked "Dozer claimed…" after an ask | Refused by the guard → exit 3, refusal logged, ask stays open |
| Unmarked agent-signature line **and** a later genuine Vas comment | The signature line is refused, Vas's comment still answers → exit 0 with the right comment |
| Vas quotes/repeats a status line as his real answer | Refused (fail toward visible) → Director eyeballs the refusal, swaps manually |
| Pre-fix unmarked comments NOT matching a signature | Still auto-approve — residual, mitigated: the Chief backfilled all 50 on 2026-09-08 |
| `alarm_clear` (heartbeat) path | Same classifier; a signature match → flag removed, never `board:responded` |
| `DOZER_COMMENT_BY` unset | Default `dozer-engine` — the stamp never silently disappears |
| files / github-issues backends | Untouched — their comments never reach the Linear reconcile |
| Unicode openers (`♻️`, `→`) in signatures | Regex-anchored on the exact bytes the call sites emit |

## How it gets tested

Extend `tests/board-reconcile-test.sh` — same protocol, same regression file,
keeping its python-harness idiom (`LINEAR_API_KEY=test-not-used`, pure functions
+ stubbed I/O, assertions in bash so a failure names itself):

- **STAMP (the acceptance: "a fresh Dozer run leaves zero unmarked comments").**
  Stub `lin.gql`/`lin.issue` to capture the `commentCreate` body; assert: an
  unmarked body gains the `board-note by:dozer-engine` marker; `DOZER_COMMENT_BY`
  is honored; an already-marked body round-trips **byte-identical** (no double
  stamp); `_comment_url()` (alarm path) stamps the same way.
- **GUARD (the incident).** `board_answers` with the exact GSAI-60 shapes — an
  unmarked `Dozer claimed - lane:marketing` / `♻️ Reaper requeued` /
  `Director approved → …` comment after an ask → NOT answered; the CLI probe exits
  3 **with the refusal on stderr**; mixed case (signature line, then Vas's real
  answer) → exit 0 returning Vas's line only. With the current code this FAILS
  (the status line reads as the answer) — the test is the repro.
- **ALARM.** `alarm_clear` with an unmarked signature line after the watchdog's
  ask → flag removed, not `board:responded` (mirrors existing case 11).
- **STRUCTURE PIN.** A bash grep asserting the only `commentCreate` sites in
  `_linear_api.py` are `comment()` and `_comment_url()` and both route through
  `_stamp_marker` — a future raw poster cannot slip in unnoticed.
- **Existing cases 1-12 stay green** — the `answered()` helper unpacks the
  extended `board_answers` return; no pinned behavior changes. No new file to
  register (`run-all.sh` globs `tests/*-test.sh`; the GSAI-30 scrub keeps
  `LINEAR_API_KEY` out).

Full `tests/run-all.sh` must stay green — nothing else in the repo pins comment
text (verified: no test asserts on the engine's comment bodies or the
`comment()` mutation).

## Post-merge verification (for the Dev-Director, not this pass)

The acceptance "a reconcile dry-run over the current 22 board issues flips
nothing": loop `directors/run.sh answer <id>` over every `board:to_review` issue
in the Board view — every one must exit 2 or 3; any exit 0 must be a comment Vas
actually wrote. Plus: the next natural Dozer run on any board issue leaves
`<!-- board-note by:… -->` on its status comments — one glance at a fresh claim
comment confirms the write side live.

## Risk

Low and layered. The stamp changes only bodies that today are guaranteed unmarked
(making them match the read-side rule that already exists), the guard only
*removes* auto-approvals (never creates one), and both are pinned by a regression
test that reproduces the measured incident. The one real behavioral risk — a
refusal swallowing a genuine answer — is by design visible (stderr + the ask stays
on the Board) and recoverable by hand, which is strictly safer than the status quo:
a question Vas never saw being marked answered by a machine.