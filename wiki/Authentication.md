# Authentication

Two modes, both registered from the **Setup** tab (`Enter` on the tenant → actions list).

## App-only certificate mode ("Register cert app"): recommended

- Registers an Entra app with **application** permissions `Sites.FullControl.All` (SharePoint) and `Sites.FullControl.All` (Graph).
- Generates and uploads a **self-signed certificate valid one year**.
- Once consented, **no per-target admin role is needed**. This removes the requirement to be Site Collection Admin on every OneDrive, which is what makes large-scale OneDrive cleanup practical.
- Admin consent for application permissions requires Global Administrator or Privileged Role Administrator. The wizard displays a consent URL that can be forwarded to whoever holds that role; the tool picks the app up once consent lands.
- Certificate files live in `~/.sharepoint-sharing-manager-cert/`, one PFX per tenant (filename carries the tenant slug, non-Windows only). Renewal is built into the Setup tab's per-tenant actions.
- Re-registering when the app already exists in Entra no longer fails outright: the wizard offers to re-key the existing registration (looks up the Client Id, attaches a fresh certificate).
- Operator-context actions that manage the app registration itself (re-key, certificate renewal, app deletion) sign in through Microsoft's multi-tenant **PnP Management Shell** app, never through the tenant's own app-only registration — app-only apps hold no delegated Graph scopes, so their tokens cannot manage app registrations regardless of the operator's role. The first such action in a tenant prompts for admin consent to the PnP Management Shell app. If sign-in fails with `AADSTS700016` mentioning client id `31359c7f-bd7e-475c-86db-fdb8c937548e`, that id is the PnP Management Shell, not your app: consent it once via the URL the tool offers to open, then retry.

## Delegated interactive mode ("Register delegated app")

- Registers an app for interactive sign-in (MSAL, via PnP.PowerShell).
- The signed-in operator's permissions apply: **Site Collection Admin** on each target site/OneDrive to scan and revoke, **SharePoint Administrator** for the Sharing tab.
- Every action is attributable to the signed-in operator in the audit log.
- Practical for a handful of sites; painful for tenant-wide OneDrive cleanup.
- Registering when the app already exists in Entra offers to adopt it: the tool looks the Client Id up by app name (operator sign-in via PnP Management Shell) and saves it to the tenant's config. Covers the case where the local config lost the Client Id.

## Comparison

| | App-only certificate | Delegated |
|---|---|---|
| Per-OneDrive Site Collection Admin | Not required | Required |
| Consent needed | Global Admin / Privileged Role Admin (one time) | Standard app consent |
| Audit attribution | The app registration | The signed-in operator |
| Best for | Tenant-wide scans, OneDrive cleanup | Small scopes, quick checks |

## Configuration storage

Sign-in configuration lives in `~/.sharepoint-sharing-manager.json`, one entry per tenant, plus a default tenant name. A legacy flat single-tenant config migrates to the multi-tenant format automatically on first launch.
