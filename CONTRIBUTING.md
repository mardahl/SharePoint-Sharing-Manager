# Contributing

Thanks for helping improve SharePoint Sharing Manager. The project is a
PowerShell TUI: a thin `SharePoint-Sharing-Manager.ps1` bootstrap plus one
file per region under `src/` - please keep that shape.

## Ground rules

1. **Thin bootstrap, one file per region.** `SharePoint-Sharing-Manager.ps1`
   is a small bootstrap (help header, `param()`, StrictMode) that
   dot-sources every `src/*.ps1` at script scope, then runs the Main event
   loop. All other runtime code lives in `src/`, one file per `#region`,
   numbered so the file-name sort order is the load order. No companion
   modules on the load path other than these dot-sourced files, no DLLs, no
   embedded binaries, no external module dependencies beyond
   `PnP.PowerShell`. Portability is still the core feature - the launcher
   `.bat` unblocks the whole folder recursively.
2. **PowerShell 7.4+ only.** `PnP.PowerShell` v3 requires it; there is no
   Windows PowerShell 5.1 compatibility target.
3. **StrictMode-safe.** The script runs under `Set-StrictMode -Version 2.0`.
   Check property existence before reading optional fields on API-shaped
   objects, and use `$hash['key']` indexing for optional hashtable keys.
4. **No telemetry, no phoning home.** The only network calls are to
   SharePoint Online and Microsoft Graph, triggered explicitly by the
   operator.
5. **Safety UX is not optional.** Destructive operations need a confirmation
   modal; revoke and tenant hardening operations need a *typed* confirmation
   (`REVOKE` / `DISABLE`). BEFORE/AFTER CSV evidence is written for every
   scan and revoke run.

## Dev setup

```powershell
pwsh ./SharePoint-Sharing-Manager.ps1
```

A test tenant with a handful of sites/OneDrives and a mix of anonymous
links, org-wide links, guest grants, and EEEU/Everyone grants is the
fastest way to exercise every rule category.

### Lint (must be clean before a PR)

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path ./SharePoint-Sharing-Manager.ps1, ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error, Warning
```

CI runs the same analyzer plus a parse check
(`[System.Management.Automation.Language.Parser]::ParseFile`) on every
`src/` file, and the assert-based tests under `tests/`.

### Testing the TUI without clicking around

`tmux` makes scripted UI testing easy (macOS/Linux, or Windows via WSL):

```bash
tmux new-session -d -s ssm -x 120 -y 32 "pwsh -NoProfile -File ./SharePoint-Sharing-Manager.ps1"
tmux send-keys -t ssm Enter        # connect + load
tmux send-keys -t ssm Space r      # select a finding, revoke
tmux capture-pane -pt ssm          # assert on the rendered screen
tmux kill-session -t ssm
```

If you change anything UI-related, paste a `capture-pane` snippet (or a
screenshot) into the PR.

### Testing against a real tenant

Use a **test tenant**. Revoked links and grants cannot be restored from
within the tool - the BEFORE CSV is the record of what a run is about to
remove, and it is worth reviewing before typing `REVOKE`.

## Code map

The code is split into a bootstrap plus one file per region under `src/`:

| File | Contents |
|---|---|
| `SharePoint-Sharing-Manager.ps1` | Bootstrap: help header, `param()`, StrictMode, dot-source loop, Main event loop |
| `src/00-globals.ps1` | Tabs, theme, glyphs, rule categories, connection/auth state |
| `src/05-logging.ps1` | `Write-SsmLog` (file + in-app ring buffer) |
| `src/10-console-vt.ps1` | Alt-buffer handling, VT enable, `Invoke-OnMainBuffer` |
| `src/15-drawing.ps1` | `Get-PadCell`, `Add-FrameLine`, footer/badges |
| `src/20-modals.ps1` | Message / confirm / typed-confirm / input / report / progress |
| `src/25-config.ps1` | Load/save `~/.sharepoint-sharing-manager.json` |
| `src/30-connections.ps1` | PnP connect/disconnect, dual-mode auth (delegated + app-only), module install |
| `src/35-scan-engine.ps1` | Shared scan engine: sharing links + direct grants across both rule presets |
| `src/40-revoke.ps1` | Removal ordering (links before grants, leaf before library before web), `AlreadyRevoked` handling |
| `src/45-targets.ps1` | Target enumeration (`Get-PnPTenantSite`), manual URL, CSV import |
| `src/50-csv.ps1` | BEFORE/REVOKED evidence export, current-view export |
| `src/55-tenant-actions.ps1` | Tenant posture (`Get-PnPTenant`) and hardening setters (`Set-PnPTenant`) |
| `src/60-setup-actions.ps1` | Delegated/app-only app registration, certificate renewal, config editor |
| `src/65-views.ps1` | Per-tab renderers, `Get-TabHints` |
| `src/75-key-dispatch.ps1` | Global + per-tab key handling |

### Conventions that bite if ignored

- **Style strings are fg-only** (`38;5;x`) so the cursor-row background
  carries through cells. Don't embed `ESC[0m` inside row content -
  `Add-FrameLine` appends the reset.
- **Tuple lines** for modals/footers are `@($style, $text)` pairs. Inside a
  multi-element `@( ... )` literal, write `@($style,$text)` **without** a
  leading comma - `,@(...)` wraps the tuple in another array and breaks
  rendering. (Leading commas are only for single-value returns: `return ,$arr`.)
- Widths are computed from plain text *before* styling - pad with
  `Get-PadCell`, then wrap in style codes.
- System libraries are excluded by their invariant URL leaf name
  (`SiteAssets`, `SitePages`, `Style Library`, `FormServerTemplates`,
  `Teams Wiki Data`), not by localized title - detection stays correct on
  non-English sites.
- Links are removed before direct grants, and leaf items (File/Folder)
  before Library before Web, so claim principals (EEEU, for example) are
  not de-provisioned out from under a later removal step.

## Pull requests

1. Fork / branch from `main`.
2. Keep PRs focused; one feature or fix per PR.
3. Update `CHANGELOG.md` under **Unreleased**.
4. Fill in the PR template checklist honestly - "not tested against a real
   tenant" is acceptable information, broken `main` is not.
