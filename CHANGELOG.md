# Changelog

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
