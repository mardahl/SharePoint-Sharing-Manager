# ============================================================================
#region CSV evidence & export
# ============================================================================

function Export-FindingsCsv {
    param($Findings, [string]$SiteUrl, [ValidateSet('BEFORE','REVOKED')][string]$Phase)
    if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Path $script:ExportDir | Out-Null }
    $tag   = ($SiteUrl.TrimEnd('/') -split '/')[-1]
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path  = Join-Path $script:ExportDir ("SSM_{0}_{1}_{2}.csv" -f $Phase, $tag, $stamp)
    $Findings | Select-Object Site, Location, Category, Name, Access, Principal, Path, RevokeStatus |
        Export-Csv -Path $path -NoTypeInformation -Encoding UTF8BOM
    Write-SsmLog -Message ("{0} evidence: {1}" -f $Phase, $path)
    return $path
}

function Export-ViewCsv {
    # Export the current view (targets or findings) for the active tab.
    param($Tab)
    if (-not (Test-Path -LiteralPath $script:ExportDir)) { New-Item -ItemType Directory -Path $script:ExportDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ($Tab['Mode'] -eq 'Findings' -and $Tab['FTab']) {
        $path = Join-Path $script:ExportDir ("{0}_findings_{1}.csv" -f $Tab['Name'], $stamp)
        @($Tab['FTab']['View']) | Select-Object Site, Location, Category, Name, Access, Principal, Path, RevokeStatus |
            Export-Csv -Path $path -NoTypeInformation -Encoding UTF8BOM
    } else {
        $path = Join-Path $script:ExportDir ("{0}_targets_{1}.csv" -f $Tab['Name'], $stamp)
        @($Tab['View']) | ForEach-Object { [pscustomobject]@{ Url=$_.Url; Title=$_.Title; Status=$_.Status; Findings=$_.FindingCount } } |
            Export-Csv -Path $path -NoTypeInformation -Encoding UTF8BOM
    }
    Show-MsgModal -Title 'Exported' -Lines @('View exported to:', $path)
}

#endregion
