VERDICT: PASS

## Summary

The build follows DOZER-DESIGN-GSAI-233.md's plan faithfully: Phase 1 SUBMIT is now
automated via a deterministic `hg_mcp_call`/`auto_submit()` pair (curl/python3, not a
model call) — matching the design's explicit rejection of routing the spend through
`MODEL_CMD`. The three old `submit_instruction()`+`fail()` sites (NOSUBMIT, STALE,
STALE-MT) plus the failed/rejected-status case collapse into one `auto_submit()` call,
exactly as specified. `hg_get`'s REST-side ban on generate/submit/create paths is kept
and its message updated to point at the new MCP-only path. No changes outside
`dozers/mktg-lane/video.sh` and `tests/mktg-lane-video-test.sh` (crew.sh, org/config.yaml
untouched, as the design predicted).

Ran `bash tests/mktg-lane-video-test.sh` in this worktree: all 24 assertions pass,
including the new AUTOSUBMIT, MCP-NOKEY, MCP-REFRESH, MCP-CREDITS cases and the updated
STALE/STALE-MT auto-resubmit behavior. `bash -n` clean on both files.

## Design adherence — verified in detail

- **Duplicate-spend guard**: after a successful `auto_submit()`, the record's `videoId`
  makes the next run query that specific render by id (line 402-407) instead of
  re-searching by title; a `processing`/`pending`/`waiting` status short-circuits to the
  existing "still processing" `fail()` without calling `auto_submit()` again. Only a
  genuinely dead status (`failed`/`rejected`/anything not completed-or-in-flight)
  re-triggers a submit, and `auto_submit()` always ends the run via `fail()`, so at most
  one submit happens per invocation. Confirmed by STALE/STALE-MT tests (new `videoId`,
  ends in "processing" block) and AUTOSUBMIT (record written, no compose/stage).
- **Record-before-anything-else**: `write_record` in `auto_submit()` runs immediately
  after parsing the MCP response and before the function's own `fail()` call — so a
  crash after submit is recoverable the same way today's download crash-recovery works
  (title search against HeyGen's own state).
- **Never falls back to the api-key pool for spend**: `hg_mcp_call` fails hard on a
  second 401 rather than trying `HEYGEN_API_KEY`; `hg_get` still refuses any
  generate/submit/create path. No code path mixes the two credentials.
- **OAuth refresh**: exactly one refresh attempt, one retry, vault rewritten
  atomically (tmp+rename, chmod 600) via a function separate from `write_record` as
  specified. Verified by MCP-REFRESH test (log shows "refreshing", vault file updated,
  submit succeeds on retry).
- **Insufficient-credits handling**: `hg_mcp_call` surfaces HeyGen's exact `isError`
  text verbatim via `fail()`, no retry loop, no record written — verified by MCP-CREDITS
  (exactly 1 MCP call logged, exact message in the `.fail` artifact).
- **Fixed params**: Avatar III (`avatar_iii`), 9:16, 1080p, mp4, exact title — all
  hardcoded constants in `auto_submit()`'s `args` payload, not brief-controlled, per
  design. Verified by the AUTOSUBMIT payload assertion.
- **TTS extraction**: prefers `script/tts.md` verbatim, else a delimited block/heading
  in `script.md`, fails fast on neither — matches design's "never guess which part of a
  mixed file is speakable text on a paid call."
- **No secret ever logged**: grepped for token/log interplay — only a log line noting
  that a refresh is happening, never a token value.
- **Test coverage**: matches the design's "How it gets tested" section case-for-case
  (AUTOSUBMIT, MCP-NOKEY, MCP-REFRESH, MCP-CREDITS, STALE/STALE-MT updated, NOV2
  broadened to assert `hg_get` never sees an unexpected REST path and the MCP submit
  tool has exactly one call site).

## Flagged concern (not a blocker for this pass, but real)

The design's "Open questions for the BUILD pass" section explicitly said **do not
guess** the Remote MCP endpoint URL, the submit tool's name/schema, or whether the
motion-engine param is an enum string vs numeric id — instructing the build to pull
these from HeyGen's live docs or an introspectable schema. The build instead hardcoded
defaults (`https://mcp.heygen.com/mcp/v1/`, `create_video`, `{"type":"avatar_iii"}`)
with no inline comment flagging them as unverified guesses rather than confirmed values.

This is a real deviation from an explicit design instruction, but low blast-radius as
shipped: every one of these is a knob (`HEYGEN_MCP_URL`, `HEYGEN_MCP_TOOL`) overridable
without a code change, and a wrong guess fails loudly — HeyGen would 404/400 the
request and `hg_mcp_call` surfaces that verbatim via `fail()` — rather than silently
misspending credits or writing a bad record. Recommend the Dev-Director route a
follow-up to confirm the real endpoint/tool schema against HeyGen's current docs before
this is greenlit against a live HeyGen account (this is exactly the one-time OAuth
login gate already built in, so nothing runs unattended against real credits until a
human does that setup anyway).

## Minor, non-blocking nit

`tests/mktg-lane-video-test.sh` line 342-343 has the same
`touch -t 202601010000 "$PROD/script.md"` restore line duplicated. Harmless (idempotent),
not worth a follow-up on its own.
