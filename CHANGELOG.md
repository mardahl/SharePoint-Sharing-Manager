# Changelog

## [Unreleased]

## [1.10.1-rc.3] - 2026-09-21

- Fix: secondary-admin Add/Remove (`M`) sat on a blank screen after the UPN
  prompt while it connected to the admin site, resolved the account, and
  ran a connect + admin read against every selected OneDrive. A spinner and
  progress modal now cover that whole stretch, per-target, and Esc during
  preflight aborts before the confirmation step.
- UI: row-3 context values (selected count, filter, sort, search, scan
  counts, cache time) are color-highlighted so they stand out from labels.

## [1.10.1-rc.2] - 2026-09-19

- Fix: pre-provision (`P`) showed no progress modal after the browser
  sign-in - the modal was only painted when a 200-user batch finished, so
  a single-batch run looked frozen. The modal and spinner now appear
  before the first request, and the Graph/personal-site loading phase
  runs under the spinner too.

## [1.10.1-rc.1] - 2026-09-15

- Fix: loading the OneDrives tab and the unprovisioned pre-check paged
  through every site collection in the tenant (the CSOM `Include` personal
  site filter adds OneDrives on top of regular sites), so the progress
  counter showed the total site count and the load was far slower than
  needed. Personal sites are now requested server-side by template
  (`SPSPERS`), and the Sites tab explicitly excludes them.

## [1.10.0] - 2026-09-15

- Add: OneDrive pre-provisioning (`P`, OneDrives tab). Loads every enabled
  member user with an Enabled SharePoint service plan whose personal site
  does not exist yet (diff of Graph `/users` against the tenant's personal
  sites, by owner UPN and `/personal/<slug>`) as rows under a new
  `Unprovisioned` filter (`F` cycle, OneDrives tab only; the rows never
  appear under `All`) with an orange `!` badge. Select rows with Space/`A`,
  press `P`, type `PROVISION`, and only the selection is submitted via
  `Request-PnPPersonalSite` in batches of 200; those rows switch to
  `Requested`. Placeholder rows are skipped by scans, revoke and admin
  actions and are not saved to the session cache. `Enter` on an empty
  Unprovisioned view loads them too. Evidence:
  `SSM_ONEDRIVE_UNPROVISIONED_<stamp>.csv` (when at least one user is
  found) and `SSM_ONEDRIVE_REQUESTED_<stamp>.csv` (`Upn, Batch, Status,
  Error`).
- Note: the provisioning request itself runs on a separate interactive
  sign-in. The service authorizes personal-site provisioning only for
  tokens carrying the SharePoint scope `AllProfiles.Manage`, which exists
  solely on Microsoft's first-party SharePoint Online Management Shell app;
  app-only certificate tokens and delegated tokens from a custom app are
  rejected with "Attempted to perform an unauthorized operation"
  (pnp/powershell#4329). After `PROVISION` a browser sign-in opens via that
  client id (`9bc3ab49-b65d-410a-85ad-de819febfddc`) on the tenant admin
  site; sign in as a SharePoint Administrator. The connection is kept for
  the session; the tool's own connection is unchanged. No extra app
  permission is needed. Live-validated by an operator against an app-only
  tenant.
- Change: `Get-TenantTargets` paging loop factored into
  `Get-SsmTenantSiteProperties` (shared with the personal-site owner set);
  no behaviour change.
- Docs: new wiki page OneDrive-Pre-Provisioning; Authentication,
  Requirements, README and help updated.

## [1.9.0] - 2026-09-14

- Add: the Sites/OneDrives status line shows `from cache (saved <date>,
  C reloads)` whenever the list on screen was restored from
  `session.json`, so a stale list is never mistaken for a fresh one.
- Add: `C` on the Sites/OneDrives tabs clears the list (Y/N confirm),
  drops it from the session cache, and re-enumerates the tenant.
- Fix: the footer key bar always shows `? help` and `Q quit`; on narrow
  terminals the middle hints are trimmed instead.
- Fix: target enumeration (`Enter` / Scan all on an empty Sites or
  OneDrives tab) now shows real progress. It drives the same paged CSOM
  call `Get-PnPTenantSite` uses internally, but updates the modal's
  "Retrieved N so far" counter after every server page instead of sitting
  on a static spinner until the whole tenant has been buffered.
- Fix: the enumerated target list is now saved to the session cache as
  soon as it is loaded (previously only a scan or revoke wrote the cache),
  so restarting the tool no longer forces a full re-enumeration of every
  OneDrive when nothing was scanned yet.
- Add: Manage Secondary Admin (`M`, OneDrives tab) gains a **List**
  operation alongside Add/Remove. Screen-only and read-only: shows every
  current site collection admin (Title/UPN/login and Entra object id when
  resolvable) grouped by selected target, for single or bulk selection.
  No UPN prompt, confirmation, export, or directory/Graph lookup;
  unresolved principals stay visible instead of being hidden, and an
  empty result is reported as "no administrators found," not a failure.
  A read failure on one target is logged and the rest of the selection
  still lists. The membership query is now factored into one shared
  helper, `Get-SsmOneDriveAdmins`, used by List and the existing
  Add/Remove preflight/mutation read.
- Fix: Manage Secondary Admin (`M`, OneDrives tab) membership read -
  `Get-SsmOneDriveAdminState` requested `AadObjectId.NameId`/
  `AadObjectId.NameIdIssuer` (dotted paths) from
  `Get-PnPSiteCollectionAdmin -Includes`. Those dotted names pass
  PnP.PowerShell's `-Includes` ValidateSet but are rejected client-side by
  the CSOM query translator (`InvalidQueryExpressionException: The query
  expression is not supported.`) - never a missing Graph scope, app
  permission, or tenant-provisioning issue. Fixed by requesting the bare
  top-level `AadObjectId` scalar, which already returns all of its own
  fields in one round trip. Confirmed offline against the installed
  PnP.PowerShell/CSOM assemblies - see `tests/onedrive-admin-csom.ps1`.
- Fix: Manage Secondary Admin (`M`, OneDrives tab) diagnostics - every
  preflight/identity/evidence failure path now logs the original
  exception via `Write-SsmErrorLog`/`Write-SsmLog` instead of being
  swallowed. Preview and mixed-batch reports show the actual
  Blocked/Failed reason under each target instead of a bare
  classification word, and a per-target outcome line (action/target/
  result, no tokens or credentials) is logged for every run. The
  zero-eligible and batch-completion reports show the actual saved
  `SSM_ADMIN_<BEFORE|AFTER>` evidence paths, never claiming a path was
  saved when its export failed, and a final-evidence-flush failure after
  a completed/stopped batch is shown in the completion report, not only
  logged. No provisioning/API behavior changed: diagnostics-only.
- Note: Add/Remove ship with limited live validation. An operator reported a successful
  Add via app-only auth after the CSOM fix above (evidence: the app
  registration's own service principal recorded as actor) - Remove,
  owner-negative cases, bulk targets, and delegated auth are still
  unverified against a live tenant. See
  `docs/superpowers/specs/2026-09-07-onedrive-admin-api-validation.md`
  for the full matrix.

## [1.9.0-rc.1] - 2026-09-07

- Add: OneDrive secondary-admin management (`M`, OneDrives tab only) - add
  or remove the tenant's secondary site-collection-admin role on selected
  OneDrives, with directory UPN resolution, per-target preflight preview,
  typed `ADDADMIN`/`REMOVEADMIN` confirmation, and
  `SSM_ADMIN_<BEFORE|AFTER>_<operation-id>.csv` evidence.
  **PRERELEASE**: this is a release candidate, published so an authorized
  test tenant can validate owner-resolution and add/remove behavior live -
  it has not yet had that live validation, and the stable release line
  (currently v1.8.0) stays put until it does. App-only registration now
  additionally requests Graph `User.Read.All` (application) for exact UPN
  lookup; delegated mode needs no change (its existing default consent set
  already covers this). See the wiki's
  [OneDrive-Admin-Management](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/OneDrive-Admin-Management)
  page.
- Change: `.github/workflows/release.yml` now tags a release as a GitHub
  prerelease (`--prerelease --latest=false`) when the pushed tag has a
  `-suffix` (e.g. `v1.9.0-rc.2`), so it never displaces the "Latest" stable
  release; it also uses `gh release edit`/`gh release view` to decide
  create-vs-upload instead of relying on upload failure to imply "doesn't
  exist yet".

## [1.8.0] - 2026-08-21

- Add: guest principals are tagged ` [guest]` in the findings view and CSV
  exports, so external identities stand out even when the display name looks
  like an internal member.
- Change: the Sites tab now enables all six rule categories by default (was
  org-wide links only), matching the OneDrives tab, so a first scan covers
  every rule. `T` still narrows a run to specific categories.
- Add: Left/Right arrow keys switch tabs, same as Tab / Shift+Tab.
- Add: persistent scan summary in the SharePoint/OneDrive target views. Once
  anything is scanned, the context line shows `scanned:N (X clean, Y with
  findings, Z total findings)` so current scan results are visible at all
  times without drilling into rows.

## [1.7.0] - 2026-08-21

- Add: startup update check queries GitHub Releases and shows a one-line
  modal when a newer version exists, with a link to the download page and an
  assurance that settings, scan cache, and exports are untouched by updating.
  Notify-only - no auto-download. `Y` opens the releases page in the default
  browser.
- Fix: PATCH keyCredentials kept failing with `Invalid property 'Members'` -
  Invoke-PnPGraphMethod always JsonSerializer.Serialize()s its -Content, and
  PSObject-wrapped values (from its own GET response, or a pre-serialized
  string round-trip) leak phantom keys. The GET+PATCH now run as raw REST
  (Invoke-RestMethod with the connection's access token), no PnP serializer
  in the path.
- Fix: operator-context Graph actions (re-key, renewal, app delete) no longer
  sign in with the retired PnP Management Shell client (31359c7f-...) - it has
  no service principal in tenants that never consented it (mandatory own-app
  registration since Sept 2024), which produced a browser AADSTS700016 and a
  hung session. They now use the same first-party bootstrap client
  PnP.PowerShell's own register cmdlets use (1950a258-...), which any tenant
  that ever ran a registration has already consented.
- Fix: cert attach (re-key and renewal) sent the PEM text as the Graph key
  (`Cannot convert ... to Edm.Binary`) and used the `addKey` action, which
  requires a proof JWT signed by an EXISTING key on the app - precisely the
  key the operator no longer holds. Both paths now PATCH `keyCredentials`
  with base64 DER (existing keys preserved, new one appended); Application
  Administrator suffices, no proof needed.
- Add: app-name lookup logs every matched app (displayName + appId) and
  warns when several apps share the name - the first match is used.
- Fix: the re-key flow for an existing Entra app always failed with "found
  but no Client Id returned" - `Get-PnPAzureADApp` returns the client id as
  `AppId`, not `AzureAppId`. The lookup (now shared as `Find-SsmAppClientId`)
  reads the correct property.
- Add: registering a delegated app that already exists in Entra now offers to
  adopt the existing registration (look the Client Id up by name, save it to
  the tenant's config) instead of failing outright - covers the case where
  the local config lost the Client Id.
- Docs: README and wiki no longer claim `C`/`D` keys register apps on the
  Setup tab - those flat keys were removed in 1.5.0; registration runs from
  the per-tenant actions list (`Enter` → Register cert app / Register
  delegated app).
- Fix: registering an app-only cert app for a second tenant on macOS/Linux
  overwrote the first tenant's PFX (`SharePoint-Sharing-Manager.pfx` had a
  fixed name in a shared dir), breaking the first tenant's auth. PFX files
  are now named per tenant slug; cert renewal is slugged too.
- Add: re-registering when the Entra app already exists now offers a re-key
  flow (look up existing Client Id, attach a fresh certificate via Graph
  `addKey`) instead of failing outright.
- Fix: operator-context Graph calls (app deletion, certificate renewal,
  re-key) no longer sign in with the tenant's app-only registration - its
  tokens lack delegated Graph scopes, so Global Admins got `Forbidden`.
  These actions now use the PnP Management Shell multi-tenant app, which
  prompts for admin consent on first use per tenant.
- Add: all CIS-baseline knobs are now individually visible/adjustable on the
  Sharing tab: `LegacyAuthProtocolsEnabled`, `EnableAzureADB2BIntegration`,
  `EmailAttestationRequired`, `EmailAttestationReAuthDays` (19 settings).
- Fix: Enter on the four new CIS rows opened the wrong picker (the view's
  row order and the settings' `N` numbers had drifted). The view, cursor
  nav and Enter now all index `$script:TenantSettings` by position - the
  `N` field is gone, so the two lists can't diverge again.
- Fix: Sharing tab now scrolls in small windows - per-row note lines were
  dropped (the highlighted row's note rides the header line), overflow is
  signalled with `↑ more above` / `↓ more below`, and PgUp/PgDn jump 10.
- Add: CIS alignment badge next to each Sharing tab value - green `CIS ✓`
  when the value meets the CIS 7.2.x recommended state (or is stricter),
  dim `CIS ✗` when not; settings without a CIS rule show no badge.
- Add: Sharing tab covers more of the tenant sharing surface:
  `SharingDomainRestrictionMode`, `FileAnonymousLinkType`,
  `FolderAnonymousLinkType`, `PreventExternalUsersFromResharing`,
  `ExternalUserExpirationRequired`, `ExternalUserExpireInDays` (15 settings).
- Change: sharing-capability values now show the SharePoint admin UI wording
  alongside the internal enum (e.g. `ExternalUserAndGuestSharing (Anyone)`),
  both in the posture view and the value picker.
- Fix: `RequireAnonymousLinksExpireInDays` note now states it applies to
  anonymous ("Anyone") links only; `0`/blank = never (not `-1`).
- Add: `C` applies the CIS Microsoft 365 Foundations 7.2.x sharing baseline
  (L1, or L1+L2 via picker; typed `CIS` confirmation). Current values are
  snapshotted to the per-tenant cache dir first. `Z` reverts to the latest
  snapshot (typed `REVERT`). CIS 7.2.6 (domain allowlist) is shown as a
  notice but not applied - the allowed-domains list is org-specific.

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
