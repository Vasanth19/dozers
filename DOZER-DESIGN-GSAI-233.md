# Design — GSAI-233: `video.sh` submits via HeyGen Remote MCP (OAuth, web-plan credits)

## What's true today

`dozers/mktg-lane/video.sh` Phase 1 (SUBMIT) is deliberately **not automated**. The
vault's `HEYGEN_API_KEY` only funds ~1 render on the api-key credit pool (`api: 2
credits`); the real, usable credit balance lives on the HeyGen **web account**. So
today, when no matching `completed` render is found by title, the crew calls
`submit_instruction()` and `fail()`s — it prints the exact HeyGen UI steps (avatar,
voice, Motion Engine: Avatar III, title, save `heygen-submission.json`) and blocks the
issue for Vasanth to do by hand in Chrome. `hg_get()` hard-refuses any HeyGen path that
looks like `generate|submit|create` — "This crew NEVER calls a HeyGen generate
endpoint" is enforced in code, not just prose.

GSAI-233 removes that human step **for the submit action only**. Status/list reads
stay exactly as they are.

## Approach

**Use HeyGen's Remote MCP (OAuth, web-account credits) as a deterministic JSON-RPC
peer, called directly by `video.sh` via curl/python3 — not routed through a model.**

Rejected alternative: have the Phase 3-style `MODEL_CMD` model call the Remote MCP tool
(the model CLI already has native MCP OAuth handling, which would save us writing a
token-refresh dance). Rejected because Phase 1 is a strict, zero-creative-freedom,
**money-spending** action — the existing doctrine forbids the crew from ever touching a
generate endpoint precisely as a financial control, not because the step needs
judgment. Handing an irreversible spend to a probabilistic model call is a safety
regression versus a deterministic, code-reviewed payload; it's also materially less
testable — the existing suite's whole method is "assert on the exact request that went
over the wire" against a stub HTTP server, which a model-mediated tool call can't give
us without stubbing the model too (and then we're testing the stub, not the crew).
Flagging this in case the Dev-Director wants to override.

### New Phase 1 flow

1. Title-search (`/v1/video.list`, unchanged) or recorded `videoId` — **exactly as
   today**. This is the existing dedup/resume mechanism; it runs *before* any submit
   decision, so a crash right after a successful submit (record not yet written) is
   still recovered by HeyGen being the source of truth.
2. If nothing found (today's `NOSUBMIT` case), the render is stale (script sha/mtime
   mismatch), or the found render's status is `failed`/`rejected`/`cancelled` — call
   the new `auto_submit()` instead of `submit_instruction()`+`fail()`. All three sites
   collapse into one function: they all mean "no usable render exists, make one."
3. `auto_submit()`:
   - Resolves `avatar_id`/`voice_id` from `.config/brand.yaml` (already parsed today,
     just moved from post-hoc record-writing to a pre-submit **requirement** — fail
     fast if either is missing; today it was optional because a human filled it in).
   - Reads the TTS text: prefer `script/tts.md` verbatim (that's what the filename
     promises); if only `script.md` exists, require a delimited block (`<!--
     tts:start -->` … `<!-- tts:end -->` or a `## TTS Script` heading) and fail fast if
     it can't find one — never guess which part of a mixed file is speakable text on a
     paid call.
   - Fixed params: Motion Engine **Avatar III** (never Avatar V), portrait 1080x1920,
     MP4, watermark off, title = `$WANT_TITLE` exactly. These are hardcoded constants
     mirroring today's human instruction text, not brief-controlled — a brief cannot
     upgrade its own render engine.
   - Calls `hg_mcp_call <tool> <json-args>` (new helper, mirrors `hg_get`'s shape).
   - On success: immediately `write_record` with `status=submitted`,
     `videoId=<returned id>`, `motionEngine`, `creditsCost`, `scriptSha256`,
     `submittedAt`, `submittedBy="dozer mktg-lane/video.sh (auto via Remote MCP)"` —
     written *before* anything else, so the local record and HeyGen's own state agree
     even if the rest of the run then fails.
   - Falls through into the **existing** status-check branch (freshly submitted =
     `processing`/`pending`), which already `fail()`s with "still processing,
     re-greenlight once it completes." No new polling/waiting code — Phase 1 keeps the
     same one-shot-per-invocation contract every other phase has (bounded by
     `timebox`, never holds the slot).

   This also means a genuinely stale-but-completed render now gets a fresh submit
   automatically instead of blocking — a deliberate, in-scope improvement: the same
   code path already existed for "nothing found," STALE is just another way to reach
   "no usable render exists."

4. **Duplicate-spend guard**: a submit only happens when step 1's search found
   *nothing usable*. On the next greenlight after an auto-submit, the search finds the
   just-created render (by title, most-recent-first) and — if still processing — hits
   the unchanged "still processing" branch, not `auto_submit()` again. Only a genuine
   `failed`/`rejected` status re-triggers a submit, and only once per invocation.

### `hg_mcp_call` — the new HeyGen Remote MCP client

- New vault file `~/ecosystem/vault/heygen-mcp-oauth.env` (chmod 600, vault-first,
  never printed) holding `HEYGEN_MCP_ACCESS_TOKEN`, `HEYGEN_MCP_REFRESH_TOKEN`, and
  whatever client id HeyGen's OAuth app requires for a refresh grant. **Populating this
  file the first time is a one-time human OAuth login, outside this script** (same
  category as the existing "the API key must be added to the vault manually once") —
  `video.sh` is headless and never performs an interactive login.
- New knobs alongside the existing `HEYGEN_*` ones: `HEYGEN_MCP_VAULT` (default the
  file above), `HEYGEN_MCP_URL` (Remote MCP endpoint — **open question, see below**),
  `HEYGEN_MCP_TOOL` (submit tool name — **open question**).
- `hg_mcp_call <tool> <json-args>`: POSTs a `tools/call` JSON-RPC request over MCP's
  Streamable HTTP transport with `Authorization: Bearer $HEYGEN_MCP_ACCESS_TOKEN`. On a
  401, attempts exactly one refresh (POST the refresh grant, rewrite the vault file
  atomically — `write_record`'s tmp+rename pattern, not `write_record` itself since
  this is a different file), retries once, then fails hard — **never** falls back to
  the plain `HEYGEN_API_KEY` for a spend call, matching the existing "never a raw
  generate endpoint" doctrine (now scoped to "never via the api-key pool").
- Missing vault file / empty tokens / refresh failure → `fail()` naming the vault path
  and "run the one-time HeyGen Remote MCP OAuth login, then re-greenlight" — phrased so
  it reads as `stuck:credits`/`stuck:access` to whoever triages the block, not
  `stuck:decision` (nobody needs to *decide* anything, the login just needs doing).
- Insufficient web-plan credits reported by HeyGen on submit → `fail()` with HeyGen's
  exact error text verbatim, no retry, no silent fallback.

### Open questions for the BUILD pass (do not guess these)

- The exact Remote MCP endpoint URL and the submit tool's name/schema — pull from
  HeyGen's own current docs at build time, not from memory. If the connected `heygen`
  MCP server in this environment (currently the local `uvx heygen-mcp` stdio server,
  api-key-only — a *different* server from the Remote MCP this task needs) exposes a
  way to introspect the Remote MCP's tool schema, use that; otherwise fetch HeyGen's
  docs directly.
- Whether the submit tool's motion-engine parameter takes an enum string (`avatar_iii`)
  or a numeric id — confirm against the live schema before hardcoding.
- Whether a refresh grant needs a client id/secret pair or is refresh-token-only —
  shapes what else the vault file needs to hold.

## Files to touch

- `dozers/mktg-lane/video.sh` — rewrite Phase 1 header comment (lines 11-15 no longer
  describe a human step); add the new knobs near the existing `HEYGEN_*` ones; add
  `hg_mcp_call`; add `auto_submit()`; replace the three `submit_instruction()`+`fail()`
  call sites (NOSUBMIT, STALE, STALE-MT, and the failed/rejected status case) with
  calls into it; drop the now-stale "API key funds ~1 render" credits-accounting
  comment since the api key no longer funds anything spend-related.
- `tests/mktg-lane-video-test.sh` — extend the stub HTTP server to also answer MCP
  `tools/call` (submit) and a token-refresh endpoint; rename/repurpose `NOSUBMIT` to
  `AUTOSUBMIT` (asserts the exact submit payload: avatar/voice ids, Avatar III, title,
  script text, 1080x1920) and that it lands in the "still processing" block, not a
  human-instruction block; update `STALE`/`STALE-MT` to expect an auto-resubmit
  (new `videoId`) instead of a block; add `MCP-NOKEY` (vault file missing →
  fails naming the vault path, HeyGen never contacted at all — REST or MCP) and
  `MCP-REFRESH` (expired access token → one transparent refresh → submit succeeds).
  Keep `NOV2`'s "no forbidden endpoint" assertion, broadened to also assert no raw
  REST generate/submit path is ever hit (submission only ever goes through
  `hg_mcp_call`).
- No `org/config.yaml` changes expected — the MCP call gets a fixed curl timeout
  (mirrors `hg_get`'s `-m 60`), not a new `timeout_*` knob; `timebox`/`T_MODEL` are
  unaffected since Phase 1 stays a plain curl, not a model run.
- **Not touched, flagged as a follow-up**: brain `vasanth-hq/sops/content-production-pipeline.md`
  (Phase 1 — HeyGen submit via Chrome) documents the old human step. SOPs live in
  GBrain, not this repo (per doctrine) — the Director should update that page after
  this merges, or the runbook will actively mislead the next person who reads it.

## Edge cases

- OAuth access token expired, refresh token valid → one transparent refresh, one retry,
  logged; no user-visible failure.
- Refresh token itself invalid/revoked → fail fast, same message as "vault missing,"
  never silently fall back to the api-key pool.
- Brand has no `avatarId`/`voiceId` in `.config/brand.yaml` → fail fast (this was
  optional before; auto-submit makes it required).
- No extractable TTS text (`script/tts.md` absent, `script.md` has no delimited block)
  → fail fast, never submit partial/wrong text on a paid call.
- HeyGen reports insufficient web-plan credits → fail fast with HeyGen's own error
  text, no retry loop that could compound the problem.
- A render already `processing` from a prior auto-submit → search finds it by title,
  falls into the existing "still processing" branch, does **not** resubmit (duplicate
  spend guard, see above).
- Script edited after a completed render (today's STALE case) → now auto-resubmits
  instead of blocking; the new render's `scriptSha256` matches current, so it will not
  be judged stale again.
- Crash between a successful HeyGen submit and the local `write_record` → recovered on
  the next run by the title search against HeyGen's own `/v1/video.list`, same as
  today's crash-recovery story for downloads.
- `DRY_RUN=1` / tests: `HEYGEN_MCP_URL` gets the same "point it at the local stub"
  treatment as `HEYGEN_API_BASE` — no live network calls in the test suite.

## How it gets tested

Extend `tests/mktg-lane-video-test.sh`'s existing single stub HTTP server (no live
HeyGen, no live MCP, no credits spent) to also serve:

- `POST <mcp path>` — a minimal JSON-RPC `tools/call` handler for the submit tool.
  Logs the exact request body so tests can assert on the real payload (avatar id,
  voice id, `avatar_iii`, exact title, exact script text) rather than trusting a
  description of it.
- A token endpoint for the refresh-grant case.

New/changed cases (existing COPY/HAPPY/RERUN/NOKEY/UNAUTH/NOV2 keep their current
meaning for the REST status/list path, which is unchanged):

- `AUTOSUBMIT` — no record, no matching render: asserts the submit call fires with the
  correct payload, a `status=submitted` record is written, and the run ends in the
  "still processing, re-greenlight later" block (not a human-instruction block).
- `STALE`/`STALE-MT` — updated to expect an auto-resubmit (new `videoId` recorded)
  instead of a block.
- `MCP-NOKEY` — `~/ecosystem/vault/heygen-mcp-oauth.env` (test-pointed) missing →
  fails naming the vault path; stub server never receives any request at all.
- `MCP-REFRESH` — stub rejects the stored access token once (401), video.sh refreshes,
  retries, submit succeeds.
- `MCP-CREDITS` — stub's submit response simulates HeyGen's insufficient-credits error
  → fails with that exact text, no retry.
- `NOV2` broadened: assert no raw `generate`/`submit`/`create` REST path is ever hit —
  only `hg_mcp_call`'s JSON-RPC path is allowed to create a render.

All cases keep running against the throwaway `mr-growth-guide` fixture brand, no live
API, no credits spent, exit non-zero on any failure — same contract as today.
