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
