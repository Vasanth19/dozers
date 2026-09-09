#!/usr/bin/env bash
# tests/dev-lane-timeout-test.sh — regression test for GSAI-37 (crew side).
#
# A crew ran a repo's test command, the coding agent, and the lockfile install with no
# time bound at all. One hung `pnpm test:db` (8 hours asleep, 0.26s CPU) held its slot
# forever: the reaper only acts on a DEAD pid, and a sleeping one looks alive. Now every
# such command runs under dozers/timebox.sh and a hang FAILS the task, naming the
# timeout, with the hung process tree killed and nothing merged.
#
# Three hangs, each driving the REAL crew against a throwaway repo (bounds cut to 2s):
#   TEST   — the repo's `npm test` hangs in the task worktree -> blocked, reason names
#            the test timeout, develop untouched, the hung grandchild is dead
#   MODEL  — the coding agent hangs -> blocked, reason names the model timeout, the
#            worktree is kept for resume, the agent's grandchild is dead
#   GATE   — tests pass in the task worktree but hang on the integration branch after
#            the merge (the green-gate run) -> merge REVERTED, reason names the timeout
#            and not "merge broke develop"
# Plus a control: the same repo with a fast test command still merges under the bounds.
#
# Run:  bash tests/dev-lane-timeout-test.sh   (exits non-zero on failure)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/dozers/dev-lane/crew.sh"

TMP="$(mktemp -d)"
cleanup() {
  # kill anything a case left sleeping (proof of a failed kill, but never a leak)
  local f; for f in "$TMP"/*.grandchild; do [[ -e "$f" ]] && { kill -9 "$(cat "$f")" 2>/dev/null || true; }; done
  rm -f "$ROOT"/.artifacts/dev/TEST-TO* 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true
  return 0   # under set -e a dead pid's failed kill must not turn a PASS into exit 1
}
trap cleanup EXIT

fail=0; ok() { echo "  ✓ $1"; }; no() { echo "  ✗ $1" >&2; fail=1; }
dump() { sed 's/^/    | /' "$1" >&2; }

# A throwaway repo on `main` + `develop`. Its test command is `bash t.sh`; t.sh hangs
# when $HANG_WHERE matches its cwd (task worktree = "*-<id>", merge worktree =
# "*-merge"), forking a grandchild sleep first and recording its pid — the dead-or-alive
# check afterwards is what proves the process GROUP was killed.
mkproj() {  # $1 = dir
  local d="$1"
  mkdir -p "$d"; ( cd "$d"
    git init -q -b main .
    git config user.email test@dozer && git config user.name dozer-test
    printf 'node_modules\n' > .gitignore
    printf '{"name":"p","version":"1.0.0","scripts":{"test":"bash t.sh"}}\n' > package.json
    cat > t.sh <<'EOS'
#!/usr/bin/env bash
case "$PWD" in
  ${HANG_WHERE:-__never__}) sleep 300 & echo $! > "$GRANDCHILD_FILE"; wait ;;
esac
exit 0
EOS
    printf 'seed\n' > feature.txt
    git add -A && git commit -q -m init
    git branch develop )
}

# Stub coding agent: commits a change. With AGENT_HANG=1 it forks a grandchild sleep,
# records the pid, and hangs — the "model that never returns" case.
STUB="$TMP/stub-agent.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
if [[ "${AGENT_HANG:-}" == 1 ]]; then sleep 300 & echo $! > "$GRANDCHILD_FILE"; wait; fi
printf 'dozer change\n' >> feature.txt
git add -A && git commit -q -m "stub agent change"
EOS
chmod +x "$STUB"

run_crew() {  # $1 = proj dir, $2 = task id, $3 = log, $4.. = extra KEY=VAL
  local proj="$1" id="$2" log="$3"; shift 3
  env GRANDCHILD_FILE="$TMP/$id.grandchild" TIMEBOX_KILL_GRACE=1 \
      DOZER_TIMEOUT_TEST=2 DOZER_TIMEOUT_MODEL=2 DOZER_TIMEOUT_DEPS=2 \
      REPO_ROOT="$TMP" WORKDIR="$proj" WORKTREE_ROOT="$TMP/wt-$id" INTEGRATION_BRANCH="develop" \
      MODEL_CMD="bash $STUB" PUSH="false" DOZER_PERSONA="test" "$@" \
      bash "$CREW" "$id" "timeout test" >"$log" 2>&1
}
dev_head() { git -C "$1" log -1 --format=%s develop 2>/dev/null || true; }
reason() { cat "$TMP/.artifacts/dev/$1.fail" 2>/dev/null || true; }
grandchild_dead() {  # $1 = id → 0 if the recorded grandchild is gone (or was never forked)
  local pid; pid="$(cat "$TMP/$1.grandchild" 2>/dev/null || true)"
  [[ -z "$pid" ]] && return 1
  sleep 1; ! kill -0 "$pid" 2>/dev/null
}

# ── TEST: the repo's test command hangs in the task worktree ──────────────────
PA="$TMP/hang-test"; mkproj "$PA"
LOG="$TMP/a.log"; start=$SECONDS; rc=0
run_crew "$PA" "TEST-TO-A" "$LOG" HANG_WHERE="*-TEST-TO-A" || rc=$?
took=$(( SECONDS - start ))
[[ $rc -ne 0 ]] && ok "TEST: crew blocked (exit $rc) in ${took}s" || { no "TEST: crew exited 0 with a hung test command"; dump "$LOG"; }
(( took <= 30 )) && ok "TEST: the bound bit (not a 300s wait)" || no "TEST: took ${took}s"
r="$(reason TEST-TO-A)"
[[ "$r" == *"timed out after 2s"* && "$r" == *"DOZER_TIMEOUT_TEST"* ]] && ok "TEST: reason names the timeout and the knob" \
  || { no "TEST: reason does not name the timeout: '$r'"; dump "$LOG"; }
[[ "$r" == *"npm test"* ]] && ok "TEST: reason names the command that hung" || no "TEST: reason lacks the command: '$r'"
[[ "$(dev_head "$PA")" == "init" ]] && ok "TEST: develop untouched" || no "TEST: develop advanced to '$(dev_head "$PA")'"
grandchild_dead TEST-TO-A && ok "TEST: hung grandchild is dead (group killed)" || no "TEST: grandchild sleep survived (pid $(cat "$TMP/TEST-TO-A.grandchild" 2>/dev/null))"

# ── MODEL: the coding agent hangs ─────────────────────────────────────────────
PB="$TMP/hang-model"; mkproj "$PB"
LOG="$TMP/b.log"; start=$SECONDS; rc=0
run_crew "$PB" "TEST-TO-B" "$LOG" AGENT_HANG=1 || rc=$?
took=$(( SECONDS - start ))
[[ $rc -ne 0 ]] && ok "MODEL: crew blocked (exit $rc) in ${took}s" || { no "MODEL: crew exited 0 with a hung agent"; dump "$LOG"; }
r="$(reason TEST-TO-B)"
[[ "$r" == *"coding agent timed out after 2s"* && "$r" == *"DOZER_TIMEOUT_MODEL"* ]] && ok "MODEL: reason names the model timeout" \
  || { no "MODEL: reason does not name the model timeout: '$r'"; dump "$LOG"; }
[[ "$r" == *"kept for resume"* ]] && ok "MODEL: worktree kept for resume" || no "MODEL: reason does not mention resume: '$r'"
[[ -d "$TMP/wt-TEST-TO-B/hang-model-TEST-TO-B" ]] && ok "MODEL: worktree actually kept" || no "MODEL: worktree removed"
[[ "$(dev_head "$PB")" == "init" ]] && ok "MODEL: develop untouched" || no "MODEL: develop advanced to '$(dev_head "$PB")'"
grandchild_dead TEST-TO-B && ok "MODEL: hung grandchild is dead (group killed)" || no "MODEL: grandchild sleep survived"

# ── GATE: tests pass in the task worktree, hang on develop after the merge ────
PC="$TMP/hang-gate"; mkproj "$PC"
LOG="$TMP/c.log"; start=$SECONDS; rc=0
run_crew "$PC" "TEST-TO-C" "$LOG" HANG_WHERE="*-merge" || rc=$?
took=$(( SECONDS - start ))
[[ $rc -ne 0 ]] && ok "GATE: crew blocked (exit $rc) in ${took}s" || { no "GATE: crew exited 0 with a hung green-gate"; dump "$LOG"; }
r="$(reason TEST-TO-C)"
[[ "$r" == *"green-gate"* && "$r" == *"timed out after 2s"* ]] && ok "GATE: reason names the green-gate timeout" \
  || { no "GATE: reason does not name the green-gate timeout: '$r'"; dump "$LOG"; }
[[ "$r" != *"merge broke"* ]] && ok "GATE: a hang is reported as a timeout, not as 'merge broke develop'" \
  || no "GATE: a hang was misreported as a broken merge"
[[ "$r" == *"reverted"* ]] && ok "GATE: reason says the merge was reverted" || no "GATE: reason lacks 'reverted': '$r'"
[[ "$(dev_head "$PC")" == "init" ]] && ok "GATE: develop reverted to pre-merge" || no "GATE: develop left at '$(dev_head "$PC")'"
grandchild_dead TEST-TO-C && ok "GATE: hung grandchild is dead (group killed)" || no "GATE: grandchild sleep survived"

# ── CONTROL: nothing hangs -> the same bounds let a normal run merge ──────────
PD="$TMP/fast"; mkproj "$PD"
LOG="$TMP/d.log"; rc=0
run_crew "$PD" "TEST-TO-D" "$LOG" || rc=$?
[[ $rc -eq 0 ]] && ok "CONTROL: a fast run still merges under the bounds" || { no "CONTROL: crew exited $rc"; dump "$LOG"; }
[[ "$(dev_head "$PD")" == merge*TEST-TO-D* ]] && ok "CONTROL: merge landed on develop" || no "CONTROL: develop HEAD is '$(dev_head "$PD")'"

if [[ $fail == 0 ]]; then echo "dev-lane-timeout-test: PASS"
else echo "dev-lane-timeout-test: FAIL" >&2; exit 1; fi
