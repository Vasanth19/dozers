# DOZER-DESIGN-GSAI-262

**Title:** Render lane has no faceless path — a p-reels-faceless brief dies demanding a
HeyGen avatar it never uses (14 reels mis-blocked)

## 1. Root cause

`dozers/mktg-lane/crew.sh` routes **every** brief whose description carries a
`production:` line to `dozers/mktg-lane/video.sh` (crew.sh:111-120) — the routing
signal is purely "is this a video brief", never "which recipe does it name". But
`video.sh` was written, and is still documented (header, line 2: *"the HeyGen VIDEO
branch"*), as a single-avatar HeyGen pipeline: it unconditionally

1. loads `HEYGEN_API_KEY` from the vault (video.sh:171-174),
2. tries to find/auto-submit **one** HeyGen avatar render (`auto_submit()`,
   video.sh:340-399) — which hard-fails if `brand.yaml` has no
   `heygen.avatarId`/`voiceId` (video.sh:343: *"cannot auto-submit: ... required for
   an automatic HeyGen render"*),
3. runs a stale-render gate that only makes sense for a HeyGen render
   (video.sh:433-468),
4. downloads and ffprobe-asserts a `heygen/raw-avatar.mp4` (Phase 2, video.sh:470-525),
5. only then reaches Phase 3 (compose) and hands `RAW_AVATAR` to the recipe.

`RECIPE` itself is already resolved earlier (video.sh:131-169, from
`.brand/recipe-policy.yaml` + the brief's `Recipe:`/`Recipe deviation:` lines) — but
nothing branches on it before Phase 1. A brief naming `p-reels-faceless` (confirmed
`valid_non_default` in MGG's `recipe-policy.yaml`, requires a `Recipe deviation:`
line) still runs straight into `auto_submit()` and dies demanding an avatar, even
though `p-reels-faceless`'s own contract
(`~/ecosystem/harness/skills/p-reels-faceless/SKILL.md`) is `providers: elevenlabs`,
`inputs: [script]` — **"NO talking head, NO avatar"** by design. It does its own TTS
(ElevenLabs) and renders its own full visual track (HyperFrames motion graphics /
optional b-roll) entirely from the script; it has no use for `heygen/raw-avatar.mp4`
at all.

This is why 14 reels are mis-blocked: they're legitimate faceless briefs, correctly
named, that never had a chance — the crew never got far enough to read the recipe
before demanding credentials the recipe doesn't need.

## 2. What else shares this shape (and what doesn't)

I checked every recipe in `.brand/recipe-policy.yaml`'s `valid_non_default` +
`default`/`default_uploaded` against its `SKILL.md` to see whether the bug is
faceless-only or structural:

| Recipe | Needs a single pre-rendered `heygen/raw-avatar.mp4`? | Why |
|---|---|---|
| `p-reels-split-heygen` (brand **default**) | **Yes** | "generates the talking-head video... then delegates ALL compositing" — exactly video.sh's Phase 1/2 contract |
| `p-reels-pip-heygen` | **Yes** | same wrapper shape |
| `p-reels-spotlight-heygen` | **Yes** | same wrapper shape |
| `p-reels-split` (**default_uploaded**) | No | consumes an **uploaded** talking-head clip already on disk — no avatar to submit/download |
| `p-reels-pip` | No | same — uploaded clip |
| `p-reels-spotlight` | No | same — uploaded clip (its `providers: heygen` frontmatter is stale/aspirational; its own `when-to-use` says uploaded-or-HeyGen and it has no `-heygen` submit logic of its own — out of scope here, not part of this bug) |
| `p-reels-faceless` | No | TTS-only, no talking head at all — **this issue** |
| `p-reels-alternating` (BRD-34) | **No, but also not the Phase-1/2 contract** | needs HeyGen too, but for **three separate avatar segments**, submitted and assembled **inside its own compose step** via `c-heygen` (per its own `SKILL.md`) — not the single-avatar-in/raw-avatar.mp4-out shape video.sh implements. Forcing it through video.sh's `auto_submit()` would be wrong in the opposite direction (one submission instead of three). |

So the fix generalizes naturally to an **allowlist of the three recipes that actually
match video.sh's Phase 1/2 contract**, not a single `if RECIPE == p-reels-faceless`
patch — that would leave `p-reels-split`/`p-reels-pip`/`p-reels-spotlight` (uploaded
footage) exposed to the identical failure the moment someone briefs one through the
Dozer instead of by hand. `p-reels-alternating` deliberately stays off the allowlist
too, for the reason above — it must keep doing its own HeyGen calls inside compose;
putting it on the allowlist would be a second bug, not a fix.

## 3. The fix

All changes are in `dozers/mktg-lane/video.sh`. No change to `crew.sh` (the
production:-line routing signal is still correct — it's "is this a video brief",
and it stays that way) and no change to recipe-policy.yaml / the brand's `SKILL.md`s
(they're already correct; video.sh just wasn't reading them).

### 3.1 New: an explicit avatar-recipe allowlist

Right after `RECIPE` is resolved (after video.sh:169), add:

```bash
# Recipes whose compose step consumes a SINGLE pre-rendered heygen/raw-avatar.mp4 —
# the exact shape Phase 1 (SUBMIT) + Phase 2 (DOWNLOAD) below produce. Every other
# recipe either uses footage already on disk (uploaded talking-head recipes) or does
# its own provider calls inside compose (e.g. p-reels-alternating's 3-segment HeyGen
# calls via c-heygen) — forcing those through this single-avatar pipeline is wrong,
# not a fallback. New avatar-wrapper recipes must be added here explicitly; an
# unlisted recipe skips straight to compose and lets its own SKILL.md decide what it
# needs (fail fast there, in a recipe-specific error, rather than here in a generic
# HeyGen one).
HEYGEN_AVATAR_RECIPES="${DOZER_HEYGEN_AVATAR_RECIPES:-p-reels-split-heygen p-reels-pip-heygen p-reels-spotlight-heygen}"
NEEDS_AVATAR=0
for _r in $HEYGEN_AVATAR_RECIPES; do [[ "$RECIPE" == "$_r" ]] && { NEEDS_AVATAR=1; break; }; done
log "avatar pipeline: $([[ $NEEDS_AVATAR == 1 ]] && echo "yes (HeyGen single-avatar)" || echo "no (recipe composes its own)")"
```

`DOZER_HEYGEN_AVATAR_RECIPES` is an override knob (same pattern as every other env
knob in this file) so tests and a future new wrapper recipe don't need a code change
to exercise the branch.

### 3.2 Gate everything HeyGen-specific behind `NEEDS_AVATAR`

- **Vault load** (video.sh:171-174, `HEYGEN_API_KEY`): only required when
  `NEEDS_AVATAR=1`. A faceless/uploaded-footage brief must never fail because of an
  unrelated HeyGen vault problem.
- **Phase 1 SUBMIT + stale-render gate + Phase 2 DOWNLOAD** (video.sh:201-525,
  everything from `SUB=...` through the `log "assert: h264 ..."` / record-refresh at
  the end of Phase 2): wrapped in `if [[ $NEEDS_AVATAR == 1 ]]; then ... fi`. When
  `NEEDS_AVATAR=0` none of it runs — no vault read, no `hg_get`/`hg_mcp_call`, no
  `heygen/heygen-submission.json` ever written, no `heygen/raw-avatar.mp4` expected.
  `RAW`, `RAW_WH`, `RAW_DUR`, `AVATAR_ID`, `VOICE_ID`, `MOTION`, `CREDITS`,
  `RENDERED_ISO`, `VIDEO_ID` are left unset/empty on this path.
- **Phase 3 COMPOSE** (video.sh:527-579): stays a single shared step for both
  branches (this is the part that already generalizes — it just execs `$MODEL_CMD`
  or `$COMPOSE_CMD` against `$RECIPE_DIR/SKILL.md`), but:
  - `DRY_RUN=1`: the current branch passes the raw avatar through
    (`ffmpeg -i "$RAW" ...`) — there is no `$RAW` when `NEEDS_AVATAR=0`. Add a second
    dry-run stub: synthesize a placeholder directly
    (`ffmpeg -f lavfi -i color=... -f lavfi -i anullsrc=... -t $FINAL_MIN_S`) so the
    output contract (1080x1920 h264+aac ≥ `FINAL_MIN_S`) is still exercised without
    a real TTS/model call, exactly like the avatar DRY_RUN path does today.
  - `COMPOSE_CMD` override: unchanged mechanism, just don't export `RAW_AVATAR` (or
    export it empty) when `NEEDS_AVATAR=0` — nothing currently in this file requires
    callers to read it.
  - Real model-run prompt (video.sh:549-561): needs a no-avatar variant that drops
    the *"the talking-head render is DONE... avatar video: heygen/raw-avatar.mp4...
    DO NOT re-render it"* lines (there's nothing to not-re-render) and instead tells
    the model this is a from-scratch script → TTS → full visual render per the
    recipe's own `SKILL.md`, same required outputs
    (`final/short.mp4` 1080x1920 h264+aac ≥ `FINAL_MIN_S`, `final/cover.png`).
- **Phase 4 STAGE** (video.sh:650-702): the draft template's `render:` line
  (video.sh:660, `"$WANT_TITLE" · $VIDEO_ID · $RENDERED_ISO · $MOTION · $CREDITS
  credits · script sha256 ...`) is HeyGen-only. Branch it:
  - `NEEDS_AVATAR=1`: unchanged.
  - `NEEDS_AVATAR=0`: `render: no-avatar (recipe $RECIPE, composed via $COMPOSED_VIA)
    · script sha256 ${SCRIPT_SHA:0:12}…` — never print blank/misleading HeyGen
    fields for a render that never touched HeyGen.

### 3.3 Header comment (video.sh:1-55)

Update the file's own doc comment — it currently states unconditionally "the HeyGen
VIDEO branch of the marketing lane" and walks through Phase 1/2/3/4 as if every video
brief needs an avatar. Rewrite the intro to state the branch: avatar-wrapper recipes
(named explicitly) get Phase 1/2 first; every other recipe (uploaded footage,
faceless, or a recipe that does its own provider calls like `p-reels-alternating`)
skips straight to Phase 3, which is recipe-driven throughout.

## 4. Non-goals / things I'm deliberately not changing

- **No caching/staleness detection for no-avatar recipes.** The HeyGen stale-render
  gate exists to decide whether to re-spend HeyGen credits on a changed script — that
  concept doesn't apply here (no credits, no record to compare against). Every
  greenlight recomposes from the current script, same as a plain "copy" brief has
  always had no caching. If MGG later wants faceless renders to be idempotent across
  re-greenlights the way the avatar path is, that's a separate, additive issue — not
  a prerequisite for unblocking the 14 reels.
- **`p-reels-spotlight`'s stale `providers: heygen` frontmatter** and
  **`p-reels-alternating`'s own avatar needs** are both noted above as explicitly out
  of scope — neither is broken by this change, and neither should be "fixed" by
  adding them to the new allowlist (see §2's table).
- **No change to `crew.sh`'s routing** (`production:` line → video.sh). That signal
  is still correct; the bug was entirely inside video.sh assuming every video brief
  implies a HeyGen avatar.

## 5. Testing

`tests/mktg-lane-video-test.sh` already drives the real `crew.sh`/`video.sh` against
a stubbed HeyGen HTTP server + a throwaway brand/production fixture, and asserts on
exactly what hit the wire (`REQLOG`/`MCPLOG`), so the new case can prove the fix the
same way the existing `NOKEY` case proves the opposite:

**New case `FACELESS`:**
1. Fixture brand.yaml: **no `heygen:` block at all** (the exact condition that
   crashes today — `resolve_avatar_voice()` would come back empty).
2. Fixture `recipe-policy.yaml`: add `p-reels-faceless` under `valid_non_default`
   (mirrors MGG's real file).
3. Brief: `Recipe: p-reels-faceless` + a `**Recipe deviation:** faceless per fixture`
   line (recipe-policy's deviation rule still applies and must be satisfied, same as
   any other non-default recipe — this issue isn't about relaxing that gate).
4. Run via `COMPOSE_CMD="bash $STUB_COMPOSE"` (same stub-compose pattern as the
   existing HAPPY case) so the test doesn't need a real ElevenLabs/HyperFrames run —
   the stub just writes a conforming `final/short.mp4` + `final/cover.png`.
5. Assert:
   - the run **succeeds** (today: fails with the "cannot auto-submit... no
     heygen.avatarId/voiceId" message — this is the regression check),
   - `REQLOG` and `MCPLOG` are **both empty/absent** — zero HeyGen contact, not even
     an auth attempt,
   - `$PROD/heygen/` is never created (no `heygen-submission.json`, no
     `raw-avatar.mp4`),
   - `.dozers-review/$ID.md` is staged with the new no-avatar `render:` line and a
     valid posts/quick payload (same captions/platform assertions as HAPPY),
   - pointing `HEYGEN_VAULT`/`HEYGEN_MCP_VAULT` at nonexistent paths does **not**
     fail the run (proves the vault is genuinely never read on this path — same
     technique the `NOKEY` case uses to prove the opposite for the avatar path).
6. A `DRY_RUN=1` sub-case (no `COMPOSE_CMD`) to exercise the new no-avatar synthetic
   placeholder path and confirm the ffprobe asserts on `final/short.mp4` still pass
   without a real model call.

**Regression coverage (must keep passing unchanged):** `AUTOSUBMIT`, `STALE`,
`STALE-MT`, `MCP-*`, `HAPPY`, `RERUN`, `NOKEY`, `UNAUTH`, `NOV2` — all exercise
`p-reels-split-heygen` (the brand default, on the allowlist), so they should be
unaffected by the branch; running them is the check that the allowlist logic didn't
accidentally change behavior for the avatar path.

**Stretch (same mechanism, not required to close GSAI-262 but cheap once the branch
exists):** one more minimal case naming `p-reels-split` (uploaded-footage, also off
the allowlist) with no `heygen:` block, to prove the fix isn't accidentally
faceless-name-specific but genuinely gated on the allowlist.

## 6. Files touched

- `dozers/mktg-lane/video.sh` — the branch, the two gated phases, the dry-run stub,
  the prompt text, the stage template, the header comment.
- `tests/mktg-lane-video-test.sh` — new `FACELESS` case (+ optional stretch case).

No other file changes required — `crew.sh`, `org/config.yaml`, and the brand-side
`recipe-policy.yaml`/`SKILL.md` files are all already correct.
