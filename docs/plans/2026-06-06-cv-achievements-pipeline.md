# CV Achievements Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a manually-run Bash fetch script that pulls a GitHub user's PR activity in an org into structured JSON, plus a `cv-achievements` skill that turns that JSON into CV achievement bullets and hands off to `update-cv`.

**Architecture:** Two fully decoupled units sharing only a JSON file contract. `fetch-prs.sh` does all GitHub I/O via `gh api graphql` (batched, rate-limit-aware) and writes a self-describing JSON wrapper to a gitignored `.cv-data/` dir. `SKILL.md` reads a supplied JSON, picks a voice from the `mode` field, and produces bullets — it never touches GitHub.

**Tech Stack:** Bash, `gh` CLI (GraphQL API), `jq` for JSON shaping/validation. No test runtime in this repo (system Jekyll, no Gemfile/npm), so verification is shell-level: smoke-running the script against a real org/author and validating output with `jq`.

---

## File Structure

```
.claude/skills/cv-achievements/
├── SKILL.md          # analysis contract: JSON in → bullets out → update-cv handoff
├── fetch-prs.sh      # mechanical fetch: gh graphql → throttle → .cv-data/*.json
└── README.md         # human-facing usage docs for the script + skill
.gitignore            # add .cv-data/
```

- `fetch-prs.sh` — single responsibility: arg parsing + GraphQL fetch + rate-limit retry + JSON write. No analysis.
- `SKILL.md` — single responsibility: read JSON, judge significance, word bullets, hand off. No fetching.
- `README.md` — single responsibility: tell a human how to run the script and invoke the skill end to end.
- `.cv-data/` — gitignored runtime output. Never committed, never served.

---

## Task 1: Gitignore the data dir

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Read current .gitignore**

Run: `cat .gitignore`
Note the existing entries so the new line matches style (no leading slash if existing entries omit it).

- [ ] **Step 2: Append the data dir entry**

Add this line to `.gitignore`:

```
.cv-data/
```

- [ ] **Step 3: Verify it is ignored**

Run:
```bash
mkdir -p .cv-data && touch .cv-data/probe.json && git status --porcelain .cv-data
```
Expected: **no output** (the dir is ignored). Then clean up: `rm -rf .cv-data`.

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore .cv-data pipeline output dir"
```

---

## Task 2: Script skeleton + argument parsing

**Files:**
- Create: `.claude/skills/cv-achievements/fetch-prs.sh`

- [ ] **Step 1: Write the skeleton with arg parsing and usage**

Create `.claude/skills/cv-achievements/fetch-prs.sh`:

```bash
#!/usr/bin/env bash
# Fetch a GitHub user's PR activity in an org into structured JSON for CV bullet generation.
# Mechanical only: no analysis, no second model, no full diffs.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: fetch-prs.sh --author <user> --org <org> [--mode authored-all|reviewed] [--out <dir>]

  --author <user>   GitHub username to fetch PRs for (required)
  --org <org>       GitHub org/owner to scope the search to (required)
  --mode <mode>     authored-all | reviewed. Omit to produce BOTH datasets.
  --out <dir>       Output directory (default: .cv-data)

Produces:
  authored-all -> <out>/prs-authored.json   (any-state PRs the author opened)
  reviewed     -> <out>/prs-reviewed.json    (author's merged PRs + PRs they reviewed)
USAGE
}

AUTHOR="" ORG="" MODE="" OUT=".cv-data"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --author) AUTHOR="${2:-}"; shift 2 ;;
    --org)    ORG="${2:-}"; shift 2 ;;
    --mode)   MODE="${2:-}"; shift 2 ;;
    --out)    OUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$AUTHOR" || -z "$ORG" ]]; then
  echo "Error: --author and --org are required." >&2
  usage; exit 2
fi

if [[ -n "$MODE" && "$MODE" != "authored-all" && "$MODE" != "reviewed" ]]; then
  echo "Error: --mode must be 'authored-all' or 'reviewed'." >&2
  exit 2
fi

mkdir -p "$OUT"
echo "stub: author=$AUTHOR org=$ORG mode=${MODE:-both} out=$OUT" >&2
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x .claude/skills/cv-achievements/fetch-prs.sh`

- [ ] **Step 3: Test missing-args error**

Run: `.claude/skills/cv-achievements/fetch-prs.sh --author foo; echo "exit=$?"`
Expected: prints `Error: --author and --org are required.` + usage, `exit=2`.

- [ ] **Step 4: Test bad mode error**

Run: `.claude/skills/cv-achievements/fetch-prs.sh --author foo --org bar --mode wrong; echo "exit=$?"`
Expected: prints `Error: --mode must be 'authored-all' or 'reviewed'.`, `exit=2`.

- [ ] **Step 5: Test happy-path stub**

Run: `.claude/skills/cv-achievements/fetch-prs.sh --author foo --org bar`
Expected: prints `stub: author=foo org=bar mode=both out=.cv-data` to stderr, creates `.cv-data/`. Then `rm -rf .cv-data`.

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/cv-achievements/fetch-prs.sh
git commit -m "feat: add fetch-prs.sh skeleton with arg parsing"
```

---

## Task 3: Rate-limit-aware GraphQL paging helper

**Files:**
- Modify: `.claude/skills/cv-achievements/fetch-prs.sh`

The GitHub search-issues GraphQL connection returns PR nodes with diffstat fields, so one paged query covers list + detail. This task adds a function that pages through a GraphQL `search` query and prints the collected PR nodes as a JSON array, sleeping/retrying on rate-limit errors.

- [ ] **Step 1: Add the paging function**

Insert this function into `fetch-prs.sh` after the arg-validation block (before the final `echo "stub..."` line, which you will remove in Task 4):

```bash
# fetch_search QUERY_STRING
# Pages a GraphQL `search(type: ISSUE)` over QUERY_STRING and prints a JSON array
# of PR nodes (with diffstat, labels, files, commits). Rate-limit aware.
fetch_search() {
  local query="$1"
  local cursor="null"
  local has_next="true"
  local all="[]"

  local gql='
    query($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            number title body url state
            createdAt mergedAt closedAt
            additions deletions changedFiles
            repository { nameWithOwner }
            labels(first: 20) { nodes { name } }
            files(first: 100) { nodes { path additions deletions } }
            commits(first: 100) { nodes { commit { message } } }
          }
        }
      }
    }'

  while [[ "$has_next" == "true" ]]; do
    local resp
    if ! resp=$(gh api graphql -f query="$gql" -f q="$query" \
                  -F after="$cursor" 2>/tmp/fetch_prs_err); then
      if grep -qiE 'rate limit|secondary' /tmp/fetch_prs_err; then
        echo "Rate limited; sleeping 60s then retrying..." >&2
        sleep 60
        continue
      fi
      cat /tmp/fetch_prs_err >&2
      return 1
    fi

    local nodes
    nodes=$(jq '.data.search.nodes' <<<"$resp")
    all=$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$nodes"))

    has_next=$(jq -r '.data.search.pageInfo.hasNextPage' <<<"$resp")
    cursor=$(jq -r '.data.search.pageInfo.endCursor' <<<"$resp")
    [[ "$cursor" == "null" ]] && break
  done

  echo "$all"
}
```

- [ ] **Step 2: Add a temporary smoke driver at the end of the script**

Temporarily append (will be replaced in Task 4):

```bash
# TEMP smoke driver — remove in Task 4
fetch_search "is:pr author:$AUTHOR org:$ORG" | jq 'length'
```

- [ ] **Step 3: Smoke test against a real author/org**

Run (substitute your own GitHub username and an org you have PRs in):
```bash
.claude/skills/cv-achievements/fetch-prs.sh --author <your-user> --org <your-org>
```
Expected: after possibly one or more "Rate limited; sleeping" lines, prints an integer count of PRs (e.g. `589`). No `set -e` abort, no raw GraphQL error dump.

- [ ] **Step 4: Verify node shape**

Edit the temp driver line to inspect one node:
```bash
fetch_search "is:pr author:$AUTHOR org:$ORG" | jq '.[0] | {number, title, repository: .repository.nameWithOwner, additions, changedFiles, files: (.files.nodes | length)}'
```
Run the script again. Expected: a JSON object with non-null `number`, `title`, `repository`, numeric `additions`/`changedFiles`. Revert the driver line back to `| jq 'length'` after confirming.

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/cv-achievements/fetch-prs.sh
git commit -m "feat: add rate-limit-aware GraphQL paging to fetch-prs.sh"
```

---

## Task 4: Normalize nodes + write the JSON wrapper

**Files:**
- Modify: `.claude/skills/cv-achievements/fetch-prs.sh`

Reshape raw GraphQL nodes into the spec's flat per-PR schema and wrap with provenance metadata. The `generated_at` timestamp is taken from `date` at runtime (allowed in a shell script; only the workflow JS runtime forbids clocks).

- [ ] **Step 1: Add the write_dataset function**

Insert after `fetch_search` (and remove the temp smoke driver from Task 3):

```bash
# write_dataset MODE QUERY OUTFILE
# Fetches, normalizes to the flat per-PR schema, and writes the wrapped JSON.
write_dataset() {
  local mode="$1" query="$2" outfile="$3"
  echo "Fetching mode=$mode ..." >&2

  local raw normalized
  raw=$(fetch_search "$query")

  normalized=$(jq '[ .[] | {
    number, title, body, url, state,
    repository: .repository.nameWithOwner,
    createdAt, mergedAt, closedAt,
    labels: [ .labels.nodes[].name ],
    additions, deletions, changedFiles,
    files:   [ .files.nodes[]   | {name: .path, additions, deletions} ],
    commits: [ .commits.nodes[] | {message: .commit.message} ]
  } ]' <<<"$raw")

  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg mode "$mode" \
    --arg author "$AUTHOR" \
    --arg org "$ORG" \
    --argjson prs "$normalized" \
    '{generated_at: $generated_at, mode: $mode, author: $author, org: $org,
      pr_count: ($prs | length), prs: $prs}' > "$outfile"

  echo "Wrote $(jq '.pr_count' "$outfile") PRs -> $outfile" >&2
}
```

- [ ] **Step 2: Add the mode dispatch at the end of the script**

Append:

```bash
run_authored() {
  write_dataset "authored-all" "is:pr author:$AUTHOR org:$ORG" "$OUT/prs-authored.json"
}
run_reviewed() {
  write_dataset "reviewed" "is:pr org:$ORG ( author:$AUTHOR is:merged OR reviewed-by:$AUTHOR )" "$OUT/prs-reviewed.json"
}

case "$MODE" in
  authored-all) run_authored ;;
  reviewed)     run_reviewed ;;
  "")           run_authored; run_reviewed ;;
esac
```

- [ ] **Step 3: Run authored-all and validate the wrapper**

Run:
```bash
.claude/skills/cv-achievements/fetch-prs.sh --author <your-user> --org <your-org> --mode authored-all
jq '{generated_at, mode, author, org, pr_count, sample: .prs[0].title}' .cv-data/prs-authored.json
```
Expected: `mode` is `"authored-all"`, `author`/`org` match your args, `pr_count` > 0, `sample` is a real PR title.

- [ ] **Step 4: Validate per-PR schema completeness**

Run:
```bash
jq '.prs[0] | keys' .cv-data/prs-authored.json
```
Expected keys (order may vary): `additions, body, changedFiles, closedAt, commits, createdAt, deletions, files, labels, mergedAt, number, repository, state, title, url`.

- [ ] **Step 5: Run no-mode and confirm BOTH files appear**

Run:
```bash
rm -f .cv-data/prs-*.json
.claude/skills/cv-achievements/fetch-prs.sh --author <your-user> --org <your-org>
ls -1 .cv-data/
```
Expected: both `prs-authored.json` and `prs-reviewed.json` exist; `jq .mode` on each prints the matching mode.

- [ ] **Step 6: Confirm data stays untracked**

Run: `git status --porcelain .cv-data`
Expected: **no output**.

- [ ] **Step 7: Commit**

```bash
git add .claude/skills/cv-achievements/fetch-prs.sh
git commit -m "feat: normalize PR nodes and write wrapped JSON datasets"
```

---

## Task 5: Write the cv-achievements SKILL.md

**Files:**
- Create: `.claude/skills/cv-achievements/SKILL.md`

This is documentation/instructions for the analyzing agent, not executable code. It must encode: input contract, voice selection from `mode`, analysis heuristics, output format, and the `update-cv` handoff with a human gate.

- [ ] **Step 1: Write SKILL.md**

Create `.claude/skills/cv-achievements/SKILL.md`:

````markdown
---
name: cv-achievements
description: Use when turning a GitHub PR-activity JSON (produced by fetch-prs.sh) into CV achievement bullets for a job entry, then handing the approved bullets to the update-cv skill. Does not fetch from GitHub itself.
---

# CV Achievements

Turn a PR-activity JSON file into 5–6 CV achievement bullets for one job entry.

## Input contract

The user supplies a path to ONE JSON file produced by `fetch-prs.sh`. Its shape:

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
````

- [ ] **Step 2: Validate the frontmatter parses**

Run:
```bash
head -5 .claude/skills/cv-achievements/SKILL.md
```
Expected: a `---` delimited block with `name: cv-achievements` and a `description:` line.

- [ ] **Step 3: Confirm referenced skill exists**

Run: `ls .claude/skills/update-cv/SKILL.md`
Expected: file exists (the handoff target is real).

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/cv-achievements/SKILL.md
git commit -m "feat: add cv-achievements skill for PR-to-bullet analysis"
```

---

## Task 6: Write the README.md usage docs

**Files:**
- Create: `.claude/skills/cv-achievements/README.md`

Human-facing instructions: prerequisites, how to run the script, how to invoke the skill, and the full flow. Documentation only — no code paths to test beyond confirming the commands shown match what the script actually accepts.

- [ ] **Step 1: Write README.md**

Create `.claude/skills/cv-achievements/README.md`:

````markdown
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
| `--out` | no | `.cv-data` | output directory |

Output (gitignored, never committed):

- `.cv-data/prs-authored.json` — PRs you opened (any state) → "led / built" voice.
- `.cv-data/prs-reviewed.json` — your merged PRs + PRs you reviewed → "participated" voice.

Hundreds of PRs are fine — the script pages via GraphQL and sleeps/retries on
rate limits. A large fetch may take a few minutes.

### Examples

```bash
# Both datasets for one person in one org
.claude/skills/cv-achievements/fetch-prs.sh --author octocat --org acme

# Only the "led" dataset
.claude/skills/cv-achievements/fetch-prs.sh --author octocat --org acme --mode authored-all
```

## Step 2 — Generate bullets

Ask Claude to use the `cv-achievements` skill and point it at one JSON file, e.g.:

> Use the cv-achievements skill on `.cv-data/prs-authored.json`.

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
````

- [ ] **Step 2: Confirm documented flags match the script**

Run:
```bash
.claude/skills/cv-achievements/fetch-prs.sh --help
```
Expected: usage lists exactly `--author`, `--org`, `--mode`, `--out` — same as the README table. Fix either side if they drift.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/cv-achievements/README.md
git commit -m "docs: add cv-achievements README usage guide"
```

---

## Task 7: End-to-end dry run

**Files:** none (verification only)

- [ ] **Step 1: Full pipeline smoke**

Run:
```bash
rm -f .cv-data/prs-*.json
.claude/skills/cv-achievements/fetch-prs.sh --author <your-user> --org <your-org>
jq '.pr_count, .mode' .cv-data/prs-authored.json .cv-data/prs-reviewed.json
```
Expected: both files report a positive `pr_count` and the correct `mode`.

- [ ] **Step 2: Confirm nothing leaked into git**

Run: `git status --porcelain`
Expected: only tracked changes are the committed script/skill/gitignore — no `.cv-data/` entries.

- [ ] **Step 3: Final commit (if any cleanup needed)**

Only if Step 2 surfaced stray tracked files; otherwise skip. The pipeline is complete.
