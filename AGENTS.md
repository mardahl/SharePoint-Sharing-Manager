# AGENTS.md

## Project

SharePoint Sharing Manager — portable PowerShell 7.4+ terminal UI (VT/ANSI, no WinForms/DLLs) that finds and revokes unwanted sharing across SharePoint Online sites and OneDrives, then hardens the tenant sharing posture. See `README.md` for the feature list and `CONTRIBUTING.md` for the ground rules (thin bootstrap + one file per region under `src/`, StrictMode-safe, typed confirmations, no telemetry).

## Wiki sync rule

The GitHub wiki mirrors the user-facing docs and **must stay in sync with changes**.

- Wiki source lives in `wiki/` in this repo (one Markdown file per page, `[[Wiki-Style]]` internal links, hyphenated page names matching GitHub wiki conventions).
- The wiki remote is `https://github.com/mardahl/SharePoint-Sharing-Manager.wiki.git`. Publish with: `git -C wiki-remote pull` / commit / push on a clone of that remote, copying changed files from `wiki/`.
- **Any change that alters user-facing behavior, keys, settings, files written, permissions, or requirements must update the affected `wiki/*.md` page(s) in the same change.** Same bar as `CHANGELOG.md` — if the changelog changes, check whether the wiki changes too.
- When adding a user-facing feature: add/update the matching wiki page, and add the page to the table in `wiki/Home.md` if it is new.

## Key docs

| File | Purpose |
|---|---|
| `README.md` | Features, quick start, caveats |
| `CHANGELOG.md` | Release notes; update under Unreleased with every user-facing change |
| `CONTRIBUTING.md` | Architecture, lint/test commands, code map, conventions |
| `SECURITY.md` | Vulnerability reporting, data-handling policy |
| `wiki/` | GitHub wiki source (see sync rule above) |
