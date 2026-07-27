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

function Get-CommonUrlPrefix {
    # Longest common prefix of the given URLs, truncated back to and including
    # the last '/', so the remainder is always a whole path segment. Used to
    # print a shared site-collection prefix once instead of on every line.
    # Returns '' when there is nothing worth factoring out.
    param([string[]]$Urls)

    $list = @($Urls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($list.Count -lt 2) { return '' }

    $prefix = $list[0]
    foreach ($u in $list) {
        $max = [Math]::Min($prefix.Length, $u.Length)
        $i = 0
        while ($i -lt $max -and $prefix[$i] -eq $u[$i]) { $i++ }
        $prefix = $prefix.Substring(0, $i)
        if ($prefix.Length -eq 0) { return '' }
    }

    # Trim back to a segment boundary so a partial name is never shown as shared.
    $cut = $prefix.LastIndexOf('/')
    if ($cut -lt 0) { return '' }
    $prefix = $prefix.Substring(0, $cut + 1)

    # Below this length the header costs more lines than it saves.
    if ($prefix.Length -le 16) { return '' }
    return $prefix
}

#endregion

# ============================================================================
#region Revoke - execution (PnP-bound, no unit tests)
# ============================================================================

function Invoke-Revoke {
    # Remove all given findings against the currently-connected site; sets
    # RevokeStatus per finding and returns the count removed.
    #
    # -State is the shared progress/cancel hashtable (see
    # New-SsmProgressCallback). When its Cancel key is set, the loop stops
    # after the finding in flight and returns normally, so the caller still
    # exports evidence and saves the cache for the work actually done.
    param($Findings, [scriptblock]$Progress, [hashtable]$State)
    $removed = 0; $failed = 0; $i = 0
    $ordered = Get-RevokeOrder -Findings $Findings
    $total = @($ordered).Count
    foreach ($f in $ordered) {
        $i++
        if ($Progress) {
            & $Progress -Count $i -Total $total -Label ("Revoking {0} / {1}: {2}" -f $i, $total, $f.Name) -Ok $removed -Failed $failed
        }
        try {
            if ($f.RemovalKind -eq 'Link') {
                if ([string]::IsNullOrWhiteSpace($f.LinkId)) { $f.RevokeStatus = 'Skipped: empty LinkId'; $failed++; continue }
                if ($f.Location -eq 'File') { Remove-PnPFileSharingLink -FileUrl $f.Path -Identity $f.LinkId -Force -ErrorAction Stop }
                else { Remove-PnPFolderSharingLink -Folder $f.Path -Identity $f.LinkId -Force -ErrorAction Stop }
            } else {   # DirectGrant
                if (-not $f.PrincipalId) { $f.RevokeStatus = 'Skipped: no PrincipalId'; $failed++; continue }
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
                $failed++
            }
        }
        if ($State -and $State.Cancel) { break }
    }
    return $removed
}

#endregion
