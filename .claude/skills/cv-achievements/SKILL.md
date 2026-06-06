---
name: cv-achievements
description: Use when turning a GitHub PR-activity JSON (produced by fetch-prs.sh) into CV achievement bullets for a job entry. Prints bullets for review only — does not fetch from GitHub and does not edit the CV.
---

# CV Achievements

Turn a PR-activity JSON file into a handful of CV achievement bullets (3–6, scaled
to the role) for one job entry.

## Input contract

The user supplies a path to ONE JSON file produced by `fetch-prs.sh` (written to
`<out>/<org>/<author>/prs-authored.json` or `<out>/<org>/<author>/prs-reviewed.json`). Its shape:

```json
{ "generated_at": "...", "mode": "authored-all|reviewed",
  "author": "...", "org": "...",
  "incomplete": false, "incomplete_reasons": [],
  "pr_count": 0, "prs": [ ... ] }
```

This skill NEVER calls GitHub. If no JSON path is supplied, ask for one and tell the
user to run `.claude/skills/cv-achievements/fetch-prs.sh --author <user> --org <org>` first.

If `incomplete` is `true`, tell the user up front that the dataset is partial
(print `incomplete_reasons`), so they can re-fetch a narrower query before
trusting the bullets. Do not present bullets from an incomplete dataset as a
full account of the work.

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
- **Real frontend vs. bulk file moves.** A surge of `.vue`/`.tsx`/`.scss` in a
  *single* PR is usually a rename, vendoring, or generated bundle — not authorship.
  Only claim frontend skill when real frontend files are *authored across several
  PRs*. Confirm with the per-PR count (the `any()` pattern below), not the raw file
  tally — one 30-file rename inflates a bare extension count into a fake "major effort."

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

- Aim for 3–6 bullets, scaled to tenure and signal: a multi-year top role can
  carry 5–6; a short stint or thin dataset should get fewer (2–3). Do not pad to
  hit a count.
- Match the existing `index.md` job-entry style: `-` bullets, action-verb first, past tense, impact-oriented.
- No PR numbers, no URLs, no repo names in the bullet text.
- Each bullet = one distinct theme. Merge overlapping clusters.
- Use the voice chosen in Step 1.
- Ground every claim in the data. State only impact you can support from
  titles, labels, files, commit messages, and diffstat. If a cluster's impact is
  unclear, describe the work plainly rather than inventing an outcome.

## Step 4 — Output only

1. Print the candidate bullets, grouped under the target job entry (ask the user
   which job if ambiguous).
2. Stop. This skill does NOT edit `index.md` and does NOT call any other skill.
   If the user wants the bullets inserted into the CV, that is a separate,
   explicit step they take afterward.
