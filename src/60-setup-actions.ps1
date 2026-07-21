# ============================================================================
#region Setup actions
# ============================================================================

function Get-SsmObjectProp {
    # ponytail: StrictMode -Version 2 throws on direct dot-access to a
    # missing property (the brief's `$obj.Foo ?? $obj.Bar` chains would
    # break instead of falling back). Check existence first, then read.
    # Also multi-object-output-safe: some PnP registration cmdlets emit an
    # informational string alongside the result object, so a single
    # assignment can collapse to an array. Scan every element for the first
    # matching, non-empty property value.
    param($InputObject, [string[]]$Name)
    foreach ($obj in @($InputObject)) {
        if (-not $obj) { continue }
        $names = @($obj.PSObject.Properties.Name)
        foreach ($n in $Name) {
            if ($names -contains $n) {
                $v = $obj.PSObject.Properties[$n].Value
                if ($v) { return $v }
            }
        }
    }
    return $null
}

function Get-SsmTenantInput {
    # Ask for (and remember) the *.onmicrosoft.com tenant name.
    if ($script:Auth.Tenant) { return $script:Auth.Tenant }
    $t = Show-InputModal -Title 'Tenant' -Prompt 'e.g. contoso.onmicrosoft.com'
    if ($t) { $script:Auth.Tenant = $t.Trim() }
    return $script:Auth.Tenant
}

function Register-SsmDelegatedApp {
    # Delegated interactive app (Register-PnPEntraIDAppForInteractiveLogin).
    # Any user may create it; a Global Admin consents once. Limitation shown:
    # the operator must be Site Collection Admin on every target OneDrive.
    if (-not (Install-SsmModule)) { return }
    $tenant = Get-SsmTenantInput; if (-not $tenant) { return }
    $ok = Show-ConfirmModal -Title 'Register delegated app' -Lines @(
        "Creates app 'SharePoint-Sharing-Manager' in $tenant for interactive sign-in.",
        'A browser window will open. A Global Admin must consent once.', '',
        'Note: delegated mode requires YOU to be Site Collection Admin on each',
        'target site/OneDrive. The app-only certificate mode (C) avoids that.')
    if (-not $ok) { return }
    try {
        $result = $null
        Invoke-OnMainBuffer {
            $script:RegResult = Register-PnPEntraIDAppForInteractiveLogin -ApplicationName 'SharePoint-Sharing-Manager' -Tenant $tenant -ErrorAction Stop
        }
        $result = $script:RegResult
        $appId = [string](Get-SsmObjectProp -InputObject $result -Name @('AzureAppId/ClientId', 'AzureAppId', 'ClientId'))
        if (-not $appId) { throw 'No app id returned - check the console output.' }
        $script:Auth.AuthMode = 'Delegated'; $script:Auth.ClientId = $appId
        Save-SsmAuth
        Show-MsgModal -Title 'Registered' -Lines @("Client Id: $appId", 'Saved to config. Delegated mode is now active.')
    } catch {
        Write-SsmLog -Message ("Delegated app registration failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @($_.Exception.Message) -Kind Error
    }
}

function Register-SsmAppOnlyApp {
    # App-only certificate app via Register-PnPAzureADApp -ValidYears 1 with
    # application permissions Sites.FullControl.All (SharePoint + Graph).
    # Creating the app needs Application Administrator; ADMIN CONSENT for the
    # application permissions needs Global Admin / Privileged Role Admin - the
    # cmdlet opens the consent URL, which can be forwarded.
    if (-not (Install-SsmModule)) { return }
    $tenant = Get-SsmTenantInput; if (-not $tenant) { return }
    $ok = Show-ConfirmModal -Title 'Register app-only certificate app' -Lines @(
        "Creates app 'SharePoint-Sharing-Manager' in $tenant with APPLICATION",
        'permissions Sites.FullControl.All (SharePoint + Graph) and a self-signed',
        'certificate valid for 1 YEAR, uploaded to the app.', '',
        'Requires: Application Administrator (to create the app).',
        'Admin consent requires Global Admin - the consent URL will be shown',
        'and can be forwarded if that is someone else.')
    if (-not $ok) { return }
    try {
        $outDir = Join-Path $HOME '.sharepoint-sharing-manager-cert'
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
        Invoke-OnMainBuffer {
            $splat = @{
                ApplicationName                  = 'SharePoint-Sharing-Manager'
                Tenant                            = $tenant
                ValidYears                        = 1
                SharePointApplicationPermissions  = 'Sites.FullControl.All'
                GraphApplicationPermissions       = 'Sites.FullControl.All'
                OutPath                           = $outDir
            }
            if ($script:IsWin) { $splat.Store = 'CurrentUser' }
            $script:RegResult = Register-PnPAzureADApp @splat -ErrorAction Stop
        }
        $r = $script:RegResult
        $appId = [string](Get-SsmObjectProp -InputObject $r -Name @('AzureAppId/ClientId', 'AzureAppId', 'ClientId'))
        $thumb = [string](Get-SsmObjectProp -InputObject $r -Name @('Certificate Thumbprint', 'CertificateThumbprint'))
        if (-not $appId) { throw 'No app id returned - check the console output.' }
        $script:Auth.AuthMode = 'AppOnly'
        $script:Auth.ClientId = $appId
        $script:Auth.Thumbprint = if ($script:IsWin) { $thumb } else { '' }
        $script:Auth.CertPath = if ($script:IsWin) { '' } else { (Join-Path $outDir 'SharePoint-Sharing-Manager.pfx') }
        $script:Auth.CertExpires = (Get-Date).AddYears(1).ToString('yyyy-MM-dd')
        Save-SsmAuth
        Show-MsgModal -Title 'Registered' -Lines @(
            "Client Id : $appId",
            ("Cert until: {0}" -f $script:Auth.CertExpires),
            'App-only mode is now active.', '',
            'If consent was not granted yet, a Global Admin must approve the',
            'consent URL printed in the console before connections will work.')
    } catch {
        Write-SsmLog -Message ("App-only registration failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @($_.Exception.Message) -Kind Error
    }
}

function Update-SsmCertificate {
    # Renew: generate a fresh 1-year self-signed cert and upload it to the
    # EXISTING app via Graph (addKey). Needs Application Administrator; no new
    # consent. Implementation: New-PnPAzureCertificate for the cert, then
    # Connect-PnPOnline with the OLD cert and Invoke-PnPGraphMethod POST
    # /applications(appId='<ClientId>')/addKey with the new public key.
    if ($script:Auth.AuthMode -ne 'AppOnly' -or -not $script:Auth.ClientId) {
        Show-MsgModal -Title 'Renew certificate' -Lines @('Only applies to app-only mode with a registered app.') -Kind Warn
        return
    }
    Show-MsgModal -Title 'Renew certificate' -Lines @(
        'Renewal steps (guided):',
        '1. A new 1-year self-signed certificate is generated locally.',
        '2. Sign in as Application Administrator when prompted.',
        '3. The new cert is added to the existing app; the old one keeps',
        '   working until its own expiry.', '',
        'Continue in the console...')
    try {
        $outDir = Join-Path $HOME '.sharepoint-sharing-manager-cert'
        $stamp = Get-Date -Format 'yyyyMMdd'
        Invoke-OnMainBuffer {
            $cert = New-PnPAzureCertificate -CommonName 'SharePoint-Sharing-Manager' -ValidYears 1 -OutPfx (Join-Path $outDir "renewed-$stamp.pfx") -OutCert (Join-Path $outDir "renewed-$stamp.cer")
            Write-Host 'New certificate generated. Uploading to the app registration...' -ForegroundColor Yellow
            Connect-PnPOnline -Url ("https://{0}" -f ($script:Auth.Tenant -replace '\.onmicrosoft\.com$', '.sharepoint.com')) -Interactive -ClientId $script:Auth.ClientId
            $keyCreds = @{ keyCredential = @{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = $cert.Certificate }; proof = $null }
            Invoke-PnPGraphMethod -Method Post -Url ("applications(appId='{0}')/addKey" -f $script:Auth.ClientId) -Content $keyCreds
            $script:RenewedCert = $cert
        }
        $script:Auth.CertExpires = (Get-Date).AddYears(1).ToString('yyyy-MM-dd')
        if ($script:IsWin -and $script:RenewedCert.Thumbprint) { $script:Auth.Thumbprint = $script:RenewedCert.Thumbprint }
        else { $script:Auth.CertPath = Join-Path $outDir "renewed-$stamp.pfx" }
        Save-SsmAuth
        Show-MsgModal -Title 'Renewed' -Lines @(("New certificate active until {0}." -f $script:Auth.CertExpires))
    } catch {
        Write-SsmLog -Message ("Certificate renewal failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @(
            $_.Exception.Message, '',
            'Fallback: run Register-PnPAzureADApp again (C) or add a certificate',
            'to the app manually in the Entra portal.') -Kind Error
    }
}

function Edit-SsmConfig {
    # Minimal field editor: prompt for each config field, empty keeps current.
    foreach ($field in @('AuthMode', 'ClientId', 'Tenant', 'AdminUrl', 'Thumbprint', 'CertPath', 'CertExpires')) {
        $v = Show-InputModal -Title "Config: $field" -Prompt 'Empty = keep current' -Default $script:Auth[$field]
        if ($null -ne $v -and $v -ne '') { $script:Auth[$field] = $v.Trim() }
    }
    Save-SsmAuth
    $script:UI.Dirty = $true
}

#endregion
