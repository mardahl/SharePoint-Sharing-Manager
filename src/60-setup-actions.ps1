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
        Write-SsmErrorLog -Context 'Delegated app registration failed' -ErrorRecord $_
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
        # Per-tenant PFX name: Register-PnPAzureADApp writes a fixed
        # 'SharePoint-Sharing-Manager.pfx' into -OutPath, which would clobber
        # the previous tenant's key when a second tenant registers. Move it to
        # a tenant-slug name right after registration.
        $certPath = ''
        if (-not $script:IsWin) {
            $fixed = Join-Path $outDir 'SharePoint-Sharing-Manager.pfx'
            $slug  = ConvertTo-SsmTenantSlug -Name ($tenant -replace '\.onmicrosoft\.com$', '')
            $named = Join-Path $outDir ("SharePoint-Sharing-Manager-{0}.pfx" -f $slug)
            if ((Test-Path -LiteralPath $fixed) -and $fixed -ne $named) {
                Move-Item -LiteralPath $fixed -Destination $named -Force
            }
            $certPath = if (Test-Path -LiteralPath $named) { $named } else { $fixed }
        }
        $script:Auth.CertPath = $certPath
        $script:Auth.CertExpires = (Get-Date).AddYears(1).ToString('yyyy-MM-dd')
        Save-SsmAuth
        Show-MsgModal -Title 'Registered' -Lines @(
            "Client Id : $appId",
            ("Cert until: {0}" -f $script:Auth.CertExpires),
            'App-only mode is now active.', '',
            'If consent was not granted yet, a Global Admin must approve the',
            'consent URL printed in the console before connections will work.')
    } catch {
        if ($_.Exception.Message -match 'already exists') {
            Write-SsmLog -Message 'App already exists - offering re-key of the existing registration.'
            Add-SsmCertToExistingApp -Tenant $tenant
            return
        }
        Write-SsmErrorLog -Context 'App-only registration failed' -ErrorRecord $_
        Show-MsgModal -Title 'Failed' -Lines @($_.Exception.Message) -Kind Error
    }
}

# PnP Management Shell: Microsoft's multi-tenant app for operator-context
# (delegated) PnP sign-ins. Carries the delegated Graph scopes needed to
# manage app registrations (Application.ReadWrite.All). The tenant's own
# app-only registration must NOT be used for operator sign-ins - it has only
# application permissions, so its delegated tokens get Forbidden from Graph
# no matter how powerful the signed-in account is. First use in a tenant
# prompts for admin consent.
$script:PnPManagementShellClientId = '31359c7f-bd7e-475c-86db-fdb8c937548e'

function Connect-SsmOperatorGraph {
    # Operator-context connection for Graph app-management calls (addKey,
    # delete application). Signs in interactively via the PnP Management
    # Shell app so the token carries DELEGATED scopes + the operator's role.
    param([Parameter(Mandatory)][string]$Tenant)
    $tenantShort = $Tenant -replace '\.onmicrosoft\.com$', ''
    $rootUrl = "https://{0}.sharepoint.com" -f $tenantShort
    # ponytail: -ForceAuthentication avoids PnP silently reusing a cached
    # token for a different tenant (which produced AADSTS700016 "app not
    # found in directory <guid>" - the request then lands in the tenant of
    # the cached session, where PnP Management Shell has no service
    # principal yet, instead of the intended one).
    Connect-PnPOnline -Url $rootUrl -Interactive -ClientId $script:PnPManagementShellClientId -Tenant $Tenant -ForceAuthentication -ErrorAction Stop
}

function Add-SsmCertToExistingApp {
    # Fallback when Register-PnPAzureADApp fails with "already exists": the app
    # from a previous (possibly clobbered) registration is still in Entra. Look
    # up its ClientId by display name, generate a fresh cert, upload via Graph
    # addKey, and point this tenant's config at it. Needs Application
    # Administrator sign-in (interactive) to call addKey.
    param([Parameter(Mandatory)][string]$Tenant)
    $ok = Show-ConfirmModal -Title 'App already exists' -Lines @(
        "An app named 'SharePoint-Sharing-Manager' already exists in $Tenant.",
        'This happens when re-registering after an earlier setup.', '',
        'Reuse it: generate a NEW certificate and attach it to the existing app?',
        '(You will sign in interactively as Application Administrator.)')
    if (-not $ok) { return }
    try {
        $outDir = Join-Path $HOME '.sharepoint-sharing-manager-cert'
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
        $slug  = ConvertTo-SsmTenantSlug -Name ($Tenant -replace '\.onmicrosoft\.com$', '')
        $stamp = Get-Date -Format 'yyyyMMdd'
        $pfx   = Join-Path $outDir "SharePoint-Sharing-Manager-$slug.pfx"
        Invoke-OnMainBuffer {
            Connect-SsmOperatorGraph -Tenant $Tenant
            $app = Get-PnPAzureADApp -Identity 'SharePoint-Sharing-Manager' -ErrorAction Stop
            $script:ExistingAppId = [string]$app.AzureAppId
            if (-not $script:ExistingAppId) { throw "App 'SharePoint-Sharing-Manager' found but no Client Id returned." }
            $cert = New-PnPAzureCertificate -CommonName 'SharePoint-Sharing-Manager' -ValidYears 1 -OutPfx $pfx -OutCert ($pfx -replace '\.pfx$', '.cer')
            $keyCreds = @{ keyCredential = @{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = $cert.Certificate }; proof = $null }
            Invoke-PnPGraphMethod -Method Post -Url ("applications(appId='{0}')/addKey" -f $script:ExistingAppId) -Content $keyCreds -ErrorAction Stop
            $script:RekeyThumb = [string]$cert.Thumbprint
        }
        $script:Auth.AuthMode = 'AppOnly'
        $script:Auth.ClientId = $script:ExistingAppId
        if ($script:IsWin -and $script:RekeyThumb) {
            $script:Auth.Thumbprint = $script:RekeyThumb
            $script:Auth.CertPath = ''
        } else {
            $script:Auth.Thumbprint = ''
            $script:Auth.CertPath = $pfx
        }
        $script:Auth.CertExpires = (Get-Date).AddYears(1).ToString('yyyy-MM-dd')
        Save-SsmAuth
        Show-MsgModal -Title 'Re-keyed' -Lines @(
            "Client Id : $($script:ExistingAppId)",
            ("Cert until: {0}" -f $script:Auth.CertExpires),
            'New certificate attached to the existing app. App-only mode is active.')
    } catch {
        Write-SsmErrorLog -Context 'Re-key of existing app failed' -ErrorRecord $_
        $msg = @($_.Exception.Message, '')
        if ($_.Exception.Message -match 'AADSTS700016') {
            # PnP Management Shell has no service principal in this tenant yet
            # and the interactive flow did not trigger consent (usually a stale
            # cached session). Consent once via the adminconsent endpoint.
            $msg += @(
                'The PnP Management Shell app is not consented in this tenant yet.',
                'Open this URL as Global Admin, consent, then retry:', '',
                ("https://login.microsoftonline.com/{0}/adminconsent?client_id={1}" -f $Tenant, $script:PnPManagementShellClientId))
        } elseif ($_.Exception.Message -match 'Forbidden|Insufficient privileges') {
            $msg += @(
                'The signed-in account needs Application Administrator (or',
                'higher) in this tenant to add a key to the app.',
                '',
                'Or delete the app in the Entra portal and register again (C).')
        } else {
            $msg += 'Alternative: delete the app in the Entra portal, then register again.'
        }
        Show-MsgModal -Title 'Failed' -Lines $msg -Kind Error
    }
}

function Update-SsmCertificate {
    # Renew: generate a fresh 1-year self-signed cert and upload it to the
    # EXISTING app via Graph (addKey). Needs Application Administrator; no new
    # consent. Implementation: New-PnPAzureCertificate for the cert, then an
    # operator-context (delegated) Graph addKey on
    # /applications(appId='<ClientId>') with the new public key.
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
        $slug  = ConvertTo-SsmTenantSlug -Name ($script:Auth.Tenant -replace '\.onmicrosoft\.com$', '')
        Invoke-OnMainBuffer {
            $cert = New-PnPAzureCertificate -CommonName 'SharePoint-Sharing-Manager' -ValidYears 1 -OutPfx (Join-Path $outDir "renewed-$slug-$stamp.pfx") -OutCert (Join-Path $outDir "renewed-$slug-$stamp.cer")
            Write-Host 'New certificate generated. Uploading to the app registration...' -ForegroundColor Yellow
            Connect-SsmOperatorGraph -Tenant $script:Auth.Tenant
            $keyCreds = @{ keyCredential = @{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = $cert.Certificate }; proof = $null }
            Invoke-PnPGraphMethod -Method Post -Url ("applications(appId='{0}')/addKey" -f $script:Auth.ClientId) -Content $keyCreds
            $script:RenewedCert = $cert
        }
        $script:Auth.CertExpires = (Get-Date).AddYears(1).ToString('yyyy-MM-dd')
        if ($script:IsWin -and $script:RenewedCert.Thumbprint) { $script:Auth.Thumbprint = $script:RenewedCert.Thumbprint }
        else { $script:Auth.CertPath = Join-Path $outDir "renewed-$slug-$stamp.pfx" }
        Save-SsmAuth
        Show-MsgModal -Title 'Renewed' -Lines @(("New certificate active until {0}." -f $script:Auth.CertExpires))
    } catch {
        Write-SsmErrorLog -Context 'Certificate renewal failed' -ErrorRecord $_
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

function Remove-SsmAppRegistration {
    # Deletes the Entra app + local cert for the active tenant, then blanks
    # the auth fields (Tenant/AdminUrl stay so re-registration is quick).
    # No abort on first failure - each step's error is collected and shown.
    if (-not $script:Auth.ClientId) {
        Show-MsgModal -Title 'Remove app registration' -Lines @('No app registration on this tenant.') -Kind Warn
        return
    }
    $lines = @(
        'This will delete:', '',
        ("Auth mode   {0}" -f $script:Auth.AuthMode),
        ("Client Id   {0}" -f $script:Auth.ClientId)
    )
    if ($script:Auth.Thumbprint -and $script:IsWin) { $lines += ("Cert        CurrentUser\My\{0}" -f $script:Auth.Thumbprint) }
    elseif ($script:Auth.CertPath) { $lines += ("PFX file    {0}" -f $script:Auth.CertPath) }
    $lines += '', 'Tenant name, admin URL, scan cache and exports are kept.'
    $ok = Show-TypedConfirmModal -Title 'Remove app registration' -Word 'REMOVE' -Lines $lines
    if (-not $ok) { return }

    $errors = @()
    $appDeleted = $false
    $certDeleted = $false

    # Step 1: delete the Entra app via operator-context (delegated) Graph.
    # Needs the operator to hold Application Administrator / Cloud App Admin /
    # Global Admin AND the sign-in client to carry delegated
    # Application.ReadWrite.All - hence the PnP Management Shell app, not the
    # tenant's app-only registration.
    $tenantName = $script:Auth.Tenant
    if (-not $tenantName -and $script:Auth.AdminUrl -match 'https://([a-z0-9-]+)-admin') {
        $tenantName = $Matches[1]
    }
    if ($tenantName) {
        try {
            $clientId = $script:Auth.ClientId
            Invoke-OnMainBuffer {
                Connect-SsmOperatorGraph -Tenant $tenantName
                Invoke-PnPGraphMethod -Method Delete -Url ("applications(appId='{0}')" -f $clientId) -ErrorAction Stop
            }
            $appDeleted = $true
        } catch {
            Write-SsmErrorLog -Context 'App registration deletion failed' -ErrorRecord $_
            if ($_.Exception.Message -match 'AADSTS700016') {
                $errors += ("Entra app: PnP Management Shell not consented in this tenant. Open as Global Admin, consent, retry: https://login.microsoftonline.com/{0}/adminconsent?client_id={1}" -f $tenantName, $script:PnPManagementShellClientId)
            } elseif ($_.Exception.Message -match 'Forbidden|Insufficient privileges') {
                $errors += 'Entra app: Forbidden - the signed-in account needs Application Administrator (or higher) in this tenant. Or delete the app in the Entra portal.'
            } else {
                $errors += ("Entra app: {0}" -f $_.Exception.Message)
            }
        }
    } else {
        $errors += 'Entra app: no tenant/admin URL on file - skipped, delete it manually in the Entra portal.'
    }

    # Step 2: delete the local cert (same logic as Remove-SsmTenantData -IncludeCert).
    try {
        if ($script:Auth.Thumbprint -and $script:IsWin) {
            $certPath = "Cert:\CurrentUser\My\{0}" -f $script:Auth.Thumbprint
            if (Test-Path $certPath) { Remove-Item $certPath -Force; $certDeleted = $true }
        } elseif ($script:Auth.CertPath -and (Test-Path -LiteralPath $script:Auth.CertPath)) {
            Remove-Item -LiteralPath $script:Auth.CertPath -Force
            $certDeleted = $true
        }
    } catch {
        Write-SsmErrorLog -Context 'Cert deletion failed' -ErrorRecord $_
        $errors += ("cert: {0}" -f $_.Exception.Message)
    }

    # Step 3: clear config, keep Tenant/AdminUrl.
    $script:Auth.AuthMode = ''
    $script:Auth.ClientId = ''
    $script:Auth.Thumbprint = ''
    $script:Auth.CertPath = ''
    $script:Auth.CertExpires = ''
    Save-SsmAuth

    $msg = @()
    $msg += if ($appDeleted) { 'Entra app deleted.' } else { 'Entra app not deleted (see warnings).' }
    $msg += if ($certDeleted) { 'Certificate deleted.' } else { 'No local certificate found.' }
    $msg += 'Config cleared.'
    if ($errors.Count) { $msg += ''; $msg += 'Warnings:'; $msg += $errors }
    Write-SsmLog -Message ("Removed app registration (app={0} cert={1})." -f $appDeleted, $certDeleted) -Level OK
    Show-MsgModal -Title 'App registration removed' -Lines $msg
}

function Invoke-RemoveTenantFlow {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -eq $script:TenantName) {
        Show-MsgModal -Title 'Remove tenant' -Lines @('Cannot remove the active tenant.', 'Switch to another tenant first.') -Kind Warn
        return
    }
    $c = Get-SsmConfig
    $e = $c.Tenants[$Name]
    $slug = ConvertTo-SsmTenantSlug -Name $Name
    $lines = @(
        ("Remove tenant '{0}'?" -f $Name), '',
        ("Auth mode   {0}" -f $e.AuthMode)
    )
    if ($e.Thumbprint)  { $lines += ("Cert        CurrentUser\My\{0}" -f $e.Thumbprint) }
    if ($e.CertPath)    { $lines += ("PFX file    {0}" -f $e.CertPath) }
    $lines += ("Cache       SSM-Cache/{0}/" -f $slug)
    $lines += ("Exports     SSM-Exports/{0}/" -f $slug)
    $lines += ''
    $lines += 'Type DELETE to also delete the certificate and scan cache.'
    $lines += 'Anything else cancels. Export CSVs are kept either way;'
    $lines += 'delete SSM-Exports manually if they should go too.'
    $ok = Show-TypedConfirmModal -Title 'Remove tenant' -Word 'DELETE' -Lines $lines
    if (-not $ok) { return }

    # ponytail: two-checkbox UI is overkill for the existing modal toolkit;
    # typed DELETE covers cert+cache, exports stay behind a second typed prompt.
    $expOk = Show-TypedConfirmModal -Title 'Delete exports' -Word 'EXPORTS' -Lines @(
        ("Also delete export CSVs for '{0}'?" -f $Name), '',
        'These are evidence of past scans and revokes. This cannot be undone.')
    $r = Remove-SsmTenantData -Name $Name -IncludeCert -IncludeCache -IncludeExports:$expOk
    $msg = @(("Removed '{0}'." -f $Name))
    if ($r.CertDeleted)     { $msg += 'Certificate deleted.' }
    if ($r.CacheDeleted)    { $msg += 'Cache deleted.' }
    if ($r.ExportsDeleted)  { $msg += 'Exports deleted.' }
    if ($r.Errors.Count)    { $msg += ('Warnings: {0}' -f ($r.Errors -join '; ')) }
    Show-MsgModal -Title 'Removed' -Lines $msg
}

function Invoke-AddTenantFlow {
    $name = Show-InputModal -Title 'Add tenant' -Prompt 'Tenant display name (e.g. contoso):'
    if (-not $name) { return }
    if (Add-SsmTenant -Name $name.Trim()) {
        Show-MsgModal -Title 'Added' -Lines @(("Tenant '{0}' added." -f $name.Trim()), 'Press Enter on it to configure auth.')
    } else {
        Show-MsgModal -Title 'Add failed' -Lines @('Name already exists or would share a cache directory with another tenant.') -Kind Warn
    }
}

function Show-TenantActionsModal {
    param([Parameter(Mandatory)][string]$Name)
    $options = @()
    if ($Name -ne $script:TenantName) { $options += 'Switch to this tenant' }
    $linkDatesOn = ($script:Auth.Contains('IncludeLinkDates') -and $script:Auth.IncludeLinkDates -eq 'True')
    $linkToggle = if ($linkDatesOn) { 'Disable link-date lookup' } else { 'Enable link-date lookup' }
    $options += @('Edit config', $linkToggle, 'Register delegated app', 'Register cert app',
                  'Renew certificate', 'Remove app registration', 'Set as default', 'Remove tenant', 'Cancel')
    $pick = Show-ListModal -Title $Name -Prompt 'Action:' -Options $options
    if (-not $pick -or $pick -eq 'Cancel') { return }

    $needsAuth = @('Edit config', 'Register delegated app', 'Register cert app', 'Renew certificate', 'Remove app registration')
    if ($pick -like '*link-date lookup*') {
        if ($Name -ne $script:TenantName) {
            if ($script:Conn.Url) { Disconnect-SsmConnection }
            if (-not (Switch-SsmTenant -Name $Name)) { return }
        }
        $script:Auth.IncludeLinkDates = if ($linkDatesOn) { '' } else { 'True' }
        Save-SsmAuth
        $state = if ($script:Auth.IncludeLinkDates) { 'ON' } else { 'OFF' }
        Show-MsgModal -Title 'Link-date lookup' -Lines @(
            ("Link-date lookup is now {0} for '{1}'." -f $state, $Name), '',
            'ON = each scan also fetches sharing-link Created date via',
            'CSOM (one extra call per uniquely-shared item = slower).',
            'The dates appear in the findings view and CSV exports.')
        $script:UI.Dirty = $true
        return
    }
    if ($needsAuth -contains $pick -and $Name -ne $script:TenantName) {
        if ($script:Conn.Url) { Disconnect-SsmConnection }
        if (-not (Switch-SsmTenant -Name $Name)) { return }
    }
    switch ($pick) {
        'Switch to this tenant'   { if ($script:Conn.Url) { Disconnect-SsmConnection }; [void](Switch-SsmTenant -Name $Name) }
        'Edit config'             { Edit-SsmConfig }
        'Register delegated app'  { Register-SsmDelegatedApp }
        'Register cert app'       { Register-SsmAppOnlyApp }
        'Renew certificate'       { Update-SsmCertificate }
        'Remove app registration' { Remove-SsmAppRegistration }
        'Set as default'          { if (Set-SsmDefaultTenant -Name $Name) { Show-MsgModal -Title 'Default' -Lines @(("'{0}' is now the startup tenant." -f $Name)) } }
        'Remove tenant'           { Invoke-RemoveTenantFlow -Name $Name }
    }
    $script:UI.Dirty = $true
}

#endregion
