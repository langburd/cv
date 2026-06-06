---
name: cv-achievements
description: Use when turning a GitHub PR-activity JSON (produced by fetch-prs.sh) into CV achievement bullets for a job entry, then handing the approved bullets to the update-cv skill. Does not fetch from GitHub itself.
---

# CV Achievements

Turn a PR-activity JSON file into 5–6 CV achievement bullets for one job entry.

## Input contract

The user supplies a path to ONE JSON file produced by `fetch-prs.sh` (written to
`<out>/<org>/<author>/prs-authored.json` or `<out>/<org>/<author>/prs-reviewed.json`). Its shape:

```json
{ "generated_at": "...", "mode": "authored-all|reviewed",
  "author": "...", "org": "...", "pr_count": 0, "prs": [ ... ] }
```

This skill NEVER calls GitHub. If no JSON path is supplied, ask for one and tell the
user to run `.claude/skills/cv-achievements/fetch-prs.sh --author <user> --org <org>` first.

## Step 1 — Read mode, pick voice

Read the top-level `mode` field:

| mode | Meaning | Voice (verbs) |
|---|---|---|
| `authored-all` | Work the author led/built | Ownership: Designed, Led, Built, Architected, Migrated, Automated |
| `reviewed` | Work the author joined as a team member | Contribution: Contributed to, Participated in, Supported, Helped deliver |

## Step 2 — Analyze prs[]

- Cluster PRs by `repository`, then by recurring themes in `labels` / `title` / `files[].name`.
- Weight a cluster by total `additions`+`deletions`, `changedFiles`, PR count, and recency (`mergedAt`/`createdAt`).
- Discard noise: dependency bumps, version bumps, typo/lint fixes, reverts, trivial config-only PRs.
- For thin/empty `body`, infer the change from `files[].name` + `commits[].message` + diffstat. Do not invent impact you cannot ground in the data.

## Step 3 — Produce 5–6 bullets

- Match the existing `index.md` job-entry style: `-` bullets, action-verb first, past tense, impact-oriented.
- No PR numbers, no URLs, no repo names in the bullet text.
- Each bullet = one distinct theme. Merge overlapping clusters; do not pad.
- Use the voice chosen in Step 1.

## Step 4 — Review gate, then hand off

1. Print the candidate bullets and the target job entry (ask the user which job if ambiguous).
2. Wait for the user to edit/approve. Do NOT edit `index.md` here.
3. On approval, invoke the `update-cv` skill to insert the bullets under that job entry
   (branch → edit `index.md` → commit → PR).
