---
name: update-cv
description: Guided workflow for editing index.md — the CV content file. Use when updating work history, skills, education, contact info, or any CV content. Handles editing, verification, commit, and push.
disable-model-invocation: false
---

## Update CV Workflow

All CV content lives in `index.md`. Do not edit any other file unless changing style or layout.

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

### Steps

1. Create a new branch:
   ```bash
   git checkout -b cv/<short-description>
   ```
2. Read current `index.md` to understand existing structure before making changes
3. Make the requested edits — surgical changes only, preserve formatting conventions
4. Verify the file still has valid YAML front matter (`---` block at top)
5. Commit:
   ```bash
   git add index.md
   git commit -m "cv: <describe what changed>"
   ```
6. Open a PR:
   ```bash
   git push origin HEAD
   ```
   Then open a PR on GitHub targeting `master`. GitHub Pages rebuilds automatically after merge (~60 seconds).
7. Confirm merge succeeded and GitHub Pages rebuilt

**Optional local preview before push:**
```bash
jekyll serve
```
Then open http://localhost:4000.
