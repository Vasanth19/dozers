# Design — GSAI-237: HeyGen Remote MCP one-time OAuth login flow

## What's true today

GSAI-233 shipped `video.sh`'s **consumer** side: `hg_mcp_call`/`hg_mcp_refresh` read
`HEYGEN_MCP_ACCESS_TOKEN` / `HEYGEN_MCP_REFRESH_TOKEN` / `HEYGEN_MCP_CLIENT_ID` out of
`~/ecosystem/vault/heygen-mcp-oauth.env`, call HeyGen's Remote MCP over Streamable HTTP,
and do one 401-refresh-and-retry. But **nothing populates that vault file** — the design
doc explicitly deferred it ("a one-time human OAuth login, outside this script... video.sh
is headless and never performs an interactive login") and the build-pass review
(`DOZER-REVIEW-GSAI-233.md`) flagged that `HEYGEN_MCP_URL`
(`https://mcp.heygen.com/mcp/v1/`) and `HEYGEN_MCP_TOKEN_URL`
(`https://mcp.heygen.com/oauth/token`) were **hardcoded guesses**, not confirmed against
HeyGen's live schema, with an explicit recommendation to verify before this runs against
a real account. Today, with no vault file, every `auto_submit()` call fails fast with
"HeyGen Remote MCP not authorized... run the one-time HeyGen Remote MCP OAuth login" —
there is no such login to run. This task builds it.

## Approach

**A standalone, human-run, one-time script — `scripts/heygen-mcp-login.sh`
— that does a standard MCP Remote-server OAuth login (discovery + dynamic client
registration + PKCE authorization code) and writes the vault file `video.sh` already
reads.** It is never invoked by a Dozer crew; it lives in `scripts/` alongside the
repo's other human-run utilities (`quota-by-project.sh`, `spend-by-kr.sh`), not in
`dozers/mktg-lane/` — it is a credential-setup tool, not part of the lane.

### Why discovery instead of hardcoding more guesses

The reviewer's flagged concern is the reason this design does **not** simply hardcode an
`/oauth/authorize` URL next to the existing guessed `/oauth/token` one. The MCP
authorization spec (the same family HeyGen's Remote MCP implements, since `video.sh`
already talks to it as a standard JSON-RPC MCP endpoint) defines a discovery chain
specifically so a client never has to guess:

1. An unauthenticated (or stale-token) request to the MCP endpoint
   (`HEYGEN_MCP_URL`) gets a `401` carrying a `WWW-Authenticate` header that points at
   a **protected-resource metadata** document (RFC 9728,
   `/.well-known/oauth-protected-resource`).
2. That document names the **authorization server**; its own
   `/.well-known/oauth-authorization-server` (RFC 8414) document gives the real
   `authorization_endpoint`, `token_endpoint`, and (if supported)
   `registration_endpoint` — no memory, no guessing.
3. If a `registration_endpoint` is present, **Dynamic Client Registration** (RFC 7591)
   gets a `client_id` for this login tool without a human pre-registering one in a
   HeyGen developer console.
4. Standard **authorization code + PKCE (S256)** flow against the discovered
   `authorization_endpoint`, token exchange against the discovered `token_endpoint`.

This also resolves (for the token endpoint specifically) the exact gap the GSAI-233
review flagged — the login flow will know the *real* token endpoint, not the guessed
one. See "Flagged follow-up" below for the one piece this task deliberately does not
fix: `video.sh` itself still has the guessed `HEYGEN_MCP_TOKEN_URL`/`HEYGEN_MCP_URL`
*defaults* hardcoded, and this script does not patch `video.sh` — that file is out of
scope for a login-flow task and changing it belongs to whoever re-verifies the
`create_video` tool schema too (the review's other flagged guess, also out of scope
here).

### Flow

1. **Preflight.** Must run from a real terminal (human-interactive) — refuse under
   `DOZER_*`/non-interactive markers the same way a lane crew would never invoke this
   (belt-and-suspenders; nothing wires a crew to call it, but a script that *can* run
   headless and silently do nothing useful is worse than one that refuses loudly).
   `--headless` flag (see below) is the one sanctioned exception for an SSH session
   with no local browser.
2. **Discover.** Hit `HEYGEN_MCP_URL` (override via env, same knob name `video.sh`
   already uses, so one vault/env story). Parse the `401`'s `WWW-Authenticate` for
   `resource_metadata`; fetch it; fetch the named authorization server's metadata.
   Fail fast, naming exactly which fetch failed and the raw response, if HeyGen's
   Remote MCP does not actually implement this discovery chain — **never falls back to
   a hardcoded guess**, since that is precisely the failure mode this task exists to
   remove.
3. **Register (or reuse).** If `~/ecosystem/vault/heygen-mcp-oauth.env` already has a
   `HEYGEN_MCP_CLIENT_ID`, reuse it (re-registering on every re-login would leak
   abandoned client registrations on HeyGen's side). Otherwise, if the metadata has a
   `registration_endpoint`, POST a DCR request (`redirect_uris`: the loopback URL from
   step 4, `token_endpoint_auth_method: none` — a CLI script is a public client, it can
   hold a refresh token but not a client secret). No `registration_endpoint` and no
   pre-supplied `HEYGEN_MCP_CLIENT_ID` env override → fail fast naming both facts and
   telling the operator to obtain a client id out-of-band and re-run with
   `HEYGEN_MCP_CLIENT_ID=... scripts/heygen-mcp-login.sh`.
4. **Authorize (PKCE).** Generate a random `code_verifier`/`code_challenge` (S256) and
   `state`. Start a one-shot local HTTP listener on `127.0.0.1:<port>` (python3's
   `http.server` via a tiny handler, mirroring the repo's existing style of small
   inline `python3 - <<'PY'` blocks rather than a new dependency) bound to
   `/callback`; port is fixed-with-fallback (try `8743`, then `0` for OS-assigned if
   taken — never silently reuse a port something else owns). Build the
   `authorization_endpoint` URL with `response_type=code`, the loopback
   `redirect_uri`, `code_challenge`/`code_challenge_method=S256`, `state`, and a scope
   if the metadata advertises one. **Interactive mode (default):** `open` it (macOS;
   this repo's platform) and also print it, since the user may be in a different
   terminal than the one with a browser. **`--headless` mode:** print the URL only and
   prompt the operator to paste back the full redirect URL (or just the `code`) after
   authorizing elsewhere — no local listener needed in this mode.
5. **Capture.** The listener's one request to `/callback` is the redirect; verify
   `state` matches (reject + fail fast on mismatch — this is the CSRF guard PKCE
   flows rely on), extract `code`, respond to the browser with a plain "you can close
   this tab" page, and shut the listener down. Timeout (default 300s) → fail fast,
   nothing written.
6. **Exchange.** POST to the discovered `token_endpoint`:
   `grant_type=authorization_code`, `code`, `redirect_uri` (must match step 4 exactly
   — most authorization servers reject a mismatch), `code_verifier`, `client_id`. Parse
   `access_token`/`refresh_token`/`expires_in`. Missing `refresh_token` in the response
   → fail fast naming it explicitly (a long-lived crew with only an access token is a
   silent future outage — better to fail the login than ship a half-working one).
7. **Write the vault.** Same atomic pattern `hg_mcp_refresh` already uses in
   `video.sh` (tmp file, `chmod 600`, `mv -f`) — not reused code (different file, this
   is a standalone script) but the identical idiom: write
   `HEYGEN_MCP_ACCESS_TOKEN`, `HEYGEN_MCP_REFRESH_TOKEN`, `HEYGEN_MCP_CLIENT_ID` (so
   `video.sh`'s refresh path has it without the operator setting it manually), plus
   informational `HEYGEN_MCP_TOKEN_URL`/`HEYGEN_MCP_AUTHORIZE_URL` comments (as shell
   comments, not consumed by `video.sh`, purely so a human reading the vault file later
   can see what was actually discovered — see flagged follow-up). Never log or print
   any token value — only the path and a success/fail line, matching vault doctrine.
8. **Verify.** Immediately after writing, make one real `hg`-style call — reuse the
   discovery's own MCP endpoint with a harmless `tools/list` JSON-RPC call (not
   `create_video`; this script must never spend credits) using the fresh access token,
   confirm a non-401 response, and report success. Catches a token that was issued but
   doesn't actually work against the MCP endpoint before the operator walks away
   thinking they're done.

### Flagged follow-up (not in scope here, naming it so it isn't lost)

If discovery's real `token_endpoint` differs from `video.sh`'s hardcoded
`HEYGEN_MCP_TOKEN_URL` default (likely, since that default was an unverified guess),
`video.sh` will still refresh against the wrong URL until someone also exports
`HEYGEN_MCP_TOKEN_URL` for the Dozer crew or patches the default in `video.sh`. This
script prints a loud, explicit warning when the discovered token endpoint differs from
`video.sh`'s known default (hardcoded in this script purely as a comparison string, not
called), naming the exact export needed — but does not edit `video.sh` itself, since
that's a different file's scope and the GSAI-233 review already separately flagged the
`create_video` tool-schema guess as its own follow-up. Recommend the Dev-Director route
a small fast-follow once this merges.

## Files to touch

- **New** `scripts/heygen-mcp-login.sh` — the whole flow above. Bash + inline
  `python3` (for the loopback HTTP listener, JSON parsing, and PKCE verifier/challenge
  generation via `hashlib`/`secrets`), matching the repo's existing style (`video.sh`,
  `hg_mcp_refresh`) of no new language/dependency for a single script.
- **New** `tests/heygen-mcp-login-test.sh` — registered automatically by
  `tests/run-all.sh` (it globs `tests/*-test.sh`), no other wiring needed.
- **Not touched:** `dozers/mktg-lane/video.sh`, `org/config.yaml`, `crew.sh` — this is
  a human-run credential tool, not a lane or engine change. No new `dozer:ready`
  lane-crew code path is added.

## Edge cases

- **Vault file already has valid tokens.** Default behavior: re-run the full login
  anyway (the operator explicitly asked to log in) and overwrite — this is a
  deliberate "log in again" tool, not a lazy-refresh (that's `hg_mcp_refresh`'s job
  inside `video.sh`). Add a `--check` flag that only runs step 8 (verify) against the
  existing vault and exits, for "is my login still good?" without burning a new OAuth
  round-trip.
- **Existing `HEYGEN_MCP_CLIENT_ID` in the vault.** Reused, not re-registered (named
  above) — avoids orphaning a prior DCR client on every re-login.
- **Discovery chain missing a piece** (no `WWW-Authenticate`, no protected-resource
  metadata, no authorization-server metadata, no `registration_endpoint` and no
  client-id override): fail fast at the exact step, naming what was expected and what
  came back — never guess a URL to keep going.
- **`state` mismatch on callback** (another process hit the loopback port, or a replay):
  fail fast, nothing written, vault untouched.
- **Loopback port already bound.** Fallback to an OS-assigned port (`:0`), which is
  safe because the port only needs to match the `redirect_uri` registered/used in the
  *same* run (steps 3-4 build the `redirect_uri` from whatever port the listener
  actually bound, not a hardcoded constant).
- **Callback never arrives** (user closes the tab, abandons the flow): timeout, fail
  fast, nothing written — never hang indefinitely holding the port.
- **No `refresh_token` in the token response:** fail fast rather than writing a
  vault file that will silently stop working the moment the access token expires.
- **`--headless` with no `code` pasted back correctly** (truncated, wrong flow):
  validate it parses as the expected redirect shape before attempting exchange; fail
  fast with the exact parse problem rather than sending garbage to HeyGen.
- **Partial write crash** (process killed between token exchange and vault write):
  nothing persists since the write is the last step and is atomic (tmp+rename) —
  re-running the login is the recovery path, identical to today's story for
  `hg_mcp_refresh`.
- **Verify step (step 8) fails** even though a token was issued: still write the vault
  (the tokens are real, HeyGen issued them) but exit non-zero and print HeyGen's exact
  error, so the operator isn't left thinking they're done when `video.sh` will still
  fail on first use.

## How it gets tested

New `tests/heygen-mcp-login-test.sh`, same shape as `tests/mktg-lane-video-test.sh`
(one stub HTTP server, `DRY_RUN`-style env knobs pointing every URL at it, no live
HeyGen, no live browser, no real OAuth provider, exits non-zero on any failure). The
one piece that's inherently interactive — a human clicking "authorize" in a browser —
is simulated by having the test harness itself act as "the browser": after the script
prints/opens the authorization URL, the test parses the printed URL for `state` and
`redirect_uri` and issues the callback request itself (`curl` to the loopback listener)
instead of a real browser, which is the standard way to test a PKCE flow without UI
automation.

Cases:
- **DISCOVER-OK** — stub serves a correct 401 + `WWW-Authenticate` +
  protected-resource + authorization-server metadata chain; script reaches the
  authorize step with the right endpoints.
- **DISCOVER-NO-CHALLENGE / DISCOVER-NO-AS-METADATA** — stub omits
  `WWW-Authenticate` / the AS metadata document → fails fast naming the missing piece,
  no authorize URL ever printed.
- **DCR-OK** — stub's `registration_endpoint` returns a `client_id`; asserts it lands
  in the vault file and is reused (not re-POSTed) on a second run.
- **DCR-NONE-WITH-OVERRIDE** — no `registration_endpoint` in metadata, but
  `HEYGEN_MCP_CLIENT_ID` is set in the environment → skips DCR, uses the override.
- **DCR-NONE-NO-OVERRIDE** — neither → fails fast with the exact remediation message.
- **PKCE-HAPPY** — full round trip: verifies the `code_challenge` sent at authorize
  time is `S256(code_verifier)` of the `code_verifier` sent at token-exchange time
  (asserts the stub's token endpoint received the right verifier for its stored
  challenge — this is the test that proves PKCE isn't just plumbed in name only).
- **STATE-MISMATCH** — test's simulated "browser" callback uses a different `state`
  than the script generated → script rejects, nothing written to the vault.
- **NO-REFRESH-TOKEN** — stub's token response omits `refresh_token` → fails fast,
  vault untouched.
- **PORT-BUSY** — pre-bind the default port before running the script → asserts it
  falls back to an OS-assigned port and the `redirect_uri` used in the authorize URL
  matches that fallback port, not the busy one.
- **VERIFY-OK** — after a successful exchange, stub's MCP endpoint accepts
  `tools/list` with the new access token → script reports success.
- **VERIFY-FAILS-BUT-TOKEN-WRITTEN** — stub's MCP endpoint rejects the fresh token on
  the step-8 check → vault file still contains the issued tokens, but the script
  exits non-zero with HeyGen's verify error.
- **CHECK-FLAG** — `--check` against a vault pre-seeded with a working token hits only
  the verify step (asserted via the stub's request log: zero authorize/token-endpoint
  calls, exactly one MCP call).
- **HEADLESS-PASTE** — `--headless` run: script prints the URL and reads a pasted
  redirect URL from stdin instead of starting a listener; test feeds it the callback
  URL directly.
- **NO-TTY-REFUSES** — invoked with stdin/stdout redirected from `/dev/null` and
  no `--headless` → refuses immediately, no network call made at all.

All cases run against a throwaway vault path (`HEYGEN_MCP_VAULT` pointed at a test
tmpdir, never the real `~/ecosystem/vault/heygen-mcp-oauth.env`), no live network, no
real browser, no credits at risk — same contract as `mktg-lane-video-test.sh`. Add it
to `tests/run-all.sh`'s coverage for free (glob-based); confirm `make test` picks it up
and the full suite stays green.
