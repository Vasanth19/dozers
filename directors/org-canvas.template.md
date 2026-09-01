# Org canvas — <ORG NAME>

Paste this into the Buzz **channel canvas** for this org (one channel per org).
The neutral Director agent reads it to learn which org/Linear team it serves.

```yaml
org: learnloop
linear_team: LL                      # Linear team key this channel operates on
lanes: [dev, marketing]
repos:                               # repo names for dev `repo:<name>` hints
  - learnloop                        #   (actual disk paths live in the Dozer config)
brand_voice: "clear, warm, no hype"  # for marketing briefs
okr: "Linear Initiative 'learnloop' -> its Projects (Objectives) + Milestones (KRs)"
escalate_to: "Chief / Vasanth for anything above lane authority"
```

Copy this per org — change `org`, `linear_team`, `repos`, `brand_voice`, `okr`.
Keep `linear_team` in sync with the Dozer's `workdirs` + `linear_teams` in
`org/config.yaml` (same team key → its repo path).
