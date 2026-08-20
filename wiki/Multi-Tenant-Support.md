# Multi-tenant support

One install manages multiple tenants. Each tenant has its own:

- Auth configuration (delegated or app-only)
- Scan cache (`SSM-Cache/<tenant-slug>/`)
- Exports
- Settings such as link-date lookup

## Setup tab: the tenant hub

The Setup tab lists all tenants with active/default/configured markers.

| Key | Action |
|---|---|
| `Up`/`Down` | Move between tenants |
| `Enter` | Per-tenant actions: switch, edit config, register apps, renew cert, enable link-date lookup, set default, remove |
| `A` | Add a tenant |

## Switching

- `T` on any non-target tab opens the tenant switcher.
- The tool boots into the last-used tenant and restores its scan cache.
- Switching tenants resets the Sharing tab (posture cleared, reload required) so the previous tenant's settings are never shown as current.

## Configuration format

`~/.sharepoint-sharing-manager.json` stores a named `Tenants` map with a `DefaultTenant`. A legacy flat v1 single-tenant config migrates to v2 automatically on first launch, and cache and exports carry over.

## Removing a tenant

The Setup tab's remove action can delete the tenant's Entra app registration and certificate along with its local config entry, for per-tenant cleanup without touching the rest.
