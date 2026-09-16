# GSAI-73 — design: the alarm NOTE in org/config.yaml is stale — the Buzz hop is live and speaks as Guzz

**Task:** `org/config.yaml`'s alarm-block NOTE (pre-fix lines 109-114) still described
the **2026-09-03** state: `BUZZ_PRIVATE_KEY` deliberately cleared from `buzz.env`,
the Buzz hop skipped, Linear carrying the alarm alone. That stopped being true on
**2026-09-08**, when Guzz's key was recovered from the macOS login keychain back
into the vault — `heartbeat-check.sh creds` has reported "Buzz hop: CAN DELIVER ✓"
since. A config comment that tells an operator a live alarm channel is dead is worse
than no comment: the operator who reads it will "fix" a working channel or, worse,
stop trusting the config as a source of truth.

**Repo:** dozers (main-only). **Files touched:** `org/config.yaml` (the NOTE
rewrite) and `dozers/heartbeat-check.sh` (one reporting line in `creds`).
Nothing else — no behavior change, no new wiring.

> **Provenance note:** the implementation for this task was already committed on
> this branch (`d53b269`) by the prior session before this design was written.
> This document records the design that commit embodies; review of the committed
> diff found nothing that must change, so the code stands as-is.

---

## What the NOTE must now say (the current truth)

Four facts, none of which the old NOTE carried:

1. **The hop is LIVE and delivers signed as Guzz** — the Dev-Director identity,
   which is the Dozer's own voice. History stays in the comment, compressed to
   two lines: key deliberately cleared 2026-09-03 (identity moved into Buzz
   Desktop as a managed agent), recovered 2026-09-08 out of the login keychain
   (service `buzz-desktop`, account `secrets`, stored as `agent:<pubkey> → nsec`)
   back into `buzz.env`.
2. **The relay is CLOSED, so the key alone is not enough.** Guzz is only a
   channel member; publishing 403s `relay_membership_required`. `buzz.env` also
   carries **`BUZZ_AUTH_TAG`** — a NIP-OA attestation signed by the *owner* key
   delegating relay membership to Guzz. Events are still authored and signed
   **by Guzz**; the tag only proves the owner authorized the agent. This was
   never written down anywhere before — it is the part an operator cannot
   rediscover from the code.
3. **How the tag reaches the process:** the whole vault file is sourced under
   `set -a` in `heartbeat-check.sh`, so the tag reaches the `buzz` child without
   any code knowing about it. Consequence: **re-mint the tag if the owner key
   rotates**, or the hop starts 403ing with no visible change in the key check.
4. **The old rule survives unchanged:** do NOT repoint `alarm_env` at
   `buzz-owner.env` — that is Vasanth's own key, and an alarm signed as him is a
   lie about who is speaking. Guzz has his own identity precisely so the watchdog
   can speak as itself.

## The `creds` companion: print the auth tag

The NOTE is prose; `heartbeat-check.sh creds` is the command an operator actually
runs before trusting the alarm. It already prints the vault path, channel,
mention, `BUZZ_RELAY_URL`/`BUZZ_PRIVATE_KEY` export state, and the `buzz` CLI —
but the load-bearing `BUZZ_AUTH_TAG` was invisible, so a closed relay could look
fully armed and still 403 at the moment it was needed.

`creds` gains one line after the key loop:

- tag present → `auth tag : present ✓ (NIP-OA — closed-relay membership via the owner)`
- tag absent → `auth tag : not set — fine on an open relay; a CLOSED one 403s relay_membership_required`

**It deliberately does NOT flip the verdict.** The hop's green/red is keyed on
`BUZZ_PRIVATE_KEY` + relay URL + CLI, and that stays: an open relay needs no tag,
so a missing tag must not mark a working hop red. The line exists so an
unannounced 403 at alarm time — the exact failure `creds` exists to rule out —
is visible before the outage, without breaking the open-relay case.

## Edge cases

| Case | Behavior |
|---|---|
| Open relay, no `BUZZ_AUTH_TAG` | Verdict unchanged (CAN DELIVER ✓); line says "fine on an open relay" |
| Closed relay, tag present | Line confirms ✓ — matches the live config today |
| Closed relay, tag missing | Line names the 403 (`relay_membership_required`) but verdict stays green — the operator reads the line, not just the verdict |
| Owner key rotates, tag goes stale | NOTE says re-mint it; `creds` shows the tag state but cannot verify freshness — the failure mode at publish time, out of scope here |
| `buzz` CLI absent / key absent | Untouched — existing optional-hop logic (quiet skip, verdict "skipped (optional)") |
| Secrets in output | None — the line prints presence/absence only, never the tag value |

## How it gets tested

`tests/heartbeat-check-test.sh` already pins the alarm-hop logic; the committed
change adds no behavior to pin — only an unconditional print of a presence
check. The full suite was run on this branch after the fix: **PASS** (all cases
green, including "creds reports the Buzz hop as live when its key is present"
and "fails loudly when NEITHER channel can deliver"). No other test asserts on
NOTE text or `creds` output shape (verified by grep — the only "Buzz hop"
reference in tests is the pre-existing skip case, which is still true behavior).

## Risk

Minimal. A comment rewrite cannot break runtime; the `creds` addition is a
read-only `printf` on an env-var presence check placed *after* the verdict
inputs are gathered, so it cannot alter any existing branch. The only real risk
was leaving the stale NOTE in place — an operator debugging a silent alarm being
sent down the wrong path by the config itself.