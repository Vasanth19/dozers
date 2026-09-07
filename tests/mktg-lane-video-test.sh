#!/usr/bin/env bash
# tests/mktg-lane-video-test.sh — regression test for GSAI-7 (the HeyGen video branch
# of the marketing lane).
#
# The marketing crew used to be a copy-only stub; a video brief now routes to
# dozers/mktg-lane/video.sh. Every case drives the REAL crew against a throwaway brand
# folder and a STUBBED HeyGen (a local HTTP server) — no live API, no credits spent.
# The stub logs every request path so the "no /v2/ calls" rule is asserted on what
# actually went over the wire, not on a grep.
#
# Cases:
#   COPY      a brief without a production: line takes the copy path exactly as before
#             (stub model runs, draft staged, HeyGen never contacted)
#   NOSUBMIT  a video brief with no submitted render blocks with the exact submit
#             instruction — the title, and "Motion Engine: Avatar III (2 credits — never
#             Avatar V at 9)" — and never composes or stages
#   STALE     the script changed after the render (sha mismatch) -> blocked as STALE
#             RENDER, no download, no compose, no stage
#   STALE-MT  no sha on record, script mtime newer than the render -> same block
#   HAPPY     completed, in-sync render -> raw downloaded + ffprobe-asserted, final/short.mp4
#             + cover.png, .dozers-review/<id>.md with a valid posts/quick payload (no
#             bluesky, no linkedin for MGG), record refreshed, only /v1/ endpoints hit
#   RERUN     the same brief again reuses the downloaded raw (idempotent)
#   NOKEY     vault file missing -> fails fast naming the vault path; HeyGen never contacted;
#             NO silent fallback to the copy path (no copy draft, model not run)
#   UNAUTH    vault holds a rejected key -> fails naming the vault path
#   NOV2      video.sh contains no /v2/ request path, and hg_get refuses one
#
# Needs ffmpeg/ffprobe + python3 (the pipeline's own hard deps).
# Run:  bash tests/mktg-lane-video-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/mktg-lane/crew.sh"
VIDEO="$ROOT/dozers/mktg-lane/video.sh"

for t in ffmpeg ffprobe python3 curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "mktg-lane-video-test: missing $t" >&2; exit 1; }
done

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() { [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }

REPO="$TMP/repo"; mkdir -p "$REPO/org"; cp "$ROOT/org/config.yaml" "$REPO/org/config.yaml"
ART="$REPO/.artifacts/mktg"

# ── fixture brand: mr-growth-guide (so the MGG linkedin exclusion is exercised) ──
BRAND="$TMP/brands/mr-growth-guide"
SLUG="09.06-test-reel"
PROD="$BRAND/creatives/productions/$SLUG"
mkdir -p "$BRAND/.config" "$BRAND/.brand" "$PROD/publish"
cat > "$BRAND/.config/brand.yaml" <<'EOF'
brandInfo:
  id: "B-GROWTHGUIDE"
platforms:
  enabled: [youtube, instagram, facebook, linkedin, tiktok, twitter, threads, bluesky]
heygen:
  avatarId: "9273e994f1ed484d9031afa3725676c5"
  voiceId: "6a9a4d08391e4321a48d019e192fa6fe"
EOF
cat > "$BRAND/.config/cfw-social.yaml" <<'EOF'
provider: cfw-social
baseUrl: https://app.cfw.social
EOF
cat > "$BRAND/.brand/recipe-policy.yaml" <<'EOF'
default: p-reels-split-heygen
effective_date: "2026-06-30"
dead_recipes:
  - r-alternating-visual
EOF
cat > "$PROD/brief.md" <<'EOF'
# Test reel brief
Recipe: p-reels-split-heygen
EOF
printf '# TTS Script\n\nThis is the test script for the reel.\n' > "$PROD/script.md"
printf 'Know AI #1 — test caption.\nFollow @mr.growthguide\n' > "$PROD/publish/caption.txt"
touch -t 202601010000 "$PROD/script.md"       # script authored long before any render
SCRIPT_SHA="$(shasum -a 256 "$PROD/script.md" | cut -d' ' -f1)"

# ── fixture render: 20s 1080x1920 h264 + aac, generated once ─────────────────
RAW_FIXTURE="$TMP/fixture-raw.mp4"
ffmpeg -y -v error -f lavfi -i "color=c=0x0F172A:s=1080x1920:r=10:d=20" -f lavfi -i "anullsrc=r=48000:cl=stereo" \
  -map 0:v -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -t 20 "$RAW_FIXTURE" \
  || { echo "could not build the fixture mp4" >&2; exit 1; }

# ── stubbed HeyGen: scenario file re-read on every request, request log ───────
SCN="$TMP/scenario.json"; REQLOG="$TMP/requests.log"; PORTFILE="$TMP/port"
GOOD_KEY="test-heygen-key-0000"
cat > "$TMP/heygen-stub.py" <<'PY'
import json, sys, http.server, socketserver
SCN, PORTFILE, LOG = sys.argv[1:4]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, code, body):
        out = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def do_GET(self):
        scn = json.load(open(SCN)); open(LOG, "a").write(self.path + "\n")
        p = self.path
        if p.startswith("/files/raw.mp4"):          # the signed URL: no key, like the real CDN
            data = open(scn["raw"], "rb").read()
            self.send_response(200); self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        if self.headers.get("X-Api-Key") != scn["key"]:
            return self._json(401, {"code": 40001, "message": "Unauthorized"})
        if p.startswith("/v1/video.list"):
            return self._json(200, {"code": 100, "data": {"videos": scn["videos"]}})
        if p.startswith("/v1/video_status.get"):
            vid = p.split("video_id=", 1)[1].split("&")[0]
            v = next((x for x in scn["videos"] if x["video_id"] == vid), None)
            if not v: return self._json(200, {"code": 40000, "message": "video not found"})
            return self._json(200, {"code": 100, "data": {"id": vid, "status": v["status"], "created_at": v["created_at"],
                "duration": scn["duration"], "error": None,
                "video_url": f"http://127.0.0.1:{self.server.server_address[1]}/files/raw.mp4"}})
        return self._json(404, {"code": 40404, "message": "no such route"})
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
scenario() {  # $1 = videos JSON array
  python3 - "$SCN" "$GOOD_KEY" "$RAW_FIXTURE" "$1" <<'PY'
import json, sys
json.dump({"key": sys.argv[2], "raw": sys.argv[3], "duration": 20.0, "videos": json.loads(sys.argv[4])}, open(sys.argv[1], "w"))
PY
}
scenario '[]'
python3 "$TMP/heygen-stub.py" "$SCN" "$PORTFILE" "$REQLOG" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$PORTFILE" ]] && break; sleep 0.1; done
[[ -s "$PORTFILE" ]] || { echo "stub HeyGen did not start" >&2; exit 1; }
API="http://127.0.0.1:$(cat "$PORTFILE")"
RENDER_TS=1780000000   # 2026-05-28 — after the script's 2026-01-01 mtime

# ── stubs: model (copy path), compose (video path), vault ─────────────────────
VAULT="$TMP/secrets.env"; printf 'HEYGEN_API_KEY=%s\n' "$GOOD_KEY" > "$VAULT"; chmod 600 "$VAULT"
BAD_VAULT="$TMP/bad-secrets.env"; printf 'HEYGEN_API_KEY=wrong-key\n' > "$BAD_VAULT"
STUB_MODEL="$TMP/stub-model.sh"
cat > "$STUB_MODEL" <<'EOS'
#!/usr/bin/env bash
: > "$MODEL_RAN"; echo "COPY DRAFT from stub model"
EOS
STUB_COMPOSE="$TMP/stub-compose.sh"
cat > "$STUB_COMPOSE" <<'EOS'
#!/usr/bin/env bash
set -e; : > "$COMPOSE_RAN"
mkdir -p "$(dirname "$OUT_MP4")"
cp "$RAW_AVATAR" "$OUT_MP4"
ffmpeg -y -v error -ss 1 -i "$OUT_MP4" -frames:v 1 "$OUT_COVER"
EOS
chmod +x "$STUB_MODEL" "$STUB_COMPOSE"

brief() {  # $1 = id, $2 = body -> path
  printf '%s\n' "$2" > "$TMP/$1.brief"; printf '%s' "$TMP/$1.brief"
}
VIDEO_BRIEF="**Owner:** Honey
production: creatives/productions/$SLUG/
Angle: test."
COPY_BRIEF="A plain copy brief with no production line."

# Extra env goes as trailing KEY=VAL args (a prefix assignment on a function call
# would leak into the shell — see dev-lane-test-gate-preflight-test.sh).
run_crew() {  # $1 = id, $2 = brief file, $3 = log, $4.. = extra KEY=VAL
  local id="$1" bf="$2" log="$3"; shift 3
  rm -f "$ART/$id".* 2>/dev/null || true
  env MODEL_RAN="$TMP/$id.model-ran" COMPOSE_RAN="$TMP/$id.compose-ran" \
      REPO_ROOT="$REPO" WORKDIR="$BRAND" DOZER_BRIEF="$bf" DOZER_PERSONA="test" \
      MODEL_CMD="bash $STUB_MODEL" COMPOSE_CMD="bash $STUB_COMPOSE" \
      HEYGEN_VAULT="$VAULT" HEYGEN_API_BASE="$API" "$@" \
      bash "$CREW" "$id" "GSAI-7 test brief" >"$log" 2>&1
}
model_ran()   { [[ -e "$TMP/$1.model-ran" ]]; }
compose_ran() { [[ -e "$TMP/$1.compose-ran" ]]; }
reset_prod()  { rm -rf "$PROD/heygen" "$PROD/final" "$BRAND/.dozers-review" 2>/dev/null || true; : > "$REQLOG"; }
sub_status()  { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$PROD/heygen/heygen-submission.json" "$1" 2>/dev/null || true; }

echo "== mktg lane: video branch (GSAI-7) =="

# ── COPY: no production: line -> the old path, untouched ─────────────────────
reset_prod; ID=VT-COPY; LOG="$TMP/$ID.log"
if run_crew "$ID" "$(brief "$ID" "$COPY_BRIEF")" "$LOG"; then
  if model_ran "$ID" && has "$BRAND/.dozers-review/$ID.md" "COPY DRAFT" && [[ ! -s "$REQLOG" ]] && [[ -s "$ART/$ID.summary" ]]; then
    ok "COPY brief takes the copy path: model ran, draft staged, HeyGen never contacted"
  else no "COPY brief should stage a copy draft without touching HeyGen"; dump "$LOG"; fi
else no "COPY brief should succeed (exit $?)"; dump "$LOG"; fi

# ── NOSUBMIT: no submission record, no matching render -> block with the ask ─
reset_prod; ID=VT-NOSUB; LOG="$TMP/$ID.log"; scenario '[{"video_id":"other","status":"completed","video_title":"unrelated","created_at":1780000000}]'
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG"; then no "NOSUBMIT should block"; dump "$LOG"
else
  F="$ART/$ID.fail"
  if has "$F" "Motion Engine: Avatar III (2 credits — never Avatar V at 9)" && has "$F" "title EXACTLY: $SLUG" \
     && has "$F" "p-reels-split-heygen" && has "$F" "SUBMIT NEEDED"; then
    ok "NOSUBMIT blocks with the exact submit instruction (title, recipe, Avatar III)"
  else no "NOSUBMIT block reason lacks the submit instruction"; dump "$F"; fi
  if ! compose_ran "$ID" && [[ ! -e "$PROD/final/short.mp4" && ! -e "$BRAND/.dozers-review/$ID.md" ]] && ! model_ran "$ID"; then
    ok "NOSUBMIT: no compose, no stage, no copy-draft fallback"
  else no "NOSUBMIT must not compose, stage, or fall back to copy"; dump "$LOG"; fi
  has "$REQLOG" "/v1/video.list" && ok "NOSUBMIT looked at /v1/video.list" || no "NOSUBMIT should have listed renders"
fi

# ── STALE: recorded sha differs from the current script -> hard block ────────
reset_prod; ID=VT-STALE; LOG="$TMP/$ID.log"
scenario "[{\"video_id\":\"vid-stale\",\"status\":\"completed\",\"video_title\":\"$SLUG\",\"created_at\":$RENDER_TS}]"
mkdir -p "$PROD/heygen"
printf '{"title":"%s","videoId":"vid-stale","status":"submitted","scriptSha256":"%s"}\n' "$SLUG" "0000000000000000000000000000000000000000000000000000000000000000" > "$PROD/heygen/heygen-submission.json"
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG"; then no "STALE should block"; dump "$LOG"
else
  F="$ART/$ID.fail"
  if has "$F" "STALE RENDER" && has "$F" "Motion Engine: Avatar III"; then ok "STALE (sha) blocks as STALE RENDER with the re-submit instruction"
  else no "STALE block reason wrong"; dump "$F"; fi
  if ! compose_ran "$ID" && [[ ! -e "$PROD/heygen/raw-avatar.mp4" && ! -e "$PROD/final/short.mp4" && ! -e "$BRAND/.dozers-review/$ID.md" ]] && ! has "$REQLOG" "/files/raw.mp4"; then
    ok "STALE: no download, no compose, no stage"
  else no "STALE must not download/compose/stage"; dump "$LOG"; fi
fi

# ── STALE-MT: no sha on record, script touched after the render ──────────────
reset_prod; ID=VT-STALEMT; LOG="$TMP/$ID.log"
mkdir -p "$PROD/heygen"
printf '{"title":"%s","status":"submitted","renderedAt":"2026-05-28T00:00:00Z"}\n' "$SLUG" > "$PROD/heygen/heygen-submission.json"
touch "$PROD/script.md"   # now: newer than the 2026-05-28 render
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG"; then no "STALE-MT should block"; dump "$LOG"
else
  has "$ART/$ID.fail" "STALE RENDER" && ! compose_ran "$ID" && [[ ! -e "$BRAND/.dozers-review/$ID.md" ]] \
    && ok "STALE (mtime, no sha) blocks as STALE RENDER" || { no "STALE-MT block wrong"; dump "$ART/$ID.fail"; }
fi
touch -t 202601010000 "$PROD/script.md"   # restore: in sync again

# ── HAPPY: completed + in-sync render -> download, compose, stage ─────────────
reset_prod; ID=VT-HAPPY; LOG="$TMP/$ID.log"
mkdir -p "$PROD/heygen"
printf '{"title":"%s","status":"submitted","motionEngine":"Avatar III","creditsCost":2,"durationEstimate":20}\n' "$SLUG" > "$PROD/heygen/heygen-submission.json"
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG"; then
  DRAFT="$BRAND/.dozers-review/$ID.md"
  [[ -s "$PROD/heygen/raw-avatar.mp4" && -s "$PROD/final/short.mp4" && -s "$PROD/final/cover.png" ]] && compose_ran "$ID" \
    && ok "HAPPY: raw downloaded, final/short.mp4 + cover.png composed" || { no "HAPPY outputs missing"; dump "$LOG"; }
  if has "$DRAFT" "posts/quick" && has "$DRAFT" '"kind": "video"' && has "$DRAFT" "final/short.mp4" && has "$DRAFT" "cover.png" \
     && has "$DRAFT" "captionsByPlatform" && has "$DRAFT" "Know AI #1" && has "$DRAFT" "NOT published" \
     && ! grep -qE '"(bluesky|linkedin)"' "$DRAFT" && grep -qE '"(youtube|instagram|tiktok)"' "$DRAFT"; then
    ok "HAPPY: review draft carries mp4, cover, captions and a posts/quick payload (no bluesky, no linkedin)"
  else no "HAPPY review draft incomplete"; dump "$DRAFT"; fi
  if [[ "$(sub_status scriptSha256)" == "$SCRIPT_SHA" && "$(sub_status status)" == "staged" && "$(sub_status videoId)" == "vid-stale" \
        && "$(sub_status mp4Path)" == "heygen/raw-avatar.mp4" && -n "$(sub_status renderedAt)" && "$(sub_status motionEngine)" == "Avatar III" ]]; then
    ok "HAPPY: heygen-submission.json refreshed (videoId, renderedAt, motionEngine, mp4Path, scriptSha256, status)"
  else no "HAPPY submission record not refreshed correctly"; cat "$PROD/heygen/heygen-submission.json" >&2; fi
  if ! grep -q '/v2/' "$REQLOG" && has "$REQLOG" "/v1/video.list" && has "$REQLOG" "/v1/video_status.get" && has "$REQLOG" "/files/raw.mp4"; then
    ok "HAPPY: only /v1/ endpoints + the signed URL were hit (no /v2/)"
  else no "HAPPY hit an unexpected endpoint"; dump "$REQLOG"; fi
  has "$ART/$ID.summary" "NOT published" && ok "HAPPY: summary artifact written" || no "HAPPY summary missing"
  [[ -s "$ART/$ID.fail" ]] && no "HAPPY left a .fail artifact" || true
  # RERUN: idempotent — the raw is reused, not re-downloaded
  : > "$REQLOG"; ID2=VT-RERUN; LOG2="$TMP/$ID2.log"
  if run_crew "$ID2" "$(brief "$ID2" "$VIDEO_BRIEF")" "$LOG2" && has "$LOG2" "reusing" && ! has "$REQLOG" "/files/raw.mp4"; then
    ok "RERUN: existing raw-avatar.mp4 reused, nothing re-downloaded"
  else no "RERUN should reuse the downloaded raw"; dump "$LOG2"; fi
else no "HAPPY should succeed"; dump "$LOG"; [[ -s "$ART/$ID.fail" ]] && dump "$ART/$ID.fail"; fi

# ── NOKEY: vault missing -> fail fast, name the vault, never fall back ────────
reset_prod; ID=VT-NOKEY; LOG="$TMP/$ID.log"
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG" HEYGEN_VAULT="$TMP/does-not-exist.env"; then no "NOKEY should fail"; dump "$LOG"
else
  if has "$ART/$ID.fail" "$TMP/does-not-exist.env" && has "$ART/$ID.fail" "HEYGEN_API_KEY" && [[ ! -s "$REQLOG" ]] \
     && ! model_ran "$ID" && [[ ! -e "$BRAND/.dozers-review/$ID.md" ]]; then
    ok "NOKEY: fails naming the vault path; no HeyGen call, no copy-path fallback"
  else no "NOKEY should name the vault and not fall back"; dump "$ART/$ID.fail"; fi
fi

# ── UNAUTH: the key is rejected -> fail naming the vault ─────────────────────
reset_prod; ID=VT-UNAUTH; LOG="$TMP/$ID.log"
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG" HEYGEN_VAULT="$BAD_VAULT"; then no "UNAUTH should fail"; dump "$LOG"
else
  if has "$ART/$ID.fail" "$BAD_VAULT" && has "$ART/$ID.fail" "401" && ! grep -q 'wrong-key' "$ART/$ID.fail" "$LOG"; then
    ok "UNAUTH: rejected key fails naming the vault (key value never printed)"
  else no "UNAUTH reason wrong or leaked the key"; dump "$ART/$ID.fail"; fi
fi

# ── NOV2: static + guard ──────────────────────────────────────────────────────
if ! grep -qE 'hg_get "/v2/|api\.heygen\.com/v2' "$VIDEO"; then ok "NOV2: video.sh issues no /v2/ request"
else no "video.sh contains a /v2/ call"; fi
if has "$VIDEO" 'refusing HeyGen $path — /v2/'; then ok "NOV2: hg_get refuses a /v2/ path outright"
else no "hg_get should refuse /v2/"; fi

echo
if (( fail == 0 )); then echo "mktg-lane-video-test: PASS"; else echo "mktg-lane-video-test: FAIL" >&2; exit 1; fi
