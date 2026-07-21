# SharePoint Sharing Manager — Design

Date: 2026-07-21
Status: Approved

## Summary

Merge `Revoke-OrgWideSharingLinks.ps1` and `Revoke-OneDrive-NonMemberAccess.ps1` into a single
PowerShell terminal-UI tool, **SharePoint-Sharing-Manager**, published as a public GitHub repo
mirroring the structure, release pipeline, and README style of
[Exchange-SOA-Manager](https://github.com/mardahl/Exchange-SOA-Manager). Nothing tenant-specific;
generic defaults, everything overridable.

Local template: `~/Documents/opencode/SOAconverter` (clone of Exchange-SOA-Manager).
Source scripts: `Revoke-OrgWideSharingLinks.ps1`, `Revoke-OneDrive-NonMemberAccess.ps1` in this repo.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Name | `SharePoint-Sharing-Manager` (repo, script, bat, app name, config file) |
| TUI layout | Tabs: Sites, OneDrives, Tenant, Setup, Log |
| Findings | Per-finding multi-select revoke (not all-or-nothing per site) |
| Scan rules | One shared engine, toggleable rule categories, per-tab defaults |
| PS floor | PowerShell 7.4+ only (PnP.PowerShell v3 requirement) |
| Demo mode | None — report-only scan is the safe preview |
| Target discovery | Auto-enumerate via `Get-PnPTenantSite` + manual URL + CSV import |
| Auth | Delegated interactive **and** app-only certificate (1-year self-signed) |
| Architecture | Option A: bootstrap + `src/` region files, concat at release to single-file zip |

## 1. Repo & artifact

- Repo `SharePoint-Sharing-Manager` on github.com/mardahl.
- Files: `SharePoint-Sharing-Manager.ps1` (bootstrap that dot-sources `src/NN-*.ps1`),
  `src/` region files, `Launch-Sharing-Manager.bat`, `README.md` (badges, ASCII screenshot,
  keys table, "no tenant-specific anything" positioning), `CONTRIBUTING.md`, `SECURITY.md`,
  `CHANGELOG.md`, `LICENSE` (MIT), `PSScriptAnalyzerSettings.psd1`, `.gitignore`.
- `.github/`: CI workflow (PSScriptAnalyzer + parse check, pwsh only), release workflow
  (concat `src/` into single-file `SharePoint-Sharing-Manager.ps1`, zip with bat + LICENSE +
  README, attach to GitHub release on tag), issue templates, PR template, dependabot.
- Generic defaults: Entra app name `SharePoint-Sharing-Manager`, config
  `~/.sharepoint-sharing-manager.json`. All names/paths overridable by parameter.

## 2. TUI layout

Tabs: `1 Sites  2 OneDrives  3 Tenant  4 Setup  5 Log`

### Sites / OneDrives tabs — two-level flow

**Level 1 — target list.** Rows are site/OneDrive URLs with status (NotScanned / Clean /
N findings / ConnectFailed / ScanFailed). Sources:

- Auto-enumerate: connect to tenant admin URL, `Get-PnPTenantSite` (Sites tab) /
  `Get-PnPTenantSite -IncludeOneDriveSites` filtered to personal sites (OneDrives tab).
- Manual URL entry (modal).
- CSV import (column `Url` or first column, matching current script behavior).

Keys: Space select, A all, N none, `/` search, `S` scan selected, `T` toggle rule categories,
`E` export, Enter drill into findings.

**Level 2 — findings view.** One row per link/grant: Category, Location (Web/Library/
Folder/File), Name, Principal, Path, RevokeStatus. Multi-select, `/` live search, `F` cycle
category filter, `E` export CSV, `R` revoke selected with typed `REVOKE` confirmation.
BEFORE CSV written at scan time, AFTER (evidence) CSV written post-revoke — same evidence
model as the current scripts.

### Shared scan engine

Ported from `Revoke-OneDrive-NonMemberAccess.ps1` (the superset). Rule categories,
individually toggleable before scan:

| Category | Mechanism |
|---|---|
| Anonymous links | Graph sharing links, scope `anonymous` |
| Org-wide links | Graph sharing links, scope `organization` |
| Guest-specific links | scope `users` with an external grantee (`#ext#` / `guest#`) |
| Guest direct grants | REST role assignments, login contains `#ext#` |
| EEEU grants | `c:0-.f\|rolemanager\|spo-grid-all-users/*` |
| Everyone grants | `c:0(.s\|true` |

Per-tab defaults: Sites tab = org-wide links only; OneDrives tab = all categories.
Same engine, different preset; user can change either before scanning.

Engine mechanics kept from the existing scripts:

- REST item enumeration by indexed Id range (`$filter=Id gt N`, `$top=5000`), only
  unique-permission items inspected further.
- Language-independent system-library exclusion by URL leaf
  (`SiteAssets`, `SitePages`, `Style Library`, `FormServerTemplates`, `Teams Wiki Data`),
  hidden lists excluded.
- `Classify-Principal` logic incl. skipping `SharingLinks.*` principals (handled via link
  cmdlets) and Limited Access (`RoleTypeKind = 1`) rows.
- Removal ordering: links before direct grants; leaf (File/Folder) before Library before Web —
  so claim principals (e.g. EEEU) are not de-provisioned out from under later removals.
- `AlreadyRevoked` handling when the principal is already gone.
- Per-site failure isolation: connect/scan failure logs the site and continues the run.

### Tenant tab

- Show current sharing posture from `Get-PnPTenant`: `SharingCapability`,
  `OneDriveSharingCapability`, `DefaultSharingLinkType`, `DefaultLinkPermission`,
  anonymous-link expiry settings.
- Hardening actions via `Set-PnPTenant`, each behind a typed confirmation
  (e.g. `DISABLE`): set tenant / OneDrive sharing capability, default link type and scope.
- Requires SharePoint Administrator (delegated) or app-only connection to the admin URL.

### Setup tab

- Auth status panel: mode, ClientId, tenant, cert thumbprint + expiry (if app-only),
  connection state.
- Actions: register delegated app, register app-only cert app, renew certificate,
  edit/clear config, install/update PnP.PowerShell.

## 3. Authentication

Config file `~/.sharepoint-sharing-manager.json`:

```json
{
  "AuthMode": "Delegated | AppOnly",
  "ClientId": "<guid>",
  "Tenant": "contoso.onmicrosoft.com",
  "Thumbprint": "<windows cert store>",
  "CertPath": "<pfx path, non-windows>",
  "CertExpires": "2027-07-21"
}
```

### Delegated (interactive)

`Register-PnPEntraIDAppForInteractiveLogin -ApplicationName SharePoint-Sharing-Manager`
(current script pattern). Any user can create the app; a Global Admin consents once.
Limitation shown in-app: the operator must be Site Collection Admin on every target
OneDrive; many actions fail otherwise.

### App-only certificate (recommended in-app)

Setup wizard runs `Register-PnPAzureADApp -ValidYears 1` with **application** permissions
`Sites.FullControl.All` (SharePoint) + `Sites.FullControl.All` (Graph):

- Creates the app registration (requires **Application Administrator** role).
- Generates a self-signed certificate valid 1 year and uploads it to the app.
- Windows: cert placed in `CurrentUser\My`, thumbprint saved to config.
  macOS/Linux: PFX file path saved to config.
- **Consent caveat (shown in-app):** Application Administrator can create the app but
  admin consent for application permissions requires Global Administrator /
  Privileged Role Administrator. The consent URL is displayed and copyable so the
  operator can hand it to whoever holds that role.
- App-only removes the per-OneDrive Site Collection Admin requirement entirely.

Cert lifecycle: header shows expiry; warning when < 30 days; **Renew** action generates and
uploads a fresh 1-year cert to the existing app (Application Administrator again; no new
consent needed).

### Connection layer

Lazy, per-tab, like SOA-Manager. Picks `Connect-PnPOnline -Interactive -ClientId ...` or
`Connect-PnPOnline -ClientId ... -Tenant ... -CertificateThumbprint/-CertificatePath ...`
from config. Caches connection per URL within a run; disconnects on exit unless
`-NoDisconnect`.

## 4. Port plan (from SOAconverter template)

| Ported ~as-is | Rewritten | Dropped |
|---|---|---|
| 00-globals | connections (PnP dual-mode auth) | demo data |
| 05-logging | data-fetchers (tenant site enumeration) | Graph SDK layer |
| 10-console-vt | scan engine (REST grants + Graph links) | backup-conversion (CSV evidence covers it) |
| 15-drawing | views (targets + findings, Tenant, Setup) | |
| 20-modals | setup wizard (app registration, cert) | |
| 55-csv | tenant actions | |
| 75-key-dispatch skeleton | | |
| bootstrap, bat, CI/release workflows | | |

## Safety invariants (unchanged from source scripts)

- Never delete files or folders; never reset inheritance.
- Skip Limited Access rows (`RoleTypeKind = 1`) — system traversal stubs.
- Links removed before direct grants; leaf-first removal order.
- Empty-LinkId guard: never fall back to "remove all links on file".
- Typed confirmation (`REVOKE` / `DISABLE`) before every destructive batch.
- BEFORE/AFTER CSV evidence for every scan and revoke run.
- Per-site failure isolation; run summary CSV at end.

## Known limitations (documented in README, carried from source scripts)

- A specific-people link that includes a guest is removed in full; internal members on the
  same link lose it too (item and other grants stay).
- Guest detection on specific-people links depends on the link exposing an external grantee;
  a follow-up report-only pass is the verification.
- EEEU/Everyone nested inside a site permission group is group membership, not a direct
  grant, and is not removed.
- Sharing links on list items outside document libraries are not handled.
- Cleanup does not prevent new sharing — the Tenant tab's hardening toggles do.

## Testing

- CI: PSScriptAnalyzer with repo settings + `[System.Management.Automation.Language.Parser]`
  parse check on every `src/` file and the concatenated release artifact.
- Pure functions (principal classification, guest-grantee extraction, removal ordering,
  CSV parsing, config resolution) get small Pester-style or assert-based checks runnable
  in CI without a tenant.
- Manual test recipe in CONTRIBUTING (tmux-scripted TUI walkthrough, as in the template).
