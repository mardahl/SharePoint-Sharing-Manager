# Scanning and revoking

The Sites and OneDrives tabs share one scan engine with six togglable rule categories (`T` opens the toggles). Defaults differ per tab: **Sites defaults to org-wide links only**, **OneDrives defaults to all categories**.

## Finding categories

| Category | Pulled | Left alone |
|---|---|---|
| Anonymous links | Any "Anyone" sharing link | (nothing) |
| Org-wide links | Any "People in your organization" link | (nothing) |
| Guest-specific links | Specific-people links exposing an external grantee | Specific-people links shared only with internal members |
| Guest direct grants | Role assignments where the login contains `#ext#` | Named internal members, default site groups (Owners/Members/Visitors), system/app accounts |
| EEEU grants | `c:0-.f\|rolemanager\|spo-grid-all-users/*` claim | EEEU/Everyone nested inside a site permission group (group membership, not a direct grant) |
| Everyone grants | `c:0(.s\|true` claim | (nothing) |

Files and folders are never deleted, and permission inheritance is never reset. "Limited Access" rows (`RoleTypeKind = 1`) are skipped on purpose: that row is the traversal stub SharePoint auto-creates so someone can reach a deeper item, not a real grant. Removing the real grant on the item clears the stub automatically.

## Target discovery

- **Auto-enumerate** via `Get-PnPTenantSite` (press `Enter` on the tab)
- **Manual URL entry** (`U`)
- **CSV import** (`I`)

Per-site failure isolation: a site that will not connect or scan is logged and the run continues.

## Keys: target list

| Key | Action |
|---|---|
| `Space` | Toggle selection (`A` all, `N` none) |
| `/` | Live search |
| `F` | Cycle status filter |
| `S` | Scan selected |
| `X` | Scan all not-yet-scanned targets (one target at a time) |
| `T` | Toggle rule categories |
| `G` | All findings (aggregate view across drives) |
| `R` | Revoke all findings on selected targets |
| `U` | Add URL |
| `I` | Import CSV |
| `Enter` | Open/load |
| `L` | Restore the saved scan session |
| `E` | Export |

## Keys: findings list

| Key | Action |
|---|---|
| `Space` | Toggle selection (`A` all, `N` none) |
| `/` | Live search |
| `F` | Cycle category filter |
| `R` | Revoke selected (typed `REVOKE` confirmation) |
| `E` | Export |
| `Esc` | Back to target list |

## Revocation behavior

- Multi-select revoke with a **typed `REVOKE` confirmation**. In the all-findings view (`G`), revoking works across every affected site with one confirmation.
- Removal ordering: **links before direct grants, leaf items (File/Folder) before Library before Web**, so claim principals (EEEU, for example) are not de-provisioned out from under a later removal step.
- `AlreadyRevoked` responses are handled gracefully; re-running over the same scope is safe.

## Evidence

Every scan and revoke run writes CSV evidence to `SSM-Exports/`:

- `SSM_<phase>_<site>_<timestamp>.csv`: BEFORE/REVOKED evidence per run
- `<tab>_targets_<timestamp>.csv` / `<tab>_findings_<timestamp>.csv`: view exports

Revoked links and grants cannot be restored from within the tool. Review the BEFORE CSV before typing `REVOKE`.

## Scan cache

Scan results are cached per tenant in `SSM-Cache/<tenant-slug>/session.json` and survive a restart; `L` restores the saved session on demand. The cache holds one session per install directory, so two installs on the same machine get independent caches. A restored session may be stale relative to the tenant's current sharing state; rescan before acting on old results. The cache contains directory data, so treat the directory accordingly.

## Sharing-link age (optional)

Setup > tenant > **"Enable link-date lookup"** makes scans also fetch each link's Created/CreatedBy via SharePoint REST (slower; one extra call per shared item). Shown as a Created column in the findings view and in CSV exports. Useful when deciding whether an old link is safe to revoke.
