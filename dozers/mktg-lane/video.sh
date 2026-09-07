#!/usr/bin/env bash
# dozers/mktg-lane/video.sh — the HeyGen VIDEO branch of the marketing lane (GSAI-7).
#
# crew.sh hands a brief here when its description carries a `production:` line that
# points at a `<brand>/creatives/productions/<MM.DD-slug>/` folder. Everything else
# stays on crew.sh's copy path, untouched.
#
# Pipeline — the automatable spine, with the rest gated (spec: GSAI-7, craft: brain
# `vasanth-hq/sops/content-production-pipeline.md`):
#
#   Phase 1  SUBMIT   — NOT automated. The API key funds ~1 render (`api: 2` credits);
#                       the usable credits live in the web account, so a human submits
#                       in Chrome. No matching COMPLETED render -> dozer:blocked with the
#                       exact title to submit + the recipe + "Motion Engine: Avatar III".
#                       This crew NEVER calls a HeyGen generate endpoint.
#   Gate     STALE    — the script is hashed and compared to the render's record (and
#                       the script mtime to renderedAt). A render older than its script
#                       is stale: block, re-submit instruction, no compose, no stage.
#   Phase 2  DOWNLOAD — /v1/video_status.get -> signed video_url -> heygen/raw-avatar.mp4,
#                       ffprobe-asserted (h264, 1080x1920, duration ±1s of the estimate).
#                       Record refreshed in heygen/heygen-submission.json.
#   Phase 3  COMPOSE  — the brand's CURRENT recipe (.brand/recipe-policy.yaml `default:`,
#                       or the brief's justified `Recipe:` line) -> final/short.mp4 +
#                       final/cover.png, ffprobe-asserted (1080x1920, h264+aac, >=18s).
#   Phase 4  STAGE    — .dozers-review/<id>.md with the mp4, the cover, the per-platform
#                       captions and the exact `POST /api/v1/posts/quick` payload it
#                       WOULD send. The publish endpoint is never called. Ever.
#
# HeyGen: only /v1/video.list, /v1/video_status.get and /v3/... are allowed — /v2/ sunsets
# 2026-10-31 and hg_get refuses it. The key is HEYGEN_API_KEY read from the vault
# (~/ecosystem/vault/secrets.env — NOT the dead ~/.gsai/secrets.env the old SOP named);
# missing or rejected -> fail fast naming the vault path. Never printed.
#
# Env (from crew.sh): ID/TITLE args, WORKDIR, REPO_ROOT, DOZER_BRIEF, MODEL_CMD, MODEL_DESC.
# Knobs (tests + deliberate runs):
#   HEYGEN_VAULT      path of the env file holding HEYGEN_API_KEY (default: the vault)
#   HEYGEN_API_BASE   API origin (default https://api.heygen.com; tests point it at a stub)
#   HEYGEN_LIST_LIMIT how many recent renders to scan for a title match (default 50)
#   COMPOSE_CMD       replaces the recipe compose step (gets PRODUCTION_DIR, RECIPE,
#                     RECIPE_DIR, RAW_AVATAR, OUT_MP4, OUT_COVER in the env)
#   DRY_RUN=1         compose = ffmpeg passthrough of the raw avatar (no model)
#   RECIPE_SKILLS_DIR where shared recipe skills live (default ~/ecosystem/harness/skills)
#   DOZER_VIDEO_EXPECT_WH          expected raw render geometry (default 1080x1920)
#   DOZER_VIDEO_DURATION_TOLERANCE seconds of drift allowed vs the estimate (default 1)
#   DOZER_FINAL_MIN_SECONDS        minimum final length (default 18)
set -euo pipefail
ID="$1"; TITLE="$2"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORKDIR="${WORKDIR:-.}"; WORKDIR="$(cd "$WORKDIR" && pwd)"
DOZER_BRIEF="${DOZER_BRIEF:-}"
OUT="$REPO_ROOT/.artifacts/mktg"; mkdir -p "$OUT"
MODEL_DESC="${MODEL_DESC:-${DOZER_MODEL_PROVIDER:-claude}/${DOZER_MODEL_NAME:-default}}"

HEYGEN_VAULT="${HEYGEN_VAULT:-$HOME/ecosystem/vault/secrets.env}"
HEYGEN_API_BASE="${HEYGEN_API_BASE:-https://api.heygen.com}"
HEYGEN_LIST_LIMIT="${HEYGEN_LIST_LIMIT:-50}"
RECIPE_SKILLS_DIR="${RECIPE_SKILLS_DIR:-$HOME/ecosystem/harness/skills}"
EXPECT_WH="${DOZER_VIDEO_EXPECT_WH:-1080x1920}"
DUR_TOL="${DOZER_VIDEO_DURATION_TOLERANCE:-1}"
FINAL_MIN_S="${DOZER_FINAL_MIN_SECONDS:-18}"
SOP_REF='brain: vasanth-hq/sops/content-production-pipeline.md (Phase 1 — HeyGen submit via Chrome)'

log()  { echo "    [mktg/video] $*"; }
# fail: the reason goes to stderr AND to $OUT/<id>.fail — the engine puts that file in
# the block comment (GSAI-26 #3). Same contract as crew.sh / the dev lane.
fail() { echo "    [mktg/video] ✗ $*" >&2; printf '%s\n' "$*" > "$OUT/$ID.fail" 2>/dev/null || true; exit 1; }
rm -f "$OUT/$ID.fail" 2>/dev/null || true

# ── Time bounds (GSAI-37): the compose step is either a model run (timeout_model /
# DOZER_TIMEOUT_MODEL) or a COMPOSE_CMD pipeline (timeout_compose / DOZER_TIMEOUT_COMPOSE).
# Either hanging fails THIS task with the timeout named; it never holds the slot.
# (The HeyGen calls already carry curl -m; the download is bounded at 900s.)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/timebox.sh"
TIMEBOX_CONFIG="$REPO_ROOT/org/config.yaml"
T_MODEL="$(timebox_secs model 3600)"     || fail "bad timeout_model / DOZER_TIMEOUT_MODEL"
T_COMPOSE="$(timebox_secs compose 1800)" || fail "bad timeout_compose / DOZER_TIMEOUT_COMPOSE"

for tool in curl ffprobe ffmpeg python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing tool '$tool' — the video lane needs curl, ffmpeg/ffprobe, python3, shasum"
done

# ── 0. Route: the production folder named in the brief ───────────────────────────
[[ -n "$DOZER_BRIEF" && -f "$DOZER_BRIEF" ]] || fail "no brief file (DOZER_BRIEF) — the engine must hand the issue description to the crew"
PROD_REF="$(python3 - "$DOZER_BRIEF" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'(?im)^\s*(?:[-*]\s+)?(?:\*\*|__)?\s*production\s*(?:\*\*|__)?\s*:\s*(?:\*\*|__)?\s*`?([^`\s*]+)', s)
print(m.group(1).rstrip('/') if m else "")
PY
)"
[[ -n "$PROD_REF" ]] || fail "brief has no production: line — not a video brief (crew.sh should not have routed here)"

PROD_DIR=""
_ref="${PROD_REF/#\~/$HOME}"
if [[ "$_ref" == /* ]]; then
  [[ -d "$_ref" ]] && PROD_DIR="$_ref"
else
  for cand in "$WORKDIR/$_ref" "$(dirname "$WORKDIR")/$_ref"; do
    [[ -d "$cand" ]] && { PROD_DIR="$cand"; break; }
  done
fi
[[ -n "$PROD_DIR" ]] || fail "production folder not found: '$PROD_REF' (looked under $WORKDIR and $(dirname "$WORKDIR")) — the brief's production: line must point at <brand>/creatives/productions/<MM.DD-slug>/"
PROD_DIR="$(cd "$PROD_DIR" && pwd)"
SLUG="$(basename "$PROD_DIR")"
# The brand folder is the ancestor above creatives/productions; else the workdir.
BRAND_DIR="$(cd "$PROD_DIR/../.." && pwd)"
[[ -d "$BRAND_DIR/creatives/productions" ]] || BRAND_DIR="$WORKDIR"
BRAND_ID="$(basename "$BRAND_DIR")"

SCRIPT_FILE=""
for cand in "$PROD_DIR/script/tts.md" "$PROD_DIR/script.md"; do
  [[ -f "$cand" ]] && { SCRIPT_FILE="$cand"; break; }
done
[[ -n "$SCRIPT_FILE" ]] || fail "no script in $PROD_DIR — expected script/tts.md or script.md"
SCRIPT_REL="${SCRIPT_FILE#$PROD_DIR/}"
SCRIPT_SHA="$(shasum -a 256 "$SCRIPT_FILE" | cut -d' ' -f1)"
SCRIPT_MTIME="$(stat -f %m "$SCRIPT_FILE" 2>/dev/null || stat -c %Y "$SCRIPT_FILE")"

log "production: $PROD_DIR"
log "brand: $BRAND_DIR  script: $SCRIPT_REL  sha256: ${SCRIPT_SHA:0:12}…"

# ── Recipe: the brand's CURRENT default, or the brief's justified deviation ────────
POLICY="$BRAND_DIR/.brand/recipe-policy.yaml"
RECIPE="$(python3 - "$POLICY" "$PROD_DIR/brief.md" <<'PY'
import re, sys, os
policy, brief = sys.argv[1], sys.argv[2]
default = None; dead = []; marker = r'(?i)recipe deviation:'
if os.path.exists(policy):
    cur = None
    for line in open(policy):
        line = line.split('#', 1)[0].rstrip()
        if not line.strip(): continue
        m = re.match(r'^(\w+):\s*(.*)$', line)
        if m:
            k, v = m.group(1), m.group(2).strip().strip('"\'')
            cur = k
            if k == 'default' and v: default = v
            if k == 'deviation_marker_regex' and v: marker = v
            continue
        m = re.match(r'^\s*-\s*(\S+)', line)
        if m and cur == 'dead_recipes': dead.append(m.group(1))
named = None; body = ""
if os.path.exists(brief):
    body = open(brief, encoding="utf-8", errors="replace").read()
    m = re.search(r'(?im)^\s*(?:\*\*)?recipe(?:\*\*)?\s*:\s*(?:\*\*)?\s*`?([A-Za-z0-9._-]+)', body)
    if m: named = m.group(1)
if named and named in dead:
    print(f"ERR brief names dead recipe '{named}' (retired in .brand/recipe-policy.yaml); default is '{default}'"); sys.exit(0)
if named and default and named != default and not re.search(marker, body):
    print(f"ERR brief names non-default recipe '{named}' without a 'Recipe deviation:' line; brand default is '{default}'"); sys.exit(0)
print(named or default or "")
PY
)"
[[ "$RECIPE" == ERR* ]] && fail "recipe gate: ${RECIPE#ERR }"
[[ -n "$RECIPE" ]] || fail "no recipe: $POLICY has no default: and $PROD_DIR/brief.md names none"
RECIPE_DIR=""
for cand in "$BRAND_DIR/.claude/skills/$RECIPE" "$RECIPE_SKILLS_DIR/$RECIPE"; do
  [[ -f "$cand/SKILL.md" ]] && { RECIPE_DIR="$cand"; break; }
done
log "recipe: $RECIPE ${RECIPE_DIR:+($RECIPE_DIR)}"

# ── HeyGen key: vault-first, fail fast, never printed ─────────────────────────────
[[ -f "$HEYGEN_VAULT" ]] || fail "HeyGen key file missing: $HEYGEN_VAULT — HEYGEN_API_KEY must live in the vault (~/ecosystem/vault/secrets.env); ~/.gsai/secrets.env is gone"
HEYGEN_API_KEY="$(grep -E '^(export[[:space:]]+)?HEYGEN_API_KEY=' "$HEYGEN_VAULT" | head -1 | sed 's/^export[[:space:]]*//; s/^HEYGEN_API_KEY=//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"
[[ -n "$HEYGEN_API_KEY" ]] || fail "HEYGEN_API_KEY is missing/empty in $HEYGEN_VAULT — add it there (vault-first), never elsewhere"

# hg_get <path?query> -> body on stdout. Refuses /v2/ (sunset 2026-10-31) and any
# generate/submit path (the crew never spends credits). Auth failures name the vault.
HG_TMP="$(mktemp -d)"; trap 'rm -rf "$HG_TMP"' EXIT
hg_get() {
  local path="$1" body="$HG_TMP/resp.json" http
  case "$path" in
    /v2/*) fail "refusing HeyGen $path — /v2/ endpoints sunset 2026-10-31; use /v1/video.list, /v1/video_status.get, /v3/…" ;;
    *generate*|*submit*|*create*) fail "refusing HeyGen $path — submission is a human step (Phase 1), the crew never spends credits" ;;
  esac
  http="$(curl -sS -m 60 -o "$body" -w '%{http_code}' -H "X-Api-Key: $HEYGEN_API_KEY" -H 'Accept: application/json' "$HEYGEN_API_BASE$path" 2>"$HG_TMP/curl.err")" \
    || fail "HeyGen $path unreachable: $(head -c 300 "$HG_TMP/curl.err")"
  case "$http" in
    401|403) fail "HeyGen rejected HEYGEN_API_KEY (HTTP $http) on $path — check the key in $HEYGEN_VAULT" ;;
    2??) ;;
    *) fail "HeyGen $path returned HTTP $http: $(head -c 300 "$body")" ;;
  esac
  python3 - "$body" <<'PY' || fail "HeyGen $path: error in response body — $(head -c 300 "$body") — if this is an auth error, check $HEYGEN_VAULT"
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("error") or (d.get("code") not in (None, 100)):
    sys.exit(1)
PY
  cat "$body"
}

# ── Phase 1 — SUBMIT is human. Find a COMPLETED render or block with the exact ask ─
SUB="$PROD_DIR/heygen/heygen-submission.json"; mkdir -p "$PROD_DIR/heygen"
sub_get() { # <key> -> value or empty (missing/invalid file => empty)
  [[ -f "$SUB" ]] || { printf ''; return 0; }
  python3 - "$SUB" "$1" <<'PY' 2>/dev/null || printf ''
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
v = d.get(sys.argv[2]); print("" if v is None else v)
PY
}
WANT_TITLE="$(sub_get title)"; WANT_TITLE="${WANT_TITLE:-$SLUG}"
SUB_VID="$(sub_get videoId)"

submit_instruction() {
  cat <<EOF
SUBMIT NEEDED (human, in Chrome — the API key cannot fund renders):
  1. app.heygen.com → New video (portrait 9:16, 1080p) → brand avatar + voice
  2. Motion Engine: Avatar III (2 credits — never Avatar V at 9)
  3. Script: paste the TTS block verbatim from $SCRIPT_REL (sha256 ${SCRIPT_SHA:0:12}…)
  4. Generate → title EXACTLY: $WANT_TITLE   (watermark off, MP4)
  5. Save $SUB with {"title":"$WANT_TITLE","status":"submitted","motionEngine":"Avatar III","creditsCost":2}
Recipe on compose: $RECIPE. Then re-greenlight this issue (dozer:ready + lane:marketing).
$SOP_REF
EOF
}

VIDEO_ID=""; RENDER_STATUS=""; RENDER_CREATED=""
if [[ -n "$SUB_VID" ]]; then
  # A recorded id: ask for that render directly.
  ST="$(hg_get "/v1/video_status.get?video_id=$SUB_VID")"
  read -r RENDER_STATUS RENDER_CREATED <<<"$(python3 -c '
import json,sys; d=json.load(sys.stdin)["data"]; print(d.get("status",""), d.get("created_at") or "")' <<<"$ST")"
  VIDEO_ID="$SUB_VID"
else
  hg_get "/v1/video.list?limit=$HEYGEN_LIST_LIMIT" > "$HG_TMP/list.json"
  read -r VIDEO_ID RENDER_STATUS RENDER_CREATED <<<"$(python3 - "$WANT_TITLE" "$HG_TMP/list.json" <<'PY'
import json, sys
want = sys.argv[1]
vids = [v for v in json.load(open(sys.argv[2]))["data"].get("videos", []) if (v.get("video_title") or "") == want]
vids.sort(key=lambda v: v.get("created_at") or 0, reverse=True)
done = [v for v in vids if v.get("status") == "completed"]
pick = done[0] if done else (vids[0] if vids else None)
print((pick or {}).get("video_id", ""), (pick or {}).get("status", ""), (pick or {}).get("created_at") or "")
PY
)"
fi

if [[ -z "$VIDEO_ID" ]]; then
  fail "$(printf 'no HeyGen render titled "%s" found in the last %s renders (and no videoId in %s).\n%s' "$WANT_TITLE" "$HEYGEN_LIST_LIMIT" "$SUB" "$(submit_instruction)")"
fi
case "$RENDER_STATUS" in
  completed) ;;
  processing|pending|waiting)
    fail "HeyGen render \"$WANT_TITLE\" ($VIDEO_ID) is still $RENDER_STATUS — nothing to download yet. Re-greenlight (dozer:ready + lane:marketing) once it completes." ;;
  *)
    fail "$(printf 'HeyGen render "%s" (%s) is %s, not completed — it must be re-rendered.\n%s' "$WANT_TITLE" "$VIDEO_ID" "${RENDER_STATUS:-unknown}" "$(submit_instruction)")" ;;
esac
log "render: \"$WANT_TITLE\" → $VIDEO_ID (completed)"

# ── Stale-render gate (hard). Script changed after the render => block, no compose ─
RENDERED_AT="$(sub_get renderedAt)"
RENDERED_EPOCH="$(python3 - "$RENDER_CREATED" "$RENDERED_AT" "$(sub_get submittedAt)" <<'PY'
import sys, datetime
for v in sys.argv[1:]:
    v = (v or "").strip()
    if not v: continue
    if v.replace('.', '', 1).isdigit():
        print(int(float(v))); break
    try:
        s = v.replace('Z', '+00:00')
        if len(s) == 16 + 6 and s[13] == ':' and s[16] == '+': s = s[:16] + ':00' + s[16:]   # "…T00:30+00:00"
        dt = datetime.datetime.fromisoformat(s)
        if dt.tzinfo is None: dt = dt.replace(tzinfo=datetime.timezone.utc)
        print(int(dt.timestamp())); break
    except Exception: continue
else:
    print("")
PY
)"
REC_SHA="$(sub_get scriptSha256)"
if [[ -n "$REC_SHA" ]]; then
  [[ "$REC_SHA" == "$SCRIPT_SHA" ]] || fail "$(printf 'STALE RENDER: %s changed after the render was made (recorded sha256 %s…, current %s…). Not composing, not staging — re-render from the corrected script.\n%s' "$SCRIPT_REL" "${REC_SHA:0:12}" "${SCRIPT_SHA:0:12}" "$(submit_instruction)")"
elif [[ -n "$RENDERED_EPOCH" ]]; then
  (( SCRIPT_MTIME <= RENDERED_EPOCH )) || fail "$(printf 'STALE RENDER: %s was modified (%s) after the render (%s) and the record carries no scriptSha256. Not composing, not staging — re-render from the corrected script.\n%s' "$SCRIPT_REL" "$(date -u -r "$SCRIPT_MTIME" +%FT%TZ 2>/dev/null || echo "$SCRIPT_MTIME")" "$(date -u -r "$RENDERED_EPOCH" +%FT%TZ 2>/dev/null || echo "$RENDERED_EPOCH")" "$(submit_instruction)")"
else
  fail "cannot tell whether the render is stale: $SUB has neither scriptSha256 nor renderedAt/submittedAt, and HeyGen returned no created_at for $VIDEO_ID"
fi
log "stale gate: script in sync with render"

# ── Phase 2 — DOWNLOAD + assert ───────────────────────────────────────────────────
ST="$(hg_get "/v1/video_status.get?video_id=$VIDEO_ID")"
read -r VIDEO_URL API_DURATION API_CREATED <<<"$(python3 -c '
import json,sys; d=json.load(sys.stdin)["data"]
print(d.get("video_url") or "-", d.get("duration") if d.get("duration") is not None else "-", d.get("created_at") or "-")' <<<"$ST")"
[[ "$VIDEO_URL" != "-" ]] || fail "HeyGen returned no video_url for completed render $VIDEO_ID"
[[ "$API_CREATED" != "-" ]] && RENDERED_EPOCH="$API_CREATED"
RENDERED_ISO="$(date -u -r "$RENDERED_EPOCH" +%FT%TZ 2>/dev/null || printf '%s' "$RENDERED_AT")"

RAW="$PROD_DIR/heygen/raw-avatar.mp4"
if [[ -s "$RAW" && "$(sub_get videoId)" == "$VIDEO_ID" && "$(sub_get status)" =~ ^(downloaded|composed|staged)$ ]]; then
  log "download: heygen/raw-avatar.mp4 already on disk for $VIDEO_ID — reusing"
else
  curl -sSL -m 900 -o "$RAW.part" "$VIDEO_URL" 2>"$HG_TMP/dl.err" || fail "download of render $VIDEO_ID failed: $(head -c 300 "$HG_TMP/dl.err")"
  mv -f "$RAW.part" "$RAW"
  log "download: → heygen/raw-avatar.mp4 ($(du -h "$RAW" | cut -f1))"
fi

# probe <file> -> "vcodec WxH duration acodec" (acodec '-' when no audio stream)
probe() {
  python3 - "$1" <<'PY'
import json, subprocess, sys
out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-show_format", sys.argv[1]],
                     capture_output=True, text=True)
if out.returncode != 0: print("ERR - - -"); sys.exit(0)
d = json.loads(out.stdout)
v = next((s for s in d.get("streams", []) if s.get("codec_type") == "video"), None)
a = next((s for s in d.get("streams", []) if s.get("codec_type") == "audio"), None)
dur = d.get("format", {}).get("duration") or (v or {}).get("duration") or "0"
print((v or {}).get("codec_name", "-"), f"{(v or {}).get('width','?')}x{(v or {}).get('height','?')}", f"{float(dur):.2f}", (a or {}).get("codec_name", "-"))
PY
}
read -r RAW_VCODEC RAW_WH RAW_DUR RAW_ACODEC <<<"$(probe "$RAW")"
[[ "$RAW_VCODEC" != "ERR" ]] || fail "ffprobe cannot read the downloaded render $RAW"
[[ "$RAW_VCODEC" == "h264" ]] || fail "render $VIDEO_ID is $RAW_VCODEC, expected h264 — the submission was misconfigured"
[[ "$RAW_WH" == "$EXPECT_WH" ]] || fail "render $VIDEO_ID is $RAW_WH, expected $EXPECT_WH (portrait 1080p) — the submission was misconfigured"
EXPECT_DUR="$(sub_get durationEstimate)"; [[ -z "$EXPECT_DUR" ]] && EXPECT_DUR="$(sub_get estimatedDuration)"
[[ -z "$EXPECT_DUR" && "$API_DURATION" != "-" ]] && EXPECT_DUR="$API_DURATION"
[[ -n "$EXPECT_DUR" ]] || fail "no duration to check against: $SUB has no durationEstimate and HeyGen reported none for $VIDEO_ID"
python3 -c 'import sys; a,e,t=map(float,sys.argv[1:4]); sys.exit(0 if abs(a-e)<=t else 1)' "$RAW_DUR" "$EXPECT_DUR" "$DUR_TOL" \
  || fail "render $VIDEO_ID runs ${RAW_DUR}s but the estimate was ${EXPECT_DUR}s (tolerance ±${DUR_TOL}s) — the submission does not match the script"
log "assert: h264 $RAW_WH ${RAW_DUR}s (estimate ${EXPECT_DUR}s) ✓"

# Refresh the record (audit trail for cost + reproducibility). Merges into what exists.
write_record() { # key=value pairs (JSON-typed where it matters)
  python3 - "$SUB" "$@" <<'PY'
import json, os, sys
p = sys.argv[1]
d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except Exception: d = {}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    if v.startswith("json:"):
        v = json.loads(v[5:])
    d[k] = v
tmp = p + ".tmp"
json.dump(d, open(tmp, "w"), indent=2); open(tmp, "a").write("\n")
os.replace(tmp, p)
PY
}
BRAND_YAML="$BRAND_DIR/.config/brand.yaml"
AVATAR_ID="$(sub_get avatarId)"; VOICE_ID="$(sub_get voiceId)"
if [[ -f "$BRAND_YAML" ]]; then
  [[ -z "$AVATAR_ID" ]] && AVATAR_ID="$(grep -oE 'avatarId:[[:space:]]*"?[0-9a-f]{32}' "$BRAND_YAML" | head -1 | grep -oE '[0-9a-f]{32}' || true)"
  [[ -z "$VOICE_ID" ]]  && VOICE_ID="$(grep -oE 'voiceId:[[:space:]]*"?[0-9a-f]{32}' "$BRAND_YAML" | head -1 | grep -oE '[0-9a-f]{32}' || true)"
fi
MOTION="$(sub_get motionEngine)"; MOTION="${MOTION:-Avatar III}"
CREDITS="$(sub_get creditsCost)"; CREDITS="${CREDITS:-2}"
write_record "issue=$ID" "production=$SLUG" "videoId=$VIDEO_ID" "title=$WANT_TITLE" \
  "renderedAt=$RENDERED_ISO" "avatarId=$AVATAR_ID" "voiceId=$VOICE_ID" "motionEngine=$MOTION" \
  "creditsCost=json:$CREDITS" "status=downloaded" "mp4Path=heygen/raw-avatar.mp4" \
  "scriptSource=$SCRIPT_REL" "scriptSha256=$SCRIPT_SHA" "durationSeconds=json:$RAW_DUR" \
  "downloadedAt=$(date -u +%FT%TZ)" "downloadedBy=dozer mktg-lane/video.sh"
log "record: $SUB refreshed (status=downloaded)"

# ── Phase 3 — COMPOSE with the brand's recipe ─────────────────────────────────────
FINAL_DIR="$PROD_DIR/final"; mkdir -p "$FINAL_DIR"
SHORT="$FINAL_DIR/short.mp4"; COVER="$FINAL_DIR/cover.png"
export PRODUCTION_DIR="$PROD_DIR" RECIPE RECIPE_DIR RAW_AVATAR="$RAW" OUT_MP4="$SHORT" OUT_COVER="$COVER" BRAND_DIR SCRIPT_FILE
if [[ -n "${COMPOSE_CMD:-}" ]]; then
  if ! timebox "$T_COMPOSE" "compose (COMPOSE_CMD)" "$PROD_DIR" "$COMPOSE_CMD"; then
    (( TIMEBOX_HIT )) && fail "compose (COMPOSE_CMD) timed out after ${T_COMPOSE}s (DOZER_TIMEOUT_COMPOSE / timeout_compose in org/config.yaml) — killed its process group; recipe $RECIPE"
    fail "compose (COMPOSE_CMD) failed for recipe $RECIPE"
  fi
  COMPOSED_VIA="COMPOSE_CMD"
elif [[ "${DRY_RUN:-}" == "1" ]]; then
  # No model: pass the avatar through so the output contract is still exercised.
  if [[ "$RAW_ACODEC" == "-" ]]; then
    ffmpeg -y -v error -i "$RAW" -f lavfi -i anullsrc=r=48000:cl=stereo -map 0:v -map 1:a -c:v copy -c:a aac -shortest "$SHORT" || fail "dry-run compose failed"
  else
    ffmpeg -y -v error -i "$RAW" -c:v copy -c:a aac "$SHORT" || fail "dry-run compose failed"
  fi
  ffmpeg -y -v error -ss 1 -i "$SHORT" -frames:v 1 "$COVER" || fail "dry-run cover extraction failed"
  COMPOSED_VIA="dry-run passthrough"
else
  [[ -n "$RECIPE_DIR" ]] || fail "recipe '$RECIPE' has no SKILL.md under $BRAND_DIR/.claude/skills or $RECIPE_SKILLS_DIR — cannot compose"
  [[ -n "${MODEL_CMD:-}" ]] || fail "no MODEL_CMD for the compose step (model routing did not run)"
  read -r -d '' PROMPT <<EOF || true
You are the Mktg-Dozer COMPOSE step for a short-form video. Work only inside this production folder: $PROD_DIR
Recipe to follow exactly: $RECIPE — read $RECIPE_DIR/SKILL.md first and follow its compositing steps.
Brand folder (voice, palette, templates, config): $BRAND_DIR
Inputs already on disk — the talking-head render is DONE:
  - avatar video: heygen/raw-avatar.mp4 ($RAW_WH h264, ${RAW_DUR}s). DO NOT re-render it. Do NOT call HeyGen, ElevenLabs or any paid provider; spend zero credits.
  - script: $SCRIPT_REL (use it as the known transcript)
  - brief: brief.md (if present)
Required outputs (nothing else is checked):
  - final/short.mp4 — 1080x1920, h264 video + aac audio, at least ${FINAL_MIN_S}s
  - final/cover.png — the cover frame
Do NOT publish, schedule, or upload anything anywhere. Do not touch files outside this production folder except the recipe's own scratch dirs. When both outputs exist, stop.
EOF
  if ! timebox "$T_MODEL" "compose model run" "$PROD_DIR" "$MODEL_CMD \"\$PROMPT\""; then
    (( TIMEBOX_HIT )) && fail "compose model run timed out after ${T_MODEL}s (DOZER_TIMEOUT_MODEL / timeout_model in org/config.yaml) — killed its process group; recipe $RECIPE"
    fail "compose model run failed for recipe $RECIPE"
  fi
  COMPOSED_VIA="$MODEL_DESC via $RECIPE"
fi
[[ -s "$SHORT" ]] || fail "compose produced no final/short.mp4 (recipe $RECIPE, via $COMPOSED_VIA)"
[[ -s "$COVER" ]] || fail "compose produced no final/cover.png (recipe $RECIPE, via $COMPOSED_VIA)"
read -r F_VCODEC F_WH F_DUR F_ACODEC <<<"$(probe "$SHORT")"
[[ "$F_VCODEC" == "h264" ]] || fail "final/short.mp4 video codec is $F_VCODEC, expected h264"
[[ "$F_ACODEC" == "aac" ]] || fail "final/short.mp4 audio codec is ${F_ACODEC/-/none}, expected aac"
[[ "$F_WH" == "1080x1920" ]] || fail "final/short.mp4 is $F_WH, expected 1080x1920"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$F_DUR" "$FINAL_MIN_S" \
  || fail "final/short.mp4 runs ${F_DUR}s, below the ${FINAL_MIN_S}s minimum"
read -r C_CODEC _ _ _ <<<"$(probe "$COVER")"
[[ "$C_CODEC" == "png" ]] || fail "final/cover.png is not a PNG (ffprobe says: $C_CODEC)"
write_record "status=composed" "recipe=$RECIPE" "finalPath=final/short.mp4" "coverPath=final/cover.png" "composedAt=$(date -u +%FT%TZ)"
log "compose: final/short.mp4 $F_WH ${F_DUR}s h264+aac, final/cover.png ✓ ($COMPOSED_VIA)"

# ── Phase 4 — STAGE. Never publish. ───────────────────────────────────────────────
CAPTIONS_JSON="$HG_TMP/captions.json"
CAPTION_SRC="$(python3 - "$PROD_DIR" "$CAPTIONS_JSON" <<'PY'
import json, os, re, sys
prod, out = sys.argv[1], sys.argv[2]
cands = ["publish/captions.json", "publish/captions.md", "captions.md", "publish/caption.txt",
         "caption.txt", "caption.md", "_cmo/captions-ready.md"]
for rel in cands:
    p = os.path.join(prod, rel)
    if not os.path.isfile(p): continue
    text = open(p, encoding="utf-8", errors="replace").read()
    if rel.endswith(".json"):
        caps = json.loads(text)
        if not isinstance(caps, dict) or not caps: continue
    else:
        text = text.strip()
        if not text: continue
        caps = {"*": text}
    bad = [k for k, v in caps.items() if re.search(r"\{\{[^}]*\}\}", v or "")]
    if bad:
        print("ERR caption still has {{placeholders}} in " + rel + " (" + ", ".join(bad) + ")"); sys.exit(0)
    json.dump(caps, open(out, "w")); print(rel); sys.exit(0)
print("")
PY
)"
[[ "$CAPTION_SRC" == ERR* ]] && fail "${CAPTION_SRC#ERR }"
[[ -n "$CAPTION_SRC" ]] || fail "no caption to stage: add publish/captions.json ({platform: caption}) or publish/caption.txt to $PROD_DIR"

CFW_YAML="$BRAND_DIR/.config/cfw-social.yaml"
PAYLOAD="$HG_TMP/payload.json"
PLATFORM_NOTE="$(python3 - "$BRAND_YAML" "$CFW_YAML" "$BRAND_ID" "$CAPTIONS_JSON" "$SHORT" "$PAYLOAD" <<'PY'
import json, os, re, sys
brand_yaml, cfw_yaml, brand_id, caps_p, short, out = sys.argv[1:7]
enabled = []
if os.path.exists(brand_yaml):
    m = re.search(r'(?m)^\s*enabled:\s*\[([^\]]*)\]', open(brand_yaml).read())
    if m: enabled = [x.strip().strip('"\'') for x in m.group(1).split(",") if x.strip()]
if not enabled:
    print("ERR no platforms.enabled: [...] in " + brand_yaml); sys.exit(0)
# Exclusions: bluesky never carries video; per-brand list from cfw-social.yaml
# `videoExcludePlatforms:`; MGG has no LinkedIn connection (SOP Phase 4 §3).
excl = {"bluesky"}
why = {"bluesky": "no video on bluesky"}
src = None
if os.path.exists(cfw_yaml):
    m = re.search(r'(?m)^\s*videoExcludePlatforms:\s*\[?([^\]\n]*)\]?', open(cfw_yaml).read())
    if m:
        src = "cfw-social.yaml videoExcludePlatforms"
        for x in re.split(r'[,\s]+', m.group(1)):
            x = x.strip().strip('"\'')
            if x: excl.add(x); why[x] = src
if src is None and brand_id in ("mr-growth-guide", "mgg"):
    excl.add("linkedin"); why["linkedin"] = "not connected for MGG"
caps = json.load(open(caps_p))
platforms = [p for p in enabled if p not in excl]
if not platforms:
    print("ERR every enabled platform is excluded for video"); sys.exit(0)
by = {p: caps.get(p, caps.get("*", "")) for p in platforms}
missing = [p for p, c in by.items() if not c]
if missing:
    print("ERR no caption for platform(s): " + ", ".join(missing)); sys.exit(0)
payload = {"platforms": platforms, "captionsByPlatform": by,
           "mediaUrls": ["file://" + short], "kind": "video", "saveAsDraft": False}
json.dump(payload, open(out, "w"), indent=2, ensure_ascii=False)
print("platforms: " + ", ".join(platforms) + " · excluded: " + ", ".join(f"{p} ({why[p]})" for p in sorted(excl) if p in enabled))
PY
)"
[[ "$PLATFORM_NOTE" == ERR* ]] && fail "${PLATFORM_NOTE#ERR }"

REVIEW_DIR="$WORKDIR/.dozers-review"; mkdir -p "$REVIEW_DIR"
DRAFT="$REVIEW_DIR/$ID.md"
{
  cat <<EOF
# VIDEO — needs approval — #$ID
brief: $TITLE
production: $PROD_DIR
recipe: $RECIPE
final: $SHORT  ($F_WH, ${F_DUR}s, h264+aac)
cover: $COVER
render: "$WANT_TITLE" · $VIDEO_ID · $RENDERED_ISO · $MOTION · $CREDITS credits · script sha256 ${SCRIPT_SHA:0:12}…
captions: $CAPTION_SRC
$PLATFORM_NOTE
status: NEEDS REVIEW — NOT published; nothing publishes until a human approves
---

## Captions by platform
EOF
  python3 -c '
import json,sys; p=json.load(open(sys.argv[1]))
for k,v in p["captionsByPlatform"].items(): print(f"\n### {k}\n{v}")' "$PAYLOAD"
  cat <<EOF

## CFW Social publish payload — NOT sent
\`POST /api/v1/posts/quick\` on \`$(grep -E '^baseUrl:' "$CFW_YAML" 2>/dev/null | sed 's/^baseUrl:[[:space:]]*//; s/#.*//; s/[[:space:]]*$//' || echo 'https://app.cfw.social')\`, header \`x-api-key\` from the brand key named in \`.config/cfw-social.yaml\`.
Before sending, upload \`final/short.mp4\` as brand media and replace the \`file://\` placeholder in \`mediaUrls\` with the public URL.
The Dozer never calls this endpoint — a human approves, then publishes.

\`\`\`json
$(cat "$PAYLOAD")
\`\`\`
EOF
} > "$DRAFT"
write_record "status=staged" "stagedAt=$(date -u +%FT%TZ)" "reviewDraft=$DRAFT"
log "staged for approval: $DRAFT  (NOT published)"

cat > "$OUT/$ID.md" <<EOF
# VIDEO staged for #$ID  (awaiting approval)
brief: $TITLE
production: $PROD_DIR
final: $SHORT
draft: $DRAFT
status: NEEDS REVIEW — nothing publishes until a human approves
EOF
cat > "$OUT/$ID.summary" <<EOF
- Picked up: $TITLE
- Video brief → $SLUG (recipe $RECIPE)
- Render "$WANT_TITLE" ($VIDEO_ID) downloaded, ffprobe ✓, script in sync
- Composed final/short.mp4 ($F_WH, ${F_DUR}s) + cover.png via $COMPOSED_VIA
- Staged → $DRAFT with the posts/quick payload (NOT published)
- Awaiting human approval
EOF
log "done #$ID (staged)"
