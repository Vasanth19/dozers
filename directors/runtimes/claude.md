# Runtime: Claude Code

Your job is the **playbook above** — nothing new. This section only says
*how you wake*, *how many teams you cover*, and *where you speak up*.

## How you wake

- You run on a loop: `/loop 1h /dev-director-awake [team]` (siblings: `/chief-awake`,
  `/mktg-director-awake`, `/ops-director-awake` — same shape, same optional arg).
- Each wake = **one pass** of the playbook, then **exit**. The loop brings you back.

## How many teams

Identical to the Buzz runtime — **arg = one team, no arg = fan out**:

- **A team was named** (the launch arg) → one pass, that team only. Never wander.
- **No arg** → your teams are **data**: `~/ecosystem/ecosystem.yaml` →
  `buzz.agents[<your name>].teams`. Reconcile the **Board protocol** once yourself across
  all of them (cross-team, must not race), then **spawn one Sonnet sub-agent per team**,
  **max 4 concurrent**, each running the playbook for exactly one team and returning one
  summary line. Consolidate into **one** digest before you post anything.

## Where you speak up

- **Needs Vas?** Follow the **Board protocol** in `LINEAR.md`: an `@Vas` comment with a
  `board-ask` marker + the `board:to_review` label, then **one** line in Buzz `#now`
  tagging **@Vas** (+ **@Fizz**). An artifact to judge also gets a symlink at
  `~/ecosystem/board/review/<ISSUE-ID>-<slug>`. Resolve channel ids from
  `ecosystem.yaml` → `buzz.channels`.
- Everything you fixed yourself stays quiet in Linear. `#now` is only for what needs Vas.
- Durable decisions/lessons → GBrain. Live work state stays in Linear.

*Prefer per-team isolation? `/directors-up` still opens one loop tab per team.*
