---
name: update-cv
description: Guided workflow for editing index.md — the CV content file. Use when updating work history, skills, education, contact info, tailoring the CV to a specific job posting, or any other CV content change. Handles editing, build verification, and commit.
---

## Update CV Workflow

All CV content lives in `index.md`. Do not edit any other file unless changing style or layout.

This repo holds **Avi Langburd's own CV**. Only run this workflow for langburd's CV. If you are generating CV bullets for a different GitHub user (e.g. via `cv-achievements`), do not edit `index.md` — those bullets belong to someone else's CV.

### Structure of index.md

```markdown
---
layout: cv
title: Avi Langburd's CV
---
# Avi Langburd
<subtitle line>

<div id="webaddress">...</div>

## Section Heading

`date-range`
**Role/Title**
Employer

Description text.

## Another Section
```

Key conventions:
- Date ranges use backtick formatting: `` `2020-2024` ``
- Job titles use `**bold**`
- Sections use `##` headings
- Sub-groupings use `###` headings
- Bullet lists use `-` for skill lists
- Verb tense follows the role's timeline so the reader can tell current work from past at a glance. The current role (date range ending in `Now`) uses present-continuous leading verbs (`Designing`, `Building`, `Architecting`). Every past role uses simple past (`Designed`, `Built`, `Architected`). When editing a bullet, match the tense of its job block — and if a block is mixed, normalize the whole block, not just the line you touched.
- Multiline content inside the contact `<div>` and other HTML blocks uses `<br>`. Prose is human, first-person where it fits; avoid AI tells (em-dash overuse, rule-of-three lists, phrases lifted verbatim from a job posting). Em dashes already appear in the existing bullets and are fine in moderation — just don't pile three into one sentence.

### Steps

1. Branch off `master`. Name by intent:
   - Ordinary content edit: `cv/<short-description>` (e.g. `cv/add-go-skill`)
   - Tailoring the CV to a specific job: `<date>-<company>-<position>` (e.g. `2026-06-24-rapyd-senior-devops-infra`), so each tailored variant lives on its own branch and `master` stays the canonical CV.
   ```bash
   git checkout -b <branch-name>
   ```
2. Read current `index.md` to understand existing structure before making changes
3. Make the requested edits — surgical changes only, preserve the formatting conventions above
4. Verify the build before committing. A broken Liquid tag or bad front matter fails the GitHub Pages build silently, so catch it locally:
   ```bash
   jekyll build
   ```
   It should end with `done in …`. If `jekyll` is not found, the binary lives at `/opt/terraspace/embedded/bin/jekyll` — add it to PATH. For a visual check, `jekyll serve` then open http://localhost:4000.
5. Commit on the branch:
   ```bash
   git add index.md
   git commit -m "cv: <describe what changed>"
   ```
6. Stop here unless the user asks to publish. Pushing and merging changes the live site, so only push when the user explicitly says so (e.g. "push it", "open the PR"). Never push straight to `master`. When asked to publish:
   ```bash
   git push origin HEAD
   ```
   Then open a PR targeting `master`. GitHub Pages rebuilds automatically after merge (~60 seconds); confirm it rebuilt.
7. After committing, ask the user whether they want a PDF of the updated CV. If yes, follow **Exporting a PDF** below.

### Exporting a PDF

The PDF must look like the CV as a browser renders and prints it — the print stylesheet (`media/langburd-print.css`) applied to the rendered HTML, not the raw Markdown. Anything that converts `index.md` directly to PDF will lose the layout and is wrong.

Use the `pdf` skill to produce the file, feeding it the print-rendered HTML:

1. Build the site and start the Jekyll server (Chrome must print from a live HTTP server, not a file path):
   ```bash
   /opt/terraspace/embedded/bin/jekyll build
   /opt/terraspace/embedded/bin/jekyll serve --detach --port 4000
   sleep 2 && curl -s -o /dev/null -w "%{http_code}" http://localhost:4000  # verify 200
   ```
2. Print to PDF using Chrome headless with print media emulation. Use `--headless=new` and `--no-pdf-header-footer` — the older `--print-to-pdf-no-header` flag does not suppress headers/footers:
   ```bash
   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
     --headless=new --disable-gpu \
     --no-pdf-header-footer \
     --print-to-pdf="<output-path>.pdf" \
     --virtual-time-budget=5000 \
     --run-all-compositor-stages-before-draw \
     --emulate-media="print" \
     "http://localhost:4000"
   pkill -f jekyll
   ```
3. Name the file `Avi_Langburd_CV_<year>[_<company>].pdf` — include the company suffix when the CV was tailored to a posting (e.g. `Avi_Langburd_CV_2026_Rapyd.pdf`), and omit it for a general update (`Avi_Langburd_CV_2026.pdf`).
4. Save it to the repo root, then tell the user the path. The PDF is a generated artifact, so do not commit it (and don't let `git add .` sweep it in — `*.pdf` is not currently in `.gitignore`).

### Tailoring to a job posting

When the request is to adapt the CV to a specific role, the goal is to surface the experience that matches that posting without inventing anything:

- Pull the must-have requirements from the posting and lead with the matching skills and bullets. Reorder the skills list so the most relevant categories come first.
- Mirror the posting's real keywords where they are genuinely true (e.g. a payments role → call out PCI DSS work), but never claim experience the CV does not already support. Tailoring is re-emphasis, not fabrication.
- Keep edits on a dedicated tailoring branch (see step 1) and leave `master` untouched.
