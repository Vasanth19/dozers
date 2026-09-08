# Dozers × Buzz — neutral Directors, one channel per org

The model:
- **One Dozer** (the doer) runs **unscoped** — it serves *every* org in `linear_teams`.
- **Neutral Director agents** (the deciders) — the *same* agent definition works for
  every org. Each org gets its own **Buzz channel**, and that channel's **canvas**
  holds the org config. The Director reads the canvas to learn which org / Linear team
  it's serving. Add one org → new channel + canvas, no new agent code.

```
Buzz:  #cfw-social (canvas: team CFW …)   #learnloop (canvas: team LL …)   #… 
          │ Dev-Director + Mktg-Director      │ same neutral agents
          │  read canvas → work team CFW       │  read canvas → work team LL
          ▼ greenlight ready+lane in Linear    ▼
   ────────────────────────────────────────────────────────────
   ONE Dozer:  dozers/dozer.sh loop   (linear_teams: "CFW,LL,BRD,GSAI,DLY" → routes each
                                        task to its org's repo; fanout parallel)
```

**Already set up:** `org/config.yaml` → `linear_teams:"CFW,LL,BRD,GSAI,DLY"`, `fanout:5`,
`push:"false"` (merges stay on the local integration branch — nothing reaches origin).
Workdirs resolve from `~/ecosystem/ecosystem.yaml`, never a hardcoded map. The loop runs
unattended under launchd as `com.dozers.loop` (`dozers/service.sh install|status|logs`).

---

## 1. Start the Dozer (unscoped — runs for everybody)

```bash
export DOZERS_HOME=~/Code/dozers
source ~/ecosystem/vault/linear.env      # LINEAR_API_KEY
"$DOZERS_HOME"/dozers/dozer.sh loop        # serves CFW + LL (all of linear_teams)
```
It polls every configured team, and for each `ready`+`lane` issue routes to that org's
repo, runs the crew, merges locally (**no push**, `push:false`), and comments back.

## 2. Per org: a Buzz channel + a canvas

For each org (e.g. learnloop):
1. Create a **channel** (e.g. `#learnloop`).
2. Paste that org's config into the **channel canvas** — copy
   `directors/org-canvas.template.md` and fill it:
   ```yaml
   org: learnloop
   linear_team: LL
   lanes: [dev, marketing]
   repos: [learnloop]
   brand_voice: "clear, warm, no hype"
   okr: "Linear Initiative 'learnloop' -> Projects + Milestones"
   escalate_to: "Chief / Vasanth"
   ```
   Keep `linear_team` in sync with the Dozer's `linear_teams` + `workdirs`.

## 3. Add the neutral Director agent(s) to each org channel

- **System prompt:** paste the output of **`directors/build-prompt.sh dev-director`** (and/or
  `mktg-director`) — it merges the persona + Linear how-to into one block — they're self-contained and **org-neutral** (they read the
  channel canvas for context).
- **Tools:** Linear MCP (or `LINEAR_API_KEY` in the agent env).
- **Heartbeat:**
  ```
  BUZZ_ACP_HEARTBEAT_INTERVAL=1200
  BUZZ_ACP_HEARTBEAT_PROMPT=You are a Director in this org's channel. Read this channel's canvas for your org context (org, linear_team, lanes, repos, brand_voice, okr). Then work that Linear team: triage untriaged issues (spec + greenlight ready + the right lane), and review needs-review items (approve, or send back with a note). Decide only; never execute — the Dozer builds what you greenlight.
  ```
The same two agent definitions get dropped into every org's channel; the canvas makes
them org-specific.

## 4. The live run

File a small task in an org's Linear team (e.g. LL: *"Add a /health endpoint"*). The
channel's Director reads the canvas → confirms team LL → specs it → greenlights
`ready`+`lane:dev`. The unscoped Dozer picks it up → builds it in the learnloop repo →
merges local `develop` (no push) → comments the summary. You review.

## Verify / rollback
- Built code: `git -C ~/initiatives/learnloop/learnloop log --oneline develop | head`
- Undo (nothing pushed): `git -C ~/initiatives/learnloop/learnloop reset --hard origin/develop`
- Stop the Dozer: Ctrl-C a foreground loop, or `dozers/service.sh` / `launchctl bootout gui/$(id -u)/com.dozers.loop` for the supervised one.

## Adding more orgs later
Create their Linear team → add its key to `linear_teams` + path to `workdirs` in
`org/config.yaml` → new Buzz channel + canvas. No agent changes. (Free Linear plan
caps at 2 teams; more orgs need a paid plan.)
