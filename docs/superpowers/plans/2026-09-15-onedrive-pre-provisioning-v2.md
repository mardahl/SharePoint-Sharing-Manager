# OneDrive Pre-Provisioning v2 (Selectable Rows) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unprovisioned OneDrive users appear as selectable rows under a new `Unprovisioned` filter on the OneDrives tab; `P` loads them when absent and provisions only the selected rows when present.

**Architecture:** Placeholder target rows (`Status = 'Unprovisioned'` / `'ProvisionRequested'`, extra `Upn` key, predicted personal URL) live in `$Tab['Items']` alongside real OneDrives. `Update-TabView` hides them from every filter except `Unprovisioned`. `Invoke-SsmOneDriveProvision` becomes context-aware (load / provision selection / nothing-selected message). Placeholders are excluded from scan, admin actions and the session cache.

**Tech Stack:** PowerShell 7.4+, PnP.PowerShell, assert-based tests (`tests/run-tests.ps1`).

Spec: `docs/superpowers/specs/2026-09-15-onedrive-pre-provisioning-v2-design.md`.

## Global Constraints

- PowerShell 7.4+, `Set-StrictMode -Version 2.0` safe. Target items are hashtables; read optional keys with `$t.ContainsKey('Upn')`.
- PnP.PowerShell only external dependency.
- Mutating action requires `Show-TypedConfirmModal` word `PROVISION`.
- Placeholder rows never appear under filter `All`; only under `Unprovisioned`.
- Sites tab `F` cycle unchanged: `All,NotScanned,Clean,Findings,Failed`. OneDrives tab: `All,NotScanned,Clean,Findings,Failed,Unprovisioned`.
- Badge: `Unprovisioned` → `$script:T.Attention` (`ESC[1;38;5;208m`), glyph `$script:G.Bang` (`!` in both glyph tables), text `Unprovisioned`. `ProvisionRequested` → `$script:T.Cloud`, `$script:G.Half`, text `Requested`.
- Predicted URL: `https://<tenant>-my.sharepoint.com/personal/<slug>`, `<tenant>` from `$script:Auth.AdminUrl` (`https://<tenant>-admin.sharepoint.com`), `<slug>` = `ConvertTo-SsmPersonalSlug -Upn`.
- Logging `Write-SsmLog -Message -Level`; errors `Write-SsmErrorLog -Context -ErrorRecord`.
- Tests: `pwsh -NoProfile -File ./tests/run-tests.ps1` green; lint `Invoke-ScriptAnalyzer -Path ./SharePoint-Sharing-Manager.ps1, ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error, Warning` clean.
- Test runner does not load `src/00-globals.ps1`; tests touching `$script:T`/`$script:G` must set and restore them.
- Wiki sync rule: user-facing change updates `wiki/*.md` + `CHANGELOG.md` Unreleased.
- Text in files self-contained (no chat references).

---

### Task 1: Placeholder predicate, theme/glyph keys, badge

**Files:**
- Modify: `src/47-onedrive-provision.ps1` (append before `#endregion`)
- Modify: `src/00-globals.ps1` (glyph tables ~lines 106-124, theme ~line 145)
- Modify: `src/15-drawing.ps1:27-43` (`Get-StatusBadge`)
- Test: `tests/onedrive-provision.tests.ps1` (append)

**Interfaces:**
- Produces: `Test-SsmPlaceholderTarget -Target [hashtable] -> [bool]` (true for Status `Unprovisioned` or `ProvisionRequested`). `$script:G.Bang`, `$script:T.Attention`.

- [ ] **Step 1: Failing tests** — append to `tests/onedrive-provision.tests.ps1`:

```powershell
Invoke-SsmTest 'Test-SsmPlaceholderTarget is true only for provisioning statuses' {
    Assert-Equal $true  (Test-SsmPlaceholderTarget -Target @{ Status = 'Unprovisioned' })
    Assert-Equal $true  (Test-SsmPlaceholderTarget -Target @{ Status = 'ProvisionRequested' })
    Assert-Equal $false (Test-SsmPlaceholderTarget -Target @{ Status = 'NotScanned' })
    Assert-Equal $false (Test-SsmPlaceholderTarget -Target @{ Status = 'Clean' })
}

Invoke-SsmTest 'Get-StatusBadge renders Unprovisioned and Requested badges' {
    $prevT = Get-Variable -Name T -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $prevG = Get-Variable -Name G -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $script:T = @{ Attention = '<A>'; Cloud = '<C>'; Muted = ''; Row = '' }
    $script:G = @{ Bang = '!'; Half = '~'; Ring = 'o'; Dot = '*' }
    try {
        $u = Get-StatusBadge -Status 'Unprovisioned' -Width 16
        if ($u -notlike '<A>! Unprovisioned*') { throw "unexpected: $u" }
        $r = Get-StatusBadge -Status 'ProvisionRequested' -Width 16
        if ($r -notlike '<C>~ Requested*') { throw "unexpected: $r" }
    } finally { $script:T = $prevT; $script:G = $prevG }
}
```

- [ ] **Step 2: Run** `pwsh -NoProfile -File ./tests/run-tests.ps1` → both FAIL.

- [ ] **Step 3: Implement**

`src/47-onedrive-provision.ps1`, before `#endregion`:

```powershell
function Test-SsmPlaceholderTarget {
    # Rows that represent a user without a personal site yet (or one just
    # requested). They have no reachable URL: never scan, connect, or cache them.
    param([Parameter(Mandatory)]$Target)
    return ([string]$Target.Status -in @('Unprovisioned', 'ProvisionRequested'))
}
```

`src/00-globals.ps1`: in the ASCII glyph table add `Bang='!'` after `Arrow='->'`; in the Unicode table add `Bang='!'` after `Arrow=([char]0x2192)`. In `$script:T` add after `Danger`:

```powershell
    Attention  = "$e[1;38;5;208m"
```

`src/15-drawing.ps1` `Get-StatusBadge` switch: add after the `'Revoked'` case:

```powershell
        'Unprovisioned'      { $style = $t.Attention; $glyph = [string]$g.Bang; $text = 'Unprovisioned' }
        'ProvisionRequested' { $style = $t.Cloud;     $glyph = [string]$g.Half; $text = 'Requested'     }
```

- [ ] **Step 4: Run tests** → PASS, `0 failed`. Parse-check `src/00-globals.ps1`.
- [ ] **Step 5: Commit**

```bash
git add src/47-onedrive-provision.ps1 src/00-globals.ps1 src/15-drawing.ps1 tests/onedrive-provision.tests.ps1
git commit -m "feat: placeholder target predicate and Unprovisioned badge"
```

---

### Task 2: Filter, F cycle, status line, cache/scan/admin exclusion

**Files:**
- Modify: `src/65-views.ps1:5-14` (`Update-TabView`), status line ~line 146-150, `Invoke-TabScan` loop ~line 297, `Get-SsmOneDriveAdminSelectedTargets` ~line 738
- Modify: `src/75-key-dispatch.ps1:90-96` (`'F'`)
- Modify: `src/70-cache.ps1:11-17` (`ConvertTo-SsmCacheObject`)
- Test: `tests/views.tests.ps1`, `tests/cache.tests.ps1` (append)

**Interfaces:**
- Consumes: `Test-SsmPlaceholderTarget` (Task 1).

- [ ] **Step 1: Failing tests** — append to `tests/views.tests.ps1`:

```powershell
Invoke-SsmTest 'Update-TabView hides placeholder rows under All and shows only them under Unprovisioned' {
    $tab = @{
        Items = @(
            @{ Url = 'https://x/a'; Title = 'a'; Status = 'Clean'; FindingCount = 0 },
            @{ Url = 'https://x/p'; Title = 'p'; Status = 'Unprovisioned'; FindingCount = 0; Upn = 'p@x.com' },
            @{ Url = 'https://x/q'; Title = 'q'; Status = 'ProvisionRequested'; FindingCount = 0; Upn = 'q@x.com' }
        )
        Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0; View = @()
    }
    Update-TabView -Tab $tab
    Assert-Equal 1 @($tab['View']).Count
    Assert-Equal 'https://x/a' $tab['View'][0].Url
    $tab['Filter'] = 'NotScanned'; Update-TabView -Tab $tab
    Assert-Equal 0 @($tab['View']).Count
    $tab['Filter'] = 'Unprovisioned'; Update-TabView -Tab $tab
    Assert-Equal 2 @($tab['View']).Count
}

Invoke-SsmTest 'F cycles into Unprovisioned only on the OneDrives tab' {
    $mk = { param($od) @{ OneDrive = $od; Items = @(); View = @(); Filter = 'Failed'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0 } }
    $script:UI = @{ Dirty = $false; SearchMode = $false }
    $k = [System.ConsoleKeyInfo]::new('f', [System.ConsoleKey]::F, $false, $false, $false)
    $od = & $mk $true;  Invoke-TargetsKey -Tab $od -K $k;  Assert-Equal 'Unprovisioned' $od['Filter']
    Invoke-TargetsKey -Tab $od -K $k;  Assert-Equal 'All' $od['Filter']
    $st = & $mk $false; Invoke-TargetsKey -Tab $st -K $k;  Assert-Equal 'All' $st['Filter']
}

Invoke-SsmTest 'Invoke-TabScan skips placeholder rows' {
    $script:Connected = $false
    function Connect-SsmSite { param($Url) $script:Connected = $true; $false }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    function Write-Screen { }
    function Start-LoadSpinner { }
    function Stop-LoadSpinner { }
    function Write-ProgressModal { }
    function New-SsmProgressCallback { param($Title, $State, $CancelMode) { } }
    function Save-SsmCache { }
    function Update-TabTargetStatuses { param($Tab) }
    $tab = @{
        Items = @(@{ Url = 'https://x/p'; Title = 'p'; Status = 'Unprovisioned'; FindingCount = 0; Findings = @(); Selected = $true; Upn = 'p@x.com' })
        Categories = @('Links'); Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0; View = @()
    }
    Invoke-TabScan -Tab $tab
    Assert-Equal $false $script:Connected
    Assert-Equal 'Unprovisioned' $tab['Items'][0].Status
}

Invoke-SsmTest 'Get-SsmOneDriveAdminSelectedTargets ignores placeholder rows' {
    $tab = @{ Items = @(
        @{ Url = 'https://x/a'; Title = 'a'; Status = 'Clean'; Selected = $true },
        @{ Url = 'https://x/p'; Title = 'p'; Status = 'Unprovisioned'; Selected = $true; Upn = 'p@x.com' }) }
    $r = @(Get-SsmOneDriveAdminSelectedTargets -Tab $tab)
    Assert-Equal 1 $r.Count
    Assert-Equal 'https://x/a' $r[0].Url
}
```

Append to `tests/cache.tests.ps1`:

```powershell
Invoke-SsmTest 'ConvertTo-SsmCacheObject omits placeholder rows' {
    $script:Version = 'test'
    $tabs = @(@{ Kind = 'Targets'; Name = 'OneDrives'; Categories = @(); Items = @(
        @{ Url = 'https://x/a'; Title = 'a'; Template = ''; Status = 'Clean'; FindingCount = 0; Findings = @() },
        @{ Url = 'https://x/p'; Title = 'p'; Template = ''; Status = 'Unprovisioned'; FindingCount = 0; Findings = @(); Upn = 'p@x.com' }) })
    $o = ConvertTo-SsmCacheObject -Tabs $tabs
    Assert-Equal 1 @($o.Tabs[0].Items).Count
    Assert-Equal 'https://x/a' $o.Tabs[0].Items[0].Url
}
```

If `ConvertTo-SsmCacheObject`'s returned object does not expose `.Tabs` (check lines 18-28 of `src/70-cache.ps1`), adjust the assertion path to the actual property name and note it in the report.

- [ ] **Step 2: Run tests** → the 5 new tests FAIL (Invoke-TabScan test may fail differently: `Connected` true).

- [ ] **Step 3: Implement**

`src/65-views.ps1` `Update-TabView` — replace the `switch ($Tab['Filter'])` block with:

```powershell
    # Placeholder rows (users without a personal site) only surface under the
    # dedicated Unprovisioned filter; every other filter hides them.
    if ($Tab['Filter'] -eq 'Unprovisioned') {
        $items = @($items | Where-Object { Test-SsmPlaceholderTarget -Target $_ })
    } else {
        $items = @($items | Where-Object { -not (Test-SsmPlaceholderTarget -Target $_) })
        switch ($Tab['Filter']) {
            'NotScanned' { $items = @($items | Where-Object { $_.Status -eq 'NotScanned' }) }
            'Clean'      { $items = @($items | Where-Object { $_.Status -eq 'Clean' }) }
            'Findings'   { $items = @($items | Where-Object { $_.Status -eq 'Findings' -or $_.Status -eq 'Revoked' }) }
            'Failed'     { $items = @($items | Where-Object { $_.Status -like '*Failed' }) }
        }
    }
```
Update the function comment to `Filter: All | NotScanned | Clean | Findings | Failed | Unprovisioned`.

Status line (after the `if ($done.Count -gt 0) { ... }` block, before the `Search` line):

```powershell
    $unprov = @($Tab['Items'] | Where-Object { $_.Status -eq 'Unprovisioned' }).Count
    if ($unprov -gt 0) { $ctx += ('   unprovisioned:{0} (F to view)' -f $unprov) }
```

`Invoke-TabScan`: change `$sel = @($Tab['Items'] | Where-Object { $_.Selected })` to:

```powershell
    $sel = @($Tab['Items'] | Where-Object { $_.Selected -and -not (Test-SsmPlaceholderTarget -Target $_) })
    $skipped = @($Tab['Items'] | Where-Object { $_.Selected -and (Test-SsmPlaceholderTarget -Target $_) }).Count
    if ($skipped -gt 0) { Write-SsmLog -Message ("Scan: skipped {0} unprovisioned placeholder row(s) - nothing to connect to yet." -f $skipped) -Level WARN }
```
and change the following `if ($sel.Count -eq 0) { Show-MsgModal ... 'Nothing selected. Space selects targets.' ; return }` line to:

```powershell
    if ($sel.Count -eq 0) {
        $msg = if ($skipped -gt 0) { 'Only unprovisioned rows are selected - there is nothing to scan yet.' } else { 'Nothing selected. Space selects targets.' }
        Show-MsgModal -Title 'Scan' -Lines @($msg); return
    }
```

`Get-SsmOneDriveAdminSelectedTargets`: change `if (-not $it.Selected) { continue }` to `if (-not $it.Selected -or (Test-SsmPlaceholderTarget -Target $it)) { continue }`.

`src/75-key-dispatch.ps1` `'F'` case: replace `$order = @('All','NotScanned','Clean','Findings','Failed')` with:

```powershell
            $order = @('All','NotScanned','Clean','Findings','Failed')
            if ($Tab['OneDrive']) { $order += 'Unprovisioned' }
```

`src/70-cache.ps1` `ConvertTo-SsmCacheObject`: inside `foreach ($it in @($tab['Items'])) {` add as first line `if (Test-SsmPlaceholderTarget -Target $it) { continue }`.

- [ ] **Step 4: Run tests + lint** → `0 failed`, analyzer silent.
- [ ] **Step 5: Commit**

```bash
git add src/65-views.ps1 src/75-key-dispatch.ps1 src/70-cache.ps1 tests/views.tests.ps1 tests/cache.tests.ps1
git commit -m "feat: Unprovisioned filter; exclude placeholder rows from scan, admin, cache"
```

---

### Task 3: Context-aware P, Enter-on-empty, help/hint text

**Files:**
- Modify: `src/65-views.ps1` (`Invoke-SsmOneDriveProvision` full rewrite; hint `@('P','pre-provision')` unchanged)
- Modify: `src/47-onedrive-provision.ps1` (append `New-SsmPlaceholderTarget`)
- Modify: `src/75-key-dispatch.ps1:72-82` (`'Enter'`)
- Modify: `src/20-modals.ps1:605` (help row)
- Test: `tests/views.tests.ps1` (replace the three existing `Invoke-SsmOneDriveProvision` tests)

**Interfaces:**
- Produces: `New-SsmPlaceholderTarget -User {Id;Upn;DisplayName} -> hashtable` (New-Target + `Upn`, Status `Unprovisioned`). `Invoke-SsmOneDriveProvision -Tab`.

- [ ] **Step 1: Replace tests** — delete the three tests named `Invoke-SsmOneDriveProvision refuses non-OneDrive tab`, `... stops without confirm when nothing is unprovisioned`, `... requests after PROVISION confirm` in `tests/views.tests.ps1` and append:

```powershell
Invoke-SsmTest 'New-SsmPlaceholderTarget builds a predicted personal URL' {
    $script:Auth = @{ AdminUrl = 'https://contoso-admin.sharepoint.com' }
    $t = New-SsmPlaceholderTarget -User ([pscustomobject]@{ Id = '1'; Upn = 'John.Doe@contoso.com'; DisplayName = 'John Doe' })
    Assert-Equal 'https://contoso-my.sharepoint.com/personal/john_doe_contoso_com' $t.Url
    Assert-Equal 'John Doe' $t.Title
    Assert-Equal 'John.Doe@contoso.com' $t.Upn
    Assert-Equal 'Unprovisioned' $t.Status
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision refuses non-OneDrive tab' {
    $script:CapturedTitle = $null
    function Show-MsgModal { param($Title, $Lines, $Kind) $script:CapturedTitle = $Title }
    Invoke-SsmOneDriveProvision -Tab @{ OneDrive = $false; Items = @() }
    Assert-Equal 'Pre-provision OneDrives' $script:CapturedTitle
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision loads placeholder rows and switches filter when none loaded' {
    $script:Auth = @{ AdminUrl = 'https://contoso-admin.sharepoint.com' }
    $script:UI = @{ Dirty = $false }
    function Write-ProgressModal { }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    function Export-SsmProvisionCsv { param($Rows, $Phase) 'x.csv' }
    function Get-SsmLicensedUsers { param($Progress) @(
        [pscustomobject]@{ Id='1'; Upn='has@contoso.com'; DisplayName='Has' },
        [pscustomobject]@{ Id='2'; Upn='new@contoso.com'; DisplayName='New' }) }
    function Get-SsmProvisionedOwnerSet { param($Progress)
        $s = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); [void]$s.Add('has@contoso.com'); return ,$s }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not confirm' }
    $tab = @{ OneDrive = $true; Items = @(); View = @(); Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0 }
    Invoke-SsmOneDriveProvision -Tab $tab
    Assert-Equal 1 @($tab['Items']).Count
    Assert-Equal 'new@contoso.com' $tab['Items'][0].Upn
    Assert-Equal 'Unprovisioned' $tab['Filter']
    Assert-Equal 1 @($tab['View']).Count
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision provisions only selected Unprovisioned rows' {
    $script:UI = @{ Dirty = $false }
    $script:RequestedUpns = @()
    function Write-ProgressModal { }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    function Export-SsmProvisionCsv { param($Rows, $Phase) 'x.csv' }
    function Get-SsmLicensedUsers { param($Progress) throw 'must not reload' }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) Assert-Equal 'PROVISION' $Word; $true }
    function Invoke-SsmPersonalSiteRequest { param($Upns, $Progress) $script:RequestedUpns = @($Upns)
        @($Upns | ForEach-Object { [pscustomobject]@{ Upn=$_; Batch=1; Status='Requested'; Error='' } }) }
    $rows = @(
        @{ Url='https://x/a'; Title='a'; Status='Unprovisioned'; FindingCount=0; Findings=@(); Selected=$true;  Upn='a@x.com' },
        @{ Url='https://x/b'; Title='b'; Status='Unprovisioned'; FindingCount=0; Findings=@(); Selected=$false; Upn='b@x.com' },
        @{ Url='https://x/c'; Title='c'; Status='ProvisionRequested'; FindingCount=0; Findings=@(); Selected=$true; Upn='c@x.com' })
    $tab = @{ OneDrive = $true; Items = $rows; View = @(); Filter = 'Unprovisioned'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0 }
    Invoke-SsmOneDriveProvision -Tab $tab
    Assert-Equal 1 $script:RequestedUpns.Count
    Assert-Equal 'a@x.com' $script:RequestedUpns[0]
    Assert-Equal 'ProvisionRequested' $rows[0].Status
    Assert-Equal $false $rows[0].Selected
    Assert-Equal 'Unprovisioned' $rows[1].Status
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision with rows loaded but none selected shows a hint and does not request' {
    $script:CapturedKind = $null
    function Show-MsgModal { param($Title, $Lines, $Kind) $script:CapturedKind = $Kind }
    function Get-SsmLicensedUsers { param($Progress) throw 'must not reload' }
    function Invoke-SsmPersonalSiteRequest { param($Upns, $Progress) throw 'must not request' }
    $tab = @{ OneDrive = $true; Items = @(@{ Url='https://x/a'; Title='a'; Status='Unprovisioned'; FindingCount=0; Findings=@(); Selected=$false; Upn='a@x.com' }) }
    Invoke-SsmOneDriveProvision -Tab $tab
    Assert-Equal 'Warn' $script:CapturedKind
}

Invoke-SsmTest 'Enter on an empty Unprovisioned view loads placeholders instead of enumerating' {
    $script:UI = @{ Dirty = $false; SearchMode = $false }
    $script:Loaded = $false; $script:Enumerated = $false
    function Invoke-SsmOneDriveProvision { param($Tab) $script:Loaded = $true }
    function Invoke-TabEnumerate { param($Tab) $script:Enumerated = $true }
    $tab = @{ OneDrive = $true; Items = @(); View = @(); Filter = 'Unprovisioned'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0 }
    $k = [System.ConsoleKeyInfo]::new([char]13, [System.ConsoleKey]::Enter, $false, $false, $false)
    Invoke-TargetsKey -Tab $tab -K $k
    Assert-Equal $true $script:Loaded
    Assert-Equal $false $script:Enumerated
}
```

- [ ] **Step 2: Run tests** → new tests FAIL.

- [ ] **Step 3: Implement**

`src/47-onedrive-provision.ps1`, before `#endregion`:

```powershell
function New-SsmPlaceholderTarget {
    # A list row for a licensed user with no personal site yet. The URL is
    # the address SharePoint will normally assign; it is a display/dedup
    # value only - nothing connects to it until provisioning completes.
    param([Parameter(Mandatory)]$User)
    $prefix = ([string]$script:Auth.AdminUrl) -replace '^https://', '' -replace '-admin\.sharepoint\.com/?$', ''
    $url = 'https://{0}-my.sharepoint.com/personal/{1}' -f $prefix, (ConvertTo-SsmPersonalSlug -Upn $User.Upn)
    $title = if ($User.DisplayName) { [string]$User.DisplayName } else { [string]$User.Upn }
    $t = New-Target -Url $url -Title $title -Template 'SPSPERS#10'
    $t['Upn'] = [string]$User.Upn
    $t['Status'] = 'Unprovisioned'
    return $t
}
```

`src/65-views.ps1` — replace the whole `Invoke-SsmOneDriveProvision` function with:

```powershell
function Invoke-SsmOneDriveProvision {
    # P on the OneDrives tab. Context-aware:
    #   no placeholder rows loaded      -> query Graph + tenant, add rows, switch to Unprovisioned filter
    #   selected Unprovisioned rows     -> typed PROVISION, request only those
    #   rows loaded, nothing selected   -> hint
    param($Tab)
    $title = 'Pre-provision OneDrives'
    if (-not $Tab['OneDrive']) {
        Show-MsgModal -Title $title -Lines @('This action is only available on the OneDrives tab.') -Kind Warn
        return
    }

    $placeholders = @($Tab['Items'] | Where-Object { Test-SsmPlaceholderTarget -Target $_ })
    if ($placeholders.Count -eq 0) {
        Write-ProgressModal -Title $title -Done 0 -Total 0 -Label 'Querying Graph for licensed users' -Ok 0 -Failed 0
        try {
            $licensed = @(Get-SsmLicensedUsers -Progress { param($n)
                Write-ProgressModal -Title $title -Done $n -Total 0 -Label 'Querying Graph for licensed users' -Ok 0 -Failed 0 })
        } catch {
            Write-SsmErrorLog -Context 'Pre-provision: Graph user query failed' -ErrorRecord $_
            $msg = $_.Exception.Message
            $lines = if ($msg -match '403|Forbidden|Authorization_RequestDenied') {
                @('Graph returned 403.', '', 'Delegated sign-in needs User.Read.All;',
                  'app-only registrations need the User.Read.All application permission.')
            } else { @('Graph user query failed:', $msg) }
            Show-MsgModal -Title $title -Lines $lines -Kind Error
            return
        }
        Write-ProgressModal -Title $title -Done 0 -Total 0 -Label 'Enumerating personal sites' -Ok 0 -Failed 0
        $ownerSet = Get-SsmProvisionedOwnerSet -Progress { param($n)
            Write-ProgressModal -Title $title -Done $n -Total 0 -Label 'Enumerating personal sites' -Ok 0 -Failed 0 }
        if ($null -eq $ownerSet) { return }   # Connect-SsmAdmin already reported the failure

        $missing = @(Get-SsmUnprovisionedUsers -Licensed $licensed -OwnerSet $ownerSet)
        Write-SsmLog -Message ("Pre-provision: {0} licensed, {1} personal sites, {2} unprovisioned." -f $licensed.Count, $ownerSet.Count, $missing.Count)
        if ($missing.Count -eq 0) {
            Show-MsgModal -Title $title -Lines @('No unprovisioned licensed users found.')
            return
        }
        $csv = Export-SsmProvisionCsv -Rows $missing -Phase UNPROVISIONED
        Add-TargetsToTab -Tab $Tab -Targets @($missing | ForEach-Object { New-SsmPlaceholderTarget -User $_ })
        $Tab['Filter'] = 'Unprovisioned'
        $Tab['Cursor'] = 0
        Update-TabView -Tab $Tab
        Show-MsgModal -Title $title -Lines @(
            ("{0} unprovisioned user(s) loaded under the Unprovisioned filter." -f $missing.Count),
            "CSV: $csv", '',
            'Space/A selects rows, P provisions the selection.')
        return
    }

    $chosen = @($placeholders | Where-Object { $_.Selected -and $_.Status -eq 'Unprovisioned' })
    if ($chosen.Count -eq 0) {
        Show-MsgModal -Title $title -Kind Warn -Lines @(
            'Nothing selected.', '',
            'F to the Unprovisioned filter, Space/A to select, then P.',
            'C clears the list so P can reload it.')
        return
    }

    $confirm = @(("Request OneDrive provisioning for {0} user(s)?" -f $chosen.Count), '',
        'SharePoint queues the work and provisions asynchronously (minutes to hours).', '') +
        @($chosen | ForEach-Object { "  $($_.Upn)" })
    if (-not (Show-TypedConfirmModal -Title $title -Lines $confirm -Word 'PROVISION')) { return }

    $upns = @($chosen | ForEach-Object { $_.Upn })
    $rows = @(Invoke-SsmPersonalSiteRequest -Upns $upns -Progress { param($b, $t)
        Write-ProgressModal -Title $title -Done $b -Total $t -Label 'Submitting provisioning batches' -Ok 0 -Failed 0 })
    $ok = @{}
    foreach ($r in $rows) { if ($r.Status -eq 'Requested') { $ok[$r.Upn] = $true } }
    foreach ($c in $chosen) {
        if ($ok.ContainsKey($c.Upn)) { $c.Status = 'ProvisionRequested'; $c.Selected = $false }
    }
    if ($Tab.ContainsKey('View')) { Update-TabView -Tab $Tab }
    $reqCsv = Export-SsmProvisionCsv -Rows $rows -Phase REQUESTED
    $failed = $rows.Count - $ok.Count
    Show-MsgModal -Title $title -Kind ($failed -gt 0 ? 'Warn' : 'Info') -Lines @(
        ("Requested {0} user(s); {1} failed." -f $ok.Count, $failed),
        "CSV: $reqCsv", '',
        'SharePoint provisions personal sites asynchronously.',
        'Rows now show Requested. C then P reloads the list to verify later.')
}
```

`src/75-key-dispatch.ps1` `'Enter'` case: replace

```powershell
            if ($view.Count -eq 0) {
                # Empty list: Enter enumerates targets from the tenant.
                Invoke-TabEnumerate -Tab $Tab
                return
            }
```
with
```powershell
            if ($view.Count -eq 0) {
                # Empty list: Enter loads it - placeholders under the Unprovisioned
                # filter, otherwise the tenant's sites/OneDrives.
                if ($Tab['Filter'] -eq 'Unprovisioned') { Invoke-SsmOneDriveProvision -Tab $Tab } else { Invoke-TabEnumerate -Tab $Tab }
                return
            }
```

`src/20-modals.ps1` help row for `P` → replace with:

```powershell
        @($t.Row, '  P                    pre-provision OneDrives (OneDrives only): load users without a OneDrive, then provision selected'),
```
and after the `F` help row (`cycle filter All/NotScanned/Clean/Findings`) change its text to `cycle filter All/NotScanned/Clean/Findings/Failed (+Unprovisioned on OneDrives)`.

- [ ] **Step 4: Run tests + lint** → `0 failed`, analyzer silent. If `views.tests.ps1` defines `$script:Auth` elsewhere, restore it after the tests that set it.
- [ ] **Step 5: Commit**

```bash
git add src/65-views.ps1 src/47-onedrive-provision.ps1 src/75-key-dispatch.ps1 src/20-modals.ps1 tests/views.tests.ps1
git commit -m "feat: P loads unprovisioned rows or provisions the selection"
```

---

### Task 4: Docs

**Files:**
- Modify: `CHANGELOG.md` (Unreleased)
- Modify: `wiki/OneDrive-Pre-Provisioning.md` (Key + Flow + Limitations)
- Modify: `wiki/Home.md` row, `README.md` bullet

- [ ] **Step 1: CHANGELOG** under `## [Unreleased]`:

```markdown
- Change: OneDrive pre-provisioning is now selective. `P` on the OneDrives
  tab loads users without a personal site as rows under a new
  `Unprovisioned` filter (`F` cycle, OneDrives tab only; the rows never
  appear under `All`) with an orange `!` badge. Select rows with
  Space/`A`, press `P` again, type `PROVISION`, and only the selection is
  submitted; those rows switch to `Requested`. Placeholder rows are skipped
  by scans and admin actions and are not saved to the session cache.
  `Enter` on an empty Unprovisioned view loads them too.
```

- [ ] **Step 2: Wiki page** — replace the `## Key` and `## Flow` sections with:

```markdown
## Key

`P` on the **OneDrives** tab. `P` is context-aware:

| State | What `P` does |
|---|---|
| No unprovisioned rows loaded | Queries the tenant and loads them under the `Unprovisioned` filter |
| Unprovisioned rows selected | Asks for `PROVISION` and submits only the selected users |
| Rows loaded, nothing selected | Shows a hint |

`Enter` on an empty list while the `Unprovisioned` filter is active also
loads the rows.

## The Unprovisioned filter

`F` cycles `All → Not scanned → Clean → Findings → Failed → Unprovisioned`
on the OneDrives tab. Unprovisioned rows show only under that filter, never
under `All`, so the normal OneDrive list is unaffected. Each row shows the
user's display name, the personal-site URL SharePoint will normally assign,
and an orange `! Unprovisioned` badge. The status line shows
`unprovisioned:N (F to view)` while any are loaded.

These rows are placeholders: scans (`S`), admin actions (`M`) skip them, and
they are not saved to the session cache. `C` clears them with the rest of
the list; `P` reloads them.

## Flow

1. Press `P`. Progress shows the Graph user paging, then the personal-site
   enumeration. Rows are added and the filter switches to `Unprovisioned`.
   `SSM_ONEDRIVE_UNPROVISIONED_<stamp>.csv` is written to
   `SSM-Exports/<tenant>/` when at least one user is found.
2. Select the users to provision with Space or `A`.
3. Press `P`, type `PROVISION`. The selected UPNs are sent to
   `Request-PnPPersonalSite` in batches of 200.
4. Successfully submitted rows change to `Requested`;
   `SSM_ONEDRIVE_REQUESTED_<stamp>.csv` records `Upn, Batch, Status, Error`.
   Rows in a failed batch stay `Unprovisioned` so they can be retried.
```

Add to `## Limitations`:

```markdown
- The URL shown on an unprovisioned row is predicted from the UPN; the
  actual site can get a different suffix if SharePoint has to disambiguate.
- Unprovisioned rows are not cached; after a restart press `P` to reload.
```

- [ ] **Step 3: Home row + README bullet** — update `wiki/Home.md` row text to `Load OneDrive-licensed users with no personal site under an Unprovisioned filter and provision the selected ones (P, OneDrives tab)`. Update README bullet to:

```markdown
- **OneDrive pre-provisioning** (`P`, OneDrives tab only) - loads enabled member users with a SharePoint service plan but no personal site as rows under an `Unprovisioned` filter (never shown under `All`); select the ones you want, press `P`, type `PROVISION`, and only those are submitted via `Request-PnPPersonalSite` (batches of 200). Provisioning completes asynchronously on the service side. See [OneDrive-Pre-Provisioning](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/OneDrive-Pre-Provisioning).
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md wiki/OneDrive-Pre-Provisioning.md wiki/Home.md README.md
git commit -m "docs: selective OneDrive pre-provisioning"
```
