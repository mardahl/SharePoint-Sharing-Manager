# Update Check (notify-only) — Design

## Goal

At every startup, check the GitHub repo for a newer release. If one exists, show a modal telling the user where to download it and assuring them their settings, scan cache, and exports are untouched by updating. No auto-download, no auto-replace.

## Decisions (from brainstorming)

- **Delivery:** check + notify only. No in-app download.
- **Source:** GitHub Releases latest tag via `https://api.github.com/repos/mardahl/SharePoint-Sharing-Manager/releases/latest`.
- **Timing:** every startup, blocking modal only when a newer version exists. Offline/error = silent skip (logged at DEBUG), startup never blocked.

## Architecture

One new region file, per project convention (thin bootstrap + one file per region under `src/`):

**`src/72-update-check.ps1`** — two functions:

- `Get-SsmLatestVersion`
  - `Invoke-RestMethod` on the releases/latest URL, `-TimeoutSec 5`, `User-Agent` header (GitHub API rejects requests without one).
  - Parse `tag_name`, strip leading `v`, return `[version]`.
  - Any failure (offline, 404, rate-limit, parse) → `$null`. Log at DEBUG, never throw.

- `Show-SsmUpdateNotice`
  - Compare `Get-SsmLatestVersion` to `$script:Version`.
  - If newer, show the existing `Show-ConfirmModal` (from `src/20-modals.ps1`) with fixed copy (below).
  - Y → `Start-Process 'https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest'` (PS7 cross-platform: opens default browser), then continue.
  - N/Esc → continue.
  - No "don't ask again" state — check re-runs next launch.

**Bootstrap change (`SharePoint-Sharing-Manager.ps1`):** one call after `Initialize-SsmTenancy`, before `Enter-Tui`:

```powershell
Show-SsmUpdateNotice
```

Wrapped so any unexpected failure is caught and logged — startup must never fail because of the update check.

## Modal copy

```
A newer version is available:  v1.6.0 → v1.7.0

Download: github.com/mardahl/SharePoint-Sharing-Manager/releases/latest

Updating replaces only the script file.
Your settings (~/.sharepoint-sharing-manager.json),
scan cache, and exports remain untouched.

Open download page in browser?
```

(Actual version numbers interpolated from `$script:Version` and the fetched tag.)

## Files touched

| File | Change |
|---|---|
| `src/72-update-check.ps1` | New — `Get-SsmLatestVersion`, `Show-SsmUpdateNotice` |
| `SharePoint-Sharing-Manager.ps1` | Add `Show-SsmUpdateNotice` call before `Enter-Tui` |
| `CHANGELOG.md` | Unreleased entry |
| `wiki/FAQ-and-Troubleshooting.md` | Note the update notification + that settings/cache survive updates |

## Explicitly out of scope (YAGNI)

- Auto-download / in-place replace of the script file
- Zip download + extract flow
- "Don't ask again" / snooze state in config
- Background/async check
- Pre-release channel handling (releases/latest already excludes drafts/prereleases)

## Testing

- Pester test (existing harness in `tests/`): mock `Invoke-RestMethod` — newer / same / older / throws → assert modal shown or not, never throws.
- Manual: run with airplane-mode/offline → starts normally.
