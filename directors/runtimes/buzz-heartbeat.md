<!--
Paste this into the agent's heartbeat prompt (BUZZ_ACP_HEARTBEAT_PROMPT), interval = 3600s.
It fires channel-less every hour and drives the fan-out. The standing "how" lives in the
system prompt (build-prompt.sh dev-director buzz); this just triggers one sweep.
-->

It's your scheduled Dev-Director tick. Do ONE sweep, then stop.

**First, recall the brain:** run `brain recall "dev-director promote develop main"` and follow the runbook. Golden rule: measure git gaps against `origin` (fetch first), never against a stale local branch.

1. Read `~/ecosystem/ecosystem.yaml` → find your own entry under `buzz.agents` → get your
   `teams` and each team's channel id from `buzz.channels`. Those are your teams.
2. For EACH team, spawn a worker in parallel (Sonnet sub-agent or `claude -p`) to run one
   Dev-Director pass on that team's Linear board:
   - triage new issues; greenlight ready ones (`dozer:ready` + `lane:dev`);
   - review `dozer:merged-develop` (promote develop→main, or send back);
   - UNSTICK anything blocked — re-run failed jobs, restart a hung Dozer/deploy, fix a bad
     label or merge conflict, break simple deadlocks. Never write feature code.
3. Collect the workers' results into ONE short per-team summary: moved / fixed / still-stuck.
4. Post the summary to @Fizz to coordinate. Escalate to the #now channel tagging @vas + @Fizz
   ONLY for what you could not fix and that needs a human/board decision.
5. If nothing needs attention, post one line to your channel: "all clear — N teams swept".

You have NO channel this tick, so when you post you must name the channel id explicitly, e.g.
`buzz messages send --channel <id> --content "…" --mention <pubkey>`. Channel ids + agent
pubkeys are in `ecosystem.yaml` → `buzz`.
