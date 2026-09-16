# GSAI-150 — design: the double eval executes the diff as shell — every review

**Task:** the dev lane's `run_model_pass` builds the model command by `eval`-ing a
string the prompt (with the branch diff) was already substituted into. The second
`eval` re-parses the prompt as shell code, so every `$( … )` and backtick in the
review diff — and any metacharacter in a task title — is EXECUTED by the crew, and
quotes in the diff silently mangle the prompt the model actually receives. This
happens on every review pass of every task.

**Repo:** dozers (main-only). **Files touched:** `dozers/dev-lane/crew.sh` (one
cmd-string, line ~304) + a new `tests/dev-lane-model-prompt-test.sh`, registered in
`tests/run-all.sh`. Nothing else.

---

## The bug, precisely

`dozers/dev-lane/crew.sh:303-304` hands timebox this cmd-string:

```bash
_PASS_BLOCK="$_PASS_BLOCK" _PASS_PROMPT="$2" timebox "$T_MODEL" "$1 agent" "$WT" \
    'eval "$_PASS_BLOCK"; eval "$MODEL_CMD \"$_PASS_PROMPT\""' || rc=$?
```

`timebox` (timebox.sh:68/76) runs `( cd <dir> && eval <cmd-string> )`. Trace the two
evals:

1. **eval #1** parses `eval "$MODEL_CMD \"$_PASS_PROMPT\""`. `\"` yields a literal
   quote character, but `$_PASS_PROMPT` is **expanded here** — its full text (the
   review prompt, with `$(git diff "$base")`'s output embedded by the heredoc at
   crew.sh:571-584) is substituted INTO the string. The argument handed to eval #2
   is therefore the *concatenated text* `<MODEL_CMD> "<entire prompt>"`.
2. **eval #2** parses that text **as shell code**. Inside double quotes bash still
   executes `` ` … ` `` and `$( … )`. A diff line like
   `+echo "sha $(git rev-parse --short HEAD)"` — routine in this very repo — runs
   `git rev-parse` as a side effect of *building the command line*. A malicious or
   merely unfortunate diff (`` `curl …` ``, `$(rm -rf …)`) executes with the crew's
   permissions, from the worktree, inside the timebox.

So "double eval executes the diff as shell — every review" is literal: the review
prompt is untrusted, model-authored text (the diff comes from whatever the BUILD pass
wrote, which itself came from a model), and it is re-parsed by a shell on every
review — initial review, rebuild re-review, all of them. The architect and build
prompts ride the same line; their payload is the Linear task title (Director-written,
but still outside the crew's trust boundary), so a title containing `$( … )` executes
too, and a title with a stray `"` corrupts the prompt.

Secondary defect, same line: **prompt mangling.** A diff containing a `"` (most diffs
do — JSON, `"test"` in package.json, quoted strings everywhere) toggles eval #2's
quote state; argument boundaries shift and the model receives a different prompt than
the crew assembled. This is silent — no non-zero exit, just a judge reading corrupted
evidence.

**Why the marketing lane is NOT affected:** `dozers/mktg-lane/crew.sh:173` passes
`"$MODEL_CMD \"\$PROMPT\""` — the `$` is escaped, so `$PROMPT` expands once, inside
double quotes, at the single eval's parse; an expansion result inside quotes is never
re-parsed. That lane is safe and untouched. `dozers/model.sh:45` (smoke) has the same
escaped-dollar shape with a fixed prompt — safe, untouched.

## Approach — escape the prompt's `$` in the cmd-string (the mktg-lane shape)

One-line change to the cmd-string in `run_model_pass`:

```bash
'eval "$_PASS_BLOCK"; eval "$MODEL_CMD \"\$_PASS_PROMPT\""'
```

Trace after the fix: eval #1 now yields eval #2 the *code*
`<MODEL_CMD> "$_PASS_PROMPT"` (the `$` is a literal character, not expanded). Eval #2
parses that code: `$MODEL_CMD`'s value was already expanded by eval #1 **after**
`eval "$_PASS_BLOCK"` ran in the same shell, so the per-pass route's `MODEL_CMD` is
what's on the line (route isolation, GSAI comment at crew.sh:241-248, unchanged).
`$_PASS_PROMPT` then expands **inside double quotes at parse time** — bash hands it to
the model CLI as ONE argument and never re-parses the value. Command substitutions,
backticks, quotes, `$` signs in the diff become inert bytes of the argument.

What the fix deliberately keeps:

- The per-pass route-block dance (`eval "$_PASS_BLOCK"` first, so ANTHROPIC_*/token
  exports live exactly as long as the pass) — untouched, byte-identical.
- The `MODEL_CMD` bypass branch (`resolve_pass` sets `_PASS_BLOCK=":"` when MODEL_CMD
  is already in the env) — the same cmd-string serves it; the `:` is a no-op and the
  prompt is still single-expanded.
- timebox's process-group kill, `TIMEBOX_HIT`, the proof/rescue logic (GSAI-147) — all
  downstream of the timebox call, untouched.
- The heredoc that builds the review prompt (crew.sh:571-584) — `$(git diff …)` is
  *supposed* to execute there, once, by the crew itself; that is the deliberate,
  trusted data-gathering step. The vulnerability was only the round-trip through two
  evals. Unchanged.

A hardening comment (3-5 lines) goes on the cmd-string so the next reader knows why
the `\$` is load-bearing: "the prompt is untrusted text (a diff / a title); it must
expand exactly once, inside double quotes, or its shell metacharacters execute."

**Considered and rejected:** passing the prompt via a temp file + a `$(cat file)`
inside the cmd-string (same one-eval property, but adds a file lifecycle the crew's
fail-fast paths would have to clean up, and `claude -p` takes the prompt as argv —
the file buys nothing); `printf %q`-quoting the prompt into the string (works, but
bloats the cmd-string by the whole prompt and is harder to read than one backslash);
dropping the second `eval` entirely (`$MODEL_CMD` would expand at eval #1 parse time,
*before* the route block ran — it must stay split exactly as it is).

## Edge cases

| Case | Behavior after the fix |
|---|---|
| Diff contains `$(cmd)`, `` `cmd` `` | Passed verbatim as prompt text; nothing executes |
| Diff contains `"`, `'`, `\` | Prompt arrives byte-identical; no quote-state shift, no mangled review input |
| Task TITLE contains shell metacharacters | Same — architect/build prompts safe (title is also untrusted) |
| Prompt is empty | `""` empty argument, same as today; the pass artifact checks catch it |
| MODEL_CMD env bypass | Same cmd-string; `_PASS_BLOCK=":"` no-op, prompt still single-expanded |
| Multi-line prompt with newlines | One argv, newlines intact (expansion inside quotes preserves them) |
| Very large diffs (argv size limit, ~256KB macOS) | Same exposure as today — the diff already rides one argv; out of scope |
| mktg lane, model.sh smoke | Untouched (already safe — escaped `$`, single expansion) |

## How it gets tested

New `tests/dev-lane-model-prompt-test.sh`, in the idiom of
`dev-lane-model-exit-test.sh` (throwaway repo + stub agent through the MODEL_CMD
bypass, plus one case on the routed path). It proves the property, not the incident:

- **INJECTION — the headline.** A stub build pass commits a source file whose diff
  contains `$(touch pwned-by-review)` and a backtick form `` `touch pwned-too` ``.
  The stub review pass writes its `$1` (the prompt it actually received) to a file
  instead of reviewing. Run the crew. Assert:
  1. **neither marker file exists** in the worktree or the repo — with the current
     code this test FAILS (both files appear; that is the bug's mechanical proof);
  2. the prompt the review stub received contains the `$(touch …)` line **verbatim**
     (round-trips as data) — this also catches the quote-mangling defect;
  3. the crew still completes and merges (the fix changes no gate).
- **ROUND-TRIP — the mangled-prompt half.** A diff line with an odd number of `"`
  (e.g. `+"test"` … a line with a lone `"`), and a title with a `$(echo hi)` in it
  (passed via the crew's `$2`). Assert the captured architect prompt contains the
  title's `$(` characters literally, and the captured review prompt contains the
  quote line literally. Under the current code the review prompt arrives shifted.
- **ROUTED PATH.** One INJECTION run on the routed branch (scrubbed MODEL_CMD, stub
  `claude` on PATH — same `SCRUB_ROUTE` discipline as dev-lane-model-exit-test.sh) so
  the fix is proven on the route-block path (`eval "$_PASS_BLOCK"`) too, not only the
  bypass.
- **REGISTRATION.** Add the file to `tests/run-all.sh` next to
  `dev-lane-model-exit-test.sh`, honoring its GSAI-30 scrub contract (the suite runs
  inside a real crew where MODEL_CMD is exported).

The build pass should first write the INJECTION case, run it against the unpatched
crew, and observe it fail with both marker files present (the mechanical proof of the
bug), then apply the one-line fix and watch it pass — the test is the repro.

All existing suites must keep passing untouched; `dev-lane-model-exit-test.sh` is the
canary that the rescue/proof machinery still works through the changed cmd-string.

## Risk

Low and contained. One cmd-string character-class change inside a function whose
callers and downstream logic are untouched; the trace above is mechanical, and the
regression test asserts both the security property (no execution) and the fidelity
property (byte-identical prompt). The one behavioral difference a fix could hide —
prompt expansion moving from eval #1 to eval #2 — is the entire point, and it happens
in the same subshell with the same env, so route resolution and timebox semantics are
invariant.

The trace above was confirmed with a live repro of the exact invocation shape (the
two-eval line driven against a stub `_PASS_BLOCK`/`_PASS_PROMPT` containing a diff
with `$(touch …)` and a backtick form):

- **current cmd-string:** both substitutions EXECUTED (both marker files appeared)
  — and notably they executed even though the stub model command itself failed with
  "command not found": the substitutions run while *constructing* the command line,
  before the CLI is ever consulted.
- **fixed cmd-string (`\$`):** the stub model CLI received `argc=1` — the prompt as
  ONE byte-identical argument, markers untouched, quote line intact.

So the two-eval claim is proven, not inferred. The regression test below is that
repro, productized.

## Post-merge verification (for the Dev-Director, not this pass)

- `bash tests/dev-lane-model-prompt-test.sh` green; full `tests/run-all.sh` green.
- Grep that no other crew site substitutes an untrusted payload into an eval'd
  string un-escaped (the two-lane audit above found none; model.sh smoke and the
  mktg lane are the safe shapes to pattern-match against).