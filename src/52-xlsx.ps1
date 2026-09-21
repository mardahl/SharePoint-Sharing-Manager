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
        $p = $f.PSObject.Properties['Reach']
        if ($p -and $null -ne $p.Value) { $r = [int]$p.Value }
        $w = 1
        $key = [string]$f.CategoryKey
        if ($script:ExposureWeights.Contains($key)) { $w = [int]$script:ExposureWeights[$key] }
        $weighted += $w * $r
        $reach += $r
    }
    if ($ItemsScanned -le 0) { return @{ Score = 0; Band = 'n/a'; WeightedReach = $weighted; ExposedPercent = 0.0 } }
    $score = [int][Math]::Min(100, [Math]::Round($weighted / $ItemsScanned * 1000, [MidpointRounding]::AwayFromZero))
    $band = if ($score -le 10) { 'Low' } elseif ($score -le 40) { 'Medium' } elseif ($score -le 70) { 'High' } else { 'Critical' }
    $pct = [Math]::Round(100.0 * $reach / $ItemsScanned, 2)
    return @{ Score = $score; Band = $band; WeightedReach = $weighted; ExposedPercent = $pct }
}

function Get-CountTable {
    # Group by a property; returns ordered list of @{ <Label>=value; Count=n } sorted by Count desc.
    # PowerShell Sort-Object is stable: ties keep insertion order from the map.
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
        $p = $f.PSObject.Properties['Reach']
        if ($p -and $null -ne $p.Value) { $reach = [int]$p.Value }
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
    # Temp file (.tmp.xlsx, ImportExcel requires an .xlsx extension) + Move-Item so a
    # failed write never leaves a half workbook at the final path.
    param([object[]]$Findings, [object[]]$Targets, [string]$TabName, [string]$ScopeLabel, [string]$SiteTag, [bool]$IncludeSites)
    if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Path $script:ExportDir -Force | Out-Null }
    $path = Join-Path $script:ExportDir (Get-ReportFileName -TabName $TabName -SiteTag $SiteTag)
    $tmp = [IO.Path]::ChangeExtension($path, '.tmp.xlsx')
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
        # Colors as literal RGB (not FromName) to avoid platform/font-resolution issues on Linux/macOS.
        $rgb = switch ($exp.Band) {
            'Low' { 144, 238, 144 } 'Medium' { 240, 230, 140 } 'High' { 255, 165, 0 } 'Critical' { 255, 99, 71 } default { 211, 211, 211 }
        }
        $ws.Cells["B$scoreRow"].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2]))
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

#endregion
