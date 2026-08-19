# Setup Tab Tenant Management + Sharing Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make multi-tenant management discoverable: Setup tab shows a cursor-navigated tenant list with a per-tenant action modal, and the "Tenant" tab is renamed "Sharing".

**Architecture:** Reuses existing tenant CRUD/switch/remove helpers in `25-config.ps1` and the registration/cert/config flows in `60-setup-actions.ps1`. Auth-mutating actions on a non-active tenant call `Switch-SsmTenant` first (single-auth-globals model). Internal tab `Kind='Tenant'` is unchanged — only display names and user-facing copy change.

**Tech Stack:** PowerShell 7.4+, single-file TUI sourced from `src/*.ps1`; tests via the assert-based harness `tests/run-tests.ps1` (dot-sources pure-logic src files).

**Spec:** `docs/superpowers/specs/2026-08-19-setup-tab-tenants-design.md`

## Global Constraints

- Never touch PnP cmdlets in view/key code paths — those live behind existing `Register-*`/`Update-*` flows and are stubbed in tests.
- `Kind='Tenant'` must NOT be renamed — `switch ($tab['Kind'])` dispatch depends on it.
- Keep `Show-HelpModal` in sync with `Get-TabHints` (comment at `src/20-modals.ps1:581` demands it).
- Tests run: `pwsh -NoProfile -File tests/run-tests.ps1` (from repo root).
- Test files needing temp state use `$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssm-test-" + [guid]::NewGuid().ToString('n'))` and `Remove-Item -Recurse -Force $script:TestRoot` in a `finally`.
- The Setup tab entry gains `Cursor = 0` — every test fixture that builds a fake `Kind='Setup'` tab must include it.

---

### Task 1: Rename tab "Tenant" → "Sharing"

**Files:**
- Modify: `src/00-globals.ps1:97` (tab definition)
- Test: `tests/tenant-actions.tests.ps1`

**Interfaces:**
- Consumes: existing `$script:Tabs` array, `Add-TabBar` in `65-views.ps1` (renders `$tab.Name`).
- Produces: tab display name `'Sharing'`; `Kind='Tenant'` unchanged.

- [ ] **Step 1: Write the failing test**

Append to `tests/tenant-actions.tests.ps1`:

```powershell
Invoke-SsmTest 'Tab 3 is named Sharing (Tenant rename)' {
    . (Join-Path $PSScriptRoot '..' 'src' '00-globals.ps1')
    Assert-Equal 'Sharing' $script:Tabs[2].Name
    Assert-Equal 'Tenant' $script:Tabs[2].Kind   # Kind must NOT change
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: FAIL with `expected [Sharing] got [Tenant]`

- [ ] **Step 3: Implement**

In `src/00-globals.ps1:97` change:

```powershell
    @{ Kind = 'Tenant'; Name = 'Sharing'; Loaded = $false; Posture = $null; Cursor = 0 },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: PASS (all tests, no regressions)

- [ ] **Step 5: Commit**

```bash
git add src/00-globals.ps1 tests/tenant-actions.tests.ps1
git commit -m "feat: rename Tenant tab to Sharing"
```

---

### Task 2: Setup tab tenant list view

**Files:**
- Modify: `src/00-globals.ps1:98` (Setup tab gains `Cursor = 0`)
- Modify: `src/65-views.ps1:549-597` (`Add-SetupView` rewrite), `src/65-views.ps1:672` (Setup hints)
- Test: `tests/setup-view.tests.ps1` (new)

**Interfaces:**
- Consumes: `Get-SsmTenantNames` (`25-config.ps1:172`), `Get-SsmConfig` (`25-config.ps1:27`), `Test-SsmAuthReady` (`25-config.ps1:73`, reads `$script:Auth` — do NOT call it per tenant; use the entry-shape helper below), `Add-FrameLine` (`15-drawing.ps1:19`), theme `$script:T` keys `Ctx`, `Muted`, `Row`, `CtxHi`, `CursorBg`, `CursorFg`, `Ok`, `Warn`.
- Produces: `$script:Tabs[3]['Cursor']` (Setup cursor, int); Setup view renders one row per tenant: `<name> [active][,default]]  <AuthMode|->  configured|not configured`; hints `Up/Dn move / Enter actions / A add tenant / T switch / 1-6 tab / ? help / Q quit`.

Note on completeness check: `Test-SsmAuthReady` reads the global `$script:Auth`, not a config entry. Add a pure helper to `25-config.ps1`:

```powershell
function Test-SsmTenantConfigured {
    # Pure: is a Tenants-map entry complete enough to connect with?
    param([hashtable]$Entry)
    if (-not $Entry.ClientId) { return $false }
    if ($Entry.AuthMode -eq 'AppOnly') {
        if (-not $Entry.Tenant) { return $false }
        if (-not ($Entry.Thumbprint -or $Entry.CertPath)) { return $false }
    }
    return $true
}
```

- [ ] **Step 1: Write the failing test**

Create `tests/setup-view.tests.ps1`:

```powershell
# View test: capture Add-SetupView output by stubbing Add-FrameLine.
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssm-test-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
$script:ConfigPath = Join-Path $script:TestRoot 'config.json'
@{
    Version = 2; DefaultTenant = 'contoso'
    Tenants = @{
        contoso = @{ AuthMode = 'AppOnly'; ClientId = 'abc'; Tenant = 'contoso.onmicrosoft.com'; AdminUrl = 'https://contoso-admin.sharepoint.com'; Thumbprint = 'THUMB'; CertPath = ''; CertExpires = '2027-01-01' }
        empty   = @{ AuthMode = ''; ClientId = ''; Tenant = ''; AdminUrl = ''; Thumbprint = ''; CertPath = ''; CertExpires = '' }
    }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8

$script:TenantName = 'contoso'
$script:T = @{ Ctx=''; Muted=''; Row=''; CtxHi=''; CursorBg=''; CursorFg=''; Ok=''; Warn='' }

function Capture-SetupView {
    $script:Captured = @{}
    $sb = New-Object System.Text.StringBuilder
    Add-SetupView -Sb $sb -W 100 -H 30
    return ($script:Captured.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Value }) -join "`n"
}

Invoke-SsmTest 'Test-SsmTenantConfigured: complete app-only entry passes' {
    $e = @{ AuthMode='AppOnly'; ClientId='x'; Tenant='t.onmicrosoft.com'; Thumbprint='th'; CertPath='' }
    Assert-Equal 'True' (Test-SsmTenantConfigured -Entry $e)
}

Invoke-SsmTest 'Test-SsmTenantConfigured: empty entry fails' {
    $e = @{ AuthMode=''; ClientId=''; Tenant=''; Thumbprint=''; CertPath='' }
    Assert-Equal 'False' (Test-SsmTenantConfigured -Entry $e)
}

Invoke-SsmTest 'Setup view lists tenants with active/default/configured markers' {
    $script:Tabs = @(@{ Kind='Targets' }, @{ Kind='Targets' }, @{ Kind='Tenant' }, @{ Kind='Setup'; Cursor=0 })
    $out = Capture-SetupView
    if ($out -notmatch 'contoso \[active,default\] +AppOnly +configured') { throw "missing contoso row: $out" }
    if ($out -notmatch 'empty .*not configured') { throw "missing empty row: $out" }
}

Invoke-SsmTest 'Setup view cursor clamps past end of list' {
    $script:Tabs = @(@{ Kind='Targets' }, @{ Kind='Targets' }, @{ Kind='Tenant' }, @{ Kind='Setup'; Cursor=99 })
    $null = Capture-SetupView
    Assert-Equal 1 $script:Tabs[3]['Cursor']
}

Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
```

Stub `Add-FrameLine` near the top of the file (before `Capture-SetupView`), after the theme setup:

```powershell
function Add-FrameLine { param($Sb, [int]$Row, [string]$Content) $script:Captured[$Row] = $Content }
```

Also: `Add-SetupView` references `Get-CertDaysLeft`, `Get-PadCell`, `Get-Module` — `Get-PadCell` comes from dot-sourced `15-drawing`-era code; check it is available in the harness (it is in `65-views.ps1` or `15-drawing.ps1`). If `15-drawing.ps1` is not dot-sourced by `tests/run-tests.ps1`, add it to the list at `tests/run-tests.ps1:15` (`'15-drawing'` before `'20-modals'`). The new Setup view must not call `Get-CertDaysLeft` or `Get-Module` (cert detail lines for the active tenant are dropped — the action modal's Edit config flow covers cert info; keep the view dumb). If `Get-CertDaysLeft`/`Get-Module` calls remain, stub them in this test file:

```powershell
function Get-CertDaysLeft { $null }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: FAIL — `Test-SsmTenantConfigured` not defined; view shows old auth-field layout (no `contoso [active,default]` row).

- [ ] **Step 3: Implement**

3a. `src/00-globals.ps1:98` — add Cursor:

```powershell
    @{ Kind = 'Setup';  Name = 'Setup'; Cursor = 0 },
```

3b. `src/25-config.ps1` — add `Test-SsmTenantConfigured` (code block above) right after `Test-SsmAuthReady` (line 80).

3c. `src/65-views.ps1` — replace `Add-SetupView` (lines 549-597) with:

```powershell
function Add-SetupView {
    param([System.Text.StringBuilder]$Sb, [int]$W, [int]$H)
    $t = $script:T
    Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + ' Tenants')
    for ($r = 4; $r -le ($H - 1); $r++) { Add-FrameLine -Sb $Sb -Row $r -Content '' }

    $tab = $script:Tabs[$script:UI.Tab]
    $names = @(Get-SsmTenantNames)
    if ($names.Count -eq 0) { $tab['Cursor'] = 0 }
    elseif ($tab['Cursor'] -ge $names.Count) { $tab['Cursor'] = $names.Count - 1 }
    if ($tab['Cursor'] -lt 0) { $tab['Cursor'] = 0 }
    $c = Get-SsmConfig

    $margin = 4; $pad = ' ' * $margin; $row = 5
    if ($names.Count -eq 0) {
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'No tenants configured. Press A to add one.'); $row += 2
    }
    for ($i = 0; $i -lt $names.Count -and $row -le ($H - 6); $i++) {
        $n = $names[$i]
        $e = $c.Tenants[$n]
        $tags = @()
        if ($n -eq $script:TenantName)   { $tags += 'active' }
        if ($n -eq $c.DefaultTenant)     { $tags += 'default' }
        $tagText = if ($tags) { ' [' + ($tags -join ',') + ']' } else { '' }
        $mode = if ($e.AuthMode) { $e.AuthMode } else { '-' }
        $state = if (Test-SsmTenantConfigured -Entry $e) { 'configured' } else { 'not configured' }
        $line = $pad + $n + $tagText + '  ' + $mode + '  ' + $state
        if ($i -eq $tab['Cursor']) { $line = $t.CursorFg + $line + $t.Reset }
        Add-FrameLine -Sb $Sb -Row $row -Content $line; $row++
    }
    $row++

    $valueW = [Math]::Max(20, $W - $margin - 14)
    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'Config file : ' + $t.Row + (Get-PadCell $script:ConfigPath $valueW)); $row += 2

    $legend = @(
        'Enter  actions for the highlighted tenant',
        'A      add a tenant',
        'T      quick-switch tenant (works on most tabs)'
    )
    foreach ($ln in $legend) {
        if ($row -gt ($H - 1)) { break }
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Row + $ln); $row++
    }
}
```

(`$t.Reset` exists in the theme at `00-globals.ps1` — verify with `grep -n "Reset" src/00-globals.ps1`; if the key is named differently, use that name.)

3d. `src/65-views.ps1:672` — Setup hints:

```powershell
        'Setup'  { return @(@('Up/Dn','move'),@('Enter','actions'),@('A','add tenant'),@('T','switch'),@('1-6','tab'),@('?','help'),@('Q','quit')) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: PASS — 4 new tests green, no regressions.

- [ ] **Step 5: Commit**

```bash
git add src/00-globals.ps1 src/25-config.ps1 src/65-views.ps1 tests/setup-view.tests.ps1 tests/run-tests.ps1
git commit -m "feat: Setup tab renders tenant list with status markers"
```

---

### Task 3: Setup keys — cursor, Enter action modal, A add

**Files:**
- Modify: `src/75-key-dispatch.ps1:254-276` (rewrite `Invoke-SetupKey`, delete `Invoke-SetupAction`)
- Modify: `src/60-setup-actions.ps1` (new `Show-TenantActionsModal` + `Invoke-AddTenantFlow`; delete `Show-TenantListModal`)
- Test: `tests/setup-keys.tests.ps1` (new)

**Interfaces:**
- Consumes: `Get-SsmTenantNames`, `Switch-SsmTenant` (`25-config.ps1:223`), `Set-SsmDefaultTenant` (`25-config.ps1:206`), `Add-SsmTenant` (`25-config.ps1:178`), `Edit-SsmConfig`/`Register-SsmDelegatedApp`/`Register-SsmAppOnlyApp`/`Update-SsmCertificate` (`60-setup-actions.ps1`), `Invoke-RemoveTenantFlow` (`60-setup-actions.ps1:169`), `Show-ListModal`/`Show-InputModal`/`Show-MsgModal` (`20-modals.ps1`).
- Produces:
  - `Invoke-SetupKey -K <ConsoleKeyInfo>` — Up/Down move `$script:Tabs[3]['Cursor']` clamped to `Get-SsmTenantNames` count; Enter calls `Show-TenantActionsModal -Name <name>` (no-op when list empty); `A` calls `Invoke-AddTenantFlow`.
  - `Show-TenantActionsModal -Name <string>` — options: `Switch to this tenant` (omitted when active), `Edit config`, `Register delegated app`, `Register cert app`, `Renew certificate`, `Set as default`, `Remove tenant`, `Cancel`. Auth actions (Edit/Register/Renew) call `Switch-SsmTenant -Name $Name` first when `$Name -ne $script:TenantName`.
  - `Invoke-AddTenantFlow` — prompt name, `Add-SsmTenant`, result modal (logic lifted verbatim from `Show-TenantListModal` lines 221-229).

- [ ] **Step 1: Write the failing test**

Create `tests/setup-keys.tests.ps1`:

```powershell
# Key-dispatch tests for the redesigned Setup tab. All modals/actions stubbed.
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssm-test-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
$script:ConfigPath = Join-Path $script:TestRoot 'config.json'
@{
    Version = 2; DefaultTenant = 'a'
    Tenants = @{
        a = @{ AuthMode='Delegated'; ClientId='id-a'; Tenant='a.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
        b = @{ AuthMode=''; ClientId=''; Tenant=''; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
    }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8

$script:Calls = @()
function Show-MsgModal    { param($Title, $Lines, $Kind) }
function Show-ListModal   { param($Title, $Prompt, $Options) $script:Calls += "list:$Title"; $script:NextPick }
function Show-InputModal  { param($Title, $Prompt, $Default) $script:NextInput }
function Switch-SsmTenant { param([string]$Name) $script:Calls += "switch:$Name"; $script:TenantName = $Name; $true }
function Edit-SsmConfig   { $script:Calls += 'edit' }
function Register-SsmDelegatedApp { $script:Calls += 'regdel' }
function Register-SsmAppOnlyApp   { $script:Calls += 'regcert' }
function Update-SsmCertificate    { $script:Calls += 'renew' }
function Set-SsmDefaultTenant     { param([string]$Name) $script:Calls += "default:$Name"; $true }
function Invoke-RemoveTenantFlow  { param([string]$Name) $script:Calls += "remove:$Name" }
function Disconnect-SsmConnection { }

function Reset-SetupUi {
    $script:UI = @{ Tab = 3; SearchMode = $false; Dirty = $false; Quit = $false }
    $script:Tabs = @(
        @{ Kind='Targets' }, @{ Kind='Targets' }, @{ Kind='Tenant' },
        @{ Kind='Setup'; Cursor = 0 }, @{ Kind='Log' }, @{ Kind='About' }
    )
    $script:TenantName = 'a'
    $script:Calls = @()
    $script:NextPick = $null
    $script:NextInput = $null
}

function Key([string]$Char) { [System.ConsoleKeyInfo]::new($Char, [Enum]::Parse([System.ConsoleKey], ('D' + $Char.ToUpper())), $false, $false, $false) }
function Arrow([System.ConsoleKey]$K) { [System.ConsoleKeyInfo]::new([char]0, $K, $false, $false, $false) }

Invoke-SsmTest 'Down arrow moves Setup cursor, clamps at last tenant' {
    Reset-SetupUi
    Invoke-SetupKey -K (Arrow DownArrow)
    Assert-Equal 1 $script:Tabs[3]['Cursor']
    Invoke-SetupKey -K (Arrow DownArrow)
    Assert-Equal 1 $script:Tabs[3]['Cursor']   # clamped
}

Invoke-SsmTest 'Up arrow clamps at zero' {
    Reset-SetupUi
    Invoke-SetupKey -K (Arrow UpArrow)
    Assert-Equal 0 $script:Tabs[3]['Cursor']
}

Invoke-SsmTest 'Enter on tenant opens the action modal with its name' {
    Reset-SetupUi
    $script:Tabs[3]['Cursor'] = 1
    Invoke-SetupKey -K (Key "`r")
    Assert-Equal 'list:b' $script:Calls[0]
}

Invoke-SsmTest 'Action modal: edit config on non-active tenant switches first' {
    Reset-SetupUi
    $script:NextPick = 'Edit config'
    Show-TenantActionsModal -Name 'b'
    Assert-Equal 'switch:b' $script:Calls[0]
    Assert-Equal 'edit' $script:Calls[1]
}

Invoke-SsmTest 'Action modal: switch option hidden for active tenant' {
    Reset-SetupUi
    $script:SeenOptions = $null
    $script:NextPick = 'Cancel'
    Show-TenantActionsModal -Name 'a'
    Assert-Equal $null ($script:SeenOptions | Where-Object { $_ -like 'Switch*' })
}

Invoke-SsmTest 'Action modal: remove routes to Invoke-RemoveTenantFlow' {
    Reset-SetupUi
    $script:NextPick = 'Remove tenant'
    Show-TenantActionsModal -Name 'b'
    Assert-Equal 'remove:b' $script:Calls[0]
}

Invoke-SsmTest 'A key runs add-tenant flow' {
    Reset-SetupUi
    $script:NextInput = 'newco'
    Invoke-SetupKey -K (Key 'a')
    $c = Get-SsmConfig
    Assert-Equal 'True' $c.Tenants.ContainsKey('newco')
}

Invoke-SsmTest 'Old flat keys D/C/W/X/L no longer fire on Setup' {
    Reset-SetupUi
    foreach ($ch in @('d','c','w','x','l')) { Invoke-SetupKey -K (Key $ch) }
    Assert-Equal 0 $script:Calls.Count
}

Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
```

For the "switch option hidden" test, capture options in the `Show-ListModal` stub: replace that stub line with:

```powershell
function Show-ListModal   { param($Title, $Prompt, $Options) $script:Calls += "list:$Title"; $script:SeenOptions = $Options; $script:NextPick }
```

Note: `Key "`r"` — Enter as a ConsoleKeyInfo. If `Invoke-SetupKey` matches on `$K.Key -eq 'Enter'` instead, use `Arrow Enter`-style construction: `[System.ConsoleKeyInfo]::new("`r", [System.ConsoleKey]::Enter, $false,$false,$false)`. Implement to match whichever the code uses; the code must handle `$K.Key -eq 'Enter'`.

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: FAIL — `Show-TenantActionsModal` not defined; Down/Enter/A do nothing (old `Invoke-SetupKey` only handles D/C/W/X/L letters).

- [ ] **Step 3: Implement**

3a. `src/60-setup-actions.ps1` — replace `Show-TenantListModal` (lines 207-243) with:

```powershell
function Invoke-AddTenantFlow {
    $name = Show-InputModal -Title 'Add tenant' -Prompt 'Tenant display name (e.g. contoso):'
    if (-not $name) { return }
    if (Add-SsmTenant -Name $name.Trim()) {
        Show-MsgModal -Title 'Added' -Lines @(("Tenant '{0}' added." -f $name.Trim()), 'Press Enter on it to configure auth.')
    } else {
        Show-MsgModal -Title 'Add failed' -Lines @('Name already exists or would share a cache directory with another tenant.') -Kind Warn
    }
}

function Show-TenantActionsModal {
    param([Parameter(Mandatory)][string]$Name)
    $options = @()
    if ($Name -ne $script:TenantName) { $options += 'Switch to this tenant' }
    $options += @('Edit config', 'Register delegated app', 'Register cert app',
                  'Renew certificate', 'Set as default', 'Remove tenant', 'Cancel')
    $pick = Show-ListModal -Title $Name -Prompt 'Action:' -Options $options
    if (-not $pick -or $pick -eq 'Cancel') { return }

    $needsAuth = @('Edit config', 'Register delegated app', 'Register cert app', 'Renew certificate')
    if ($needsAuth -contains $pick -and $Name -ne $script:TenantName) {
        if ($script:Conn.Url) { Disconnect-SsmConnection }
        if (-not (Switch-SsmTenant -Name $Name)) { return }
    }
    switch ($pick) {
        'Switch to this tenant'   { if ($script:Conn.Url) { Disconnect-SsmConnection }; [void](Switch-SsmTenant -Name $Name) }
        'Edit config'             { Edit-SsmConfig }
        'Register delegated app'  { Register-SsmDelegatedApp }
        'Register cert app'       { Register-SsmAppOnlyApp }
        'Renew certificate'       { Update-SsmCertificate }
        'Set as default'          { if (Set-SsmDefaultTenant -Name $Name) { Show-MsgModal -Title 'Default' -Lines @(("'{0}' is now the startup tenant." -f $Name)) } }
        'Remove tenant'           { Invoke-RemoveTenantFlow -Name $Name }
    }
    $script:UI.Dirty = $true
}
```

3b. `src/75-key-dispatch.ps1` — replace `Invoke-SetupAction` + `Invoke-SetupKey` (lines 254-276) with:

```powershell
function Invoke-SetupKey {
    param([System.ConsoleKeyInfo]$K)
    $tab = $script:Tabs[$script:UI.Tab]
    $names = @(Get-SsmTenantNames)
    switch ($K.Key) {
        'UpArrow'   { if ($tab['Cursor'] -gt 0) { $tab['Cursor']-- }; return }
        'DownArrow' { if ($tab['Cursor'] -lt ($names.Count - 1)) { $tab['Cursor']++ }; return }
        'Enter'     { if ($names.Count -gt 0) { Show-TenantActionsModal -Name $names[$tab['Cursor']] }; return }
    }
    if ([char]::ToUpper($K.KeyChar) -eq 'A') { Invoke-AddTenantFlow; return }
}
```

Check `$script:Conn` shape (`00-globals.ps1:66`-ish: `Url`, `Admin`, `Account`) — used above to decide disconnect-before-switch. `Disconnect-SsmConnection` lives in `30-connections.ps1` (dot-sourced in tests; stubbed in the test file to avoid touching real state).

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: PASS — 9 new tests green, no regressions.

- [ ] **Step 5: Commit**

```bash
git add src/60-setup-actions.ps1 src/75-key-dispatch.ps1 tests/setup-keys.tests.ps1
git commit -m "feat: Setup tab cursor nav + per-tenant action modal"
```

---

### Task 4: Hints and help modal sync

**Files:**
- Modify: `src/65-views.ps1:671,673-674` (Tenant/Log/About hints gain `T switch`/`T tenants`)
- Modify: `src/20-modals.ps1:609-616` (help: rename "Tenant tab" section, rewrite Setup section, add Tenants section)
- Test: `tests/help.tests.ps1` (new)

**Interfaces:**
- Consumes: `Show-HelpModal` (`20-modals.ps1:580`), `Get-TabHints` (`65-views.ps1:656`).
- Produces: help text containing 'Sharing tab' section, a 'Tenants' section documenting T switcher + Setup management; Setup hints already done in Task 2 — here only Sharing/Log/About hints.

- [ ] **Step 1: Write the failing test**

Create `tests/help.tests.ps1`:

```powershell
$script:T = @{ ModalTitle=''; Row=''; CtxHi=''; Muted='' }
$script:LogFile = 'x.log'; $script:ExportDir = 'x'
$script:Version = '9.9.9'
$script:CapturedHelp = ''
function Show-ReportModal { param($Title, $Lines) $script:CapturedHelp = ($Lines | ForEach-Object { $_[1] }) -join "`n" }

Invoke-SsmTest 'Help modal documents Sharing tab and tenant management' {
    Show-HelpModal
    if ($script:CapturedHelp -notmatch 'Sharing tab') { throw 'no Sharing section' }
    if ($script:CapturedHelp -match 'Tenant tab') { throw 'stale Tenant section' }
    if ($script:CapturedHelp -notmatch 'Tenants') { throw 'no Tenants section' }
    if ($script:CapturedHelp -notmatch 'quick-switch') { throw 'T switcher undocumented' }
    if ($script:CapturedHelp -notmatch 'Enter\s+actions for the highlighted tenant') { throw 'Setup Enter undocumented' }
}

Invoke-SsmTest 'Non-Targets tab hints advertise the T switcher' {
    foreach ($kind in @('Tenant','Log','About')) {
        $hints = Get-TabHints -Tab @{ Kind = $kind }
        $joined = ($hints | ForEach-Object { $_[0] + ':' + $_[1] }) -join ' '
        if ($joined -notmatch 'T:switch') { throw "$kind hints missing T switch: $joined" }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: FAIL — help says "Tenant tab", no Tenants section; hints lack T.

- [ ] **Step 3: Implement**

3a. `src/20-modals.ps1:609-616` — replace the 'Tenant tab' and 'Setup tab' help blocks:

```powershell
        @($t.ModalTitle, 'Sharing tab'),
        @($t.Row, '  Up / Down            move between sharing settings'),
        @($t.Row, '  Enter                load posture, or change the highlighted setting'),
        @($t.Row, '  R                    refresh the sharing posture'),
        @($t.Row, ''),
        @($t.ModalTitle, 'Tenants'),
        @($t.Row, '  T                    quick-switch tenant (all tabs except Sites/OneDrives)'),
        @($t.Row, '  Setup tab            manage tenants: add, configure, set default, remove'),
        @($t.Row, ''),
        @($t.ModalTitle, 'Setup tab'),
        @($t.Row, '  Up / Down            move between tenants'),
        @($t.Row, '  Enter                actions for the highlighted tenant'),
        @($t.Row, '  A                    add a tenant'),
```

3b. `src/65-views.ps1` — update three hint branches (lines 671-674):

```powershell
        'Tenant' { return @(@('Up/Dn','move'),@('Enter','load/change'),@('R','refresh'),@('T','switch'),@('1-6','tab'),@('?','help'),@('Q','quit')) }
        'Setup'  { return @(@('Up/Dn','move'),@('Enter','actions'),@('A','add tenant'),@('T','switch'),@('1-6','tab'),@('?','help'),@('Q','quit')) }
        'Log'    { return @(@('Up/Dn','scroll'),@('O','open log file'),@('T','switch'),@('?','help'),@('Q','quit')) }
        'About'  { return @(@('G','github'),@('R','releases'),@('T','switch'),@('?','help'),@('Q','quit')) }
```

(Setup line already shipped in Task 2 — include here only if Task 2's version differs; otherwise leave it.)

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/run-tests.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/20-modals.ps1 src/65-views.ps1 tests/help.tests.ps1
git commit -m "feat: help + footer hints document tenant management"
```

---

### Task 5: Docs, version bump, release

**Files:**
- Modify: `CHANGELOG.md`, `README.md` (keys/setup sections), `src/00-globals.ps1:5` (version)
- Modify: `AGENTS.md` if it documents tab names or Setup keys (check with `grep -n "Tenant\|Setup" AGENTS.md`)

- [ ] **Step 1: Verify no stale references**

Run: `grep -rn "Tenant tab" src/ README.md CHANGELOG.md AGENTS.md`
Expected: only CHANGELOG history entries (leave those); fix any live references to say "Sharing tab".

Also: `grep -n "Show-TenantListModal\|Invoke-SetupAction" src/ tests/` — expected: zero hits (both deleted in Task 3).

- [ ] **Step 2: Update docs**

`CHANGELOG.md` — new section at top:

```markdown
## [1.5.0] - 2026-08-19

- Change: Setup tab is now the tenant management hub: lists all tenants with
  active/default/configured markers; Enter opens per-tenant actions (switch,
  edit config, register apps, renew cert, set default, remove); A adds a tenant.
- Change: "Tenant" tab renamed to "Sharing" to avoid confusion with tenant
  management. Internal behavior unchanged.
- Change: removed flat D/C/W/X/L keys on Setup (absorbed into the per-tenant
  action modal). T quick-switcher unchanged.
- Fix: tenant switcher (T) now advertised in footer hints and help.
```

`README.md` — update the keys/setup section: replace D/C/W/X/L-on-Setup description with Enter/A/T model; rename "Tenant tab" to "Sharing tab". Keep it minimal — mirror the help-modal wording.

- [ ] **Step 3: Bump version**

`src/00-globals.ps1:5`: `$script:Version = '1.5.0'`

- [ ] **Step 4: Full test run + rebuild dist**

Run: `pwsh -NoProfile -File tests/run-tests.ps1` — all green.
Run: `pwsh -NoProfile -File build/New-SingleFile.ps1` (check its usage first: `Get-Content build/New-SingleFile.ps1 -TotalCount 30`) — regenerates `dist/SharePoint-Sharing-Manager.ps1`.
Verify: `grep -n "script:Version = '1.5.0'" dist/SharePoint-Sharing-Manager.ps1`.

- [ ] **Step 5: Commit and tag**

```bash
git add -A
git commit -m "release: 1.5.0 - Setup tab tenant management hub + Sharing rename"
git tag v1.5.0
```
