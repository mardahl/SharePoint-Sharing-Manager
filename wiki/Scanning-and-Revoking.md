# Scanning and revoking

The Sites and OneDrives tabs share one scan engine with six togglable rule categories (`T` opens the toggles). **Both tabs default to all six categories enabled** — the first scan covers every rule; press `T` to narrow a run to specific categories.

## Finding categories

| Category | What it means | Why it is a risk |
|---|---|---|
| Anonymous links | "Anyone" sharing links — no sign-in required | Anyone holding the URL opens the content, and the link can be forwarded without limit. The most exposed share type. |
| Org-wide links | "People in your organization" links | Every signed-in employee (and any AI agent they run, e.g. Copilot) can reach the content. Fine for deliberate broadcasts, risky when created casually. |
| Guest-specific links | Specific-people links that expose an external grantee | External users keep access long after the collaboration ended. Links shared only with internal members are left alone. |
| Guest direct grants | Permission grants where the login contains `#ext#` | Same staleness problem as guest links, but granted directly on the item. Named internal members, default site groups (Owners/Members/Visitors), and system/app accounts are left alone. |
| EEEU grants | Grants to "Everyone except external users" (`spo-grid-all-users` claim) | One step below anonymous: every internal user has standing access, whether they know it or not. Grants nested inside a site permission group are group membership, not direct grants, and are left alone. |
| Everyone grants | Grants to the "Everyone" claim (`c:0(.s|true`) | Includes external identities in most tenants. Effectively anonymous access. |

Files and folders are never deleted, and permission inheritance is never reset. "Limited Access" rows (`RoleTypeKind = 1`) are skipped on purpose: that row is the traversal stub SharePoint auto-creates so someone can reach a deeper item, not a real grant. Removing the real grant on the item clears the stub automatically.

## Reducing oversharing with the rules

A practical sequence:

1. **Run the defaults first.** With all six rules on, `X` (scan all) on each tab gives a full exposure inventory. Export (`E`) before revoking anything.
2. **Kill the worst exposure first.** Anonymous links and Everyone grants are the two categories where access requires no account at all — filter the findings view (`F`) to those categories and revoke them in the first pass.
3. **Then cut implicit internal blast radius.** Org-wide links and EEEU grants are what Copilot and other AI agents surface to any employee on demand. Most org-wide links were created for convenience ("share to the team") and are safe to replace with named-group access.
4. **Triage guests last.** Guest links and guest grants are often legitimate. Sort by the Created column (Setup > tenant > "Enable link-date lookup") and revoke anything older than the project it belonged to, then spot-check the remainder with the external parties.
5. **Lock the tenant down so it stays clean.** After revocation, use the [[Tenant-Hardening]] tab to disable anonymous links tenant-wide and default new links to specific people, so the categories stay quiet on rescan.

## Target discovery

- **Auto-enumerate** via `Get-PnPTenantSite` (press `Enter` on the tab)
- **Manual URL entry** (`U`)
- **CSV import** (`I`)

Per-site failure isolation: a site that will not connect or scan is logged and the run continues.

Once anything is scanned, the status line above the target list always shows a running summary: `scanned:N (X clean, Y with findings, Z total findings)`. Per-target counts live in the Findings column; `Enter` drills into one target, `G` aggregates all findings.

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
