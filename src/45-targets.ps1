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
