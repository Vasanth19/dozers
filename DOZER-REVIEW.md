# DOZER-REVIEW — GSAI-73 (review pass)

VERDICT: PASS

## What the task asked and what shipped

The spec: `org/config.yaml`'s alarm-block NOTE was stale — it still described the
2026-09-03 state (Buzz key cleared, hop skipped, Linear alone) while the hop has been
live since 2026-09-08. The fix rewrites the NOTE to the current truth and adds one
reporting line to `heartbeat-check.sh creds`. Diff scope is exactly the design's:
`org/config.yaml` (comment-only) + `dozers/heartbeat-check.sh` (+7, one print) +
`DOZER-DESIGN.md`. No behavior change anywhere else.

## Why it satisfies the spec and follows the design

1. **The NOTE now carries the four facts the design required** (org/config.yaml:117-131):
   hop LIVE signed as Guzz; the compressed 2026-09-03 → 2026-09-08 key history; the
   closed-relay reality (Guzz is only a channel member, `BUZZ_AUTH_TAG` is the NIP-OA
   owner attestation that makes publishing possible, with the owner-rotation re-mint
   warning); and the preserved "do NOT repoint `alarm_env` at buzz-owner.env" rule.
2. **The design's load-bearing mechanism claim is true in code**: the whole vault file
   is sourced under `set -a` (heartbeat-check.sh:86-93), so `BUZZ_AUTH_TAG` reaches the
   `buzz messages send` child (heartbeat-check.sh:284) with no code change — exactly as
   the NOTE now tells the operator.
3. **The `creds` addition matches the design verbatim** (heartbeat-check.sh:360-366):
   both print strings are word-for-word from the design; it prints presence only —
   never the tag value — consistent with the function's no-secrets contract and the
   test's leak assertions (`creds never prints the … key value` stays green). It is
   placed after the verdict inputs are gathered and deliberately does NOT flip the
   verdict (an open relay needs no tag — the design's edge-case table is honored).
4. **Design's grep claim verified**: no other test asserts on NOTE text or `creds`
   output shape; the only "Buzz hop" assertions in tests are the pre-existing optional-
   skip cases and the substring-based creds verdicts, all unaffected.
5. **Tests green — run by this review, not just claimed by the design**:
   `tests/heartbeat-check-test.sh` PASS in isolation, and the full `make test` on this
   branch: **PASS — 33/33 in 905s**.

## One red observed and run down (transparency — resolved as an upstream flake)

The first full-suite run reported `dev-lane-migration-gate-test.sh` FAIL (OVERRIDE
case: crew exited 1, `[skip-migration]` escape hatch not honored). Investigated before
ruling:
- It **cannot be this branch's doing**: every file in that failure's code path
  (`crew.sh`, `timebox.sh`, `model.sh`, the test itself) is byte-identical to develop,
  and the test's crews read none of the three changed files — the test points
  `REPO_ROOT` at a throwaway dir, so even `org/config.yaml` is not read.
- It is **intermittent**: the same test passed on this branch in isolation, again in
  the second full-suite run (33/33 above), and 3/3 times on a develop checkout under
  identical conditions.

Verdict impact: none for GSAI-73. But the flake is real (two observed failures) and
lives in develop-carried code — recommend a separate issue for the Dev-Director to
greenlight a deterministic reproduction of the migration-gate OVERRIDE path.

## Nits (non-blocking)

- The `alarm_env:` inline comment still says the vault file holds
  `BUZZ_PRIVATE_KEY + BUZZ_RELAY_URL`; it now also holds `BUZZ_AUTH_TAG`. The NOTE
  directly below explains this, so the config remains self-consistent.
- The `creds` line landed after the `buzz cli` line rather than "after the key loop"
  as the design sketched — cosmetic placement inside the same section.
- The `auth tag : present ✓` branch is not exercised by any fixture (test vaults carry
  no tag); the "not set" branch is covered by the passing creds tests. A presence-only
  printf — negligible risk, not worth new fixture plumbing.

## Provenance note

The implementation (`d53b269`) was committed before the design pass (`bbb692e`) — the
design documents this openly, and this review confirms the committed code matches the
design that was then written for it. No rework required.