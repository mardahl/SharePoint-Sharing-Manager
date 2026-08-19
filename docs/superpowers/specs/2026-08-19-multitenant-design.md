# Multi-tenant support design

Date: 2026-08-19
Status: Approved
Target release: 1.4.0

## Goal

SharePoint Sharing Manager supports multiple configured SharePoint Online
tenants. The operator can switch the active tenant in-app, and all
tenant-scoped state (auth settings, scan cache, export CSVs, certificate
material) is isolated per tenant. Removing a tenant optionally deletes its
certificate, cache, and exports.

## Non-goals

- Concurrent sessions against multiple tenants in one process. One PnP
  connection at a time remains the model; switching disconnects first.
- Cross-tenant aggregate views or comparisons.
- Migrating certificates between tenants.

## Configuration schema (v2)

Single config file, `~/.sharepoint-sharing-manager.json`:

```json
{
  "Version": 2,
  "DefaultTenant": "contoso",
  "Tenants": {
    "contoso": {
      "AuthMode": "AppOnly",
      "ClientId": "...",
      "Tenant": "contoso.onmicrosoft.com",
      "AdminUrl": "https://contoso-admin.sharepoint.com",
      "Thumbprint": "A1B2...",
      "CertPath": "",
      "CertExpires": "2027-08-19"
    },
    "fabrikam": { "...": "..." }
  }
}
```

- Tenant map key = tenant display name chosen by the operator. Used as the
  human label in the switcher and as the basis for on-disk paths.
- `DefaultTenant` selects which entry is loaded at startup. Empty string =
  no default; the Setup tab is the landing spot, matching the current
  no-config behaviour.

### Legacy migration (v1 → v2)

A flat config (no `Tenants` key) is migrated in place on first load:

1. Derive tenant name from `Tenant` (strip `.onmicrosoft.com`) falling back
   to the AdminUrl host segment, then to `default` if neither is present.
2. Move flat keys into `Tenants[<name>]`, set `DefaultTenant = <name>`,
   `Version = 2`, save.
3. Move `SSM-Cache/session.json` → `SSM-Cache/<slug>/session.json` if
   present. Move `SSM-Exports/*` → `SSM-Exports/<slug>/*` if present.
4. Log the migration at `OK` level.

## Paths

Paths derive from a slug of the active tenant name:

- Slug = lowercase, any character not in `[a-z0-9-]` replaced with `-`,
  collapsed repeats, trimmed to 40 chars.
- `$script:CacheDir  = SSM-Cache/<slug>`
- `$script:CacheFile = SSM-Cache/<slug>/session.json`
- `$script:ExportDir = SSM-Exports/<slug>`

`Set-SsmTenantPaths -Name <tenantName>` recomputes these globals. Called
once at startup (after config load) and on every tenant switch. The
`README.txt` warning file is written into each new cache subdir.

## Switching tenants

Key `T` from the main UI (global, not tab-scoped) opens
`Show-TenantSwitcherModal`:

- One row per configured tenant: name, auth mode, cert days-remaining,
  cache indicator (`cached: N items @ <timestamp>` from
  `Test-SsmCacheAvailable` against that tenant's path).
- Active tenant marked; selecting it is a no-op.
- Selecting a different tenant runs `Switch-SsmTenant -Name`:

1. If the current Targets tabs hold unscanned or selected findings, show a
   confirmation modal ("Discard current session state for <old-tenant>?").
2. `Disconnect-PnPOnline` guarded by try/catch; clear `$script:Conn`.
3. Reset every Targets tab: `Items = @()`, `View = @()`,
   `Loaded = $false`, `Selected` cleared, `Mode = 'Targets'`.
4. Load the tenant's auth block into `$script:Auth` (same shape as today).
5. `$script:TenantName = <name>`; `Set-SsmTenantPaths -Name <name>`.
6. Re-run `Test-SsmCacheAvailable` so the existing restore hint appears on
   the new tenant.
7. Update the Setup tab's state and the title bar.
8. Log the switch.

Persisting `DefaultTenant` is explicit, not implicit: the switcher has a
separate `Set default` key. Switching alone does not rewrite the config
file.

## Setup tab

Replaces the single-tenant form with two sections:

1. **Tenant list**: rows of configured tenants, cursor keys to move.
   - `A` add tenant (name prompt, then existing auth wizard).
   - `E` edit selected tenant's auth (reuses existing wizard).
   - `D` remove selected tenant (see below).
   - `Enter` or `*` set selected as default.
2. **Active tenant details**: read-only summary of the currently loaded
   auth, unchanged from today.

### Remove tenant flow

Blocked when the selected tenant is the active one.

Confirmation modal lists everything that can be deleted and offers two
checkboxes:

```
Remove tenant 'fabrikam'?

  Auth mode      AppOnly
  Certificate    CurrentUser\My\A1B2C3... (expires 2027-08-19)
  PFX file       (none)
  Cache          SSM-Cache/fabrikam/ (12 items, saved 2026-08-19)
  Exports        SSM-Exports/fabrikam/ (6 CSV files)

  [x] Delete certificate and scan cache
  [ ] Also delete export CSVs

  [Remove]  [Cancel]
```

On confirm, in order:

1. If first checkbox and `Thumbprint` set on Windows:
   `Remove-Item Cert:\CurrentUser\My\<thumbprint>`.
2. If first checkbox and `CertPath` points at an existing file:
   `Remove-Item -LiteralPath`.
3. If first checkbox: `Remove-Item -Recurse -Force` on the cache subdir.
4. If second checkbox: `Remove-Item -Recurse -Force` on the export subdir.
5. Remove the entry from `Tenants`, clear `DefaultTenant` if it pointed
   here, save config.

Each step is wrapped; a failure logs a warning and the sequence continues.
Outcome is logged at `OK` with counts of what was deleted.

Certificates are unique per tenant. The issuance wizard never offers an
existing thumbprint picker across tenants; it always generates a new cert
for the tenant being added. No reuse guard is required at removal time.

## Cache and exports

`70-cache.ps1` keeps its current logic; all reads/writes already flow
through `$script:CacheFile` / `$script:CacheDir`. Same for `50-csv.ps1`
and `$script:ExportDir`. No signature changes.

`Test-SsmCacheAvailable` and `Restore-SsmCache` are path-driven and work
per tenant once paths swap.

## Files touched

- `src/00-globals.ps1` — add `$script:TenantName`, `$script:Tenants`,
  `$script:DefaultTenant`; defer `$script:CacheDir` / `ExportDir` to
  `Set-SsmTenantPaths`.
- `src/25-config.ps1` — v2 schema load/save, migration, tenant CRUD
  helpers, `Set-SsmTenantPaths`.
- `src/55-tenant-actions.ps1` — new `Show-TenantSwitcherModal`,
  `Switch-SsmTenant`, remove-tenant flow.
- `src/60-setup-actions.ps1` — tenant list UI section wiring.
- `src/75-key-dispatch.ps1` — bind `T` to switcher.
- `tests/` — add Pester cases: migration, slug, switch clears state,
  remove deletes cert+cache, remove of active tenant blocked.

## Error handling

- Config file unreadable or unparseable → treated as missing; Setup tab
  prompt as today.
- Migration failures logged; original file is rewritten only after a
  successful in-memory migration, and a `.bak` copy is kept alongside.
- Tenant name collision on add → inline error in the modal.
- Slug collision between two tenant names (e.g. `Contoso Ltd` and
  `contoso-ltd`) → detected at add time and rejected with an explanatory
  message.

## Testing

- Pester unit tests for `Get-SsmConfig` migration, slug function, tenant
  CRUD helpers, `Switch-SsmTenant` state clearing (mocked PnP), remove
  flow (mocked cert store + filesystem).
- Manual: two-tenant smoke pass — add, switch, scan, cache, remove,
  verify on-disk artefacts.

## Known issues / limitations

- Switching tenants discards in-memory scan results for the previous
  tenant; the on-disk cache is the only persistence. Restore flow covers
  reload.
- Export CSVs are evidence; deleting them is irreversible and gated
  behind the second checkbox.
- The certificate store delete is `CurrentUser` scope; certs installed to
  `LocalMachine` are outside this tool's scope and must be removed
  manually.
