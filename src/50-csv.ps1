# ============================================================================
#region CSV evidence & export
# ============================================================================

function Export-FindingsCsv {
    param($Findings, [string]$SiteUrl, [ValidateSet('BEFORE','REVOKED')][string]$Phase)
    if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Path $script:ExportDir | Out-Null }
    $tag   = ($SiteUrl.TrimEnd('/') -split '/')[-1]
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path  = Join-Path $script:ExportDir ("SSM_{0}_{1}_{2}.csv" -f $Phase, $tag, $stamp)
    $Findings | Select-Object Site, Location, Category, Name, Access, Principal, Path, LinkCreated, RevokeStatus |
        Export-Csv -Path $path -Encoding UTF8BOM
    Write-SsmLog -Message ("{0} evidence: {1}" -f $Phase, $path)
    return $path
}

function Export-SsmAdminCsv {
    # Dedicated secondary-admin evidence export. Never mixed into the
    # findings CSV schema/columns. Writes to a same-directory temporary file
    # first and only replaces the final path once serialization succeeds, so
    # a failed write (disk full, locked file) never leaves a half-written or
    # missing evidence file in place.
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][guid]$OperationId,
        [Parameter(Mandatory)][ValidateSet('BEFORE', 'AFTER')][string]$Phase
    )
    if (-not (Test-Path -LiteralPath $script:ExportDir)) {
        New-Item -ItemType Directory -Path $script:ExportDir -Force | Out-Null
    }
    $columns = @(
        'OperationId', 'TimestampUtc', 'ResultTimestampUtc', 'TenantId', 'Actor', 'Action', 'TargetUrl',
        'EnteredUpn', 'ResolvedUpn', 'ResolvedUserId', 'OwnerUpn', 'OwnerId',
        'PrimaryAdminUpn', 'PrimaryAdminId', 'AdminLogin', 'AdminBefore', 'AdminAfter',
        'Result', 'Error'
    )
    $path = Join-Path $script:ExportDir ("SSM_ADMIN_{0}_{1}.csv" -f $Phase, $OperationId)
    $tmp = "$path.tmp"
    try {
        $Rows | Select-Object $columns | Export-Csv -LiteralPath $tmp -Encoding UTF8BOM -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw "Export-SsmAdminCsv: failed to write $Phase evidence: $($_.Exception.Message)"
    }
    Write-SsmLog -Message ("{0} admin evidence: {1}" -f $Phase, $path)
    return $path
}

function Export-ViewCsv {
    # Export the current view (targets or findings) for the active tab.
    param($Tab)
    if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Path $script:ExportDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ($Tab['Mode'] -eq 'Findings' -and $Tab['FTab']) {
        $path = Join-Path $script:ExportDir ("{0}_findings_{1}.csv" -f $Tab['Name'], $stamp)
        @($Tab['FTab']['View']) | Select-Object Site, Location, Category, Name, Access, Principal, Path, LinkCreated, RevokeStatus |
            Export-Csv -Path $path -Encoding UTF8BOM
    } else {
        $path = Join-Path $script:ExportDir ("{0}_targets_{1}.csv" -f $Tab['Name'], $stamp)
        @($Tab['View']) | ForEach-Object { [pscustomobject]@{ Url=$_.Url; Title=$_.Title; Status=$_.Status; Findings=$_.FindingCount } } |
            Export-Csv -Path $path -Encoding UTF8BOM
    }
    Show-MsgModal -Title 'Exported' -Lines @('View exported to:', $path)
}

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
    @($Rows) | Select-Object $columns | Export-Csv -LiteralPath $path -Encoding UTF8BOM
    Write-SsmLog -Message ("Pre-provision {0} evidence: {1}" -f $Phase, $path)
    return $path
}

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
    $ownerMap = $null; $note = @()
    if ($Tab['OneDrive']) {
        # OneDrive owner Entra object ids come from Graph at export time, so
        # cached and CSV-imported lists resolve too. Failure leaves the
        # columns blank instead of blocking the report.
        $ownerMap = @{}
        $title = 'Resolving OneDrive owners'
        if (Connect-SsmAdmin) {
            Start-LoadSpinner
            Write-ProgressModal -Title $title -Done 0 -Total 0 -Label 'Querying Graph for users' -Ok 0 -Failed 0
            try {
                $ownerMap = Get-SsmUserIdMap -Progress { param($n)
                    Write-ProgressModal -Title $title -Done $n -Total 0 -Label 'Querying Graph for users' -Ok 0 -Failed 0 }
            } catch {
                Write-SsmErrorLog -Context 'Excel report: Graph user query failed' -ErrorRecord $_
                $note = @('', 'Owner Object ID column is blank: the Graph user query failed', '(needs User.Read.All). See the Log tab.')
            } finally { Stop-LoadSpinner }
        } else {
            $note = @('', 'Owner Object ID column is blank: no tenant connection.')
        }
    }
    try {
        $path = Export-FindingsXlsx -Findings $scope.Findings -Targets $scope.Targets -TabName $Tab['Name'] -ScopeLabel $scope.ScopeLabel -SiteTag $scope.SiteTag -IncludeSites $scope.IncludeSites -OwnerMap $ownerMap
        Show-MsgModal -Title 'Exported' -Lines (@('Excel report written to:', $path) + $note)
    } catch {
        Write-SsmErrorLog -Context 'Excel report export failed' -ErrorRecord $_
        Show-MsgModal -Title 'Export failed' -Lines @($_.Exception.Message, 'See the Log tab. CSV export is still available.') -Kind Error
    }
}

#endregion
