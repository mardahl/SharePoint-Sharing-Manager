# Setup Tab Redesign + Tenant→Sharing Rename — Design

Date: 2026-08-19
Target release: 1.5.0

## Problem

Multi-tenant support shipped in 1.4.0, but entry points are undiscoverable: the tenant
switcher (T) and tenant list (L on Setup) appear in no footer or help text. The Setup
tab still presents flat auth actions (D/C/W/X) that silently operate on the *active*
tenant, and the tab named "Tenant" actually shows tenant-wide *sharing posture* — a
naming collision now that "tenant" means an account you manage.

## Decisions (from brainstorming)

- Setup tab shows the tenant list on the page itself (cursor-navigated).
- Enter on a tenant opens a full action modal (not per-row hotkeys).
- Tab "Tenant" renamed to "Sharing" (internal `Kind='Tenant'` unchanged).

## Design

### 1. Rename tab "Tenant" → "Sharing"

- `src/00-globals.ps1`: tab entry `Name = 'Sharing'`; `Kind` stays `'Tenant'` so all
  `switch ($tab['Kind'])` dispatch (views, keys, hints) is untouched.
- Any user-facing strings that call this tab "Tenant" (help modal, messages) updated to
  "Sharing".

### 2. Setup tab becomes tenant list view

`Add-SetupView` rewritten:

- Header row 3: ` Tenants`.
- One row per tenant: cursor highlight, name, `[active]` / `[default]` tags, auth mode,
  and a config-completeness marker:
  - `configured` — entry passes the same checks as `Test-SsmAuthReady` (ClientId + for
    AppOnly: Tenant + Thumbprint/CertPath)
  - `not configured` — otherwise
- Below the list: `Config file : <path>` and `PnP module : installed (vX)` lines (kept
  from current view).
- A trailing `<add new tenant>` row is NOT rendered in the view; adding is via the `A`
  key (consistent with `U add url` on Targets).
- Setup tab state gains `Cursor = 0` in `$script:Tabs` entry; cursor clamps to list
  length on render.

### 3. Setup keys

`Invoke-SetupKey` rewritten:

- `UpArrow`/`DownArrow` — move cursor over tenant names.
- `Enter` — open `Show-TenantActionsModal -Name <selected>` (new function in
  `60-setup-actions.ps1`).
- `A` — add-tenant flow (existing input + `Add-SsmTenant` + success/warn modals,
  extracted from `Show-TenantListModal`).
- Old flat keys `D/C/W/X/L` on Setup are removed. `L`'s logic is absorbed into the
  view + action modal; `Show-TenantListModal` is deleted.
- `Invoke-SetupAction` stub deleted (registration functions exist for real now).

### 4. Tenant action modal

New `Show-TenantActionsModal -Name <n>` in `60-setup-actions.ps1`:

Options (Show-ListModal):
1. `Switch to this tenant` — existing `Switch-SsmTenant`; hidden if already active.
2. `Edit config` — existing `Edit-SsmConfig` flow (field-by-field editor + Save-SsmAuth).
3. `Register delegated app` — existing `Register-SsmDelegatedApp`.
4. `Register cert app` — existing `Register-SsmAppOnlyApp`.
5. `Renew certificate` — existing `Update-SsmCertificate`.
6. `Set as default` — existing `Set-SsmDefaultTenant`.
7. `Remove tenant` — existing `Invoke-RemoveTenantFlow` (typed DELETE + EXPORTS prompts).
8. `Cancel`

Auth-mutating actions (2–5) operate on the selected tenant: if it is not the active
tenant, run `Switch-SsmTenant -Name $n` first (existing behavior: swaps auth, clears
tabs, repaths cache/exports), then run the action. This reuses the single-auth-globals
model instead of introducing parallel per-tenant auth state.

Registration/cert actions are no-ops with a warn modal when the tenant lacks required
fields (same guards the current flows already have).

### 5. Hints & help

- `Get-TabHints` Setup branch: `@('Up/Dn','move'),@('Enter','actions'),@('A','add tenant'),@('T','switch'),@('1-6','tab'),@('?','help'),@('Q','quit')`.
- Non-Targets tabs gain a `T tenants`/`T switch` hint where missing (Sharing, Log,
  About) — the switcher works there but is invisible today.
- `Show-HelpModal`: add a Tenants section: T = quick-switch (not on Targets), Setup
  tab = manage tenants (add/configure/default/remove), per-tenant cache/export paths
  one-liner. Fix Sharing-tab description to say "Sharing".

### 6. Unchanged

- T switcher modal (`Show-TenantSwitcherModal`) stays as-is.
- Config schema, tenant CRUD helpers, migration, remove flows — untouched.
- Targets tab keeps T = rules (switcher already excluded there).

## Files touched

- `src/00-globals.ps1` — tab rename, Setup `Cursor` state.
- `src/65-views.ps1` — `Add-SetupView` rewrite, `Get-TabHints` Setup + T hints.
- `src/60-setup-actions.ps1` — new `Show-TenantActionsModal`, extracted add-tenant
  helper; delete `Show-TenantListModal`.
- `src/75-key-dispatch.ps1` — `Invoke-SetupKey` rewrite; delete `Invoke-SetupAction`.
- `src/20-modals.ps1` — help modal Tenants section + Sharing wording.
- `CHANGELOG.md`, `README.md` (keys/setup sections), version bump to 1.5.0.

## Testing

Extend `tests/` (existing Pester-less `.tests.ps1` harness):

- View-level: Setup view renders tenant rows with active/default/configured markers
  (string-assert on frame lines, as existing view tests do).
- Key dispatch: Up/Dn moves Setup cursor with clamping; Enter on row invokes action
  modal (stub `Show-ListModal`); A invokes add flow; D/C/W/X/L no longer fire on Setup.
- `Show-TenantActionsModal`: selecting an auth action on a non-active tenant calls
  `Switch-SsmTenant` first (assert call order with stubs).
- Tab bar shows "Sharing", not "Tenant".

## Out of scope

- Concurrent multi-tenant sessions, cross-tenant views (still out, per multitenant spec).
- Editing tenant display name (add+remove covers it).
- Reordering tenants in the list.
