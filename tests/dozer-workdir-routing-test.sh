#!/usr/bin/env bash
# tests/dozer-workdir-routing-test.sh — regression test for GSAI-131.
#
# resolve_workdir() used to swallow the resolver's stderr and fall through three
# silent fallbacks onto $ROOT — the repo that holds the engine itself. Caught live on
# BRD-85 (2026-09-15): the same `repo:mr-growth-guide` task ran once in the brand repo
# and once in ~/Code/dozers, where a crew spent ~2 min writing the brand's test suite
# into the engine and cut dozer/BRD-85 off the ENGINE's develop. The invariant this
# test pins down:
#
#   A task that carries an IDENTITY — a repo: label or a team — is routed by the
#   registry or not at all. It never falls back, and so can never reach the engine's
#   own checkout. When routing fails nothing runs: no crew, no worktree, no branch, and
#   the task lands on blocked carrying the resolver's real error.
#
#   HAPPY    — repo:<id> that resolves lands the crew in exactly that checkout
#   MISS     — repo:<id> that does not resolve BLOCKS: no crew ran, and the block
#              comment names the id and the resolver's rc
#   DEMOTE   — repo:<id> miss + a team that WOULD resolve still blocks; an explicit
#              repo hint is never quietly demoted into the team's default repo
#   BROKEN   — an unparseable ecosystem.yaml (the live BRD-85 failure mode) blocks and
#              the resolver's stderr reaches the task comment, instead of being
#              discarded and the task routed into the engine
#   TEAM     — a team with no repo hint still resolves through the registry, unchanged
#   TEAMMISS — a team that resolves to nothing blocks; it does NOT fall through to
#              workdir_default and into the engine
#   TYPO     — a foreign repo:<id> whose registry entry mistakenly points AT the engine
#              checkout is refused; only the engine's own name may work on the engine
#   DEMO     — the one legitimate route to the engine repo survives: a task naming
#              neither a repo nor a team runs under workdir_default (files-backend mode)
#   NEVERROOT— no crew that named a repo or a team ever ran with cwd == the engine root
#
# It drives the REAL engine (dozers/dozer.sh) on the files backend from a throwaway
# copy of the repo carrying one extra lane, `probe`, whose crew only records the
# WORKDIR it was handed. No model, no network, no worktrees.
#
# Run:  bash tests/dozer-workdir-routing-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
FAKE="$TMP/root"

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# ── a throwaway engine: the real scripts + a `probe` lane, its own board and locks ──
mkdir -p "$FAKE/dozers/probe-lane" "$FAKE/tasks" "$FAKE/org"
cp -R "$ROOT/dozers/." "$FAKE/dozers/"
for f in "$ROOT"/tasks/*; do [[ -f "$f" ]] && cp "$f" "$FAKE/tasks/"; done
cp "$ROOT/org/config.yaml" "$FAKE/org/config.yaml"

# the probe lane: record the workdir it was handed, then succeed. Never writes to it.
CWDLOG="$TMP/cwd.log"
cat > "$FAKE/dozers/probe-lane/crew.sh" <<EOS
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$WORKDIR" >> "$CWDLOG"
mkdir -p "\$REPO_ROOT/.artifacts/probe"
printf -- '- probed\n' > "\$REPO_ROOT/.artifacts/probe/\$1.summary"
EOS
chmod +x "$FAKE/dozers/probe-lane/crew.sh"
: > "$CWDLOG"

BOARD="$FAKE/tasks/board"
mkdir -p "$TMP/proj/app" "$TMP/proj/other"
cat > "$TMP/ecosystem.yaml" <<YAML
orgs:
  acme:
    linear_team: ACME
projects:
  - id: app
    org: acme
    local: $TMP/proj/app/
  - id: other
    org: acme
    local: $TMP/proj/other/
YAML
# the BRD-85 failure mode: a registry that momentarily does not parse
cat > "$TMP/broken.yaml" <<'YAML'
projects:
  - id: app
     local: /tmp/nope
  : : :
YAML

seed() { # <id> [repo] [team]
  mkdir -p "$BOARD/ready"
  { printf 'title: probe %s\nlane: probe\n' "$1"
    [[ -n "${2:-}" ]] && printf 'repo: %s\n' "$2"
    [[ -n "${3:-}" ]] && printf 'team: %s\n' "$3"; } > "$BOARD/ready/$1.md"
}

drain() { # run one drain pass over everything currently in ready/
  ECOSYSTEM_REGISTRY="${REGISTRY:-$TMP/ecosystem.yaml}" \
  BACKEND=files FANOUT=4 LOCK_DIR="$TMP/locks" HEARTBEAT_FILE="$TMP/hb" \
  WORKDIR_DEFAULT="${WD_DEFAULT-}" \
    bash "$FAKE/dozers/dozer.sh" once >>"$TMP/engine.log" 2>&1
}

cwd_of()  { grep -E "^$1"$'\t' "$CWDLOG" 2>/dev/null | head -1 | cut -f2; }
ran()     { grep -qE "^$1"$'\t' "$CWDLOG" 2>/dev/null; }
card()    { ls "$BOARD"/*/"$1".md 2>/dev/null | head -1; }
state()   { local f; f="$(card "$1")"; [[ -n "$f" ]] && basename "$(dirname "$f")" || echo MISSING; }
comment() { local f; f="$(card "$1")"; [[ -n "$f" ]] && cat "$f" || true; }

# ── HAPPY / MISS / DEMOTE — one drain, the registry intact ────────────────────
seed HAPPY  app
seed MISS   no-such-repo-id
seed DEMOTE no-such-repo-id ACME
seed TEAM   "" ACME
drain

[[ "$(state HAPPY)" == done && "$(cwd_of HAPPY)" == "$TMP/proj/app" ]] \
  && ok "HAPPY repo:app -> $(cwd_of HAPPY)" \
  || no "HAPPY expected done in $TMP/proj/app, got state=$(state HAPPY) cwd=$(cwd_of HAPPY)"

if [[ "$(state MISS)" == blocked ]] && ! ran MISS; then
  c="$(comment MISS)"
  [[ "$c" == *"no-such-repo-id"* && "$c" == *"rc="* && "$c" == *"no worktree was created"* ]] \
    && ok "MISS unresolvable repo: blocked with the resolver's error, no crew ran" \
    || no "MISS blocked but the comment lost the reason: $(printf '%s' "$c" | tr '\n' ' ')"
else
  no "MISS expected blocked with no crew run, got state=$(state MISS) cwd=$(cwd_of MISS)"
fi

if [[ "$(state DEMOTE)" == blocked ]] && ! ran DEMOTE; then
  ok "DEMOTE explicit repo: miss is never demoted to the team's default repo"
else
  no "DEMOTE expected blocked, got state=$(state DEMOTE) cwd=$(cwd_of DEMOTE) (team default is $TMP/proj/app)"
fi

[[ "$(state TEAM)" == done && "$(cwd_of TEAM)" == "$TMP/proj/app" ]] \
  && ok "TEAM no hint -> the org's default repo, unchanged" \
  || no "TEAM expected done in $TMP/proj/app, got state=$(state TEAM) cwd=$(cwd_of TEAM)"

# ── BROKEN — the registry does not parse (the live BRD-85 failure mode) ───────
seed BROKEN app
REGISTRY="$TMP/broken.yaml" drain
if [[ "$(state BROKEN)" == blocked ]] && ! ran BROKEN; then
  c="$(comment BROKEN)"
  [[ "$c" == *"Resolver said:"* ]] \
    && ok "BROKEN unparseable registry blocks and the resolver's stderr reaches the task" \
    || no "BROKEN blocked but the resolver's stderr was discarded: $(printf '%s' "$c" | tr '\n' ' ')"
else
  no "BROKEN expected blocked with no crew run, got state=$(state BROKEN) cwd=$(cwd_of BROKEN)"
fi

# ── TEAMMISS — a team that resolves to nothing must not slide into the default ──
seed TEAMMISS "" NOSUCHTEAM
drain
if [[ "$(state TEAMMISS)" == blocked ]] && ! ran TEAMMISS; then
  ok "TEAMMISS an unresolvable team blocks instead of falling through to the engine"
else
  no "TEAMMISS expected blocked, got state=$(state TEAMMISS) cwd=$(cwd_of TEAMMISS)"
fi

# ── TYPO — a registry entry for ANOTHER repo mistakenly pointing at the engine ──
# The BRD-85 contamination arriving through the "correct" path: the resolver returns
# rc=0 and a real directory, and that directory is the engine itself.
cat > "$TMP/typo.yaml" <<YAML
projects:
  - id: someone-elses-repo
    org: acme
    local: $FAKE
YAML
seed TYPO someone-elses-repo
REGISTRY="$TMP/typo.yaml" drain
if [[ "$(state TYPO)" == blocked ]] && ! ran TYPO; then
  ok "TYPO a foreign repo id resolving onto the engine checkout is refused"
else
  no "TYPO expected blocked, got state=$(state TYPO) cwd=$(cwd_of TYPO)"
fi

# ── DEMO — the ONE legitimate route to the engine repo, still intact ──────────
# A task naming neither a repo nor a team (files-backend / zero-config mode) works on
# the repo the Dozer ships in. Nothing about it points elsewhere, so workdir_default —
# "." in the shipped config — is a configured answer rather than a guess. Pinned here
# so the fail-fast rules above are never "fixed" by breaking self-hosted mode.
seed DEMO
drain
[[ "$(state DEMO)" == done && "$(cd "$(cwd_of DEMO)" 2>/dev/null && pwd -P)" == "$(cd "$FAKE" && pwd -P)" ]] \
  && ok "DEMO no repo and no team -> workdir_default (the engine's own checkout)" \
  || no "DEMO expected done in $FAKE, got state=$(state DEMO) cwd=$(cwd_of DEMO)"

# ── NEVERROOT — the whole point: no IDENTIFIED task ever saw the engine repo ──
engine_real="$(cd "$FAKE" && pwd -P)"
leaked=""
while IFS=$'\t' read -r id wd; do
  [[ -n "$wd" || "$id" == DEMO ]] || continue
  [[ "$id" == DEMO ]] && continue   # the one sanctioned case, asserted above
  [[ "$(cd "$wd" 2>/dev/null && pwd -P)" == "$engine_real" ]] && leaked="$leaked $id"
done < "$CWDLOG"
[[ -z "$leaked" ]] && ok "NEVERROOT no task naming a repo or a team ran in the engine repo" \
                   || no "NEVERROOT crews routed into the engine repo:$leaked"

echo
(( fail == 0 )) && { echo "dozer-workdir-routing-test: PASS"; exit 0; }
echo "dozer-workdir-routing-test: FAIL" >&2
echo "--- engine log ---" >&2; tail -40 "$TMP/engine.log" >&2
exit 1
