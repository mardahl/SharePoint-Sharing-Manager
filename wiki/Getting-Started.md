# Getting started

## Download

Get the zip from [Releases](https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest) and extract it.

## Launch

Double-click **`Launch-Sharing-Manager.bat`**. It unblocks the extracted files (removes the Mark of the Web) and starts the tool.

Or start it directly:

```powershell
pwsh ./SharePoint-Sharing-Manager.ps1
```

## First run: pick an auth mode

1. Open the **Setup** tab.
2. Press `Enter` on the tenant and choose:
   - `C`: register an **app-only certificate** app (recommended; removes the per-OneDrive Site Collection Admin requirement)
   - `D`: register a **delegated (interactive)** app

The setup wizard walks through app registration and certificate issuance (1-year validity), and displays an admin-consent URL that can be forwarded to whoever holds Global Administrator or Privileged Role Administrator. See [[Authentication]] for the trade-offs.

## Typical first session

1. **Setup**: register the app, consent, confirm the tenant connects.
2. **Sites** tab: press `Enter` to enumerate targets (auto-discovery via `Get-PnPTenantSite`), or add URLs manually (`U`) or import a CSV (`I`).
3. Select targets (`Space`, `A` all) and scan (`S`), or scan everything not yet scanned (`X`).
4. Review the findings list. `/` live-searches, `F` cycles the category filter.
5. `E` exports the BEFORE CSV. Review it before acting.
6. Select findings, press `R`, type `REVOKE` to confirm. A REVOKED CSV records what was removed.
7. **Sharing** tab: review the tenant posture and apply hardening so sharing does not creep back. See [[Tenant-Hardening]].

## Global keys

| Key | Action |
|---|---|
| `Tab` / `Shift+Tab` | Switch tabs |
| `T` | Switch tenant (not on the target lists) |
| `?` | Help |
| `Q` | Quit |
