# ============================================================================
#region Connections
# ============================================================================

function Get-ConnectParams {
    # Splat for Connect-PnPOnline, from the configured auth mode.
    param([string]$Url)
    $p = @{ Url = $Url; ClientId = $script:Auth.ClientId }
    if ($script:Auth.AuthMode -eq 'AppOnly') {
        $p.Tenant = $script:Auth.Tenant
        if ($script:Auth.Thumbprint) { $p.Thumbprint = $script:Auth.Thumbprint }
        else { $p.CertificatePath = $script:Auth.CertPath }
    } else {
        $p.Interactive = $true
    }
    return $p
}

#endregion
