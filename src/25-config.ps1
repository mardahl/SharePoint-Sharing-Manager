# ============================================================================
#region Config & modules
# ============================================================================

$script:AuthKeys = @('AuthMode','ClientId','Tenant','AdminUrl','Thumbprint','CertPath','CertExpires')

function ConvertTo-SsmConfigV2 {
    # Pure: accept any parsed config hashtable, return v2 shape.
    param([hashtable]$Config)
    if ($Config.ContainsKey('Tenants')) {
        if (-not $Config.ContainsKey('Version'))      { $Config.Version = 2 }
        if (-not $Config.ContainsKey('DefaultTenant')){ $Config.DefaultTenant = '' }
        return $Config
    }
    # v1 flat shape -> v2. Name from Tenant host, fallback AdminUrl, then 'default'.
    $name = ''
    if ($Config.Tenant)    { $name = ($Config.Tenant -replace '\.onmicrosoft\.com$', '') }
    if (-not $name -and $Config.AdminUrl) {
        if ($Config.AdminUrl -match 'https://([a-z0-9-]+)-admin') { $name = $Matches[1] }
    }
    if (-not $name) { $name = 'default' }
    $entry = @{}
    foreach ($k in $script:AuthKeys) { if ($Config.ContainsKey($k)) { $entry[$k] = [string]$Config[$k] } }
    return @{ Version = 2; DefaultTenant = $name; Tenants = @{ $name = $entry } }
}

function Get-SsmConfig {
    param([string]$Path = $script:ConfigPath)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $c = (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)
        return (ConvertTo-SsmConfigV2 -Config $c)
    } catch { return $null }
}

function Save-SsmConfig {
    param([hashtable]$Config, [string]$Path = $script:ConfigPath)
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Initialize-SsmAuth {
    # Load saved config (if any) into $script:Auth. Missing file is fine: the
    # Setup tab is the guided path to create one.
    $c = Get-SsmConfig
    if ($null -ne $c -and $c.DefaultTenant -and $c.Tenants.ContainsKey($c.DefaultTenant)) {
        $script:TenantName = [string]$c.DefaultTenant
        $entry = $c.Tenants[$script:TenantName]
        foreach ($k in $script:AuthKeys) {
            if ($entry.ContainsKey($k) -and $entry[$k]) { $script:Auth[$k] = [string]$entry[$k] }
        }
        Write-SsmLog -Message ("Config loaded from {0} (tenant: {1}, mode: {2})" -f $script:ConfigPath, $script:TenantName, $script:Auth.AuthMode)
    }
    $script:Auth.Loaded = $true
}

function Save-SsmAuth {
    # Persist current $script:Auth back into Tenants[$script:TenantName], preserving other tenants.
    $c = Get-SsmConfig
    if ($null -eq $c) { $c = @{ Version = 2; DefaultTenant = ''; Tenants = @{} } }
    if (-not $script:TenantName) {
        # First save: derive a name from the tenant being saved.
        $script:TenantName = if ($script:Auth.Tenant) { $script:Auth.Tenant -replace '\.onmicrosoft\.com$', '' } else { 'default' }
    }
    $entry = @{}
    foreach ($k in $script:AuthKeys) { $entry[$k] = [string]$script:Auth[$k] }
    $c.Tenants[$script:TenantName] = $entry
    if (-not $c.DefaultTenant) { $c.DefaultTenant = $script:TenantName }
    $c.Version = 2
    Save-SsmConfig -Config $c
    Write-SsmLog -Message ("Config saved to {0} (tenant: {1})" -f $script:ConfigPath, $script:TenantName)
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

function ConvertTo-SsmTenantSlug {
    # Filesystem-safe slug from a tenant display name. Lowercase, only
    # [a-z0-9-], runs of invalid chars collapse to one dash, capped at 40.
    param([Parameter(Mandatory)][string]$Name)
    $s = $Name.ToLowerInvariant()
    $s = $s -replace '[^a-z0-9-]+', '-'
    $s = $s -replace '-{2,}', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).TrimEnd('-') }
    if (-not $s) { $s = 'tenant' }
    return $s
}

function Set-SsmTenantPaths {
    # Point cache + export dirs at the active tenant's slug subdir. Empty
    # name = legacy un-suffixed dirs (pre-tenant startup state).
    param([AllowEmptyString()][string]$Name)
    if ($Name) {
        $slug = ConvertTo-SsmTenantSlug -Name $Name
        $script:CacheDir  = Join-Path $script:Root ("SSM-Cache/{0}" -f $slug)
        $script:ExportDir = Join-Path $script:Root ("SSM-Exports/{0}" -f $slug)
    } else {
        $script:CacheDir  = Join-Path $script:Root 'SSM-Cache'
        $script:ExportDir = Join-Path $script:Root 'SSM-Exports'
    }
    $script:CacheFile = Join-Path $script:CacheDir 'session.json'
}

#endregion
