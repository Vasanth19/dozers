VERDICT: PASS

## Summary

GSAI-237 asked for the one-time HeyGen Remote MCP OAuth login flow that GSAI-233
deliberately deferred. The build delivers exactly that: `scripts/heygen-mcp-login.sh`
(human-run, standalone, not wired into `crew.sh`/`org/config.yaml`/`video.sh`) plus
`tests/heygen-mcp-login-test.sh`, both matching `DOZER-DESIGN-GSAI-237.md` closely.

## What I checked

- **Design fidelity.** Walked the script against the design's 8-step flow (preflight →
  discover → register/reuse → PKCE authorize → capture → exchange → vault write →
  verify). Each step is present and in the right order, including the
  listener-before-DCR ordering needed because `redirect_uri` must match exactly across
  DCR, authorize, and token exchange.
- **Scope discipline.** `git diff --stat develop..HEAD -- dozers/mktg-lane/video.sh
  org/config.yaml crew.sh` is empty — none of those files were touched, matching the
  design's explicit "Not touched" list. The GSAI-233 flagged follow-up (video.sh's
  guessed `HEYGEN_MCP_TOKEN_URL` default) is correctly left out of scope, with a loud
  runtime warning when discovery disagrees with it — and the warning's comparison
  string (`https://mcp.heygen.com/oauth/token`) is byte-for-byte what `video.sh` (line
  254) actually hardcodes, not a stale guess.
- **Ran the real test suite**, not just read it: `bash tests/heygen-mcp-login-test.sh`
  — all 15 assertions pass, including the PKCE one that matters most (the stub's token
  endpoint independently recomputes SHA256(code_verifier) against the stored
  code_challenge and rejects a mismatch, so HAPPY passing is real proof PKCE is wired
  correctly, not just plumbed in name).
- **Security/fail-fast posture.** No token value is ever printed (grepped the HAPPY
  log for both stub token strings — absent). Vault write is atomic (tmp + chmod 600 +
  rename), matching `hg_mcp_refresh`'s idiom. Every discovery/DCR/exchange failure
  path fails fast naming the exact gap, never falls back to a guessed URL — directly
  answering the GSAI-233 review's core complaint. State-mismatch and missing-refresh-
  token cases both confirmed to leave the vault untouched.
- `bash -n scripts/heygen-mcp-login.sh` — clean syntax.
- Confirmed `tests/run-all.sh` globs `tests/*-test.sh` with no manual registration
  needed, so the new test is picked up for free as the design claimed.

## Minor non-blocking notes (not worth a FAIL)

- `usage()` extracts help text via a hardcoded `sed -n '2,46p'` line range tied to the
  header comment block — if that header is edited later without updating the range,
  `--help` output will silently drift. Cosmetic, not a functional defect.
- RFC 8414's `.well-known` insertion-before-path rule isn't implemented (the script
  always appends `/.well-known/oauth-authorization-server` to the bare issuer host);
  fine for HeyGen's expected flat issuer URL, would need revisiting only if a future
  issuer uses a path-prefixed metadata document.

Neither affects correctness against the stated spec or introduces a security/fail-fast
violation. Implementation matches the design doc, the new tests genuinely exercise the
flow against a stub authorization server, and the full new suite passes.
