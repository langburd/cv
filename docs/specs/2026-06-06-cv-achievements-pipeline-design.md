# CV Achievements Pipeline — Design

**Date:** 2026-06-06
**Status:** Approved (design)
**Goal:** Generate accurate, well-phrased achievement bullets for a job entry on the CV, derived from real GitHub PR activity instead of memory.

## Problem

A current/recent job entry in `index.md` often has **no achievement bullets**, even though years of work and hundreds of PRs exist in GitHub. Recalling that work by hand is lossy and biased toward recent memory. This pipeline reconstructs achievements from the actual PR record, and is reusable for any job (any author, any org).

## Solution Overview

Two fully decoupled pieces sharing only a JSON file contract:

```
┌─────────────────────────┐         ┌───────────────────────────┐
│  fetch-prs.sh (manual)  │  JSON   │  SKILL.md (cv-achievements) │
│  fetch → throttle → save│ ──────► │  read JSON → analyze →      │
│  knows nothing of skill │  file   │  bullets → update-cv        │
└─────────────────────────┘         └───────────────────────────┘
```

- **Script** does *all* mechanical work: fetch, paginate, throttle, save. Run manually by the user.
- **Skill** does *all* analysis: read a supplied JSON, produce bullets, hand off to `update-cv`.
- Neither invokes the other. The script never analyzes; the skill never calls GitHub.

## Strict Labor Split

| Concern | Owner |
|---|---|
| GitHub API calls, paging, rate-limit handling | `fetch-prs.sh` only |
| Choosing what data to keep (fields) | `fetch-prs.sh` only |
| Reading JSON, judging significance, wording bullets | skill / agent only |
| Editing `index.md` | existing `update-cv` skill only |

## Component 1 — `fetch-prs.sh`

**Stack:** Bash + `gh` CLI. No deps, no PAT handling (relies on an authenticated `gh`), no build tools. Matches the repo's minimal ethos.

**Arguments:**

| Flag | Required | Default | Purpose |
|---|---|---|---|
| `--author <user>` | yes | — | GitHub username to fetch PRs for. Enables reuse for any person/job. |
| `--org <org>` | yes | — | GitHub org/owner to scope the search to. |
| `--mode authored-all \| reviewed` | no | both | Which narrative dataset(s) to produce (see below). Omit to produce both. |
| `--out <dir>` | no | `.cv-data/` | Output directory for the JSON file(s). |

**Modes (mutually exclusive per fetch; together when no flag given):**

| Invocation | Produces | Narrative angle |
|---|---|---|
| `--mode authored-all` | `prs-authored.json` | Projects the author **led / built / drove** — ownership voice |
| `--mode reviewed` | `prs-reviewed.json` | Projects the author **joined as a team member** — contribution voice |
| *(no `--mode`)* | both files | runs both fetches sequentially |

- `authored-all` = all PRs authored by `--author`, **any state** (open, closed, merged).
- `reviewed` = merged PRs authored by `--author` **plus** PRs reviewed by `--author` (team participation signal).

**Per-PR fields extracted:**
`number, title, body, url, state, repository, createdAt, mergedAt/closedAt, labels, additions, deletions, changedFiles, files[{name, additions, deletions}], commits[{message}]`

**Explicitly NOT collected:** full diffs/patches, AI-enriched descriptions. No second model is called anywhere. Thin descriptions are left thin — the analyzing agent infers significance from diffstat + filenames + commit messages.

**Output wrapper (single JSON object per file):**

```json
{
  "generated_at": "<ISO8601, stamped by script>",
  "mode": "authored-all | reviewed",
  "author": "<--author value>",
  "org": "<--org value>",
  "pr_count": 0,
  "prs": [ { /* fields above */ } ]
}
```

The `mode` field is the contract the skill reads to choose its voice. `author`/`org` are stamped from the arguments for provenance.

### Rate-limit handling (verified necessary)

During design, GitHub's **secondary rate limit** was tripped with only a handful of search calls. With hundreds of PRs, a naive `1 list + N detail` REST loop will trip it reliably. Therefore:

- Use **GraphQL** (`gh api graphql`) batched queries. Diffstat fields (`additions`, `deletions`, `changedFiles`, `files`) live on the PR node, so list + detail come in one paged query — not `1 + N` calls.
- Page with a `cursor`, ~50 PRs/page.
- On `HTTP 403` secondary-limit or primary-limit exhaustion: read the reset/`Retry-After`, `sleep`, then resume.
- Writes should be safe to re-run (re-running a mode overwrites its own file cleanly).

## Component 2 — `SKILL.md` (`cv-achievements`)

**Input:** a JSON path supplied by the user (one of the produced files).

**Behavior:**
1. Read the wrapper; take `mode` → select voice:
   - `authored-all` → ownership verbs: *Designed, Led, Built, Architected, Migrated, Automated*.
   - `reviewed` → contribution verbs: *Contributed to, Participated in, Supported, Helped deliver*.
2. Analyze `prs[]`: cluster by repository / labels / recurring themes; weight by change size and recency; discard noise (dependency bumps, typo fixes, reverts, trivial config).
3. Produce **5–6** candidate bullets (a sensible cap for a top role; the user can request fewer for shorter tenures).
4. Style-match the target job's section in `index.md`: `-` bullets, action-verb-led, past tense, impact-oriented, no PR numbers/links in the bullet text.

**Output / handoff:**
- Print the candidate bullets for review.
- User edits/approves.
- On approval, invoke the existing `update-cv` skill to insert them under the relevant job entry (branch → edit `index.md` → commit → PR). This skill does **not** edit `index.md` itself.

## Files

```
.claude/skills/cv-achievements/
├── SKILL.md
└── fetch-prs.sh
```

Data files live in a gitignored directory **inside the repo**: `.cv-data/`. Added to `.gitignore`. Never committed, never served by GitHub Pages.

## Out of Scope (YAGNI)

- Per-PR AI enrichment / any second model.
- Full diff/patch extraction.
- The skill auto-running the fetch script.
- Auto-inserting bullets into `index.md` without a human review gate.
- Hardcoding any author, org, or job — all are parameters/inputs.

## Verification Criteria

- `./fetch-prs.sh --author <user> --org <org> --mode authored-all` writes a valid `prs-authored.json` with a populated `prs[]` and correct `mode`/`author`/`org`/`pr_count`.
- `./fetch-prs.sh --author <user> --org <org>` with no `--mode` writes **both** JSON files.
- Missing `--author` or `--org` exits with a clear usage error.
- A full fetch of several hundred PRs completes **without** an unhandled `403` secondary-limit abort.
- The skill, given a `prs-authored.json`, emits ownership-voice bullets in `index.md` style and stops for review before any edit.
- `.cv-data/` is gitignored; no data file is tracked by git.
