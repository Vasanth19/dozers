VERDICT: PASS

## Why

**Spec match.** GSAI-262 is "a p-reels-faceless brief dies demanding a HeyGen avatar it
never uses." The build adds an explicit avatar-recipe allowlist
(`dozers/mktg-lane/video.sh:184-197`) and gates everything HeyGen-specific (vault read,
Phase 1 SUBMIT, the stale gate, Phase 2 DOWNLOAD) behind `NEEDS_AVATAR`, exactly as
`DOZER-DESIGN-GSAI-262.md` §3.1/3.2 specifies. A faceless (or uploaded-footage) recipe now
skips straight to compose with zero HeyGen contact.

**Followed the design, not just the task title.** The design's own root-cause analysis
(§2) correctly identified that this isn't a single-recipe patch — `p-reels-split`/`pip`/
`spotlight` (uploaded footage) share the same exposure, while `p-reels-alternating`
(3-segment HeyGen-in-compose) must stay *off* the allowlist. The build matches this:
the allowlist is exactly `p-reels-split-heygen p-reels-pip-heygen p-reels-spotlight-heygen`
(video.sh:194), and the new `UPLOADED` test case proves `p-reels-split` is also exempted.

**Code-level correctness, verified by reading the whole file (not just the diff):**
- `RAW`, `SUB`, and friends are pre-initialized to `""` (video.sh:201-202) so `set -u`
  doesn't blow up on the no-avatar path, and `SUB` is only ever pointed at a real path
  inside the `NEEDS_AVATAR` block (video.sh:260) — so `$PROD_DIR/heygen/` is genuinely
  never created on the no-avatar path.
- `probe()`, `HG_TMP` (+ its EXIT trap), and `BRAND_YAML` were correctly hoisted *above*
  the `NEEDS_AVATAR` gate (video.sh:204-226) because Phase 3/4 need them unconditionally
  — this wasn't spelled out verbatim in the design but is a necessary, correctly-applied
  consequence of it.
- Every `write_record` call outside the gated block is itself guarded with
  `[[ "$NEEDS_AVATAR" == "1" ]] &&` (video.sh:649, 760) — `write_record` is a function
  *defined inside* the gated block, so an unguarded call on the no-avatar path would be
  "command not found," not just a logic bug. This is handled correctly everywhere.
- Phase 4's `render:` line branches per design §3.2 (video.sh:721-725); the DRY_RUN
  synthetic-placeholder path (video.sh:591-598) exercises the same ffprobe contract
  (1080x1920, h264+aac, ≥18s) without a model call, as specified.
- No changes to `crew.sh`, `org/config.yaml`, or brand-side `recipe-policy.yaml`/
  `SKILL.md` — matches the design's explicit non-goals (§3, §4).

**Verified by running the actual test suite** (`tests/mktg-lane-video-test.sh`), not just
reading it — all 30 assertions pass:
- New/changed cases: `FACELESS` (zero HeyGen contact, no `heygen/` dir, composes and
  stages correctly), `FACELESS DRY_RUN` (synthetic placeholder passes ffprobe), and the
  stretch `UPLOADED` case (`p-reels-split` also off the allowlist) — all green.
- Full regression set for the avatar path — `AUTOSUBMIT`, `STALE`, `STALE (mtime)`,
  `MCP-NOKEY`, `MCP-REFRESH`, `MCP-CREDITS`, `HAPPY`, `RERUN`, `NOKEY`, `UNAUTH`, `NOV2` —
  unaffected, confirming the allowlist branch didn't change behavior for
  `p-reels-split-heygen`.

No correctness issues found. The one thing worth a future follow-up (not a blocker, and
explicitly called out as a non-goal in the design §4): no-avatar renders have no
staleness/idempotency tracking across re-greenlights, same as a plain copy brief always
had — consistent with the stated scope of this fix.
