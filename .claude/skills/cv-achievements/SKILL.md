---
name: cv-achievements
description: Use when turning a GitHub PR-activity JSON (produced by fetch-prs.sh) into CV achievement bullets for a job entry. Prints bullets for review only — does not fetch from GitHub and does not edit the CV.
---

# CV Achievements

Turn a PR-activity JSON file into a handful of CV achievement bullets (3–6 for
most roles, up to 7 for a long multi-year tenure with many distinct themes,
scaled to the role) for one job entry.

## Input contract

The user supplies a path produced by `fetch-prs.sh` — either ONE JSON file or the
`<out>/<org>/<author>/` **directory** that holds `prs-authored.json` and/or
`prs-reviewed.json`. Its shape:

```json
{ "generated_at": "...", "mode": "authored-all|reviewed",
  "author": "...", "org": "...",
  "incomplete": false, "incomplete_reasons": [],
  "pr_count": 0, "prs": [ ... ] }
```

This skill NEVER calls GitHub. If no path is supplied, ask for one and tell the
user to run `.claude/skills/cv-achievements/fetch-prs.sh --author <user> --org <org>` first.

**If the path is a directory** (or both files exist): default to
`prs-authored.json` — ownership voice is the stronger CV claim. Note that
`prs-reviewed.json` is also present and offer to process it afterward. Never
silently merge the two into one bullet set; each is its own `mode` run (see the
mode-reconciliation note in Step 3).

When `incomplete` is `true`, read `incomplete_reasons` and calibrate the warning
to the reason — do not blanket-warn (see the table below). Always print the
reasons so the user can judge.

| Reason pattern | Impact on bullets | What to tell the user |
|---|---|---|
| `file list truncated at 100 files` / `commit list truncated` | **Low** — `pr_count`, titles, labels intact; theme detection unaffected. Only the few huge PRs understate breadth. | One line: those N PRs are large; breadth is slightly undercounted. Proceed. |
| result cap / search-window / query truncation (whole PRs missing) | **High** — the dataset is genuinely partial. | Tell the user up front, suggest a narrower re-fetch before trusting counts; don't present bullets as a full account. |

## Step 1 — Read mode, pick voice

Read the top-level `mode` field:

| mode | Meaning | Voice (verbs) |
|---|---|---|
| `authored-all` | Work the author led/built | Ownership: Designed, Led, Built, Architected, Migrated, Automated |
| `reviewed` | Work the author joined as a team member | Contribution: Contributed to, Participated in, Supported, Helped deliver |

## Step 2 — Analyze prs[]

Bodies are usually empty and titles carry the ticket-style summary
(e.g. `INF-3184 Add new image versions for metrics-server and cluster-autoscaler`).
So the title tells you *what* a PR did; `files[]` tells you *which technology and
which subsystem* — the part a bullet needs to name a stack and group related work.
Use them together, with `files[]` as the sharpening signal, not the lead.

### 2a — Detect the tech stack from file extensions and paths

A PR's file extensions are a reliable fingerprint of the technology, even when the
title is terse. Map them to the stack you'd actually name on a CV:

| Signal in `files[].name` | Technology to name |
|---|---|
| `.tf`, `.hcl`, `.tftpl`, `.tf.json` | Terraform / Terragrunt (IaC) |
| `.ts` + `cdktf.json` under a CDK/infra path | CDKTF (TypeScript IaC) |
| `.yaml`/`.yml` under `playbooks/`, `roles/`, `inventory/` | Ansible |
| `.yaml`/`.yml` with k8s kinds, `charts/`, `Chart.yaml`, `values.yaml` | Kubernetes / Helm |
| `.github/workflows/*.yml` | GitHub Actions CI/CD |
| `.gitlab-ci.yml`, `.gitlab/` | GitLab CI |
| `*.sentinel`, `policies/`, `sentinel.hcl` | Policy-as-code / governance |
| `Dockerfile`, `*.dockerfile` | Docker / container images |
| `argocd/`, `applicationset`, `*.app.yaml` | ArgoCD / GitOps |
| `.go`, `go.mod`, `go.sum` | Go (compiled services / CLI tooling) |
| `.py` under `services/<name>/`, `adapters/`, `plugins/`, with `pyproject.toml`/`Pipfile` | Python application / backend service |
| `.py`, `.sh` as standalone scripts (`scripts/`, `tasks/`, root) | Python / Bash tooling and automation |
| `.vue`, `.jsx`/`.tsx`, `.scss`/`.css`, `.svelte` (genuine authorship — see caution below) | Frontend (Vue / React / etc.) |

Treat this as a starting map, not a closed list — these examples skew toward infra
because that's one author's stack, but the method is stack-agnostic: read whatever
the files plainly indicate (Go, Rust, Java, frontend, data pipelines, …) and name the
technology the *bulk* of a cluster's files point to.

Two judgment calls the extensions alone won't make:

- **Application vs. script.** `.py`/`.go` under a named `services/<name>/` (or
  `adapters/`, `plugins/`) directory, especially with build/manifest files, is a
  *shipped service* — a stronger CV claim than a one-off script in `scripts/`. The
  path tells you which; name it accordingly ("built a service" vs "wrote tooling").
- **Authored vs. generated/synth output.** Not every file in a PR was hand-written.
  Generated and vendored files inflate counts without proving skill: CDKTF emits
  `cdktf.out/*.json` (and `*.tf.json`) from a small `.ts` change; lockfiles
  (`*.lock.hcl`, `package-lock.json`, `go.sum`), a `terraform fmt` sweep, or a
  bulk `.vue`/`.tsx`/`.scss` rename all balloon file/line totals. Weigh the
  *authored source* — count the `.ts`/`.go`/`.py`/`.tf` a human wrote, not the
  emitted artifacts. A surge of generated or moved files in a *single* PR is the
  tell; confirm a real skill with the per-PR count of authored files across
  *several* PRs (the `any()` pattern below), not the raw file tally — one 30-file
  rename or a 500-file synth dump becomes a fake "major effort" otherwise.

### 2b — Cluster the work

- **Primary cluster key: top-level path prefix**, then `repository`. The directory a
  PR touches is usually the project boundary — `ecr/images/` + `ecr/charts/` is one
  "container image / ECR management" theme; `playbooks/` is an Ansible-automation
  theme; `.github/workflows/` is a CI theme — even across PRs with unrelated titles.
- Within a path cluster, group by recurring themes in `title` / `labels`.
- **Also cluster by named subject across repos/paths.** A single accomplishment
  often spans several locations: a service named `foo` might appear as app code in
  `services/foo/`, a `charts/foo/` Helm chart, an `argocd/foo` manifest, and the
  `deployments/foo` Terraform that runs it — across two or three repos. When the same
  name recurs, that's *one* end-to-end "designed, built, and shipped X" theme, a
  strong CV bullet. Don't fragment it into a separate bullet per repo.
- Merge clusters that describe the same accomplishment; a bullet is a *theme*, not a PR.

When counting how many PRs fall in a cluster with `jq`, match at the PR level with
`any(...)`, not a bare `.files[]` predicate — the latter iterates files and counts a
PR once *per matching file*, badly inflating large clusters. Use:
`[ .prs[] | select(any(.files[]?.name; test("^deployments/cloudflare"))) ] | length`

Starter recon block — run these first to surface clusters before reading titles
(`$F` = the JSON path):

```bash
# repos and tenure window
jq -r '[.prs[].repository]|group_by(.)|map({r:.[0],n:length})|sort_by(-.n)|.[][]' "$F"
jq -r '[.prs[].mergedAt // .prs[].createdAt]|min,max' "$F"
# PR-level histogram of top-level path prefixes (NOT file-level — see any() above)
jq -r '[.prs[]|[.files[]?.name|split("/")[0]]|unique[]]|group_by(.)|map({p:.[0],n:length})|sort_by(-.n)|.[][]' "$F"
# count PRs matching one cluster regex
jq -r '[.prs[]|select(any(.files[]?.name; test("REGEX")))]|length' "$F"
```

Note the inner `unique` in the histogram — it dedups paths *within* a PR so each
PR contributes at most once per prefix (a file-level `split` would re-inflate).

### 2c — Weight clusters (what's CV-worthy)

- **Breadth of meaningful change** is the strongest signal: distinct non-trivial
  files across multiple repos/subsystems > one large auto-generated or vendored file.
- Then: PR count in the cluster, recency (`mergedAt`/`createdAt`), and presence of
  governance/quality artifacts (`*.sentinel`, `CODEOWNERS`, `.pre-commit-config.*`)
  which signal "established standards/compliance," a CV-worthy theme in itself.
- Treat raw `additions`+`deletions` as a *weak* proxy only — a 2000-line diff can be
  a single `terraform fmt` or a lockfile regen. Let `files[]` sanity-check linecounts.

### 2d — Discard noise

A PR is noise if `files[]` and `title` show no substantive change. Drop it when:

- Every file is config/lint/format/test scaffolding only — matches just
  `.pre-commit-config.*`, `.yamllint`, `.yamlfmt`, `.editorconfig`, `*.md`, or `test_*`.
- It's a dependency/version bump, a revert, or a typo/whitespace fix.
- The title flags it as non-work: `DO NOT MERGE`, `Test `, `WIP`, `Fix mistake`,
  `Revert`, `bump`.

### 2e — Grounding

For thin/empty `body`, infer the change from `files[].name` + `commits[].message` +
diffstat — and state only what those plainly support. Name the stack and subsystem
(files prove those); do **not** invent outcomes (cost %, SLA, audit results) that the
data cannot show. If a cluster's impact is unclear, describe the work plainly.

## Step 3 — Produce bullets

- Aim for 3–6 bullets, scaled to tenure and signal. A short stint or thin
  dataset should get fewer (2–3); a multi-year role carries 5–6. A long tenure
  (5+ years) with many genuinely distinct themes can run to 7 — but only when
  each extra bullet is its own real accomplishment, not padding. The rule is
  one-bullet-per-theme, not a target count: if merging two thin themes reads
  stronger, merge them; never split one accomplishment to hit a number.
- Match the existing `index.md` job-entry style: `-` bullets, action-verb first, past tense, impact-oriented.
- No PR numbers, no URLs, no repo names in the bullet text.
- Each bullet = one distinct theme. Merge overlapping clusters.
- Use the voice chosen in Step 1.
- Ground every claim in the data. State only impact you can support from
  titles, labels, files, commit messages, and diffstat. If a cluster's impact is
  unclear, describe the work plainly rather than inventing an outcome.

**Reconciling `authored` and `reviewed`.** When both modes exist for the same
author, their themes usually *mirror* — the person who builds a subsystem also
reviews changes to it. Keep the sets separate and pick **one framing per CV
entry**: ownership (`authored`) reads stronger and is the default. Only pull a
reviewed bullet in to make a distinct collaboration/mentorship/gatekeeping point
(e.g. "core reviewer for the platform"), and never claim the same accomplishment
twice across the two voices — that double-counts one body of work.

## Step 4 — Output only

1. Print the candidate bullets, grouped under the target job entry (ask the user
   which job if ambiguous).
2. Stop. This skill does NOT edit `index.md` and does NOT call any other skill.
   If the user wants the bullets inserted into the CV, that is a separate,
   explicit step they take afterward.
