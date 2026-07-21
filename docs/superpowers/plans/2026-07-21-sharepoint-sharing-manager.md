# SharePoint Sharing Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the two hardening scripts into one PowerShell TUI (`SharePoint-Sharing-Manager`) with tabs for Sites, OneDrives, Tenant, Setup, and Log, released on GitHub with the same structure as Exchange-SOA-Manager.

**Architecture:** Bootstrap script dot-sources numbered `src/NN-*.ps1` region files (template pattern). UI plumbing (VT console, drawing, modals, logging) is ported from the local template clone at `/Users/mum@inciro.com/Documents/opencode/SOAconverter` with an `Ssm` function prefix. New code: PnP dual-mode auth (delegated / app-only certificate), a shared scan engine with toggleable rule categories, per-finding multi-select revoke, tenant hardening actions, and a setup wizard.

**Tech Stack:** PowerShell 7.4+, PnP.PowerShell v3 (installed on demand, CurrentUser), GitHub Actions (PSScriptAnalyzer + parse + assert tests, tag-triggered release building a single-file artifact).

## Global Constraints

- PowerShell floor: **7.4** (`#Requires -Version 7.4`); no Windows PowerShell 5.1 support.
- Only dependency: **PnP.PowerShell** (v3), installed on demand at CurrentUser scope. No other modules.
- Nothing tenant-specific: default Entra app name `SharePoint-Sharing-Manager`, config file `~/.sharepoint-sharing-manager.json`, all names/paths overridable by parameter.
- Function prefix for ported/log helpers: `Ssm` (e.g. `Write-SsmLog`).
- Safety invariants (never violate): never delete files/folders, never reset inheritance, skip Limited Access rows (`RoleTypeKind = 1`), links removed before direct grants, leaf-first removal order, empty-LinkId guard, typed confirmation before destructive batches, BEFORE/AFTER CSV evidence.
- License MIT. `Set-StrictMode -Version 2.0` everywhere. PSScriptAnalyzer must pass with repo settings.
- Template source for ported files: `/Users/mum@inciro.com/Documents/opencode/SOAconverter` (referenced below as `$TPL`).
- Spec: `docs/superpowers/specs/2026-07-21-sharepoint-sharing-manager-design.md`.

## File Structure

| File | Responsibility |
|---|---|
| `SharePoint-Sharing-Manager.ps1` | Bootstrap: param block, dot-source loop with concat markers, main loop |
| `Launch-Sharing-Manager.bat` | Unblock files, launch via pwsh, error if pwsh missing |
| `src/00-globals.ps1` | Version, state hashtables, tabs, glyphs, theme, rule categories |
| `src/05-logging.ps1` | `Write-SsmLog`, `Write-SsmErrorLog` (ported) |
| `src/10-console-vt.ps1` | VT setup, alt buffer, console size (ported as-is) |
| `src/15-drawing.ps1` | Pad/frame/footer helpers + `Get-StatusBadge` (ported, badge swapped) |
| `src/20-modals.ps1` | Msg/confirm/typed-confirm/input/report modals, spinner (ported) |
| `src/25-config.ps1` | Config load/save, module check/install, cert expiry helper |
| `src/30-connections.ps1` | `Get-ConnectParams`, site/admin connect with per-URL cache |
| `src/35-scan-engine.ps1` | Principal classification, guest grantees, REST scan of one site |
| `src/40-revoke.ps1` | Removal ordering + revoke execution |
| `src/45-targets.ps1` | CSV URL import, tenant site enumeration |
| `src/50-csv.ps1` | Evidence CSVs (BEFORE/AFTER), view export |
| `src/55-tenant-actions.ps1` | Read tenant sharing posture, hardening setters |
| `src/60-setup-actions.ps1` | Register delegated app, register app-only cert app, renew cert |
| `src/65-views.ps1` | Title/tab bars, targets/findings/tenant/setup/log views, `Write-Screen` |
| `src/75-key-dispatch.ps1` | Per-view key handlers, global dispatch |
| `tests/run-tests.ps1` | Assert-based test runner (no Pester) |
| `.github/workflows/ci.yml` | Analyzer + parse (pwsh) + tests |
| `.github/workflows/release.yml` | Concat single-file artifact, zip, attach to release |
| `README.md` etc. | Docs mirroring the template repo |

**Repo root** = current working directory (`SPOhardening`, git already initialized). The two source scripts stay in the repo root during development; Task 16 moves them to `docs/legacy/`.

---

### Task 1: Repo chrome and CI

**Files:**
- Create: `.gitignore`, `PSScriptAnalyzerSettings.psd1`, `LICENSE`, `Launch-Sharing-Manager.bat`, `.github/workflows/ci.yml`
- Copy from `$TPL`: `.github/ISSUE_TEMPLATE/`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/dependabot.yml`

**Interfaces:**
- Produces: CI expects `SharePoint-Sharing-Manager.ps1` + `src/*.ps1` + `tests/run-tests.ps1` to exist (created in Tasks 2–3; CI is committed now, will go green once they land).

- [ ] **Step 1: Copy template chrome**

```bash
TPL=/Users/mum@inciro.com/Documents/opencode/SOAconverter
mkdir -p .github
cp -r "$TPL/.github/ISSUE_TEMPLATE" .github/
cp "$TPL/.github/PULL_REQUEST_TEMPLATE.md" "$TPL/.github/dependabot.yml" .github/
cp "$TPL/LICENSE" LICENSE
```

Then edit `.github/ISSUE_TEMPLATE/*.yml` and `PULL_REQUEST_TEMPLATE.md`: replace every occurrence of `SOA-Manager` with `SharePoint-Sharing-Manager`, `Exchange SOA Manager` with `SharePoint Sharing Manager`, and drop any 5.1-related checklist lines.

- [ ] **Step 2: Write `.gitignore`**

```gitignore
# Tool output (contains directory data - never commit)
SSM-Exports/
SharePoint-Sharing-Manager_*.log
*.pfx

# OS / editor noise
.DS_Store
Thumbs.db
*.swp
.vscode/
.worktrees/
```

Note: `docs/` is NOT ignored (spec + plan live there).

- [ ] **Step 3: Write `PSScriptAnalyzerSettings.psd1`**

```powershell
@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.0')
        }
    }
}
```

- [ ] **Step 4: Write `Launch-Sharing-Manager.bat`**

```bat
@echo off
rem Removes the "downloaded from the internet" block (Mark of the Web) from
rem every file next to this launcher, then starts SharePoint-Sharing-Manager.ps1.
rem Requires PowerShell 7.4+ (pwsh). https://aka.ms/powershell
setlocal
where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7.4+ ^(pwsh^) is required but was not found.
    echo Install it from https://aka.ms/powershell and run this launcher again.
    pause
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse | Unblock-File"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0SharePoint-Sharing-Manager.ps1" %*
```

- [ ] **Step 5: Write `.github/workflows/ci.yml`**

Adapt the template CI: keep the analyzer job and the PS7 parse job (retargeted to the new file names), DROP the 5.1 parse job, ADD a tests job.

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  lint:
    name: PSScriptAnalyzer
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Run PSScriptAnalyzer
        shell: pwsh
        run: |
          Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
          $results = @(Invoke-ScriptAnalyzer -Path ./SharePoint-Sharing-Manager.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error, Warning)
          $results += @(Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error, Warning)
          if ($results.Count -gt 0) {
              $results | Format-Table RuleName, ScriptName, Line, Message -AutoSize | Out-String | Write-Host
              throw "PSScriptAnalyzer reported $($results.Count) finding(s)."
          }
          Write-Host 'PSScriptAnalyzer: clean.'

  parse:
    name: Parse check (PowerShell 7)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Parse all script files
        shell: pwsh
        run: |
          $files = @("$PWD/SharePoint-Sharing-Manager.ps1") + (Get-ChildItem "$PWD/src/*.ps1" | ForEach-Object FullName)
          $failed = 0
          foreach ($file in $files) {
              $errs = $null; $tokens = $null
              [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errs)
              if ($errs.Count -gt 0) {
                  $failed++
                  $errs | ForEach-Object { Write-Host ("{0} L{1}: {2}" -f (Split-Path $file -Leaf), $_.Extent.StartLineNumber, $_.Message) }
              }
          }
          if ($failed -gt 0) { throw "Parse errors in $failed file(s)." }
          Write-Host 'Parse OK.'

  tests:
    name: Unit tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Run assert tests
        shell: pwsh
        run: ./tests/run-tests.ps1
```

- [ ] **Step 6: Commit**

```bash
git add .gitignore PSScriptAnalyzerSettings.psd1 LICENSE Launch-Sharing-Manager.bat .github
git commit -m "chore: repo chrome, launcher, and CI from template"
```

---

### Task 2: Port UI plumbing (bootstrap, globals, logging, console, drawing, modals)

**Files:**
- Create: `SharePoint-Sharing-Manager.ps1`, `src/00-globals.ps1`, `src/05-logging.ps1`, `src/10-console-vt.ps1`, `src/15-drawing.ps1`, `src/20-modals.ps1`

**Interfaces:**
- Produces: `Write-SsmLog -Message <s> [-Level INFO|WARN|ERROR|OK]`, `Write-SsmErrorLog`, `Enable-VirtualTerminal`, `Enter-Tui`/`Exit-Tui`, `Invoke-OnMainBuffer { }`, `Get-ConsoleSize`, `Get-PadCell <text> <width>`, `Add-FrameLine -Sb -Row -Content`, `Get-StatusBadge -Status <s> -Width <n>`, `Get-FooterBar -Hints -Width`, `Write-CenteredPanel`, `Show-MsgModal`, `Show-ConfirmModal`, `Show-TypedConfirmModal -Title -Lines -Word <WORD>`, `Show-InputModal -Title -Prompt [-Default]`, `Show-ReportModal`, `Start-LoadSpinner`/`Stop-LoadSpinner`, `Write-ProgressModal`, `Show-HelpModal`.
- Produces state: `$script:UI`, `$script:Tabs`, `$script:T` (theme), `$script:G` (glyphs), `$script:Conn`, `$script:Auth`, `$script:RuleCategories`, `$script:LogBuffer`, `$script:LogFile`, `$script:ExportDir`.

- [ ] **Step 1: Copy and rename the four plumbing files**

```bash
TPL=/Users/mum@inciro.com/Documents/opencode/SOAconverter
mkdir -p src
for f in 05-logging 10-console-vt 15-drawing 20-modals; do cp "$TPL/src/$f.ps1" "src/$f.ps1"; done
# Rename the log function prefix everywhere (BSD sed on macOS)
sed -i '' -e 's/Write-SoaLog/Write-SsmLog/g' -e 's/Write-SoaErrorLog/Write-SsmErrorLog/g' src/*.ps1
```

Then open each copied file and check for any remaining `Soa`/`SOA-Manager` strings (`grep -n 'Soa\|SOA' src/*.ps1`); rename them to `Ssm`/`SharePoint-Sharing-Manager` equivalents. In `src/15-drawing.ps1`, DELETE `Get-SoaBadge` and `Get-AuditGlyph` and add:

```powershell
function Get-StatusBadge {
    param([string]$Status, [int]$Width)
    # Colored, padded badge for a target's scan status.
    $t = $script:T; $g = $script:G
    $style = $t.Muted; $glyph = [string]$g.Ring; $text = $Status
    switch ($Status) {
        'NotScanned'    { $style = $t.Muted;   $glyph = [string]$g.Ring; $text = 'Not scanned' }
        'Scanning'      { $style = $t.Pending; $glyph = [string]$g.Half; $text = 'Scanning'   }
        'Clean'         { $style = $t.Good;    $glyph = [string]$g.Dot;  $text = 'Clean'      }
        'Findings'      { $style = $t.Warn;    $glyph = [string]$g.Dot;  $text = 'Findings'   }
        'ConnectFailed' { $style = $t.Danger;  $glyph = [string]$g.Dot;  $text = 'Conn fail'  }
        'ScanFailed'    { $style = $t.Danger;  $glyph = [string]$g.Dot;  $text = 'Scan fail'  }
        'Revoked'       { $style = $t.Cloud;   $glyph = [string]$g.Dot;  $text = 'Revoked'    }
    }
    return $style + (Get-PadCell ($glyph + ' ' + $text) $Width) + $script:T.Row
}
```

If `Show-HelpModal` in `src/20-modals.ps1` hardcodes SOA key help, replace its body text with the key table from Task 10 Step 2 (`Get-TabHints`) — one line per key, grouped by tab.

- [ ] **Step 2: Write `src/00-globals.ps1`**

Base it on `$TPL/src/00-globals.ps1` (keep `$script:ESC`, glyphs `$script:G`, theme `$script:T`, `$script:UI` verbatim) but replace version, paths, connection state, and tabs with:

```powershell
$script:Version = '1.0.0'

$script:LogFile   = Join-Path $script:Root ("SharePoint-Sharing-Manager_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:ExportDir = Join-Path $script:Root 'SSM-Exports'
$script:LogBuffer = New-Object System.Collections.ArrayList
$script:Spinner   = $null

# Auth/config state (populated from ~/.sharepoint-sharing-manager.json in 25-config)
$script:Auth = @{
    Loaded      = $false
    AuthMode    = ''      # 'Delegated' | 'AppOnly'
    ClientId    = ''
    Tenant      = ''      # contoso.onmicrosoft.com
    AdminUrl    = ''      # https://contoso-admin.sharepoint.com
    Thumbprint  = ''      # Windows cert store (CurrentUser\My)
    CertPath    = ''      # PFX path (non-Windows)
    CertExpires = ''      # ISO date string
}

# Connection state: one PnP connection at a time, cached per URL
$script:Conn = @{
    Url     = ''          # currently connected site URL ('' = none)
    Admin   = $false      # currently connected to the admin URL
    Account = ''          # signed-in account or app id shown in title bar
}

# Rule categories: key -> display name (order matters for the toggle modal)
$script:RuleCategories = [ordered]@{
    AnonymousLink = 'Anonymous link'
    OrgLink       = 'Organization link'
    GuestLink     = 'Guest-specific link'
    GuestGrant    = 'Guest grant'
    EEEU          = 'EEEU grant'
    Everyone      = 'Everyone grant'
}

# System libraries skipped by INVARIANT URL leaf (language-independent)
$script:ExcludedUrlNames = @('SiteAssets','SitePages','Style Library','FormServerTemplates','Teams Wiki Data')

function New-TargetsTab {
    param([string]$Name, [string]$Noun, [bool]$OneDrive, [string[]]$Preset)
    return @{
        Kind      = 'Targets'
        Name      = $Name
        Noun      = $Noun          # 'sites' | 'OneDrives'
        OneDrive  = $OneDrive      # enumerate personal sites instead of regular sites
        Categories= [System.Collections.ArrayList]@($Preset)   # enabled rule category keys
        Items     = @()            # target objects (see New-Target in 45-targets)
        View      = @()
        Loaded    = $false
        Cursor    = 0
        Scroll    = 0
        Search    = ''
        Filter    = 'All'          # All | NotScanned | Clean | Findings | Failed
        SortCol   = 'Url'
        SortDesc  = $false
        Mode      = 'Targets'      # 'Targets' | 'Findings'
        FTab      = $null          # findings sub-state when Mode = 'Findings'
    }
}

$script:Tabs = @(
    (New-TargetsTab -Name 'Sites'     -Noun 'sites'     -OneDrive $false -Preset @('OrgLink')),
    (New-TargetsTab -Name 'OneDrives' -Noun 'OneDrives' -OneDrive $true  -Preset @($script:RuleCategories.Keys)),
    @{ Kind = 'Tenant'; Name = 'Tenant'; Loaded = $false; Posture = $null },
    @{ Kind = 'Setup';  Name = 'Setup' },
    @{ Kind = 'Log';    Name = 'Log' }
)
```

Keep the template's `if ($Ascii) { ... } else { ... }` glyph block and the `$script:T` theme block verbatim. Delete `New-ListTab`, `$script:GraphWorker`, `$script:Org`, `$script:DemoOrgCloudDefault`, `$script:BackupDir`, `$script:DebugLog`.

- [ ] **Step 3: Write the bootstrap `SharePoint-Sharing-Manager.ps1`**

Base on `$TPL/SOA-Manager.ps1`. Changes: comment-based help describing THIS tool (synopsis: terminal UI that finds and revokes unwanted SharePoint/OneDrive sharing — anonymous/org-wide/guest links, guest/EEEU/Everyone grants — with app-only or delegated PnP auth); `#Requires -Version 7.4`; param block below; keep the suppression attributes; wrap the dot-source loop in concat markers; keep the main loop and finally-block shape (drop Demo/backup lines, replace module list with `PnP.PowerShell`, call `Disconnect-SsmConnection` instead of `Disconnect-AllServices`).

```powershell
param(
    [switch]$Ascii,
    [switch]$NoDisconnect,
    [string]$ConfigPath = (Join-Path $HOME '.sharepoint-sharing-manager.json')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:ConfigPath = $ConfigPath
$script:KeepSessions = [bool]$NoDisconnect

# ==== BEGIN SRC LOAD ==== (the release build replaces this block with the inlined files)
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.ps1' | Sort-Object Name)) {
    . $f.FullName
}
# ==== END SRC LOAD ====
```

Main loop stays byte-for-byte the template pattern (resize check, `Write-Screen` on dirty, `Invoke-KeyDispatch`, 25 ms sleep; `finally { Exit-Tui; Disconnect-SsmConnection unless KeepSessions }`).

- [ ] **Step 4: Parse-check everything**

Run: `pwsh -NoProfile -c '$e=0; foreach ($f in @("./SharePoint-Sharing-Manager.ps1") + (Get-ChildItem ./src/*.ps1).FullName) { $errs=$null;$t=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$errs); if ($errs) { $e++; $errs | % { "$f L$($_.Extent.StartLineNumber): $($_.Message)" } } }; if ($e) { exit 1 }; "parse OK"'`
Expected: `parse OK`. (Full run not possible yet — later src files are missing; parse only.)

- [ ] **Step 5: Commit**

```bash
git add SharePoint-Sharing-Manager.ps1 src
git commit -m "feat: bootstrap + ported TUI plumbing (globals, logging, VT console, drawing, modals)"
```

---

### Task 3: Test harness

**Files:**
- Create: `tests/run-tests.ps1`

**Interfaces:**
- Produces: `Invoke-SsmTest -Name <s> -Block { }` convention. The runner dot-sources ONLY pure-logic src files (no PnP calls at load time), executes every `tests/*.tests.ps1`, prints per-test PASS/FAIL, exits non-zero on any failure.
- Consumed by: CI `tests` job (Task 1) and every TDD task below.

- [ ] **Step 1: Write `tests/run-tests.ps1`**

```powershell
#Requires -Version 7.4
# Assert-based test runner: dot-sources pure-logic src files, runs tests/*.tests.ps1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Minimal stubs so src files that log can load without the full TUI
$script:LogBuffer = New-Object System.Collections.ArrayList
$script:LogFile = Join-Path ([IO.Path]::GetTempPath()) 'ssm-test.log'
function Write-SsmLog { param([string]$Message, [string]$Level = 'INFO') }

# Pure-logic files only - keep in sync as files gain PnP-free helpers
foreach ($f in @('25-config','30-connections','35-scan-engine','40-revoke','45-targets')) {
    $p = Join-Path $root "src/$f.ps1"
    if (Test-Path $p) { . $p }
}

$script:Passed = 0; $script:Failed = 0
function Invoke-SsmTest {
    param([string]$Name, [scriptblock]$Block)
    try { & $Block; $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "expected [$Expected] got [$Actual] $Because" }
}

foreach ($tf in Get-ChildItem -Path $PSScriptRoot -Filter '*.tests.ps1') {
    Write-Host $tf.Name
    . $tf.FullName
}
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
```

- [ ] **Step 2: Run it (empty pass)**

Run: `pwsh ./tests/run-tests.ps1`
Expected: `0 passed, 0 failed`, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add tests/run-tests.ps1
git commit -m "test: assert-based runner without external dependencies"
```

---

### Task 4: Config module

**Files:**
- Create: `src/25-config.ps1`, `tests/config.tests.ps1`

**Interfaces:**
- Produces: `Get-SsmConfig [-Path]` → hashtable or `$null`; `Save-SsmConfig -Config <hashtable> [-Path]`; `Initialize-SsmAuth` (loads config into `$script:Auth`, sets `Loaded`); `Test-SsmAuthReady` → bool (ClientId + mode-specific fields present); `Get-CertDaysLeft` → int or `$null`; `Install-SsmModule` (PnP.PowerShell on-demand install + import, ported pattern from the old scripts).
- Consumes: `$script:Auth`, `$script:ConfigPath` (Task 2).

- [ ] **Step 1: Write failing tests `tests/config.tests.ps1`**

```powershell
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ssm-cfg-{0}.json" -f [guid]::NewGuid())

Invoke-SsmTest 'Get-SsmConfig returns null for missing file' {
    Assert-Equal '' (Get-SsmConfig -Path $tmp)
}
Invoke-SsmTest 'Save/Get round-trips all fields' {
    Save-SsmConfig -Path $tmp -Config @{
        AuthMode='AppOnly'; ClientId='11111111-1111-1111-1111-111111111111'
        Tenant='contoso.onmicrosoft.com'; AdminUrl='https://contoso-admin.sharepoint.com'
        Thumbprint='ABCD'; CertPath=''; CertExpires='2027-07-21'
    }
    $c = Get-SsmConfig -Path $tmp
    Assert-Equal 'AppOnly' $c.AuthMode
    Assert-Equal 'ABCD' $c.Thumbprint
    Assert-Equal '2027-07-21' $c.CertExpires
}
Invoke-SsmTest 'Get-SsmConfig survives corrupt JSON' {
    Set-Content -LiteralPath $tmp -Value '{not json'
    Assert-Equal '' (Get-SsmConfig -Path $tmp)
}
Invoke-SsmTest 'Test-SsmAuthReady: delegated needs ClientId only' {
    $script:Auth = @{ Loaded=$true; AuthMode='Delegated'; ClientId='x'; Tenant=''; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
    Assert-Equal 'True' (Test-SsmAuthReady)
}
Invoke-SsmTest 'Test-SsmAuthReady: app-only needs tenant + cert' {
    $script:Auth = @{ Loaded=$true; AuthMode='AppOnly'; ClientId='x'; Tenant=''; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
    Assert-Equal 'False' (Test-SsmAuthReady)
    $script:Auth.Tenant = 'contoso.onmicrosoft.com'; $script:Auth.Thumbprint = 'ABCD'
    Assert-Equal 'True' (Test-SsmAuthReady)
}
Invoke-SsmTest 'Get-CertDaysLeft parses ISO date' {
    $script:Auth.CertExpires = (Get-Date).AddDays(10).ToString('yyyy-MM-dd')
    $d = Get-CertDaysLeft
    if ($d -lt 9 -or $d -gt 10) { throw "expected ~10, got $d" }
}
Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `pwsh ./tests/run-tests.ps1`
Expected: FAILs with "The term 'Get-SsmConfig' is not recognized".

- [ ] **Step 3: Implement `src/25-config.ps1`**

```powershell
# ============================================================================
#region Config & modules
# ============================================================================

function Get-SsmConfig {
    param([string]$Path = $script:ConfigPath)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable) }
    catch { return $null }
}

function Save-SsmConfig {
    param([hashtable]$Config, [string]$Path = $script:ConfigPath)
    $Config | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Initialize-SsmAuth {
    # Load saved config (if any) into $script:Auth. Missing file is fine: the
    # Setup tab is the guided path to create one.
    $c = Get-SsmConfig
    if ($null -ne $c) {
        foreach ($k in @('AuthMode','ClientId','Tenant','AdminUrl','Thumbprint','CertPath','CertExpires')) {
            if ($c.ContainsKey($k) -and $c[$k]) { $script:Auth[$k] = [string]$c[$k] }
        }
        Write-SsmLog -Message ("Config loaded from {0} (mode: {1})" -f $script:ConfigPath, $script:Auth.AuthMode)
    }
    $script:Auth.Loaded = $true
}

function Save-SsmAuth {
    # Persist current $script:Auth back to the config file.
    Save-SsmConfig -Config @{
        AuthMode    = $script:Auth.AuthMode
        ClientId    = $script:Auth.ClientId
        Tenant      = $script:Auth.Tenant
        AdminUrl    = $script:Auth.AdminUrl
        Thumbprint  = $script:Auth.Thumbprint
        CertPath    = $script:Auth.CertPath
        CertExpires = $script:Auth.CertExpires
    }
    Write-SsmLog -Message ("Config saved to {0}" -f $script:ConfigPath)
}

function Test-SsmAuthReady {
    if (-not $script:Auth.ClientId) { return $false }
    if ($script:Auth.AuthMode -eq 'AppOnly') {
        if (-not $script:Auth.Tenant) { return $false }
        if (-not ($script:Auth.Thumbprint -or $script:Auth.CertPath)) { return $false }
    }
    return $true
}

function Get-CertDaysLeft {
    if (-not $script:Auth.CertExpires) { return $null }
    try { return [int]([datetime]::Parse($script:Auth.CertExpires) - (Get-Date)).TotalDays }
    catch { return $null }
}

function Install-SsmModule {
    # Install + import PnP.PowerShell (CurrentUser) on demand. Runs on the main
    # buffer so gallery prompts/progress are visible.
    if (Get-Module -Name 'PnP.PowerShell') { return $true }
    if (-not (Get-Module -ListAvailable -Name 'PnP.PowerShell')) {
        $ok = Show-ConfirmModal -Title 'Module required' -Lines @(
            'PnP.PowerShell is not installed.',
            'Install it now for the current user?')
        if (-not $ok) { return $false }
        Invoke-OnMainBuffer {
            Write-Host 'Installing PnP.PowerShell (CurrentUser)...' -ForegroundColor Yellow
            Install-Module -Name 'PnP.PowerShell' -Scope CurrentUser -Force -AllowClobber
        }
        Write-SsmLog -Message 'PnP.PowerShell installed (CurrentUser).' -Level OK
    }
    Import-Module 'PnP.PowerShell' -ErrorAction Stop
    return $true
}

#endregion
```

Note: if the template's `Invoke-OnMainBuffer` takes the scriptblock differently, match its signature (check `src/10-console-vt.ps1`).

- [ ] **Step 4: Run tests, verify pass**

Run: `pwsh ./tests/run-tests.ps1`
Expected: 6 PASS, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add src/25-config.ps1 tests/config.tests.ps1
git commit -m "feat: config load/save, auth readiness, on-demand PnP install"
```

---

### Task 5: Scan-engine pure functions (classification)

**Files:**
- Create: `src/35-scan-engine.ps1` (pure part), `tests/scan-engine.tests.ps1`

**Interfaces:**
- Produces: `Get-PrincipalCategory -Login <s> -Title <s>` → category KEY (`'EEEU'|'Everyone'|'GuestGrant'`) or `$null`; `Get-GuestGrantees -Link <obj>` → string[]; `Get-LinkCategory -Scope <s> -Link <obj>` → hashtable `@{ Key; Principal }` or `$null`.
- Category keys match `$script:RuleCategories` (Task 2). Display names come from that map — findings store the KEY in `CategoryKey` and the display name in `Category`.

- [ ] **Step 1: Write failing tests `tests/scan-engine.tests.ps1`**

```powershell
Invoke-SsmTest 'EEEU login classified' {
    Assert-Equal 'EEEU' (Get-PrincipalCategory -Login 'c:0-.f|rolemanager|spo-grid-all-users/abc123' -Title 'Everyone except external users')
}
Invoke-SsmTest 'Everyone claim classified' {
    Assert-Equal 'Everyone' (Get-PrincipalCategory -Login 'c:0(.s|true' -Title 'Everyone')
}
Invoke-SsmTest 'Guest ext login classified' {
    Assert-Equal 'GuestGrant' (Get-PrincipalCategory -Login 'i:0#.f|membership|jane_gmail.com#ext#@contoso.onmicrosoft.com' -Title 'Jane Guest')
}
Invoke-SsmTest 'Internal member kept (null)' {
    Assert-Equal '' (Get-PrincipalCategory -Login 'i:0#.f|membership|bob@contoso.com' -Title 'Bob')
}
Invoke-SsmTest 'SharingLinks principal skipped' {
    Assert-Equal '' (Get-PrincipalCategory -Login 'x' -Title 'SharingLinks.abc.Flexible.def')
}
Invoke-SsmTest 'Empty principal skipped' {
    Assert-Equal '' (Get-PrincipalCategory -Login '' -Title '')
}
Invoke-SsmTest 'Guest grantees extracted from users-link' {
    $link = [pscustomobject]@{ GrantedToIdentitiesV2 = @(
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|g_x.com#ext#@t.onmicrosoft.com' }; User = [pscustomobject]@{ Email = 'g@x.com' } },
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|bob@contoso.com' }; User = [pscustomobject]@{ Email = 'bob@contoso.com' } }
    )}
    $g = @(Get-GuestGrantees -Link $link)
    Assert-Equal 1 $g.Count
    Assert-Equal 'g@x.com' $g[0]
}
Invoke-SsmTest 'Link categories: anonymous / organization / internal users-link' {
    $r = Get-LinkCategory -Scope 'anonymous' -Link ([pscustomobject]@{})
    Assert-Equal 'AnonymousLink' $r.Key
    $r = Get-LinkCategory -Scope 'organization' -Link ([pscustomobject]@{})
    Assert-Equal 'OrgLink' $r.Key
    $r = Get-LinkCategory -Scope 'users' -Link ([pscustomobject]@{ GrantedToIdentitiesV2 = @() })
    Assert-Equal '' $r    # internal-only specific-people link is KEPT
}
```

- [ ] **Step 2: Run tests, verify fail** — `pwsh ./tests/run-tests.ps1`, expect "Get-PrincipalCategory is not recognized".

- [ ] **Step 3: Implement the pure part of `src/35-scan-engine.ps1`**

Port from `Revoke-OneDrive-NonMemberAccess.ps1` (`Classify-Principal`, `Get-GuestGrantees`, the link `switch`), returning category KEYS:

```powershell
# ============================================================================
#region Scan engine - classification (pure)
# ============================================================================

function Get-PrincipalCategory {
    # Classify a role-assignment principal; return a rule-category key to
    # remove, or $null to KEEP (named internal member, default group, system).
    param([string]$Login, [string]$Title)
    if ([string]::IsNullOrWhiteSpace($Login) -and [string]::IsNullOrWhiteSpace($Title)) { return $null }
    if ($Title -like 'SharingLinks.*' -or $Login -like '*SharingLinks.*') { return $null }  # handled via link cmdlets
    if ($Login -like 'c:0-.f|rolemanager|spo-grid-all-users/*') { return 'EEEU' }
    if ($Login -eq 'c:0(.s|true') { return 'Everyone' }
    if ($Login -like '*#ext#*') { return 'GuestGrant' }
    return $null
}

function Get-GuestGrantees {
    # External grantees on a "users" (specific people) sharing link.
    param($Link)
    $out = @()
    foreach ($g in @($Link.GrantedToIdentitiesV2)) {
        if (-not $g) { continue }
        $ln = $g.SiteUser.LoginName
        $em = $g.User.Email
        if     ($ln -and $ln -like '*#ext#*') { $out += ($em ? $em : $ln) }
        elseif ($em -and $em -match 'guest#') { $out += $em }
    }
    return $out
}

function Get-LinkCategory {
    # Map a sharing link to a rule-category key + display principal, or $null to keep.
    param([string]$Scope, $Link)
    switch ($Scope.ToLower()) {
        'anonymous'    { return @{ Key = 'AnonymousLink'; Principal = 'Anyone with the link' } }
        'organization' { return @{ Key = 'OrgLink'; Principal = 'People in your organization' } }
        'users'        {
            $g = @(Get-GuestGrantees -Link $Link)
            if ($g.Count -gt 0) { return @{ Key = 'GuestLink'; Principal = ($g -join ';') } }
            return $null
        }
    }
    return $null
}

#endregion
```

- [ ] **Step 4: Run tests, verify pass** — `pwsh ./tests/run-tests.ps1`, expect all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/35-scan-engine.ps1 tests/scan-engine.tests.ps1
git commit -m "feat: principal and link classification (pure scan-engine core)"
```

---

### Task 6: Revoke ordering + connection params (pure)

**Files:**
- Create: `src/40-revoke.ps1` (ordering only), `src/30-connections.ps1` (param builder only), `tests/revoke.tests.ps1`, `tests/connections.tests.ps1`

**Interfaces:**
- Produces: `Get-RevokeOrder -Findings <array>` → sorted array (links first, then grants; leaf File/Folder before Library before Web); `Get-ConnectParams -Url <s>` → hashtable splat for `Connect-PnPOnline` built from `$script:Auth`.
- Finding object shape (used by everything downstream): `Site, Location('Web'|'Library'|'Folder'|'File'), Name, CategoryKey, Category, Access, Principal, Path, RemovalKind('Link'|'DirectGrant'), LinkId, ListId, ItemId, PrincipalId, RevokeStatus, Selected`.

- [ ] **Step 1: Write failing tests**

`tests/revoke.tests.ps1`:

```powershell
Invoke-SsmTest 'Revoke order: links first, leaf before web' {
    $f = @(
        [pscustomobject]@{ RemovalKind='DirectGrant'; Location='Web';    Name='w' },
        [pscustomobject]@{ RemovalKind='DirectGrant'; Location='File';   Name='fg' },
        [pscustomobject]@{ RemovalKind='Link';        Location='Folder'; Name='fl' },
        [pscustomobject]@{ RemovalKind='DirectGrant'; Location='Library';Name='lib' },
        [pscustomobject]@{ RemovalKind='Link';        Location='File';   Name='fi' }
    )
    $o = @(Get-RevokeOrder -Findings $f)
    Assert-Equal 'Link' $o[0].RemovalKind
    Assert-Equal 'Link' $o[1].RemovalKind
    Assert-Equal 'fg'  $o[2].Name
    Assert-Equal 'lib' $o[3].Name
    Assert-Equal 'w'   $o[4].Name
}
```

`tests/connections.tests.ps1`:

```powershell
Invoke-SsmTest 'Connect params: delegated' {
    $script:Auth = @{ Loaded=$true; AuthMode='Delegated'; ClientId='cid'; Tenant=''; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
    $p = Get-ConnectParams -Url 'https://x.sharepoint.com/sites/a'
    Assert-Equal 'cid' $p.ClientId
    Assert-Equal 'True' $p.Interactive
    Assert-Equal 'False' $p.ContainsKey('Thumbprint')
}
Invoke-SsmTest 'Connect params: app-only thumbprint' {
    $script:Auth = @{ Loaded=$true; AuthMode='AppOnly'; ClientId='cid'; Tenant='contoso.onmicrosoft.com'; AdminUrl=''; Thumbprint='ABCD'; CertPath=''; CertExpires='' }
    $p = Get-ConnectParams -Url 'https://x.sharepoint.com/sites/a'
    Assert-Equal 'ABCD' $p.Thumbprint
    Assert-Equal 'contoso.onmicrosoft.com' $p.Tenant
    Assert-Equal 'False' $p.ContainsKey('Interactive')
}
Invoke-SsmTest 'Connect params: app-only pfx path when no thumbprint' {
    $script:Auth = @{ Loaded=$true; AuthMode='AppOnly'; ClientId='cid'; Tenant='contoso.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath='/tmp/a.pfx'; CertExpires='' }
    $p = Get-ConnectParams -Url 'https://x.sharepoint.com/sites/a'
    Assert-Equal '/tmp/a.pfx' $p.CertificatePath
}
```

- [ ] **Step 2: Run tests, verify fail** — expect "Get-RevokeOrder is not recognized".

- [ ] **Step 3: Implement**

`src/40-revoke.ps1` (ordering part; execution added in Task 8):

```powershell
# ============================================================================
#region Revoke - ordering (pure)
# ============================================================================

function Get-RevokeOrder {
    # Links before direct grants; leaf grants (File/Folder) before Library
    # before Web, so a single claim principal (e.g. EEEU) is not
    # de-provisioned out from under later removals.
    param($Findings)
    $depth = @{ 'File' = 0; 'Folder' = 0; 'Library' = 1; 'Web' = 2 }
    return @($Findings | Sort-Object `
        @{ Expression = { if ($_.RemovalKind -eq 'Link') { 0 } else { 1 } } }, `
        @{ Expression = { $depth[$_.Location] } })
}

#endregion
```

`src/30-connections.ps1` (param builder; connect functions added in Task 8):

```powershell
# ============================================================================
#region Connections
# ============================================================================

function Get-ConnectParams {
    # Splat for Connect-PnPOnline, from the configured auth mode.
    param([string]$Url)
    $p = @{ Url = $Url; ClientId = $script:Auth.ClientId }
    if ($script:Auth.AuthMode -eq 'AppOnly') {
        $p.Tenant = $script:Auth.Tenant
        if ($script:Auth.Thumbprint) { $p.Thumbprint = $script:Auth.Thumbprint }
        else { $p.CertificatePath = $script:Auth.CertPath }
    } else {
        $p.Interactive = $true
    }
    return $p
}

#endregion
```

- [ ] **Step 4: Run tests, verify pass** — `pwsh ./tests/run-tests.ps1`, all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/40-revoke.ps1 src/30-connections.ps1 tests/revoke.tests.ps1 tests/connections.tests.ps1
git commit -m "feat: revoke ordering and Connect-PnPOnline param builder"
```

---

### Task 7: Targets (CSV import + tenant enumeration)

**Files:**
- Create: `src/45-targets.ps1`, `tests/targets.tests.ps1`

**Interfaces:**
- Produces: `New-Target -Url <s> [-Title <s>] [-Template <s>]` → target object `@{ Url; Title; Template; Status='NotScanned'; FindingCount=0; Findings=@(); Selected=$false }`; `Get-UrlsFromCsv -Path <s> [-UrlColumn 'Url']` → string[]; `Get-TenantTargets -OneDrive <bool>` → target[] (PnP; requires admin connection); `Add-TargetsToTab -Tab -Targets` (dedupe by URL, append).
- Consumes: `Connect-SsmAdmin` (Task 8) — `Get-TenantTargets` calls it; until Task 8 lands it will fail at runtime, which is fine (parse + pure tests only here).

- [ ] **Step 1: Write failing tests `tests/targets.tests.ps1`**

```powershell
$csv = Join-Path ([IO.Path]::GetTempPath()) ("ssm-{0}.csv" -f [guid]::NewGuid())

Invoke-SsmTest 'CSV import: Url header' {
    @('Url','https://a/ ',' https://b',''), '' | Out-Null
    Set-Content -LiteralPath $csv -Value "Url`nhttps://a/ `n https://b`n"
    $u = @(Get-UrlsFromCsv -Path $csv)
    Assert-Equal 2 $u.Count
    Assert-Equal 'https://a/' $u[0].TrimEnd()   # trimmed of spaces, not slash
    Assert-Equal 'https://b' $u[1]
}
Invoke-SsmTest 'CSV import: falls back to first column' {
    Set-Content -LiteralPath $csv -Value "SiteUrl`nhttps://c`n"
    $u = @(Get-UrlsFromCsv -Path $csv)
    Assert-Equal 'https://c' $u[0]
}
Invoke-SsmTest 'CSV import: missing file throws' {
    $threw = $false
    try { Get-UrlsFromCsv -Path '/nonexistent/x.csv' } catch { $threw = $true }
    Assert-Equal 'True' $threw
}
Invoke-SsmTest 'Add-TargetsToTab dedupes by URL' {
    $tab = @{ Items = @(); View = @(); Cursor = 0; Search=''; Filter='All'; SortCol='Url'; SortDesc=$false }
    Add-TargetsToTab -Tab $tab -Targets @((New-Target -Url 'https://a'), (New-Target -Url 'https://a/'), (New-Target -Url 'https://b'))
    Assert-Equal 2 @($tab.Items).Count
}
Remove-Item -LiteralPath $csv -ErrorAction SilentlyContinue
```

Note: `Add-TargetsToTab` must not call `Update-TabView` when it is not defined (tests load no views). Guard with `Get-Command -ErrorAction SilentlyContinue`.

- [ ] **Step 2: Run tests, verify fail** — expect "Get-UrlsFromCsv is not recognized".

- [ ] **Step 3: Implement `src/45-targets.ps1`**

```powershell
# ============================================================================
#region Targets
# ============================================================================

function New-Target {
    param([string]$Url, [string]$Title = '', [string]$Template = '')
    if (-not $Title) { $Title = ($Url.TrimEnd('/') -split '/')[-1] }
    return @{
        Url = $Url.Trim(); Title = $Title; Template = $Template
        Status = 'NotScanned'; FindingCount = 0
        Findings = @(); Selected = $false
    }
}

function Get-UrlsFromCsv {
    # Column 'Url' (or -UrlColumn), falling back to the first column -
    # same behavior as the original OneDrive script.
    param([string]$Path, [string]$UrlColumn = 'Url')
    if (-not (Test-Path -LiteralPath $Path)) { throw "CSV not found: $Path" }
    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { return @() }
    $col = $UrlColumn
    if (-not ($rows[0].PSObject.Properties.Name -contains $col)) { $col = $rows[0].PSObject.Properties.Name[0] }
    return @($rows | ForEach-Object { $_.$col } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Add-TargetsToTab {
    # Append targets, deduplicating on trailing-slash-insensitive URL.
    param($Tab, $Targets)
    $known = @{}
    foreach ($t in @($Tab['Items'])) { $known[$t.Url.TrimEnd('/')] = $true }
    $items = [System.Collections.ArrayList]@($Tab['Items'])
    foreach ($t in @($Targets)) {
        $key = $t.Url.TrimEnd('/')
        if (-not $key -or $known.ContainsKey($key)) { continue }
        $known[$key] = $true
        [void]$items.Add($t)
    }
    $Tab['Items'] = @($items)
    $Tab['Loaded'] = $true
    if (Get-Command Update-TabView -ErrorAction SilentlyContinue) { Update-TabView -Tab $Tab }
}

function Get-TenantTargets {
    # Enumerate site collections via the tenant admin connection.
    # OneDrive tab: personal sites (SPSPERS template); Sites tab: everything else.
    param([bool]$OneDrive)
    if (-not (Connect-SsmAdmin)) { return @() }
    $sites = @(Get-PnPTenantSite -IncludeOneDriveSites:$OneDrive -ErrorAction Stop)
    $out = @()
    foreach ($s in $sites) {
        $isPersonal = ($s.Template -like 'SPSPERS*')
        if ($OneDrive -ne $isPersonal) { continue }
        $out += (New-Target -Url $s.Url -Title $s.Title -Template $s.Template)
    }
    Write-SsmLog -Message ("Enumerated {0} {1} from the tenant." -f $out.Count, ($OneDrive ? 'OneDrives' : 'sites'))
    return $out
}

#endregion
```

- [ ] **Step 4: Run tests, verify pass** — all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/45-targets.ps1 tests/targets.tests.ps1
git commit -m "feat: target objects, CSV import, tenant site enumeration"
```

---

### Task 8: Connections (live), site scan, revoke execution

**Files:**
- Modify: `src/30-connections.ps1`, `src/35-scan-engine.ps1`, `src/40-revoke.ps1`

**Interfaces:**
- Produces: `Connect-SsmSite -Url <s>` → bool (connects via `Get-ConnectParams`, caches `$script:Conn.Url`, no-op if already connected there); `Connect-SsmAdmin` → bool (uses `$script:Auth.AdminUrl`; prompts via `Show-InputModal` and saves it if empty); `Disconnect-SsmConnection`; `Invoke-SiteScan -Target <target> -Categories <string[]> [-Progress <scriptblock>]` → finding[] ; `Invoke-Revoke -Findings <array>` → int removed (sets `RevokeStatus` per finding).
- Consumes: `Get-ConnectParams`, `Get-PrincipalCategory`, `Get-LinkCategory`, `Get-RevokeOrder`, `$script:ExcludedUrlNames`, `Install-SsmModule`, modals.
- PnP-bound code: no unit tests; verification is parse + analyzer + the manual tmux recipe (Task 15).

- [ ] **Step 1: Complete `src/30-connections.ps1`**

Append below `Get-ConnectParams`:

```powershell
function Connect-SsmSite {
    # Connect (or reuse) a PnP connection to a specific site/OneDrive URL.
    param([string]$Url)
    if (-not (Install-SsmModule)) { return $false }
    if (-not (Test-SsmAuthReady)) {
        Show-MsgModal -Title 'Not configured' -Lines @(
            'No usable sign-in configuration.',
            'Go to the Setup tab (4) to register an app or enter a Client Id.') -Kind Warn
        return $false
    }
    $norm = $Url.TrimEnd('/')
    if ($script:Conn.Url -eq $norm) { return $true }
    try {
        $p = Get-ConnectParams -Url $norm
        if ($script:Auth.AuthMode -eq 'Delegated') {
            # Interactive auth needs the main buffer for the browser prompt message
            Invoke-OnMainBuffer { Write-Host ("Signing in to {0} ..." -f $norm) -ForegroundColor Yellow }
        }
        Connect-PnPOnline @p -ErrorAction Stop
        $script:Conn.Url = $norm
        $script:Conn.Admin = ($norm -like '*-admin.sharepoint.com*')
        $script:Conn.Account = if ($script:Auth.AuthMode -eq 'AppOnly') { 'app:' + $script:Auth.ClientId.Substring(0, 8) }
                               else { (Get-PnPConnection).PSCredential ?? 'delegated' }
        Write-SsmLog -Message ("Connected to {0}" -f $norm) -Level OK
        return $true
    } catch {
        Write-SsmLog -Message ("Connect failed for {0}: {1}" -f $norm, $_.Exception.Message) -Level ERROR
        $script:Conn.Url = ''
        return $false
    }
}

function Connect-SsmAdmin {
    # Connect to the tenant admin site (for Get-PnPTenantSite / Set-PnPTenant).
    if (-not $script:Auth.AdminUrl) {
        $u = Show-InputModal -Title 'Tenant admin URL' -Prompt 'e.g. https://contoso-admin.sharepoint.com'
        if (-not $u) { return $false }
        $script:Auth.AdminUrl = $u.Trim().TrimEnd('/')
        Save-SsmAuth
    }
    return (Connect-SsmSite -Url $script:Auth.AdminUrl)
}

function Disconnect-SsmConnection {
    try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
    $script:Conn.Url = ''; $script:Conn.Admin = $false; $script:Conn.Account = ''
    Write-SsmLog -Message 'Disconnected.'
}
```

Note on `$script:Conn.Account` for delegated mode: after `Connect-PnPOnline -Interactive`, read the signed-in identity via `(Get-PnPProperty -ClientObject (Get-PnPContext).Web -Property CurrentUser).Email` inside a try/catch; fall back to `'delegated'`. Keep whichever expression works — verify during manual testing.

- [ ] **Step 2: Add `Invoke-SiteScan` to `src/35-scan-engine.ps1`**

Port `Scan-Site`, `Get-RestUnique`, `Add-GrantsRest` from `Revoke-OneDrive-NonMemberAccess.ps1` (lines 168–274) with these changes — the mechanics (REST enumeration by Id range, `$top=5000`, unique-permission filter, excluded URL leaf names, hidden lists skipped) stay identical:

1. Rename `Scan-Site` → `Invoke-SiteScan`, signature `param($Target, [string[]]$Categories, [scriptblock]$Progress)`.
2. Findings gain `CategoryKey` (the key) and `Category` (display name from `$script:RuleCategories[$key]`) and `Selected = $false`. All original fields kept: `Site, Location, Name, Access, Principal, Path, RemovalKind, LinkId, ListId, ItemId, PrincipalId, RevokeStatus`.
3. Category gating: in `Add-GrantsRest`, after `Get-PrincipalCategory` returns a key, `if ($Categories -notcontains $key) { continue }`. For links, after `Get-LinkCategory` returns `@{Key;Principal}`, same check. Grant scanning (web/library/item role assignments) is skipped entirely when `$Categories` contains none of `GuestGrant`,`EEEU`,`Everyone`; link enumeration is skipped when none of `AnonymousLink`,`OrgLink`,`GuestLink`.
4. Replace `Write-Host`/`Write-Progress` calls with `Write-SsmLog` + `& $Progress -Count <n> -Label <s>` (throttled by the caller, template pattern from `Invoke-TabLoad`).
5. The Limited Access skip stays verbatim: real roles = `RoleDefinitionBindings` where `[int]RoleTypeKind -ne 1`; zero real roles ⇒ skip.

- [ ] **Step 3: Add `Invoke-Revoke` to `src/40-revoke.ps1`**

Port `Remove-Findings` (lines 277–319 of the OneDrive script) renamed `Invoke-Revoke`, using `Get-RevokeOrder` for ordering. Keep verbatim: empty-LinkId skip, `Remove-PnPFileSharingLink`/`Remove-PnPFolderSharingLink` split by Location, direct-grant removal via `RoleAssignments.GetByPrincipalId().DeleteObject()` + `Invoke-PnPQuery`, and the `AlreadyRevoked` catch (`'find the principal'|'does not exist'|'Cannot find'`). Replace `Write-Progress` with an optional `-Progress` scriptblock like the scan. Returns count removed.

- [ ] **Step 4: Parse + analyzer + tests**

Run: `pwsh ./tests/run-tests.ps1` → all PASS (pure tests unaffected).
Run: `pwsh -c 'Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error,Warning'` → no output.

- [ ] **Step 5: Commit**

```bash
git add src/30-connections.ps1 src/35-scan-engine.ps1 src/40-revoke.ps1
git commit -m "feat: PnP connections, full site scan, revoke execution"
```

---

### Task 9: Evidence CSVs

**Files:**
- Create: `src/50-csv.ps1`, `tests/csv.tests.ps1`

**Interfaces:**
- Produces: `Export-FindingsCsv -Findings <array> -SiteUrl <s> -Phase 'BEFORE'|'REVOKED'` → written file path (in `$script:ExportDir`, creating it; name `SSM_<Phase>_<siteTag>_<yyyyMMdd-HHmmss>.csv`, UTF8BOM, columns `Site,Location,Category,Name,Access,Principal,Path,RevokeStatus`); `Export-ViewCsv -Tab` (current view of targets or findings to CSV, same dir).
- Consumes: finding shape (Task 6), `$script:ExportDir`.

- [ ] **Step 1: Write failing test `tests/csv.tests.ps1`**

```powershell
Invoke-SsmTest 'Evidence CSV written with expected name and columns' {
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssm-exp-{0}" -f [guid]::NewGuid())
    $f = @([pscustomobject]@{ Site='https://x/personal/y'; Location='File'; CategoryKey='OrgLink'; Category='Organization link'; Name='doc.docx'; Access='View'; Principal='People in your organization'; Path='/personal/y/Documents/doc.docx'; RemovalKind='Link'; LinkId='1'; ListId='L'; ItemId=3; PrincipalId=$null; RevokeStatus='NotAttempted'; Selected=$true })
    $path = Export-FindingsCsv -Findings $f -SiteUrl 'https://x/personal/y' -Phase 'BEFORE'
    if ($path -notmatch 'SSM_BEFORE_y_\d{8}-\d{6}\.csv$') { throw "bad name: $path" }
    $row = @(Import-Csv -LiteralPath $path)[0]
    Assert-Equal 'Organization link' $row.Category
    Assert-Equal 'NotAttempted' $row.RevokeStatus
    Remove-Item -Recurse -Force $script:ExportDir
}
```

Add `50-csv` to the runner's pure-file list in `tests/run-tests.ps1`.

- [ ] **Step 2: Run tests, verify fail** — "Export-FindingsCsv is not recognized".

- [ ] **Step 3: Implement `src/50-csv.ps1`**

```powershell
# ============================================================================
#region CSV evidence & export
# ============================================================================

function Export-FindingsCsv {
    param($Findings, [string]$SiteUrl, [ValidateSet('BEFORE','REVOKED')][string]$Phase)
    if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Path $script:ExportDir | Out-Null }
    $tag   = ($SiteUrl.TrimEnd('/') -split '/')[-1]
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path  = Join-Path $script:ExportDir ("SSM_{0}_{1}_{2}.csv" -f $Phase, $tag, $stamp)
    $Findings | Select-Object Site, Location, Category, Name, Access, Principal, Path, RevokeStatus |
        Export-Csv -Path $path -NoTypeInformation -Encoding UTF8BOM
    Write-SsmLog -Message ("{0} evidence: {1}" -f $Phase, $path)
    return $path
}

function Export-ViewCsv {
    # Export the current view (targets or findings) for the active tab.
    param($Tab)
    if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Path $script:ExportDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ($Tab['Mode'] -eq 'Findings' -and $Tab['FTab']) {
        $path = Join-Path $script:ExportDir ("{0}_findings_{1}.csv" -f $Tab['Name'], $stamp)
        @($Tab['FTab']['View']) | Select-Object Site, Location, Category, Name, Access, Principal, Path, RevokeStatus |
            Export-Csv -Path $path -NoTypeInformation -Encoding UTF8BOM
    } else {
        $path = Join-Path $script:ExportDir ("{0}_targets_{1}.csv" -f $Tab['Name'], $stamp)
        @($Tab['View']) | ForEach-Object { [pscustomobject]@{ Url=$_.Url; Title=$_.Title; Status=$_.Status; Findings=$_.FindingCount } } |
            Export-Csv -Path $path -NoTypeInformation -Encoding UTF8BOM
    }
    Show-MsgModal -Title 'Exported' -Lines @('View exported to:', $path)
}

#endregion
```

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add src/50-csv.ps1 tests/csv.tests.ps1 tests/run-tests.ps1
git commit -m "feat: BEFORE/REVOKED evidence CSVs and view export"
```

---

### Task 10: Views and key dispatch

**Files:**
- Create: `src/65-views.ps1`, `src/75-key-dispatch.ps1`

**Interfaces:**
- Produces: `Write-Screen`, `Update-TabView -Tab`, `Update-FindingsView -Tab`, `Invoke-TabScan -Tab`, `Enter-FindingsMode -Tab -Target`, `Exit-FindingsMode -Tab`, `Invoke-FindingsRevoke -Tab`, `Show-CategoryToggleModal -Tab`, `Get-TabHints -Tab`, `Invoke-KeyDispatch -K <ConsoleKeyInfo>`.
- Consumes: everything above plus template drawing/modals. Tenant/Setup view render state comes from Tasks 11–12; write the two views here against the interfaces those tasks declare (`$script:Tabs[2].Posture`, `$script:Auth`).

Start both files from the template (`$TPL/src/65-views.ps1`, `$TPL/src/75-key-dispatch.ps1`): keep `Add-TitleBar` (retitle `SharePoint Sharing Manager`, connection piece shows `$script:Conn.Url`/`Account` instead of EXO/Graph), plus an app-only cert-expiry piece: when `Get-CertDaysLeft` returns a value, append `cert <date>` styled `TitleOk`, or `TitleDim`+Warn style when under 30 days, `Add-TabBar`, `Add-LogView`, `Invoke-LogKey`, the scroll-clamping row loop of `Add-ListView`, the search-mode blocks, and the `Write-Screen`/`Invoke-KeyDispatch` skeletons. Replace list specifics as follows.

- [ ] **Step 1: Views — `src/65-views.ps1`**

```powershell
function Update-TabView {
    # Filter + sort targets. Filter: All | NotScanned | Clean | Findings | Failed.
    param($Tab)
    $items = @($Tab['Items'])
    switch ($Tab['Filter']) {
        'NotScanned' { $items = @($items | Where-Object { $_.Status -eq 'NotScanned' }) }
        'Clean'      { $items = @($items | Where-Object { $_.Status -eq 'Clean' }) }
        'Findings'   { $items = @($items | Where-Object { $_.Status -eq 'Findings' -or $_.Status -eq 'Revoked' }) }
        'Failed'     { $items = @($items | Where-Object { $_.Status -like '*Failed' }) }
    }
    if (-not [string]::IsNullOrEmpty($Tab['Search'])) {
        $n = $Tab['Search']
        $items = @($items | Where-Object { ($_.Url -like "*$n*") -or ($_.Title -like "*$n*") })
    }
    $prop = $Tab['SortCol']   # Url | Title | Status | Findings
    $expr = switch ($prop) { 'Findings' { { $_.FindingCount } } default { { $_.$prop } } }
    $items = if ($Tab['SortDesc']) { @($items | Sort-Object -Property $expr -Descending) } else { @($items | Sort-Object -Property $expr) }
    $Tab['View'] = $items
    if ($Tab['Cursor'] -ge $items.Count) { $Tab['Cursor'] = [Math]::Max(0, $items.Count - 1) }
    $script:UI.Dirty = $true
}

function Update-FindingsView {
    # Filter + sort the findings sub-view. Filter cycles category keys.
    param($Tab)
    $ft = $Tab['FTab']
    $items = @($ft['Items'])
    if ($ft['Filter'] -ne 'All') { $items = @($items | Where-Object { $_.CategoryKey -eq $ft['Filter'] }) }
    if (-not [string]::IsNullOrEmpty($ft['Search'])) {
        $n = $ft['Search']
        $items = @($items | Where-Object { ($_.Name -like "*$n*") -or ($_.Principal -like "*$n*") -or ($_.Path -like "*$n*") })
    }
    $ft['View'] = @($items | Sort-Object Category, Path)
    if ($ft['Cursor'] -ge @($ft['View']).Count) { $ft['Cursor'] = [Math]::Max(0, @($ft['View']).Count - 1) }
    $script:UI.Dirty = $true
}
```

Targets list rendering (`Add-TargetsView`): mirror the template `Add-ListView` structure exactly (not-loaded panel, context row, header, scroll clamp, cursor/selection styling) with columns `sel(3) | Title(flex 35%) | Url(flex 65%) | Findings(8, right-aligned count) | Status(13 via Get-StatusBadge)`. Not-loaded panel text: "No targets yet." / "Press Enter to enumerate from the tenant, U to add a URL, I to import a CSV." plus, when `-not (Test-SsmAuthReady)`, a Warn line "Sign-in is not configured - see the Setup tab (4)."

Findings rendering (`Add-FindingsView`): context row `' <site url>   N of M findings   K selected   filter:<F>'`, columns `sel(3) | Category(20) | Loc(7) | Name(flex 40%) | Principal(flex 60%) | Status(12)`; status cell shows `RevokeStatus` (`Removed` in Good, `Failed:*` in Danger, else Muted).

Scan orchestration:

```powershell
function Invoke-TabScan {
    # Scan all selected targets sequentially. Per-target failure isolation:
    # a failed connect/scan marks the target and the loop continues.
    param($Tab)
    $sel = @($Tab['Items'] | Where-Object { $_.Selected })
    if ($sel.Count -eq 0) { Show-MsgModal -Title 'Scan' -Lines @('Nothing selected. Space selects targets.') ; return }
    $cats = @($Tab['Categories'])
    if ($cats.Count -eq 0) { Show-MsgModal -Title 'Scan' -Lines @('No rule categories enabled. Press T to enable some.') -Kind Warn; return }
    $i = 0
    foreach ($t in $sel) {
        $i++
        $t.Status = 'Scanning'; Write-Screen
        Start-LoadSpinner
        Write-ProgressModal -Title ("Scanning {0}/{1}" -f $i, $sel.Count) -Done 0 -Total 0 -Label $t.Url -Ok 0 -Failed 0
        $fnProgress = ${function:Write-ProgressModal}
        $state = @{ LastTick = 0 }
        $cb = {
            param($Count, $Label)
            while ([Console]::KeyAvailable) {
                if ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Escape) { throw (New-Object System.OperationCanceledException 'Scan cancelled.') }
            }
            $now = [Environment]::TickCount
            if (($now - $state.LastTick) -lt 150) { return }
            $state.LastTick = $now
            & $fnProgress -Title 'Scanning' -Done $Count -Total 0 -Label $Label -Ok 0 -Failed 0
        }.GetNewClosure()
        try {
            if (-not (Connect-SsmSite -Url $t.Url)) { $t.Status = 'ConnectFailed'; continue }
            $findings = @(Invoke-SiteScan -Target $t -Categories $cats -Progress $cb)
            $t.Findings = $findings
            $t.FindingCount = $findings.Count
            $t.Status = if ($findings.Count -eq 0) { 'Clean' } else { 'Findings' }
            if ($findings.Count -gt 0) { [void](Export-FindingsCsv -Findings $findings -SiteUrl $t.Url -Phase 'BEFORE') }
        } catch [System.OperationCanceledException] {
            $t.Status = 'NotScanned'
            Write-SsmLog -Message 'Scan cancelled by user (Esc).' -Level WARN
            Stop-LoadSpinner
            break
        } catch {
            $t.Status = 'ScanFailed'
            Write-SsmLog -Message ("Scan failed for {0}: {1}" -f $t.Url, $_.Exception.Message) -Level ERROR
        } finally {
            Stop-LoadSpinner
        }
    }
    Update-TabView -Tab $Tab
}

function Enter-FindingsMode {
    param($Tab, $Target)
    $Tab['Mode'] = 'Findings'
    $Tab['FTab'] = @{ Target = $Target; Items = @($Target.Findings); View = @(); Cursor = 0; Scroll = 0; Search = ''; Filter = 'All' }
    Update-FindingsView -Tab $Tab
}

function Exit-FindingsMode {
    param($Tab)
    $Tab['Mode'] = 'Targets'; $Tab['FTab'] = $null
    $script:UI.Dirty = $true
}

function Invoke-FindingsRevoke {
    # Revoke selected findings on the drilled target, typed confirmation first.
    param($Tab)
    $ft = $Tab['FTab']; $target = $ft['Target']
    $sel = @($ft['Items'] | Where-Object { $_.Selected })
    if ($sel.Count -eq 0) { Show-MsgModal -Title 'Revoke' -Lines @('Nothing selected.'); return }
    $byCat = ($sel | Group-Object Category | ForEach-Object { "  {0}: {1}" -f $_.Name, $_.Count })
    $ok = Show-TypedConfirmModal -Title 'Revoke sharing' -Word 'REVOKE' -Lines (@(
        ("Remove {0} link(s)/grant(s) on" -f $sel.Count), $target.Url, '') + $byCat + @('', 'Files and folders are never deleted. This cannot be undone.'))
    if (-not $ok) { return }
    if (-not (Connect-SsmSite -Url $target.Url)) { return }
    $removed = Invoke-Revoke -Findings $sel
    [void](Export-FindingsCsv -Findings @($ft['Items']) -SiteUrl $target.Url -Phase 'REVOKED')
    $target.FindingCount = @($target.Findings | Where-Object { $_.RevokeStatus -ne 'Removed' -and $_.RevokeStatus -ne 'AlreadyRevoked' }).Count
    if ($target.FindingCount -eq 0) { $target.Status = 'Revoked' }
    Show-ReportModal -Title 'Revoke complete' -Lines @(("Removed {0} of {1}. Evidence CSV written." -f $removed, $sel.Count))
    Update-FindingsView -Tab $Tab
}

function Show-CategoryToggleModal {
    # Space toggles a category, Enter accepts. Simple numbered input loop
    # built on Show-InputModal-style modal drawing (see template Read-ModalKey).
    param($Tab)
    $keys = @($script:RuleCategories.Keys)
    while ($true) {
        $lines = @('Enabled rule categories (press 1-' + $keys.Count + ' to toggle, Enter to accept):', '')
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $on = ($Tab['Categories'] -contains $keys[$i])
            $mark = if ($on) { [string]$script:G.ChkOn } else { [string]$script:G.ChkOff }
            $lines += ("  {0} {1} {2}" -f ($i + 1), $mark, $script:RuleCategories[$keys[$i]])
        }
        Write-ModalFrame -Title 'Scan rules' -Lines (ConvertTo-ModalLines -Lines $lines)
        $k = Read-ModalKey
        if ($k.Key -eq 'Enter' -or $k.Key -eq 'Escape') { break }
        $n = 0
        if ([int]::TryParse([string]$k.KeyChar, [ref]$n) -and $n -ge 1 -and $n -le $keys.Count) {
            $key = $keys[$n - 1]
            if ($Tab['Categories'] -contains $key) { [void]$Tab['Categories'].Remove($key) } else { [void]$Tab['Categories'].Add($key) }
        }
    }
    $script:UI.Dirty = $true
}
```

Adjust `Write-ModalFrame`/`ConvertTo-ModalLines`/`Read-ModalKey` call signatures to whatever the ported `src/20-modals.ps1` actually exposes.

Tenant view (`Add-TenantView`, template `Add-OrgView` pattern): not-loaded panel ("Press Enter to connect to the tenant admin site and read the sharing posture."); loaded: rows for `SharingCapability`, `OneDriveSharingCapability`, `DefaultSharingLinkType`, `DefaultLinkPermission`, `RequireAnonymousLinksExpireInDays` from `$script:Tabs[2].Posture`, each with a Muted explanation line; footer-hinted action keys are handled in dispatch.

Setup view (`Add-SetupView`): static panel showing `$script:Auth` fields (mode, ClientId, tenant, admin URL, cert thumbprint/path + `Get-CertDaysLeft` with Warn style under 30 days), config path, PnP module presence/version, and the action key legend (D/C/W/X per Task 12).

`Get-TabHints`:

```powershell
function Get-TabHints {
    param($Tab)
    if ($script:UI.SearchMode) { return @() }
    switch ($Tab['Kind']) {
        'Targets' {
            if ($Tab['Mode'] -eq 'Findings') {
                return @(@('Spc','select'),@('A','all'),@('N','none'),@('/','find'),@('F','filter'),
                         @('R','revoke selected'),@('E','export'),@('Esc','back'),@('?','help'),@('Q','quit'))
            }
            return @(@('Spc','select'),@('A','all'),@('N','none'),@('/','find'),@('F','filter'),
                     @('S','scan'),@('T','rules'),@('U','add url'),@('I','import csv'),
                     @('Enter','open/load'),@('E','export'),@('?','help'),@('Q','quit'))
        }
        'Tenant' { return @(@('Enter','load'),@('1-5','change setting'),@('R','refresh'),@('?','help'),@('Q','quit')) }
        'Setup'  { return @(@('D','delegated app'),@('C','cert app'),@('W','renew cert'),@('X','edit config'),@('?','help'),@('Q','quit')) }
        'Log'    { return @(@('Up/Dn','scroll'),@('O','open log file'),@('?','help'),@('Q','quit')) }
    }
    return @()
}
```

`Write-Screen`: template skeleton; switch on `$tab['Kind']` → `'Targets'` renders `Add-TargetsView` or `Add-FindingsView` per `Mode`; `'Tenant'`/`'Setup'`/`'Log'` render their views.

- [ ] **Step 2: Key dispatch — `src/75-key-dispatch.ps1`**

Template skeleton with: `Invoke-TargetsKey` (template `Invoke-ListKey` navigation/search/selection verbatim, hotkeys: `F` cycles `All→NotScanned→Clean→Findings→Failed`, `S`→`Invoke-TabScan`, `T`→`Show-CategoryToggleModal`, `U`→`Show-InputModal` for a URL then `Add-TargetsToTab` with `New-Target`, `I`→`Show-InputModal` for a CSV path then `Get-UrlsFromCsv`|`New-Target`|`Add-TargetsToTab` in try/catch with `Show-MsgModal` on error, `E`→`Export-ViewCsv`, `Enter` on empty list→`Add-TargetsToTab -Targets (Get-TenantTargets -OneDrive $Tab['OneDrive'])`, `Enter` on a target with Status `Findings`/`Revoked`→`Enter-FindingsMode`); `Invoke-FindingsKey` (same navigation against `$Tab['FTab']`, `F` cycles `All` + each category key present in items, `R`→`Invoke-FindingsRevoke`, `E`→`Export-ViewCsv`, `Escape`→`Exit-FindingsMode`); `Invoke-TenantKey` and `Invoke-SetupKey` delegating to Task 11/12 functions; `Invoke-LogKey` ported verbatim; `Invoke-KeyDispatch` global keys: Ctrl+C/Q quit, Tab/1-5 switch, `?` help, `W` disconnect → `Disconnect-SsmConnection` (keep targets loaded; only connection state resets).

- [ ] **Step 3: Verify**

Run: parse check (Task 2 Step 4 command) → `parse OK`.
Run: `pwsh ./tests/run-tests.ps1` → all PASS.
Run: analyzer (Task 8 Step 4 command) → clean.
Smoke: `pwsh ./SharePoint-Sharing-Manager.ps1` in a real terminal — UI opens, tabs switch, `Q` quits cleanly, log file written. (Skip if headless; the tmux recipe in Task 15 covers it.)

- [ ] **Step 4: Commit**

```bash
git add src/65-views.ps1 src/75-key-dispatch.ps1
git commit -m "feat: targets/findings/tenant/setup views and key dispatch"
```

---

### Task 11: Tenant actions

**Files:**
- Create: `src/55-tenant-actions.ps1`

**Interfaces:**
- Produces: `Get-TenantPosture` → hashtable stored on `$script:Tabs[2].Posture` (`SharingCapability, OneDriveSharingCapability, DefaultSharingLinkType, DefaultLinkPermission, RequireAnonymousLinksExpireInDays, CheckedAt`); `Invoke-TenantSetting -Number <1..5>` (prompts for the new value, typed `APPLY` confirmation, `Set-PnPTenant`, refresh).
- Consumes: `Connect-SsmAdmin`, modals, `$script:Tabs[2]`.

- [ ] **Step 1: Implement `src/55-tenant-actions.ps1`**

```powershell
# ============================================================================
#region Tenant actions
# ============================================================================

$script:TenantSettings = @(
    @{ N=1; Prop='SharingCapability';                 Values=@('Disabled','ExistingExternalUserSharingOnly','ExternalUserSharingOnly','ExternalUserAndGuestSharing') },
    @{ N=2; Prop='OneDriveSharingCapability';         Values=@('Disabled','ExistingExternalUserSharingOnly','ExternalUserSharingOnly','ExternalUserAndGuestSharing') },
    @{ N=3; Prop='DefaultSharingLinkType';            Values=@('None','Direct','Internal','AnonymousAccess') },
    @{ N=4; Prop='DefaultLinkPermission';             Values=@('None','View','Edit') },
    @{ N=5; Prop='RequireAnonymousLinksExpireInDays'; Values=@() }   # numeric, free input
)

function Get-TenantPosture {
    if (-not (Connect-SsmAdmin)) { return $false }
    $t = Get-PnPTenant -ErrorAction Stop
    $script:Tabs[2].Posture = @{
        SharingCapability                 = [string]$t.SharingCapability
        OneDriveSharingCapability         = [string]$t.OneDriveSharingCapability
        DefaultSharingLinkType            = [string]$t.DefaultSharingLinkType
        DefaultLinkPermission             = [string]$t.DefaultLinkPermission
        RequireAnonymousLinksExpireInDays = [string]$t.RequireAnonymousLinksExpireInDays
        CheckedAt                         = Get-Date
    }
    $script:Tabs[2].Loaded = $true
    Write-SsmLog -Message 'Tenant sharing posture loaded.' -Level OK
    $script:UI.Dirty = $true
    return $true
}

function Invoke-TenantSetting {
    param([int]$Number)
    if (-not $script:Tabs[2].Loaded) { Show-MsgModal -Title 'Tenant' -Lines @('Load the posture first (Enter).'); return }
    $s = $script:TenantSettings | Where-Object { $_.N -eq $Number }
    if (-not $s) { return }
    $current = $script:Tabs[2].Posture[$s.Prop]
    $prompt = if ($s.Values.Count -gt 0) { 'One of: ' + ($s.Values -join ' | ') } else { 'Number of days (0 = no requirement)' }
    $new = Show-InputModal -Title $s.Prop -Prompt $prompt -Default $current
    if (-not $new -or $new -eq $current) { return }
    if ($s.Values.Count -gt 0 -and $s.Values -notcontains $new) {
        Show-MsgModal -Title 'Invalid value' -Lines @("'$new' is not one of:", ($s.Values -join ', ')) -Kind Warn
        return
    }
    $ok = Show-TypedConfirmModal -Title 'Change tenant setting' -Word 'APPLY' -Lines @(
        ("{0}: {1} {2} {3}" -f $s.Prop, $current, [string]$script:G.Arrow, $new), '',
        'This changes sharing behavior for the WHOLE tenant.')
    if (-not $ok) { return }
    try {
        $args = @{ $s.Prop = $new }
        Set-PnPTenant @args -ErrorAction Stop
        Write-SsmLog -Message ("Tenant setting changed: {0} = {1}" -f $s.Prop, $new) -Level OK
        [void](Get-TenantPosture)
    } catch {
        Write-SsmLog -Message ("Tenant setting failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @($_.Exception.Message) -Kind Error
    }
}

#endregion
```

`Invoke-TenantKey` (Task 10) wires: `Enter`/`R` → `Get-TenantPosture`, digits 1–5 → `Invoke-TenantSetting`.

- [ ] **Step 2: Verify** — parse + analyzer clean, tests still pass.

- [ ] **Step 3: Commit**

```bash
git add src/55-tenant-actions.ps1
git commit -m "feat: tenant sharing posture view and hardening setters"
```

---

### Task 12: Setup actions (app registration + certificate)

**Files:**
- Create: `src/60-setup-actions.ps1`

**Interfaces:**
- Produces: `Register-SsmDelegatedApp`, `Register-SsmAppOnlyApp`, `Update-SsmCertificate`, `Edit-SsmConfig` — all invoked from `Invoke-SetupKey` (D / C / W / X).
- Consumes: `Install-SsmModule`, `Save-SsmAuth`, modals, `Invoke-OnMainBuffer`.

- [ ] **Step 1: Implement `src/60-setup-actions.ps1`**

```powershell
# ============================================================================
#region Setup actions
# ============================================================================

function Get-SsmTenantInput {
    # Ask for (and remember) the *.onmicrosoft.com tenant name.
    if ($script:Auth.Tenant) { return $script:Auth.Tenant }
    $t = Show-InputModal -Title 'Tenant' -Prompt 'e.g. contoso.onmicrosoft.com'
    if ($t) { $script:Auth.Tenant = $t.Trim() }
    return $script:Auth.Tenant
}

function Register-SsmDelegatedApp {
    # Delegated interactive app (Register-PnPEntraIDAppForInteractiveLogin).
    # Any user may create it; a Global Admin consents once. Limitation shown:
    # the operator must be Site Collection Admin on every target OneDrive.
    if (-not (Install-SsmModule)) { return }
    $tenant = Get-SsmTenantInput; if (-not $tenant) { return }
    $ok = Show-ConfirmModal -Title 'Register delegated app' -Lines @(
        "Creates app 'SharePoint-Sharing-Manager' in $tenant for interactive sign-in.",
        'A browser window will open. A Global Admin must consent once.', '',
        'Note: delegated mode requires YOU to be Site Collection Admin on each',
        'target site/OneDrive. The app-only certificate mode (C) avoids that.')
    if (-not $ok) { return }
    try {
        $result = $null
        Invoke-OnMainBuffer {
            $script:RegResult = Register-PnPEntraIDAppForInteractiveLogin -ApplicationName 'SharePoint-Sharing-Manager' -Tenant $tenant -ErrorAction Stop
        }
        $result = $script:RegResult
        $appId = [string]($result.'AzureAppId/ClientId' ?? $result.AzureAppId ?? $result.ClientId)
        if (-not $appId) { throw 'No app id returned - check the console output.' }
        $script:Auth.AuthMode = 'Delegated'; $script:Auth.ClientId = $appId
        Save-SsmAuth
        Show-MsgModal -Title 'Registered' -Lines @("Client Id: $appId", 'Saved to config. Delegated mode is now active.')
    } catch {
        Write-SsmLog -Message ("Delegated app registration failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @($_.Exception.Message) -Kind Error
    }
}

function Register-SsmAppOnlyApp {
    # App-only certificate app via Register-PnPAzureADApp -ValidYears 1 with
    # application permissions Sites.FullControl.All (SharePoint + Graph).
    # Creating the app needs Application Administrator; ADMIN CONSENT for the
    # application permissions needs Global Admin / Privileged Role Admin - the
    # cmdlet opens the consent URL, which can be forwarded.
    if (-not (Install-SsmModule)) { return }
    $tenant = Get-SsmTenantInput; if (-not $tenant) { return }
    $ok = Show-ConfirmModal -Title 'Register app-only certificate app' -Lines @(
        "Creates app 'SharePoint-Sharing-Manager' in $tenant with APPLICATION",
        'permissions Sites.FullControl.All (SharePoint + Graph) and a self-signed',
        'certificate valid for 1 YEAR, uploaded to the app.', '',
        'Requires: Application Administrator (to create the app).',
        'Admin consent requires Global Admin - the consent URL will be shown',
        'and can be forwarded if that is someone else.')
    if (-not $ok) { return }
    try {
        $outDir = Join-Path $HOME '.sharepoint-sharing-manager-cert'
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
        Invoke-OnMainBuffer {
            $splat = @{
                ApplicationName                  = 'SharePoint-Sharing-Manager'
                Tenant                           = $tenant
                Interactive                      = $true
                ValidYears                       = 1
                SharePointApplicationPermissions = 'Sites.FullControl.All'
                GraphApplicationPermissions      = 'Sites.FullControl.All'
                OutPath                          = $outDir
            }
            if ($script:IsWin) { $splat.Store = 'CurrentUser' }
            $script:RegResult = Register-PnPAzureADApp @splat -ErrorAction Stop
        }
        $r = $script:RegResult
        $appId = [string]($r.'AzureAppId/ClientId' ?? $r.AzureAppId ?? $r.ClientId)
        $thumb = [string]($r.'Certificate Thumbprint' ?? $r.CertificateThumbprint ?? '')
        if (-not $appId) { throw 'No app id returned - check the console output.' }
        $script:Auth.AuthMode = 'AppOnly'
        $script:Auth.ClientId = $appId
        $script:Auth.Thumbprint = if ($script:IsWin) { $thumb } else { '' }
        $script:Auth.CertPath = if ($script:IsWin) { '' } else { (Join-Path $outDir 'SharePoint-Sharing-Manager.pfx') }
        $script:Auth.CertExpires = (Get-Date).AddYears(1).ToString('yyyy-MM-dd')
        Save-SsmAuth
        Show-MsgModal -Title 'Registered' -Lines @(
            "Client Id : $appId",
            ("Cert until: {0}" -f $script:Auth.CertExpires),
            'App-only mode is now active.', '',
            'If consent was not granted yet, a Global Admin must approve the',
            'consent URL printed in the console before connections will work.')
    } catch {
        Write-SsmLog -Message ("App-only registration failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @($_.Exception.Message) -Kind Error
    }
}

function Update-SsmCertificate {
    # Renew: generate a fresh 1-year self-signed cert and upload it to the
    # EXISTING app via Graph (addKey). Needs Application Administrator; no new
    # consent. Implementation: New-PnPAzureCertificate for the cert, then
    # Connect-PnPOnline with the OLD cert and Invoke-PnPGraphMethod POST
    # /applications(appId='<ClientId>')/addKey with the new public key.
    if ($script:Auth.AuthMode -ne 'AppOnly' -or -not $script:Auth.ClientId) {
        Show-MsgModal -Title 'Renew certificate' -Lines @('Only applies to app-only mode with a registered app.') -Kind Warn
        return
    }
    Show-MsgModal -Title 'Renew certificate' -Lines @(
        'Renewal steps (guided):',
        '1. A new 1-year self-signed certificate is generated locally.',
        '2. Sign in as Application Administrator when prompted.',
        '3. The new cert is added to the existing app; the old one keeps',
        '   working until its own expiry.', '',
        'Continue in the console...')
    try {
        $outDir = Join-Path $HOME '.sharepoint-sharing-manager-cert'
        $stamp = Get-Date -Format 'yyyyMMdd'
        Invoke-OnMainBuffer {
            $cert = New-PnPAzureCertificate -CommonName 'SharePoint-Sharing-Manager' -ValidYears 1 -OutPfx (Join-Path $outDir "renewed-$stamp.pfx") -OutCert (Join-Path $outDir "renewed-$stamp.cer")
            Write-Host 'New certificate generated. Uploading to the app registration...' -ForegroundColor Yellow
            Connect-PnPOnline -Url ("https://{0}" -f ($script:Auth.Tenant -replace '\.onmicrosoft\.com$', '.sharepoint.com')) -Interactive -ClientId $script:Auth.ClientId
            $keyCreds = @{ keyCredential = @{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = $cert.CertificateBase64Encoded } ; proof = $null }
            Invoke-PnPGraphMethod -Method Post -Url ("applications(appId='{0}')/addKey" -f $script:Auth.ClientId) -Content $keyCreds
            $script:RenewedCert = $cert
        }
        $script:Auth.CertExpires = (Get-Date).AddYears(1).ToString('yyyy-MM-dd')
        if ($script:IsWin -and $script:RenewedCert.Thumbprint) { $script:Auth.Thumbprint = $script:RenewedCert.Thumbprint }
        else { $script:Auth.CertPath = Join-Path $outDir "renewed-$stamp.pfx" }
        Save-SsmAuth
        Show-MsgModal -Title 'Renewed' -Lines @(("New certificate active until {0}." -f $script:Auth.CertExpires))
    } catch {
        Write-SsmLog -Message ("Certificate renewal failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @(
            $_.Exception.Message, '',
            'Fallback: run Register-PnPAzureADApp again (C) or add a certificate',
            'to the app manually in the Entra portal.') -Kind Error
    }
}

function Edit-SsmConfig {
    # Minimal field editor: prompt for each config field, empty keeps current.
    foreach ($field in @('AuthMode','ClientId','Tenant','AdminUrl','Thumbprint','CertPath','CertExpires')) {
        $v = Show-InputModal -Title "Config: $field" -Prompt 'Empty = keep current' -Default $script:Auth[$field]
        if ($null -ne $v -and $v -ne '') { $script:Auth[$field] = $v.Trim() }
    }
    Save-SsmAuth
    $script:UI.Dirty = $true
}

#endregion
```

**Verification note for the implementer:** `Register-PnPAzureADApp` / `Register-PnPEntraIDAppForInteractiveLogin` output property names and the exact `addKey` payload shape must be checked against the installed PnP.PowerShell version's docs (`Get-Help Register-PnPAzureADApp -Full`) during manual testing — the defensive `??` chains above are the safety net, not a guarantee. The `addKey` Graph call also requires a `proof` JWT signed with an existing cert; if `Invoke-PnPGraphMethod` cannot produce it, change `Update-SsmCertificate` to instead print exact portal instructions (Entra portal → App registrations → Certificates & secrets → Upload certificate, using the generated `.cer`) and still update the local config. That fallback is acceptable v1 behavior.

- [ ] **Step 2: Verify** — parse + analyzer + tests all clean.

- [ ] **Step 3: Commit**

```bash
git add src/60-setup-actions.ps1
git commit -m "feat: setup wizard - delegated app, app-only cert app, cert renewal"
```

---

### Task 13: Documentation (README, CONTRIBUTING, SECURITY, CHANGELOG)

**Files:**
- Create: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`

- [ ] **Step 1: Write `README.md`**

Mirror the Exchange-SOA-Manager README structure exactly (badges → one-line pitch → ASCII screenshot → TOC → Why → Features → Quick start → Requirements → Files the tool writes → Caveats → References → Contributing/Security/Credits/License). Content requirements:

- Badges: CI workflow badge (`mardahl/SharePoint-Sharing-Manager`), PowerShell 7.4+, platform Windows|macOS|Linux, MIT, PRs welcome.
- Pitch: "A portable PowerShell **terminal UI** that finds and revokes unwanted sharing across **SharePoint Online sites and OneDrives** - anonymous links, org-wide links, guest links, and direct grants to guests, 'Everyone' and 'Everyone except external users' (EEEU) - then locks the tenant down so it stays clean."
- ASCII screenshot block showing the OneDrives findings view (mimic the template's mock: title bar with connection dot, tab bar `1 Sites 2 OneDrives 3 Tenant 4 Setup 5 Log`, context row, 3-4 finding rows with categories, footer hints).
- Why: the delegated-auth pain (Site Collection Admin per OneDrive) and how app-only cert mode fixes it; table of the six rule categories with what is Pulled vs Left alone (adapt the header comments of the two source scripts).
- Quick start: download zip from Releases → `Launch-Sharing-Manager.bat`, or `pwsh ./SharePoint-Sharing-Manager.ps1`; first-run: Setup tab → `C` register app-only cert app (recommended) or `D` delegated.
- Requirements: PS 7.4+, PnP.PowerShell (on demand); roles table — create app: Application Administrator; consent app permissions: Global Admin / Privileged Role Admin; delegated mode: Site Collection Admin per target + SharePoint Admin for tenant tab.
- Keys table: content of `Get-TabHints` (Task 10).
- Files the tool writes: log, `SSM-Exports/` (BEFORE/REVOKED evidence + view exports), `~/.sharepoint-sharing-manager.json`, `~/.sharepoint-sharing-manager-cert/`.
- Caveats: the four "Known limitations" bullets from the spec, verbatim, plus "cleanup does not prevent new sharing - use the Tenant tab".
- Credits: "Grown out of two single-purpose hardening scripts; TUI framework shared with [Exchange-SOA-Manager](https://github.com/mardahl/Exchange-SOA-Manager)."

- [ ] **Step 2: Write `CONTRIBUTING.md` and `SECURITY.md`**

Copy from `$TPL`, rename tool/repo strings, drop 5.1-compat rules (floor is 7.4), keep: bootstrap + `src/` region file layout, safety-UX ground rules (typed confirmations for destructive ops), the scripted tmux TUI test recipe (retarget script name), PSScriptAnalyzer requirement. SECURITY.md: no telemetry; auth delegated to PnP.PowerShell/MSAL; logs and exports contain directory data; certificate PFX files live in `~/.sharepoint-sharing-manager-cert/` and must be protected; private vulnerability reporting via GitHub.

- [ ] **Step 3: Write `CHANGELOG.md`**

```markdown
# Changelog

## [1.0.0] - 2026-07-21

Initial release.

- Terminal UI with Sites, OneDrives, Tenant, Setup and Log tabs
- Shared scan engine: anonymous / org-wide / guest links, guest / EEEU / Everyone grants, toggleable per tab
- Per-finding multi-select revoke with typed confirmation and BEFORE/REVOKED CSV evidence
- Target discovery: tenant enumeration, manual URL, CSV import
- Delegated (interactive) and app-only certificate auth; guided app registration incl. 1-year cert
- Tenant sharing posture view and hardening setters
```

- [ ] **Step 4: Commit**

```bash
git add README.md CONTRIBUTING.md SECURITY.md CHANGELOG.md
git commit -m "docs: README, contributing, security policy, changelog"
```

---

### Task 14: Release workflow (single-file build)

**Files:**
- Create: `.github/workflows/release.yml`, `build/New-SingleFile.ps1`

**Interfaces:**
- Consumes: the `# ==== BEGIN SRC LOAD ====` / `# ==== END SRC LOAD ====` markers in the bootstrap (Task 2).
- Produces: `dist/SharePoint-Sharing-Manager.ps1` (single file), zipped with bat + README + LICENSE + CHANGELOG.

- [ ] **Step 1: Write `build/New-SingleFile.ps1`**

```powershell
#Requires -Version 7.4
# Builds the single-file release artifact: replaces the dot-source block in the
# bootstrap with the inlined contents of every src/*.ps1 (in name order).
param([string]$OutDir = 'dist')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$boot = Get-Content -LiteralPath (Join-Path $root 'SharePoint-Sharing-Manager.ps1') -Raw
$begin = '# ==== BEGIN SRC LOAD ===='
$end   = '# ==== END SRC LOAD ===='
$i = $boot.IndexOf($begin); $j = $boot.IndexOf($end)
if ($i -lt 0 -or $j -lt 0) { throw 'Concat markers not found in bootstrap.' }
$srcBody = (Get-ChildItem (Join-Path $root 'src/*.ps1') | Sort-Object Name | ForEach-Object {
    "# ---- inlined: $($_.Name) ----`n" + (Get-Content -LiteralPath $_.FullName -Raw)
}) -join "`n"
$single = $boot.Substring(0, $i) + $srcBody + $boot.Substring($j + $end.Length)
if (-not (Test-Path (Join-Path $root $OutDir))) { New-Item -ItemType Directory -Path (Join-Path $root $OutDir) | Out-Null }
$outFile = Join-Path $root "$OutDir/SharePoint-Sharing-Manager.ps1"
Set-Content -LiteralPath $outFile -Value $single -Encoding UTF8BOM
# Parse-verify the artifact
$errs = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($outFile, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) { $errs | ForEach-Object { Write-Host $_.Message }; throw 'Single-file artifact has parse errors.' }
Write-Host "Built and parse-verified: $outFile"
```

Also add `dist/` to `.gitignore`.

- [ ] **Step 2: Test the build locally**

Run: `pwsh ./build/New-SingleFile.ps1`
Expected: `Built and parse-verified: .../dist/SharePoint-Sharing-Manager.ps1`. Then `grep -c 'inlined:' dist/SharePoint-Sharing-Manager.ps1` = number of src files.

- [ ] **Step 3: Write `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags: ['v*.*.*']

permissions:
  contents: write

jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - name: Build single-file artifact
        shell: pwsh
        run: ./build/New-SingleFile.ps1

      - name: Build release zip
        run: |
          stage="SharePoint-Sharing-Manager-${GITHUB_REF_NAME}"
          mkdir "$stage"
          cp dist/SharePoint-Sharing-Manager.ps1 Launch-Sharing-Manager.bat README.md LICENSE CHANGELOG.md "$stage/"
          zip -r "${stage}.zip" "$stage"

      - name: Attach to release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          ver="${GITHUB_REF_NAME#v}"
          awk -v ver="$ver" '
            $0 ~ "^## \\[" ver "\\]" { flag=1; next }
            flag && /^## \[/ { exit }
            flag { print }
          ' CHANGELOG.md > notes.md
          gh release upload "$GITHUB_REF_NAME" SharePoint-Sharing-Manager-*.zip --clobber \
            || gh release create "$GITHUB_REF_NAME" SharePoint-Sharing-Manager-*.zip --notes-file notes.md
```

- [ ] **Step 4: Commit**

```bash
git add build/New-SingleFile.ps1 .github/workflows/release.yml .gitignore
git commit -m "ci: single-file release build and tag-triggered release workflow"
```

---

### Task 15: Manual TUI verification

**Files:**
- None created; this is a gate.

- [ ] **Step 1: Scripted TUI smoke test (tmux)**

```bash
tmux new-session -d -s ssm -x 120 -y 34 'pwsh ./SharePoint-Sharing-Manager.ps1'
sleep 3
tmux capture-pane -t ssm -p          # expect title bar, 5 tabs, footer hints
tmux send-keys -t ssm '2'; sleep 1
tmux capture-pane -t ssm -p          # expect OneDrives empty-state panel
tmux send-keys -t ssm '4'; sleep 1
tmux capture-pane -t ssm -p          # expect Setup panel with config fields
tmux send-keys -t ssm '5'; sleep 1
tmux capture-pane -t ssm -p          # expect log lines incl. startup banner
tmux send-keys -t ssm '?'; sleep 1
tmux capture-pane -t ssm -p          # expect help modal
tmux send-keys -t ssm Escape 'q'; sleep 1
tmux kill-session -t ssm 2>/dev/null || true
```

Each capture must show the expected screen; fix rendering/dispatch bugs before proceeding.

- [ ] **Step 2: Live-tenant checklist (operator-run, document results in the PR/commit message)**

1. Setup tab → `C` → app registered, cert uploaded, consent URL shown; config file written.
2. OneDrives tab → Enter → tenant enumeration lists personal sites.
3. Select one OneDrive → `S` → scan completes, BEFORE CSV in `SSM-Exports/`.
4. Enter → findings view → select one finding → `R` → typed REVOKE → removed, REVOKED CSV written.
5. Re-scan the same OneDrive → previously removed finding no longer reported.
6. Tenant tab → Enter → posture shown. (Do NOT change settings on a production tenant.)

- [ ] **Step 3: Commit any fixes**

```bash
git add -A && git commit -m "fix: TUI issues found in manual verification"
```

---

### Task 16: Publish to GitHub

**Files:**
- Move: `Revoke-OneDrive-NonMemberAccess.ps1`, `Revoke-OrgWideSharingLinks.ps1` → `docs/legacy/`

- [ ] **Step 1: Move legacy scripts and final check**

```bash
mkdir -p docs/legacy
git mv Revoke-OneDrive-NonMemberAccess.ps1 Revoke-OrgWideSharingLinks.ps1 docs/legacy/
pwsh ./tests/run-tests.ps1
pwsh ./build/New-SingleFile.ps1
pwsh -c 'Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error,Warning'
git commit -m "chore: move original scripts to docs/legacy"
```

All three commands must pass clean.

- [ ] **Step 2: Create the repo and push (requires user confirmation)**

```bash
git branch -M main
gh repo create mardahl/SharePoint-Sharing-Manager --public \
  --description "Terminal UI that finds and revokes unwanted SharePoint Online and OneDrive sharing - anonymous, org-wide and guest links, EEEU/Everyone grants - with app-only certificate auth. Single-file PowerShell, PS 7.4+." \
  --source . --push
gh repo edit mardahl/SharePoint-Sharing-Manager --add-topic powershell --add-topic tui --add-topic sharepoint-online --add-topic onedrive --add-topic pnp-powershell --add-topic security-hardening --add-topic terminal-ui
```

- [ ] **Step 3: Verify CI, then tag v1.0.0**

```bash
gh run watch --repo mardahl/SharePoint-Sharing-Manager   # CI green first
git tag v1.0.0 && git push origin v1.0.0
gh run watch --repo mardahl/SharePoint-Sharing-Manager   # release job
gh release view v1.0.0 --repo mardahl/SharePoint-Sharing-Manager
```

Expected: release `v1.0.0` with `SharePoint-Sharing-Manager-v1.0.0.zip` attached.
