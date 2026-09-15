# Authentication

Two modes, both registered from the **Setup** tab (`Enter` on the tenant → actions list).

## App-only certificate mode ("Register cert app"): recommended

- Registers an Entra app with **application** permissions `Sites.FullControl.All` (SharePoint), `Sites.FullControl.All` (Graph), and `User.Read.All` (Graph).
- OneDrive pre-provisioning (`P`, see [[OneDrive-Pre-Provisioning]]) does not use this app for the provisioning request: the service only accepts Microsoft's SharePoint Online Management Shell client, so that step opens its own interactive SharePoint Administrator sign-in. No extra application permission enables it.
- `User.Read.All` is requested so the OneDrive secondary-admin **Add/Remove** operations (`M`, OneDrives tab, limited validation - see [[OneDrive-Admin-Management]]) can resolve an entered UPN to an exact directory user; `List` needs no extra scope. New registrations get it automatically; the wizard shows the added scope and the reason before you confirm.
- **Existing app-only registrations made before this scope was added are not automatically changed.** The tool never PATCHes permissions onto an existing registration. If re-registering hits "already exists," the wizard's re-key path attaches a fresh certificate only - it does not add `User.Read.All`. To grant it: in the Entra portal, open the `SharePoint-Sharing-Manager` app registration → API permissions → add Microsoft Graph → Application → `User.Read.All` → grant admin consent (Global Administrator or Privileged Role Administrator).
- Generates and uploads a **self-signed certificate valid one year**.
- Once consented, **no per-target admin role is needed**. This removes the requirement to be Site Collection Admin on every OneDrive, which is what makes large-scale OneDrive cleanup practical.
- Admin consent for application permissions requires Global Administrator or Privileged Role Administrator. The wizard displays a consent URL that can be forwarded to whoever holds that role; the tool picks the app up once consent lands.
- Certificate files live in `~/.sharepoint-sharing-manager-cert/`, one PFX per tenant (filename carries the tenant slug, non-Windows only). Renewal is built into the Setup tab's per-tenant actions.
- Re-registering when the app already exists in Entra no longer fails outright: the wizard offers to re-key the existing registration (looks up the Client Id, attaches a fresh certificate).
- Operator-context actions that manage the app registration itself (re-key, certificate renewal, app deletion) sign in interactively with the same first-party bootstrap client that PnP.PowerShell's own register cmdlets use — never through the tenant's own app-only registration, whose tokens lack delegated Graph scopes. (The retired PnP Management Shell client id `31359c7f-...` is no longer used; it produced AADSTS700016 in tenants that never consented it.)

## Delegated interactive mode ("Register delegated app")

- Registers an app for interactive sign-in (MSAL, via PnP.PowerShell) with PnP.PowerShell 3.3.0's documented **default** delegated scopes: `AllSites.FullControl`, `Group.ReadWrite.All`, `User.ReadWrite.All`, `TermStore.ReadWrite.All`. No narrower scope override is requested by this tool.
- `User.ReadWrite.All` already exceeds what the OneDrive secondary-admin **Add/Remove** operations (`M`, limited validation - see [[OneDrive-Admin-Management]]) need for exact UPN lookup, so delegated mode needs no additional consent for those operations; `List` needs no directory scope at all.
- The signed-in operator's permissions apply: **Site Collection Admin** on each target site/OneDrive to scan and revoke, **SharePoint Administrator** for the Sharing tab.
- Every action is attributable to the signed-in operator in the audit log.
- Practical for a handful of sites; painful for tenant-wide OneDrive cleanup.
- Registering when the app already exists in Entra offers to adopt it: the tool looks the Client Id up by app name (operator sign-in via the bootstrap client) and saves it to the tenant's config. Covers the case where the local config lost the Client Id.

## Comparison

| | App-only certificate | Delegated |
|---|---|---|
| Per-OneDrive Site Collection Admin | Not required | Required |
| Consent needed | Global Admin / Privileged Role Admin (one time) | Standard app consent |
| Audit attribution | The app registration | The signed-in operator |
| Best for | Tenant-wide scans, OneDrive cleanup | Small scopes, quick checks |

## Configuration storage

Sign-in configuration lives in `~/.sharepoint-sharing-manager.json`, one entry per tenant, plus a default tenant name. A legacy flat single-tenant config migrates to the multi-tenant format automatically on first launch.

## OneDrive secondary-admin auth-mode status (validation status)

Neither auth mode's directory-lookup or admin-mutation behavior for the `M` feature has completed live validation. What's known so far:

| Mode | Directory scope present | Live-verified? |
|---|---|---|
| App-only | `User.Read.All` (Graph, application) - new registrations only | Add: operator-reported success. Remove: no |
| Delegated | `User.ReadWrite.All` (Graph, default) | No |

Graph's `Get drive` API is documented "Not supported" for application permissions in every variant, ruling it out for app-only owner reads; `List Drives` (`GET /sites/{siteId}/drives`) documents an application-permission path, and is the path covered by the operator-reported app-only Add above. The full validation matrix (Remove, owner-negative cases, delegated auth) is still pending. See [[OneDrive-Admin-Management]] and `docs/superpowers/specs/2026-09-07-onedrive-admin-api-validation.md` in the repo for the full gate.
