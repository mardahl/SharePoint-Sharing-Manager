# SharePoint Sharing Manager

[![CI](https://github.com/mardahl/SharePoint-Sharing-Manager/actions/workflows/ci.yml/badge.svg)](https://github.com/mardahl/SharePoint-Sharing-Manager/actions/workflows/ci.yml)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.4%2B-5391FE?logo=powershell&logoColor=white)](#requirements)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-555)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Downloads](https://img.shields.io/github/downloads/mardahl/SharePoint-Sharing-Manager/total)](https://github.com/mardahl/SharePoint-Sharing-Manager/releases)
![Visitors](https://hits.sh/github.com/mardahl/SharePoint-Sharing-Manager.svg)

A portable PowerShell **terminal UI** that finds and revokes unwanted sharing across **SharePoint Online sites and OneDrives** - anonymous links, org-wide links, guest links, and direct grants to guests, "Everyone" and "Everyone except external users" (EEEU) - then locks the tenant down so it stays clean.

## TL;DR

Download the [latest release](https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest), extract, double-click `Launch-Sharing-Manager.bat` (or run `pwsh ./SharePoint-Sharing-Manager.ps1`), then pick an auth mode on the **Setup** tab. Full steps in [Quick start](#quick-start); full docs in the [wiki](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki).

```
 SharePoint Sharing Manager  v1.0.0        ● https://contoso-my.sharepoint.com/personal/jane_contoso_com
  1 Sites   2 OneDrives   3 Sharing   4 Setup   5 Log
 https://contoso-my.sharepoint.com/personal/jane_contoso_com   4 of 4 findings   0 selected   filter:All
 sel Category              Loc     Name                    Principal                 Status
 [ ] Anonymous link         File    Q4-Budget.xlsx          (anonymous)               -
 [ ] Guest grant            Web     personal_jane           bob@fabrikam.com          -
 [ ] EEEU grant              Library HR Documents            Everyone except external  -
 [ ] Organization link      Folder  Shared with Sales        (organization)            -
 Spc select  A all  N none  / find  F filter  R revoke selected  E export  Esc back  ? help  Q quit
```

---

- [TL;DR](#tldr)
- [Why](#why)
- [Features](#features)
- [Quick start](#quick-start)
- [Requirements](#requirements)
- [Files the tool writes](#files-the-tool-writes)
- [Caveats](#caveats)
- [References](#references)
- [Contributing](#contributing) · [Security](#security) · [Changelog](CHANGELOG.md) · [Wiki](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki)

## Why

Oversharing was always a risk, but Microsoft 365 Copilot and other AI agents raise the stakes: they search and summarize across everything a signed-in user can already reach, including stale anonymous links, forgotten guest grants, and org-wide links nobody remembers creating. A sharing grant that used to require someone to stumble across a URL now surfaces through a chat prompt in seconds. Running this tool before turning on Copilot, or any AI agent with tenant-wide reach, is a way to find and close that exposure first.

Cleaning up SharePoint/OneDrive sharing with delegated auth means being made Site Collection Admin on every single OneDrive first - painful at scale, and it leaves a wide trail of temporary admin grants behind. This tool adds an app-only certificate mode that removes the per-OneDrive admin requirement entirely, with one shared scan engine covering both site-level sharing links and OneDrive access review, each with its own togglable rule set per tab.

| Category | Pulled | Left alone |
|---|---|---|
| Anonymous links | Any "Anyone" sharing link | - |
| Org-wide links | Any "People in your organization" link | - |
| Guest-specific links | Specific-people links exposing an external grantee | Specific-people links shared only with internal members |
| Guest direct grants | Role assignments where the login contains `#ext#` | Named internal members, default site groups (Owners/Members/Visitors), system/app accounts |
| EEEU grants | `c:0-.f\|rolemanager\|spo-grid-all-users/*` claim | EEEU/Everyone nested inside a site permission group (group membership, not a direct grant) |
| Everyone grants | `c:0(.s\|true` claim | - |

Files and folders are never deleted and permission inheritance is never reset. "Limited Access" rows (`RoleTypeKind = 1`) are skipped on purpose - that is the traversal stub SharePoint auto-creates so someone can reach a deeper item, not a real grant; removing the real grant on the item clears the stub automatically.

## Features

- **Pure PowerShell TUI** (VT/ANSI) - no WinForms, no DLLs, works over SSH and in any VT-capable terminal
- **PowerShell 7.4+** on Windows, macOS, and Linux
- **Shared scan engine**, six togglable rule categories (`T`), all enabled by default on both the Sites and OneDrives tabs
- **Per-finding multi-select revoke** with typed `REVOKE` confirmation and BEFORE/REVOKED CSV evidence for every run
- **Target discovery**: auto-enumerate via `Get-PnPTenantSite`, manual URL entry, or CSV import
- **Delegated (interactive) and app-only certificate authentication**, with a guided in-app setup wizard including 1-year certificate issuance and renewal
- **Sharing tab**: current sharing posture (`Get-PnPTenant`) plus hardening setters (`Set-PnPTenant`) behind typed confirmation
- **Search** (`/` live filter), category filter, multi-select, sorting
- **CSV export** of any view; CSV import of target URLs
- **Timestamped log file** plus an in-app log viewer
- **Per-site failure isolation** - a site that will not connect or scan is logged and the run continues
- **Persistent scan cache with manual restore** - scan results survive a restart and can be reloaded on demand
- **Bulk revocation across drives and across the full findings list** - revoke every finding on a set of selected targets, or every finding in the aggregate view, in one confirmed pass
- **Multi-tenant** - manage multiple tenants from one install, switch between them (`T`), each with its own auth, scan cache, and exports; legacy single-tenant config migrates automatically
- **Sharing-link age** (optional, per tenant) - Setup > tenant > "Enable link-date lookup" makes scans also fetch each link's Created date via CSOM (slower; one extra call per shared item). Shown as a Created column in the findings view and in CSV exports - useful when deciding whether an old link is safe to revoke

## Quick start

Download the zip from [Releases](https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest), extract, then double-click **`Launch-Sharing-Manager.bat`** - it unblocks the files (removes the Mark of the Web) and starts the tool. Or run it yourself:

```powershell
pwsh ./SharePoint-Sharing-Manager.ps1
```

First run: open the **Setup** tab, press `Enter` on the tenant, and pick an auth mode from the actions list -

- **Register cert app** - app-only certificate auth (recommended; removes the per-OneDrive Site Collection Admin requirement)
- **Register delegated app** - delegated (interactive) auth

Full key reference, auth trade-offs, and per-setting docs live in the [wiki](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki).

## Requirements

### Modules (installed on demand, CurrentUser scope)

- [`PnP.PowerShell`](https://www.powershellgallery.com/packages/PnP.PowerShell) v3 - the only dependency

### Roles & permissions

| Task | Requirement |
|---|---|
| Create the app registration (either mode) | **Application Administrator** |
| Consent to application permissions (app-only mode) | **Global Administrator** or **Privileged Role Administrator** |
| Delegated mode: scan/revoke on a target | **Site Collection Admin** on that site or OneDrive |
| Delegated mode: Sharing tab | **SharePoint Administrator** |
| App-only mode | No per-target admin role needed once the app is consented |

Details: [Authentication](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/Authentication) in the wiki.

## Files the tool writes

| Location | Content |
|---|---|
| `SharePoint-Sharing-Manager_<timestamp>.log` | Session log (also viewable on the Log tab) |
| `SSM-Exports/SSM_<phase>_<site>_<timestamp>.csv` | BEFORE/REVOKED evidence for each scan and revoke run |
| `SSM-Exports/<tab>_targets_<timestamp>.csv` / `SSM-Exports/<tab>_findings_<timestamp>.csv` | View exports |
| `~/.sharepoint-sharing-manager.json` | Sign-in configuration - one entry per tenant, plus a default tenant name |
| `~/.sharepoint-sharing-manager-cert/` | Self-signed certificate files for app-only mode (PFX on non-Windows) |
| `SSM-Cache/<tenant-slug>/session.json` | Cached scan results (targets + findings) per tenant, for restore; contains directory data |
| `SSM-Cache/README.txt` | Sensitivity notice for the cache directory |

## Caveats

Known limitations:

- A specific-people link that includes a guest is removed in full; internal members on the same link lose it too (the item and any other grants stay).
- Guest detection on specific-people links depends on the link exposing an external grantee; a follow-up report-only pass is the verification.
- EEEU/Everyone nested inside a site permission group is group membership, not a direct grant, and is not removed.
- Sharing links on list items outside document libraries are not handled.
- Cleanup does not prevent new sharing - use the Sharing tab's hardening toggles for that.
- The SharePoint admin site URL is derived from the tenant name as `https://<tenant>-admin.sharepoint.com`; tenants where the SharePoint hostname doesn't follow this pattern (vanity domains, some multi-geo setups) need the Setup tab's config editor to override `AdminUrl` manually.
- The scan cache holds one session per install directory (`SSM-Cache/session.json`, next to the script); two installs on the same machine get independent caches. Restoring it loads whatever was scanned last, which may be stale relative to the tenant's current sharing state - rescan before acting on old results. Scan-all (`X`) scans one target at a time.

## References

- [Turn external sharing on or off (Microsoft Learn)](https://learn.microsoft.com/sharepoint/turn-external-sharing-on-or-off)

## Contributing

Bug reports and PRs are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the ground rules (bootstrap + `src/` region files, safety UX) and a scripted tmux recipe for testing the TUI. CI enforces PSScriptAnalyzer and a parse check. Release notes live in [CHANGELOG.md](CHANGELOG.md).

## Security

No telemetry. Authentication is delegated to PnP.PowerShell / MSAL. Logs and CSV exports contain directory data - treat them accordingly. See [SECURITY.md](SECURITY.md) for the full policy and how to report vulnerabilities privately.

## Credits

Combines and supersedes the original standalone `Revoke-OrgWideSharingLinks` and `Revoke-OneDrive-NonMemberAccess` scripts. TUI framework shared with [Exchange-SOA-Manager](https://github.com/mardahl/Exchange-SOA-Manager).

## License

MIT - see [LICENSE](LICENSE).

Provided as-is, without warranty. Test in a non-production tenant first.
