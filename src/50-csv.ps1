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
        Export-Csv -Path $path -NoTypeInformation -Encoding UTF8BOM
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
        $Rows | Select-Object $columns | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8BOM -ErrorAction Stop
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
            Export-Csv -Path $path -NoTypeInformation -Encoding UTF8BOM
    } else {
        $path = Join-Path $script:ExportDir ("{0}_targets_{1}.csv" -f $Tab['Name'], $stamp)
        @($Tab['View']) | ForEach-Object { [pscustomobject]@{ Url=$_.Url; Title=$_.Title; Status=$_.Status; Findings=$_.FindingCount } } |
            Export-Csv -Path $path -NoTypeInformation -Encoding UTF8BOM
    }
    Show-MsgModal -Title 'Exported' -Lines @('View exported to:', $path)
}

#endregion
