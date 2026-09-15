# OneDrive Pre-Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `P` on the OneDrives tab lists OneDrive-licensed users without a provisioned personal site, exports them to CSV, and after typed confirmation bulk-requests provisioning via `Request-PnPPersonalSite`.

**Architecture:** New region file `src/47-onedrive-provision.ps1` holds pure diff/slug/chunk logic plus thin Graph/CSOM wrappers. The CSOM paging loop in `Get-TenantTargets` is factored into a shared `Get-SsmTenantSiteProperties`. A view function in `src/65-views.ps1` orchestrates Graph query → CSOM enumeration → report modal → typed confirm → batched request → CSVs. Key handler in `src/75-key-dispatch.ps1`.

**Tech Stack:** PowerShell 7.4+, PnP.PowerShell (`Invoke-PnPGraphMethod`, `Request-PnPPersonalSite`, tenant CSOM), assert-based tests in `tests/run-tests.ps1`.

Spec: `docs/superpowers/specs/2026-09-15-onedrive-pre-provisioning-design.md`.

## Global Constraints

- PowerShell 7.4+, `Set-StrictMode -Version 2.0` safe (no reads of undefined properties/variables; use `$obj.PSObject.Properties['x']` when a Graph field may be absent).
- PnP.PowerShell is the only external dependency; Graph via `Invoke-PnPGraphMethod` only.
- One file per region under `src/`, numeric prefix controls load order.
- Destructive/mutating action requires `Show-TypedConfirmModal` with an exact word: `PROVISION`.
- CSVs written with `-NoTypeInformation -Encoding UTF8BOM` into `$script:ExportDir`.
- Logging via `Write-SsmLog -Message ... -Level INFO|WARN|ERROR|OK` and `Write-SsmErrorLog -Context ... -ErrorRecord $_`.
- Tests: `pwsh -NoProfile -File ./tests/run-tests.ps1` must pass; new pure-logic files must be added to the dot-source list in `tests/run-tests.ps1`.
- Lint: `Invoke-ScriptAnalyzer -Path ./SharePoint-Sharing-Manager.ps1, ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error, Warning` clean.
- Wiki sync rule: any user-facing change updates `wiki/*.md` and `CHANGELOG.md` Unreleased.
- Text inside files must be self-contained (no chat references).

---

### Task 1: Pure logic — slug, licensed filter, diff, chunking

**Files:**
- Create: `src/47-onedrive-provision.ps1`
- Create: `tests/onedrive-provision.tests.ps1`
- Modify: `tests/run-tests.ps1:40` (dot-source list)

**Interfaces:**
- Produces:
  - `ConvertTo-SsmPersonalSlug([string]$Upn) -> [string]` — `john.doe@contoso.com` → `john_doe_contoso_com`, lowercase.
  - `Select-SsmSharePointLicensed([object[]]$Users) -> [pscustomobject[]]{Id;Upn;DisplayName}` — keeps Graph user objects with an `assignedPlans` entry where `service -eq 'SharePoint'` and `capabilityStatus -eq 'Enabled'`.
  - `Get-SsmUnprovisionedUsers([pscustomobject[]]$Licensed, [System.Collections.Generic.HashSet[string]]$OwnerSet) -> [pscustomobject[]]` — licensed users whose lowercased UPN and slug are both absent from `$OwnerSet`.
  - `Split-SsmBatch([string[]]$Items, [int]$Size) -> [object[]]` of `[string[]]` chunks.

- [ ] **Step 1: Write failing tests**

`tests/onedrive-provision.tests.ps1`:

```powershell
Invoke-SsmTest 'ConvertTo-SsmPersonalSlug replaces . and @ with _ and lowercases' {
    Assert-Equal 'john_doe_contoso_com' (ConvertTo-SsmPersonalSlug -Upn 'John.Doe@Contoso.com')
}

Invoke-SsmTest 'Select-SsmSharePointLicensed keeps only enabled SharePoint plans' {
    $users = @(
        [pscustomobject]@{ id='1'; userPrincipalName='a@x.com'; displayName='A'; assignedPlans=@(
            [pscustomobject]@{ service='SharePoint'; capabilityStatus='Enabled' }) },
        [pscustomobject]@{ id='2'; userPrincipalName='b@x.com'; displayName='B'; assignedPlans=@(
            [pscustomobject]@{ service='SharePoint'; capabilityStatus='Deleted' }) },
        [pscustomobject]@{ id='3'; userPrincipalName='c@x.com'; displayName='C'; assignedPlans=@(
            [pscustomobject]@{ service='exchange'; capabilityStatus='Enabled' }) },
        [pscustomobject]@{ id='4'; userPrincipalName='d@x.com'; displayName='D'; assignedPlans=@() }
    )
    $r = @(Select-SsmSharePointLicensed -Users $users)
    Assert-Equal 1 $r.Count
    Assert-Equal 'a@x.com' $r[0].Upn
    Assert-Equal '1' $r[0].Id
    Assert-Equal 'A' $r[0].DisplayName
}

Invoke-SsmTest 'Get-SsmUnprovisionedUsers matches by UPN, by slug, case-insensitive' {
    $lic = @(
        [pscustomobject]@{ Id='1'; Upn='Has.Owner@x.com'; DisplayName='' },
        [pscustomobject]@{ Id='2'; Upn='slug.only@x.com'; DisplayName='' },
        [pscustomobject]@{ Id='3'; Upn='missing@x.com'; DisplayName='' }
    )
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$set.Add('has.owner@x.com')
    [void]$set.Add('slug_only_x_com')
    $r = @(Get-SsmUnprovisionedUsers -Licensed $lic -OwnerSet $set)
    Assert-Equal 1 $r.Count
    Assert-Equal 'missing@x.com' $r[0].Upn
}

Invoke-SsmTest 'Get-SsmUnprovisionedUsers returns empty for empty input' {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Assert-Equal 0 (@(Get-SsmUnprovisionedUsers -Licensed @() -OwnerSet $set)).Count
}

Invoke-SsmTest 'Split-SsmBatch chunks into fixed sizes with remainder' {
    $b = @(Split-SsmBatch -Items @(1..5 | ForEach-Object { "u$_" }) -Size 2)
    Assert-Equal 3 $b.Count
    Assert-Equal 2 (@($b[0])).Count
    Assert-Equal 1 (@($b[2])).Count
    Assert-Equal 'u5' (@($b[2]))[0]
}
```

- [ ] **Step 2: Add file to runner dot-source list**

In `tests/run-tests.ps1`, change the array on line 40 to include `'47-onedrive-provision'` after `'46-onedrive-admin'`:

```powershell
foreach ($f in @('15-drawing','20-modals','25-config','30-connections','35-scan-engine','40-revoke','45-targets','46-onedrive-admin','47-onedrive-provision','50-csv','55-tenant-actions','60-setup-actions','65-views','70-cache','72-update-check','75-key-dispatch')) {
```

- [ ] **Step 3: Run tests, verify failure**

Run: `pwsh -NoProfile -File ./tests/run-tests.ps1`
Expected: `FAIL` lines for the five new tests (command not recognized).

- [ ] **Step 4: Implement pure functions**

Create `src/47-onedrive-provision.ps1`:

```powershell
# ============================================================================
#region OneDrive pre-provisioning
# ============================================================================
# Finds OneDrive-licensed users without a provisioned personal site and
# requests provisioning in bulk. Pure helpers first (unit-tested), then the
# Graph/CSOM wrappers.

function ConvertTo-SsmPersonalSlug {
    # user@example.com -> user_example_com : the path segment SharePoint uses
    # under /personal/. Fallback match for sites whose Owner is empty.
    param([Parameter(Mandatory)][string]$Upn)
    return ($Upn -replace '[.@]', '_').ToLowerInvariant()
}

function Select-SsmSharePointLicensed {
    # Keep Graph users with an Enabled SharePoint service plan. Matching on
    # the assignedPlans.service name avoids maintaining a plan-GUID list.
    param([object[]]$Users)
    $out = @()
    foreach ($u in @($Users)) {
        $plans = @()
        if ($u.PSObject.Properties['assignedPlans'] -and $u.assignedPlans) { $plans = @($u.assignedPlans) }
        $hit = $plans | Where-Object { $_.service -eq 'SharePoint' -and $_.capabilityStatus -eq 'Enabled' } | Select-Object -First 1
        if (-not $hit) { continue }
        $out += [pscustomobject]@{
            Id          = [string]$u.id
            Upn         = [string]$u.userPrincipalName
            DisplayName = if ($u.PSObject.Properties['displayName']) { [string]$u.displayName } else { '' }
        }
    }
    return $out
}

function Get-SsmUnprovisionedUsers {
    # Licensed users absent from the owner set by both UPN and URL slug.
    param(
        [object[]]$Licensed,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$OwnerSet
    )
    $out = @()
    foreach ($u in @($Licensed)) {
        if ($OwnerSet.Contains($u.Upn)) { continue }
        if ($OwnerSet.Contains((ConvertTo-SsmPersonalSlug -Upn $u.Upn))) { continue }
        $out += $u
    }
    return $out
}

function Split-SsmBatch {
    param([string[]]$Items, [Parameter(Mandatory)][int]$Size)
    $out = @()
    $all = @($Items)
    for ($i = 0; $i -lt $all.Count; $i += $Size) {
        $end = [Math]::Min($i + $Size, $all.Count) - 1
        $out += ,@($all[$i..$end])
    }
    return $out
}

#endregion
```

- [ ] **Step 5: Run tests, verify pass**

Run: `pwsh -NoProfile -File ./tests/run-tests.ps1`
Expected: five `PASS` lines for `onedrive-provision.tests.ps1`, `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add src/47-onedrive-provision.ps1 tests/onedrive-provision.tests.ps1 tests/run-tests.ps1
git commit -m "feat: pure helpers for OneDrive pre-provisioning diff"
```

---

### Task 2: Shared CSOM paging helper + provisioned owner set

**Files:**
- Modify: `src/45-targets.ps1:47-87` (`Get-TenantTargets`)
- Modify: `src/47-onedrive-provision.ps1` (append)
- Test: `tests/targets.tests.ps1` (no change expected; run to confirm no regression)

**Interfaces:**
- Produces:
  - `Get-SsmTenantSiteProperties([bool]$IncludePersonal, [scriptblock]$Progress) -> [System.Collections.ArrayList]` of CSOM `SiteProperties` (fields used downstream: `Url`, `Title`, `Template`, `LockState`, `Owner`). Caller must already be connected to the admin site.
  - `Get-SsmProvisionedOwnerSet([scriptblock]$Progress) -> [System.Collections.Generic.HashSet[string]]` case-insensitive; contains lowercased `Owner` and URL slug of every `SPSPERS*` site. Calls `Connect-SsmAdmin`; returns `$null` on connection failure.

- [ ] **Step 1: Extract the paging loop in `Get-TenantTargets`**

Replace lines 59-72 of `src/45-targets.ps1` (from `$ctx = Get-PnPContext` through the `} while (...)` line) with:

```powershell
    $sites = Get-SsmTenantSiteProperties -IncludePersonal $OneDrive -Progress $Progress
```

Add this function directly **above** `Get-TenantTargets` in `src/45-targets.ps1`:

```powershell
function Get-SsmTenantSiteProperties {
    # Paged CSOM enumeration of tenant site properties - the same loop
    # Get-PnPTenantSite runs internally, unrolled so callers can report per
    # page. IncludeDetail is required for LockState/Owner to be populated.
    # Caller must already hold the admin connection (Connect-SsmAdmin).
    param([bool]$IncludePersonal, [scriptblock]$Progress)
    $ctx = Get-PnPContext
    $tenant = New-Object Microsoft.Online.SharePoint.TenantAdministration.Tenant($ctx)
    $filter = New-Object Microsoft.Online.SharePoint.TenantAdministration.SPOSitePropertiesEnumerableFilter
    $filter.IncludePersonalSite = $IncludePersonal ? [Microsoft.Online.SharePoint.TenantAdministration.PersonalSiteFilter]::Include : [Microsoft.Online.SharePoint.TenantAdministration.PersonalSiteFilter]::UseServerDefault
    $filter.IncludeDetail = $true
    $sites = [System.Collections.ArrayList]::new()
    do {
        $page = $tenant.GetSitePropertiesFromSharePointByFilters($filter)
        $ctx.Load($page)
        Invoke-PnPQuery -ErrorAction Stop
        foreach ($p in $page) { [void]$sites.Add($p) }
        $filter.StartIndex = $page.NextStartIndexFromSharePoint
        if ($Progress) { & $Progress $sites.Count }
    } while (-not [string]::IsNullOrWhiteSpace($page.NextStartIndexFromSharePoint))
    return $sites
}
```

Keep the existing comment block above `Get-TenantTargets` but delete the sentences that describe the loop internals now living in the helper (the "Same paged CSOM loop…" and "IncludeDetail is required…" lines); keep the LockState filtering explanation.

- [ ] **Step 2: Parse-check and run tests**

Run:
```bash
pwsh -NoProfile -c '[void][System.Management.Automation.Language.Parser]::ParseFile("./src/45-targets.ps1",[ref]$null,[ref]$e); $e | % { $_.Message }; "parse ok"'
pwsh -NoProfile -File ./tests/run-tests.ps1
```
Expected: `parse ok`, `0 failed`.

- [ ] **Step 3: Add owner-set wrapper**

Append to `src/47-onedrive-provision.ps1` before `#endregion`:

```powershell
function Get-SsmProvisionedOwnerSet {
    # Every existing personal site, keyed by lowercased Owner UPN and by URL
    # slug (/personal/<slug>). Slug covers sites whose Owner is empty or
    # SID-shaped. Returns $null if the admin connection cannot be made.
    param([scriptblock]$Progress)
    if (-not (Connect-SsmAdmin)) { return $null }
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sites = Get-SsmTenantSiteProperties -IncludePersonal $true -Progress $Progress
    foreach ($s in $sites) {
        if ($s.Template -notlike 'SPSPERS*') { continue }
        $owner = [string]$s.Owner
        if ($owner) { [void]$set.Add($owner.ToLowerInvariant()) }
        $slug = ([string]$s.Url).TrimEnd('/') -split '/personal/' | Select-Object -Last 1
        if ($slug) { [void]$set.Add($slug.ToLowerInvariant()) }
    }
    Write-SsmLog -Message ("Pre-provision: {0} personal sites enumerated." -f $set.Count)
    return $set
}
```

- [ ] **Step 4: Parse-check, tests, commit**

Run same two commands as Step 2. Expected: `parse ok`, `0 failed`.

```bash
git add src/45-targets.ps1 src/47-onedrive-provision.ps1
git commit -m "refactor: share tenant CSOM paging; add provisioned owner set"
```

---

### Task 3: Graph licensed-user query + batched provisioning request

**Files:**
- Modify: `src/47-onedrive-provision.ps1` (append)

**Interfaces:**
- Consumes: `Select-SsmSharePointLicensed`, `Split-SsmBatch` (Task 1).
- Produces:
  - `Get-SsmLicensedUsers([scriptblock]$Progress) -> [pscustomobject[]]{Id;Upn;DisplayName}`. Throws on Graph error (caller maps 403 to a permission message).
  - `Invoke-SsmPersonalSiteRequest([string[]]$Upns, [scriptblock]$Progress) -> [pscustomobject[]]{Upn;Batch;Status;Error}` where `Status` is `Requested` or `Failed`. Requires admin connection already open (Task 2's owner-set call guarantees it in the view flow).

- [ ] **Step 1: Add Graph query**

Append before `#endregion`:

```powershell
function Get-SsmLicensedUsers {
    # Page through enabled member users, filter client-side to those with an
    # Enabled SharePoint plan. One request per 999 users; no per-user calls.
    # Throws on Graph failure - the view maps 403 to a permissions message.
    param([scriptblock]$Progress)
    $url = "users?`$filter=accountEnabled eq true and userType eq 'Member'&`$select=id,userPrincipalName,displayName,assignedPlans&`$top=999"
    $raw = [System.Collections.ArrayList]::new()
    do {
        $resp = Invoke-PnPGraphMethod -Method Get -Url $url -ErrorAction Stop
        $items = @()
        if ($resp.PSObject.Properties['value']) { $items = @($resp.value) }
        foreach ($i in $items) { [void]$raw.Add($i) }
        $url = if ($resp.PSObject.Properties['@odata.nextLink']) { [string]$resp.'@odata.nextLink' } else { $null }
        if ($Progress) { & $Progress $raw.Count }
    } while ($url)
    $licensed = @(Select-SsmSharePointLicensed -Users $raw.ToArray())
    Write-SsmLog -Message ("Pre-provision: {0} enabled members, {1} with SharePoint plan." -f $raw.Count, $licensed.Count)
    return $licensed
}

function Invoke-SsmPersonalSiteRequest {
    # Request-PnPPersonalSite accepts up to 200 UPNs per call and queues the
    # work server-side; SharePoint provisions asynchronously afterwards.
    # A failed batch marks every UPN in it Failed and the run continues.
    # ponytail: no retry/backoff; add if 429 throttling shows up in the log.
    param([string[]]$Upns, [scriptblock]$Progress)
    $rows = @()
    $batches = @(Split-SsmBatch -Items $Upns -Size 200)
    $n = 0
    foreach ($b in $batches) {
        $n++
        $status = 'Requested'; $err = ''
        try {
            Request-PnPPersonalSite -UserEmails @($b) -ErrorAction Stop
            Write-SsmLog -Message ("Pre-provision: batch {0}/{1} requested ({2} users)." -f $n, $batches.Count, @($b).Count) -Level OK
        } catch {
            $status = 'Failed'; $err = $_.Exception.Message
            Write-SsmErrorLog -Context ("Pre-provision: batch {0}/{1} failed" -f $n, $batches.Count) -ErrorRecord $_
        }
        foreach ($u in @($b)) { $rows += [pscustomobject]@{ Upn=$u; Batch=$n; Status=$status; Error=$err } }
        if ($Progress) { & $Progress $n $batches.Count }
    }
    return $rows
}
```

- [ ] **Step 2: Parse-check + lint + tests**

Run:
```bash
pwsh -NoProfile -c '[void][System.Management.Automation.Language.Parser]::ParseFile("./src/47-onedrive-provision.ps1",[ref]$null,[ref]$e); $e | % { $_.Message }; "parse ok"'
pwsh -NoProfile -c 'Invoke-ScriptAnalyzer -Path ./src/47-onedrive-provision.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error, Warning'
pwsh -NoProfile -File ./tests/run-tests.ps1
```
Expected: `parse ok`, no analyzer output, `0 failed`.

- [ ] **Step 3: Commit**

```bash
git add src/47-onedrive-provision.ps1
git commit -m "feat: Graph licensed-user query and batched personal-site request"
```

---

### Task 4: CSV exports

**Files:**
- Modify: `src/50-csv.ps1` (append after `Export-ViewCsv`)
- Test: `tests/csv.tests.ps1` (append)

**Interfaces:**
- Produces: `Export-SsmProvisionCsv([object[]]$Rows, [ValidateSet('UNPROVISIONED','REQUESTED')][string]$Phase) -> [string]` path. `UNPROVISIONED` columns `Upn, DisplayName`; `REQUESTED` columns `Upn, Batch, Status, Error`. Filename `SSM_ONEDRIVE_<Phase>_<yyyyMMdd-HHmmss>.csv` in `$script:ExportDir`.

- [ ] **Step 1: Write failing test**

Append to `tests/csv.tests.ps1`:

```powershell
Invoke-SsmTest 'Export-SsmProvisionCsv writes phase-specific columns' {
    $prev = $script:ExportDir
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssm-prov-{0}" -f ([guid]::NewGuid()))
    try {
        $p1 = Export-SsmProvisionCsv -Rows @([pscustomobject]@{ Upn='a@x.com'; DisplayName='A' }) -Phase UNPROVISIONED
        $h1 = (Get-Content -LiteralPath $p1)[0]
        Assert-Equal '"Upn","DisplayName"' $h1
        $p2 = Export-SsmProvisionCsv -Rows @([pscustomobject]@{ Upn='a@x.com'; Batch=1; Status='Requested'; Error='' }) -Phase REQUESTED
        $h2 = (Get-Content -LiteralPath $p2)[0]
        Assert-Equal '"Upn","Batch","Status","Error"' $h2
        if ((Split-Path $p1 -Leaf) -notlike 'SSM_ONEDRIVE_UNPROVISIONED_*.csv') { throw "bad name $p1" }
    } finally {
        if (Test-Path -LiteralPath $script:ExportDir) { Remove-Item -LiteralPath $script:ExportDir -Recurse -Force }
        $script:ExportDir = $prev
    }
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `pwsh -NoProfile -File ./tests/run-tests.ps1`
Expected: `FAIL  Export-SsmProvisionCsv writes phase-specific columns`.

- [ ] **Step 3: Implement**

Append to `src/50-csv.ps1` before the closing `#endregion` (or at end of file if none):

```powershell
function Export-SsmProvisionCsv {
    # OneDrive pre-provisioning evidence. UNPROVISIONED = the preview list
    # shown before confirmation; REQUESTED = per-user outcome of the
    # Request-PnPPersonalSite batches.
    param(
        [object[]]$Rows,
        [Parameter(Mandatory)][ValidateSet('UNPROVISIONED','REQUESTED')][string]$Phase
    )
    if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Path $script:ExportDir -Force | Out-Null }
    $columns = if ($Phase -eq 'UNPROVISIONED') { @('Upn','DisplayName') } else { @('Upn','Batch','Status','Error') }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $script:ExportDir ("SSM_ONEDRIVE_{0}_{1}.csv" -f $Phase, $stamp)
    @($Rows) | Select-Object $columns | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8BOM
    Write-SsmLog -Message ("Pre-provision {0} evidence: {1}" -f $Phase, $path)
    return $path
}
```

- [ ] **Step 4: Run tests, verify pass; commit**

Run: `pwsh -NoProfile -File ./tests/run-tests.ps1` → `0 failed`.

```bash
git add src/50-csv.ps1 tests/csv.tests.ps1
git commit -m "feat: CSV evidence for OneDrive pre-provisioning"
```

---

### Task 5: View orchestration, key binding, hints, help

**Files:**
- Modify: `src/65-views.ps1` (add `Invoke-SsmOneDriveProvision` after `Invoke-SsmOneDriveAdmin`; hint at line ~1185)
- Modify: `src/75-key-dispatch.ps1:153-156` (add `'P'` case next to `'M'`)
- Modify: `src/20-modals.ps1:604` (help row after the `M` row)
- Test: `tests/views.tests.ps1` (append)

**Interfaces:**
- Consumes: `Get-SsmLicensedUsers`, `Get-SsmProvisionedOwnerSet`, `Get-SsmUnprovisionedUsers`, `Invoke-SsmPersonalSiteRequest`, `Export-SsmProvisionCsv`, `Show-ReportModal`, `Show-TypedConfirmModal`, `Show-MsgModal`, `Write-ProgressModal`.
- Produces: `Invoke-SsmOneDriveProvision($Tab)`.

- [ ] **Step 1: Write failing tests**

Append to `tests/views.tests.ps1`:

```powershell
Invoke-SsmTest 'Invoke-SsmOneDriveProvision refuses non-OneDrive tab' {
    $script:CapturedTitle = $null
    function Show-MsgModal { param($Title, $Lines, $Kind) $script:CapturedTitle = $Title }
    Invoke-SsmOneDriveProvision -Tab @{ OneDrive = $false }
    Assert-Equal 'Pre-provision OneDrives' $script:CapturedTitle
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision stops without confirm when nothing is unprovisioned' {
    $script:Requested = $false
    function Write-ProgressModal { }
    function Get-SsmLicensedUsers { param($Progress) @([pscustomobject]@{ Id='1'; Upn='a@x.com'; DisplayName='A' }) }
    function Get-SsmProvisionedOwnerSet { param($Progress)
        $s = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); [void]$s.Add('a@x.com'); $s }
    function Export-SsmProvisionCsv { param($Rows, $Phase) 'x.csv' }
    function Show-ReportModal { param($Title, $Lines, $Hint) }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not confirm' }
    function Invoke-SsmPersonalSiteRequest { param($Upns, $Progress) $script:Requested = $true }
    Invoke-SsmOneDriveProvision -Tab @{ OneDrive = $true }
    Assert-Equal $false $script:Requested
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision requests after PROVISION confirm' {
    $script:RequestedUpns = @()
    function Write-ProgressModal { }
    function Get-SsmLicensedUsers { param($Progress) @([pscustomobject]@{ Id='1'; Upn='new@x.com'; DisplayName='N' }) }
    function Get-SsmProvisionedOwnerSet { param($Progress) [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    function Export-SsmProvisionCsv { param($Rows, $Phase) 'x.csv' }
    function Show-ReportModal { param($Title, $Lines, $Hint) }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) Assert-Equal 'PROVISION' $Word; $true }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    function Invoke-SsmPersonalSiteRequest { param($Upns, $Progress) $script:RequestedUpns = @($Upns)
        @([pscustomobject]@{ Upn='new@x.com'; Batch=1; Status='Requested'; Error='' }) }
    Invoke-SsmOneDriveProvision -Tab @{ OneDrive = $true }
    Assert-Equal 1 $script:RequestedUpns.Count
    Assert-Equal 'new@x.com' $script:RequestedUpns[0]
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `pwsh -NoProfile -File ./tests/run-tests.ps1`
Expected: three new `FAIL` lines (`Invoke-SsmOneDriveProvision` not recognized).

- [ ] **Step 3: Implement view function**

In `src/65-views.ps1`, directly after the closing brace of `Invoke-SsmOneDriveAdmin`, add:

```powershell
function Invoke-SsmOneDriveProvision {
    # P on the OneDrives tab: list licensed users with no personal site,
    # export the list, then (typed PROVISION) bulk-request provisioning.
    param($Tab)
    $title = 'Pre-provision OneDrives'
    if (-not $Tab['OneDrive']) {
        Show-MsgModal -Title $title -Lines @('This action is only available on the OneDrives tab.') -Kind Warn
        return
    }

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
    $csv = Export-SsmProvisionCsv -Rows $missing -Phase UNPROVISIONED

    $lines = [System.Collections.ArrayList]::new()
    [void]$lines.Add(("{0} licensed  |  {1} personal sites  |  {2} unprovisioned" -f $licensed.Count, $ownerSet.Count, $missing.Count))
    [void]$lines.Add("CSV: $csv")
    [void]$lines.Add('')
    foreach ($u in $missing) { [void]$lines.Add(("  {0}  {1}" -f $u.Upn, $u.DisplayName)) }
    Show-ReportModal -Title $title -Lines $lines.ToArray()
    if ($missing.Count -eq 0) { return }

    $confirm = @(("Request OneDrive provisioning for {0} user(s)?" -f $missing.Count), '',
        'SharePoint queues the work and provisions asynchronously (minutes to hours).',
        'Users who already have a personal site are ignored by the service.', '') +
        @($missing | ForEach-Object { "  $($_.Upn)" })
    if (-not (Show-TypedConfirmModal -Title $title -Lines $confirm -Word 'PROVISION')) { return }

    $upns = @($missing | ForEach-Object { $_.Upn })
    $rows = @(Invoke-SsmPersonalSiteRequest -Upns $upns -Progress { param($b, $t)
        Write-ProgressModal -Title $title -Done $b -Total $t -Label 'Submitting provisioning batches' -Ok 0 -Failed 0 })
    $reqCsv = Export-SsmProvisionCsv -Rows $rows -Phase REQUESTED
    $failed = @($rows | Where-Object { $_.Status -eq 'Failed' }).Count
    $batches = if ($rows.Count -gt 0) { ($rows | Measure-Object -Property Batch -Maximum).Maximum } else { 0 }
    Show-MsgModal -Title $title -Kind ($failed -gt 0 ? 'Warn' : 'Info') -Lines @(
        ("Requested {0} user(s) in {1} batch(es); {2} failed." -f ($rows.Count - $failed), $batches, $failed),
        "CSV: $reqCsv", '',
        'SharePoint provisions personal sites asynchronously.',
        'Press P again later to verify the unprovisioned count shrinks.')
}
```

- [ ] **Step 4: Key handler**

In `src/75-key-dispatch.ps1`, after the `'M'` case (lines 153-156), add:

```powershell
        'P' {
            if ($Tab['OneDrive']) { Invoke-SsmOneDriveProvision -Tab $Tab }
            return
        }
```

Verify `P` is not already bound in the Targets handler: `grep -n "'P'" src/75-key-dispatch.ps1` must show only the new case within the Targets switch.

- [ ] **Step 5: Footer hint and help row**

`src/65-views.ps1` line ~1185, change:

```powershell
            if ($Tab['OneDrive']) { $base += ,@('M','manage admins') }
```
to:
```powershell
            if ($Tab['OneDrive']) { $base += @(,@('M','manage admins'),@('P','pre-provision')) }
```

`src/20-modals.ps1`, after the `M` help row (line 604), add:

```powershell
        @($t.Row, '  P                    pre-provision OneDrives (OneDrives only): list licensed users without a OneDrive, then request'),
```

- [ ] **Step 6: Run tests, parse, lint**

Run:
```bash
pwsh -NoProfile -File ./tests/run-tests.ps1
pwsh -NoProfile -c 'Invoke-ScriptAnalyzer -Path ./SharePoint-Sharing-Manager.ps1, ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Error, Warning'
```
Expected: `0 failed`; analyzer prints nothing. If `help.tests.ps1` asserts on help row counts or keys, update its expectation to include `P`.

- [ ] **Step 7: Commit**

```bash
git add src/65-views.ps1 src/75-key-dispatch.ps1 src/20-modals.ps1 tests/views.tests.ps1 tests/help.tests.ps1
git commit -m "feat: P key - OneDrive pre-provisioning view"
```

---

### Task 6: Documentation (changelog, wiki, README)

**Files:**
- Modify: `CHANGELOG.md:3` (Unreleased)
- Create: `wiki/OneDrive-Pre-Provisioning.md`
- Modify: `wiki/Home.md:19` (table row after OneDrive-Admin-Management)
- Modify: `README.md:76` (feature bullet after the secondary-admin bullet)

- [ ] **Step 1: CHANGELOG**

Under `## [Unreleased]` add:

```markdown
- Add: OneDrive pre-provisioning (`P`, OneDrives tab). Lists every enabled
  member user with an Enabled SharePoint service plan whose personal site
  does not exist yet (diff of Graph `/users` against the tenant's personal
  sites), writes `SSM_ONEDRIVE_UNPROVISIONED_<stamp>.csv`, and after typed
  `PROVISION` submits `Request-PnPPersonalSite` in batches of 200 with a
  `SSM_ONEDRIVE_REQUESTED_<stamp>.csv` outcome file. Needs `User.Read.All`
  (already in both auth modes) and SharePoint Administrator.
```

- [ ] **Step 2: Wiki page**

Create `wiki/OneDrive-Pre-Provisioning.md`:

```markdown
# OneDrive Pre-Provisioning

Find users who are licensed for OneDrive but have never had a personal
site created, and request provisioning for all of them in one pass. Useful
before migrations or before assigning secondary admins, both of which need
the OneDrive to exist first.

## Key

`P` on the **OneDrives** tab. No selection needed; the tool works on the
whole tenant.

## What counts as licensed

An enabled member user (`accountEnabled = true`, `userType = Member`) with
at least one `assignedPlans` entry where `service = SharePoint` and
`capabilityStatus = Enabled`. Guests and disabled accounts are excluded.

## How "not provisioned" is decided

The tool enumerates every personal site (`SPSPERS*` template) through the
tenant admin connection and builds a set of each site's owner UPN and its
`/personal/<slug>` URL segment. A licensed user missing from both is
reported as unprovisioned. No per-user Graph or drive calls are made.

## Flow

1. Press `P`. Progress shows the Graph user paging, then the personal-site
   enumeration.
2. A report lists `N licensed | M personal sites | K unprovisioned` and
   every unprovisioned UPN. `SSM_ONEDRIVE_UNPROVISIONED_<stamp>.csv` is
   written to `SSM-Exports/<tenant>/` at this point.
3. If `K > 0`, type `PROVISION` to submit. UPNs are sent to
   `Request-PnPPersonalSite` in batches of 200.
4. `SSM_ONEDRIVE_REQUESTED_<stamp>.csv` records `Upn, Batch, Status, Error`
   for every user. A failed batch marks all of its users `Failed`; the run
   continues with the next batch.

## Permissions

| Auth mode | Needs |
|---|---|
| Delegated | SharePoint Administrator role; `User.Read.All` (included in the default delegated scopes) |
| App-only | `Sites.FullControl.All` and `User.Read.All` application permissions (both granted by the setup wizard) |

## Limitations

- Provisioning is asynchronous on the SharePoint side and can take minutes
  to hours. Press `P` again later to confirm the unprovisioned count drops.
- A personal site whose owner field is empty **and** whose URL slug no
  longer matches the user's current UPN (for example after a UPN rename) is
  reported as unprovisioned. Requesting it again is harmless; SharePoint
  ignores requests for users who already have a site.
- No automatic retry on throttling. Failed batches are listed in the
  REQUESTED CSV; re-run `P` to retry them.
```

- [ ] **Step 3: Home table row**

In `wiki/Home.md` after the `OneDrive-Admin-Management` row add:

```markdown
| [[OneDrive-Pre-Provisioning]] | Find OneDrive-licensed users with no personal site yet and bulk-request provisioning (`P`, OneDrives tab) |
```

- [ ] **Step 4: README bullet**

In `README.md` after the secondary-admin feature bullet (line 76) add:

```markdown
- **OneDrive pre-provisioning** (`P`, OneDrives tab only) - lists enabled member users with a SharePoint service plan whose personal site does not exist yet, exports the list, and after typed `PROVISION` submits `Request-PnPPersonalSite` in batches of 200. Provisioning completes asynchronously on the service side; re-run `P` to verify. See [OneDrive-Pre-Provisioning](https://github.com/mardahl/SharePoint-Sharing-Manager/wiki/OneDrive-Pre-Provisioning).
```

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md wiki/OneDrive-Pre-Provisioning.md wiki/Home.md README.md
git commit -m "docs: OneDrive pre-provisioning changelog, wiki, README"
```

---

### Task 7: Manual live verification (not automatable)

**Files:** none.

- [ ] **Step 1: Single-file build parses**

Run: `pwsh -NoProfile -File ./build/New-SingleFile.ps1`
Expected: build succeeds with parse verification message.

- [ ] **Step 2: Live smoke test against a test tenant**

Launch the tool, connect (delegated or app-only), open OneDrives tab, press `P`.
Check:
- Graph paging progress advances; no 403.
- Report counts are plausible (licensed ≥ unprovisioned; personal-sites count matches the OneDrives tab list size roughly).
- `SSM-Exports/<tenant>/SSM_ONEDRIVE_UNPROVISIONED_*.csv` exists with `Upn,DisplayName` header.
- With one known unprovisioned test user: type `PROVISION`, confirm `SSM_ONEDRIVE_REQUESTED_*.csv` shows `Requested`; after 10–30 minutes, `P` again shows that user gone from the list.
- Log (`Log` tab) shows `Pre-provision:` lines for Graph count, site count, batch OK.

- [ ] **Step 3: Record outcome**

Add one line under the CHANGELOG entry: `Validated live on <date> with <auth mode>.` if it passed, or note the gap in the wiki Limitations section if not. Commit:

```bash
git add CHANGELOG.md wiki/OneDrive-Pre-Provisioning.md
git commit -m "docs: record pre-provisioning live validation"
```
