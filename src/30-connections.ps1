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

function Connect-SsmSite {
    # Connect (or reuse) a PnP connection to a specific site/OneDrive URL.
    param([string]$Url)
    if (-not (Install-SsmModule)) { return $false }
    if (-not (Test-SsmAuthReady)) {
        Show-MsgModal -Title 'Not configured' -Lines @(
            'No usable sign-in configuration.',
            'Go to the Setup tab (4) to register an app or enter a Client Id.') -Kind Warn
        return $false
    }
    $norm = $Url.TrimEnd('/')
    if ($script:Conn.Url -eq $norm) { return $true }
    try {
        $p = Get-ConnectParams -Url $norm
        if ($script:Auth.AuthMode -eq 'Delegated') {
            # Interactive auth needs the main buffer so the browser/consent
            # prompt and any console messages are visible instead of hidden
            # behind the alternate-screen TUI. Run the connect there too, not
            # just the "Signing in" line.
            Invoke-OnMainBuffer {
                Write-Host ("Signing in to {0} ..." -f $norm) -ForegroundColor Yellow
                Connect-PnPOnline @p -ErrorAction Stop
            }
        } else {
            Connect-PnPOnline @p -ErrorAction Stop
        }
        $script:Conn.Url = $norm
        $script:Conn.Admin = ($norm -like '*-admin.sharepoint.com*')
        if ($script:Auth.AuthMode -eq 'AppOnly') {
            $script:Conn.Account = 'app:' + $script:Auth.ClientId.Substring(0, 8)
        } else {
            # Delegated: read the signed-in user's identity off the connected web.
            try { $script:Conn.Account = (Get-PnPProperty -ClientObject (Get-PnPWeb) -Property CurrentUser).Email }
            catch { $script:Conn.Account = 'delegated' }
            if (-not $script:Conn.Account) { $script:Conn.Account = 'delegated' }
        }
        Write-SsmLog -Message ("Connected to {0}" -f $norm) -Level OK
        return $true
    } catch {
        Write-SsmErrorLog -Context ("Connect failed for {0}" -f $norm) -ErrorRecord $_
        $script:Conn.Url = ''
        return $false
    }
}

function Connect-SsmAdmin {
    # Connect to the tenant admin site (for Get-PnPTenantSite / Set-PnPTenant).
    # AdminUrl is derived from Tenant (contoso.onmicrosoft.com -> https://
    # contoso-admin.sharepoint.com) rather than asked for separately - the
    # tenant name is already known from setup/registration.
    if (-not $script:Auth.AdminUrl) {
        $tenant = Get-SsmTenantInput
        if (-not $tenant) { return $false }
        $prefix = $tenant -replace '\.onmicrosoft\.com$', ''
        $script:Auth.AdminUrl = "https://$prefix-admin.sharepoint.com"
        Save-SsmAuth
    }
    return (Connect-SsmSite -Url $script:Auth.AdminUrl)
}

function Test-SsmSiteLocked {
    # True when an error record is the SPO front-door "site inaccessible" block:
    # HTTP 403 Forbidden with an EMPTY response content-type. That signature
    # means the site is locked (LockState=NoAccess) or deprovisioned - typically
    # a OneDrive still pending deletion after the user was removed. A genuine
    # app-permission 403 returns a NON-empty (JSON/XML) body, so it won't match.
    # Connect-PnPOnline only acquires a token and succeeds; the lock only shows
    # on the first real CSOM call (e.g. Get-PnPWeb), which is why it lands here.
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        $m = [string]$ex.Message
        if ($m -match 'content type of the response is\s*""' -and $m -match 'Forbidden') {
            return $true
        }
        $ex = $ex.InnerException
    }
    return $false
}

function Disconnect-SsmConnection {
    try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
    $script:Conn.Url = ''; $script:Conn.Admin = $false; $script:Conn.Account = ''
    Write-SsmLog -Message 'Disconnected.'
}

#endregion
