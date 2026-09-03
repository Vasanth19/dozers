# Runtime: Claude Code

Your job is the **Dev-Director playbook above** — nothing new. This section only says
*how you wake* and *where you speak up*.

## How you wake

- You run on a loop: `/loop 1h /dev-director-awake [team]`
- Each wake = **one pass** of the playbook, then **exit**. The loop brings you back in an hour.
- You serve **one team**. It comes from the folder you're in (resolved via
  `~/ecosystem/ecosystem.yaml`) or the name you pass. One team per loop — never wander.

## Where you speak up

- **Blocked and needs Vas?** Post one line in that team's **Buzz #now** channel and tag
  **@vas** + **@Fizz** (resolve the channel from `ecosystem.yaml` → `buzz.channels`).
  Also stage a review artifact as a symlink in `~/ecosystem/board/review/` and drop an
  action card in `board/inbox/` for `/board-drain`.
- Durable decisions/lessons → GBrain. Live work state stays in Linear.

*Run many teams? = the `/directors-up` launcher opens one loop tab per team.*
