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
#   COPY        a brief without a production: line takes the copy path exactly as before
#               (stub model runs, draft staged, HeyGen never contacted)
#   AUTOSUBMIT  a video brief with no submitted render auto-submits via the HeyGen Remote
#               MCP stub (GSAI-233): asserts the exact submit payload (avatar/voice ids,
#               avatar_iii, title, script text, 9:16/1080p) and ends in the "processing,
#               re-greenlight later" block — no human-instruction text, no compose/stage
#   STALE       the script changed after the render (sha mismatch) -> auto-resubmits (new
#               videoId), no download/compose/stage this run
#   STALE-MT    no sha on record, script mtime newer than the render -> same auto-resubmit
#   MCP-NOKEY   the Remote MCP OAuth vault (test-pointed) is missing -> fails naming the
#               vault path; the MCP endpoint is never hit
#   MCP-REFRESH the stored access token is rejected once (401) -> one transparent refresh
#               -> retried submit succeeds; the vault is rewritten with the new token
#   MCP-CREDITS the stub's submit response simulates HeyGen's insufficient-credits error
#               -> fails with that exact text, no retry
#   HAPPY       completed, in-sync render -> raw downloaded + ffprobe-asserted, final/short.mp4
#               + cover.png, .dozers-review/<id>.md with a valid posts/quick payload (no
#               bluesky, no linkedin for MGG), record refreshed, only /v1/ endpoints hit
#   RERUN       the same brief again reuses the downloaded raw (idempotent)
#   NOKEY       vault file missing -> fails fast naming the vault path; HeyGen never contacted;
#               NO silent fallback to the copy path (no copy draft, model not run)
#   UNAUTH      vault holds a rejected key -> fails naming the vault path
#   NOV2        video.sh contains no /v2/ request path, hg_get refuses one, hg_get is only
#               ever called with the known-safe REST reads, and the MCP submit tool has
#               exactly one call site (inside auto_submit)
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
printf '## TTS Script\n\nThis is the test script for the reel.\n' > "$PROD/script.md"
printf 'Know AI #1 — test caption.\nFollow @mr.growthguide\n' > "$PROD/publish/caption.txt"
touch -t 202601010000 "$PROD/script.md"       # script authored long before any render
SCRIPT_SHA="$(shasum -a 256 "$PROD/script.md" | cut -d' ' -f1)"

# ── fixture render: 20s 1080x1920 h264 + aac, generated once ─────────────────
RAW_FIXTURE="$TMP/fixture-raw.mp4"
ffmpeg -y -v error -f lavfi -i "color=c=0x0F172A:s=1080x1920:r=10:d=20" -f lavfi -i "anullsrc=r=48000:cl=stereo" \
  -map 0:v -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -t 20 "$RAW_FIXTURE" \
  || { echo "could not build the fixture mp4" >&2; exit 1; }

# ── stubbed HeyGen: scenario file re-read on every request, request log ───────
# Also serves the Remote MCP submit tool (POST /mcp/v1/) and a token-refresh endpoint
# (POST /oauth/token) — GSAI-233. MCPLOG gets one line per tools/call request body, so
# tests assert on the exact payload that went over the wire, not a description of it.
SCN="$TMP/scenario.json"; REQLOG="$TMP/requests.log"; MCPLOG="$TMP/mcp-requests.log"; PORTFILE="$TMP/port"
GOOD_KEY="test-heygen-key-0000"
MCP_GOOD_TOKEN="test-mcp-access-token"
MCP_GOOD_REFRESH="test-mcp-refresh-token"
cat > "$TMP/heygen-stub.py" <<'PY'
import json, sys, http.server, socketserver
SCN, PORTFILE, LOG, MCPLOG = sys.argv[1:5]
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
    def do_POST(self):
        scn = json.load(open(SCN))
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        open(LOG, "a").write("POST " + self.path + "\n")
        if self.path.startswith("/mcp/v1"):
            open(MCPLOG, "a").write(raw.decode("utf-8", "replace") + "\n")
            auth = self.headers.get("Authorization", "")
            tok = auth[len("Bearer "):] if auth.startswith("Bearer ") else ""
            if tok != scn.get("mcp_valid_token"):
                return self._json(401, {"error": "unauthorized"})
            req = json.loads(raw)
            rid = req.get("id")
            if scn.get("mcp_credits_error"):
                return self._json(200, {"jsonrpc": "2.0", "id": rid, "result": {
                    "isError": True,
                    "content": [{"type": "text", "text": scn.get("mcp_credits_message", "Insufficient credits")}]}})
            vid = scn.get("mcp_new_video_id", "vid-auto")
            return self._json(200, {"jsonrpc": "2.0", "id": rid, "result": {
                "isError": False,
                "content": [{"type": "text", "text": json.dumps({"video_id": vid, "credits_cost": 2})}]}})
        if self.path.startswith("/oauth/token"):
            new_tok = scn.get("mcp_refreshed_token", "")
            if not new_tok:
                return self._json(400, {"error": "invalid_grant"})
            return self._json(200, {"access_token": new_tok, "refresh_token": scn.get("mcp_refreshed_refresh", "")})
        return self._json(404, {"code": 40404, "message": "no such route"})
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
scenario() {  # $1 = videos JSON array; extra KEY=VALUE... merged into the scenario (mcp_*)
  local videos="$1"; shift || true
  python3 - "$SCN" "$GOOD_KEY" "$RAW_FIXTURE" "$videos" "$MCP_GOOD_TOKEN" "$@" <<'PY'
import json, sys
scn, key, raw, videos, mcp_tok = sys.argv[1:6]
d = {"key": key, "raw": raw, "duration": 20.0, "videos": json.loads(videos), "mcp_valid_token": mcp_tok}
for kv in sys.argv[6:]:
    k, v = kv.split("=", 1)
    d[k] = v
json.dump(d, open(scn, "w"))
PY
}
scenario '[]'
python3 "$TMP/heygen-stub.py" "$SCN" "$PORTFILE" "$REQLOG" "$MCPLOG" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$PORTFILE" ]] && break; sleep 0.1; done
[[ -s "$PORTFILE" ]] || { echo "stub HeyGen did not start" >&2; exit 1; }
API="http://127.0.0.1:$(cat "$PORTFILE")"
RENDER_TS=1780000000   # 2026-05-28 — after the script's 2026-01-01 mtime

# ── Remote MCP OAuth vault fixtures (GSAI-233) ────────────────────────────────
MCP_VAULT="$TMP/heygen-mcp-oauth.env"
printf 'HEYGEN_MCP_ACCESS_TOKEN=%s\nHEYGEN_MCP_REFRESH_TOKEN=%s\n' "$MCP_GOOD_TOKEN" "$MCP_GOOD_REFRESH" > "$MCP_VAULT"
chmod 600 "$MCP_VAULT"
MCP_VAULT_EXPIRED="$TMP/heygen-mcp-oauth-expired.env"
printf 'HEYGEN_MCP_ACCESS_TOKEN=%s\nHEYGEN_MCP_REFRESH_TOKEN=%s\n' "expired-access-token" "$MCP_GOOD_REFRESH" > "$MCP_VAULT_EXPIRED"
chmod 600 "$MCP_VAULT_EXPIRED"

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
      HEYGEN_VAULT="$VAULT" HEYGEN_API_BASE="$API" \
      HEYGEN_MCP_VAULT="$MCP_VAULT" HEYGEN_MCP_URL="$API/mcp/v1/" HEYGEN_MCP_TOKEN_URL="$API/oauth/token" "$@" \
      bash "$CREW" "$id" "GSAI-7 test brief" >"$log" 2>&1
}
model_ran()   { [[ -e "$TMP/$1.model-ran" ]]; }
compose_ran() { [[ -e "$TMP/$1.compose-ran" ]]; }
reset_prod()  { rm -rf "$PROD/heygen" "$PROD/final" "$BRAND/.dozers-review" 2>/dev/null || true; : > "$REQLOG"; : > "$MCPLOG"; }
sub_status()  { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$PROD/heygen/heygen-submission.json" "$1" 2>/dev/null || true; }

echo "== mktg lane: video branch (GSAI-7) =="

# ── COPY: no production: line -> the old path, untouched ─────────────────────
reset_prod; ID=VT-COPY; LOG="$TMP/$ID.log"
if run_crew "$ID" "$(brief "$ID" "$COPY_BRIEF")" "$LOG"; then
  if model_ran "$ID" && has "$BRAND/.dozers-review/$ID.md" "COPY DRAFT" && [[ ! -s "$REQLOG" ]] && [[ -s "$ART/$ID.summary" ]]; then
    ok "COPY brief takes the copy path: model ran, draft staged, HeyGen never contacted"
  else no "COPY brief should stage a copy draft without touching HeyGen"; dump "$LOG"; fi
else no "COPY brief should succeed (exit $?)"; dump "$LOG"; fi

# ── AUTOSUBMIT: no submission record, no matching render -> auto-submit via Remote MCP ─
reset_prod; ID=VT-AUTOSUB; LOG="$TMP/$ID.log"
scenario '[{"video_id":"other","status":"completed","video_title":"unrelated","created_at":1780000000}]' mcp_new_video_id=vid-autosubmit
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG"; then no "AUTOSUBMIT should end in the still-processing block"; dump "$LOG"
else
  F="$ART/$ID.fail"
  if has "$F" "processing" && has "$F" "vid-autosubmit" && ! has "$F" "SUBMIT NEEDED"; then
    ok "AUTOSUBMIT ends in the 'processing, re-greenlight later' block, not a human-instruction block"
  else no "AUTOSUBMIT block reason wrong"; dump "$F"; fi
  if [[ -s "$MCPLOG" ]] && tail -1 "$MCPLOG" | python3 -c '
import json,sys
d = json.load(sys.stdin); a = d["params"]["arguments"]
assert a["avatar_id"] == "9273e994f1ed484d9031afa3725676c5"
assert a["voice_id"] == "6a9a4d08391e4321a48d019e192fa6fe"
assert a["engine"] == {"type": "avatar_iii"}
assert a["title"] == sys.argv[1]
assert a["aspect_ratio"] == "9:16" and a["resolution"] == "1080p"
assert "This is the test script for the reel." in a["script"]
' "$SLUG" 2>/dev/null; then
    ok "AUTOSUBMIT: exact submit payload (avatar/voice ids, avatar_iii, title, script, 9:16/1080p)"
  else no "AUTOSUBMIT submit payload wrong"; dump "$MCPLOG"; fi
  if [[ "$(sub_status status)" == "submitted" && "$(sub_status videoId)" == "vid-autosubmit" && "$(sub_status motionEngine)" == "Avatar III" ]]; then
    ok "AUTOSUBMIT: submission record written (status=submitted, videoId, motionEngine)"
  else no "AUTOSUBMIT submission record wrong"; cat "$PROD/heygen/heygen-submission.json" >&2 2>/dev/null || true; fi
  if ! compose_ran "$ID" && [[ ! -e "$PROD/final/short.mp4" && ! -e "$BRAND/.dozers-review/$ID.md" ]] && ! model_ran "$ID"; then
    ok "AUTOSUBMIT: no compose, no stage, no copy-draft fallback"
  else no "AUTOSUBMIT must not compose, stage, or fall back to copy"; dump "$LOG"; fi
  has "$REQLOG" "/v1/video.list" && ok "AUTOSUBMIT looked at /v1/video.list first (dedup search)" || no "AUTOSUBMIT should have listed renders first"
fi

# ── MCP-NOKEY: Remote MCP OAuth vault missing -> fail fast, MCP never contacted ─
reset_prod; ID=VT-MCPNOKEY; LOG="$TMP/$ID.log"; scenario '[]'
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG" HEYGEN_MCP_VAULT="$TMP/does-not-exist-mcp.env"; then no "MCP-NOKEY should fail"; dump "$LOG"
else
  if has "$ART/$ID.fail" "$TMP/does-not-exist-mcp.env" && [[ ! -s "$MCPLOG" ]]; then
    ok "MCP-NOKEY: fails naming the vault path; the Remote MCP is never contacted"
  else no "MCP-NOKEY should name the vault and never hit the MCP endpoint"; dump "$ART/$ID.fail"; fi
fi

# ── MCP-REFRESH: stored access token rejected once -> transparent refresh -> submit OK ─
reset_prod; ID=VT-MCPREFRESH; LOG="$TMP/$ID.log"
cp "$MCP_VAULT_EXPIRED" "$TMP/$ID-mcp-vault.env"
scenario '[]' mcp_valid_token=fresh-access-token mcp_new_video_id=vid-refreshed \
  mcp_refreshed_token=fresh-access-token mcp_refreshed_refresh=fresh-refresh-token
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG" HEYGEN_MCP_VAULT="$TMP/$ID-mcp-vault.env"; then no "MCP-REFRESH should end in the still-processing block"; dump "$LOG"
else
  if has "$ART/$ID.fail" "vid-refreshed" && has "$LOG" "refreshing" && grep -q "fresh-access-token" "$TMP/$ID-mcp-vault.env"; then
    ok "MCP-REFRESH: one transparent refresh, retried submit succeeds, vault rewritten with the new token"
  else no "MCP-REFRESH failed to refresh/retry/rewrite correctly"; dump "$LOG"; fi
fi

# ── MCP-CREDITS: HeyGen reports insufficient web-plan credits -> fail, no retry ─
reset_prod; ID=VT-MCPCREDITS; LOG="$TMP/$ID.log"
scenario '[]' mcp_credits_error=1 mcp_credits_message='Insufficient credits: your plan has 0 credits remaining.'
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG"; then no "MCP-CREDITS should fail"; dump "$LOG"
else
  MCPCALLS="$(grep -c '"jsonrpc"' "$MCPLOG" 2>/dev/null || echo 0)"
  if has "$ART/$ID.fail" "Insufficient credits: your plan has 0 credits remaining." \
     && [[ "$(sub_status status)" != "submitted" ]] && [[ "$MCPCALLS" -eq 1 ]]; then
    ok "MCP-CREDITS: fails with HeyGen's exact error text, no retry, no record written"
  else no "MCP-CREDITS should fail with the exact credits message and not retry"; dump "$ART/$ID.fail"; fi
fi

# ── STALE: recorded sha differs from the current script -> auto-resubmit ─────
reset_prod; ID=VT-STALE; LOG="$TMP/$ID.log"
scenario "[{\"video_id\":\"vid-stale\",\"status\":\"completed\",\"video_title\":\"$SLUG\",\"created_at\":$RENDER_TS}]" mcp_new_video_id=vid-stale-resubmit
mkdir -p "$PROD/heygen"
printf '{"title":"%s","videoId":"vid-stale","status":"submitted","scriptSha256":"%s"}\n' "$SLUG" "0000000000000000000000000000000000000000000000000000000000000000" > "$PROD/heygen/heygen-submission.json"
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG"; then no "STALE should end in the still-processing block"; dump "$LOG"
else
  F="$ART/$ID.fail"
  if has "$LOG" "STALE RENDER" && has "$LOG" "auto-resubmitting" && has "$F" "vid-stale-resubmit" && has "$F" "processing"; then
    ok "STALE (sha): auto-resubmits (new videoId), ends in the processing block"
  else no "STALE block reason wrong"; dump "$F"; dump "$LOG"; fi
  if [[ "$(sub_status videoId)" == "vid-stale-resubmit" && "$(sub_status status)" == "submitted" ]] \
     && ! compose_ran "$ID" && [[ ! -e "$PROD/heygen/raw-avatar.mp4" && ! -e "$PROD/final/short.mp4" && ! -e "$BRAND/.dozers-review/$ID.md" ]] \
     && ! has "$REQLOG" "/files/raw.mp4"; then
    ok "STALE: no download, no compose, no stage — record now points at the fresh submit"
  else no "STALE must not download/compose/stage, and must record the new videoId"; dump "$LOG"; fi
fi

# ── STALE-MT: no sha on record, script touched after the render -> auto-resubmit ─
reset_prod; ID=VT-STALEMT; LOG="$TMP/$ID.log"
scenario "[{\"video_id\":\"vid-stalemt\",\"status\":\"completed\",\"video_title\":\"$SLUG\",\"created_at\":$RENDER_TS}]" mcp_new_video_id=vid-stalemt-resubmit
mkdir -p "$PROD/heygen"
printf '{"title":"%s","status":"submitted","renderedAt":"2026-05-28T00:00:00Z"}\n' "$SLUG" > "$PROD/heygen/heygen-submission.json"
touch "$PROD/script.md"   # now: newer than the 2026-05-28 render
if run_crew "$ID" "$(brief "$ID" "$VIDEO_BRIEF")" "$LOG"; then no "STALE-MT should end in the still-processing block"; dump "$LOG"
else
  if has "$LOG" "STALE RENDER" && has "$LOG" "auto-resubmitting" && has "$ART/$ID.fail" "vid-stalemt-resubmit" \
     && [[ "$(sub_status videoId)" == "vid-stalemt-resubmit" ]] && ! compose_ran "$ID" && [[ ! -e "$BRAND/.dozers-review/$ID.md" ]]; then
    ok "STALE (mtime, no sha): auto-resubmits (new videoId), ends in the processing block"
  else no "STALE-MT block wrong"; dump "$ART/$ID.fail"; dump "$LOG"; fi
fi
touch -t 202601010000 "$PROD/script.md"   # restore: in sync again
touch -t 202601010000 "$PROD/script.md"   # restore: in sync again

# ── HAPPY: completed + in-sync render -> download, compose, stage ─────────────
reset_prod; ID=VT-HAPPY; LOG="$TMP/$ID.log"
scenario "[{\"video_id\":\"vid-stale\",\"status\":\"completed\",\"video_title\":\"$SLUG\",\"created_at\":$RENDER_TS}]"
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

# ── FACELESS: p-reels-faceless (no avatar) — no heygen: block, never contacted (GSAI-262) ─
reset_prod; ID=VT-FACELESS; LOG="$TMP/$ID.log"
cp "$BRAND/.config/brand.yaml" "$TMP/brand.yaml.bak"
cp "$PROD/brief.md" "$TMP/prod-brief.md.bak"
cat > "$BRAND/.config/brand.yaml" <<'EOF'
brandInfo:
  id: "B-GROWTHGUIDE"
platforms:
  enabled: [youtube, instagram, facebook, linkedin, tiktok, twitter, threads, bluesky]
EOF
if ! grep -q 'valid_non_default' "$BRAND/.brand/recipe-policy.yaml"; then
  cat >> "$BRAND/.brand/recipe-policy.yaml" <<'EOF'
valid_non_default:
  - p-reels-faceless
EOF
fi
cat > "$PROD/brief.md" <<'EOF'
# Test reel brief
Recipe: p-reels-faceless
**Recipe deviation:** faceless per fixture
EOF
STUB_COMPOSE_FACELESS="$TMP/stub-compose-faceless.sh"
cat > "$STUB_COMPOSE_FACELESS" <<'EOS'
#!/usr/bin/env bash
set -e; : > "$COMPOSE_RAN"
mkdir -p "$(dirname "$OUT_MP4")"
ffmpeg -y -v error -f lavfi -i "color=c=0x1E293B:s=1080x1920:r=10:d=18" -f lavfi -i "anullsrc=r=48000:cl=stereo" \
  -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p -c:a aac -t 18 "$OUT_MP4"
ffmpeg -y -v error -ss 1 -i "$OUT_MP4" -frames:v 1 "$OUT_COVER"
EOS
chmod +x "$STUB_COMPOSE_FACELESS"
if env MODEL_RAN="$TMP/$ID.model-ran" COMPOSE_RAN="$TMP/$ID.compose-ran" \
    REPO_ROOT="$REPO" WORKDIR="$BRAND" DOZER_BRIEF="$(brief "$ID" "$VIDEO_BRIEF")" DOZER_PERSONA="test" \
    MODEL_CMD="bash $STUB_MODEL" COMPOSE_CMD="bash $STUB_COMPOSE_FACELESS" \
    HEYGEN_VAULT="$TMP/does-not-exist-faceless.env" HEYGEN_API_BASE="$API" \
    HEYGEN_MCP_VAULT="$TMP/does-not-exist-faceless-mcp.env" HEYGEN_MCP_URL="$API/mcp/v1/" HEYGEN_MCP_TOKEN_URL="$API/oauth/token" \
    bash "$CREW" "$ID" "GSAI-262 test brief" >"$LOG" 2>&1; then
  DRAFT="$BRAND/.dozers-review/$ID.md"
  if [[ ! -s "$REQLOG" && ! -s "$MCPLOG" ]]; then
    ok "FACELESS: zero HeyGen contact (REQLOG and MCPLOG both empty)"
  else no "FACELESS should never contact HeyGen"; dump "$REQLOG"; dump "$MCPLOG"; fi
  if [[ ! -d "$PROD/heygen" ]]; then
    ok "FACELESS: \$PROD/heygen/ never created"
  else no "FACELESS must not create heygen/ (no submission, no raw-avatar.mp4)"; ls -la "$PROD/heygen" >&2; fi
  if [[ -s "$PROD/final/short.mp4" && -s "$PROD/final/cover.png" ]] && compose_ran "$ID"; then
    ok "FACELESS: final/short.mp4 + cover.png composed without an avatar"
  else no "FACELESS compose outputs missing"; dump "$LOG"; fi
  if has "$DRAFT" "no-avatar" && has "$DRAFT" "p-reels-faceless" && has "$DRAFT" "posts/quick" && has "$DRAFT" "NOT published"; then
    ok "FACELESS: staged with the no-avatar render line and a valid posts/quick payload"
  else no "FACELESS draft missing the no-avatar render line"; dump "$DRAFT"; fi
else no "FACELESS should succeed (this is the GSAI-262 regression check — today it fails demanding an avatar)"; dump "$LOG"; [[ -s "$ART/$ID.fail" ]] && dump "$ART/$ID.fail"; fi

# DRY_RUN sub-case: no COMPOSE_CMD, exercises the synthetic no-avatar placeholder
reset_prod; ID=VT-FACELESSDRY; LOG="$TMP/$ID.log"
if env MODEL_RAN="$TMP/$ID.model-ran" COMPOSE_RAN="$TMP/$ID.compose-ran" \
    REPO_ROOT="$REPO" WORKDIR="$BRAND" DOZER_BRIEF="$(brief "$ID" "$VIDEO_BRIEF")" DOZER_PERSONA="test" \
    MODEL_CMD="bash $STUB_MODEL" DRY_RUN=1 \
    HEYGEN_VAULT="$TMP/does-not-exist-faceless.env" HEYGEN_API_BASE="$API" \
    HEYGEN_MCP_VAULT="$TMP/does-not-exist-faceless-mcp.env" HEYGEN_MCP_URL="$API/mcp/v1/" HEYGEN_MCP_TOKEN_URL="$API/oauth/token" \
    bash "$CREW" "$ID" "GSAI-262 dry-run test brief" >"$LOG" 2>&1; then
  if [[ -s "$PROD/final/short.mp4" && -s "$PROD/final/cover.png" ]]; then
    read -r D_VCODEC D_WH D_DUR D_ACODEC <<<"$(python3 - "$PROD/final/short.mp4" <<'PY'
import json, subprocess, sys
out = subprocess.run(["ffprobe","-v","error","-print_format","json","-show_streams","-show_format",sys.argv[1]],capture_output=True,text=True)
d = json.loads(out.stdout)
v = next((s for s in d.get("streams", []) if s.get("codec_type")=="video"), None)
a = next((s for s in d.get("streams", []) if s.get("codec_type")=="audio"), None)
dur = d.get("format", {}).get("duration") or (v or {}).get("duration") or "0"
print((v or {}).get("codec_name","-"), f"{(v or {}).get('width','?')}x{(v or {}).get('height','?')}", f"{float(dur):.2f}", (a or {}).get("codec_name","-"))
PY
)"
    if [[ "$D_VCODEC" == "h264" && "$D_WH" == "1080x1920" && "$D_ACODEC" == "aac" ]] \
       && python3 -c "import sys; sys.exit(0 if float('$D_DUR') >= 18 else 1)"; then
      ok "FACELESS DRY_RUN: synthetic placeholder passes the ffprobe contract (1080x1920 h264+aac >=18s), no model/COMPOSE_CMD call"
    else no "FACELESS DRY_RUN placeholder failed the ffprobe contract"; fi
  else no "FACELESS DRY_RUN produced no final outputs"; dump "$LOG"; fi
else no "FACELESS DRY_RUN should succeed"; dump "$LOG"; [[ -s "$ART/$ID.fail" ]] && dump "$ART/$ID.fail"; fi
cp "$TMP/brand.yaml.bak" "$BRAND/.config/brand.yaml"
cp "$TMP/prod-brief.md.bak" "$PROD/brief.md"

# ── Stretch: p-reels-split (uploaded-footage, also off the allowlist) — no heygen: block ─
reset_prod; ID=VT-UPLOADED; LOG="$TMP/$ID.log"
cp "$BRAND/.config/brand.yaml" "$TMP/brand.yaml.bak2"
cp "$PROD/brief.md" "$TMP/prod-brief.md.bak2"
cat > "$BRAND/.config/brand.yaml" <<'EOF'
brandInfo:
  id: "B-GROWTHGUIDE"
platforms:
  enabled: [youtube, instagram, facebook, linkedin, tiktok, twitter, threads, bluesky]
EOF
cat > "$PROD/brief.md" <<'EOF'
# Test reel brief
Recipe: p-reels-split
**Recipe deviation:** uploaded footage per fixture
EOF
if env MODEL_RAN="$TMP/$ID.model-ran" COMPOSE_RAN="$TMP/$ID.compose-ran" \
    REPO_ROOT="$REPO" WORKDIR="$BRAND" DOZER_BRIEF="$(brief "$ID" "$VIDEO_BRIEF")" DOZER_PERSONA="test" \
    MODEL_CMD="bash $STUB_MODEL" COMPOSE_CMD="bash $STUB_COMPOSE_FACELESS" \
    HEYGEN_VAULT="$TMP/does-not-exist-faceless.env" HEYGEN_API_BASE="$API" \
    HEYGEN_MCP_VAULT="$TMP/does-not-exist-faceless-mcp.env" HEYGEN_MCP_URL="$API/mcp/v1/" HEYGEN_MCP_TOKEN_URL="$API/oauth/token" \
    bash "$CREW" "$ID" "GSAI-262 uploaded-footage test brief" >"$LOG" 2>&1; then
  if [[ ! -s "$REQLOG" && ! -s "$MCPLOG" && ! -d "$PROD/heygen" ]]; then
    ok "UPLOADED (p-reels-split): off the allowlist too — no HeyGen contact, no heygen/ dir"
  else no "UPLOADED should never contact HeyGen"; dump "$REQLOG"; dump "$MCPLOG"; fi
else no "UPLOADED (p-reels-split) should succeed"; dump "$LOG"; [[ -s "$ART/$ID.fail" ]] && dump "$ART/$ID.fail"; fi
cp "$TMP/brand.yaml.bak2" "$BRAND/.config/brand.yaml"
cp "$TMP/prod-brief.md.bak2" "$PROD/brief.md"

# ── NOV2: static + guard ──────────────────────────────────────────────────────
if ! grep -qE 'hg_get "/v2/|api\.heygen\.com/v2' "$VIDEO"; then ok "NOV2: video.sh issues no /v2/ request"
else no "video.sh contains a /v2/ call"; fi
if has "$VIDEO" 'refusing HeyGen $path — /v2/'; then ok "NOV2: hg_get refuses a /v2/ path outright"
else no "hg_get should refuse /v2/"; fi
# Broadened (GSAI-233): hg_get (the REST client) is only ever called with the two known-safe
# reads — no raw REST generate/submit/create path exists anywhere in the file.
UNEXPECTED_HG_GET="$(grep -oE 'hg_get "[^"]*"' "$VIDEO" | grep -vE '/v1/video\.list\?|/v1/video_status\.get\?' || true)"
if [[ -z "$UNEXPECTED_HG_GET" ]]; then ok "NOV2: hg_get (REST) is only ever called with /v1/video.list or /v1/video_status.get"
else no "video.sh calls hg_get with an unexpected REST path"; printf '%s\n' "$UNEXPECTED_HG_GET" >&2; fi
# Only auto_submit() may create a render — one call site for the MCP submit tool.
HG_MCP_CALL_SITES="$(grep -c 'hg_mcp_call "\$HEYGEN_MCP_TOOL"' "$VIDEO" || true)"
if [[ "$HG_MCP_CALL_SITES" -eq 1 ]]; then ok "NOV2: the MCP submit tool has exactly one call site (inside auto_submit)"
else no "expected exactly one hg_mcp_call \"\$HEYGEN_MCP_TOOL\" call site, found $HG_MCP_CALL_SITES"; fi

echo
if (( fail == 0 )); then echo "mktg-lane-video-test: PASS"; else echo "mktg-lane-video-test: FAIL" >&2; exit 1; fi
