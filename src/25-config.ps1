# ============================================================================
#region Config & modules
# ============================================================================

function Get-SsmConfig {
    param([string]$Path = $script:ConfigPath)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable) }
    catch { return $null }
}

function Save-SsmConfig {
    param([hashtable]$Config, [string]$Path = $script:ConfigPath)
    $Config | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Initialize-SsmAuth {
    # Load saved config (if any) into $script:Auth. Missing file is fine: the
    # Setup tab is the guided path to create one.
    $c = Get-SsmConfig
    if ($null -ne $c) {
        foreach ($k in @('AuthMode','ClientId','Tenant','AdminUrl','Thumbprint','CertPath','CertExpires')) {
            if ($c.ContainsKey($k) -and $c[$k]) { $script:Auth[$k] = [string]$c[$k] }
        }
        Write-SsmLog -Message ("Config loaded from {0} (mode: {1})" -f $script:ConfigPath, $script:Auth.AuthMode)
    }
    $script:Auth.Loaded = $true
}

function Save-SsmAuth {
    # Persist current $script:Auth back to the config file.
    Save-SsmConfig -Config @{
        AuthMode    = $script:Auth.AuthMode
        ClientId    = $script:Auth.ClientId
        Tenant      = $script:Auth.Tenant
        AdminUrl    = $script:Auth.AdminUrl
        Thumbprint  = $script:Auth.Thumbprint
        CertPath    = $script:Auth.CertPath
        CertExpires = $script:Auth.CertExpires
    }
    Write-SsmLog -Message ("Config saved to {0}" -f $script:ConfigPath)
}

function Test-SsmAuthReady {
    if (-not $script:Auth.ClientId) { return $false }
    if ($script:Auth.AuthMode -eq 'AppOnly') {
        if (-not $script:Auth.Tenant) { return $false }
        if (-not ($script:Auth.Thumbprint -or $script:Auth.CertPath)) { return $false }
    }
    return $true
}

function Get-CertDaysLeft {
    if (-not $script:Auth.CertExpires) { return $null }
    try { return [int]([datetime]::Parse($script:Auth.CertExpires) - (Get-Date)).TotalDays }
    catch { return $null }
}

function Install-SsmModule {
    # Install + import PnP.PowerShell (CurrentUser) on demand. Runs on the main
    # buffer so gallery prompts/progress are visible.
    if (Get-Module -Name 'PnP.PowerShell') { return $true }
    if (-not (Get-Module -ListAvailable -Name 'PnP.PowerShell')) {
        $ok = Show-ConfirmModal -Title 'Module required' -Lines @(
            'PnP.PowerShell is not installed.',
            'Install it now for the current user?')
        if (-not $ok) { return $false }
        Invoke-OnMainBuffer {
            Write-Host 'Installing PnP.PowerShell (CurrentUser)...' -ForegroundColor Yellow
            Install-Module -Name 'PnP.PowerShell' -Scope CurrentUser -Force -AllowClobber
        }
        Write-SsmLog -Message 'PnP.PowerShell installed (CurrentUser).' -Level OK
    }
    Import-Module 'PnP.PowerShell' -ErrorAction Stop
    return $true
}

#endregion
