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

#endregion
