#!/usr/bin/env bash
# scripts/heygen-mcp-login.sh — the ONE-TIME human OAuth login for HeyGen's Remote MCP
# (GSAI-237). GSAI-233 shipped video.sh's MCP *consumer* (hg_mcp_call/hg_mcp_refresh) but
# nothing populated ~/ecosystem/vault/heygen-mcp-oauth.env, so every auto-submit failed
# fast with "run the one-time HeyGen Remote MCP OAuth login" — there was no such login to
# run. This script is it. It is a standalone, human-run credential tool (alongside
# quota-by-project.sh, spend-by-kr.sh) — it is NEVER invoked by a Dozer crew, and video.sh
# never sources or calls it.
#
# Why discovery, not another hardcoded URL: the GSAI-233 review flagged video.sh's
# HEYGEN_MCP_URL/HEYGEN_MCP_TOKEN_URL as unverified guesses. This script never adds a
# third guess next to them — it walks the standard MCP Remote-server authorization chain
# (RFC 9728 protected-resource metadata -> RFC 8414 authorization-server metadata ->
# optional RFC 7591 dynamic client registration -> RFC 6749 authorization code + PKCE
# S256) and fails fast, naming the exact missing piece, if HeyGen's Remote MCP does not
# actually implement it. See DOZER-DESIGN-GSAI-237.md for the full design.
#
# Usage:
#   scripts/heygen-mcp-login.sh [--headless] [--check] [--port N]
#
# Flags:
#   --headless  print the authorization URL and read the resulting redirect (full URL,
#               or a bare code) back from stdin instead of starting a local loopback
#               listener — for an SSH session with no local browser. Default: open a
#               browser and listen on 127.0.0.1 for the redirect.
#   --check     skip the OAuth round-trip entirely; make one harmless tools/list call
#               with the vault's EXISTING access token and report whether it still
#               works. Zero authorize/token-endpoint calls.
#   -h, --help  this text.
#
# Env:
#   HEYGEN_MCP_VAULT      vault file to write (default ~/ecosystem/vault/heygen-mcp-oauth.env
#                         — the exact path video.sh's hg_mcp_call/hg_mcp_refresh read)
#   HEYGEN_MCP_URL        Remote MCP endpoint used to trigger discovery and for the final
#                         verify call (default https://mcp.heygen.com/mcp/v1/ — same knob
#                         name video.sh uses, so one vault/env story; tests point it at a
#                         local stub)
#   HEYGEN_MCP_CLIENT_ID  a pre-registered client id; skips Dynamic Client Registration.
#                         If unset, an existing client id already in the vault is reused
#                         (never re-registered); only if neither exists AND the
#                         authorization server advertises no registration_endpoint does
#                         this script fail, naming both facts.
#   HEYGEN_MCP_LOGIN_PORT     loopback listener port (default 8743; falls back to an
#                         OS-assigned port if that one is already bound by something else)
#   HEYGEN_MCP_LOGIN_TIMEOUT seconds to wait for the OAuth callback (default 300)
#   HEYGEN_MCP_LOGIN_OPEN_CMD command used to open the authorization URL in a browser
#                         (default: macOS `open`)
#   HEYGEN_MCP_LOGIN_ASSUME_TTY=1  TEST-ONLY — bypass the interactive-terminal preflight
#                         check without going --headless, so tests/heygen-mcp-login-test.sh
#                         can drive the real loopback-listener code path (acting as "the
#                         browser" by curling the callback itself) under a test harness
#                         that has no real tty. Never set this for an actual login.
#
# Never falls back to a hardcoded authorize/token URL — every endpoint comes from
# discovery or an explicit override. Never prints a token value, only the vault path and
# a success/fail line (vault doctrine). Not wired into org/config.yaml, crew.sh, or any
# `dozer:ready` lane path — this is a credential-setup tool, not part of a lane.
set -euo pipefail

usage() { sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

HEADLESS=0
CHECK=0
PORT="${HEYGEN_MCP_LOGIN_PORT:-8743}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless) HEADLESS=1; shift ;;
    --check) CHECK=1; shift ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "heygen-mcp-login.sh: unknown argument '$1' (see --help)" >&2; exit 1 ;;
  esac
done

# ── Preflight: this is a human, one-time tool. Refuse under a lane-crew environment
# (any DOZER_* var — nothing wires a crew to call this, but a script that *can* run
# headless inside one and silently do nothing useful is worse than one that refuses
# loudly) and refuse non-interactively unless --headless was explicitly passed. ──────
for v in $(compgen -e); do
  case "$v" in
    DOZER_*)
      echo "heygen-mcp-login.sh: refusing to run — $v is set. This looks like a Dozer lane-crew environment; heygen-mcp-login.sh is a human-run, one-time credential tool and must never be invoked by a crew." >&2
      exit 1
      ;;
  esac
done
if [[ "$HEADLESS" != "1" && "${HEYGEN_MCP_LOGIN_ASSUME_TTY:-0}" != "1" ]]; then
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "heygen-mcp-login.sh: refusing to run non-interactively. This is a human OAuth login tool — run it from a real terminal, or pass --headless for an SSH session with no local browser." >&2
    exit 1
  fi
fi

command -v python3 >/dev/null 2>&1 || { echo "heygen-mcp-login.sh: missing python3" >&2; exit 1; }

HEYGEN_MCP_VAULT="${HEYGEN_MCP_VAULT:-$HOME/ecosystem/vault/heygen-mcp-oauth.env}"
HEYGEN_MCP_URL="${HEYGEN_MCP_URL:-https://mcp.heygen.com/mcp/v1/}"

# The python body lives in a temp file, NOT a `python3 - <<PY` heredoc: a heredoc feeds
# the script SOURCE over the process's own stdin, which would leave nothing on stdin for
# --headless's interactive input() prompt (it would hit EOF immediately). A real file
# keeps this script's actual stdin (terminal, or a test harness's pipe) free for that.
HG_TMP_PY="$(mktemp -t heygen-mcp-login-py)"
trap 'rm -f "$HG_TMP_PY"' EXIT
cat > "$HG_TMP_PY" <<'PY'
import base64, hashlib, http.server, json, os, re, secrets, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request

def eprint(*a): print("heygen-mcp-login.sh:", *a, file=sys.stderr)
def fail(msg):
    eprint(msg)
    sys.exit(1)

VAULT = os.environ["HGLOGIN_VAULT"]
MCP_URL = os.environ["HGLOGIN_MCP_URL"]
CLIENT_ID_OVERRIDE = os.environ.get("HEYGEN_MCP_CLIENT_ID", "")
HEADLESS = os.environ.get("HGLOGIN_HEADLESS") == "1"
CHECK = os.environ.get("HGLOGIN_CHECK") == "1"
PORT_CFG = int(os.environ["HGLOGIN_PORT"])
TIMEOUT_S = int(os.environ["HGLOGIN_TIMEOUT"])
OPEN_CMD = os.environ["HGLOGIN_OPEN_CMD"]
# video.sh's hardcoded HEYGEN_MCP_TOKEN_URL default — a comparison string only, NEVER
# called from here. If discovery finds a different real token_endpoint, we warn loudly
# (DOZER-DESIGN-GSAI-237.md's flagged follow-up) rather than silently living with it.
TOKEN_URL_DEFAULT = "https://mcp.heygen.com/oauth/token"

def http_request(method, url, headers=None, data=None, timeout=30):
    """-> (status, headers_obj, body_bytes). Never raises on an HTTP error status."""
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()
    except urllib.error.URLError as e:
        fail(f"unreachable: {url} — {e}")

def as_json(body, ctx):
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except Exception:
        fail(f"{ctx}: response is not valid JSON: {body[:300]!r}")

def vault_read(path):
    d = {}
    if not os.path.isfile(path):
        return d
    for line in open(path, encoding="utf-8", errors="replace"):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        if s.startswith("export "):
            s = s[len("export "):]
        k, v = s.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        d[k.strip()] = v
    return d

def vault_write(path, access, refresh, client_id, token_url, authorize_url):
    # Same atomic idiom video.sh's hg_mcp_refresh uses (tmp + chmod 600 + rename) — a
    # different file, not reused code, but never a partial write either way.
    drop_keys = {"HEYGEN_MCP_ACCESS_TOKEN", "HEYGEN_MCP_REFRESH_TOKEN", "HEYGEN_MCP_CLIENT_ID"}
    existing = []
    if os.path.isfile(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            s = line.rstrip("\n")
            stripped = s.lstrip()
            if stripped.startswith("# HEYGEN_MCP_TOKEN_URL discovered:") or \
               stripped.startswith("# HEYGEN_MCP_AUTHORIZE_URL discovered:"):
                continue
            bare = s[len("export "):] if s.startswith("export ") else s
            key = bare.split("=", 1)[0].strip()
            if key in drop_keys:
                continue
            existing.append(s)
    lines = existing + [
        f"HEYGEN_MCP_ACCESS_TOKEN={access}",
        f"HEYGEN_MCP_REFRESH_TOKEN={refresh}",
        f"HEYGEN_MCP_CLIENT_ID={client_id}",
        f"# HEYGEN_MCP_TOKEN_URL discovered: {token_url}",
        f"# HEYGEN_MCP_AUTHORIZE_URL discovered: {authorize_url}",
    ]
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)

def mcp_verify(mcp_url, access_token):
    """One harmless tools/list call — never create_video, this script must never spend
    credits (step 8, and the whole of --check)."""
    payload = json.dumps({"jsonrpc": "2.0", "id": "verify", "method": "tools/list", "params": {}}).encode()
    status, _, body = http_request("POST", mcp_url, headers={
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }, data=payload)
    if status == 401:
        return False, "HTTP 401 — the access token was rejected"
    if not (200 <= status < 300):
        return False, f"HTTP {status}: {body[:300].decode('utf-8', 'replace')}"
    d = as_json(body, "verify")
    if d.get("error"):
        return False, f"MCP error: {json.dumps(d['error'])}"
    return True, "tools/list OK"

# ── --check: ONLY step 8, against the vault's existing token. No discovery, no DCR,
# no authorize, no token exchange — exactly one MCP call. ──────────────────────────────
if CHECK:
    vault = vault_read(VAULT)
    access = vault.get("HEYGEN_MCP_ACCESS_TOKEN", "")
    if not access:
        fail(f"--check: HEYGEN_MCP_ACCESS_TOKEN missing/empty in {VAULT} — run the login first (without --check)")
    ok, detail = mcp_verify(MCP_URL, access)
    if ok:
        print(f"heygen-mcp-login.sh: --check OK — {VAULT}'s access token is valid ({detail})")
        sys.exit(0)
    fail(f"--check FAILED — {detail}. Run the login again (without --check).")

# ── 2. Discover: an unauthenticated request to HEYGEN_MCP_URL must 401 with a
# WWW-Authenticate pointing at RFC 9728 protected-resource metadata, which names the
# authorization server, whose RFC 8414 metadata gives the real endpoints. Never guesses. ─
def discover(mcp_url):
    status, hdrs, body = http_request("POST", mcp_url, headers={
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }, data=json.dumps({"jsonrpc": "2.0", "id": "discover", "method": "tools/list", "params": {}}).encode())
    if status != 401:
        fail(f"discovery: expected HTTP 401 from {mcp_url} to begin the OAuth discovery chain, got {status}: "
             f"{body[:300].decode('utf-8', 'replace')} — HeyGen's Remote MCP may not implement RFC 9728 the way "
             "this script expects; never falling back to a hardcoded guess")
    www = hdrs.get("WWW-Authenticate", "") if hdrs else ""
    m = re.search(r'resource_metadata="([^"]+)"', www)
    if not m:
        fail(f"discovery: the 401's WWW-Authenticate header has no resource_metadata — got: {www!r}")
    rm_url = m.group(1)

    status, _, body = http_request("GET", rm_url, headers={"Accept": "application/json"})
    if not (200 <= status < 300):
        fail(f"discovery: protected-resource metadata {rm_url} returned HTTP {status}: {body[:300].decode('utf-8', 'replace')}")
    rm = as_json(body, f"protected-resource metadata {rm_url}")
    as_list = rm.get("authorization_servers") or []
    if not as_list:
        fail(f"discovery: {rm_url} has no authorization_servers — got: {json.dumps(rm)[:300]}")
    issuer = as_list[0]

    as_meta_url = issuer.rstrip("/") + "/.well-known/oauth-authorization-server"
    status, _, body = http_request("GET", as_meta_url, headers={"Accept": "application/json"})
    if not (200 <= status < 300):
        fail(f"discovery: authorization-server metadata {as_meta_url} returned HTTP {status}: {body[:300].decode('utf-8', 'replace')}")
    as_meta = as_json(body, f"authorization-server metadata {as_meta_url}")
    if not as_meta.get("authorization_endpoint") or not as_meta.get("token_endpoint"):
        fail(f"discovery: {as_meta_url} is missing authorization_endpoint/token_endpoint — got: {json.dumps(as_meta)[:300]}")
    return as_meta

AS_META = discover(MCP_URL)
AUTH_ENDPOINT = AS_META["authorization_endpoint"]
TOKEN_ENDPOINT = AS_META["token_endpoint"]
REG_ENDPOINT = AS_META.get("registration_endpoint", "")
SCOPE = " ".join(AS_META.get("scopes_supported") or [])

if TOKEN_ENDPOINT != TOKEN_URL_DEFAULT:
    eprint(f"WARNING: the discovered token_endpoint ({TOKEN_ENDPOINT}) differs from video.sh's "
           f"hardcoded HEYGEN_MCP_TOKEN_URL default ({TOKEN_URL_DEFAULT}). Export "
           f"HEYGEN_MCP_TOKEN_URL=\"{TOKEN_ENDPOINT}\" for the Dozer crew (or patch video.sh's "
           "default) — see DOZER-DESIGN-GSAI-237.md's flagged follow-up.")

# ── 3/4. Bind the loopback listener (interactive) or fix a redirect_uri (headless)
# BEFORE registering, since the redirect_uri a client registers/uses must match exactly. ─
captured = {}
srv = None

class CallbackHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if not self.path.startswith("/callback"):
            self.send_response(404); self.end_headers(); return
        qs = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(qs)
        captured["code"] = (params.get("code") or [""])[0]
        captured["state"] = (params.get("state") or [""])[0]
        captured["error"] = (params.get("error") or [""])[0]
        body = b"<html><body>heygen-mcp-login: you can close this tab.</body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if HEADLESS:
    redirect_uri = f"http://127.0.0.1:{PORT_CFG}/callback"
else:
    try:
        srv = http.server.HTTPServer(("127.0.0.1", PORT_CFG), CallbackHandler)
    except OSError:
        srv = http.server.HTTPServer(("127.0.0.1", 0), CallbackHandler)   # port busy: OS-assigned fallback
    redirect_uri = f"http://127.0.0.1:{srv.server_address[1]}/callback"

vault = vault_read(VAULT)
client_id = CLIENT_ID_OVERRIDE or vault.get("HEYGEN_MCP_CLIENT_ID", "")
if not client_id:
    if not REG_ENDPOINT:
        fail("no registration_endpoint in the authorization-server metadata and no HEYGEN_MCP_CLIENT_ID "
             "supplied — obtain a client id out-of-band and re-run with "
             "HEYGEN_MCP_CLIENT_ID=... scripts/heygen-mcp-login.sh")
    dcr_body = json.dumps({
        "redirect_uris": [redirect_uri],
        "token_endpoint_auth_method": "none",   # a CLI script is a public client
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "client_name": "dozers-heygen-mcp-login",
    }).encode()
    status, _, body = http_request("POST", REG_ENDPOINT, headers={"Content-Type": "application/json"}, data=dcr_body)
    if not (200 <= status < 300):
        fail(f"dynamic client registration ({REG_ENDPOINT}) returned HTTP {status}: {body[:300].decode('utf-8', 'replace')}")
    reg = as_json(body, f"DCR response {REG_ENDPOINT}")
    client_id = reg.get("client_id", "")
    if not client_id:
        fail(f"dynamic client registration ({REG_ENDPOINT}) returned no client_id: {json.dumps(reg)[:300]}")
else:
    eprint(f"reusing existing client id (not re-registering): {client_id}")

# ── PKCE (S256) + state ────────────────────────────────────────────────────────────
verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
state = secrets.token_urlsafe(24)

authorize_params = {
    "response_type": "code", "client_id": client_id, "redirect_uri": redirect_uri,
    "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
}
if SCOPE:
    authorize_params["scope"] = SCOPE
authorize_url = AUTH_ENDPOINT + "?" + urllib.parse.urlencode(authorize_params)

print(f"heygen-mcp-login.sh: open this URL to authorize (it will also try to open automatically):\n  {authorize_url}")
if not HEADLESS:
    try:
        subprocess.run([OPEN_CMD, authorize_url], check=False,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass   # best-effort; the URL is already printed

# ── 5. Capture the redirect ─────────────────────────────────────────────────────────
if HEADLESS:
    pasted = input("Paste the full redirect URL (or just the code) after authorizing: ").strip()
    if "://" in pasted:
        qs = urllib.parse.urlparse(pasted).query
        params = urllib.parse.parse_qs(qs)
        code = (params.get("code") or [""])[0]
        got_state = (params.get("state") or [""])[0]
        if not code:
            fail(f"--headless: the pasted redirect URL has no 'code' parameter: {pasted!r}")
        if got_state != state:
            fail("--headless: state mismatch on the pasted redirect — possible CSRF/replay; nothing written")
    elif pasted and "=" not in pasted and " " not in pasted:
        code = pasted   # a bare code, no state to check in this form
    else:
        fail(f"--headless: could not parse the pasted value as a redirect URL or a bare code: {pasted!r}")
else:
    srv.timeout = 1
    deadline = time.time() + TIMEOUT_S
    while time.time() < deadline and "code" not in captured:
        srv.handle_request()
    srv.server_close()
    if "code" not in captured:
        fail(f"timed out after {TIMEOUT_S}s waiting for the OAuth callback — nothing written")
    if captured.get("error"):
        fail(f"authorization server returned an error on the callback: {captured['error']}")
    if captured.get("state") != state:
        fail("state mismatch on the OAuth callback — possible CSRF/replay; nothing written")
    code = captured["code"]
    if not code:
        fail("the OAuth callback carried no 'code' parameter")

# ── 6. Exchange ──────────────────────────────────────────────────────────────────────
exchange_body = urllib.parse.urlencode({
    "grant_type": "authorization_code", "code": code, "redirect_uri": redirect_uri,
    "code_verifier": verifier, "client_id": client_id,
}).encode()
status, _, body = http_request("POST", TOKEN_ENDPOINT,
                                headers={"Content-Type": "application/x-www-form-urlencoded"},
                                data=exchange_body)
if not (200 <= status < 300):
    fail(f"token exchange ({TOKEN_ENDPOINT}) returned HTTP {status}: {body[:300].decode('utf-8', 'replace')}")
tok = as_json(body, f"token exchange {TOKEN_ENDPOINT}")
access_token = tok.get("access_token", "")
refresh_token = tok.get("refresh_token", "")
if not access_token:
    fail("token exchange succeeded but the response has no access_token: "
         f"{json.dumps({k: v for k, v in tok.items() if k not in ('access_token', 'refresh_token')})}")
if not refresh_token:
    fail("token exchange succeeded but the response has no refresh_token — a long-lived crew with only "
         "an access token is a silent future outage; failing the login rather than shipping a half-working one")

# ── 7. Write the vault (atomic; never prints a token value) ──────────────────────────
vault_write(VAULT, access_token, refresh_token, client_id, TOKEN_ENDPOINT, AUTH_ENDPOINT)
print(f"heygen-mcp-login.sh: wrote {VAULT} (access + refresh token, client id) — values never printed")

# ── 8. Verify: a harmless tools/list call with the fresh token, never create_video ───
ok, detail = mcp_verify(MCP_URL, access_token)
if ok:
    print(f"heygen-mcp-login.sh: verified — {detail}. Login complete.")
    sys.exit(0)
fail(f"tokens were issued and written to {VAULT}, but the post-login verify call failed: {detail}. "
     "video.sh will fail on first use until this is resolved.")
PY

HGLOGIN_VAULT="$HEYGEN_MCP_VAULT" \
HGLOGIN_MCP_URL="$HEYGEN_MCP_URL" \
HGLOGIN_HEADLESS="$HEADLESS" \
HGLOGIN_CHECK="$CHECK" \
HGLOGIN_PORT="$PORT" \
HGLOGIN_TIMEOUT="${HEYGEN_MCP_LOGIN_TIMEOUT:-300}" \
HGLOGIN_OPEN_CMD="${HEYGEN_MCP_LOGIN_OPEN_CMD:-open}" \
python3 -u "$HG_TMP_PY"
exit $?
