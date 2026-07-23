# Changelog

## [Unreleased]

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
