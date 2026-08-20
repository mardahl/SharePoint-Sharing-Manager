# SharePoint Sharing Manager wiki

SharePoint Sharing Manager is a portable PowerShell **terminal UI** that finds and revokes unwanted sharing across **SharePoint Online sites and OneDrives**: anonymous links, org-wide links, guest links, and direct grants to guests, "Everyone" and "Everyone except external users" (EEEU). It then locks the tenant down so it stays clean.

## Why it exists

Oversharing was always a risk, but Microsoft 365 Copilot and other AI agents raise the stakes: they search and summarize across everything a signed-in user can already reach, including stale anonymous links, forgotten guest grants, and org-wide links nobody remembers creating. A sharing grant that used to require someone to stumble across a URL now surfaces through a chat prompt in seconds. Running this tool before turning on Copilot, or any AI agent with tenant-wide reach, is a way to find and close that exposure first.

Cleaning up SharePoint/OneDrive sharing with delegated auth means being made Site Collection Admin on every single OneDrive first, which is painful at scale. This tool adds an app-only certificate mode that removes the per-OneDrive admin requirement entirely.

## Pages

| Page | Contents |
|---|---|
| [[Getting-Started]] | Download, launch, first-run auth setup |
| [[Requirements]] | PowerShell, modules, Entra roles per task |
| [[Authentication]] | Delegated vs app-only certificate mode |
| [[Scanning-and-Revoking]] | Findings categories, keys, evidence CSVs |
| [[Tenant-Hardening]] | Sharing tab settings and the CIS baseline |
| [[Multi-Tenant-Support]] | Managing several tenants from one install |
| [[FAQ-and-Troubleshooting]] | Caveats, known limitations, common issues |

## Quick facts

- **Pure PowerShell TUI** (VT/ANSI): no WinForms, no DLLs, works over SSH and in any VT-capable terminal
- **PowerShell 7.4+** on Windows, macOS, Linux
- Only dependency: [PnP.PowerShell](https://www.powershellgallery.com/packages/PnP.PowerShell) v3 (installed on demand, CurrentUser scope)
- **No telemetry**: the only network calls are to SharePoint Online and Microsoft Graph, triggered explicitly by the operator
- Destructive operations sit behind typed confirmations (`REVOKE` / `APPLY` / `CIS`), and every scan and revoke run writes BEFORE/REVOKED CSV evidence
- License: MIT. Provided as-is. Test in a non-production tenant first.

Source, releases, and issue tracker: [github.com/mardahl/SharePoint-Sharing-Manager](https://github.com/mardahl/SharePoint-Sharing-Manager)
