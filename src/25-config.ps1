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

function Test-SsmTenantConfigured {
    # Pure: is a Tenants-map entry complete enough to connect with?
    param([hashtable]$Entry)
    if (-not $Entry.ClientId) { return $false }
    if ($Entry.AuthMode -eq 'AppOnly') {
        if (-not $Entry.Tenant) { return $false }
        if (-not ($Entry.Thumbprint -or $Entry.CertPath)) { return $false }
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

function Invoke-SsmLegacyMigration {
    # Move legacy un-suffixed cache/export content into the active tenant's
    # slug subdir. Idempotent: only moves when legacy location has content
    # and the destination does not already hold the file.
    param([Parameter(Mandatory)][string]$TenantName)
    $slug = ConvertTo-SsmTenantSlug -Name $TenantName
    foreach ($pair in @(
        @{ Root = 'SSM-Cache';   File = 'session.json' },
        @{ Root = 'SSM-Exports'; File = $null }
    )) {
        $legacy = Join-Path $script:Root $pair.Root
        $dest   = Join-Path $script:Root ("{0}/{1}" -f $pair.Root, $slug)
        if (-not (Test-Path -LiteralPath $legacy)) { continue }
        if ($pair.File) {
            $src = Join-Path $legacy $pair.File
            $dst = Join-Path $dest $pair.File
            if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Move-Item -LiteralPath $src -Destination $dst
                Write-SsmLog -Message ("Migrated {0}/{1} to tenant '{2}'." -f $pair.Root, $pair.File, $TenantName) -Level OK
            }
        } else {
            $items = @(Get-ChildItem -LiteralPath $legacy -File -ErrorAction SilentlyContinue)
            if ($items.Count -gt 0) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                foreach ($it in $items) {
                    $dst = Join-Path $dest $it.Name
                    if (-not (Test-Path -LiteralPath $dst)) { Move-Item -LiteralPath $it.FullName -Destination $dst }
                }
                Write-SsmLog -Message ("Migrated {0} export(s) to tenant '{1}'." -f $items.Count, $TenantName) -Level OK
            }
        }
    }
}

function Get-SsmTenantNames {
    $c = Get-SsmConfig
    if ($null -eq $c) { return @() }
    return @($c.Tenants.Keys | Sort-Object)
}

function Add-SsmTenant {
    # Add an empty tenant entry. Reject exact name dup and slug collision
    # (two names that would share a cache dir).
    param([Parameter(Mandatory)][string]$Name)
    $c = Get-SsmConfig
    if ($null -eq $c) { $c = @{ Version=2; DefaultTenant=''; Tenants=@{} } }
    if ($c.Tenants.ContainsKey($Name)) { return $false }
    $slug = ConvertTo-SsmTenantSlug -Name $Name
    foreach ($k in $c.Tenants.Keys) {
        if ((ConvertTo-SsmTenantSlug -Name $k) -eq $slug) { return $false }
    }
    $entry = @{}
    foreach ($k in $script:AuthKeys) { $entry[$k] = '' }
    $c.Tenants[$Name] = $entry
    Save-SsmConfig -Config $c
    return $true
}

function Remove-SsmTenant {
    param([Parameter(Mandatory)][string]$Name)
    $c = Get-SsmConfig
    if ($null -eq $c -or -not $c.Tenants.ContainsKey($Name)) { return $false }
    $c.Tenants.Remove($Name)
    if ($c.DefaultTenant -eq $Name) { $c.DefaultTenant = '' }
    Save-SsmConfig -Config $c
    return $true
}

function Set-SsmDefaultTenant {
    param([Parameter(Mandatory)][string]$Name)
    $c = Get-SsmConfig
    if ($null -eq $c -or -not $c.Tenants.ContainsKey($Name)) { return $false }
    $c.DefaultTenant = $Name
    Save-SsmConfig -Config $c
    return $true
}

function Initialize-SsmTenancy {
    # Startup entry point: load config, point paths at the active tenant,
    # and migrate any legacy un-suffixed cache/export content once.
    Initialize-SsmAuth
    Set-SsmTenantPaths -Name $script:TenantName
    if ($script:TenantName) { Invoke-SsmLegacyMigration -TenantName $script:TenantName }
}

function Switch-SsmTenant {
    # Swap active tenant. Loads the tenant's auth into $script:Auth, resets
    # every Targets tab to empty/unloaded, clears connection state, repaths
    # cache/exports. Caller is responsible for Disconnect-PnPOnline first.
    param([Parameter(Mandatory)][string]$Name)
    $c = Get-SsmConfig
    if ($null -eq $c -or -not $c.Tenants.ContainsKey($Name)) { return $false }
    $entry = $c.Tenants[$Name]
    foreach ($k in $script:AuthKeys) {
        $script:Auth[$k] = if ($entry.ContainsKey($k)) { [string]$entry[$k] } else { '' }
    }
    $script:Auth.Loaded = $true
    $script:TenantName = $Name
    foreach ($tab in @($script:Tabs)) {
        if ($tab['Kind'] -eq 'Tenant') {
            # Sharing tab holds the OLD tenant's posture - force a reload.
            $tab['Loaded'] = $false; $tab['Posture'] = $null; $tab['Cursor'] = 0
            continue
        }
        if ($tab['Kind'] -ne 'Targets') { continue }
        $tab['Items']  = @()
        $tab['View']   = @()
        $tab['Loaded'] = $false
        $tab['Mode']   = 'Targets'
        $tab['Search'] = ''
        $tab['Cursor'] = 0
        $tab['Scroll'] = 0
        $tab['FTab']   = $null
    }
    $script:Conn.Url = ''; $script:Conn.Admin = $false; $script:Conn.Account = ''
    Set-SsmTenantPaths -Name $Name
    # Persist as startup tenant so next launch boots into the last-used one.
    [void](Set-SsmDefaultTenant -Name $Name)
    # Restore this tenant's on-disk scan cache (if any) so scans don't start over.
    [void](Restore-SsmCache)
    Write-SsmLog -Message ("Switched active tenant to '{0}'." -f $Name) -Level OK
    return $true
}

function Remove-SsmTenantData {
    # Delete the tenant's local artefacts per flags, then remove the config
    # entry. Each step is isolated; failures are collected in .Errors and do
    # not abort the rest. Windows cert-store deletion only runs on Windows.
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$IncludeCert,
        [switch]$IncludeCache,
        [switch]$IncludeExports
    )
    $result = @{ Removed=$false; CertDeleted=$false; CacheDeleted=$false; ExportsDeleted=$false; Errors=@() }
    $c = Get-SsmConfig
    if ($null -eq $c -or -not $c.Tenants.ContainsKey($Name)) { return $result }
    $entry = $c.Tenants[$Name]
    $slug  = ConvertTo-SsmTenantSlug -Name $Name

    if ($IncludeCert) {
        try {
            if ($entry.Thumbprint -and $script:IsWin) {
                $certPath = "Cert:\CurrentUser\My\{0}" -f $entry.Thumbprint
                if (Test-Path $certPath) { Remove-Item $certPath -Force; $result.CertDeleted = $true }
            } elseif ($entry.CertPath -and (Test-Path -LiteralPath $entry.CertPath)) {
                Remove-Item -LiteralPath $entry.CertPath -Force
                $result.CertDeleted = $true
            }
        } catch { $result.Errors += ("cert: {0}" -f $_.Exception.Message) }
    }
    if ($IncludeCache) {
        try {
            $dir = Join-Path $script:Root ("SSM-Cache/{0}" -f $slug)
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; $result.CacheDeleted = $true }
        } catch { $result.Errors += ("cache: {0}" -f $_.Exception.Message) }
    }
    if ($IncludeExports) {
        try {
            $dir = Join-Path $script:Root ("SSM-Exports/{0}" -f $slug)
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; $result.ExportsDeleted = $true }
        } catch { $result.Errors += ("exports: {0}" -f $_.Exception.Message) }
    }
    $result.Removed = [bool](Remove-SsmTenant -Name $Name)
    Write-SsmLog -Message ("Removed tenant '{0}' (cert={1} cache={2} exports={3})." -f $Name, $result.CertDeleted, $result.CacheDeleted, $result.ExportsDeleted) -Level OK
    return $result
}
