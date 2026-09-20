#!/usr/bin/env bash
# tests/dozer-group-cap-test.sh — regression for GSAI-169 (per-team crew-slot cap).
#
# `fanout` is a GLOBAL cap, and a global cap is won by whoever greenlights the most.
# That is how the factory ends up building the factory: the 2026-09-20 audit found 57%
# of the Ollama allowance going to GSAI housekeeping while CFW — the team with actual
# customers — queued behind it. With `fanout: 5` and ten GSAI issues sorted ahead of two
# CFW issues, the old drain claimed five GSAI and zero CFW, every time.
#
# It drives the REAL engine (dozers/dozer.sh) on the files backend, from a throwaway copy
# of the repo carrying one extra lane, `nap`, whose crew just sleeps. No model, no network.
# The invariants:
#
#   1. CAPPED — at most `slots` crews live at once for a group, however much of the ready
#      list belongs to it. (GSAI: 1.)
#   2. NOT BLOCKING — a saturated group is SKIPPED PAST, not waited on: the CFW issues at
#      the BOTTOM of the queue are claimed in the same drain that refuses the ninth GSAI.
#      This is the whole point — a full group costs that group throughput and nobody else's.
#   3. DEFAULT GROUP — a team named in no group gets one shared default slot, so a new
#      team cannot quietly take the fleet before someone budgets it.
#   4. LOGGED — the refusal says `skip: group-cap <team> <live>/<cap>`, once per group.
#   5. PROGRESS — the cap throttles concurrency, never completion: `once` still finishes
#      every task, just fewer at a time.
#
# Run:  bash tests/dozer-group-cap-test.sh   (exits non-zero on any failure)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; FAKE="$TMP/root"; LOCKS="$TMP/locks"; HB="$TMP/hb"
ENGINE_PID=""
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
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1" >&2; }

# ── a throwaway engine: the real scripts + a `nap` lane, its own board and locks ──
mkdir -p "$FAKE/dozers/nap-lane" "$FAKE/tasks" "$FAKE/org" "$LOCKS"
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
BOARD="$FAKE/tasks/board"

# The caps under test come from the SHIPPED org/config.yaml — this test is a check on
# the real budget, not on a fixture's.
grep -qE '^fanout_by_group:' "$FAKE/org/config.yaml" \
  && ok "org/config.yaml carries a fanout_by_group budget" \
  || bad "org/config.yaml has no fanout_by_group block"
caps="$(sed -n '/^fanout_by_group:/,/^[^[:space:]#-]/p' "$FAKE/org/config.yaml" | grep -cE '^[[:space:]]*-')"
[[ "$caps" == "3" ]] && ok "three groups are budgeted (CFW / GSAI / LL+BRD+DLY)" \
  || bad "found $caps group rows, want 3"
# The sum must fit inside fanout or the numbers are a fiction (the engine warns; assert it).
sumslots="$(sed -n '/^fanout_by_group:/,/^[^[:space:]#-]/p' "$FAKE/org/config.yaml" \
            | sed -n 's/.*slots:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | paste -sd+ - | bc)"
fanoutcfg="$(grep -E '^fanout:' "$FAKE/org/config.yaml" | head -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')"
(( sumslots <= fanoutcfg )) && ok "the slot budget ($sumslots) fits inside fanout ($fanoutcfg)" \
  || bad "slots sum to $sumslots but fanout is $fanoutcfg"

seed() {  # $1 = id, $2 = priority, $3 = seconds
  mkdir -p "$BOARD/ready"
  printf 'title: nap sleep=%s\nlane: nap\npriority: %s\n' "$3" "$2" > "$BOARD/ready/$1.md"
}
live_for() {  # $1 = team prefix -> how many live crew locks it holds right now
  local n=0 lock pid id
  shopt -s nullglob
  for lock in "$LOCKS"/*.lock; do
    [[ -f "$lock/owner" ]] || continue
    pid="$(grep -E '^pid=' "$lock/owner" 2>/dev/null | cut -d= -f2)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || continue
    id="$(grep -E '^task=' "$lock/owner" 2>/dev/null | cut -d= -f2)"
    [[ "${id%%-*}" == "$1" ]] && n=$((n+1))
  done
  shopt -u nullglob
  printf '%s' "$n"
}

# ── the queue: 10 GSAI first (p1), then 3 ZZZ (p2, no group), then 2 CFW (p3) ──
# Priorities put every capped team AHEAD of CFW on purpose: under the old drain, fanout=5
# would be spent entirely on GSAI and CFW would never be reached.
rm -rf "$BOARD"; mkdir -p "$BOARD"/{ready,wip,done,blocked,review,inbox}
for i in 1 2 3 4 5 6 7 8 9 10; do seed "GSAI-$i" 1 30; done
for i in 1 2 3; do seed "ZZZ-$i" 2 30; done
for i in 1 2; do seed "CFW-$i" 3 30; done

LOG="$TMP/loop.log"
env -u DOZER_MODEL_DEV -u MODEL_CMD BACKEND=files ADAPTER_QUIET=1 REAPER_ENABLED=0 \
    FANOUT=5 POLL_SECONDS=1 HEARTBEAT_SECONDS=1 LOCK_DIR="$LOCKS" HEARTBEAT_FILE="$HB" \
    bash "$FAKE/dozers/dozer.sh" loop >"$LOG" 2>&1 &
ENGINE_PID=$!

# Settle: wait until the engine has claimed all it is going to claim (4 crews), or give up.
start=$SECONDS
while (( SECONDS - start < 30 )); do
  (( $(live_for GSAI) + $(live_for ZZZ) + $(live_for CFW) >= 4 )) && break
  sleep 0.5
done
sleep 2   # ...and a beat longer, so an over-claim would have shown up by now

g="$(live_for GSAI)"; z="$(live_for ZZZ)"; c="$(live_for CFW)"

# ── 1. capped ────────────────────────────────────────────────────────────────
[[ "$g" == "1" ]] && ok "GSAI holds exactly 1 crew, not 5, with 10 of its issues queued" \
  || { bad "GSAI holds $g live crews, want 1"; sed 's/^/    | /' "$LOG" >&2; }

# ── 2. a full group does not block the others ────────────────────────────────
[[ "$c" == "2" ]] \
  && ok "both CFW issues ran despite sitting BELOW 10 capped GSAI issues in the queue" \
  || { bad "CFW holds $c live crews, want 2 — a saturated group blocked the queue"; sed 's/^/    | /' "$LOG" >&2; }

# ── 3. the default group ─────────────────────────────────────────────────────
[[ "$z" == "1" ]] && ok "an ungrouped team (ZZZ) falls into the default group: 1 slot" \
  || bad "ZZZ holds $z live crews, want 1"

# ...and the global cap is still the ceiling, not the floor: 1+1+2 = 4 of fanout 5.
(( g + z + c <= 5 )) && ok "the group caps hold under the global fanout (total $((g+z+c))/5)" \
  || bad "total live crews $((g+z+c)) exceeds fanout 5"

# ── 4. the refusal is logged ─────────────────────────────────────────────────
grep -qE '^  ~ skip: group-cap GSAI 1/1$' "$LOG" \
  && ok "the drain logs \`skip: group-cap GSAI 1/1\`" \
  || { bad "no group-cap line for GSAI: $(grep -c 'group-cap' "$LOG") matches"; grep 'group-cap' "$LOG" | sed 's/^/    | /' >&2; }
[[ "$(grep -cE '^  ~ skip: group-cap GSAI ' "$LOG")" -le "$(grep -cE '^\[dozer\] .* poll ' "$LOG")" ]] \
  && ok "...once per group per drain, not once per deferred issue" \
  || bad "the group-cap line is repeated per issue: $(grep -cE '^  ~ skip: group-cap GSAI ' "$LOG") lines"

kill "$ENGINE_PID" 2>/dev/null; wait "$ENGINE_PID" 2>/dev/null; ENGINE_PID=""
kill_crews

# ── 5. the cap throttles concurrency, never completion ───────────────────────
rm -rf "$BOARD" "$LOCKS" "$HB" "$FAKE/.artifacts"
mkdir -p "$BOARD"/{ready,wip,done,blocked,review,inbox} "$LOCKS"
for i in 1 2 3; do seed "GSAI-$i" 1 0; done
for i in 1 2; do seed "CFW-$i" 2 0; done
LOG2="$TMP/once.log"
env -u DOZER_MODEL_DEV -u MODEL_CMD BACKEND=files ADAPTER_QUIET=1 REAPER_ENABLED=0 \
    FANOUT=5 POLL_SECONDS=1 HEARTBEAT_SECONDS=1 LOCK_DIR="$LOCKS" HEARTBEAT_FILE="$HB" \
    bash "$FAKE/dozers/dozer.sh" once >"$LOG2" 2>&1
rc=$?
(( rc == 0 )) && ok "ONCE: exited 0 with a capped group in the queue" \
  || { bad "ONCE: exited $rc"; sed 's/^/    | /' "$LOG2" >&2; }
[[ "$(ls "$BOARD"/done/*.md 2>/dev/null | wc -l | tr -d ' ')" == "5" ]] \
  && ok "ONCE: all 5 tasks still reached done/ — the cap slows a group, it never strands it" \
  || { bad "ONCE: done=$(ls "$BOARD"/done/*.md 2>/dev/null | wc -l) of 5"; sed 's/^/    | /' "$LOG2" >&2; }

echo "dozer-group-cap: $pass ✓, $fail ✗"; (( fail == 0 ))
