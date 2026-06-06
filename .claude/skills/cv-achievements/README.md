# cv-achievements

Generate CV achievement bullets for a job entry from your real GitHub PR
activity. Reusable for any GitHub user, any org, and any job.

## Pieces

| File | Role |
|---|---|
| `fetch-prs.sh` | Fetches PR activity into JSON. Run it yourself. |
| `SKILL.md` | Claude skill: reads the JSON, writes bullets, hands off to `update-cv`. |

The script does all GitHub I/O. The skill does all analysis. They share only the
JSON file — neither calls the other.

## Prerequisites

- [`gh`](https://cli.github.com/) installed and authenticated: `gh auth status`.
  Your token needs `repo` read scope for the target org.
- [`jq`](https://jqlang.github.io/jq/) installed.

## Step 1 — Fetch your PRs

```bash
.claude/skills/cv-achievements/fetch-prs.sh --author <github-user> --org <org>
```

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `--author` | yes | — | GitHub username to fetch PRs for |
| `--org` | yes | — | GitHub org/owner to scope to |
| `--mode` | no | both | `authored-all` or `reviewed`; omit for both |
| `--out` | no | `.cv-data` | output base directory; files land under `<out>/<org>/` |

Output (gitignored, never committed) — files are scoped per org under `<out>/<org>/`:

- `.cv-data/<org>/prs-authored.json` — PRs you opened (any state) → "led / built" voice.
- `.cv-data/<org>/prs-reviewed.json` — your merged PRs + PRs you reviewed → "participated" voice.

Hundreds of PRs are fine — the script pages via GraphQL and sleeps/retries on
rate limits (up to 5 attempts before giving up). A large fetch may take a few
minutes. GitHub's search API caps any query at 1000 results; if a dataset hits
that ceiling the script prints a `Warning: ... INCOMPLETE` line on stderr —
narrow the query (e.g. by date range) if you see it.

### Examples

```bash
# Both datasets for one person in one org
.claude/skills/cv-achievements/fetch-prs.sh --author octocat --org acme

# Only the "led" dataset
.claude/skills/cv-achievements/fetch-prs.sh --author octocat --org acme --mode authored-all
```

## Step 2 — Generate bullets

Ask Claude to use the `cv-achievements` skill and point it at one JSON file, e.g.:

> Use the cv-achievements skill on `.cv-data/acme/prs-authored.json`.

The skill reads the `mode` field to pick the voice, analyzes the PRs, and prints
5–6 candidate bullets. It does **not** edit your CV yet.

## Step 3 — Insert into the CV

Review/edit the bullets. On your approval, the skill invokes the `update-cv`
skill to add them under the chosen job entry in `index.md` (branch → commit → PR).

## Notes

- Re-running a mode overwrites only its own JSON file.
- `.cv-data/` is gitignored. Don't commit it.
- Thin PR descriptions are kept as-is; significance is inferred from changed
  files, diffstat, and commit messages. No PR text is sent to a second model.
