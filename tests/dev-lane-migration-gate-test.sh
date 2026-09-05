#!/usr/bin/env bash
# tests/dev-lane-migration-gate-test.sh — regression test for GSAI-24 (LL-31 guardrail).
#
# The dev-lane migration gate runs BEFORE the merge: if a branch touches a DB
# schema file (Prisma by default) but ships no matching migration, the merge is
# blocked and the task sent back — a schema drift with no migration breaks
# deploys (the LL-31 incident). This drives the real crew end-to-end against a
# throwaway repo (no test runner, so the gate is the only thing under test) and
# checks three scenarios:
#   BLOCK   — schema edited, no migration            → crew fails, develop unchanged
#   ALLOW   — schema edited + migration added         → crew succeeds, develop advances
#   OVERRIDE— schema edited, no migration, [skip-migration] in commit → succeeds
#   NO-OP   — only a normal file edited               → crew succeeds (no false positive)
#
# Run:  bash tests/dev-lane-migration-gate-test.sh   (exits non-zero on any failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }

# ── build a fresh throwaway Prisma-shaped repo with a develop branch ──────────
mkproj() {  # $1 = dest dir
  local p="$1"; mkdir -p "$p/prisma"; cd "$p"
  git init -q -b main .
  git config user.email test@dozer && git config user.name dozer-test
  printf 'generator client { provider = "prisma-client-js" }\nmodel User { id Int @id }\n' > prisma/schema.prisma
  printf 'seed\n' > app.txt
  git add -A && git commit -q -m "init"
  git branch develop                     # integration branch, not checked out
}

# ── run the real crew with a given stub coding agent; echoes the exit code ─────
run_crew() {  # $1 = proj dir, $2 = task id, $3 = stub script path
  local proj="$1" id="$2" stub="$3" rc=0
  REPO_ROOT="$TMP" WORKDIR="$proj" \
    WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
    MODEL_CMD="bash $stub" PUSH="false" DOZER_PERSONA="test" \
    bash "$CREW" "$id" "migration gate $id" >"$TMP/$id.log" 2>&1 || rc=$?
  echo "$rc"
}

mkstub() {  # $1 = path, $2 = body
  printf '#!/usr/bin/env bash\nset -e\n%s\n' "$2" > "$1"; chmod +x "$1"
}

# ── 1. BLOCK: schema edited, no migration → crew must fail, develop unchanged ──
P1="$TMP/block"; mkproj "$P1"
DEV_BEFORE="$(git -C "$P1" rev-parse develop)"
mkstub "$TMP/s1.sh" 'printf "model Post { id Int @id }\n" >> prisma/schema.prisma
git add -A && git commit -q -m "add Post model (forgot migration)"'
rc="$(run_crew "$P1" "GATE-BLOCK" "$TMP/s1.sh")"
[[ "$rc" -ne 0 ]] && ok "BLOCK: crew failed on schema change with no migration" \
  || { no "BLOCK: crew exited 0 — gate did NOT block"; sed 's/^/    | /' "$TMP/GATE-BLOCK.log" >&2; }
grep -qF "no matching migration" "$TMP/GATE-BLOCK.log" \
  && ok "BLOCK: failure names the LL-31 guardrail" || no "BLOCK: missing guardrail message"
[[ "$(git -C "$P1" rev-parse develop)" == "$DEV_BEFORE" ]] \
  && ok "BLOCK: develop was not advanced" || no "BLOCK: develop moved despite the block"

# ── 2. ALLOW: schema edited + migration added → crew must succeed, develop moves ─
P2="$TMP/allow"; mkproj "$P2"
mkstub "$TMP/s2.sh" 'printf "model Post { id Int @id }\n" >> prisma/schema.prisma
mkdir -p prisma/migrations/20240101000000_add_post
printf "CREATE TABLE \"Post\" (id INT);\n" > prisma/migrations/20240101000000_add_post/migration.sql
git add -A && git commit -q -m "add Post model + migration"'
rc="$(run_crew "$P2" "GATE-ALLOW" "$TMP/s2.sh")"
[[ "$rc" -eq 0 ]] && ok "ALLOW: crew succeeded when a migration ships with the schema" \
  || { no "ALLOW: crew exited $rc — gate blocked a valid change"; sed 's/^/    | /' "$TMP/GATE-ALLOW.log" >&2; }
[[ "$(git -C "$P2" log -1 --format=%s develop)" == merge*GATE-ALLOW* ]] \
  && ok "ALLOW: merge commit landed on develop" \
  || no "ALLOW: develop HEAD not the expected merge: '$(git -C "$P2" log -1 --format=%s develop)'"

# ── 3. OVERRIDE: schema edited, no migration, [skip-migration] → succeed ───────
P3="$TMP/override"; mkproj "$P3"
mkstub "$TMP/s3.sh" 'sed -i.bak "s/prisma-client-js/prisma-client-js2/" prisma/schema.prisma && rm -f prisma/schema.prisma.bak
git add -A && git commit -q -m "tweak generator [skip-migration]"'
rc="$(run_crew "$P3" "GATE-SKIP" "$TMP/s3.sh")"
[[ "$rc" -eq 0 ]] && ok "OVERRIDE: [skip-migration] lets a schema-only edit through" \
  || { no "OVERRIDE: crew exited $rc — escape hatch ignored"; sed 's/^/    | /' "$TMP/GATE-SKIP.log" >&2; }

# ── 4. NO-OP: only a normal file edited → no false positive ────────────────────
P4="$TMP/noop"; mkproj "$P4"
mkstub "$TMP/s4.sh" 'printf "change\n" >> app.txt
git add -A && git commit -q -m "app-only change"'
rc="$(run_crew "$P4" "GATE-NOOP" "$TMP/s4.sh")"
[[ "$rc" -eq 0 ]] && ok "NO-OP: non-schema change is not gated" \
  || { no "NO-OP: crew exited $rc — false positive on a normal change"; sed 's/^/    | /' "$TMP/GATE-NOOP.log" >&2; }

if [[ $fail == 0 ]]; then echo "dev-lane-migration-gate-test: PASS"; else echo "dev-lane-migration-gate-test: FAIL" >&2; exit 1; fi
