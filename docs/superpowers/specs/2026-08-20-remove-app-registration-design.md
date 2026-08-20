# Remove app registration — design

Date: 2026-08-20

## Problem

`Register-PnPEntraIDAppForInteractiveLogin` (delegated) and `Register-PnPAzureADApp` (app-only) both create an Entra app named `SharePoint-Sharing-Manager`. Once one mode is registered, switching to the other fails because the app already exists. There is no in-app way to remove the registration per tenant.

## Solution

New tenant action **"Remove app registration"** in `Show-TenantActionsModal` (src/60-setup-actions.ps1).

### Flow

1. Guard: tenant entry must have `ClientId` set; otherwise warn ("nothing to remove") and return.
2. Typed confirmation (`REMOVE`): lists what will be deleted — Entra app, local cert (PFX file or `CurrentUser\My\<thumbprint>` on Windows), and the auth fields in the tenant's config entry. Tenant entry itself, cache, and exports stay.
3. Execute, collecting errors per step (no abort on first failure):
   - **Delete Entra app**: `Connect-PnPOnline -Url https://<tenant>-admin.sharepoint.com -Interactive -ClientId <current ClientId>` then `Invoke-PnPGraphMethod -Method Delete -Url "applications(appId='<ClientId>')"`. Runs on main buffer via `Invoke-OnMainBuffer` like the register flows. Requires Application Administrator or app owner.
   - **Delete local cert**: same logic as `Remove-SsmTenantData -IncludeCert` (thumbprint → cert store on Windows; else PFX file at `CertPath`).
   - **Clear config**: blank `AuthMode`, `ClientId`, `Thumbprint`, `CertPath`, `CertExpires` in `$script:Auth`, then `Save-SsmAuth`. Keep `Tenant` and `AdminUrl` so re-registration doesn't re-ask the tenant name.
4. Result modal: per-step outcome (app deleted / cert deleted / config cleared / warnings).

### Menu

- Add `'Remove app registration'` to `$options` in `Show-TenantActionsModal`, plus its switch arm. Add to `$needsAuth` list so switching to a non-active tenant happens first (matches Edit config / Register flows).
- Help modal (src/20-modals.ps1, Setup tab section, ~line 624): extend the line to mention the new action. It's reachable via Enter → actions, so no dedicated hotkey needed; help text just notes "remove app registration" as an action.

## Non-goals

- No Graph app deletion via app-only auth (the app can't delete itself; delegated sign-in is the documented path).
- No cache/export deletion — existing "Remove tenant" covers that.
