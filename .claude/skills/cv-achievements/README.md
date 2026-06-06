# cv-achievements

Generate CV achievement bullets for a job entry from your real GitHub PR
activity. Reusable for any GitHub user, any org, and any job.

## Pieces

| File | Role |
|---|---|
| `fetch-prs.sh` | Fetches PR activity into JSON. Run it yourself. |
| `SKILL.md` | Claude skill: reads the JSON and prints candidate bullets for review. |

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
| `--out` | no | `.cv-data` | output base directory; files land under `<out>/<org>/<author>/` (default `.cv-data/<org>/<author>/`) |

Output (gitignored, never committed) — files are scoped per org and author under `<out>/<org>/<author>/`:

- `.cv-data/<org>/<author>/prs-authored.json` — PRs you opened (any state) → "led / built" voice.
- `.cv-data/<org>/<author>/prs-reviewed.json` — PRs by *others* that you reviewed (your own PRs are excluded, so the two files don't overlap) → "participated" voice.

Thousands of PRs are fine — the script pages via GraphQL and sleeps/retries on
rate limits (up to 5 attempts before giving up). GitHub's search API caps any
single query at 1000 results, so the script partitions each query into UTC date
windows and recursively bisects any window that hits the cap, then merges and
de-duplicates — the full history is collected even past 1000. The extra windowed
queries make a large fetch take a few minutes.

If a dataset is still partial, the script prints a `Warning:` line on stderr
**and** stamps `"incomplete": true` plus `"incomplete_reasons": [...]` into the
JSON, so the skill can flag it too. Remaining causes:

- A PR with more than 100 files or 100 commits has its file/commit list
  truncated (sub-connections are not paged).
- A single calendar day with more than 1000 matching PRs — unsplittable, so that
  day is truncated. Astronomically unlikely for one author.

### Examples

```bash
# Both datasets for one person in one org
.claude/skills/cv-achievements/fetch-prs.sh --author octocat --org acme

# Only the "led" dataset
.claude/skills/cv-achievements/fetch-prs.sh --author octocat --org acme --mode authored-all
```

## Step 2 — Generate bullets

Ask Claude to use the `cv-achievements` skill and point it at one JSON file, e.g.:

> Use the cv-achievements skill on `.cv-data/acme/octocat/prs-authored.json`.

The skill reads the `mode` field to pick the voice, analyzes the PRs, and prints
candidate bullets (3–6, scaled to the role). It does **not** edit your CV — it
only prints bullets for review.

## Step 3 — Insert into the CV (manual)

Review/edit the printed bullets, then add the ones you want under the relevant
job entry in `index.md` yourself (or ask Claude to, as a separate explicit step).
This pipeline stops at "here are the candidate bullets."

## Notes

- Re-running a mode overwrites only its own JSON file.
- `.cv-data/` is gitignored. Don't commit it.
- Thin PR descriptions are kept as-is; significance is inferred from changed
  files, diffstat, and commit messages. No PR text is sent to a second model.
