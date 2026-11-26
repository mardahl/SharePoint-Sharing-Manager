# Scanning and revoking

The Sites and OneDrives tabs share one scan engine with six togglable rule categories (`T` opens the toggles). **Both tabs default to all six categories enabled** — the first scan covers every rule; press `T` to narrow a run to specific categories.

## Finding categories

| Category | What it means | Why it is a risk |
|---|---|---|
| Anonymous links | "Anyone" sharing links — no sign-in required | Anyone holding the URL opens the content, and the link can be forwarded without limit. The most exposed share type. |
| Org-wide links | "People in your organization" links | Every signed-in employee (and any AI agent they run, e.g. Copilot) can reach the content. Fine for deliberate broadcasts, risky when created casually. |
| Guest-specific links | Specific-people links that expose an external grantee | External users keep access long after the collaboration ended. Links shared only with internal members are left alone. |
| Guest direct grants | Permission grants where the login contains `#ext#` | Same staleness problem as guest links, but granted directly on the item. Named internal members, default site groups (Owners/Members/Visitors), and system/app accounts are left alone. |
| EEEU grants | Grants to "Everyone except external users" (`spo-grid-all-users` claim) | One step below anonymous: every internal user has standing access, whether they know it or not. Grants nested inside a site permission group are group membership, not direct grants, and are left alone. **System sites are exempt:** an EEEU grant that carries only Read on the root of a My Sites host, a Search center or the tenant App catalog (templates `SPSMSITEHOST#0`, `SRCHCEN#0`, `APPCATALOG#0`) is not reported, because these system sites commonly carry it and removing it can break things such as SPFx web parts and Power Automate. EEEU with any other permission level on those sites, and the Everyone claim, are still reported. Each skipped grant is logged as "Not flagged". |
| Everyone grants | Grants to the "Everyone" claim (`c:0(.s|true`) | Includes external identities in most tenants. Effectively anonymous access. |

Files and folders are never deleted, and permission inheritance is never reset. "Limited Access" rows (`RoleTypeKind = 1`) are skipped on purpose: that row is the traversal stub SharePoint auto-creates so someone can reach a deeper item, not a real grant. Removing the real grant on the item clears the stub automatically.

Guest rows are tagged: any finding whose principal is external (guest direct grant or guest on a specific-people link) shows ` [guest]` after the name in the Principal column and in CSV exports, so external identities stand out even when their display name looks like an internal user.

## Reducing oversharing with the rules

A practical sequence:

1. **Run the defaults first.** With all six rules on, `X` (scan all) on each tab gives a full exposure inventory. Export (`E`) before revoking anything.
2. **Kill the worst exposure first.** Anonymous links and Everyone grants are the two categories where access requires no account at all — filter the findings view (`F`) to those categories and revoke them in the first pass.
3. **Then cut implicit internal blast radius.** Org-wide links and EEEU grants are what Copilot and other AI agents surface to any employee on demand. Most org-wide links were created for convenience ("share to the team") and are safe to replace with named-group access.
4. **Triage guests last.** Guest links and guest grants are often legitimate. Sort by the Created column (Setup > tenant > "Enable link-date lookup") and revoke anything older than the project it belonged to, then spot-check the remainder with the external parties.
5. **Lock the tenant down so it stays clean.** After revocation, use the [[Tenant-Hardening]] tab to disable anonymous links tenant-wide and default new links to specific people, so the categories stay quiet on rescan.

## Target discovery

- **Auto-enumerate** from the tenant admin API (press `Enter` on the tab). The progress modal shows a running "Retrieved N so far" count that advances once per server page; on large OneDrive tenants the first page can take a while to arrive. The enumerated list is written to the scan cache immediately, so the next launch restores it instead of re-enumerating. `Esc` cancels (takes effect when the current server page returns); if enumeration fails, the error is shown and logged and `Enter` retries. Locked or inaccessible sites and OneDrives (LockState other than `Unlock`) cannot be scanned and are not listed; each one is logged at `WARN` level with its URL and LockState ("Not listed (never scanned)"), so check the Log tab if a site you expect is missing.
- **Manual URL entry** (`U`)
- **CSV import** (`I`)

Per-site failure isolation: a site that will not connect or scan is logged and the run continues.

**Retries and incomplete scans.** Reads that fail with a transient error (for example an HTTP timeout) are tried up to 3 times with a short pause (2 s, then 4 s). This covers a library's root folder, each page of its items, every permission and role-assignment read (site, library and item), and the sharing-link read of each file and folder. An item that was deleted while the scan ran (HTTP 404) is the only failure skipped quietly: it is logged at `WARN` level by item id (never by file name) and does not make the target incomplete. A sharing-link read that fails any other way marks the target incomplete (one entry per library, with the number of items and the first three item ids). An items page is retried from the last item Id already read, never from the start of the library. If a part of a site still cannot be read, for example a library whose root folder is unreadable or whose item list stops partway, that part is skipped, the failure is logged at `ERROR` level with the library name (items read before the failure are still checked, and the library is not counted as scanned), and the target is shown with a red `! Incomplete` status instead of `Clean`. An incomplete target is never reported as clean: it is left out of the `scanned:` summary, counted in `incomplete:N` on the status line, listed under the `Failed` filter, and kept as `Incomplete` after its findings are revoked. Findings found in the parts that could be read are kept (`Enter` opens them, and they are listed under the `Findings` filter). Select the target and press `S` to scan it again.

Once anything is scanned, the status line above the target list always shows a running summary: `scanned:N (X clean, Y with findings, Z total findings)`. Per-target counts live in the Findings column; `Enter` drills into one target, `G` aggregates all findings.

The target list also shows **Files** and **Storage** columns. Storage is the tenant-reported usage (`StorageUsage`, includes version history and recycle bin), filled in at enumeration with no extra calls; blank for manually added or CSV-imported targets. Files is the count of files (folders excluded) across the scanned document libraries, filled in by the scan.

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
| `C` | Clear the list and reload it from the tenant (Y/N confirm; discards scan results for the tab; resets the filter to `All`, except `Unprovisioned` on the OneDrives tab, which is kept and reloaded) |
| `L` | Restore the saved scan session |
| `E` | Export menu: `C` CSV, `X` Excel report |

## Keys: findings list

| Key | Action |
|---|---|
| `Space` | Toggle selection (`A` all, `N` none) |
| `/` | Live search |
| `F` | Cycle category filter |
| `R` | Revoke selected (typed `REVOKE` confirmation) |
| `E` | Export menu: `C` CSV, `X` Excel report |
| `Esc` | Back to target list |

## Revocation behavior

- Multi-select revoke with a **typed `REVOKE` confirmation**. In the all-findings view (`G`), revoking works across every affected site with one confirmation.
- Removal ordering: **links before direct grants, leaf items (File/Folder) before Library before Web**, so claim principals (EEEU, for example) are not de-provisioned out from under a later removal step.
- `AlreadyRevoked` responses are handled gracefully; re-running over the same scope is safe. A finding is marked `AlreadyRevoked` only when SharePoint reports that the principal or item no longer exists. Any other error (for example a connection or sign-in problem) is recorded as `Failed: <message>`, counts as not removed, and keeps the finding open.

## Evidence

Every scan and revoke run writes CSV evidence to `SSM-Exports/`:

- `SSM_<phase>_<site>_<timestamp>.csv`: BEFORE/REVOKED evidence per run
- `<tab>_targets_<timestamp>.csv` / `<tab>_findings_<timestamp>.csv`: view exports

Revoked links and grants cannot be restored from within the tool. Review the BEFORE CSV before typing `REVOKE`.

### Excel report (`E` → `X`)

Writes `SSM-Exports/SSM_REPORT_<SharePoint|OneDrive>_<site|ALL>_<timestamp>.xlsx`. Needs the `ImportExcel` module; you are asked to install it (CurrentUser) the first time. Scope follows the view: from the target list it covers every scanned target in the tab; from a findings view it covers the rows currently shown (filter and search applied).

| Sheet | Content |
|---|---|
| Summary | Tool version, tenant, scope, generated time, operator; totals (findings, sites affected, items scanned, links vs direct grants, anonymous links, removed/failed/not attempted); Copilot Exposure Indicator; counts by category, access and revoke status; top 10 sites |
| Findings | One row per finding: Site Title, Site URL, Location, Category, Sharing Type, Item Name, Full Path, Access, Shared With, Link Created, Reach (items), Revoke Status, Link Id, List Id, Item Id |
| Sites | Target-list and all-findings (`G`) exports only: Title, URL, Status, Findings, Items Scanned, Files, Storage (GB), Exposure Score, Band |

OneDrive reports (OneDrives tab) add **Owner UPN** and **Owner Object ID** (the owner's Entra ID user object id) after the URL column on the Findings and Sites sheets. The ids come from a single Graph user query at export time (one request per 999 users), which needs `User.Read.All` (see [[Requirements]]). Each OneDrive is matched on its tenant Owner first, then on the `/personal/<slug>` segment of its URL, so lists restored from the cache or imported from CSV resolve too. Cells stay blank when no unique user matches (deleted user, or two UPNs that map to the same slug). If the Graph query fails, the report is still written with blank owner columns and the message names the cause.

#### Copilot Exposure Indicator

A heuristic, not a Microsoft metric. Each finding is weighted by how wide its audience is (Anonymous link 5, EEEU 5, Everyone 5, Organization link 3, Guest link 2, Guest grant 2, other 1) and multiplied by its *reach*: 1 for a file or folder, the library item count for a library-level grant, the site item count for a web-level grant.

`Score = min(100, round(sum(weight × reach) / items scanned × 1000))`, banded Low (0-10), Medium (11-40), High (41-70), Critical (71-100). The raw "items overshared %" is shown next to it.

Limits: hidden/excluded libraries are not in the denominator; folder sharing counts as one item; inherited exposure is estimated via reach, not verified per item. Results restored from a cache written before this feature show `n/a` until the target is rescanned.

## Scan cache

Enumerated target lists and scan results are cached per tenant in `SSM-Cache/<tenant-slug>/session.json` and survive a restart; `L` restores the saved session on demand. During a scan or revoke run the cache is written at most every 10 seconds and once more when the run ends or is cancelled, so an interrupted run loses at most the last few targets' results (a save of 100k targets takes about half a second, which used to be paid per target). The cache holds one session per install directory, so two installs on the same machine get independent caches. When the list on screen came from the cache, the status line above it reads `from cache (saved <date>, C reloads)`. A restored session may be stale relative to the tenant's current sharing state; rescan before acting on old results, or press `C` to discard the list and enumerate the tenant afresh. The cache contains directory data, so treat the directory accordingly.

## Sharing-link age (optional)

Setup > tenant > **"Enable link-date lookup"** makes scans also fetch each link's Created/CreatedBy via SharePoint REST (slower; one extra call per shared item). Shown as a Created column in the findings view and in CSV exports. Useful when deciding whether an old link is safe to revoke.
