# Requirements

## Runtime

- **PowerShell 7.4+** on Windows, macOS, or Linux. There is no Windows PowerShell 5.1 compatibility target.
- A VT-capable terminal (the UI is raw ANSI escape sequences; it works over SSH).

## Modules

- [`PnP.PowerShell`](https://www.powershellgallery.com/packages/PnP.PowerShell) v3, the only dependency. Installed on demand at first launch, CurrentUser scope.

## Entra roles per task

| Task | Requirement |
|---|---|
| Create the app registration (either mode) | **Application Administrator** |
| Consent to application permissions (app-only mode) | **Global Administrator** or **Privileged Role Administrator** |
| Delegated mode: scan/revoke on a target | **Site Collection Admin** on that site or OneDrive |
| Delegated mode: Sharing tab | **SharePoint Administrator** |
| App-only mode | No per-target admin role needed once the app is consented |

## App-only permissions

App-only mode requests **application** permissions:

- `Sites.FullControl.All` (SharePoint)
- `Sites.FullControl.All` (Graph)

and uploads a self-signed certificate valid one year. Application Administrator can create the app registration, but admin consent for application permissions requires Global Administrator or Privileged Role Administrator. The setup wizard displays a consent URL that can be forwarded to whoever holds that role.

## Tenant URL assumption

The SharePoint admin site URL is derived from the tenant name as `https://<tenant>-admin.sharepoint.com`. Tenants where the SharePoint hostname does not follow this pattern (vanity domains, some multi-geo setups) need the Setup tab's config editor to override `AdminUrl` manually.
