#!/usr/bin/env bash
# tests/dev-lane-deps-drift-test.sh — regression test for GSAI-254 (and GSAI-261's
# switch from a symlinked node_modules to a cloned one — see the probe below).
#
# link_deps clones the host checkout's node_modules into every task and merge
# worktree (GSAI-261: a symlink resolves back to the host's real path, which
# Turbopack and friends reject as outside the worktree's project root), and
# install_deps used to return early on ANY node_modules entry. So the host's
# node_modules — which belongs to whatever branch the host sits on — suppressed
# the install for good. A dependency added on the integration branch could never be
# installed into a worktree: `Cannot find module 'heic-convert'` on every dev task.
#
# The install decision now follows drift between the worktree's install inputs
# (package.json + lockfiles) and $WORKDIR's. An unchanged clone is still the fast
# path (drift is checked BEFORE cloning too, so already-stale inputs skip the clone
# rather than cloning stale bytes just to invalidate them), and a real worktree dir
# (cloned or installed) is re-installed only when its stamp says its inputs changed.
#
# Hermetic: a fake `npm` on PATH stands in for the real one. `npm ci` provisions
# node_modules and writes node_modules/heic-convert.marker only when the lockfile names
# heic-convert; `npm test` fails like a missing module when the marker is absent. The
# fake records every ci/install call with its cwd in $NPM_LOG, so the tests can prove
# WHERE an install ran (and that it never wrote through a link into the host).
#
# Run:  bash tests/dev-lane-deps-drift-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# ── fake npm: records ci/install (cwd only — never the arguments), models the marker ──
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  ci|install)
    echo "ci $(pwd -P)" >> "$NPM_LOG"
    mkdir -p node_modules && : > node_modules/.installed
    grep -q heic-convert package-lock.json 2>/dev/null && : > node_modules/heic-convert.marker
    echo "added 1 package"; exit 0 ;;
  test)
    [[ -f node_modules/heic-convert.marker ]] || { echo "Cannot find module 'heic-convert'" >&2; exit 1; }
    echo "1 passed"; exit 0 ;;
esac
exit 0
EOS
chmod +x "$TMP/bin/npm"

# ── fixtures ──────────────────────────────────────────────────────────────────
init_repo() {  # $1 = dir → a repo on main: feature.txt and a gitignored node_modules
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email test@dozer && git -C "$1" config user.name dozer-test
  printf 'node_modules\n' > "$1/.gitignore"   # no trailing slash: also ignores dep symlinks
  printf 'seed\n' > "$1/feature.txt"
  git -C "$1" add -A && git -C "$1" commit -q -m init
}
commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }
write_deps() {  # $1 = dir, $2 = heic|bare → package.json + package-lock.json
  local pkgs='{}'
  [[ "$2" == heic ]] && pkgs='{"node_modules/heic-convert":{"version":"2.0.0"}}'
  printf '{"name":"proj","version":"1.0.0","scripts":{"test":"vitest run"}}\n' > "$1/package.json"
  printf '{"name":"proj","version":"1.0.0","lockfileVersion":3,"packages":%s}\n' "$pkgs" > "$1/package-lock.json"
}

# ── stub coding agents (run inside the task worktree) ─────────────────────────
# Each records what the worktree looked like BEFORE it changed anything: the worktree is
# reaped on exit, so the probe is the only evidence of its state at agent time.
STUB_TOUCH="$TMP/stub-touch.sh"
cat > "$STUB_TOUCH" <<'EOS'
#!/usr/bin/env bash
{
  [[ -L node_modules ]] && echo "wt-nm-link -> $(readlink node_modules)"
  [[ -d node_modules && ! -L node_modules ]] && echo "wt-nm-dir"
  [[ ! -e node_modules ]] && echo "wt-nm-absent"
  [[ -f node_modules/.dozer-deps-stamp ]] && echo "wt-nm-stamp $(cat node_modules/.dozer-deps-stamp)"
} > "$PROBE"
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent: touch feature"
EOS
chmod +x "$STUB_TOUCH"

# changes the lockfile during the BUILD pass (adds heic-convert on a branch that started bare)
STUB_DEP="$TMP/stub-dep.sh"
cat > "$STUB_DEP" <<'EOS'
#!/usr/bin/env bash
printf '{"name":"proj","version":"1.0.0","scripts":{"test":"vitest run"}}\n' > package.json
printf '{"name":"proj","version":"1.0.0","lockfileVersion":3,"packages":{"node_modules/heic-convert":{"version":"2.0.0"}}}\n' > package-lock.json
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent: add heic-convert"
EOS
chmod +x "$STUB_DEP"

EXTRA_ENV=()
run_crew() {  # $1 = project dir, $2 = id, $3 = crew log, $4 = npm call log; $STUB; EXTRA_ENV[@]
  env PATH="$TMP/bin:$PATH" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    NPM_LOG="$4" PROBE="$TMP/probe-$2" \
    REPO_ROOT="$TMP" WORKDIR="$1" \
    WORKTREE_ROOT="$TMP/wt-$2" INTEGRATION_BRANCH="develop" \
    MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" \
    TEST_GATE="bootstrap" \
    bash "$CREW" "$2" "add heic-convert" >"$3" 2>&1
}
tree_sum() { (cd "$1" && find "$2" -print | sort | cksum); }   # a dir's shape, byte-stable
merged_as() { [[ "$(git -C "$1" log -1 --format=%s develop 2>/dev/null)" == merge*"$2"* ]]; }

# ── 1. the bug: a dep only the integration branch has must reach the gate ─────
P1="$TMP/s1"; init_repo "$P1"
git -C "$P1" checkout -q -b develop; write_deps "$P1" heic; commit_all "$P1" "develop: add heic-convert"
git -C "$P1" checkout -q -b featA main            # host sits on a branch with no deps at all
mkdir -p "$P1/node_modules" && : > "$P1/node_modules/.installed"
HOST1_BEFORE="$(tree_sum "$P1" node_modules)"
STUB="$STUB_TOUCH"; NPM1="$TMP/npm1.log"; : > "$NPM1"; EXTRA_ENV=(); rc=0
run_crew "$P1" TEST-GDD1 "$TMP/crew1.log" "$NPM1" || rc=$?

[[ $rc -eq 0 ]] && ok "crew exited clean — the develop-only dep was installed for the gate" \
  || { no "crew exited $rc — the gate ran without heic-convert"; sed 's/^/    | /' "$TMP/crew1.log" >&2; }
merged_as "$P1" TEST-GDD1 && ok "merge commit landed on develop" \
  || no "develop HEAD is not the expected merge: '$(git -C "$P1" log -1 --format=%s develop)'"
grep -q 'TEST-GDD1' "$NPM1" && grep -q -- '-TEST-GDD1' "$NPM1" && ok "npm ci ran in the task worktree" \
  || no "no npm ci in the task worktree (npm log: $(cat "$NPM1"))"
grep -q -- '-merge' "$NPM1" && ok "npm ci ran in the merge worktree too (post-merge tree)" \
  || no "no npm ci in the merge worktree"
grep -q 'node_modules missing' "$TMP/crew1.log" && ok "the already-drifted clone was skipped and reported as missing" \
  || no "no 'node_modules missing' line in the log"

# ── 3. isolation: the host's node_modules is never written through a link ─────
[[ "$(tree_sum "$P1" node_modules)" == "$HOST1_BEFORE" ]] && ok "host node_modules tree is byte-identical after the run" \
  || no "host node_modules changed — an install wrote through the link"
[[ ! -e "$P1/node_modules/heic-convert.marker" ]] && ok "no marker leaked into the host checkout" \
  || no "heic-convert marker appeared in the host checkout"
grep -q 'wt-nm-dir' "$TMP/probe-TEST-GDD1" && ok "the worktree's node_modules was its own real dir at agent time" \
  || no "worktree node_modules at agent time: $(cat "$TMP/probe-TEST-GDD1" 2>/dev/null)"

# ── 2. unchanged lockfile keeps the fast path ─────────────────────────────────
P2="$TMP/s2"; init_repo "$P2"
write_deps "$P2" heic; commit_all "$P2" "main: heic-convert"
git -C "$P2" branch develop
mkdir -p "$P2/node_modules" && : > "$P2/node_modules/.installed" && : > "$P2/node_modules/heic-convert.marker"
STUB="$STUB_TOUCH"; NPM2="$TMP/npm2.log"; : > "$NPM2"; EXTRA_ENV=(); rc=0
run_crew "$P2" TEST-GDD2 "$TMP/crew2.log" "$NPM2" || rc=$?

[[ $rc -eq 0 ]] && ok "crew exited clean on the shared lockfile" \
  || { no "crew exited $rc"; sed 's/^/    | /' "$TMP/crew2.log" >&2; }
grep -qx 'wt-nm-dir' "$TMP/probe-TEST-GDD2" && ok "node_modules is a real dir (cloned from the host) at agent time" \
  || no "fast path broke: $(cat "$TMP/probe-TEST-GDD2" 2>/dev/null)"
grep -q '^wt-nm-stamp' "$TMP/probe-TEST-GDD2" && ok "the clone carries a deps stamp" \
  || no "no .dozer-deps-stamp on the clone: $(cat "$TMP/probe-TEST-GDD2" 2>/dev/null)"
[[ ! -s "$NPM2" ]] && ok "no npm ci/install ran" || no "npm ran on the fast path: $(cat "$NPM2")"
grep -qE 'node_modules (missing|differs|is a dangling|changed)|unlinked nested|removed nested' "$TMP/crew2.log" \
  && no "fast path logged a deps decision" || ok "fast path logged nothing new"

# ── 4. post-build drift: the BUILD pass changes the lockfile ──────────────────
P4="$TMP/s4"; init_repo "$P4"
write_deps "$P4" bare; commit_all "$P4" "main: bare deps"
git -C "$P4" branch develop
mkdir -p "$P4/node_modules" && : > "$P4/node_modules/.installed" && : > "$P4/node_modules/heic-convert.marker"
STUB="$STUB_DEP"; NPM4="$TMP/npm4.log"; : > "$NPM4"; EXTRA_ENV=(); rc=0
run_crew "$P4" TEST-GDD4 "$TMP/crew4.log" "$NPM4" || rc=$?

[[ $rc -eq 0 ]] && ok "post-build lockfile change reached the gate with its own deps" \
  || { no "crew exited $rc after the build changed the lockfile"; sed 's/^/    | /' "$TMP/crew4.log" >&2; }
merged_as "$P4" TEST-GDD4 && ok "merge commit landed on develop" \
  || no "develop HEAD is not the expected merge"
grep -q 'task worktree: node_modules changed since its last install' "$TMP/crew4.log" && ok "post-build call saw the drift and reinstalled" \
  || no "post-build call did not detect the lockfile drift"
grep -q -- '-TEST-GDD4$' "$NPM4" && ok "npm ci ran in the task worktree after the build" \
  || no "no post-build npm ci in the task worktree (npm log: $(cat "$NPM4"))"

# ── 5. nested package clone: removed before the install, never written through ──
P5="$TMP/s5"; init_repo "$P5"
mkdir -p "$P5/packages/web" && printf '{"name":"web","version":"1.0.0"}\n' > "$P5/packages/web/package.json"
commit_all "$P5" "main: workspace package"
git -C "$P5" checkout -q -b develop; write_deps "$P5" heic; commit_all "$P5" "develop: root heic-convert"
git -C "$P5" checkout -q main
mkdir -p "$P5/node_modules" && : > "$P5/node_modules/.installed"
mkdir -p "$P5/packages/web/node_modules" && : > "$P5/packages/web/node_modules/.installed"
HOST5_BEFORE="$(tree_sum "$P5" packages/web/node_modules)"
STUB="$STUB_TOUCH"; NPM5="$TMP/npm5.log"; : > "$NPM5"; EXTRA_ENV=(); rc=0
run_crew "$P5" TEST-GDD5 "$TMP/crew5.log" "$NPM5" || rc=$?

[[ $rc -eq 0 ]] && ok "monorepo task cleared the gate with its root deps" \
  || { no "crew exited $rc"; sed 's/^/    | /' "$TMP/crew5.log" >&2; }
grep -q 'removed nested packages/web/node_modules clone' "$TMP/crew5.log" \
  && ok "nested package clone removed before the install" \
  || no "nested clone was not removed before the install"
[[ "$(tree_sum "$P5" packages/web/node_modules)" == "$HOST5_BEFORE" ]] \
  && ok "host packages/web/node_modules is unchanged" \
  || no "host packages/web/node_modules changed — the install wrote through the clone"
grep -q -- '-TEST-GDD5$' "$NPM5" && ok "root npm ci ran in the task worktree" \
  || no "no root npm ci in the task worktree (npm log: $(cat "$NPM5"))"

# ── 6. DEPS_INSTALL=off: an already-drifted source is left unlinked, nothing runs ─
# (host sits on featA, which has no package.json at all — drifted vs. the task
# worktree's develop-based package.json before the clone ever runs, so the clone is
# skipped the same way a drifted link used to be removed; DEPS_INSTALL=off then
# skips the install too, leaving node_modules absent rather than a stale copy.)
P6="$TMP/s6"; init_repo "$P6"
git -C "$P6" checkout -q -b develop; write_deps "$P6" heic; commit_all "$P6" "develop: add heic-convert"
git -C "$P6" checkout -q -b featA main
mkdir -p "$P6/node_modules" && : > "$P6/node_modules/.installed"
STUB="$STUB_TOUCH"; NPM6="$TMP/npm6.log"; : > "$NPM6"; EXTRA_ENV=(DEPS_INSTALL=off)
run_crew "$P6" TEST-GDD6 "$TMP/crew6.log" "$NPM6" || true   # the gate fails: no heic-convert, as expected

grep -qx 'wt-nm-absent' "$TMP/probe-TEST-GDD6" && ok "already-drifted source left node_modules absent at agent time" \
  || no "DEPS_INSTALL=off produced unexpected node_modules state: $(cat "$TMP/probe-TEST-GDD6" 2>/dev/null)"
[[ ! -s "$NPM6" ]] && ok "no npm ci/install ran under DEPS_INSTALL=off" \
  || no "npm ran under DEPS_INSTALL=off: $(cat "$NPM6")"
grep -q 'task worktree: deps install off' "$TMP/crew6.log" && ok "logged 'deps install off'" \
  || no "no 'deps install off' line in the log"

if [[ $fail == 0 ]]; then echo "dev-lane-deps-drift-test: PASS"; else echo "dev-lane-deps-drift-test: FAIL" >&2; exit 1; fi
