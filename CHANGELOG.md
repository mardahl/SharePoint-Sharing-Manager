# Changelog

## [1.5.1] - 2026-08-19

- Fix: switching tenants now resets the Sharing tab (posture cleared, reload
  required) so the previous tenant's settings are never shown as current.

## [1.5.0] - 2026-08-19

- Change: Setup tab is now the tenant management hub: lists all tenants with
  active/default/configured markers; Enter opens per-tenant actions (switch,
  edit config, register apps, renew cert, set default, remove); A adds a tenant.
- Change: "Tenant" tab renamed to "Sharing" to avoid confusion with tenant
  management. Internal behavior unchanged.
- Change: removed flat D/C/W/X/L keys on Setup (absorbed into the per-tenant
  action modal). T quick-switcher unchanged.
- Fix: tenant switcher (T) now advertised in footer hints and help.

## [1.4.1] - 2026-08-19

- Fix: applying a True/False tenant hardening setting (e.g.
  `ShowEveryoneExceptExternalUsersClaim`) failed with
  "Cannot convert 'System.String' to ... System.Nullable`1[System.Boolean]" -
  the value is now cast to `[bool]` before calling `Set-PnPTenant`.

## [1.4.0] - 2026-08-19

- Add: multi-tenant support. Config (`~/.sharepoint-sharing-manager.json`) now
  stores a named `Tenants` map with a `DefaultTenant`, and a legacy flat v1
  config is migrated to v2 automatically on first launch (cache and exports
  are moved into per-tenant directories keyed off a slugified tenant name).
  The title bar shows the active tenant name (`[<tenant>]`, next to the
  version). `T` on any non-Targets tab opens a tenant switcher; switching
  tenants swaps the active auth, repaths cache/exports/logs to that tenant's
  directories, and clears the Sites/OneDrives target tabs. The Setup tab
  gains a tenant list with add (`A`, via the existing auth wizard),
  set-default, and remove flows - removing a tenant deletes its config entry
  and, behind a typed `DELETE` confirmation, its cached scan session and
  certificate together; CSV exports are deleted separately behind a typed
  `EXPORTS` confirmation.

## [1.3.3] - 2026-07-27

- Fix: a revoke could succeed and show "Revoked" in the TUI, but the session
  cache (`session.json`) still said "Findings" after a restart or a manual
  cache restore (`L`) - the underlying `RevokeStatus` on each finding was
  saved correctly, but the target's summary `Status`/`FindingCount` was not.
  Two gaps caused this: the single-target drill-down revoke (`R` inside a
  target's findings view) never saved the cache at all, and the bulk revoke
  (`R` on the target list, and the aggregate findings view) saved the cache
  per site *before* recomputing `Status`/`FindingCount` from the finalized
  `RevokeStatus` values, so every save persisted a stale "Findings" status.

## [1.3.2] - 2026-07-27

- Fix: the bulk revoke confirmation hid its `REVOKE` input field when many
  sites were selected. The dialog listed one full site URL per line, each
  wrapping to two lines, and the body was silently truncated to the terminal
  height - taking the typed-confirmation prompt and field with it, with no
  indication that anything was hidden. The site list now scrolls (Up/Down,
  PgUp/PgDn, Home/End) while the warning, prompt and input field stay pinned
  to the bottom of the box, and a `3-14 of 36` position counter appears in the
  footer whenever content is off screen. Sites that share a URL prefix now
  print that prefix once as a header, so each site fits on one line.
- Fix: revoking sharing froze the interface until the whole job finished, with
  no bar, no spinner and no way to stop. Both revoke paths now show a
  determinate progress bar that runs continuously across every affected site,
  with the item in flight, live OK/failed counts and a moving spinner during
  slow calls. Esc asks for confirmation and then stops after the current item;
  everything processed up to that point is still written to the evidence CSV
  and the session cache, and the completion report states where the run
  stopped.
- Fix: long option lists in picker modals were truncated with no way to scroll,
  which could leave the selection cursor on an invisible row.
- Fix: the progress bar overran its border on terminals narrower than about 64
  columns; its width is now derived from the terminal size. Modals also honour
  the same 80x20 minimum as the main screen instead of painting over the
  "Terminal too small" message.

## [1.3.1] - 2026-07-27

- Fix: the target list (Sites/OneDrives) crashed with `The property 'Count'
  cannot be found on this object` whenever a filter, search, or sort left
  exactly zero or one matching target - including an empty tab. This also
  broke session restore (`L`), since it re-sorts every target tab and a
  tenant with only one populated tab (e.g. OneDrives) always hits the
  empty-tab case on the other one (Sites). Root cause: `$items = if (...) {
  @(...) } else { @(...) }` re-streams the winning branch's output through
  the if/else expression before assignment, and PowerShell collapses a
  0-or-1-object pipeline result to `$null`/a scalar even though each branch
  itself was array-cast. `@()` now wraps the whole if/else instead of each
  branch.

## [1.3.0] - 2026-07-24

- Add: new "About" tab (last tab in the tab bar) showing the app's purpose,
  version, and author (Michael Mardahl), with dedicated keys - `G` opens the
  author's GitHub profile (github.com/mardahl) and `R` opens the project's
  releases page - directly in the default browser.

## [1.2.0] - 2026-07-23

- Add: scan results are now cached to `SSM-Cache/session.json` after every
  scan (including scan-all) and can be reloaded with `L` on the Sites/
  OneDrives target list, so a restart no longer means re-scanning everything.
  The cache directory carries a `README.txt` noting that it holds directory
  data and should be treated as sensitive.
- Add: `G` on the Sites/OneDrives target list opens an all-findings view that
  aggregates findings from every scanned target in that tab, with a `Site`
  column identifying which target each finding came from.
- Add: `R` now revokes in bulk from two places - on the target list it
  revokes every finding on the selected targets, and in the all-findings
  aggregate view it revokes every selected finding across every affected
  site. Both prompt once with the typed `REVOKE` confirmation regardless of
  how many sites are touched.
- Add: `X` on the Sites/OneDrives target list scans every not-yet-scanned
  target in one run, saving the cache incrementally so an interrupted
  scan-all resumes from where it left off instead of restarting.

## [1.1.1] - 2026-07-23

- Fix: `Invoke-SiteScan` threw `System.ArgumentException: Argument types do
  not match` and aborted the scan whenever a OneDrive/site had zero findings
  (or exactly one). Its two `return @($bag)` statements wrapped a
  `System.Collections.Generic.List[object]` with the array-subexpression
  operator, which fails on PowerShell 7.6 for list counts of 0 or 1. Changed
  to `$bag.ToArray()`, the same idiom already used elsewhere in the codebase.

## [1.1.0] - 2026-07-23

- Change: the Tenant tab is now a navigable list instead of a numeric menu.
  Its `1`-`9` shortcuts had taken over the digit keys, so the main-menu digit
  shortcuts (`1`-`5` jump to a tab) did nothing while the Tenant tab was
  focused. Digits now switch tabs from every tab; the Tenant settings are
  driven with Up/Down to move the cursor and `Enter` to load the posture or
  change the highlighted setting (`R` still refreshes).
- Add: loading the tenant sharing posture now shows the same spinner/progress
  modal as the scan and target-enumeration paths. `Connect` + `Get-PnPTenant`
  is a blocking single-threaded call, so previously the TUI froze on its last
  frame with no feedback while it connected; it is now visibly working.
- Add: fixed-value tenant settings (e.g. `SharingCapability`,
  `DefaultLinkPermission`, the People Picker claim toggles) are changed with a
  navigable value picker instead of free-text entry, so the operator selects a
  valid value with the arrow keys and `Enter` and can no longer type an
  invalid string. Only `RequireAnonymousLinksExpireInDays` (numeric) keeps
  text input.

## [1.0.5] - 2026-07-23

- Fix: pressing `Enter` on an empty Sites or OneDrives list froze the TUI with
  no feedback. Enter on an empty list enumerates targets from the tenant
  (`Connect` + `Get-PnPTenantSite`), a blocking single-threaded call - but
  unlike the scan path it drew no progress modal or spinner, so the main loop
  stopped reading keys and repainting and the interface appeared to hang doing
  nothing. Enumeration now shows the same spinner/progress modal as scanning,
  so it is visibly working and the spinner keeps animating while the call
  blocks.
- Fix: delegated interactive sign-in ran `Connect-PnPOnline` on the
  alternate-screen buffer, so any browser/consent prompt or console message
  was hidden behind the TUI. The interactive connect now runs on the main
  buffer (like the "Signing in" line already did), so the prompt is visible.

## [1.0.4] - 2026-07-22

- Fix: a single item or library with an unexpected shape aborted the entire
  OneDrive/site scan (e.g. `Argument types do not match`). Under
  `Set-StrictMode` the scan was less tolerant than the original standalone
  scripts, which log a problem and carry on. Scanning is now fault-isolated:
  a problematic item or library is logged in full and skipped, and the rest
  of the scan completes.
- Improved: scan failures now log full exception detail (type, inner
  exceptions, category, and script stack trace with the exact file and line)
  via `Write-SsmErrorLog`, instead of only the top-level message - so the
  offending item/line is identifiable from the log file alone.

## [1.0.3] - 2026-07-22

- Fix: saved sign-in configuration (`~/.sharepoint-sharing-manager.json`,
  including auth mode, tenant, certificate thumbprint/path) was never
  loaded back on startup - `Initialize-SsmAuth` existed but nothing called
  it, so `$script:Auth` always started from empty defaults regardless of
  what was previously saved.
- Fix: the tenant admin site URL is now derived from the tenant name
  (`https://<tenant>-admin.sharepoint.com`) instead of a separate manual
  prompt, since the tenant name is already known from setup/registration.
  Combined with the fix above, the admin URL is now actually remembered
  across restarts.
- Docs: noted the admin-URL derivation as a known limitation for tenants
  whose SharePoint hostname doesn't follow the standard pattern (vanity
  domains, some multi-geo setups) - override `AdminUrl` via the Setup tab's
  config editor in that case.

## [1.0.2] - 2026-07-21

- Fix: OneDrive/site scans could abort with `The property 'Email' cannot be
  found on this object` - a sharing-link grantee whose identity only
  resolved to a `SiteUser` (no linked Entra ID `User`, e.g. an unredeemed
  guest invite) tripped `Set-StrictMode`'s null-property check in
  `Get-GuestGrantees`. Both `SiteUser` and `User` are now null-guarded
  before use.
- Fix: pressing `1`-`5` on the Tenant tab jumped tabs instead of changing a
  tenant sharing setting - the tab-switch digit shortcut and the Tenant
  setting picker shared the same `1`-`5` key range, and the global tab
  switcher (which runs first) always won, making `Invoke-TenantSetting`
  unreachable from the keyboard. The Tenant tab now owns its digit range;
  use `Tab`/`Shift+Tab` to switch away from it.
- Added: 4 tenant hardening settings for org-wide sharing claims and EEEU
  (Everyone Except External Users) grants in the People Picker -
  `ShowEveryoneClaim`, `ShowAllUsersClaim`, `ShowEveryoneExceptExternalUsersClaim`,
  `AllowEveryoneExceptExternalUsersClaimInPrivateSite` - settings `6`-`9` on
  the Tenant tab.

## [1.0.1] - 2026-07-21

Fixes app-only certificate registration, which was broken on PnP.PowerShell
v3.3+ in the v1.0.0 release build.

- Fix: `Register-PnPAzureADApp` no longer accepts `-Interactive` on
  PnP.PowerShell v3.3+; removed the stale parameter from the app-only
  registration call
- Fix: read the certificate registration result safely when the cmdlet
  emits multiple pipeline objects (was collapsing to an array and missing
  the app id)
- Fix: use the correct `Certificate` property name when uploading a
  renewed certificate's public key
- Improved: error catches in setup actions and site connection now log
  full exception detail (type, category, inner exceptions, stack trace)
  instead of just the top-level message, to make future auth failures
  diagnosable from the log file alone

## [1.0.0] - 2026-07-21

Initial release.

- Terminal UI with Sites, OneDrives, Tenant, Setup and Log tabs
- Shared scan engine: anonymous / org-wide / guest links, guest / EEEU / Everyone grants, toggleable per tab
- Per-finding multi-select revoke with typed confirmation and BEFORE/REVOKED CSV evidence
- Target discovery: tenant enumeration, manual URL, CSV import
- Delegated (interactive) and app-only certificate auth; guided app registration incl. 1-year cert
- Tenant sharing posture view and hardening setters
