# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Jekyll static site — a Markdown CV rendered to HTML and PDF via CSS. Hosted on GitHub Pages at `cv.langburd.com`.

## Key Files

- `index.md` — the CV content (only file that needs editing for CV updates)
- `_config.yml` — Jekyll config; `style` key sets the active CSS theme
- `media/` — CSS stylesheets (`langburd-screen.css`, `langburd-print.css`)
- `_layouts/cv.html` — single layout template; links CSS based on `site.style`

## Local Development

```bash
jekyll serve   # serves at http://localhost:4000
jekyll build   # builds to _site/
```

No Gemfile — uses system Jekyll. No npm, no build tools.

Jekyll binary is at `/opt/terraspace/embedded/bin/jekyll` — ensure this is on your PATH (added via `~/.zshenv` on the primary dev machine).

## Style Themes

One theme: `langburd`. Active via `_config.yml`: `style: langburd`.

## PDF Export

Open `http://localhost:4000` (or the live site) in a browser and press `Cmd+P`. CSS print stylesheets handle layout automatically.

## Deployment

Push to `master` — GitHub Pages builds and deploys automatically via native Jekyll support. No Actions needed.

## What to Avoid

- Do not add a Gemfile unless explicitly requested — the site intentionally runs on system Jekyll.
- Do not modify `_layouts/cv.html` unless explicitly asked to change layout.
- Do not add new files to the root unless they serve a clear purpose (the site is intentionally minimal).

## Multi-Person Skill Usage

Skills like `cv-achievements` may be run against GitHub users other than the repo owner. When processing any GitHub user **other than `langburd`**, do NOT invoke the `update-cv` skill — the resulting bullets are for a different person's CV, not this repository's `index.md`.
