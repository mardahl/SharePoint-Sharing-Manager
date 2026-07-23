# ============================================================================
#region Revoke - ordering (pure)
# ============================================================================

function Get-RevokeOrder {
    # Links before direct grants; leaf grants (File/Folder) before Library
    # before Web, so a single claim principal (e.g. EEEU) is not
    # de-provisioned out from under later removals.
    param($Findings)
    $depth = @{ 'File' = 0; 'Folder' = 0; 'Library' = 1; 'Web' = 2 }
    return @($Findings | Sort-Object `
        @{ Expression = { if ($_.RemovalKind -eq 'Link') { 0 } else { 1 } } }, `
        @{ Expression = { $depth[$_.Location] } })
}

function Group-FindingsBySite {
    # Group findings by their source Site URL for per-site bulk revocation.
    param($Findings)
    return @(@($Findings) | Group-Object -Property Site)
}

#endregion

# ============================================================================
#region Revoke - execution (PnP-bound, no unit tests)
# ============================================================================

function Invoke-Revoke {
    # Remove all given findings against the currently-connected site; sets
    # RevokeStatus per finding and returns the count removed.
    param($Findings, [scriptblock]$Progress)
    $removed = 0; $i = 0
    $ordered = Get-RevokeOrder -Findings $Findings
    foreach ($f in $ordered) {
        $i++
        if ($Progress) { & $Progress -Count $i -Label ("Revoking {0} / {1}: {2}" -f $i, @($ordered).Count, $f.Name) }
        try {
            if ($f.RemovalKind -eq 'Link') {
                if ([string]::IsNullOrWhiteSpace($f.LinkId)) { $f.RevokeStatus = 'Skipped: empty LinkId'; continue }
                if ($f.Location -eq 'File') { Remove-PnPFileSharingLink -FileUrl $f.Path -Identity $f.LinkId -Force -ErrorAction Stop }
                else { Remove-PnPFolderSharingLink -Folder $f.Path -Identity $f.LinkId -Force -ErrorAction Stop }
            } else {   # DirectGrant
                if (-not $f.PrincipalId) { $f.RevokeStatus = 'Skipped: no PrincipalId'; continue }
                $sec = switch ($f.Location) {
                    'Web'     { Get-PnPWeb }
                    'Library' { Get-PnPList -Identity $f.ListId }
                    default   { Get-PnPListItem -List $f.ListId -Id $f.ItemId }   # File / Folder
                }
                $sec.RoleAssignments.GetByPrincipalId([int]$f.PrincipalId).DeleteObject()
                Invoke-PnPQuery
            }
            $f.RevokeStatus = 'Removed'; $removed++
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'find the principal' -or $msg -match 'does not exist' -or $msg -match 'Cannot find') {
                # Principal already gone (e.g. a single claim like EEEU removed at its leaf grant
                # cascades away site-wide). End state is what we wanted, so count it as success.
                $f.RevokeStatus = 'AlreadyRevoked'; $removed++
            } else {
                $f.RevokeStatus = "Failed: $msg"
            }
        }
    }
    return $removed
}

#endregion
