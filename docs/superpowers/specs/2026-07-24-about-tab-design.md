# About Tab — Design

**Date:** 2026-07-24
**Component:** SharePoint Sharing Manager TUI

## Purpose

Add an "About" menu item (tab) to the terminal UI. It explains the app's
purpose, credits the author (Michael Mardahl), and provides dedicated keys to
launch a browser directly to the author's GitHub profile and to the project's
releases page.

## Requirements

- New tab labeled "About" in the tab bar.
- Static screen showing: app name + version, a short purpose paragraph, the
  author's name, the GitHub profile URL, and the releases URL.
- Key `G` launches the default browser to `https://github.com/mardahl`.
- Key `R` launches the default browser to
  `https://github.com/mardahl/SharePoint-Sharing-Manager/releases`.
- Footer hints reflect the new keys.

## Placement

Append as the 6th (last) tab in `$script:Tabs` (`src/00-globals.ps1:92`), with
`Kind = 'About'`. The digit-key dispatch already scales to the tab count
(`src/75-key-dispatch.ps1:295`), so pressing `6` jumps to it with no change.
Tab / Shift+Tab cycling already covers it too.

Tab entry:

```powershell
@{ Kind = 'About'; Name = 'About' }
```

## Rendering

New function `Add-AboutView` in `src/65-views.ps1`, modeled on `Add-SetupView`
(`src/65-views.ps1:508`). It clears rows 3..H-1, then draws, with a left margin:

- Row 3 context line: e.g. `About`
- App name + `v$script:Version`
- Blank line
- Purpose paragraph (2-3 wrapped lines), drawn from the script synopsis:
  > A dependency-light PowerShell terminal UI that finds and revokes unwanted
  > SharePoint Online and OneDrive for Business sharing across a tenant —
  > anonymous links, org-wide links, guest sharing, and broad grants (EEEU,
  > Everyone).
- Blank line
- `Author  : Michael Mardahl`
- `GitHub  : https://github.com/mardahl`
- `Releases: https://github.com/mardahl/SharePoint-Sharing-Manager/releases`
- Blank line
- Key legend:
  - `G  open the author's GitHub profile in a browser`
  - `R  open the releases page in a browser`

Use existing theme styles (`$script:T`) and `Add-FrameLine` / `Get-PadCell`
helpers, consistent with `Add-SetupView`. Lines that would exceed `H - 1` are
skipped (same guard pattern as the Setup legend loop).

Wire into `Write-Screen`'s kind switch (`src/65-views.ps1:624`):

```powershell
'About' { Add-AboutView -Sb $sb -W $W -H $H }
```

## Browser launch helper

The Log tab already opens a file with an OS-detect `Start-Process` block
(`src/75-key-dispatch.ps1:259`). Factor that OS branching into a small shared
helper so both the About keys and (optionally) the Log tab can call it.

```powershell
function Open-SsmUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        if ($script:IsWin) {
            Start-Process $Url
        } elseif ($PSVersionTable.PSVersion.Major -ge 6 -and
                  (Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS) {
            Start-Process open -ArgumentList $Url
        } else {
            Start-Process xdg-open -ArgumentList $Url
        }
        Write-SsmLog -Message ("Opened URL in browser: {0}" -f $Url)
    } catch {
        Show-MsgModal -Title 'About' -Lines @('Could not open the browser:', $_.Exception.Message) -Kind Error
    }
}
```

Note: Windows uses `Start-Process $Url` (shell-associates the https URL);
macOS/Linux pass the URL as an argument to `open` / `xdg-open`. This mirrors
the existing Log-tab logic which uses the file path directly on Windows and as
an argument elsewhere.

Placement: define `Open-SsmUrl` alongside the key-dispatch functions in
`src/75-key-dispatch.ps1` (or reuse from the Log handler). Refactoring the Log
tab's inline block to call `Open-SsmUrl` is optional and out of scope unless
trivial; the URLs there are file paths, so it can stay as-is.

## Key handling

New function `Invoke-AboutKey` in `src/75-key-dispatch.ps1`:

```powershell
function Invoke-AboutKey {
    param([System.ConsoleKeyInfo]$K)
    switch ([char]::ToUpper($K.KeyChar)) {
        'G' { Open-SsmUrl -Url 'https://github.com/mardahl'; return }
        'R' { Open-SsmUrl -Url 'https://github.com/mardahl/SharePoint-Sharing-Manager/releases'; return }
    }
}
```

Wire into the `switch ($tab['Kind'])` in `Invoke-KeyDispatch`
(`src/75-key-dispatch.ps1:312`):

```powershell
'About' { Invoke-AboutKey -K $K }
```

Global keys (`Q` quit, `?` help, digit tab-jump, Tab cycle) are handled before
this switch and remain available. Note `W` (disconnect) is gated to
non-Setup tabs; on the About tab `W` would attempt a disconnect confirm if a
session is connected. This matches current behavior for Tenant/Log tabs and is
acceptable — no change needed.

## Footer hints

In `Get-TabHints` (`src/65-views.ps1:585`) add an `'About'` case:

```powershell
'About' { return @(@('G','github'),@('R','releases'),@('?','help'),@('Q','quit')) }
```

Also correct the stale hint in the `'Tenant'` case (`src/65-views.ps1:600`):
change `@('1-5','tab')` to `@('1-6','tab')` now that there are six tabs.

## Help modal

`Show-HelpModal` (`src/20-modals.ps1:437`) is a static per-tab key reference.
Its header comment says to keep it in sync with `Get-TabHints`. Two edits:

- Update the navigation line `1-5  jump to tab` (`src/20-modals.ps1:442`) to
  `1-6  jump to tab`, and the same on the Misc quit block if present.
- Add an `About tab` section before `Misc`:

  ```
  About tab
    G                    open the author's GitHub profile
    R                    open the releases page
  ```

## Testing

- The About view is a static render — no automated test.
- `Open-SsmUrl` has OS-branch logic. Add one Pester self-check following the
  repo layout (`tests/*.tests.ps1`, run via `tests/run-tests.ps1`) — e.g.
  `tests/open-url.tests.ps1` — that verifies it selects the correct launcher
  per platform, mocking `Start-Process`. Keep it minimal; no fixtures.
- Manual verification: launch the app, press `6` (or Tab to About), confirm the
  screen renders, press `G` and `R`, confirm the browser opens the correct URLs
  and a log line is written.

## Out of scope

- No new config or persisted state.
- Refactoring the Log tab's file-open to use `Open-SsmUrl`.

## Files touched

- `src/00-globals.ps1` — add the About tab entry.
- `src/65-views.ps1` — `Add-AboutView`, `Write-Screen` switch, `Get-TabHints`
  About case + Tenant hint fix.
- `src/75-key-dispatch.ps1` — `Open-SsmUrl` helper, `Invoke-AboutKey`,
  `Invoke-KeyDispatch` switch case.
- `src/20-modals.ps1` — help modal: About section + `1-5`→`1-6` fix.
- `tests/open-url.tests.ps1` — one self-check for `Open-SsmUrl`.
