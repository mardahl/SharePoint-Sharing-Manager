# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) on this
repository instead. Reports are looked at on a best-effort basis - this is a
community tool maintained in spare time.

## Scope & threat model

SharePoint Sharing Manager is an **operator tool**: it runs with the
permissions of the signed-in administrator or app registration, and performs
only the actions the operator confirms. Relevant notes:

- **No credential handling.** Authentication is delegated entirely to
  `PnP.PowerShell` (MSAL under the hood), in either delegated (interactive)
  or app-only certificate mode. The tool never sees, stores, or logs
  passwords, tokens, or client secrets.
- **No telemetry.** The only network traffic is to SharePoint Online and
  Microsoft Graph endpoints, initiated explicitly by the operator.
- **Local artifacts may be sensitive.** Log files
  (`SharePoint-Sharing-Manager_*.log`) and CSV exports (`SSM-Exports/*.csv`)
  contain directory data: site URLs, display names, user principal names,
  and revoke outcomes. They are written next to the script, are
  `.gitignore`d, and should be treated like any other directory export -
  don't commit them, don't share them unredacted.
- **Certificate files must be protected.** App-only mode generates a
  self-signed certificate valid for one year. On Windows it is stored in the
  `CurrentUser\My` certificate store; on macOS/Linux the PFX file is written
  to `~/.sharepoint-sharing-manager-cert/`. Anyone with access to that PFX
  can authenticate as the app with `Sites.FullControl.All` (SharePoint and
  Graph) across the tenant - protect it like any other private key material,
  and use the in-app **Renew** action if it is ever suspected compromised.
- **Module supply chain.** On demand, the tool offers to install
  `PnP.PowerShell` from the PowerShell Gallery in CurrentUser scope. If your
  organization requires pinned/internal module sources, install the module
  yourself beforehand - the tool uses whatever is already available.

## Supported versions

Only the latest release on `main` is supported.
