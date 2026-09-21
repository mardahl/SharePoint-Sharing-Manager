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
    if (-not ($rows[0].PSObject.Properties.Name -contains $col)) { $col = @($rows[0].PSObject.Properties.Name)[0] }
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
    $Tab['CachedAt'] = $null
    if (Get-Command Update-TabView -ErrorAction SilentlyContinue) { Update-TabView -Tab $Tab }
    # Persist the target list so a restart does not force a full re-enumeration.
    if (Get-Command Save-SsmCache -ErrorAction SilentlyContinue) { Save-SsmCache }
}

function Get-SsmTenantSiteProperties {
    # Paged CSOM enumeration of tenant site properties - the same loop
    # Get-PnPTenantSite runs internally, unrolled so callers can report per
    # page. IncludeDetail is required for LockState/Owner to be populated.
    # Caller must already hold the admin connection (Connect-SsmAdmin).
    param([bool]$IncludePersonal, [scriptblock]$Progress)
    $ctx = Get-PnPContext
    $tenant = New-Object Microsoft.Online.SharePoint.TenantAdministration.Tenant($ctx)
    $filter = New-Object Microsoft.Online.SharePoint.TenantAdministration.SPOSitePropertiesEnumerableFilter
    # Include = personal sites IN ADDITION to regular sites, so also pin Template
    # to SPSPERS server-side; otherwise every tenant site is paged and the
    # progress count reflects all sites, not OneDrives.
    if ($IncludePersonal) {
        $filter.IncludePersonalSite = [Microsoft.Online.SharePoint.TenantAdministration.PersonalSiteFilter]::Include
        $filter.Template = 'SPSPERS'
    } else {
        $filter.IncludePersonalSite = [Microsoft.Online.SharePoint.TenantAdministration.PersonalSiteFilter]::Exclude
    }
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

function Get-TenantTargets {
    # Enumerate site collections via the tenant admin connection.
    # OneDrive tab: personal sites (SPSPERS template); Sites tab: everything else.
    # -Progress: scriptblock invoked after each server page with the running
    # site count, so the caller can show real progress instead of a spinner.
    param([bool]$OneDrive, [scriptblock]$Progress)
    if (-not (Connect-SsmAdmin)) { return @() }
    # LockState 'Unlock' = accessible; anything else (NoAccess/ReadOnly/NoAdditions)
    # is a locked or deprovisioned site that would only 403 on scan, so filter it
    # out here.
    $sites = Get-SsmTenantSiteProperties -IncludePersonal $OneDrive -Progress $Progress
    $out = [System.Collections.Generic.List[object]]::new()
    $locked = 0
    foreach ($s in $sites) {
        $isPersonal = ($s.Template -like 'SPSPERS*')
        if ($OneDrive -ne $isPersonal) { continue }
        if ([string]$s.LockState -ne 'Unlock') { $locked++; continue }
        $out.Add((New-Target -Url $s.Url -Title $s.Title -Template $s.Template))
    }
    if ($locked -gt 0) {
        Write-SsmLog -Message ("Filtered out {0} locked/inaccessible {1} (LockState not Unlock)." -f $locked, ($OneDrive ? 'OneDrives' : 'sites')) -Level WARN
    }
    Write-SsmLog -Message ("Enumerated {0} {1} from the tenant." -f $out.Count, ($OneDrive ? 'OneDrives' : 'sites'))
    return $out.ToArray()
}

function Get-TabFindings {
    # Every finding across all targets in a tab (same object references).
    param($Tab)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($it in @($Tab['Items'])) {
        foreach ($f in @($it.Findings)) { $out.Add($f) }
    }
    return $out.ToArray()
}

#endregion
