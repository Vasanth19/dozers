# Live dev run on learnloop — Buzz Director + Dozer

Goal: a real learnloop dev task greenlit by a **Buzz Director** and built by a
**Dozer** end-to-end, on your machine, **no push** (fully reversible).

**Already done for you:**
- ✅ ab-hustler **stopped** (so nothing collides on the learnloop repo).
  *Restart it later with:* `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gsai.ab-hustler.plist`
- ✅ Dozers **configured**: `org/config.yaml` → `linear_teams: "CFW,LL"`, `fanout: 2`,
  `push: "false"` (nothing leaves your machine), `LL → /Users/vasanth/initiatives/learnloop/learnloop`.

---

## 0. Prereqs (one terminal)

```bash
export DOZERS_HOME=/Users/vasanth/Code/dozers
source ~/ecosystem/vault/linear.env        # exports LINEAR_API_KEY
```

## 1. Start the Dozer (the doer) — scope it to learnloop for this first run

```bash
LINEAR_TEAM=LL "$DOZERS_HOME"/dozers/dozer.sh loop
```
It polls team **LL** every 30s, and for any `ready`+`lane:dev` issue it: cuts a
`dozer/<id>` worktree off `develop` in the learnloop checkout, runs the coding agent
(`claude -p`) to implement + test, **merges to LOCAL `develop` (no push)**, and posts
a ≤10-line summary back on the Linear issue. Leave this running.

> Scoping to `LINEAR_TEAM=LL` for the first run keeps it off the CFW board. Later,
> drop the override to serve `CFW,LL` together.

## 2. Create the Buzz Director (the decider)

In the Buzz app, create an agent:
- **System prompt / instructions:** paste the entire contents of
  **`directors/buzz/dev-director-LL.md`** (it's self-contained — persona + the Linear
  how-to). *Agents only get pasted text, so paste the whole file.*
- **Tools:** give it the **Linear MCP** (or set `LINEAR_API_KEY` in its env).
- **Heartbeat** (so it works the board unattended):
  ```
  BUZZ_ACP_HEARTBEAT_INTERVAL=1200
  BUZZ_ACP_HEARTBEAT_PROMPT=You are the learnloop Dev-Director. Check Linear team LL: triage untriaged issues (spec them in the description, then greenlight with labels ready + lane:dev), and review anything labeled needs-review (approve → Done, or send back with a comment). Decide only; never write code — the Dozer builds what you greenlight.
  ```

## 3. Do the live run

1. **File a small task** in Linear team **LL** (or let the Director find one). Keep it
   tiny for the first run, e.g. *"Add a /health endpoint returning {ok:true}"*.
2. The **Director** (on its next heartbeat, or trigger it) triages → writes the spec in
   the issue description → adds labels **`ready` + `lane:dev`** (+ `repo:` only if the
   task targets a non-default learnloop repo).
3. The **Dozer** (step 1) picks it up within ~30s → worktree → `claude -p` implements +
   runs `npm test` → merges to local `develop` → comments the summary on the issue.
4. **You review**: the Linear issue shows claim + done comments; the code is on local
   `develop` in `/Users/vasanth/initiatives/learnloop/learnloop` (not pushed).

## 4. Verify / rollback

- **See what it built:** `git -C /Users/vasanth/initiatives/learnloop/learnloop log --oneline develop | head`
- **Undo the merge (nothing was pushed):**
  `git -C /Users/vasanth/initiatives/learnloop/learnloop reset --hard origin/develop`
- **Stop the Dozer:** Ctrl-C the loop.
- **Restart ab-hustler when done:**
  `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gsai.ab-hustler.plist`

## Safety rails in effect

- `push: "false"` → the Dozer never pushes; all merges are local `develop`.
- ab-hustler stopped → no second engine touching learnloop.
- Worktrees are isolated (`dozer/<id>`), cleaned up after each task.
- First run scoped to `LINEAR_TEAM=LL` → CFW untouched.
