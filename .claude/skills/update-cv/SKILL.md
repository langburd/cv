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

1. Read current `index.md` to understand existing structure before making changes
2. Make the requested edits — surgical changes only, preserve formatting conventions
3. Verify the file still has valid YAML front matter (`---` block at top)
4. Commit:
   ```bash
   git add index.md
   git commit -m "cv: <describe what changed>"
   ```
5. Push:
   ```bash
   git push origin master
   ```
6. Confirm push succeeded — GitHub Pages will rebuild automatically in ~60 seconds

**Optional local preview before push:**
```bash
jekyll serve
```
Then open http://localhost:4000.
