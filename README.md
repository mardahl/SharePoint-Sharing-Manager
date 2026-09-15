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
- [OneDrive secondary admin (limited live validation)](#onedrive-secondary-admin-limited-live-validation)
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
- **OneDrive secondary-admin management** (`M`, OneDrives tab only, released in v1.9.0 with limited live validation) - list, add, or remove the tenant's *secondary* site-collection-admin role on selected OneDrives. **List** is read-only (no confirmation, no UPN entry, no directory lookup, no `User.Read.All` requirement, no permission change) and shows every current site collection admin per selected OneDrive as-is. Add/Remove require typed confirmation and write BEFORE/AFTER CSV evidence. **Add/Remove validation**: an operator has reported a successful Add via app-only auth; Remove, owner-negative cases, bulk targets, and delegated auth are still unverified - see [Caveats](#caveats) and [OneDrive-Admin-Management](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/OneDrive-Admin-Management) before relying on them.
- **OneDrive pre-provisioning** (`P`, OneDrives tab only) - loads enabled member users with a SharePoint service plan but no personal site as rows under an `Unprovisioned` filter (never shown under `All`); select the ones you want, press `P`, type `PROVISION`, and only those are submitted via `Request-PnPPersonalSite` (batches of 200). Provisioning completes asynchronously on the service side. See [OneDrive-Pre-Provisioning](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/OneDrive-Pre-Provisioning).

## OneDrive secondary admin (limited live validation)

> The whole feature (`List`, `Add`, `Remove`) was released in v1.9.0 with
> limited live validation. **List** is read-only and does not change any
> permission - it makes no UPN entry, confirmation, CSV evidence, or directory
> (`User.Read.All`) lookup, only reading existing site collection admin
> membership on selected OneDrives. **Add** and **Remove** additionally
> require live-tenant validation: an operator has reported a successful
> Add against a live tenant using app-only auth after the CSOM `-Includes`
> fix; Remove, owner-negative cases, bulk targets, and delegated auth remain
> unverified. Testing is limited, not complete - do not rely on this feature
> for production access changes until the remaining cases are validated.
> Review BEFORE/AFTER CSV evidence carefully. See the "Auth mode support" note
> below and the full [OneDrive-Admin-Management](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/OneDrive-Admin-Management) wiki page.

```text
Select one or more OneDrives, press M, choose List, Add, or Remove.
List shows every current site collection admin per selected target and
requires nothing further. Add/Remove ask for one UPN, resolve it in the
tenant directory, and preview every selected target before requiring
ADDADMIN or REMOVEADMIN. Removal changes only the named
secondary administrator role; other access grants remain in place.
```


- **Full access, not a scoped role**: the *secondary site collection
  administrator* role this tool adds/removes grants full access to that
  OneDrive - the same level as the actual owner - not a limited "read-only"
  or "helpdesk" role. There is no narrower built-in role to grant instead.
- **Owner and primary-admin protection**: the request is blocked, before any
  write, if the entered account is the OneDrive's actual owner or the
  tenant's primary site-collection administrator on that drive - removing
  either one that way is not supported by this tool.
- **Unresolved/unknown owner or primary admin blocks the request**: if the
  drive's owner or the tenant's primary-admin binding cannot be read (blank/
  group-valued owner field, or a read failure), the target is blocked rather
  than assumed safe - unknown never defaults to "not protected."
- **Canonical UPN required**: the entered UPN is resolved to the account's
  canonical `userPrincipalName`; an alias-only match is rejected, so mixed
  case or trailing whitespace is normalized but a genuinely different alias
  is not silently accepted.
- **Deleted-user cleanup is out of scope**: this feature adds/removes one
  named, currently-resolvable account. It is not a scan for stale/deleted
  secondary admins already on a drive.
- **Hidden selected targets are still included**: a OneDrive you selected
  earlier and then filtered/searched out of view is still acted on - only
  actual selection state matters, not what is currently visible.
- **No sharing-scan prerequisite**: this feature does not require having
  scanned the selected OneDrives first; it works from the target list alone.
- **Partial outcomes are expected in a multi-target batch**: each selected
  OneDrive is processed independently and reported with its own Blocked /
  NoOp / Success / Failed / Unverified / Cancelled result - one target
  failing does not stop the others (except a same-identity drift or a
  protected-identity change mid-batch, which stops all remaining targets).
- **No automatic rollback**: a Remove that fails partway, or an add later
  found to be unwanted, is not automatically undone - use Add/Remove again
  to restore a prior state.
- **Evidence files**: writes `SSM_ADMIN_BEFORE_<operation-id>.csv` and
  `SSM_ADMIN_AFTER_<operation-id>.csv` to `SSM-Exports/` (same directory and
  sensitivity as every other export - see [Files the tool writes](#files-the-tool-writes)
  and [Security](#security)). The AFTER file is re-written after every
  target so partial progress is durable even if the batch is cancelled.
- **Directory scopes needed**: exact UPN-to-account resolution needs a
  directory-read permission beyond the scan/revoke scopes this tool already
  requests. See [Requirements](#requirements) and the
  [Authentication](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/Authentication)
  wiki page for exactly which mode(s) that has been added to and which
  remain unverified.
- **Missing consent**: if the required directory scope was never consented
  (older registration, or delegated mode's documented default doesn't
  apply), pressing `M` fails with a specific permission error - it never
  silently falls back to a partial-match lookup. Existing scans and revokes
  are unaffected; only this feature is blocked. See
  [Authentication](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/Authentication)
  for how to add the missing consent to an existing app registration.

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
| OneDrive secondary-admin **List** (`M`, read-only) | Same as any other target action - no extra directory scope needed. |
| OneDrive secondary-admin **Add/Remove** (`M`, limited validation, see [Caveats](#caveats)) | App-only mode's registration additionally requests Graph `User.Read.All` (application) for exact UPN resolution - added to new registrations by this version; existing app-only registrations need manual re-consent (guided in-app). Delegated mode's existing default consent set already covers this (`User.ReadWrite.All`); no change needed there. An operator has reported a successful Add via app-only auth; delegated auth and Remove are still unverified against a live tenant. |
| OneDrive pre-provisioning (`P`) | SharePoint Administrator. App-only mode additionally needs the SharePoint application permission `User.ReadWrite.All` (User Profile Service, used by `Request-PnPPersonalSite`) - requested by new registrations from v1.10.0; existing app-only registrations must add it manually and grant admin consent (the failure summary in the tool spells out the steps). Delegated mode's default consent set already includes it. |

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
| `SSM-Exports/SSM_ADMIN_<BEFORE\|AFTER>_<operation-id>.csv` | BEFORE/AFTER evidence for OneDrive secondary-admin changes (see [above](#onedrive-secondary-admin-limited-live-validation)) |

## Caveats

Known limitations:

- A specific-people link that includes a guest is removed in full; internal members on the same link lose it too (the item and any other grants stay).
- Guest detection on specific-people links depends on the link exposing an external grantee; a follow-up report-only pass is the verification.
- EEEU/Everyone nested inside a site permission group is group membership, not a direct grant, and is not removed.
- Sharing links on list items outside document libraries are not handled.
- Cleanup does not prevent new sharing - use the Sharing tab's hardening toggles for that.
- The SharePoint admin site URL is derived from the tenant name as `https://<tenant>-admin.sharepoint.com`; tenants where the SharePoint hostname doesn't follow this pattern (vanity domains, some multi-geo setups) need the Setup tab's config editor to override `AdminUrl` manually.
- The scan cache holds one session per install directory (`SSM-Cache/session.json`, next to the script); two installs on the same machine get independent caches. Restoring it loads whatever was scanned last, which may be stale relative to the tenant's current sharing state - rescan before acting on old results. Scan-all (`X`) scans one target at a time.
- **OneDrive secondary-admin management (`M`) released in v1.9.0 with limited live validation.** List is read-only. An operator has reported a successful Add via app-only auth after the CSOM fix; Remove, owner-negative cases, bulk targets, and delegated auth remain unverified against a live tenant, and must not be relied on for production access changes until the remaining cases are validated. Review BEFORE/AFTER CSV evidence carefully. See [OneDrive-Admin-Management](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/OneDrive-Admin-Management).

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
