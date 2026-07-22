# Changelog

## [Unreleased]

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
