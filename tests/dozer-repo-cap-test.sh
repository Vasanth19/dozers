#!/usr/bin/env bash
# tests/dozer-repo-cap-test.sh — regression for GSAI-112 (per-repo crew cap).
#
# `fanout` and the group caps count CREWS. Neither knows which checkout a crew cuts its
# worktree from, so nine repo:cfw-social issues could fill all five slots and every crew
# would cut dozer/<id> off the same develop at once. `max_per_repo` caps crews PER
# CHECKOUT at claim time — a skip, never a wait.
#
# It drives the REAL engine (dozers/dozer.sh) on the files backend, from a throwaway copy
# of the repo carrying one extra lane, `nap`, whose crew just sleeps. A fake registry comes
# in through ECOSYSTEM_REGISTRY. No model, no network. The invariants:
#
#    1. CAPPED        6 ready issues on one repo, max_per_repo 2 -> exactly 2 live crews there.
#    2. NOT BLOCKING  the other-repo issues at the BOTTOM of the queue are claimed in the same
#                     drain that refuses the third alpha issue.
#    3. LABELS KEPT   a refused issue stays in ready/, untouched, with no claim comment.
#    4. LOGGED        `  ~ repo cap: alpha at 2/2, skipping <ID>` for each refusal.
#    5. PROGRESS      `once` still finishes every task — the cap throttles, never strands.
#    6. NO IDENTITY   tasks with no repo: and no team run up to fanout, uncapped.
#    7. UNRESOLVABLE  repo:ghost is uncapped at the gate, blocked by run_one with the
#                     resolver's reason, and takes no repo slot.
#    8. TWO ROUTES    a team-routed issue (team: ACME, no repo:) resolves to alpha and so
#                     shares alpha's cap.
#    9. LEGACY LOCK   a live lock from before this change (no repo= line) still counts.
#   10. DEAD LOCK     a dead owner holds no repo slot, and its stranded task is requeued.
#   11. CONFIG        max_per_repo: banana stops the engine at start, naming the key and value.
#   12. DEFAULT       the shipped org/config.yaml sets max_per_repo: 2.
#
# Run:  bash tests/dozer-repo-cap-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; FAKE="$TMP/root"; LOCKS="$TMP/locks"; HB="$TMP/hb"; REG="$TMP/ecosystem.yaml"
BOARD="$FAKE/tasks/board"; ALPHA="$TMP/proj/alpha"; BETA="$TMP/proj/beta"
ENGINE_PID=""; BG_PID=""

kill_crews() {
  local lock pid
  shopt -s nullglob
  for lock in "$LOCKS"/*.lock; do
    [[ -e "$lock/owner" ]] || continue
    pid="$(grep -E '^pid=' "$lock/owner" | cut -d= -f2)"
    [[ -n "$pid" ]] && { pkill -9 -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null; }
  done
  shopt -u nullglob
}
cleanup() {
  [[ -n "$ENGINE_PID" ]] && kill "$ENGINE_PID" 2>/dev/null
  kill_crews
  [[ -n "$BG_PID" ]] && kill "$BG_PID" 2>/dev/null
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

# ── a throwaway engine: the real scripts + a `nap` lane, its own board, locks, registry ──
mkdir -p "$FAKE/dozers/nap-lane" "$FAKE/tasks" "$FAKE/org" "$LOCKS" "$ALPHA" "$BETA"
cp -R "$ROOT/dozers/." "$FAKE/dozers/"
for f in "$ROOT"/tasks/*; do [[ -f "$f" ]] && cp "$f" "$FAKE/tasks/"; done
cp "$ROOT/org/config.yaml" "$FAKE/org/config.yaml"
cat > "$FAKE/dozers/nap-lane/crew.sh" <<'EOS'
#!/usr/bin/env bash
ID="$1"; TITLE="$2"; secs="${TITLE##*sleep=}"; secs="${secs%% *}"
sleep "$secs"
mkdir -p "$REPO_ROOT/.artifacts/nap"; printf -- '- slept %ss\n' "$secs" > "$REPO_ROOT/.artifacts/nap/$ID.summary"
EOS
chmod +x "$FAKE/dozers/nap-lane/crew.sh"

# alpha is first in its org, so it is ACME's default repo; beta is a second repo.
cat > "$REG" <<YAML
orgs:
  acme:
    linear_team: ACME
projects:
  - id: alpha
    org: acme
    local: $ALPHA
  - id: beta
    org: acme
    local: $BETA
YAML

# Every engine run in this file shares one environment. DEFAULT_GROUP_SLOTS=5 is deliberate:
# these ids sit in no fanout_by_group team, so without it they would share one 1-slot
# default group and the repo cap would never be the thing under test.
ENGINE_ENV=(env -u MAX_PER_REPO -u DOZER_MODEL_DEV -u MODEL_CMD BACKEND=files ADAPTER_QUIET=1
  FANOUT=5 DEFAULT_GROUP_SLOTS=5 POLL_SECONDS=1 HEARTBEAT_SECONDS=1
  LOCK_DIR="$LOCKS" HEARTBEAT_FILE="$HB" ECOSYSTEM_REGISTRY="$REG")

# ── board helpers ────────────────────────────────────────────────────────────────
reset_board() { rm -rf "$BOARD" "$LOCKS" "$HB" "$FAKE/.artifacts"; mkdir -p "$BOARD"/{ready,wip,done,blocked,review,inbox} "$LOCKS"; }
seed() {  # <id> <repo or ""> <seconds> <priority>
  mkdir -p "$BOARD/ready"
  { printf 'title: nap sleep=%s\nlane: nap\npriority: %s\n' "$3" "$4"
    [[ -n "$2" ]] && printf 'repo: %s\n' "$2"; } > "$BOARD/ready/$1.md"
}

# One line per LIVE crew lock: "<task>\t<repo= value>". A lock with no repo= line prints an
# empty second field, which is exactly the legacy shape.
live_lock_lines() {
  local lock pid
  shopt -s nullglob
  for lock in "$LOCKS"/*.lock; do
    [[ -f "$lock/owner" ]] || continue
    pid="$(grep -E '^pid=' "$lock/owner" 2>/dev/null | cut -d= -f2)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || continue
    printf '%s\t%s\n' "$(grep -E '^task=' "$lock/owner" | cut -d= -f2)" "$(grep -E '^repo=' "$lock/owner" | cut -d= -f2-)"
  done
  shopt -u nullglob
}
n_all()  { live_lock_lines | wc -l | tr -d ' '; }
n_repo() { live_lock_lines | awk -F'\t' -v r="$1" '$2==r' | wc -l | tr -d ' '; }
n_task() { live_lock_lines | awk -F'\t' -v p="$1" 'index($1,p)==1' | wc -l | tr -d ' '; }

# Poll a condition (an eval'd string) for up to $1 seconds.
wait_until() {
  local deadline=$(( SECONDS + $1 )); shift
  while (( SECONDS < deadline )); do eval "$*" && return 0; sleep 0.5; done
  return 1
}

start_loop() {  # <log> [REAPER_ENABLED]
  "${ENGINE_ENV[@]}" REAPER_ENABLED="${2:-0}" bash "$FAKE/dozers/dozer.sh" loop >"$1" 2>&1 &
  ENGINE_PID=$!
}
stop_loop() {
  kill "$ENGINE_PID" 2>/dev/null; wait "$ENGINE_PID" 2>/dev/null; ENGINE_PID=""
  kill_crews
}

# ── 12. the shipped budget ───────────────────────────────────────────────────────
grep -qE '^max_per_repo: 2$' "$FAKE/org/config.yaml" \
  && ok "12 DEFAULT: org/config.yaml sets max_per_repo: 2" \
  || bad "12 DEFAULT: org/config.yaml has no 'max_per_repo: 2' line"

# ── 1-4. CAPPED / NOT BLOCKING / LABELS KEPT / LOGGED — one loop, the queue mixed ──
reset_board
for i in 1 2 3 4 5 6; do seed "ALPHA-$i" alpha 30 1; done
for i in 1 2;         do seed "BETA-$i"  beta  30 2; done
start_loop "$TMP/p1.log"
wait_until 30 '(( $(n_all) >= 4 ))'; sleep 2
a="$(n_repo "$ALPHA")"; b="$(n_repo "$BETA")"

[[ "$a" == 2 ]] && ok "1 CAPPED: alpha holds exactly 2 live crews, with 6 of its issues queued" \
  || bad "1 CAPPED: alpha holds $a live crews, want 2"
[[ "$b" == 2 ]] && ok "2 NOT BLOCKING: both beta issues ran, below 4 queued alpha issues" \
  || { bad "2 NOT BLOCKING: beta holds $b live crews, want 2"; sed 's/^/    | /' "$TMP/p1.log" >&2; }
[[ "$(ls "$BOARD"/ready/ALPHA-*.md 2>/dev/null | wc -l | tr -d ' ')" == 4 ]] \
  && ! grep -q 'Dozer claimed' "$BOARD/ready/ALPHA-6.md" \
  && ok "3 LABELS KEPT: the 4 refused alpha issues stay in ready/, with no claim comment" \
  || bad "3 LABELS KEPT: refused issues were moved or touched"
grep -qE '^  ~ repo cap: alpha at 2/2, skipping ALPHA-3$' "$TMP/p1.log" \
  && ok "4 LOGGED: \`~ repo cap: alpha at 2/2, skipping ALPHA-3\`" \
  || { bad "4 LOGGED: no repo-cap line for ALPHA-3"; grep 'repo cap' "$TMP/p1.log" | sed 's/^/    | /' >&2; }
stop_loop

# ── 5. PROGRESS — once finishes every task ───────────────────────────────────────
reset_board
for i in 1 2 3 4 5 6; do seed "ALPHA-$i" alpha 0 1; done
for i in 1 2;         do seed "BETA-$i"  beta  0 2; done
"${ENGINE_ENV[@]}" REAPER_ENABLED=0 bash "$FAKE/dozers/dozer.sh" once >"$TMP/p2.log" 2>&1; rc=$?
(( rc == 0 )) && ok "5 PROGRESS: once exited 0 with a capped checkout in the queue" \
  || { bad "5 PROGRESS: once exited $rc"; sed 's/^/    | /' "$TMP/p2.log" >&2; }
[[ "$(ls "$BOARD"/done/*.md 2>/dev/null | wc -l | tr -d ' ')" == 8 ]] \
  && ok "5 PROGRESS: all 8 tasks reached done/ — the cap slows a repo, it never strands it" \
  || bad "5 PROGRESS: done=$(ls "$BOARD"/done/*.md 2>/dev/null | wc -l | tr -d ' ') of 8"

# ── 6. NO IDENTITY — uncapped ────────────────────────────────────────────────────
reset_board
for i in 1 2 3 4 5; do seed "ZERO-$i" "" 30 1; done
start_loop "$TMP/p3.log"
wait_until 30 '(( $(n_all) >= 5 ))'; sleep 2
[[ "$(n_all)" == 5 ]] && ! grep -q 'repo cap' "$TMP/p3.log" \
  && ok "6 NO IDENTITY: 5 tasks with no repo:/team ran at once, uncapped" \
  || { bad "6 NO IDENTITY: $(n_all) live crews, want 5"; sed 's/^/    | /' "$TMP/p3.log" >&2; }
stop_loop

# ── 7. UNRESOLVABLE — uncapped at the gate, blocked by run_one, no repo slot taken ───
reset_board
for i in 1 2 3; do seed "GHOST-$i" ghost 30 1; done
for i in 1 2 3; do seed "ALPHA-$i" alpha 30 2; done
start_loop "$TMP/p4.log"
wait_until 30 '[[ -f "$BOARD/blocked/GHOST-3.md" ]] && (( $(n_repo "$ALPHA") >= 2 ))'; sleep 1
[[ "$(ls "$BOARD"/blocked/GHOST-*.md 2>/dev/null | wc -l | tr -d ' ')" == 3 ]] \
  && grep -q 'repo:ghost does not resolve' "$BOARD/blocked/GHOST-1.md" \
  && ok "7 UNRESOLVABLE: 3 ghost issues blocked with the resolver's reason, no crew ran" \
  || bad "7 UNRESOLVABLE: ghost issues not blocked with the resolver's reason"
[[ "$(n_task GHOST)" == 0 ]] && ! grep -q 'skipping GHOST' "$TMP/p4.log" \
  && [[ "$(n_repo "$ALPHA")" == 2 ]] \
  && ok "7 UNRESOLVABLE: the ghosts took no repo slot — alpha still holds its 2" \
  || bad "7 UNRESOLVABLE: ghosts held or were capped a slot (alpha=$(n_repo "$ALPHA"))"
stop_loop

# ── 8. TWO ROUTES — team-routed issue shares alpha's cap ─────────────────────────
reset_board
seed ALPHA-1 alpha 30 1
seed ALPHA-2 alpha 30 1
printf 'title: nap sleep=30\nlane: nap\npriority: 2\nteam: ACME\n' > "$BOARD/ready/TEAM-1.md"
start_loop "$TMP/p5.log"
wait_until 30 '(( $(n_repo "$ALPHA") >= 2 ))'; sleep 2
[[ "$(n_repo "$ALPHA")" == 2 ]] && [[ ! -f "$BOARD/wip/TEAM-1.md" ]] \
  && grep -qE '^  ~ repo cap: alpha at 2/2, skipping TEAM-1$' "$TMP/p5.log" \
  && ok "8 TWO ROUTES: team:ACME resolves to alpha and is refused by alpha's cap" \
  || { bad "8 TWO ROUTES: alpha=$(n_repo "$ALPHA"), TEAM-1 in wip: $([[ -f "$BOARD/wip/TEAM-1.md" ]] && echo yes || echo no)"; sed 's/^/    | /' "$TMP/p5.log" >&2; }
stop_loop

# ── 9. LEGACY LOCK — a pre-GSAI-112 lock still counts, via its task's checkout ───
reset_board
sleep 300 & BG_PID=$!
mkdir -p "$LOCKS/ALPHA-LEG.lock"
printf 'pid=%s\nhost=local\ntask=ALPHA-LEG\nlane=nap\nts=legacy\n' "$BG_PID" > "$LOCKS/ALPHA-LEG.lock/owner"
printf 'title: legacy\nlane: nap\nrepo: alpha\n' > "$BOARD/wip/ALPHA-LEG.md"
for i in 1 2 3; do seed "ALPHA-$i" alpha 30 1; done
start_loop "$TMP/p6.log"
wait_until 30 '(( $(n_task ALPHA-) >= 2 ))'; sleep 2
claimed="$(ls "$BOARD"/wip/ALPHA-[123].md 2>/dev/null | wc -l | tr -d ' ')"
[[ "$claimed" == 1 ]] && grep -qE '^  ~ repo cap: alpha at 2/2, skipping ALPHA-2$' "$TMP/p6.log" \
  && ok "9 LEGACY LOCK: the live pre-change lock counted, so only 1 new alpha crew started" \
  || { bad "9 LEGACY LOCK: $claimed new alpha crews claimed, want 1"; sed 's/^/    | /' "$TMP/p6.log" >&2; }
stop_loop
kill "$BG_PID" 2>/dev/null; BG_PID=""

# ── 10. DEAD LOCK — a dead owner holds no slot; the stranded task is requeued ────
reset_board
sleep 0 & dead_pid=$!; wait "$dead_pid" 2>/dev/null
mkdir -p "$LOCKS/ALPHA-DEAD.lock"
printf 'pid=%s\nhost=local\ntask=ALPHA-DEAD\nlane=nap\nts=dead\nrepo=%s\n' "$dead_pid" "$ALPHA" > "$LOCKS/ALPHA-DEAD.lock/owner"
printf 'title: nap sleep=30\nlane: nap\nrepo: alpha\n' > "$BOARD/wip/ALPHA-DEAD.md"
for i in 1 2 3; do seed "ALPHA-$i" alpha 30 1; done
start_loop "$TMP/p7.log" 1
wait_until 30 '(( $(n_repo "$ALPHA") >= 2 ))'; sleep 2
[[ "$(n_repo "$ALPHA")" == 2 ]] && [[ -f "$BOARD/ready/ALPHA-DEAD.md" ]] && [[ ! -d "$LOCKS/ALPHA-DEAD.lock" ]] \
  && ok "10 DEAD LOCK: the dead owner held no slot (alpha holds 2) and ALPHA-DEAD was requeued" \
  || { bad "10 DEAD LOCK: alpha=$(n_repo "$ALPHA"), requeued=$([[ -f "$BOARD/ready/ALPHA-DEAD.md" ]] && echo yes || echo no)"; sed 's/^/    | /' "$TMP/p7.log" >&2; }
stop_loop

# ── 11. CONFIG — a bad value stops the engine at start ───────────────────────────
reset_board
sed 's/^max_per_repo: 2$/max_per_repo: banana/' "$FAKE/org/config.yaml" > "$TMP/cfg.yaml" && mv "$TMP/cfg.yaml" "$FAKE/org/config.yaml"
seed ALPHA-1 alpha 0 1
"${ENGINE_ENV[@]}" REAPER_ENABLED=0 bash "$FAKE/dozers/dozer.sh" once >"$TMP/p8.log" 2>&1; rc=$?
if (( rc == 1 )) && grep -q 'max_per_repo must be a positive integer' "$TMP/p8.log" && grep -q 'banana' "$TMP/p8.log"; then
  ok "11 CONFIG: max_per_repo: banana exits 1, naming the key and the value"
else
  bad "11 CONFIG: rc=$rc, log: $(tr '\n' ' ' < "$TMP/p8.log")"
fi

echo "dozer-repo-cap: $pass ✓, $fail ✗"; (( fail == 0 ))
