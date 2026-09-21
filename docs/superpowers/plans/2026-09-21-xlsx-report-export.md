# Excel Report Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `E` opens an export menu; `X` writes a three-sheet `.xlsx` (Summary with Copilot exposure indicator, Findings detail, Sites) via ImportExcel, CSV path unchanged.

**Architecture:** Scan engine records `ItemsScanned` per target and `Reach` per finding. New region `src/52-xlsx.ps1` holds pure aggregation/scoring functions plus the ImportExcel-bound writer and an install-on-demand helper. `src/20-modals.ps1` gains a tiny export-choice modal; `src/75-key-dispatch.ps1` routes `E` to it.

**Tech Stack:** PowerShell 7.4+, PnP.PowerShell (existing), ImportExcel (new, optional, installed on demand). Assert tests via `tests/run-tests.ps1`.

Spec: `docs/superpowers/specs/2026-09-21-xlsx-report-export-design.md`

## Global Constraints

- PowerShell 7.4+, `Set-StrictMode -Version 2.0`: check optional properties with `$obj.PSObject.Properties['X']` and hashtable keys with `$h['key']` / `$h.Contains('key')`.
- One file per region under `src/`, numbered; bootstrap dot-sources `src/*.ps1` sorted by name.
- ImportExcel is the ONLY allowed dependency beyond PnP.PowerShell; it is optional and used only by `src/52-xlsx.ps1`.
- CSV export behaviour and columns unchanged.
- Lint: `Invoke-ScriptAnalyzer -Path ./SharePoint-Sharing-Manager.ps1, ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error, Warning` must be clean.
- Tests: `pwsh ./tests/run-tests.ps1` must exit 0. Test files are dot-sourced by the runner, which defines `Invoke-SsmTest 'name' { }` and `Assert-Equal $expected $actual`.
- Filename: `SSM_REPORT_<SharePoint|OneDrive>_<site-tag|ALL>_<yyyyMMdd-HHmmss>.xlsx` in `$script:ExportDir`.
- Exposure weights: AnonymousLink 5, EEEU 5, Everyone 5, OrgLink 3, GuestLink 2, GuestGrant 2, other 1. `Score = min(100, round(WeightedReach / ItemsScanned * 1000))`. Bands: 0-10 Low, 11-40 Medium, 41-70 High, 71-100 Critical, `n/a` when ItemsScanned = 0.
- Every user-facing change updates CHANGELOG (Unreleased), README, and `wiki/*.md` in the same change.

---

### Task 1: Scan engine records ItemsScanned and Reach

**Files:**
- Modify: `src/45-targets.ps1:5-13` (`New-Target`)
- Modify: `src/35-scan-engine.ps1:83-108` (`Add-GrantsRest`), `:110-218` (`Invoke-SiteScan`)
- Modify: `src/70-cache.ps1:17-21`, `:49-53`
- Test: `tests/scan-engine.tests.ps1` (append), `tests/cache.tests.ps1` if present else append to `tests/scan-engine.tests.ps1`

**Interfaces:**
- Produces: target hashtable keys `ItemsScanned` (int), `LibrariesScanned` (int); finding property `Reach` (int) on every finding object.

- [ ] **Step 1: Write failing tests**

Append to `tests/scan-engine.tests.ps1`:

```powershell
Invoke-SsmTest 'New-Target defaults ItemsScanned and LibrariesScanned to 0' {
    $t = New-Target -Url 'https://x.sharepoint.com/sites/a'
    Assert-Equal 0 $t.ItemsScanned
    Assert-Equal 0 $t.LibrariesScanned
}

Invoke-SsmTest 'Cache round-trips ItemsScanned and finding Reach' {
    $t = New-Target -Url 'https://x.sharepoint.com/sites/a'
    $t.ItemsScanned = 1234; $t.LibrariesScanned = 2; $t.Status = 'Findings'; $t.FindingCount = 1
    $t.Findings = @([pscustomobject]@{ Site=$t.Url; Location='Library'; Name='Documents'; CategoryKey='EEEU'; Category='EEEU grant'; Access='Read'; Principal='Everyone except external users'; Path='/sites/a/Shared Documents'; RemovalKind='DirectGrant'; LinkId=$null; ListId='L'; ItemId=$null; PrincipalId=4; LinkCreated=''; Reach=1000; RevokeStatus='NotAttempted'; Selected=$false })
    $tab = @{ Kind='Targets'; Name='Sites'; Categories=@('EEEU'); Items=@($t) }
    $json = ConvertTo-SsmCacheObject -Tabs @($tab) | ConvertTo-Json -Depth 10
    $tab2 = @{ Kind='Targets'; Name='Sites'; Categories=@(); Items=@() }
    ConvertFrom-SsmCacheObject -Cache ($json | ConvertFrom-Json) -Tabs @($tab2)
    Assert-Equal 1234 $tab2['Items'][0].ItemsScanned
    Assert-Equal 2 $tab2['Items'][0].LibrariesScanned
    Assert-Equal 1000 $tab2['Items'][0].Findings[0].Reach
}

Invoke-SsmTest 'Cache restore tolerates old entries without ItemsScanned' {
    $old = [pscustomobject]@{ Tabs=@([pscustomobject]@{ Name='Sites'; Categories=@(); Items=@([pscustomobject]@{ Url='https://x/sites/a'; Title='a'; Template=''; Status='Clean'; FindingCount=0; Findings=@() }) }); SavedAt='2026-01-01T00:00:00Z' }
    $tab = @{ Kind='Targets'; Name='Sites'; Categories=@(); Items=@() }
    ConvertFrom-SsmCacheObject -Cache $old -Tabs @($tab)
    Assert-Equal 0 $tab['Items'][0].ItemsScanned
}
```

Check the exact name of the cache serializer first: `grep -n "^function" src/70-cache.ps1`. If it is not `ConvertTo-SsmCacheObject`, use the real name in the test.

- [ ] **Step 2: Run tests, verify fail**

Run: `pwsh ./tests/run-tests.ps1`
Expected: the three new tests FAIL (property `ItemsScanned` not found).

- [ ] **Step 3: New-Target defaults**

In `src/45-targets.ps1` replace the hashtable body of `New-Target`:

```powershell
    return @{
        Url = $Url.Trim(); Title = $Title; Template = $Template
        Status = 'NotScanned'; FindingCount = 0
        Findings = @(); Selected = $false
        ItemsScanned = 0; LibrariesScanned = 0
    }
```

- [ ] **Step 4: Cache save/restore**

`src/70-cache.ps1` save block (line ~17): add `ItemsScanned` and `LibrariesScanned`:

```powershell
            $items.Add([ordered]@{
                Url = $it.Url; Title = $it.Title; Template = $it.Template
                Status = $it.Status; FindingCount = $it.FindingCount
                ItemsScanned = [int]$it.ItemsScanned; LibrariesScanned = [int]$it.LibrariesScanned
                Findings = @($it.Findings)
            })
```

Restore block (line ~49); old caches lack the keys, so read them defensively:

```powershell
            $scannedItems = 0; $scannedLibs = 0
            if ($ci.PSObject.Properties['ItemsScanned']) { $scannedItems = [int]$ci.ItemsScanned }
            if ($ci.PSObject.Properties['LibrariesScanned']) { $scannedLibs = [int]$ci.LibrariesScanned }
            $items.Add(@{
                Url = $ci.Url; Title = $ci.Title; Template = $ci.Template
                Status = $ci.Status; FindingCount = $ci.FindingCount
                ItemsScanned = $scannedItems; LibrariesScanned = $scannedLibs
                Findings = $findings.ToArray(); Selected = $false
            })
```

Also in the restore finding loop (line ~46) add a `Reach` default for old findings:

```powershell
                if (-not $f.PSObject.Properties['Reach']) { $f | Add-Member -NotePropertyName Reach -NotePropertyValue 1 -Force }
```

- [ ] **Step 5: Reach on findings + ItemsScanned in scan**

`src/35-scan-engine.ps1`:

a) `Add-GrantsRest` gets a `[int]$Reach = 1` parameter and stores it:

```powershell
    param($RaUrl, $Site, $Location, $Name, $Path, $ListId, $ItemId, [string[]]$Categories, $Bag, [int]$Reach = 1)
```
and in the `$Bag.Add([pscustomobject]@{ ... })` block add `Reach = $Reach` after `LinkCreated = ''`.

b) Link finding (line ~197) add `Reach = 1` after `LinkCreated = $created`.

c) In `Invoke-SiteScan`:
- After `$bag = ...` add `$totalItems = 0; $libCount = 0`.
- Web-root call (line 127): pass `-Reach 0` for now; patched at end. Change to:
  `Add-GrantsRest "$base/_api/web/roleassignments?$raSelect" $site 'Web' $web.Title $base $null $null $Categories $bag 0`
- Library-root call (line 143): append ` $total` as the Reach argument.
- After `Write-SsmLog -Message ("{0} scanned, ..."` (line 162) add `$totalItems += $scanned; $libCount++`.
- Replace both `return $bag.ToArray()` (lines 130 and 217) with a call to a small finisher. Add before the function:

```powershell
function Complete-SiteScan {
    # Record totals on the target and give web-level findings the full site reach.
    param($Target, $Bag, [int]$TotalItems, [int]$LibCount)
    $Target.ItemsScanned = $TotalItems
    $Target.LibrariesScanned = $LibCount
    foreach ($f in $Bag) { if ($f.Location -eq 'Web') { $f.Reach = $TotalItems } }
    return $Bag.ToArray()
}
```
and use `return Complete-SiteScan -Target $Target -Bag $bag -TotalItems $totalItems -LibCount $libCount` at both return sites.

Add test for the finisher to `tests/scan-engine.tests.ps1`:

```powershell
Invoke-SsmTest 'Complete-SiteScan sets ItemsScanned and web Reach' {
    $t = New-Target -Url 'https://x/sites/a'
    $bag = [System.Collections.Generic.List[object]]::new()
    $bag.Add([pscustomobject]@{ Location='Web'; Reach=0 })
    $bag.Add([pscustomobject]@{ Location='File'; Reach=1 })
    $out = @(Complete-SiteScan -Target $t -Bag $bag -TotalItems 500 -LibCount 3)
    Assert-Equal 500 $t.ItemsScanned
    Assert-Equal 3 $t.LibrariesScanned
    Assert-Equal 500 $out[0].Reach
    Assert-Equal 1 $out[1].Reach
}
```

- [ ] **Step 6: Run tests, verify pass; lint**

Run: `pwsh ./tests/run-tests.ps1` → all PASS.
Run lint command from Global Constraints → no output.

- [ ] **Step 7: Commit**

```bash
git add src/45-targets.ps1 src/35-scan-engine.ps1 src/70-cache.ps1 tests/scan-engine.tests.ps1
git commit -m "feat: record ItemsScanned per target and Reach per finding"
```

---

### Task 2: Pure summary and exposure functions

**Files:**
- Create: `src/52-xlsx.ps1`
- Modify: `tests/run-tests.ps1:39` (add `'52-xlsx'` to the file list after `'50-csv'`)
- Test: `tests/xlsx.tests.ps1` (create)

**Interfaces:**
- Produces:
  - `Get-ExposureScore -Findings [object[]] -ItemsScanned [int]` → hashtable `@{ Score=[int]; Band=[string]; WeightedReach=[int]; ExposedPercent=[double] }`
  - `Get-FindingsSummary -Findings [object[]] -Targets [object[]]` → hashtable `@{ Total; SitesAffected; Links; DirectGrants; AnonymousLinks; Removed; Failed; NotAttempted; ItemsScanned; ByCategory=@(@{Category;Count}); ByAccess=@(@{Access;Count}); ByStatus=@(@{Status;Count}); TopSites=@(@{Site;Title;Count}) }`
  - `$script:ExposureWeights` ordered hashtable CategoryKey → weight.

- [ ] **Step 1: Write failing tests** (`tests/xlsx.tests.ps1`)

```powershell
function New-XlsxTestFinding {
    param([string]$Site, [string]$Key, [string]$Loc = 'File', [int]$Reach = 1, [string]$Access = 'View', [string]$Status = 'NotAttempted', [string]$Kind = 'Link')
    [pscustomobject]@{ Site=$Site; Location=$Loc; Name='doc.docx'; CategoryKey=$Key; Category=$script:RuleCategories[$Key]; Access=$Access; Principal='p'; Path="/x/$Site/doc.docx"; RemovalKind=$Kind; LinkId='1'; ListId='L'; ItemId=1; PrincipalId=$null; LinkCreated=''; Reach=$Reach; RevokeStatus=$Status; Selected=$false }
}

Invoke-SsmTest 'Exposure: 5 anonymous links in 1000 items -> 25 Medium' {
    $f = @(1..5 | ForEach-Object { New-XlsxTestFinding -Site 's1' -Key 'AnonymousLink' })
    $r = Get-ExposureScore -Findings $f -ItemsScanned 1000
    Assert-Equal 25 $r.WeightedReach
    Assert-Equal 25 $r.Score
    Assert-Equal 'Medium' $r.Band
    Assert-Equal 0.5 $r.ExposedPercent
}

Invoke-SsmTest 'Exposure: library EEEU reaching every item -> 100 Critical' {
    $f = @(New-XlsxTestFinding -Site 's1' -Key 'EEEU' -Loc 'Library' -Reach 1000 -Kind 'DirectGrant')
    $r = Get-ExposureScore -Findings $f -ItemsScanned 1000
    Assert-Equal 100 $r.Score
    Assert-Equal 'Critical' $r.Band
}

Invoke-SsmTest 'Exposure: zero items scanned -> n/a' {
    $r = Get-ExposureScore -Findings @(New-XlsxTestFinding -Site 's1' -Key 'OrgLink') -ItemsScanned 0
    Assert-Equal 0 $r.Score
    Assert-Equal 'n/a' $r.Band
}

Invoke-SsmTest 'Exposure: bands at boundaries' {
    # weight 1 (GuestGrant is 2; use unknown key for weight 1) reach 10 of 1000 -> 10 Low
    $low = @(New-XlsxTestFinding -Site 's1' -Key 'Everyone' -Reach 2)   # 5*2=10 -> 10 Low
    Assert-Equal 'Low' (Get-ExposureScore -Findings $low -ItemsScanned 1000).Band
    $high = @(New-XlsxTestFinding -Site 's1' -Key 'OrgLink' -Reach 20)  # 3*20=60 -> High
    Assert-Equal 'High' (Get-ExposureScore -Findings $high -ItemsScanned 1000).Band
}

Invoke-SsmTest 'Summary: counts, distinct sites, top sites ordering' {
    $f = @(
        (New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'AnonymousLink' -Access 'Edit'),
        (New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'OrgLink' -Status 'Removed'),
        (New-XlsxTestFinding -Site 'https://x/sites/b' -Key 'GuestGrant' -Kind 'DirectGrant' -Status 'Failed: 403')
    )
    $ta = New-Target -Url 'https://x/sites/a' -Title 'A'; $ta.ItemsScanned = 100
    $tb = New-Target -Url 'https://x/sites/b' -Title 'B'; $tb.ItemsScanned = 50
    $s = Get-FindingsSummary -Findings $f -Targets @($ta, $tb)
    Assert-Equal 3 $s.Total
    Assert-Equal 2 $s.SitesAffected
    Assert-Equal 2 $s.Links
    Assert-Equal 1 $s.DirectGrants
    Assert-Equal 1 $s.AnonymousLinks
    Assert-Equal 1 $s.Removed
    Assert-Equal 1 $s.Failed
    Assert-Equal 1 $s.NotAttempted
    Assert-Equal 150 $s.ItemsScanned
    Assert-Equal 'https://x/sites/a' $s.TopSites[0].Site
    Assert-Equal 'A' $s.TopSites[0].Title
    Assert-Equal 2 $s.TopSites[0].Count
    Assert-Equal 'Anonymous link' $s.ByCategory[0].Category
    Assert-Equal 2 @($s.ByAccess | Where-Object { $_.Access -eq 'View' })[0].Count
}
```

- [ ] **Step 2: Run tests, verify fail**

Add `'52-xlsx'` to the list in `tests/run-tests.ps1:39` first. Run: `pwsh ./tests/run-tests.ps1` → new tests FAIL (`Get-ExposureScore` not recognized).

- [ ] **Step 3: Implement** `src/52-xlsx.ps1`

```powershell
# ============================================================================
#region Excel report export (ImportExcel, optional)
# ============================================================================

# Copilot exposure heuristic: weight per rule category. Higher = wider audience
# whose Copilot can surface the item. Anything unlisted counts 1.
$script:ExposureWeights = [ordered]@{
    AnonymousLink = 5; EEEU = 5; Everyone = 5
    OrgLink       = 3
    GuestLink     = 2; GuestGrant = 2
}

function Get-ExposureScore {
    # Score = min(100, round(sum(weight * Reach) / ItemsScanned * 1000)).
    # Reach = items a finding exposes (1 for file/folder, library ItemCount for
    # library-level, site total for web-level). Band n/a when nothing was counted.
    param([object[]]$Findings, [int]$ItemsScanned)
    $weighted = 0; $reach = 0
    foreach ($f in @($Findings)) {
        if (-not $f) { continue }
        $r = 1
        if ($f.PSObject.Properties['Reach'] -and $f.Reach) { $r = [int]$f.Reach }
        $w = 1
        $key = [string]$f.CategoryKey
        if ($script:ExposureWeights.Contains($key)) { $w = [int]$script:ExposureWeights[$key] }
        $weighted += $w * $r
        $reach += $r
    }
    if ($ItemsScanned -le 0) { return @{ Score = 0; Band = 'n/a'; WeightedReach = $weighted; ExposedPercent = 0.0 } }
    $score = [int][Math]::Min(100, [Math]::Round($weighted / $ItemsScanned * 1000))
    $band = if ($score -le 10) { 'Low' } elseif ($score -le 40) { 'Medium' } elseif ($score -le 70) { 'High' } else { 'Critical' }
    $pct = [Math]::Round(100.0 * $reach / $ItemsScanned, 2)
    return @{ Score = $score; Band = $band; WeightedReach = $weighted; ExposedPercent = $pct }
}

function Get-CountTable {
    # Group by a property; returns ordered list of @{ <Label>=value; Count=n } sorted by Count desc.
    param([object[]]$Items, [string]$Property, [string]$Label)
    $map = [ordered]@{}
    foreach ($it in @($Items)) {
        $v = [string]$it.$Property
        if (-not $map.Contains($v)) { $map[$v] = 0 }
        $map[$v]++
    }
    $out = @()
    foreach ($k in ($map.Keys | Sort-Object { $map[$_] } -Descending)) { $out += @{ $Label = $k; Count = [int]$map[$k] } }
    return $out
}

function Get-FindingsSummary {
    param([object[]]$Findings, [object[]]$Targets)
    $f = @($Findings | Where-Object { $_ })
    $titleByUrl = @{}
    $itemsScanned = 0
    foreach ($t in @($Targets)) {
        if (-not $t) { continue }
        $titleByUrl[[string]$t.Url] = [string]$t.Title
        if ($t.Contains('ItemsScanned')) { $itemsScanned += [int]$t.ItemsScanned }
    }
    $sites = @($f | ForEach-Object { [string]$_.Site } | Sort-Object -Unique)
    $top = @()
    foreach ($row in (Get-CountTable -Items $f -Property 'Site' -Label 'Site' | Select-Object -First 10)) {
        $title = if ($titleByUrl.ContainsKey($row.Site)) { $titleByUrl[$row.Site] } else { ($row.Site.TrimEnd('/') -split '/')[-1] }
        $top += @{ Site = $row.Site; Title = $title; Count = $row.Count }
    }
    return @{
        Total          = $f.Count
        SitesAffected  = $sites.Count
        Links          = @($f | Where-Object { $_.RemovalKind -eq 'Link' }).Count
        DirectGrants   = @($f | Where-Object { $_.RemovalKind -eq 'DirectGrant' }).Count
        AnonymousLinks = @($f | Where-Object { $_.CategoryKey -eq 'AnonymousLink' }).Count
        Removed        = @($f | Where-Object { $_.RevokeStatus -eq 'Removed' }).Count
        Failed         = @($f | Where-Object { [string]$_.RevokeStatus -like 'Failed*' }).Count
        NotAttempted   = @($f | Where-Object { $_.RevokeStatus -eq 'NotAttempted' }).Count
        ItemsScanned   = $itemsScanned
        ByCategory     = @(Get-CountTable -Items $f -Property 'Category' -Label 'Category')
        ByAccess       = @(Get-CountTable -Items $f -Property 'Access' -Label 'Access')
        ByStatus       = @(Get-CountTable -Items $f -Property 'RevokeStatus' -Label 'Status')
        TopSites       = $top
    }
}

#endregion
```

Note: targets are hashtables, hence `$t.Contains('ItemsScanned')`.

- [ ] **Step 4: Run tests, verify pass; lint**

Run: `pwsh ./tests/run-tests.ps1` → PASS. Lint clean.

- [ ] **Step 5: Commit**

```bash
git add src/52-xlsx.ps1 tests/xlsx.tests.ps1 tests/run-tests.ps1
git commit -m "feat: findings summary and Copilot exposure score helpers"
```

---

### Task 3: ImportExcel on-demand install and xlsx writer

**Files:**
- Modify: `src/52-xlsx.ps1` (append before `#endregion`)
- Test: `tests/xlsx.tests.ps1` (append; writer test skips when ImportExcel absent)

**Interfaces:**
- Consumes: `Get-FindingsSummary`, `Get-ExposureScore` (Task 2); `Show-ConfirmModal`, `Invoke-OnMainBuffer`, `Write-SsmLog`, `Write-SsmErrorLog`, `$script:ExportDir`, `$script:Version`, `$script:Auth.AdminUrl`, `$script:Conn.Account`.
- Produces:
  - `Install-SsmImportExcel` → `[bool]` (module imported).
  - `Get-ReportFileName -TabName [string] -SiteTag [string]` → `[string]` leaf name.
  - `ConvertTo-ReportRows -Findings [object[]] -Targets [object[]]` → `[pscustomobject[]]` with the 15 Findings-sheet columns.
  - `Export-FindingsXlsx -Findings [object[]] -Targets [object[]] -TabName [string] -ScopeLabel [string] -SiteTag [string] -IncludeSites [bool]` → `[string]` full path.

- [ ] **Step 1: Write failing tests** (append to `tests/xlsx.tests.ps1`)

```powershell
Invoke-SsmTest 'Report filename pattern' {
    $n = Get-ReportFileName -TabName 'OneDrives' -SiteTag 'ALL'
    if ($n -notmatch '^SSM_REPORT_OneDrive_ALL_\d{8}-\d{6}\.xlsx$') { throw "bad name: $n" }
    $n2 = Get-ReportFileName -TabName 'Sites' -SiteTag 'hr'
    if ($n2 -notmatch '^SSM_REPORT_SharePoint_hr_\d{8}-\d{6}\.xlsx$') { throw "bad name: $n2" }
}

Invoke-SsmTest 'Report rows carry title, sharing type, full path, reach, ids' {
    $t = New-Target -Url 'https://x/sites/a' -Title 'HR Site'
    $f = @(New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'OrgLink' -Reach 1)
    $f[0].LinkCreated = '2026-07-24T07:10:18.520Z'
    $rows = @(ConvertTo-ReportRows -Findings $f -Targets @($t))
    Assert-Equal 'HR Site' $rows[0].'Site Title'
    Assert-Equal 'https://x/sites/a' $rows[0].'Site URL'
    Assert-Equal 'Link' $rows[0].'Sharing Type'
    Assert-Equal '/x/https://x/sites/a/doc.docx' $rows[0].'Full Path'
    Assert-Equal '2026-07-24' $rows[0].'Link Created'
    Assert-Equal 1 $rows[0].'Reach (items)'
    Assert-Equal 'L' $rows[0].'List Id'
}

Invoke-SsmTest 'Report rows: direct grant label, blank date, title fallback' {
    $f = @(New-XlsxTestFinding -Site 'https://x/sites/zz' -Key 'EEEU' -Kind 'DirectGrant')
    $rows = @(ConvertTo-ReportRows -Findings $f -Targets @())
    Assert-Equal 'Direct grant' $rows[0].'Sharing Type'
    Assert-Equal '' $rows[0].'Link Created'
    Assert-Equal 'zz' $rows[0].'Site Title'
}

Invoke-SsmTest 'Export-FindingsXlsx writes workbook with three sheets (skipped without ImportExcel)' {
    if (-not (Get-Module -ListAvailable ImportExcel)) { Write-Host '  (skipped: ImportExcel not installed)'; return }
    Import-Module ImportExcel
    $prev = $script:ExportDir
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssm-xlsx-{0}" -f [guid]::NewGuid())
    try {
        $t = New-Target -Url 'https://x/sites/a' -Title 'A'; $t.ItemsScanned = 100; $t.Status = 'Findings'; $t.FindingCount = 1
        $f = @(New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'AnonymousLink')
        $t.Findings = $f
        $p = Export-FindingsXlsx -Findings $f -Targets @($t) -TabName 'Sites' -ScopeLabel 'All SharePoint sites' -SiteTag 'ALL' -IncludeSites $true
        if (-not (Test-Path -LiteralPath $p)) { throw "no file: $p" }
        $sheets = @((Open-ExcelPackage -Path $p).Workbook.Worksheets | ForEach-Object { $_.Name })
        Assert-Equal 'Summary,Findings,Sites' ($sheets -join ',')
        if (Test-Path -LiteralPath "$p.tmp") { throw 'temp file left behind' }
    } finally {
        if (Test-Path -LiteralPath $script:ExportDir) { Remove-Item -Recurse -Force $script:ExportDir }
        $script:ExportDir = $prev
    }
}
```

- [ ] **Step 2: Run tests, verify fail**

`pwsh ./tests/run-tests.ps1` → new tests FAIL (functions missing).

- [ ] **Step 3: Implement** (append to `src/52-xlsx.ps1` before `#endregion`)

```powershell
function Install-SsmImportExcel {
    # Optional dependency: only the Excel report needs it. Mirrors Install-SsmModule.
    if (Get-Module -Name 'ImportExcel') { return $true }
    if (-not (Get-Module -ListAvailable -Name 'ImportExcel')) {
        $ok = Show-ConfirmModal -Title 'Module required' -Lines @(
            'Excel export needs the ImportExcel module (PowerShell Gallery).',
            'Install it now for the current user?',
            '',
            'Choose N to keep using CSV export instead.')
        if (-not $ok) { return $false }
        try {
            Invoke-OnMainBuffer {
                Write-Host 'Installing ImportExcel (CurrentUser)...' -ForegroundColor Yellow
                Install-Module -Name 'ImportExcel' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            }
            Write-SsmLog -Message 'ImportExcel installed (CurrentUser).' -Level OK
        } catch {
            Write-SsmErrorLog -Context 'ImportExcel install failed' -ErrorRecord $_
            Show-MsgModal -Title 'Install failed' -Lines @('Could not install ImportExcel. See the Log tab.', 'Use CSV export instead.') -Kind Error
            return $false
        }
    }
    try { Import-Module 'ImportExcel' -ErrorAction Stop; return $true }
    catch { Write-SsmErrorLog -Context 'ImportExcel import failed' -ErrorRecord $_; return $false }
}

function Get-ReportFileName {
    param([string]$TabName, [string]$SiteTag)
    $kind = if ($TabName -like 'OneDrive*') { 'OneDrive' } else { 'SharePoint' }
    return ("SSM_REPORT_{0}_{1}_{2}.xlsx" -f $kind, $SiteTag, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function ConvertTo-ReportRows {
    # Findings sheet rows. Richer than the CSV: title, sharing type, reach, ids.
    param([object[]]$Findings, [object[]]$Targets)
    $titleByUrl = @{}
    foreach ($t in @($Targets)) { if ($t) { $titleByUrl[[string]$t.Url] = [string]$t.Title } }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @($Findings)) {
        if (-not $f) { continue }
        $site = [string]$f.Site
        $title = if ($titleByUrl.ContainsKey($site) -and $titleByUrl[$site]) { $titleByUrl[$site] } else { ($site.TrimEnd('/') -split '/')[-1] }
        $created = ''
        $lc = $f.PSObject.Properties['LinkCreated']
        if ($lc -and $lc.Value) { [datetime]$d = [datetime]::MinValue; if ([datetime]::TryParse([string]$lc.Value, [ref]$d)) { $created = $d.ToString('yyyy-MM-dd') } }
        $reach = 1
        if ($f.PSObject.Properties['Reach'] -and $f.Reach) { $reach = [int]$f.Reach }
        $rows.Add([pscustomobject]@{
            'Site Title'    = $title
            'Site URL'      = $site
            'Location'      = [string]$f.Location
            'Category'      = [string]$f.Category
            'Sharing Type'  = if ($f.RemovalKind -eq 'Link') { 'Link' } else { 'Direct grant' }
            'Item Name'     = [string]$f.Name
            'Full Path'     = [string]$f.Path
            'Access'        = [string]$f.Access
            'Shared With'   = [string]$f.Principal
            'Link Created'  = $created
            'Reach (items)' = $reach
            'Revoke Status' = [string]$f.RevokeStatus
            'Link Id'       = [string]$f.LinkId
            'List Id'       = [string]$f.ListId
            'Item Id'       = [string]$f.ItemId
        })
    }
    return $rows.ToArray()
}

function Export-FindingsXlsx {
    # Three sheets: Summary (KPIs + exposure indicator), Findings (table), Sites (whole-tab only).
    # Temp file + Move-Item so a failed write never leaves a half workbook.
    param([object[]]$Findings, [object[]]$Targets, [string]$TabName, [string]$ScopeLabel, [string]$SiteTag, [bool]$IncludeSites)
    if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Path $script:ExportDir -Force | Out-Null }
    $path = Join-Path $script:ExportDir (Get-ReportFileName -TabName $TabName -SiteTag $SiteTag)
    $tmp = "$path.tmp"
    $sum = Get-FindingsSummary -Findings $Findings -Targets $Targets
    $exp = Get-ExposureScore -Findings $Findings -ItemsScanned $sum.ItemsScanned
    try {
        # --- Summary sheet as label/value rows ------------------------------
        $rows = [System.Collections.Generic.List[object]]::new()
        $add = { param($a, $b) $rows.Add([pscustomobject]@{ A = [string]$a; B = "$b" }) }
        & $add 'SharePoint Sharing Manager - Sharing Findings Report' ''
        & $add '' ''
        & $add 'Tool version' $script:Version
        & $add 'Tenant admin URL' $script:Auth.AdminUrl
        & $add 'Scope' $ScopeLabel
        & $add 'Generated (UTC)' ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))
        & $add 'Operator' $script:Conn.Account
        & $add '' ''
        & $add 'Total findings' $sum.Total
        & $add 'Sites/OneDrives affected' $sum.SitesAffected
        & $add 'Items scanned' $sum.ItemsScanned
        & $add 'Sharing links' $sum.Links
        & $add 'Direct grants' $sum.DirectGrants
        & $add 'Anonymous links' $sum.AnonymousLinks
        & $add 'Removed' $sum.Removed
        & $add 'Failed' $sum.Failed
        & $add 'Not attempted' $sum.NotAttempted
        & $add '' ''
        & $add 'Copilot Exposure Indicator (heuristic)' ''
        $scoreRow = $rows.Count + 1   # 1-based Excel row of the Score line
        if ($exp.Band -eq 'n/a') { & $add 'Score (0-100)' 'n/a - rescan to compute' } else { & $add 'Score (0-100)' $exp.Score }
        & $add 'Band' $exp.Band
        & $add 'Items overshared (%)' $exp.ExposedPercent
        & $add 'Method' 'Score = min(100, round(sum(weight x reach) / items scanned x 1000)). Reach = items a link/grant exposes.'
        & $add 'Weights' 'Anonymous link 5, EEEU 5, Everyone 5, Organization link 3, Guest link 2, Guest grant 2, other 1'
        & $add 'Limits' 'SSM heuristic, not a Microsoft metric. Hidden/excluded libraries are not counted. Folder sharing counts as 1 item. Inherited exposure is estimated via reach, not verified per item.'
        & $add '' ''
        foreach ($tbl in @(@('By category', 'ByCategory', 'Category'), @('By access', 'ByAccess', 'Access'), @('By revoke status', 'ByStatus', 'Status'))) {
            & $add $tbl[0] 'Count'
            foreach ($r in @($sum[$tbl[1]])) { & $add $r[$tbl[2]] $r.Count }
            & $add '' ''
        }
        & $add 'Top sites' 'Findings'
        foreach ($r in @($sum.TopSites)) { & $add ("{0} ({1})" -f $r.Title, $r.Site) $r.Count }

        $pkg = $rows.ToArray() | Export-Excel -Path $tmp -WorksheetName 'Summary' -NoHeader -AutoSize -PassThru
        $ws = $pkg.Workbook.Worksheets['Summary']
        $ws.Cells['A1'].Style.Font.Bold = $true; $ws.Cells['A1'].Style.Font.Size = 14
        $ws.Cells["A2:A$($rows.Count)"].Style.Font.Bold = $true
        $ws.Column(1).Width = 42; $ws.Column(2).Width = 90
        $ws.Cells["B$scoreRow"].Style.Fill.PatternType = 'Solid'
        $color = switch ($exp.Band) { 'Low' { 'LightGreen' } 'Medium' { 'Khaki' } 'High' { 'Orange' } 'Critical' { 'Tomato' } default { 'LightGray' } }
        $ws.Cells["B$scoreRow"].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromName($color))
        Close-ExcelPackage $pkg

        # --- Findings sheet ------------------------------------------------
        ConvertTo-ReportRows -Findings $Findings -Targets $Targets |
            Export-Excel -Path $tmp -WorksheetName 'Findings' -TableName 'Findings' -TableStyle Medium2 -AutoSize -FreezeTopRow -AutoFilter

        # --- Sites sheet (whole-tab export only) ---------------------------
        if ($IncludeSites) {
            $siteRows = foreach ($t in @($Targets)) {
                if (-not $t) { continue }
                $tf = @($t.Findings)
                $te = Get-ExposureScore -Findings $tf -ItemsScanned ([int]$t.ItemsScanned)
                [pscustomobject]@{
                    'Title' = [string]$t.Title; 'URL' = [string]$t.Url; 'Status' = [string]$t.Status
                    'Findings' = $tf.Count; 'Items Scanned' = [int]$t.ItemsScanned
                    'Exposure Score' = $te.Score; 'Band' = $te.Band
                }
            }
            @($siteRows) | Export-Excel -Path $tmp -WorksheetName 'Sites' -TableName 'Sites' -TableStyle Medium2 -AutoSize -FreezeTopRow -AutoFilter
        }
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
    Write-SsmLog -Message ("Excel report: {0}" -f $path)
    return $path
}
```

Notes for implementer:
- `Export-Excel -Path` with a `.tmp` extension: ImportExcel requires `.xlsx`. Use `$tmp = [IO.Path]::ChangeExtension($path, '.tmp.xlsx')` instead of `"$path.tmp"`, and adjust the test's leftover check to `"$($p -replace '\.xlsx$', '.tmp.xlsx')"`.
- `System.Drawing.Color` is available in PS7 via System.Drawing.Primitives (used by ImportExcel itself). If `FromName` fails on Linux CI, replace with `[System.Drawing.Color]::FromArgb(...)` literals: LightGreen `144,238,144`, Khaki `240,230,140`, Orange `255,165,0`, Tomato `255,99,71`, LightGray `211,211,211`.
- Run the writer test locally after `Install-Module ImportExcel -Scope CurrentUser`. CI lacks the module → test prints skipped.

- [ ] **Step 4: Run tests, verify pass; lint**

`pwsh ./tests/run-tests.ps1` → PASS (writer test passes locally, skips in CI). Lint clean.

- [ ] **Step 5: Commit**

```bash
git add src/52-xlsx.ps1 tests/xlsx.tests.ps1
git commit -m "feat: Excel report writer with Summary, Findings and Sites sheets"
```

---

### Task 4: Export menu modal and key wiring

**Files:**
- Modify: `src/20-modals.ps1` (append `Show-ExportModal` after `Show-ConfirmModal`, line ~232)
- Modify: `src/50-csv.ps1` (append `Invoke-ViewExport`)
- Modify: `src/75-key-dispatch.ps1:121`, `:229`
- Modify: `src/65-views.ps1:1406`, `:1411` (hints)
- Test: `tests/xlsx.tests.ps1` (append)

**Interfaces:**
- Consumes: `Export-ViewCsv -Tab`, `Install-SsmImportExcel`, `Export-FindingsXlsx`, `Get-TabFindings -Tab`, `Show-MsgModal`, `Write-ModalFrame`, `Read-ModalKey`, `ConvertTo-ModalLines`.
- Produces: `Show-ExportModal` → `'CSV' | 'XLSX' | $null`; `Get-ExportScope -Tab` → `@{ Findings; Targets; SiteTag; ScopeLabel; IncludeSites }`; `Invoke-ViewExport -Tab`.

- [ ] **Step 1: Write failing test** (append to `tests/xlsx.tests.ps1`)

```powershell
Invoke-SsmTest 'Export scope: target list = whole tab, findings view = current view' {
    $ta = New-Target -Url 'https://x/sites/a' -Title 'A'
    $ta.Findings = @((New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'OrgLink'), (New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'AnonymousLink'))
    $tb = New-Target -Url 'https://x/sites/b' -Title 'B'
    $tb.Findings = @(New-XlsxTestFinding -Site 'https://x/sites/b' -Key 'EEEU')
    $tab = @{ Kind='Targets'; Name='Sites'; Noun='sites'; Mode='Targets'; Items=@($ta,$tb); View=@($ta,$tb) }
    $s = Get-ExportScope -Tab $tab
    Assert-Equal 3 @($s.Findings).Count
    Assert-Equal 'ALL' $s.SiteTag
    Assert-Equal $true $s.IncludeSites
    Assert-Equal 'All sites' $s.ScopeLabel

    $tab['Mode'] = 'Findings'
    $tab['FTab'] = @{ Target = $ta; Items = @($ta.Findings); View = @($ta.Findings[0]); Filter='OrgLink'; Search='' }
    $s2 = Get-ExportScope -Tab $tab
    Assert-Equal 1 @($s2.Findings).Count
    Assert-Equal 'a' $s2.SiteTag
    Assert-Equal $false $s2.IncludeSites

    $tab['FTab'] = @{ Target = @{ Url = 'All sites' }; Items = @($ta.Findings + $tb.Findings); View = @($ta.Findings + $tb.Findings); Filter='All'; Search=''; Aggregate=$true }
    $s3 = Get-ExportScope -Tab $tab
    Assert-Equal 'ALL' $s3.SiteTag
    Assert-Equal $true $s3.IncludeSites
}
```

- [ ] **Step 2: Run, verify fail** → `Get-ExportScope` not recognized.

- [ ] **Step 3: Implement**

`src/20-modals.ps1`, after `Show-ConfirmModal`:

```powershell
function Show-ExportModal {
    # Export format picker. Returns 'CSV', 'XLSX' or $null (cancelled).
    $lines = ConvertTo-ModalLines -Width 64 -Lines @(
        'C   CSV      - current view, same columns as before',
        'X   Excel    - report workbook: Summary, Findings, Sites',
        '',
        @($script:T.Muted, 'Excel export needs the ImportExcel module (installed on demand).'))
    while ($true) {
        Write-Screen
        [void](Write-ModalFrame -Title 'Export' -BodyLines $lines -FooterHint 'C csv   X excel   Esc cancel' -BorderStyle $script:T.Border)
        $k = Read-ModalKey
        if ($k.Key -eq 'Escape') { $script:UI.Dirty = $true; return $null }
        if (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'C') { $script:UI.Dirty = $true; return $null }
        switch ([char]::ToUpper($k.KeyChar)) {
            'C' { $script:UI.Dirty = $true; return 'CSV' }
            'X' { $script:UI.Dirty = $true; return 'XLSX' }
        }
    }
}
```

`src/50-csv.ps1`, append before `#endregion`:

```powershell
function Get-ExportScope {
    # What an Excel report covers, following the current view.
    param($Tab)
    $inFindings = ($Tab['Mode'] -eq 'Findings' -and $Tab['FTab'])
    if ($inFindings) {
        $ft = $Tab['FTab']
        $agg = [bool]$ft['Aggregate']
        $tag = if ($agg) { 'ALL' } else { ([string]$ft['Target'].Url).TrimEnd('/') -split '/' | Select-Object -Last 1 }
        $label = if ($agg) { 'All ' + $Tab['Noun'] } else { [string]$ft['Target'].Url }
        return @{ Findings = @($ft['View']); Targets = @($Tab['Items']); SiteTag = $tag; ScopeLabel = $label; IncludeSites = $agg }
    }
    return @{ Findings = @(Get-TabFindings -Tab $Tab); Targets = @($Tab['Items']); SiteTag = 'ALL'; ScopeLabel = ('All ' + $Tab['Noun']); IncludeSites = $true }
}

function Invoke-ViewExport {
    # E key: pick CSV (unchanged path) or Excel report.
    param($Tab)
    $choice = Show-ExportModal
    if ($choice -eq 'CSV') { Export-ViewCsv -Tab $Tab; return }
    if ($choice -ne 'XLSX') { return }
    $scope = Get-ExportScope -Tab $Tab
    if (@($scope.Findings).Count -eq 0) { Show-MsgModal -Title 'Export' -Lines @('No findings to report. Scan targets first (S or X).'); return }
    if (-not (Install-SsmImportExcel)) { return }
    try {
        $path = Export-FindingsXlsx -Findings $scope.Findings -Targets $scope.Targets -TabName $Tab['Name'] -ScopeLabel $scope.ScopeLabel -SiteTag $scope.SiteTag -IncludeSites $scope.IncludeSites
        Show-MsgModal -Title 'Exported' -Lines @('Excel report written to:', $path)
    } catch {
        Write-SsmErrorLog -Context 'Excel report export failed' -ErrorRecord $_
        Show-MsgModal -Title 'Export failed' -Lines @($_.Exception.Message, 'See the Log tab. CSV export is still available.') -Kind Error
    }
}
```

`src/75-key-dispatch.ps1` line 121 and line 229: change `'E' { Export-ViewCsv -Tab $Tab; return }` to `'E' { Invoke-ViewExport -Tab $Tab; return }` (both).

`src/65-views.ps1` hints lines 1406 and 1411: `@('E','export')` → `@('E','export...')` (both).

- [ ] **Step 4: Run tests, lint, manual TUI smoke**

`pwsh ./tests/run-tests.ps1` → PASS. Lint clean.
Manual (per CONTRIBUTING tmux recipe): open Sites tab with cached findings, press `E` → modal; `C` → CSV as before; `X` → install prompt if needed, then "Exported" modal with `.xlsx` path; open the file, confirm three sheets and coloured score cell. In findings view with a filter active, `X` → Findings sheet holds only filtered rows, no Sites sheet.

- [ ] **Step 5: Commit**

```bash
git add src/20-modals.ps1 src/50-csv.ps1 src/75-key-dispatch.ps1 src/65-views.ps1 tests/xlsx.tests.ps1
git commit -m "feat: E opens export menu with CSV or Excel report"
```

---

### Task 5: Documentation and wiki sync

**Files:**
- Modify: `CHANGELOG.md:3` (Unreleased), `README.md:69`, `README.md:172-174`, `CONTRIBUTING.md:13-17`
- Modify: `wiki/Scanning-and-Revoking.md` (key tables lines 56, 67; Evidence section line 76), `wiki/FAQ-and-Troubleshooting.md:59`, `wiki/Getting-Started.md:29-33`

- [ ] **Step 1: CHANGELOG** under `## [Unreleased]`:

```markdown
- New: Excel report export. `E` on the Sites/OneDrives tab and in the findings
  view now opens an export menu: `C` writes the CSV as before, `X` writes
  `SSM-Exports/SSM_REPORT_<SharePoint|OneDrive>_<site|ALL>_<timestamp>.xlsx`
  with a Summary sheet (KPIs, counts by category/access/status, top sites),
  a Findings sheet (site title, full path, sharing type, reach, ids) and,
  for whole-tab exports, a Sites sheet.
- New: Copilot Exposure Indicator (heuristic) on the Summary and Sites sheets:
  weighted overshared items relative to items scanned, 0-100 with
  Low/Medium/High/Critical bands. Scans now record items scanned per target
  and reach per finding; results restored from an older cache show `n/a`
  until rescanned.
- New optional dependency: `ImportExcel` (PowerShell Gallery), installed on
  demand (CurrentUser) the first time Excel export is chosen. Declining keeps
  CSV export available.
```

- [ ] **Step 2: README**

Line 69: `- **CSV export** of any view; CSV import of target URLs` →
`- **CSV export** of any view, **Excel report** (`E` → `X`) with summary, detailed findings and a heuristic Copilot exposure score; CSV import of target URLs`

Lines 172-174:
```markdown
### Modules (installed on demand, CurrentUser scope)

- [`PnP.PowerShell`](https://www.powershellgallery.com/packages/PnP.PowerShell) v3 - required
- [`ImportExcel`](https://www.powershellgallery.com/packages/ImportExcel) - optional, only for the Excel report export; prompted on first use
```

- [ ] **Step 3: CONTRIBUTING** rule 1, replace `no external module dependencies beyond \`PnP.PowerShell\`.` with:
`no external module dependencies beyond \`PnP.PowerShell\` and the optional \`ImportExcel\` (installed on demand, used only by \`src/52-xlsx.ps1\` for the Excel report; every other feature must work without it).`

- [ ] **Step 4: wiki/Scanning-and-Revoking.md**

Both key tables: `| \`E\` | Export |` → `| \`E\` | Export menu: \`C\` CSV, \`X\` Excel report |`.

After the Evidence bullet list add:

```markdown
### Excel report (`E` → `X`)

Writes `SSM-Exports/SSM_REPORT_<SharePoint|OneDrive>_<site|ALL>_<timestamp>.xlsx`. Needs the `ImportExcel` module; you are asked to install it (CurrentUser) the first time. Scope follows the view: from the target list it covers every scanned target in the tab; from a findings view it covers the rows currently shown (filter and search applied).

| Sheet | Content |
|---|---|
| Summary | Tool version, tenant, scope, generated time, operator; totals (findings, sites affected, items scanned, links vs direct grants, anonymous links, removed/failed/not attempted); Copilot Exposure Indicator; counts by category, access and revoke status; top 10 sites |
| Findings | One row per finding: Site Title, Site URL, Location, Category, Sharing Type, Item Name, Full Path, Access, Shared With, Link Created, Reach (items), Revoke Status, Link Id, List Id, Item Id |
| Sites | Whole-tab exports only: Title, URL, Status, Findings, Items Scanned, Exposure Score, Band |

#### Copilot Exposure Indicator

A heuristic, not a Microsoft metric. Each finding is weighted by how wide its audience is (Anonymous link 5, EEEU 5, Everyone 5, Organization link 3, Guest link 2, Guest grant 2, other 1) and multiplied by its *reach*: 1 for a file or folder, the library item count for a library-level grant, the site item count for a web-level grant.

`Score = min(100, round(sum(weight × reach) / items scanned × 1000))`, banded Low (0-10), Medium (11-40), High (41-70), Critical (71-100). The raw "items overshared %" is shown next to it.

Limits: hidden/excluded libraries are not in the denominator; folder sharing counts as one item; inherited exposure is estimated via reach, not verified per item. Results restored from a cache written before this feature show `n/a` until the target is rescanned.
```

- [ ] **Step 5: wiki/FAQ-and-Troubleshooting.md** line 59 table row for `SSM-Exports/`: append `, Excel reports (\`SSM_REPORT_*.xlsx\`)`. Add a Q under the same section:

```markdown
## Excel export asks to install ImportExcel - is that required?

No. `ImportExcel` is only used for the Excel report (`E` → `X`) and is installed for the current user on demand. Choose N to keep using CSV export. Offline machines can install it beforehand with `Install-Module ImportExcel -Scope CurrentUser`.
```

- [ ] **Step 6: wiki/Getting-Started.md** lines 29-33: where `E` export is mentioned, add "(`C` for CSV, `X` for an Excel report)".

- [ ] **Step 7: Commit**

```bash
git add CHANGELOG.md README.md CONTRIBUTING.md wiki/Scanning-and-Revoking.md wiki/FAQ-and-Troubleshooting.md wiki/Getting-Started.md
git commit -m "docs: Excel report export, exposure indicator, optional ImportExcel"
```

Wiki publish (after merge): clone `https://github.com/mardahl/SharePoint-Sharing-Manager.wiki.git` to `wiki-remote`, copy changed `wiki/*.md`, commit, push.
