# Update Check (Notify-Only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At every startup, check GitHub Releases for a newer version; if found, show a modal pointing to the download page and assuring the user that settings, scan cache, and exports are untouched by updating.

**Architecture:** One new region file `src/72-update-check.ps1` with two functions (`Get-SsmLatestVersion`, `Show-SsmUpdateNotice`), called once from the bootstrap before `Enter-Tui`. Notify-only: no auto-download. Spec: `docs/superpowers/specs/2026-08-21-update-check-design.md`.

**Tech Stack:** PowerShell 7.4+, `Invoke-RestMethod` against the GitHub REST API, existing `Show-ConfirmModal` (src/20-modals.ps1) and `Open-SsmUrl` (src/75-key-dispatch.ps1).

## Global Constraints

- StrictMode 2.0-safe: every variable initialized before use.
- The update check must NEVER block or crash startup: any failure → log at DEBUG (INFO for "new version found"), return `$null`, continue.
- No new dependencies. No config-file changes. No "don't ask again" state.
- User-facing copy must state that settings, cache, and exports remain untouched (verbatim lines in Task 1).
- Repo: `mardahl/SharePoint-Sharing-Manager`. API: `https://api.github.com/repos/mardahl/SharePoint-Sharing-Manager/releases/latest`. Public download page: `https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest`.
- GitHub API requires a `User-Agent` header on all requests.
- Do NOT run any git mutations unless the user explicitly asks.

---

### Task 1: `Get-SsmLatestVersion` + tests

**Files:**
- Create: `src/72-update-check.ps1`
- Create: `tests/update-check.tests.ps1`
- Modify: `tests/run-tests.ps1:14` (add `'72-update-check'` to the dot-source list)

**Interfaces:**
- Consumes: `Write-SsmLog -Message <string> -Level <string>` (stubbed in test runner), `$script:Version` (set in src/00-globals.ps1; tests set their own).
- Produces:
  - `Get-SsmLatestVersion` → returns `[version]` or `$null`. Parameters: none. Test seam: the function reads the URI from `$script:UpdateCheckUri` if set, else the default GitHub API URL — tests override the script variable with a local file/endpoint or stub `Invoke-RestMethod` via function shadowing (pattern already used in tests/about.tests.ps1).
  - `Test-SsmNewerVersion -Latest [version] -Current [version]` → `$true` if `Latest` is strictly newer. Pure function, trivially testable.

- [ ] **Step 1: Write the failing test**

Create `tests/update-check.tests.ps1`:

```powershell
# Update-check tests. Get-SsmLatestVersion is tested via a shadowed
# Invoke-RestMethod; Test-SsmNewerVersion is pure.

Invoke-SsmTest 'Test-SsmNewerVersion: newer patch returns true' {
    Assert-Equal 'True' (Test-SsmNewerVersion -Latest ([version]'1.6.1') -Current ([version]'1.6.0'))
}

Invoke-SsmTest 'Test-SsmNewerVersion: same version returns false' {
    Assert-Equal 'False' (Test-SsmNewerVersion -Latest ([version]'1.6.0') -Current ([version]'1.6.0'))
}

Invoke-SsmTest 'Test-SsmNewerVersion: older version returns false' {
    Assert-Equal 'False' (Test-SsmNewerVersion -Latest ([version]'1.5.9') -Current ([version]'1.6.0'))
}

Invoke-SsmTest 'Get-SsmLatestVersion parses v-prefixed tag_name' {
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) @{ tag_name = 'v1.7.0' } }
    $r = Get-SsmLatestVersion
    Assert-Equal '1.7.0' $r
}

Invoke-SsmTest 'Get-SsmLatestVersion parses bare tag_name' {
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) @{ tag_name = '1.7.2' } }
    $r = Get-SsmLatestVersion
    Assert-Equal '1.7.2' $r
}

Invoke-SsmTest 'Get-SsmLatestVersion returns null on network error' {
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) throw 'offline' }
    $r = Get-SsmLatestVersion
    Assert-Equal '' $r
}

Invoke-SsmTest 'Get-SsmLatestVersion returns null on garbage tag' {
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) @{ tag_name = 'not-a-version' } }
    $r = Get-SsmLatestVersion
    Assert-Equal '' $r
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: FAIL — `Test-SsmNewerVersion` / `Get-SsmLatestVersion` not defined.

- [ ] **Step 3: Write minimal implementation**

Create `src/72-update-check.ps1`:

```powershell
# ============================================================================
#region Update check (notify-only)
# ============================================================================
# Startup check against GitHub Releases. Notify-only: never downloads, never
# blocks startup. Any failure is logged and swallowed so the tool always boots.

$script:SsmReleasesApi = 'https://api.github.com/repos/mardahl/SharePoint-Sharing-Manager/releases/latest'
$script:SsmReleasesUrl = 'https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest'

function Get-SsmLatestVersion {
    # Latest release tag from GitHub as [version]; $null on any failure.
    # Tests shadow Invoke-RestMethod to drive the branches.
    try {
        $r = Invoke-RestMethod -Uri $script:SsmReleasesApi -TimeoutSec 5 -Headers @{ 'User-Agent' = 'SharePoint-Sharing-Manager' }
        $tag = [string]$r.tag_name
        if ($tag.StartsWith('v')) { $tag = $tag.Substring(1) }
        return [version]$tag
    } catch {
        Write-SsmLog -Message ("Update check skipped: {0}" -f $_.Exception.Message) -Level DEBUG
        return $null
    }
}

function Test-SsmNewerVersion {
    param([Parameter(Mandatory)][version]$Latest, [Parameter(Mandatory)][version]$Current)
    return ($Latest -gt $Current)
}
```

Add `'72-update-check'` to the file list in `tests/run-tests.ps1:14` (insert before `'75-key-dispatch'` to keep numeric order).

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: all update-check tests PASS, no regressions.

---

### Task 2: `Show-SsmUpdateNotice` + bootstrap wiring

**Files:**
- Modify: `src/72-update-check.ps1` (append function)
- Modify: `tests/update-check.tests.ps1` (append tests)
- Modify: `SharePoint-Sharing-Manager.ps1:84-92` (call the notice after `Initialize-SsmTenancy`)

**Interfaces:**
- Consumes: `Get-SsmLatestVersion` (Task 1), `Show-ConfirmModal -Title <string> -Lines <object[]>` → `$true/$false` (src/20-modals.ps1), `Open-SsmUrl -Url <string>` (src/75-key-dispatch.ps1), `$script:Version`, `$script:SsmReleasesUrl`.
- Produces: `Show-SsmUpdateNotice` → no return value. Side effects: log line; on newer version, modal; on Y, opens browser to releases page.

- [ ] **Step 1: Write the failing tests**

Append to `tests/update-check.tests.ps1` (shadow `Get-SsmLatestVersion`, `Show-ConfirmModal`, `Open-SsmUrl` per case):

```powershell
Invoke-SsmTest 'Show-SsmUpdateNotice shows modal when newer version exists' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { [version]'1.7.0' }
    $script:ModalTitle = $null
    function Show-ConfirmModal { param($Title, $Lines) $script:ModalTitle = $Title; return $false }
    Show-SsmUpdateNotice
    Assert-Equal 'Update available' $script:ModalTitle
}

Invoke-SsmTest 'Show-SsmUpdateNotice copy promises settings/cache/exports untouched' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { [version]'1.7.0' }
    $script:ModalLines = $null
    function Show-ConfirmModal { param($Title, $Lines) $script:ModalLines = $Lines; return $false }
    Show-SsmUpdateNotice
    $flat = $script:ModalLines -join ' '
    if ($flat -notmatch 'settings')        { throw 'copy missing settings assurance' }
    if ($flat -notmatch 'scan cache')      { throw 'copy missing cache assurance' }
    if ($flat -notmatch 'exports')         { throw 'copy missing exports assurance' }
    if ($flat -notmatch 'remain untouched'){ throw 'copy missing remain-untouched phrase' }
    if ($flat -notmatch '1\.6\.0')         { throw 'copy missing current version' }
    if ($flat -notmatch '1\.7\.0')         { throw 'copy missing new version' }
}

Invoke-SsmTest 'Show-SsmUpdateNotice opens browser on Y' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { [version]'1.7.0' }
    function Show-ConfirmModal { param($Title, $Lines) return $true }
    $script:OpenedUrl = $null
    function Open-SsmUrl { param([string]$Url) $script:OpenedUrl = $Url }
    Show-SsmUpdateNotice
    Assert-Equal 'https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest' $script:OpenedUrl
}

Invoke-SsmTest 'Show-SsmUpdateNotice silent when version is current' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { [version]'1.6.0' }
    $script:ModalTitle = $null
    function Show-ConfirmModal { param($Title, $Lines) $script:ModalTitle = $Title; return $false }
    Show-SsmUpdateNotice
    Assert-Equal '' $script:ModalTitle
}

Invoke-SsmTest 'Show-SsmUpdateNotice silent when check fails (offline)' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { return $null }
    $script:ModalTitle = $null
    function Show-ConfirmModal { param($Title, $Lines) $script:ModalTitle = $Title; return $false }
    Show-SsmUpdateNotice
    Assert-Equal '' $script:ModalTitle
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: FAIL — `Show-SsmUpdateNotice` not defined.

- [ ] **Step 3: Implement `Show-SsmUpdateNotice`**

Append to `src/72-update-check.ps1`:

```powershell
function Show-SsmUpdateNotice {
    # Startup hook. Shows a modal only when GitHub has a newer release.
    # Y opens the releases page in the default browser; N/Esc just continues.
    $latest = Get-SsmLatestVersion
    if ($null -eq $latest) { return }
    if (-not (Test-SsmNewerVersion -Latest $latest -Current ([version]$script:Version))) { return }
    Write-SsmLog -Message ("Update available: v{0} -> v{1}" -f $script:Version, $latest) -Level INFO
    $open = Show-ConfirmModal -Title 'Update available' -Lines @(
        ("A newer version is available:  v{0} -> v{1}" -f $script:Version, $latest),
        '',
        'Download: github.com/mardahl/SharePoint-Sharing-Manager/releases/latest',
        '',
        'Updating replaces only the script file.',
        'Your settings (~/.sharepoint-sharing-manager.json),',
        'scan cache, and exports remain untouched.',
        '',
        'Open download page in browser?'
    )
    if ($open) { Open-SsmUrl -Url $script:SsmReleasesUrl }
}
```

Note: modal copy uses `->` not the Unicode arrow, so the `-Ascii` console mode stays clean. Replace `->` with `→` only if the project later standardizes on Unicode in modals (existing copy in 20-modals.ps1 uses ASCII arrows).

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Wire into bootstrap**

Edit `SharePoint-Sharing-Manager.ps1`, after the `Restore-SsmCache` block (line 87-92), before `#region Main`:

```powershell
# Notify-only update check (never blocks startup; see src/72-update-check.ps1).
try { Show-SsmUpdateNotice } catch { Write-SsmLog -Message ("Update notice failed: {0}" -f $_.Exception.Message) -Level DEBUG }
```

Note: `Show-SsmUpdateNotice` runs before `Enter-Tui`, but `Show-ConfirmModal` needs the TUI. Check `Enter-Tui` (src/10-console-vt.ps1) — if the modal renderer requires the alternate buffer, move the call to immediately AFTER `Enter-Tui` inside the `try` block instead. The tests don't depend on this ordering; verify manually in Step 6 and keep whichever placement renders correctly. **Placement rule: after `Enter-Tui`, before the `while` loop** is the safe default since `Show-ConfirmModal` calls `Write-Screen`.

- [ ] **Step 6: Parse-verify and lint**

Run:
```bash
pwsh -NoProfile -Command "\$errs=\$null; \$tok=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('SharePoint-Sharing-Manager.ps1',[ref]\$tok,[ref]\$errs); if (\$errs.Count) { \$errs | ForEach-Object { Write-Host \$_.Message }; exit 1 } else { Write-Host 'parse OK' }"
pwsh -NoProfile -Command "if (Get-Module -ListAvailable PSScriptAnalyzer) { Invoke-ScriptAnalyzer -Path src/72-update-check.ps1 -Settings PSScriptAnalyzerSettings.psd1 } else { Write-Host 'PSScriptAnalyzer not installed - skipped' }"
```
Expected: parse OK, no analyzer errors.

- [ ] **Step 7: Rebuild single-file artifact**

Run: `pwsh -NoProfile -File build/New-SingleFile.ps1`
Expected: `Built and parse-verified: .../dist/SharePoint-Sharing-Manager.ps1`

---

### Task 3: Docs (CHANGELOG + wiki)

**Files:**
- Modify: `CHANGELOG.md` (Unreleased section)
- Modify: `wiki/FAQ-and-Troubleshooting.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: CHANGELOG entry**

Add under `## [Unreleased]` → `### Added`:

```markdown
- Startup update check: queries GitHub Releases and shows a one-line modal when a newer version exists, with a link to the download page and an assurance that settings, scan cache, and exports are untouched by updating. Notify-only - no auto-download. Y opens the releases page in the default browser.
```

- [ ] **Step 2: Wiki entry**

Append a section to `wiki/FAQ-and-Troubleshooting.md`:

```markdown
## The tool says a newer version is available - how do I update?

At startup the tool checks [[GitHub Releases|https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest]] and shows a notice if a newer version exists. Press `Y` to open the download page in your browser, then replace your copy of `SharePoint-Sharing-Manager.ps1` with the new one.

Updating replaces only the script file. Your settings (`~/.sharepoint-sharing-manager.json`), scan cache (`SSM-Cache/`), and exports (`SSM-Exports/`) remain untouched.

The check is notify-only: the tool never downloads or replaces itself. If the machine is offline or GitHub is unreachable, the check is skipped silently and the tool starts normally.
```

- [ ] **Step 3: Verify wiki link style**

Run: `rg -n '\[\[' wiki/Home.md | head -5` to confirm the `[[Wiki-Style]]` link convention used elsewhere, and match it (external URL inside wiki link as shown, or plain URL if that's the existing convention — follow the file's existing style).

---

## Self-Review Notes

- Spec coverage: Task 1 = Get-SsmLatestVersion + comparison; Task 2 = Show-SsmUpdateNotice + bootstrap wiring + copy; Task 3 = CHANGELOG + wiki. All spec sections covered.
- Type consistency: `Get-SsmLatestVersion` returns `[version]`/`$null`; `Test-SsmNewerVersion -Latest [version] -Current [version]`; `Show-SsmUpdateNotice` consumes both. Consistent across tasks.
- No placeholders. Modal copy is verbatim. Test code is complete.
- Shadowing pattern (redefining `Invoke-RestMethod`/`Show-ConfirmModal` inside test blocks) matches existing tests/about.tests.ps1 convention.
- Git mutations deliberately omitted from tasks — repo rule requires explicit user request.
