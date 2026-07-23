# Scan Cache, Bulk Revocation, and Scan-All Resume — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist scan results to disk, add bulk revocation across many drives, and make a full tenant scan resumable so an interrupted run continues instead of restarting.

**Architecture:** A new pure-logic file `src/70-cache.ps1` serializes the two Targets tabs to `SSM-Cache/session.json` and restores them on demand. An aggregate findings view (a mode toggle inside the existing Targets tab, no new tab) flattens every finding across drives; a shared group-by-site bulk-revoke routine reuses the existing `Invoke-Revoke`. A scan-all action scans every not-yet-scanned target, saving the cache after each one.

**Tech Stack:** PowerShell 7.4+, PnP.PowerShell v3 (single connection at a time), the repo's assert-based test runner (`tests/run-tests.ps1`), PSScriptAnalyzer + parse-check CI.

## Global Constraints

- PowerShell 7.4+; `Set-StrictMode -Version 2.0`; `$ErrorActionPreference = 'Stop'`.
- PnP.PowerShell is the only external dependency. No new dependencies.
- Source files are numbered region files under `src/`, dot-sourced in name order by `SharePoint-Sharing-Manager.ps1`. Load order matters: `00` before `70`.
- Pure-logic (PnP-free) helpers go in files dot-sourced by `tests/run-tests.ps1` and get assert tests. PnP/console/IO-bound code is not unit-tested (matches the repo's split), but must pass the parse check and PSScriptAnalyzer (Error + Warning, clean).
- TUI code calls cross-file functions through `if (Get-Command X -ErrorAction SilentlyContinue)` guards when the callee lives in a file not loaded by the test runner (existing pattern, e.g. `src/45-targets.ps1:41`).
- Findings are `pscustomobject` records with properties: `Site, Location, Name, CategoryKey, Category, Access, Principal, Path, RemovalKind, LinkId, ListId, ItemId, PrincipalId, RevokeStatus, Selected`. Every finding already carries its `Site` (source drive URL).
- Target objects are hashtables: `Url, Title, Template, Status, FindingCount, Findings, Selected` (`New-Target`, `src/45-targets.ps1`).
- Verification commands (run from repo root):
  - Tests: `pwsh -NoProfile ./tests/run-tests.ps1`
  - Parse check: `pwsh -NoProfile -Command "$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./src/<FILE>).Path,[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object{Write-Host $_.Message};throw 'parse fail'}else{'Parse OK'}"`
  - Lint: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error,Warning"`

---

### Task 1: Cache serialization (pure)

Create the serialization helpers and register the new file with the test runner. Pure functions only — no disk IO yet.

**Files:**
- Create: `src/70-cache.ps1`
- Modify: `tests/run-tests.ps1:13` (add `70-cache` to the dot-source list)
- Test: `tests/cache.tests.ps1`

**Interfaces:**
- Consumes: `$script:Version` (string, may be null in tests), the two Targets tab hashtables (`Kind='Targets'`, keys `Name`, `Categories`, `Items`).
- Produces:
  - `ConvertTo-SsmCacheObject -Tabs <array>` → `[ordered]` object `{ Version, SavedAt, Tabs: [ { Name, Categories:[string], Items:[ {Url,Title,Template,Status,FindingCount,Findings:[]} ] } ] }`. Only `Kind='Targets'` tabs are included.
  - `ConvertFrom-SsmCacheObject -Cache <parsed> -Tabs <array>` → void; populates matching (by `Name`) Targets tabs in place: sets `Categories` (ArrayList), rebuilds `Items` as target hashtables with `Selected=$false`, each finding's `Selected` reset to `$false`, and `Loaded=$true`.

- [ ] **Step 1: Write the failing test**

Create `tests/cache.tests.ps1`:

```powershell
Invoke-SsmTest 'Cache round-trips a target and finding' {
    $script:Version = '9.9.9'
    $finding = [pscustomobject]@{
        Site='https://x/personal/a'; Location='File'; Name='q.xlsx'
        CategoryKey='OrgLink'; Category='Organization link'; Access='View'
        Principal='People in your organization'; Path='/p/q.xlsx'; RemovalKind='Link'
        LinkId='L1'; ListId='LI1'; ItemId=5; PrincipalId=$null
        RevokeStatus='NotAttempted'; Selected=$true
    }
    $srcTabs = @(
        @{ Kind='Targets'; Name='OneDrives'; Categories=[System.Collections.ArrayList]@('OrgLink')
           Items=@(@{ Url='https://x/personal/a'; Title='a'; Template='SPSPERS'
                      Status='Findings'; FindingCount=1; Findings=@($finding); Selected=$true }) }
    )
    $obj  = ConvertTo-SsmCacheObject -Tabs $srcTabs
    $json = $obj | ConvertTo-Json -Depth 8
    $back = $json | ConvertFrom-Json

    $dstTabs = @(
        @{ Kind='Targets'; Name='OneDrives'; Categories=[System.Collections.ArrayList]@(); Items=@(); Loaded=$false }
    )
    ConvertFrom-SsmCacheObject -Cache $back -Tabs $dstTabs

    Assert-Equal 1 @($dstTabs[0].Items).Count
    Assert-Equal 'https://x/personal/a' $dstTabs[0].Items[0].Url
    Assert-Equal 'Findings' $dstTabs[0].Items[0].Status
    Assert-Equal 1 @($dstTabs[0].Items[0].Findings).Count
    Assert-Equal 'q.xlsx' $dstTabs[0].Items[0].Findings[0].Name
    Assert-Equal 'False' $dstTabs[0].Items[0].Findings[0].Selected   # reset on restore
    Assert-Equal 'True'  $dstTabs[0].Loaded
    Assert-Equal 'OrgLink' $dstTabs[0].Categories[0]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — `ConvertTo-SsmCacheObject` not recognized (file not created / not dot-sourced yet).

- [ ] **Step 3: Register the file with the test runner**

In `tests/run-tests.ps1`, line 13, add `'70-cache'` to the array (keep numeric order):

```powershell
foreach ($f in @('25-config','30-connections','35-scan-engine','40-revoke','45-targets','50-csv','55-tenant-actions','70-cache','75-key-dispatch')) {
```

- [ ] **Step 4: Write minimal implementation**

Create `src/70-cache.ps1`:

```powershell
# ============================================================================
#region Session cache - serialization (pure)
# ============================================================================

function ConvertTo-SsmCacheObject {
    # Snapshot the Targets tabs into a plain object ready for ConvertTo-Json.
    param($Tabs)
    $tabsOut = @()
    foreach ($tab in @($Tabs)) {
        if ($tab['Kind'] -ne 'Targets') { continue }
        $items = @()
        foreach ($it in @($tab['Items'])) {
            $items += [ordered]@{
                Url = $it.Url; Title = $it.Title; Template = $it.Template
                Status = $it.Status; FindingCount = $it.FindingCount
                Findings = @($it.Findings)
            }
        }
        $tabsOut += [ordered]@{
            Name = $tab['Name']; Categories = @($tab['Categories']); Items = $items
        }
    }
    return [ordered]@{
        Version = $script:Version
        SavedAt = (Get-Date).ToString('o')
        Tabs    = $tabsOut
    }
}

function ConvertFrom-SsmCacheObject {
    # Load a parsed cache object into matching (by Name) Targets tabs in place.
    param($Cache, $Tabs)
    foreach ($ct in @($Cache.Tabs)) {
        $tab = @($Tabs) | Where-Object { $_['Kind'] -eq 'Targets' -and $_['Name'] -eq $ct.Name } | Select-Object -First 1
        if (-not $tab) { continue }
        $tab['Categories'] = [System.Collections.ArrayList]@($ct.Categories)
        $items = @()
        foreach ($ci in @($ct.Items)) {
            $findings = @()
            foreach ($f in @($ci.Findings)) {
                if (-not $f) { continue }
                $f | Add-Member -NotePropertyName Selected -NotePropertyValue $false -Force
                $findings += $f
            }
            $items += @{
                Url = $ci.Url; Title = $ci.Title; Template = $ci.Template
                Status = $ci.Status; FindingCount = $ci.FindingCount
                Findings = $findings; Selected = $false
            }
        }
        $tab['Items'] = @($items)
        $tab['Loaded'] = $true
    }
}

#endregion
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS — `Cache round-trips a target and finding`, and all pre-existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/70-cache.ps1 tests/cache.tests.ps1 tests/run-tests.ps1
git commit -m "feat: session cache serialization for Targets tabs"
```

---

### Task 2: Cache disk IO — save, availability, restore

Add the path constants and the file read/write wrappers around Task 1's serializers, with an atomic write and a sensitivity warning file.

**Files:**
- Modify: `src/00-globals.ps1` (after line 16, add cache path/warning constants)
- Modify: `src/70-cache.ps1` (append IO region)
- Test: `tests/cache.tests.ps1` (append)

**Interfaces:**
- Consumes: `ConvertTo-SsmCacheObject`, `ConvertFrom-SsmCacheObject` (Task 1); `$script:Root`.
- Produces:
  - `$script:CacheDir` (string), `$script:CacheFile` (string), `$script:CacheWarning` (string).
  - `Save-SsmCache` → void; creates `SSM-Cache/` + `README.txt` on first use, writes `session.json` atomically (temp then move). Best-effort: logs a WARN and returns on failure, never throws.
  - `Test-SsmCacheAvailable` → `$null` if no readable cache, else `[pscustomobject]@{ Count=<int total targets>; SavedAt=<string> }`.
  - `Restore-SsmCache` → `[bool]`; loads `session.json` into `$script:Tabs`, refreshes views via `Update-TabView` (guarded), returns `$true` on success.

- [ ] **Step 1: Write the failing test**

Append to `tests/cache.tests.ps1`:

```powershell
Invoke-SsmTest 'Save then restore via disk round-trips' {
    $script:Version = '9.9.9'
    $script:CacheDir  = Join-Path ([IO.Path]::GetTempPath()) ("ssmcache-{0}" -f [guid]::NewGuid())
    $script:CacheFile = Join-Path $script:CacheDir 'session.json'
    $script:CacheWarning = 'test-warning'
    $script:Tabs = @(
        @{ Kind='Targets'; Name='OneDrives'; Categories=[System.Collections.ArrayList]@('OrgLink')
           Items=@(@{ Url='https://x/personal/a'; Title='a'; Template='SPSPERS'
                      Status='Clean'; FindingCount=0; Findings=@(); Selected=$false }) }
    )
    Save-SsmCache
    Assert-Equal 'True' ([string](Test-Path -LiteralPath $script:CacheFile))

    $avail = Test-SsmCacheAvailable
    Assert-Equal 1 $avail.Count

    $script:Tabs = @(
        @{ Kind='Targets'; Name='OneDrives'; Categories=[System.Collections.ArrayList]@(); Items=@(); Loaded=$false }
    )
    $ok = Restore-SsmCache
    Assert-Equal 'True' ([string]$ok)
    Assert-Equal 'https://x/personal/a' $script:Tabs[0].Items[0].Url
    Assert-Equal 'Clean' $script:Tabs[0].Items[0].Status

    Remove-Item -LiteralPath $script:CacheDir -Recurse -Force -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — `Save-SsmCache` not recognized.

- [ ] **Step 3: Add path constants to globals**

In `src/00-globals.ps1`, immediately after line 16 (`$script:Spinner = $null`), add:

```powershell
$script:CacheDir     = Join-Path $script:Root 'SSM-Cache'
$script:CacheFile    = Join-Path $script:CacheDir 'session.json'
$script:CacheWarning = @(
    'This directory holds cached SharePoint/OneDrive scan results.'
    'session.json contains directory data - site paths, principal names,'
    'and guest email addresses. Treat it as sensitive; it is protected by'
    'filesystem permissions only, not encryption. Delete it when no longer needed.'
) -join [Environment]::NewLine
```

Also add a restore-info slot to the `$script:UI` hashtable (inside the existing `@{ ... }`, add a line before the closing brace, e.g. after `LogScroll  = 0`):

```powershell
    RestoreInfo = $null    # set at startup by Test-SsmCacheAvailable
```

- [ ] **Step 4: Append the IO region to `src/70-cache.ps1`**

Add before the file's final `#endregion` is fine, or as a new region at the end:

```powershell
# ============================================================================
#region Session cache - disk IO
# ============================================================================

function Save-SsmCache {
    # Persist the Targets tabs to session.json (atomic). Best-effort: never throws.
    try {
        if (-not (Test-Path -LiteralPath $script:CacheDir)) {
            New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:CacheDir 'README.txt') -Value $script:CacheWarning -Encoding UTF8
        }
        $json = ConvertTo-SsmCacheObject -Tabs $script:Tabs | ConvertTo-Json -Depth 8
        $tmp  = $script:CacheFile + '.tmp'
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:CacheFile -Force
    } catch {
        Write-SsmLog -Message ("Cache save failed: {0}" -f $_.Exception.Message) -Level WARN
    }
}

function Test-SsmCacheAvailable {
    # Return { Count, SavedAt } when a readable cache exists, else $null.
    if (-not (Test-Path -LiteralPath $script:CacheFile)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $script:CacheFile -Raw | ConvertFrom-Json
        $count = 0
        foreach ($ct in @($cache.Tabs)) { $count += @($ct.Items).Count }
        return [pscustomobject]@{ Count = $count; SavedAt = [string]$cache.SavedAt }
    } catch { return $null }
}

function Restore-SsmCache {
    # Load session.json into $script:Tabs. Returns $true on success.
    if (-not (Test-Path -LiteralPath $script:CacheFile)) { return $false }
    try {
        $cache = Get-Content -LiteralPath $script:CacheFile -Raw | ConvertFrom-Json
        ConvertFrom-SsmCacheObject -Cache $cache -Tabs $script:Tabs
        if (Get-Command Update-TabView -ErrorAction SilentlyContinue) {
            foreach ($tab in @($script:Tabs)) { if ($tab['Kind'] -eq 'Targets') { Update-TabView -Tab $tab } }
        }
        Write-SsmLog -Message 'Restored scan cache from disk.' -Level OK
        return $true
    } catch {
        Write-SsmLog -Message ("Cache restore failed: {0}" -f $_.Exception.Message) -Level WARN
        return $false
    }
}

#endregion
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS — both cache tests and all pre-existing tests.

- [ ] **Step 6: Parse + lint the changed src files**

Run parse check for `70-cache.ps1` and `00-globals.ps1`, then:
Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error,Warning"`
Expected: no output (clean).

- [ ] **Step 7: Commit**

```bash
git add src/00-globals.ps1 src/70-cache.ps1 tests/cache.tests.ps1
git commit -m "feat: atomic session cache save/restore with availability check"
```

---

### Task 3: Aggregate-findings and group-by-site helpers (pure)

Two small pure helpers that back the aggregate view and bulk revoke.

**Files:**
- Modify: `src/45-targets.ps1` (append `Get-TabFindings`)
- Modify: `src/40-revoke.ps1` (append `Group-FindingsBySite` in the pure region)
- Test: `tests/targets.tests.ps1` (append), `tests/revoke.tests.ps1` (append)

**Interfaces:**
- Produces:
  - `Get-TabFindings -Tab <hashtable>` → flat array of every finding object across `$Tab['Items']` (only targets that have findings contribute). Returns the same object references (so `RevokeStatus` updates propagate to the targets).
  - `Group-FindingsBySite -Findings <array>` → array of `Group-Object` groups keyed by the finding `Site` property (`.Name` = site URL, `.Group` = that site's findings).

- [ ] **Step 1: Write the failing tests**

Append to `tests/targets.tests.ps1`:

```powershell
Invoke-SsmTest 'Get-TabFindings flattens findings across targets' {
    $tab = @{ Items = @(
        @{ Url='https://x/a'; Findings=@([pscustomobject]@{ Site='https://x/a'; Name='f1' }) },
        @{ Url='https://x/b'; Findings=@() },
        @{ Url='https://x/c'; Findings=@(
            [pscustomobject]@{ Site='https://x/c'; Name='f2' },
            [pscustomobject]@{ Site='https://x/c'; Name='f3' }) }
    ) }
    $all = @(Get-TabFindings -Tab $tab)
    Assert-Equal 3 $all.Count
}
```

Append to `tests/revoke.tests.ps1`:

```powershell
Invoke-SsmTest 'Group-FindingsBySite groups by Site' {
    $f = @(
        [pscustomobject]@{ Site='https://x/a'; Name='f1' },
        [pscustomobject]@{ Site='https://x/b'; Name='f2' },
        [pscustomobject]@{ Site='https://x/a'; Name='f3' }
    )
    $groups = @(Group-FindingsBySite -Findings $f)
    Assert-Equal 2 $groups.Count
    $a = $groups | Where-Object { $_.Name -eq 'https://x/a' }
    Assert-Equal 2 @($a.Group).Count
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: FAIL — `Get-TabFindings` / `Group-FindingsBySite` not recognized.

- [ ] **Step 3: Implement `Get-TabFindings`**

Append to `src/45-targets.ps1` before the final `#endregion`:

```powershell
function Get-TabFindings {
    # Every finding across all targets in a tab (same object references).
    param($Tab)
    $out = @()
    foreach ($it in @($Tab['Items'])) {
        if (@($it.Findings).Count -gt 0) { $out += @($it.Findings) }
    }
    return $out
}
```

- [ ] **Step 4: Implement `Group-FindingsBySite`**

Append to the pure region of `src/40-revoke.ps1` (after `Get-RevokeOrder`, before the `#endregion` that closes the ordering region):

```powershell
function Group-FindingsBySite {
    # Group findings by their source Site URL for per-site bulk revocation.
    param($Findings)
    return @(@($Findings) | Group-Object -Property Site)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: PASS — both new tests plus all pre-existing.

- [ ] **Step 6: Commit**

```bash
git add src/45-targets.ps1 src/40-revoke.ps1 tests/targets.tests.ps1 tests/revoke.tests.ps1
git commit -m "feat: aggregate-findings and group-by-site helpers"
```

---

### Task 4: Shared bulk-revoke routine and target-status recompute

The PnP-bound routine that revokes a set of findings grouped by site, saving the cache after each site. Not unit-tested (connects live); verified by parse + lint + manual smoke. The grouping it relies on is already tested (Task 3).

**Files:**
- Modify: `src/65-views.ps1` (add `Update-TabTargetStatuses` and `Invoke-BulkRevoke`)

**Interfaces:**
- Consumes: `Group-FindingsBySite` (Task 3), `Connect-SsmSite`, `Invoke-Revoke`, `Export-FindingsCsv`, `Save-SsmCache` (Task 2), `Show-MsgModal`, `Show-TypedConfirmModal`, `Show-ReportModal`, `Update-TabView`.
- Produces:
  - `Update-TabTargetStatuses -Tab <hashtable>` → void; for each target, recomputes `FindingCount` (findings whose `RevokeStatus` is neither `Removed` nor `AlreadyRevoked`) and sets `Status='Revoked'` when a scanned target drops to 0 findings.
  - `Invoke-BulkRevoke -Findings <array> -Tab <hashtable>` → void; confirms, loops sites (connect → `Invoke-Revoke` → REVOKED CSV → `Save-SsmCache`), then recomputes statuses and reports.

- [ ] **Step 1: Implement the helpers**

Add to `src/65-views.ps1` (near the other revoke code, after `Invoke-FindingsRevoke`):

```powershell
function Update-TabTargetStatuses {
    # Recompute per-target FindingCount/Status from live RevokeStatus values.
    param($Tab)
    foreach ($it in @($Tab['Items'])) {
        $remaining = @(@($it.Findings) | Where-Object { $_.RevokeStatus -ne 'Removed' -and $_.RevokeStatus -ne 'AlreadyRevoked' })
        $it.FindingCount = $remaining.Count
        if (@($it.Findings).Count -gt 0 -and $remaining.Count -eq 0) { $it.Status = 'Revoked' }
    }
}

function Invoke-BulkRevoke {
    # Revoke an explicit set of findings, grouped by site, with one typed
    # confirmation and a per-site connect/revoke/save loop.
    param($Findings, $Tab)
    $sel = @($Findings)
    if ($sel.Count -eq 0) { Show-MsgModal -Title 'Revoke' -Lines @('Nothing selected.'); return }
    $groups = Group-FindingsBySite -Findings $sel
    $lines  = @(("Remove {0} link(s)/grant(s) across {1} site(s):" -f $sel.Count, $groups.Count), '')
    foreach ($g in $groups) { $lines += ("  {0}: {1}" -f $g.Name, @($g.Group).Count) }
    $lines += @('', 'Files and folders are never deleted. This cannot be undone.')
    if (-not (Show-TypedConfirmModal -Title 'Bulk revoke sharing' -Word 'REVOKE' -Lines $lines)) { return }

    $totalRemoved = 0; $siteReport = @()
    foreach ($g in $groups) {
        if (-not (Connect-SsmSite -Url $g.Name)) {
            $siteReport += ("{0}: connect failed" -f $g.Name); continue
        }
        $removed = Invoke-Revoke -Findings @($g.Group)
        [void](Export-FindingsCsv -Findings @($g.Group) -SiteUrl $g.Name -Phase 'REVOKED')
        $totalRemoved += $removed
        $siteReport += ("{0}: removed {1} of {2}" -f $g.Name, $removed, @($g.Group).Count)
        if (Get-Command Save-SsmCache -ErrorAction SilentlyContinue) { Save-SsmCache }
    }
    Update-TabTargetStatuses -Tab $Tab
    Show-ReportModal -Title 'Bulk revoke complete' -Lines (@(("Removed {0} of {1} across {2} site(s)." -f $totalRemoved, $sel.Count, $groups.Count), '') + $siteReport)
    Update-TabView -Tab $Tab
}
```

- [ ] **Step 2: Parse check**

Run the parse check for `src/65-views.ps1`.
Expected: `Parse OK`.

- [ ] **Step 3: Lint + tests**

Run: `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error,Warning"`
Expected: clean.
Run: `pwsh -NoProfile ./tests/run-tests.ps1`
Expected: all pass (no behavior change to tested code).

- [ ] **Step 4: Commit**

```bash
git add src/65-views.ps1
git commit -m "feat: shared group-by-site bulk revoke routine"
```

---

### Task 5: Aggregate findings view + `G` key

Add the aggregate mode (a Findings mode whose items span every drive), a Site column in the findings view when aggregate, and route aggregate `R` to bulk revoke.

**Files:**
- Modify: `src/65-views.ps1` (`Enter-AggregateMode`; `Get-FindingsLayout`; `Add-FindingsView`; `Invoke-FindingsRevoke`)
- Modify: `src/75-key-dispatch.ps1` (`Invoke-TargetsKey`: `G`; `Invoke-FindingsKey` already routes `R` to `Invoke-FindingsRevoke`)

**Interfaces:**
- Consumes: `Get-TabFindings` (Task 3), `Invoke-BulkRevoke` (Task 4), `Update-FindingsView`, `Show-MsgModal`.
- Produces: `Enter-AggregateMode -Tab <hashtable>` → void; sets `$Tab['Mode']='Findings'` with `$Tab['FTab']` carrying `Aggregate=$true`, `Target=@{Url=('All '+Noun)}`, `Items` = all findings.

- [ ] **Step 1: Implement `Enter-AggregateMode`**

Add to `src/65-views.ps1` (after `Enter-FindingsMode`):

```powershell
function Enter-AggregateMode {
    # Findings mode spanning every scanned target in the tab.
    param($Tab)
    $all = @(Get-TabFindings -Tab $Tab)
    if ($all.Count -eq 0) { Show-MsgModal -Title 'All findings' -Lines @('No findings yet. Scan targets first (S or X).'); return }
    $Tab['Mode'] = 'Findings'
    $Tab['FTab'] = @{ Target = @{ Url = ('All ' + $Tab['Noun']) }; Items = $all; View = @(); Cursor = 0; Scroll = 0; Search = ''; Filter = 'All'; Aggregate = $true }
    Update-FindingsView -Tab $Tab
}
```

- [ ] **Step 2: Add a Site column to the findings view when aggregate**

In `src/65-views.ps1`, replace `Get-FindingsLayout` so it accepts an aggregate flag and reserves a Site column:

```powershell
function Get-FindingsLayout {
    param([int]$W, [bool]$Aggregate = $false)
    $siteW = if ($Aggregate) { 22 } else { 0 }
    $siteFixed = if ($Aggregate) { $siteW + 2 } else { 0 }
    # ' ' sel(3) ' ' [Site(22) '  '] Category(20) '  ' Loc(7) '  ' Name(flex 40%) '  ' Principal(flex 60%) '  ' Status(12)
    $fixed = 1 + 3 + 1 + $siteFixed + 20 + 2 + 7 + 2 + 2 + 2 + 12
    $flex = $W - $fixed - 1
    if ($flex -lt 20) { $flex = 20 }
    $nameW = [int]($flex * 0.4)
    $principalW = $flex - $nameW
    return @{ Site = $siteW; Category = 20; Loc = 7; Name = $nameW; Principal = $principalW; Status = 12 }
}
```

Then in `Add-FindingsView`, read the aggregate flag and include the Site cell. Change the layout call and header, and each row. Replace the layout/header block:

```powershell
    $agg = [bool]$ft['Aggregate']
    $col = Get-FindingsLayout -W $W -Aggregate $agg
    $siteHead = if ($agg) { (Get-PadCell 'Site' $col.Site) + '  ' } else { '' }
    $head = ' ' + (Get-PadCell 'sel' 3) + ' ' + $siteHead + (Get-PadCell 'Category' $col.Category) + '  ' + (Get-PadCell 'Loc' $col.Loc) + '  ' + (Get-PadCell 'Name' $col.Name) + '  ' + (Get-PadCell 'Principal' $col.Principal) + '  ' + (Get-PadCell 'Status' $col.Status)
    Add-FrameLine -Sb $Sb -Row 4 -Content ($t.ColHead + $head)
```

And in the per-row rendering, insert the Site cell right after the checkbox block and before the Category cell. Find the line `$line += (Get-PadCell $item.Category $col.Category) + '  '` and prepend the site cell:

```powershell
        if ($agg) {
            $siteTag = ($item.Site.TrimEnd('/') -split '/')[-1]
            $line += (Get-PadCell $siteTag $col.Site) + '  '
        }
        $line += (Get-PadCell $item.Category $col.Category) + '  '
```

- [ ] **Step 3: Route aggregate revoke to bulk**

In `src/65-views.ps1`, at the top of `Invoke-FindingsRevoke`, add the aggregate branch:

```powershell
function Invoke-FindingsRevoke {
    param($Tab)
    $ft = $Tab['FTab']
    if ($ft['Aggregate']) {
        Invoke-BulkRevoke -Findings @($ft['Items'] | Where-Object { $_.Selected }) -Tab $Tab
        Update-FindingsView -Tab $Tab
        return
    }
    $target = $ft['Target']
    # ... existing single-target body unchanged ...
```

(Keep the rest of the existing function exactly as-is below the new branch.)

- [ ] **Step 4: Bind `G` in the target list**

In `src/75-key-dispatch.ps1`, in `Invoke-TargetsKey`, add to the `switch ([char]::ToUpper($K.KeyChar))` block (alongside `S`, `T`, ...):

```powershell
        'G' { Enter-AggregateMode -Tab $Tab; return }
```

- [ ] **Step 5: Parse + lint + tests**

Run parse check on `src/65-views.ps1` and `src/75-key-dispatch.ps1`; run lint over `./src`; run `./tests/run-tests.ps1`.
Expected: parse OK, lint clean, tests pass.

- [ ] **Step 6: Manual smoke (interactive)**

Launch `pwsh ./SharePoint-Sharing-Manager.ps1` against a test tenant (or a session with cached findings restored). On the OneDrives tab with findings present, press `G`: verify the aggregate list shows a Site column mixing rows from multiple drives, `/` search and `F` filter work, and `Esc` returns to the target list. Do NOT run a real revoke here unless in a disposable tenant.

- [ ] **Step 7: Commit**

```bash
git add src/65-views.ps1 src/75-key-dispatch.ps1
git commit -m "feat: aggregate findings view (G) with Site column and bulk revoke"
```

---

### Task 6: Target-list bulk revoke (`R` on the target list)

Let `R` on the target list revoke all findings on the selected targets, via the shared bulk routine.

**Files:**
- Modify: `src/75-key-dispatch.ps1` (`Invoke-TargetsKey`)

**Interfaces:**
- Consumes: `Invoke-BulkRevoke` (Task 4), `Get-TabFindings` filtered to selected targets, `Show-MsgModal`.

- [ ] **Step 1: Bind `R` in the target list**

In `src/75-key-dispatch.ps1`, in `Invoke-TargetsKey`'s `switch ([char]::ToUpper($K.KeyChar))` block, add:

```powershell
        'R' {
            $selTargets = @($Tab['Items'] | Where-Object { $_.Selected })
            if ($selTargets.Count -eq 0) { Show-MsgModal -Title 'Revoke' -Lines @('No targets selected. Space selects a drive.'); return }
            $findings = @()
            foreach ($tt in $selTargets) { if (@($tt.Findings).Count -gt 0) { $findings += @($tt.Findings) } }
            if ($findings.Count -eq 0) { Show-MsgModal -Title 'Revoke' -Lines @('Selected targets have no findings to revoke.'); return }
            Invoke-BulkRevoke -Findings $findings -Tab $Tab
            return
        }
```

- [ ] **Step 2: Parse + lint + tests**

Run parse check on `src/75-key-dispatch.ps1`; run lint; run `./tests/run-tests.ps1`.
Expected: parse OK, lint clean, tests pass.

- [ ] **Step 3: Manual smoke (interactive)**

In a disposable tenant only: on the target list, select 2+ drives that have findings, press `R`, confirm the typed `REVOKE` dialog shows a per-site breakdown, and after running verify each drive's `Findings` count drops and status becomes `Revoked` when cleared. Confirm a REVOKED CSV was written per site under `SSM-Exports/`.

- [ ] **Step 4: Commit**

```bash
git add src/75-key-dispatch.ps1
git commit -m "feat: revoke all findings on selected targets (R on target list)"
```

---

### Task 7: Scan-all with incremental save + resume (`X`)

Add incremental cache save inside the existing scan loop, and a scan-all action that enumerates if needed and scans every not-yet-scanned target.

**Files:**
- Modify: `src/65-views.ps1` (`Invoke-TabScan` incremental save; add `Invoke-TabScanAll`)
- Modify: `src/75-key-dispatch.ps1` (`Invoke-TargetsKey`: `X`)

**Interfaces:**
- Consumes: `Get-TenantTargets`, `Add-TargetsToTab`, `Invoke-TabScan`, `Save-SsmCache` (Task 2), `Start-LoadSpinner`/`Stop-LoadSpinner`, `Write-ProgressModal`, `Show-MsgModal`.
- Produces: `Invoke-TabScanAll -Tab <hashtable>` → void.

- [ ] **Step 1: Add incremental save to `Invoke-TabScan`**

In `src/65-views.ps1`, inside `Invoke-TabScan`, in the per-target `finally` block, after `Stop-LoadSpinner`, add a guarded save so both single scan and scan-all persist progress after each drive:

```powershell
        } finally {
            Stop-LoadSpinner
            if (Get-Command Save-SsmCache -ErrorAction SilentlyContinue) { Save-SsmCache }
        }
```

- [ ] **Step 2: Implement `Invoke-TabScanAll`**

Add to `src/65-views.ps1` (after `Invoke-TabScan`):

```powershell
function Invoke-TabScanAll {
    # Enumerate if empty, then scan every NotScanned target. Cache is saved
    # after each target by Invoke-TabScan, so an interrupted run resumes.
    param($Tab)
    if (-not $Tab['Loaded'] -or @($Tab['Items']).Count -eq 0) {
        Start-LoadSpinner
        Write-ProgressModal -Title 'Enumerating tenant' -Done 0 -Total 0 -Label ($Tab['OneDrive'] ? 'Loading OneDrives...' : 'Loading sites...') -Ok 0 -Failed 0
        try { $targets = Get-TenantTargets -OneDrive $Tab['OneDrive'] } finally { Stop-LoadSpinner }
        Add-TargetsToTab -Tab $Tab -Targets $targets
    }
    foreach ($it in @($Tab['Items'])) { $it.Selected = ($it.Status -eq 'NotScanned') }
    if (@($Tab['Items'] | Where-Object { $_.Selected }).Count -eq 0) {
        Show-MsgModal -Title 'Scan all' -Lines @('No unscanned targets remain. Everything here is already scanned.')
        return
    }
    Invoke-TabScan -Tab $Tab
}
```

- [ ] **Step 3: Bind `X` in the target list**

In `src/75-key-dispatch.ps1`, in `Invoke-TargetsKey`'s `switch ([char]::ToUpper($K.KeyChar))` block, add:

```powershell
        'X' { Invoke-TabScanAll -Tab $Tab; return }
```

- [ ] **Step 4: Parse + lint + tests**

Run parse checks on both changed files; run lint; run `./tests/run-tests.ps1`.
Expected: parse OK, lint clean, tests pass.

- [ ] **Step 5: Manual smoke (interactive)**

In a test tenant: on the OneDrives tab with an empty list, press `X`; verify it enumerates then scans sequentially, and that `SSM-Cache/session.json` updates after each drive (check its mtime grows during the run). Interrupt with `Esc` mid-run, confirm already-scanned drives kept their status. Relaunch, press `L` to restore, press `X` again, and confirm only the remaining `NotScanned` drives are scanned.

- [ ] **Step 6: Commit**

```bash
git add src/65-views.ps1 src/75-key-dispatch.ps1
git commit -m "feat: scan-all (X) with incremental cache save and resume"
```

---

### Task 8: Startup restore wiring + `L` key + restore banner

Populate the restore info at startup, add the `L` restore key, and surface an on-screen hint.

**Files:**
- Modify: `SharePoint-Sharing-Manager.ps1` (set `$script:UI.RestoreInfo` after src load)
- Modify: `src/75-key-dispatch.ps1` (`Invoke-TargetsKey`: `L`)
- Modify: `src/65-views.ps1` (`Add-TargetsView` empty-state hint)

**Interfaces:**
- Consumes: `Test-SsmCacheAvailable`, `Restore-SsmCache` (Task 2), `Show-MsgModal`.

- [ ] **Step 1: Set restore info at startup**

In `SharePoint-Sharing-Manager.ps1`, after `Initialize-SsmAuth` (line 77) and before the `#region Main` logging, add:

```powershell
$script:UI.RestoreInfo = Test-SsmCacheAvailable
if ($script:UI.RestoreInfo) {
    Write-SsmLog -Message ("Session cache available: {0} target(s) from {1}. Press L on a target tab to restore." -f $script:UI.RestoreInfo.Count, $script:UI.RestoreInfo.SavedAt)
}
```

- [ ] **Step 2: Bind `L` restore in the target list**

In `src/75-key-dispatch.ps1`, in `Invoke-TargetsKey`'s `switch ([char]::ToUpper($K.KeyChar))` block, add:

```powershell
        'L' {
            if (-not $script:UI.RestoreInfo) { Show-MsgModal -Title 'Restore' -Lines @('No saved session cache to restore.'); return }
            if (Restore-SsmCache) {
                $script:UI.RestoreInfo = $null
                Show-MsgModal -Title 'Restored' -Lines @('Scan cache restored from disk.')
            } else {
                Show-MsgModal -Title 'Restore failed' -Lines @('Could not read the session cache. See the Log tab.') -Kind Error
            }
            return
        }
```

- [ ] **Step 3: Show the restore hint on an empty target list**

In `src/65-views.ps1`, in `Add-TargetsView`, inside the `if (-not $Tab['Loaded'])` empty-state block, after the existing `$hint` lines are added and before the auth warning, add a restore line when a cache is available:

```powershell
        if ($script:UI.RestoreInfo) {
            [void]$lines.Add(@('', 0))
            $rmsg = ("Cached session available ({0} targets, saved {1}) - press L to restore." -f $script:UI.RestoreInfo.Count, $script:UI.RestoreInfo.SavedAt)
            [void]$lines.Add(@(($script:T.Good + $rmsg), $rmsg.Length))
        }
```

- [ ] **Step 4: Parse + lint + tests**

Run parse checks on the three changed files; run lint over `./src`; run `./tests/run-tests.ps1`.
Expected: parse OK, lint clean, tests pass.

- [ ] **Step 5: Manual smoke (interactive)**

With an existing `SSM-Cache/session.json`, launch the tool: verify the OneDrives tab's empty state shows the green "press L to restore" hint and the Log tab records the availability line. Press `L`, confirm targets and findings reappear with their prior statuses and that `G` then shows the restored aggregate findings.

- [ ] **Step 6: Commit**

```bash
git add SharePoint-Sharing-Manager.ps1 src/75-key-dispatch.ps1 src/65-views.ps1
git commit -m "feat: startup cache detection, L restore key, restore hint"
```

---

### Task 9: Documentation, footer hints, help, changelog

Reflect the new keys and files in the in-app hints and the docs.

**Files:**
- Modify: `src/65-views.ps1` (`Get-TabHints` for Targets list and Findings mode)
- Modify: `src/20-modals.ps1` (help modal — only if it enumerates keys; otherwise skip)
- Modify: `README.md` (keys table, feature list, "Files the tool writes")
- Modify: `CHANGELOG.md`

**Interfaces:** none (docs/UI copy only).

- [ ] **Step 1: Add footer hints**

In `src/65-views.ps1`, `Get-TabHints`, extend the Targets-list return array to include the new keys and the Findings-mode array to note site-spanning bulk revoke. Update the target-list branch:

```powershell
            return @(@('Spc','select'),@('A','all'),@('N','none'),@('/','find'),@('F','filter'),
                     @('S','scan'),@('X','scan all'),@('T','rules'),@('G','all findings'),
                     @('R','revoke selected'),@('U','add url'),@('I','import csv'),
                     @('Enter','open/load'),@('L','restore'),@('E','export'),@('?','help'),@('Q','quit'))
```

- [ ] **Step 2: Update the help modal (conditional)**

Open `src/20-modals.ps1` and locate `Show-HelpModal`. If it lists per-tab keys, add lines for `X` (scan all), `G` (all findings / bulk revoke), `R` (revoke selected targets), and `L` (restore cached session). If the help text is generic and does not enumerate keys, make no change and note that in the commit body.

- [ ] **Step 3: Update README**

In `README.md`:
- Keys table (Sites / OneDrives target list): add rows `X` = "Scan all not-yet-scanned targets", `G` = "All findings (aggregate view across drives)", `R` = "Revoke all findings on selected targets", `L` = "Restore the saved scan session".
- Keys table (findings sub-view): note that in the aggregate view `R` revokes across every affected site with one confirmation.
- Feature list: add "Persistent scan cache with manual restore" and "Bulk revocation across drives and across the full findings list".
- "Files the tool writes" table: add a row — `SSM-Cache/session.json` / "Cached scan results (targets + findings) for restore; contains directory data" and `SSM-Cache/README.txt` / "Sensitivity notice for the cache directory".

- [ ] **Step 4: Update CHANGELOG**

Add a new entry at the top of `CHANGELOG.md` describing: session cache with manual restore (`L`), aggregate findings view (`G`), bulk revoke across sites (aggregate `R` and target-list `R`), and scan-all with resume (`X`).

- [ ] **Step 5: Parse + lint**

Run parse check on `src/65-views.ps1` (and `src/20-modals.ps1` if changed); run lint over `./src`.
Expected: parse OK, lint clean.

- [ ] **Step 6: Commit**

```bash
git add src/65-views.ps1 src/20-modals.ps1 README.md CHANGELOG.md
git commit -m "docs: document scan cache, bulk revoke, and scan-all keys"
```

---

## Self-Review

**Spec coverage:**
- Persistence (cache file, contents, atomic save, manual restore, warning file) → Tasks 1, 2, 8. ✓
- Aggregate findings view + Site column + bulk revoke → Tasks 3, 4, 5. ✓
- Target-list bulk revoke ("per OD site") → Task 6. ✓
- Scan-all + incremental save + resume → Task 7. ✓
- No new tab / digit mapping preserved → aggregate is a mode toggle (Task 5). ✓
- Known limitations (stale cache, sensitivity, sequential, single slot) → surfaced via restore banner timestamp (Task 8), README/CHANGELOG (Task 9), warning file (Task 2). ✓
- Files-changed list in the spec matches Tasks 1–9. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; Task 9 Step 2 is explicitly conditional with a decision rule, not a placeholder. ✓

**Type/name consistency:** `Save-SsmCache`, `Test-SsmCacheAvailable`, `Restore-SsmCache`, `ConvertTo-SsmCacheObject`, `ConvertFrom-SsmCacheObject`, `Get-TabFindings`, `Group-FindingsBySite`, `Invoke-BulkRevoke`, `Update-TabTargetStatuses`, `Enter-AggregateMode`, `Invoke-TabScanAll` are each defined once and referenced with matching signatures. `$Tab['FTab']['Aggregate']` is set in Task 5 and read in Tasks 4/5. Finding `Site` property is relied on by Tasks 3–5 and confirmed present in the scan engine output and CSV projection. ✓
