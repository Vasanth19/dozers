#!/usr/bin/env bash
# tests/heygen-mcp-login-test.sh — regression test for GSAI-237 (the one-time HeyGen
# Remote MCP OAuth login flow GSAI-233 deferred).
#
# Drives the REAL script (scripts/heygen-mcp-login.sh) against a stubbed authorization
# server + Remote MCP endpoint (a local HTTP server) — no live HeyGen, no live browser,
# no real OAuth provider, no credits at risk. The stub enforces real PKCE (SHA256 of the
# code_verifier must match the code_challenge stored at authorize time), so a broken PKCE
# wiring fails EVERY case, not just the dedicated one.
#
# The one piece that's inherently interactive — a human clicking "authorize" in a
# browser — is simulated by having the test harness act as "the browser": once the
# script prints the authorization URL, the test either curls it (-L, following the
# stub's redirect straight into the script's own loopback listener) for the default
# interactive flow, or crafts the callback request itself for STATE-MISMATCH, or feeds a
# pasted redirect over stdin for --headless. This is the standard way to test a PKCE flow
# without UI automation.
#
# Cases (see DOZER-DESIGN-GSAI-237.md):
#   HAPPY                 discovery -> DCR -> PKCE authorize -> exchange -> vault write
#                         -> verify, all green (covers DISCOVER-OK / VERIFY-OK / PKCE-HAPPY)
#   DISCOVER-NO-CHALLENGE  401 has no WWW-Authenticate -> fails naming it, no authorize URL
#   DISCOVER-NO-AS-METADATA  authorization-server metadata 404s -> fails naming it
#   DCR-REUSE              a second login with an existing vault client id does not re-POST
#                         /register
#   DCR-NONE-WITH-OVERRIDE  no registration_endpoint, HEYGEN_MCP_CLIENT_ID set -> skips DCR
#   DCR-NONE-NO-OVERRIDE    neither -> fails with the exact remediation message
#   STATE-MISMATCH         simulated callback carries the wrong state -> rejected, nothing
#                         written
#   NO-REFRESH-TOKEN       token response omits refresh_token -> fails, vault untouched
#   PORT-BUSY              the configured port is pre-bound -> falls back to an
#                         OS-assigned port; redirect_uri matches the fallback
#   VERIFY-FAILS-BUT-TOKEN-WRITTEN  tokens issued and written, but the post-login verify
#                         call is rejected -> non-zero exit, vault still holds the tokens
#   CHECK-FLAG              --check against a pre-seeded vault hits only the verify step
#                         (zero authorize/register/token calls, exactly one MCP call)
#   HEADLESS-PASTE          --headless: prints the URL, reads the pasted redirect from
#                         stdin instead of starting a listener
#   NO-TTY-REFUSES          no tty, no --headless -> refuses immediately, no network call
#
# Run:  bash tests/heygen-mcp-login-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGIN="$ROOT/scripts/heygen-mcp-login.sh"

# Defensive: this test must stand on its own even run from inside a Dozer crew shell
# (tests/run-all.sh already scrubs DOZER_* from the outer env it invokes tests in, but a
# developer running this file directly may not have that scrub applied).
for v in $(compgen -e); do case "$v" in DOZER_*) unset "$v" ;; esac; done

for t in python3 curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "heygen-mcp-login-test: missing $t" >&2; exit 1; }
done

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() { [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2 2>/dev/null || true; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }

# ── stubbed authorization server + Remote MCP (GSAI-237) ─────────────────────────────
SCN="$TMP/scenario.json"; REQLOG="$TMP/requests.log"; DCRLOG="$TMP/dcr.log"; TOKENLOG="$TMP/token.log"
PORTFILE="$TMP/port"
cat > "$TMP/stub.py" <<'PY'
import base64, hashlib, http.server, json, socketserver, sys, urllib.parse
SCN, PORTFILE, REQLOG, DCRLOG, TOKENLOG = sys.argv[1:6]
CODES = {}
SEQ = [0]

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, code, body, extra=None):
        out = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        scn = json.load(open(SCN))
        open(REQLOG, "a").write("GET " + self.path + "\n")
        base = f"http://127.0.0.1:{self.server.server_address[1]}"
        if self.path.startswith("/.well-known/oauth-protected-resource"):
            return self._json(200, {"authorization_servers": [base]})
        if self.path.startswith("/.well-known/oauth-authorization-server"):
            if scn.get("omit_as_metadata"):
                return self._json(404, {"error": "not found"})
            meta = {"authorization_endpoint": base + "/authorize", "token_endpoint": base + "/token"}
            if not scn.get("omit_registration_endpoint"):
                meta["registration_endpoint"] = base + "/register"
            return self._json(200, meta)
        if self.path.startswith("/authorize"):
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            redirect_uri = qs["redirect_uri"][0]
            state = qs["state"][0]
            challenge = qs["code_challenge"][0]
            SEQ[0] += 1
            code = f"code-{SEQ[0]}"
            CODES[code] = challenge
            loc = redirect_uri + "?" + urllib.parse.urlencode({"code": code, "state": state})
            self.send_response(302); self.send_header("Location", loc); self.end_headers()
            return
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        scn = json.load(open(SCN))
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        open(REQLOG, "a").write("POST " + self.path + "\n")
        base = f"http://127.0.0.1:{self.server.server_address[1]}"
        if self.path.startswith("/mcp/v1"):
            auth = self.headers.get("Authorization", "")
            if not auth:
                extra = {} if scn.get("omit_www_auth") else {
                    "WWW-Authenticate": f'Bearer resource_metadata="{base}/.well-known/oauth-protected-resource"'}
                return self._json(401, {"error": "unauthorized"}, extra)
            tok = auth[len("Bearer "):] if auth.startswith("Bearer ") else ""
            if tok != scn.get("mcp_valid_token"):
                return self._json(401, {"error": "unauthorized"})
            req = json.loads(raw)
            return self._json(200, {"jsonrpc": "2.0", "id": req.get("id"), "result": {"tools": []}})
        if self.path.startswith("/register"):
            open(DCRLOG, "a").write(raw.decode("utf-8", "replace") + "\n")
            cid = scn.get("dcr_client_id")
            if not cid:
                return self._json(400, {"error": "registration not supported"})
            return self._json(200, {"client_id": cid})
        if self.path.startswith("/token"):
            open(TOKENLOG, "a").write(raw.decode("utf-8", "replace") + "\n")
            form = urllib.parse.parse_qs(raw.decode())
            code = form.get("code", [""])[0]
            verifier = form.get("code_verifier", [""])[0]
            challenge = CODES.get(code)
            if challenge is None:
                return self._json(400, {"error": "invalid_grant", "error_description": "unknown code"})
            want = b64u(hashlib.sha256(verifier.encode()).digest())
            if want != challenge:
                return self._json(400, {"error": "invalid_grant", "error_description": "PKCE verification failed"})
            body = {"access_token": scn.get("issued_access_token", "stub-access-token"), "expires_in": 3600}
            if not scn.get("omit_refresh_token"):
                body["refresh_token"] = scn.get("issued_refresh_token", "stub-refresh-token")
            return self._json(200, body)
        return self._json(404, {"error": "not found"})

srv = socketserver.TCPServer(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
scenario() {  # KEY=VALUE... (python-typed via json.loads on each value) -> overwrites $SCN
  python3 - "$SCN" "$@" <<'PY'
import json, sys
scn, pairs = sys.argv[1], sys.argv[2:]
d = {
    "omit_www_auth": False, "omit_as_metadata": False, "omit_registration_endpoint": False,
    "dcr_client_id": "stub-client-id", "mcp_valid_token": "stub-access-token",
    "issued_access_token": "stub-access-token", "omit_refresh_token": False,
    "issued_refresh_token": "stub-refresh-token",
}
for kv in pairs:
    k, v = kv.split("=", 1)
    try: v = json.loads(v)
    except Exception: pass
    d[k] = v
json.dump(d, open(scn, "w"))
PY
}
scenario
python3 "$TMP/stub.py" "$SCN" "$PORTFILE" "$REQLOG" "$DCRLOG" "$TOKENLOG" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$PORTFILE" ]] && break; sleep 0.1; done
[[ -s "$PORTFILE" ]] || { echo "stub authorization server did not start" >&2; exit 1; }
API="http://127.0.0.1:$(cat "$PORTFILE")"

reset_logs() { : > "$REQLOG"; : > "$DCRLOG"; : > "$TOKENLOG"; }
qparam() { python3 -c "import sys,urllib.parse as u; print(u.parse_qs(u.urlparse(sys.argv[1]).query).get(sys.argv[2],[''])[0])" "$1" "$2"; }

# run_login: $1=log $2.. = extra KEY=VAL env/flags for the script. Backgrounds it; sets
# $LOGINPID. Always points HEYGEN_MCP_URL at the stub and sets ASSUME_TTY (harmless for
# --headless, which already satisfies the preflight on its own).
run_login() {
  local log="$1"; shift
  rm -f "$log"
  env HEYGEN_MCP_LOGIN_ASSUME_TTY=1 HEYGEN_MCP_LOGIN_OPEN_CMD=true HEYGEN_MCP_URL="$API/mcp/v1/" "$@" \
    bash "$LOGIN" >"$log" 2>&1 &
  LOGINPID=$!
}
wait_for_url() {  # $1=log -> the printed authorize URL, or empty after ~5s
  local log="$1" i
  for i in $(seq 1 50); do
    grep -qE 'http://127\.0\.0\.1:[0-9]+/authorize\?' "$log" 2>/dev/null && break
    sleep 0.1
  done
  grep -oE 'http://127\.0\.0\.1:[0-9]+/authorize\?[^ ]*' "$log" | head -1
}
browse() { curl -sS -m 10 -L -o /dev/null "$1"; }   # "click authorize" -> follow stub's redirect into our listener

echo "== heygen-mcp-login.sh: GSAI-237 =="

# ── HAPPY: full round trip (DISCOVER-OK, DCR-OK, PKCE-HAPPY, VERIFY-OK) ───────────────
reset_logs; VAULT="$TMP/vault-happy.env"; LOG="$TMP/happy.log"; scenario
run_login "$LOG" HEYGEN_MCP_VAULT="$VAULT"
URL="$(wait_for_url "$LOG")"
if [[ -n "$URL" ]]; then browse "$URL"; else no "HAPPY: authorize URL never printed"; fi
wait "$LOGINPID"; RC=$?
if (( RC == 0 )) && has "$LOG" "Login complete" && [[ -s "$VAULT" ]] \
   && grep -q '^HEYGEN_MCP_ACCESS_TOKEN=stub-access-token$' "$VAULT" \
   && grep -q '^HEYGEN_MCP_REFRESH_TOKEN=stub-refresh-token$' "$VAULT" \
   && grep -q '^HEYGEN_MCP_CLIENT_ID=stub-client-id$' "$VAULT" \
   && [[ "$(wc -l < "$DCRLOG" | tr -d ' ')" == "1" ]] && [[ -s "$TOKENLOG" ]]; then
  ok "HAPPY: discovery -> DCR -> PKCE authorize -> exchange -> vault write -> verify, all green"
else no "HAPPY flow failed (exit $RC)"; dump "$LOG"; fi
if ! has "$LOG" "stub-access-token" && ! has "$LOG" "stub-refresh-token"; then
  ok "HAPPY: the access/refresh token values are never printed to the log"
else no "a token value leaked into the log"; dump "$LOG"; fi

# ── DISCOVER-NO-CHALLENGE: 401 has no WWW-Authenticate -> fails, no authorize URL ─────
reset_logs; LOG="$TMP/nochallenge.log"; scenario omit_www_auth=true
run_login "$LOG" HEYGEN_MCP_VAULT="$TMP/vault-nochallenge.env"
wait "$LOGINPID"; RC=$?
if (( RC != 0 )) && has "$LOG" "WWW-Authenticate" && ! has "$LOG" "/authorize?" && ! grep -q '/authorize' "$REQLOG"; then
  ok "DISCOVER-NO-CHALLENGE: fails naming the missing WWW-Authenticate, no authorize URL ever printed"
else no "DISCOVER-NO-CHALLENGE should fail naming the missing header"; dump "$LOG"; fi

# ── DISCOVER-NO-AS-METADATA: AS metadata 404s -> fails naming it ─────────────────────
reset_logs; LOG="$TMP/noasmeta.log"; scenario omit_as_metadata=true
run_login "$LOG" HEYGEN_MCP_VAULT="$TMP/vault-noasmeta.env"
wait "$LOGINPID"; RC=$?
if (( RC != 0 )) && has "$LOG" "authorization-server metadata" && ! has "$LOG" "/authorize?"; then
  ok "DISCOVER-NO-AS-METADATA: fails naming the missing authorization-server metadata"
else no "DISCOVER-NO-AS-METADATA should fail naming the missing metadata"; dump "$LOG"; fi

# ── DCR-REUSE: a second login with an existing vault client id does not re-register ──
reset_logs; VAULT="$TMP/vault-dcr.env"; LOG1="$TMP/dcr1.log"; LOG2="$TMP/dcr2.log"
scenario dcr_client_id=dcr-issued-client
run_login "$LOG1" HEYGEN_MCP_VAULT="$VAULT"
URL="$(wait_for_url "$LOG1")"; [[ -n "$URL" ]] && browse "$URL"
wait "$LOGINPID"; RC1=$?
DCR_COUNT_1="$(wc -l < "$DCRLOG" | tr -d ' ')"
if (( RC1 == 0 )) && grep -q '^HEYGEN_MCP_CLIENT_ID=dcr-issued-client$' "$VAULT" && [[ "$DCR_COUNT_1" == "1" ]]; then
  ok "DCR-OK: first login registers a client via DCR and writes it to the vault"
else no "DCR-OK first login failed"; dump "$LOG1"; fi
run_login "$LOG2" HEYGEN_MCP_VAULT="$VAULT"
URL="$(wait_for_url "$LOG2")"; [[ -n "$URL" ]] && browse "$URL"
wait "$LOGINPID"; RC2=$?
DCR_COUNT_2="$(wc -l < "$DCRLOG" | tr -d ' ')"
if (( RC2 == 0 )) && grep -q '^HEYGEN_MCP_CLIENT_ID=dcr-issued-client$' "$VAULT" && [[ "$DCR_COUNT_2" == "1" ]]; then
  ok "DCR-REUSE: second login reuses the vault's client id — no re-registration (still 1 DCR POST total)"
else no "DCR-REUSE should not re-POST /register (saw $DCR_COUNT_2 total, expected 1)"; dump "$LOG2"; fi

# ── DCR-NONE-WITH-OVERRIDE: no registration_endpoint, but HEYGEN_MCP_CLIENT_ID given ──
reset_logs; LOG="$TMP/dcrnone-ov.log"; VAULT="$TMP/vault-dcrnone-ov.env"
scenario omit_registration_endpoint=true
run_login "$LOG" HEYGEN_MCP_VAULT="$VAULT" HEYGEN_MCP_CLIENT_ID=override-client-id
URL="$(wait_for_url "$LOG")"; [[ -n "$URL" ]] && browse "$URL"
wait "$LOGINPID"; RC=$?
if (( RC == 0 )) && [[ ! -s "$DCRLOG" ]] && grep -q '^HEYGEN_MCP_CLIENT_ID=override-client-id$' "$VAULT" \
   && grep -q 'client_id=override-client-id' "$TOKENLOG"; then
  ok "DCR-NONE-WITH-OVERRIDE: no registration_endpoint + an env override -> DCR skipped, override used"
else no "DCR-NONE-WITH-OVERRIDE should skip DCR and use the override client id"; dump "$LOG"; fi

# ── DCR-NONE-NO-OVERRIDE: neither -> fails with the exact remediation message ────────
reset_logs; LOG="$TMP/dcrnone-none.log"
scenario omit_registration_endpoint=true
run_login "$LOG" HEYGEN_MCP_VAULT="$TMP/vault-dcrnone-none.env"
wait "$LOGINPID"; RC=$?
if (( RC != 0 )) && has "$LOG" "no registration_endpoint" && has "$LOG" "HEYGEN_MCP_CLIENT_ID=..." && ! has "$LOG" "/authorize?"; then
  ok "DCR-NONE-NO-OVERRIDE: fails naming both facts and the exact remediation"
else no "DCR-NONE-NO-OVERRIDE should fail with the exact remediation message"; dump "$LOG"; fi

# ── STATE-MISMATCH: simulated callback carries the wrong state -> rejected ───────────
reset_logs; VAULT="$TMP/vault-state.env"; LOG="$TMP/state.log"; scenario
run_login "$LOG" HEYGEN_MCP_VAULT="$VAULT"
URL="$(wait_for_url "$LOG")"
if [[ -n "$URL" ]]; then
  REDIR="$(qparam "$URL" redirect_uri)"
  curl -sS -m 10 -o /dev/null "${REDIR}?code=fake-code&state=totally-wrong-state"
else no "STATE-MISMATCH: authorize URL never printed"; fi
wait "$LOGINPID"; RC=$?
if (( RC != 0 )) && has "$LOG" "state mismatch" && [[ ! -s "$VAULT" ]]; then
  ok "STATE-MISMATCH: rejected on a wrong state, nothing written to the vault"
else no "STATE-MISMATCH should reject and write nothing"; dump "$LOG"; fi

# ── NO-REFRESH-TOKEN: token response omits refresh_token -> fails, vault untouched ───
reset_logs; VAULT="$TMP/vault-norefresh.env"; LOG="$TMP/norefresh.log"
scenario omit_refresh_token=true
run_login "$LOG" HEYGEN_MCP_VAULT="$VAULT"
URL="$(wait_for_url "$LOG")"; [[ -n "$URL" ]] && browse "$URL"
wait "$LOGINPID"; RC=$?
if (( RC != 0 )) && has "$LOG" "no refresh_token" && [[ ! -s "$VAULT" ]]; then
  ok "NO-REFRESH-TOKEN: fails fast, vault untouched"
else no "NO-REFRESH-TOKEN should fail and write nothing"; dump "$LOG"; fi

# ── PORT-BUSY: the configured port is pre-bound -> OS-assigned fallback ──────────────
reset_logs; VAULT="$TMP/vault-portbusy.env"; LOG="$TMP/portbusy.log"; scenario
python3 -c "
import socket, time
s = socket.socket(); s.bind(('127.0.0.1', 18743)); s.listen(1)
time.sleep(10)
" &
BUSYPID=$!
sleep 0.3
run_login "$LOG" HEYGEN_MCP_VAULT="$VAULT" HEYGEN_MCP_LOGIN_PORT=18743
URL="$(wait_for_url "$LOG")"
[[ -n "$URL" ]] && browse "$URL"
wait "$LOGINPID"; RC=$?
kill "$BUSYPID" 2>/dev/null; wait "$BUSYPID" 2>/dev/null
REDIR_PORT="$(qparam "$URL" redirect_uri)"
if (( RC == 0 )) && [[ -n "$URL" ]] && [[ "$REDIR_PORT" != *":18743/"* ]] && [[ -s "$VAULT" ]]; then
  ok "PORT-BUSY: falls back to an OS-assigned port; redirect_uri matches the fallback, not the busy 18743"
else no "PORT-BUSY should fall back to a free port"; dump "$LOG"; fi

# ── VERIFY-FAILS-BUT-TOKEN-WRITTEN: issued, written, but the final verify is rejected ─
reset_logs; VAULT="$TMP/vault-verifyfail.env"; LOG="$TMP/verifyfail.log"
scenario issued_access_token=fresh-verify-fail-token mcp_valid_token=some-other-token
run_login "$LOG" HEYGEN_MCP_VAULT="$VAULT"
URL="$(wait_for_url "$LOG")"; [[ -n "$URL" ]] && browse "$URL"
wait "$LOGINPID"; RC=$?
if (( RC != 0 )) && grep -q '^HEYGEN_MCP_ACCESS_TOKEN=fresh-verify-fail-token$' "$VAULT" \
   && has "$LOG" "post-login verify call failed" && has "$LOG" "401"; then
  ok "VERIFY-FAILS-BUT-TOKEN-WRITTEN: non-zero exit, but the issued tokens are still in the vault"
else no "VERIFY-FAILS-BUT-TOKEN-WRITTEN should still write the vault and fail loudly"; dump "$LOG"; fi

# ── CHECK-FLAG: --check against a pre-seeded vault hits only the verify step ──────────
reset_logs; VAULT="$TMP/vault-check.env"
printf 'HEYGEN_MCP_ACCESS_TOKEN=precheck-good-token\nHEYGEN_MCP_REFRESH_TOKEN=precheck-refresh\n' > "$VAULT"
scenario mcp_valid_token=precheck-good-token
LOG="$TMP/check.log"
env HEYGEN_MCP_LOGIN_ASSUME_TTY=1 HEYGEN_MCP_URL="$API/mcp/v1/" HEYGEN_MCP_VAULT="$VAULT" bash "$LOGIN" --check < /dev/null > "$LOG" 2>&1
RC=$?
MCP_CALLS="$(grep -c '^POST /mcp/v1' "$REQLOG" 2>/dev/null || echo 0)"
if (( RC == 0 )) && has "$LOG" "--check OK" && [[ ! -s "$DCRLOG" ]] && ! grep -q '/authorize' "$REQLOG" \
   && ! grep -q '^POST /token' "$REQLOG" && [[ "$MCP_CALLS" == "1" ]]; then
  ok "CHECK-FLAG: --check hits only the verify step — zero authorize/register/token calls, exactly one MCP call"
else no "CHECK-FLAG should make exactly one MCP call and nothing else"; dump "$LOG"; fi

# ── HEADLESS-PASTE: prints the URL, reads the pasted redirect from stdin ─────────────
reset_logs; VAULT="$TMP/vault-headless.env"; LOG="$TMP/headless.log"; scenario
rm -f "$TMP/headless.fifo"; mkfifo "$TMP/headless.fifo"
exec 9<>"$TMP/headless.fifo"   # held open read-write so the fifo never EOFs prematurely
env HEYGEN_MCP_LOGIN_OPEN_CMD=true HEYGEN_MCP_URL="$API/mcp/v1/" HEYGEN_MCP_VAULT="$VAULT" \
  bash "$LOGIN" --headless < "$TMP/headless.fifo" > "$LOG" 2>&1 &
LOGINPID=$!
URL="$(wait_for_url "$LOG")"
if [[ -n "$URL" ]]; then
  REDIR="$(qparam "$URL" redirect_uri)"; STATE="$(qparam "$URL" state)"
  # "the browser": hit the stub's real authorize endpoint (so PKCE's challenge is stored
  # server-side too) and capture the 302 Location it would have sent the browser to.
  LOC="$(curl -sS -m 10 -D - -o /dev/null "$URL" | grep -i '^Location:' | tr -d '\r' | sed 's/^[Ll]ocation: //')"
  printf '%s\n' "$LOC" >&9
fi
exec 9>&-
wait "$LOGINPID"; RC=$?
if (( RC == 0 )) && has "$LOG" "Login complete" && [[ -s "$VAULT" ]]; then
  ok "HEADLESS-PASTE: --headless reads the pasted redirect from stdin instead of starting a listener"
else no "HEADLESS-PASTE should complete the login from a pasted redirect"; dump "$LOG"; fi
rm -f "$TMP/headless.fifo"

# ── NO-TTY-REFUSES: no tty, no --headless -> refuses immediately, no network call ────
reset_logs; LOG="$TMP/notty.log"
bash "$LOGIN" < /dev/null > "$LOG" 2>&1
RC=$?
if (( RC != 0 )) && has "$LOG" "refusing to run non-interactively" && [[ ! -s "$REQLOG" ]]; then
  ok "NO-TTY-REFUSES: refuses immediately, no network call made at all"
else no "NO-TTY-REFUSES should refuse without touching the network"; dump "$LOG"; fi

echo
if (( fail == 0 )); then echo "heygen-mcp-login-test: PASS"; else echo "heygen-mcp-login-test: FAIL" >&2; exit 1; fi
