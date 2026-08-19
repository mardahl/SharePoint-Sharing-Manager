# Multi-tenant support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the tool hold multiple configured tenants, switch the active tenant in-app, and isolate config/cache/exports/certificates per tenant.

**Architecture:** Single config file upgraded to schema v2 (`Tenants` map + `DefaultTenant`). Active tenant's auth stays in the existing flat `$script:Auth`. Tenant name drives a slug used for per-tenant cache and export subdirectories. In-app switcher swaps auth + paths and clears in-memory tab state. Setup tab gains a tenant list with add/edit/remove/set-default; remove optionally deletes the tenant's certificate, cache, and exports.

**Tech Stack:** PowerShell 7.4+, PnP.PowerShell, existing custom assert-based test runner (`tests/run-tests.ps1`).

## Global Constraints

- PowerShell 7.4+; `Set-StrictMode -Version 2.0` in tests.
- Source files live in `src/NN-name.ps1` and are dot-sourced in numeric order by the main script; pure-logic files are also dot-sourced by `tests/run-tests.ps1` — keep PnP calls out of functions the tests import, or guard with `Get-Command`.
- All file paths built via `Join-Path` against `$script:Root` / `$script:CacheDir` / `$script:ExportDir`.
- Existing test style: `Invoke-SsmTest 'name' { ... }` + `Assert-Equal expected actual`.
- Commit style: conventional commits (`feat:`, `fix:`, `docs:`), see `git log`.
- Do not break existing tests: `pwsh tests/run-tests.ps1` must stay green.

---

### Task 1: Tenant slug helper

**Files:**
- Modify: `src/25-config.ps1` (append at end, before `#endregion`)
- Test: `tests/config.tests.ps1`

**Interfaces:**
- Produces: `ConvertTo-SsmTenantSlug -Name <string>` → lowercase slug, `[a-z0-9-]` only, max 40 chars. Used by paths, migration, cache, exports.

- [ ] **Step 1: Write the failing test**

Append to `tests/config.tests.ps1`:

```powershell
Invoke-SsmTest 'ConvertTo-SsmTenantSlug lowercases and sanitises' {
    Assert-Equal 'contoso' (ConvertTo-SsmTenantSlug -Name 'Contoso')
    Assert-Equal 'contoso-ltd' (ConvertTo-SsmTenantSlug -Name 'Contoso Ltd')
    Assert-Equal 'a-b-c' (ConvertTo-SsmTenantSlug -Name 'a  b--c')
    Assert-Equal 'x' (ConvertTo-SsmTenantSlug -Name 'X')
}
Invoke-SsmTest 'ConvertTo-SsmTenantSlug caps at 40 chars' {
    $long = 'a' * 60
    Assert-Equal 40 ((ConvertTo-SsmTenantSlug -Name $long).Length)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/run-tests.ps1`
Expected: FAIL with "ConvertTo-SsmTenantSlug is not recognized"

- [ ] **Step 3: Write minimal implementation**

Append to `src/25-config.ps1` before `#endregion`:

```powershell
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh tests/run-tests.ps1`
Expected: PASS, all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add src/25-config.ps1 tests/config.tests.ps1
git commit -m "feat: add ConvertTo-SsmTenantSlug for per-tenant paths"
```

---

### Task 2: Config schema v2 — load, migrate, save

**Files:**
- Modify: `src/25-config.ps1` (replace `Get-SsmConfig`, `Save-SsmConfig`, `Initialize-SsmAuth`, `Save-SsmAuth`)
- Test: `tests/config.tests.ps1`

**Interfaces:**
- Produces:
  - `Get-SsmConfig [-Path]` → hashtable with `Version`, `DefaultTenant`, `Tenants` (always v2 shape; migrates v1 on read).
  - `Save-SsmConfig -Config <hashtable> [-Path]` → writes v2 shape verbatim.
  - `Initialize-SsmAuth` → loads `DefaultTenant` entry into `$script:Auth`, sets `$script:TenantName`.
  - `Save-SsmAuth` → writes `$script:Auth` back into `Tenants[$script:TenantName]`, preserves other tenants.
  - `$script:TenantName` (new global; set by Task 3 globals change — this task references it but tests set it directly).

- [ ] **Step 1: Write the failing tests**

Append to `tests/config.tests.ps1`:

```powershell
Invoke-SsmTest 'Get-SsmConfig migrates flat v1 config to v2' {
    $v1 = Join-Path ([IO.Path]::GetTempPath()) ("ssm-v1-{0}.json" -f [guid]::NewGuid())
    Save-SsmConfig -Path $v1 -Config @{
        AuthMode='AppOnly'; ClientId='1111'; Tenant='contoso.onmicrosoft.com'
        AdminUrl='https://contoso-admin.sharepoint.com'
        Thumbprint='ABCD'; CertPath=''; CertExpires='2027-01-01'
    }
    $c = Get-SsmConfig -Path $v1
    Assert-Equal 2 $c.Version
    Assert-Equal 'contoso' $c.DefaultTenant
    Assert-Equal 'ABCD' $c.Tenants['contoso'].Thumbprint
    Remove-Item -LiteralPath $v1 -ErrorAction SilentlyContinue
}
Invoke-SsmTest 'Save-SsmAuth writes into Tenants[TenantName], preserves others' {
    $v2 = Join-Path ([IO.Path]::GetTempPath()) ("ssm-v2-{0}.json" -f [guid]::NewGuid())
    $script:ConfigPath = $v2
    $script:TenantName = 'contoso'
    $script:Auth = @{ AuthMode='AppOnly'; ClientId='1111'; Tenant='contoso.onmicrosoft.com'; AdminUrl=''; Thumbprint='ABCD'; CertPath=''; CertExpires='' }
    Save-SsmConfig -Path $v2 -Config @{
        Version=2; DefaultTenant='contoso'
        Tenants=@{ contoso=@{ ClientId='1111' }; fabrikam=@{ ClientId='2222' } }
    }
    Save-SsmAuth
    $c = Get-SsmConfig -Path $v2
    Assert-Equal 'ABCD' $c.Tenants['contoso'].Thumbprint
    Assert-Equal '2222' $c.Tenants['fabrikam'].ClientId
    Remove-Item -LiteralPath $v2 -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh tests/run-tests.ps1`
Expected: FAIL — migration assertions fail (v1 shape returned as-is).

- [ ] **Step 3: Write minimal implementation**

Replace `Get-SsmConfig`/`Save-SsmConfig`/`Initialize-SsmAuth`/`Save-SsmAuth` in `src/25-config.ps1`:

```powershell
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh tests/run-tests.ps1`
Expected: PASS all, including the original round-trip test (now migrating v1 in memory).

- [ ] **Step 5: Commit**

```bash
git add src/25-config.ps1 tests/config.tests.ps1
git commit -m "feat: config schema v2 with Tenants map and v1 migration"
```

---

### Task 3: Tenant-scoped paths + globals

**Files:**
- Modify: `src/00-globals.ps1`
- Modify: `src/25-config.ps1` (add `Set-SsmTenantPaths`)
- Test: `tests/config.tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-SsmTenantSlug` (Task 1).
- Produces:
  - `$script:TenantName` (string, active tenant key; `''` when unset).
  - `Set-SsmTenantPaths -Name <string>` → sets `$script:CacheDir`, `$script:CacheFile`, `$script:ExportDir` from slug. Name may be empty → falls back to legacy un-suffixed dirs (back-compat before a tenant is chosen).

- [ ] **Step 1: Write the failing test**

Append to `tests/config.tests.ps1`:

```powershell
Invoke-SsmTest 'Set-SsmTenantPaths derives per-tenant dirs from slug' {
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("ssm-root-{0}" -f [guid]::NewGuid())
    Set-SsmTenantPaths -Name 'Contoso Ltd'
    Assert-Equal (Join-Path $script:Root 'SSM-Cache/contoso-ltd') $script:CacheDir
    Assert-Equal (Join-Path $script:Root 'SSM-Cache/contoso-ltd/session.json') $script:CacheFile
    Assert-Equal (Join-Path $script:Root 'SSM-Exports/contoso-ltd') $script:ExportDir
}
Invoke-SsmTest 'Set-SsmTenantPaths with empty name keeps legacy dirs' {
    Set-SsmTenantPaths -Name ''
    Assert-Equal (Join-Path $script:Root 'SSM-Cache') $script:CacheDir
    Assert-Equal (Join-Path $script:Root 'SSM-Exports') $script:ExportDir
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/run-tests.ps1`
Expected: FAIL — `Set-SsmTenantPaths` not recognized.

- [ ] **Step 3: Write minimal implementation**

In `src/00-globals.ps1`:

- Add after `$script:Auth = @{...}` block:

```powershell
$script:TenantName = ''   # key into config Tenants map; '' = not chosen yet
```

- Replace the static cache/export path lines (currently lines 14, 17-18):

```powershell
$script:ExportDir = $null   # set by Set-SsmTenantPaths
$script:CacheDir  = $null   # set by Set-SsmTenantPaths
$script:CacheFile = $null
```

Append to `src/25-config.ps1`:

```powershell
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh tests/run-tests.ps1`
Expected: PASS all.

- [ ] **Step 5: Commit**

```bash
git add src/00-globals.ps1 src/25-config.ps1 tests/config.tests.ps1
git commit -m "feat: per-tenant cache/export paths via Set-SsmTenantPaths"
```

---

### Task 4: Migrate legacy cache/exports on first load

**Files:**
- Modify: `src/25-config.ps1` (add `Invoke-SsmLegacyMigration`, call from a new `Initialize-SsmTenancy` that wraps `Initialize-SsmAuth` + path setup + file moves)
- Modify: `SharePoint-Sharing-Manager.ps1` (call `Initialize-SsmTenancy` instead of `Initialize-SsmAuth`)
- Test: `tests/config.tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-SsmConfigV2`, `Set-SsmTenantPaths`, `$script:TenantName`.
- Produces: `Initialize-SsmTenancy` — one entry point the main script calls; performs: config load, `Set-SsmTenantPaths`, legacy cache/export moves.

- [ ] **Step 1: Write the failing test**

Append to `tests/config.tests.ps1`:

```powershell
Invoke-SsmTest 'Invoke-SsmLegacyMigration moves cache and exports into slug dirs' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ssm-mig-{0}" -f [guid]::NewGuid())
    $script:Root = $root
    New-Item -ItemType Directory -Path (Join-Path $root 'SSM-Cache') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'SSM-Exports') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'SSM-Cache/session.json') -Value '{"Tabs":[]}'
    Set-Content -LiteralPath (Join-Path $root 'SSM-Exports/a.csv') -Value 'x'
    $script:TenantName = 'Contoso'
    Set-SsmTenantPaths -Name $script:TenantName
    Invoke-SsmLegacyMigration -TenantName $script:TenantName
    Assert-Equal $true (Test-Path -LiteralPath (Join-Path $root 'SSM-Cache/contoso/session.json'))
    Assert-Equal $true (Test-Path -LiteralPath (Join-Path $root 'SSM-Exports/contoso/a.csv'))
    Remove-Item -LiteralPath $root -Recurse -Force
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/run-tests.ps1`
Expected: FAIL — `Invoke-SsmLegacyMigration` not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `src/25-config.ps1`:

```powershell
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

function Initialize-SsmTenancy {
    # Startup entry point: load config, point paths at the active tenant,
    # and migrate any legacy un-suffixed cache/export content once.
    Initialize-SsmAuth
    Set-SsmTenantPaths -Name $script:TenantName
    if ($script:TenantName) { Invoke-SsmLegacyMigration -TenantName $script:TenantName }
}
```

In `SharePoint-Sharing-Manager.ps1`, replace the call to `Initialize-SsmAuth` with `Initialize-SsmTenancy`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh tests/run-tests.ps1`
Expected: PASS all.

- [ ] **Step 5: Commit**

```bash
git add src/25-config.ps1 SharePoint-Sharing-Manager.ps1 tests/config.tests.ps1
git commit -m "feat: migrate legacy cache/exports into tenant slug dirs at startup"
```

---

### Task 5: Tenant CRUD helpers

**Files:**
- Modify: `src/25-config.ps1`
- Test: `tests/config.tests.ps1`

**Interfaces:**
- Consumes: v2 config, `$script:AuthKeys`.
- Produces:
  - `Get-SsmTenantNames` → `string[]` of tenant keys.
  - `Add-SsmTenant -Name <string>` → creates empty entry, returns `$false` on name or slug collision.
  - `Remove-SsmTenant -Name <string>` → removes entry, clears `DefaultTenant` if it pointed here. Returns `$true` when removed.
  - `Set-SsmDefaultTenant -Name <string>`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/config.tests.ps1`:

```powershell
Invoke-SsmTest 'Add/Remove/Default tenant helpers' {
    $p = Join-Path ([IO.Path]::GetTempPath()) ("ssm-crud-{0}.json" -f [guid]::NewGuid())
    $script:ConfigPath = $p
    Save-SsmConfig -Path $p -Config @{ Version=2; DefaultTenant=''; Tenants=@{} }
    Assert-Equal $true (Add-SsmTenant -Name 'contoso')
    Assert-Equal $true (Add-SsmTenant -Name 'fabrikam')
    Assert-Equal $false (Add-SsmTenant -Name 'contoso')          # exact dup
    Assert-Equal $false (Add-SsmTenant -Name 'Contoso Ltd')      # different slug ok
    Assert-Equal $false (Add-SsmTenant -Name 'Contoso-Ltd')      # slug collision
    Set-SsmDefaultTenant -Name 'fabrikam'
    $c = Get-SsmConfig -Path $p
    Assert-Equal 'fabrikam' $c.DefaultTenant
    Assert-Equal $true (Remove-SsmTenant -Name 'fabrikam')
    $c = Get-SsmConfig -Path $p
    Assert-Equal '' $c.DefaultTenant
    Assert-Equal $false ($c.Tenants.ContainsKey('fabrikam'))
    Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh tests/run-tests.ps1`
Expected: FAIL — functions not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `src/25-config.ps1`:

```powershell
function Get-SsmTenantNames {
    $c = Get-SsmConfig
    if ($null -eq $c) { return @() }
    return @($c.Tenants.Keys)
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh tests/run-tests.ps1`
Expected: PASS all.

- [ ] **Step 5: Commit**

```bash
git add src/25-config.ps1 tests/config.tests.ps1
git commit -m "feat: tenant CRUD helpers (add/remove/set-default)"
```

---

### Task 6: Switch-SsmTenant (in-memory state swap)

**Files:**
- Modify: `src/25-config.ps1`
- Test: `tests/config.tests.ps1`

**Interfaces:**
- Consumes: `Get-SsmConfig`, `Set-SsmTenantPaths`, `$script:Tabs` shape from `00-globals.ps1`.
- Produces:
  - `Switch-SsmTenant -Name <string>` → loads tenant's auth into `$script:Auth`, sets `$script:TenantName`, resets every Targets tab (Items/View/Loaded/Mode/Search), repaths, clears `$script:Conn`. Does NOT call `Disconnect-PnPOnline` (UI layer's job — keeps this pure for tests). Returns `$true` on success, `$false` if tenant unknown.

- [ ] **Step 1: Write the failing test**

Append to `tests/config.tests.ps1`:

```powershell
Invoke-SsmTest 'Switch-SsmTenant swaps auth, repaths, clears Targets tabs' {
    $p = Join-Path ([IO.Path]::GetTempPath()) ("ssm-sw-{0}.json" -f [guid]::NewGuid())
    $script:ConfigPath = $p
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("ssm-root-{0}" -f [guid]::NewGuid())
    Save-SsmConfig -Path $p -Config @{
        Version=2; DefaultTenant='contoso'
        Tenants=@{
            contoso=@{ AuthMode='AppOnly'; ClientId='aaaa'; Tenant='contoso.onmicrosoft.com'; AdminUrl=''; Thumbprint='THUMB1'; CertPath=''; CertExpires='' }
            fabrikam=@{ AuthMode='Delegated'; ClientId='bbbb'; Tenant='fabrikam.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
        }
    }
    $script:TenantName = 'contoso'
    $script:Auth = @{ AuthMode='AppOnly'; ClientId='aaaa'; Tenant='contoso.onmicrosoft.com'; AdminUrl=''; Thumbprint='THUMB1'; CertPath=''; CertExpires=''; Loaded=$true }
    $script:Conn = @{ Url='https://contoso.sharepoint.com'; Admin=$false; Account='app:aaaa' }
    $script:Tabs = @(
        @{ Kind='Targets'; Name='Sites'; Items=@(@{Url='x'}); View=@(@{Url='x'}); Loaded=$true; Mode='Findings'; Search='abc'; Categories=[System.Collections.ArrayList]@('OrgLink'); FTab=$null; Cursor=0; Scroll=0; Filter='All'; SortCol='Url'; SortDesc=$false },
        @{ Kind='Tenant'; Name='Tenant'; Loaded=$true; Posture=@{}; Cursor=0 }
    )
    Set-SsmTenantPaths -Name 'contoso'
    Assert-Equal $true (Switch-SsmTenant -Name 'fabrikam')
    Assert-Equal 'fabrikam' $script:TenantName
    Assert-Equal 'Delegated' $script:Auth.AuthMode
    Assert-Equal '' $script:Auth.Thumbprint
    Assert-Equal '' $script:Conn.Url
    Assert-Equal 0 @($script:Tabs[0]['Items']).Count
    Assert-Equal $false $script:Tabs[0]['Loaded']
    Assert-Equal 'Targets' $script:Tabs[0]['Mode']
    Assert-Equal '' $script:Tabs[0]['Search']
    Assert-Equal $true ($script:CacheDir -like '*fabrikam*')
    # Tenant (posture) tab untouched
    Assert-Equal $true $script:Tabs[1].Loaded
    Assert-Equal $false (Switch-SsmTenant -Name 'no-such')
    Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/run-tests.ps1`
Expected: FAIL — `Switch-SsmTenant` not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `src/25-config.ps1`:

```powershell
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
    Write-SsmLog -Message ("Switched active tenant to '{0}'." -f $Name) -Level OK
    return $true
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh tests/run-tests.ps1`
Expected: PASS all.

- [ ] **Step 5: Commit**

```bash
git add src/25-config.ps1 tests/config.tests.ps1
git commit -m "feat: Switch-SsmTenant swaps auth, clears tabs, repaths"
```

---

### Task 7: Remove-SsmTenantData — cert, cache, exports

**Files:**
- Modify: `src/25-config.ps1`
- Test: `tests/config.tests.ps1`

**Interfaces:**
- Consumes: `Get-SsmConfig`, `Remove-SsmTenant`, `ConvertTo-SsmTenantSlug`.
- Produces:
  - `Remove-SsmTenantData -Name <string> [-IncludeCert] [-IncludeCache] [-IncludeExports]` → deletes tenant's cert (Windows store by thumbprint on Windows; PFX at `CertPath` otherwise), cache subdir, export subdir per flags. Removes config entry always. Returns a hashtable `@{ Removed=$bool; CertDeleted=$bool; CacheDeleted=$bool; ExportsDeleted=$bool; Errors=@(...) }` so the UI can report accurately. Does NOT block on active tenant — caller checks that.

- [ ] **Step 1: Write the failing test**

Append to `tests/config.tests.ps1`:

```powershell
Invoke-SsmTest 'Remove-SsmTenantData deletes cache+exports per flags, removes config' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ssm-rm-{0}" -f [guid]::NewGuid())
    $script:Root = $root
    $p = Join-Path $root 'cfg.json'
    $script:ConfigPath = $p
    Save-SsmConfig -Path $p -Config @{
        Version=2; DefaultTenant=''
        Tenants=@{ fabrikam=@{ AuthMode='AppOnly'; ClientId='x'; Tenant='f.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' } }
    }
    $cache = Join-Path $root 'SSM-Cache/fabrikam'
    $expo  = Join-Path $root 'SSM-Exports/fabrikam'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    New-Item -ItemType Directory -Path $expo  -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cache 'session.json') -Value '{}'
    Set-Content -LiteralPath (Join-Path $expo 'a.csv') -Value 'x'
    $r = Remove-SsmTenantData -Name 'fabrikam' -IncludeCache
    Assert-Equal $true $r.Removed
    Assert-Equal $true $r.CacheDeleted
    Assert-Equal $false $r.ExportsDeleted
    Assert-Equal $false (Test-Path -LiteralPath $cache)
    Assert-Equal $true  (Test-Path -LiteralPath $expo)
    $c = Get-SsmConfig -Path $p
    Assert-Equal $false ($c.Tenants.ContainsKey('fabrikam'))
    Remove-Item -LiteralPath $root -Recurse -Force
}
Invoke-SsmTest 'Remove-SsmTenantData deletes PFX when CertPath set (non-Windows path)' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ssm-rm2-{0}" -f [guid]::NewGuid())
    $script:Root = $root
    $p = Join-Path $root 'cfg.json'
    $script:ConfigPath = $p
    $pfx = Join-Path $root 'cert.pfx'
    Set-Content -LiteralPath $pfx -Value 'fake'
    Save-SsmConfig -Path $p -Config @{
        Version=2; DefaultTenant=''
        Tenants=@{ t1=@{ AuthMode='AppOnly'; ClientId='x'; Tenant=''; AdminUrl=''; Thumbprint=''; CertPath=$pfx; CertExpires='' } }
    }
    $r = Remove-SsmTenantData -Name 't1' -IncludeCert
    Assert-Equal $true $r.Removed
    Assert-Equal $true $r.CertDeleted
    Assert-Equal $false (Test-Path -LiteralPath $pfx)
    Remove-Item -LiteralPath $root -Recurse -Force
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh tests/run-tests.ps1`
Expected: FAIL — function not recognized.

- [ ] **Step 3: Write minimal implementation**

Append to `src/25-config.ps1`:

```powershell
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh tests/run-tests.ps1`
Expected: PASS all.

- [ ] **Step 5: Commit**

```bash
git add src/25-config.ps1 tests/config.tests.ps1
git commit -m "feat: Remove-SsmTenantData deletes cert/cache/exports and config entry"
```

---

### Task 8: Tenant switcher modal + `T` keybinding

**Files:**
- Modify: `src/55-tenant-actions.ps1` (append `Show-TenantSwitcherModal`)
- Modify: `src/75-key-dispatch.ps1` (bind global `T` in `Invoke-KeyDispatch`; remove the now-dead "Tenant posture loads in Task 11" stub wording if it conflicts — do not change behaviour otherwise)
- Test: none (UI wiring; covered by manual smoke)

**Interfaces:**
- Consumes: `Get-SsmTenantNames`, `Get-SsmConfig`, `Switch-SsmTenant`, `Test-SsmCacheAvailable`, `Show-ListModal` (exists in `20-modals.ps1`), `Show-ConfirmModal`, `Show-MsgModal`, `Disconnect-PnPOnline` (PnP), `Write-SsmLog`.
- Produces: `Show-TenantSwitcherModal` — modal lists tenants; on pick, confirms, disconnects, calls `Switch-SsmTenant`, updates `$script:UI.RestoreInfo`, marks `$script:UI.Dirty = $true`.

- [ ] **Step 1: Implement**

Append to `src/55-tenant-actions.ps1`:

```powershell
function Show-TenantSwitcherModal {
    $names = @(Get-SsmTenantNames)
    if ($names.Count -eq 0) {
        Show-MsgModal -Title 'Switch tenant' -Lines @('No tenants configured yet.', 'Use the Setup tab to add one.') -Kind Warn
        return
    }
    $c = Get-SsmConfig
    $options = @()
    foreach ($n in $names) {
        $e = $c.Tenants[$n]
        $marker = if ($n -eq $script:TenantName) { ' (active)' } else { '' }
        $options += ("{0}{1} - {2}" -f $n, $marker, $e.AuthMode)
    }
    $pick = Show-ListModal -Title 'Switch tenant' -Prompt 'Select tenant:' -Options $options -Default $script:TenantName
    if (-not $pick) { return }
    # Extract tenant name back out of the decorated label.
    $name = ($pick -split ' - ')[0] -replace ' \(active\)$', ''
    if ($name -eq $script:TenantName) { return }
    if (-not ($c.Tenants.ContainsKey($name))) { return }

    $hasState = $false
    foreach ($tab in @($script:Tabs)) {
        if ($tab['Kind'] -eq 'Targets' -and @($tab['Items']).Count -gt 0) { $hasState = $true; break }
    }
    if ($hasState) {
        $ok = Show-ConfirmModal -Title 'Switch tenant' -Lines @(
            ("Switch from '{0}' to '{1}'?" -f $script:TenantName, $name), '',
            'Current scan state in memory will be discarded.',
            'The on-disk cache for this tenant is kept and can be restored.')
        if (-not $ok) { return }
    }

    try { if ($script:Conn.Url) { Disconnect-PnPOnline -ErrorAction SilentlyContinue } } catch {}
    if (Switch-SsmTenant -Name $name) {
        if (Get-Command Test-SsmCacheAvailable -ErrorAction SilentlyContinue) {
            $script:UI.RestoreInfo = Test-SsmCacheAvailable
        }
        $script:UI.Dirty = $true
        Show-MsgModal -Title 'Switched' -Lines @("Active tenant: $name")
    }
}
```

In `src/75-key-dispatch.ps1`, inside `Invoke-KeyDispatch`, right after the `'?'` help binding, add:

```powershell
    if ($upper -eq 'T' -and $tab['Kind'] -ne 'Targets') { Show-TenantSwitcherModal; return }
```

Note: the `T` key on a Targets tab is already bound to `Show-CategoryToggleModal`. Binding switcher globally would shadow it. Restricting the switcher to non-Targets tabs avoids the conflict; the footer/help text can note `T` on any non-Targets tab.

- [ ] **Step 2: Manual smoke**

Run `pwsh ./SharePoint-Sharing-Manager.ps1`, add two tenants via Setup, press `T` on Setup tab, switch between them, confirm tabs clear and cache restore prompt appears.

- [ ] **Step 3: Commit**

```bash
git add src/55-tenant-actions.ps1 src/75-key-dispatch.ps1
git commit -m "feat: tenant switcher modal on T key (non-Targets tabs)"
```

---

### Task 9: Setup tab tenant list + remove flow

**Files:**
- Modify: `src/60-setup-actions.ps1` (add `Show-TenantListModal` and `Invoke-RemoveTenantFlow`)
- Modify: `src/75-key-dispatch.ps1` (`Invoke-SetupKey` add `L` = list/manage tenants)
- Test: none (UI wiring)

**Interfaces:**
- Consumes: `Get-SsmTenantNames`, `Get-SsmConfig`, `Add-SsmTenant`, `Set-SsmDefaultTenant`, `Remove-SsmTenantData`, `Show-ListModal`, `Show-InputModal`, `Show-ConfirmModal`, `Show-MsgModal`.
- Produces:
  - `Show-TenantListModal` — lists tenants with markers for active/default; keys inside the modal are out of scope (modal is selection-only) — management actions happen via follow-up prompts after a submenu pick.
  - `Invoke-RemoveTenantFlow -Name <string>` — confirmation modal with the two checkboxes, calls `Remove-SsmTenantData`, reports outcome.

- [ ] **Step 1: Implement**

Append to `src/60-setup-actions.ps1`:

```powershell
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

function Show-TenantListModal {
    $names = @(Get-SsmTenantNames)
    $c = Get-SsmConfig
    $options = @()
    foreach ($n in $names) {
        $tag = @()
        if ($n -eq $script:TenantName)    { $tag += 'active' }
        if ($n -eq $c.DefaultTenant)      { $tag += 'default' }
        $suffix = if ($tag) { ' [' + ($tag -join ',') + ']' } else { '' }
        $options += ($n + $suffix)
    }
    $options += '<add new tenant>'
    $pick = Show-ListModal -Title 'Tenants' -Prompt 'Select:' -Options $options
    if (-not $pick) { return }
    if ($pick -eq '<add new tenant>') {
        $name = Show-InputModal -Title 'Add tenant' -Prompt 'Tenant display name (e.g. contoso):'
        if (-not $name) { return }
        if (Add-SsmTenant -Name $name) {
            Show-MsgModal -Title 'Added' -Lines @(("Tenant '{0}' added." -f $name), 'Configure auth via D or C on the Setup tab.')
        } else {
            Show-MsgModal -Title 'Add failed' -Lines @('Name already exists or would share a cache directory with another tenant.') -Kind Warn
        }
        return
    }
    $name = ($pick -replace ' \[.*\]$', '')
    $action = Show-ListModal -Title $name -Prompt 'Action:' -Options @('Set as default', 'Remove tenant', 'Cancel')
    switch ($action) {
        'Set as default' {
            if (Set-SsmDefaultTenant -Name $name) {
                Show-MsgModal -Title 'Default' -Lines @(("'{0}' is now the startup tenant." -f $name))
            }
        }
        'Remove tenant' { Invoke-RemoveTenantFlow -Name $name }
    }
}
```

In `src/75-key-dispatch.ps1`, extend `Invoke-SetupKey`:

```powershell
        'L' { Show-TenantListModal; return }
```

- [ ] **Step 2: Manual smoke**

Run the tool, add two tenants, set default, remove one with `DELETE`, confirm cert/cache removed from disk; remove another answering `EXPORTS` and confirm exports gone.

- [ ] **Step 3: Commit**

```bash
git add src/60-setup-actions.ps1 src/75-key-dispatch.ps1
git commit -m "feat: Setup tab tenant list with add/set-default/remove flows"
```

---

### Task 10: Wire setup auth actions to active tenant name

**Files:**
- Modify: `src/60-setup-actions.ps1` (`Register-SsmDelegatedApp`, `Register-SsmAppOnlyApp`, `Update-SsmCertificate`, `Edit-SsmConfig` set `$script:TenantName` before `Save-SsmAuth` when unset)
- Test: extend `tests/config.tests.ps1` with a Save-SsmAuth round-trip when TenantName pre-set.

**Interfaces:**
- Consumes: existing `Save-SsmAuth` behaviour from Task 2 (auto-derives name from `$script:Auth.Tenant` when `$script:TenantName` empty).
- Produces: no new functions; ensures registration flows land under the right tenant key.

- [ ] **Step 1: Write the failing test**

Append to `tests/config.tests.ps1`:

```powershell
Invoke-SsmTest 'Save-SsmAuth derives tenant name from Auth.Tenant when unset' {
    $p = Join-Path ([IO.Path]::GetTempPath()) ("ssm-derive-{0}.json" -f [guid]::NewGuid())
    $script:ConfigPath = $p
    $script:TenantName = ''
    $script:Auth = @{ AuthMode='Delegated'; ClientId='x'; Tenant='fabrikam.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires=''; Loaded=$true }
    Save-SsmAuth
    Assert-Equal 'fabrikam' $script:TenantName
    $c = Get-SsmConfig -Path $p
    Assert-Equal 'fabrikam' $c.DefaultTenant
    Assert-Equal $true ($c.Tenants.ContainsKey('fabrikam'))
    Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/run-tests.ps1`
Expected: PASS already (Task 2's `Save-SsmAuth` handles this). If it passes without changes, treat as regression coverage and skip implementation step.

- [ ] **Step 3: Implementation**

No code change needed — Task 2's `Save-SsmAuth` already derives. The four setup actions call `Save-SsmAuth` after mutating `$script:Auth`, which is the correct hook. Verified by reading `60-setup-actions.ps1` (`Register-SsmDelegatedApp`, `Register-SsmAppOnlyApp`, `Update-SsmCertificate`, `Edit-SsmConfig` all end in `Save-SsmAuth`).

- [ ] **Step 4: Run tests**

Run: `pwsh tests/run-tests.ps1`
Expected: PASS all.

- [ ] **Step 5: Commit**

```bash
git add tests/config.tests.ps1
git commit -m "test: cover Save-SsmAuth tenant-name derivation"
```

---

### Task 11: Full test pass + manual two-tenant smoke

**Files:**
- No file changes expected; fixes land under earlier tasks if regressions surface.

- [ ] **Step 1: Full suite**

Run: `pwsh tests/run-tests.ps1`
Expected: all pass, zero failed.

- [ ] **Step 2: PSScriptAnalyzer**

Run: `Invoke-ScriptAnalyzer -Path src/ -Settings PSScriptAnalyzerSettings.psd1`
Expected: no new warnings introduced.

- [ ] **Step 3: Manual smoke script**

```
1. Backup ~/.sharepoint-sharing-manager.json
2. Launch tool on legacy config -> confirm migration log line + tenant name in title.
3. T (on Setup tab) -> add second tenant via wizard.
4. Scan a site under tenant A, quit, confirm SSM-Cache/<slugA>/session.json exists.
5. Relaunch, switch to tenant B via T, confirm targets cleared.
6. Scan a site under tenant B, quit, confirm SSM-Cache/<slugB>/session.json.
7. Relaunch, Setup -> L -> remove tenant B -> type DELETE, type EXPORTS.
8. Confirm cert removed (Get-ChildItem Cert:\CurrentUser\My), cache + exports dirs gone, config entry gone.
```

- [ ] **Step 4: Update CHANGELOG + README + bump version**

Edit `CHANGELOG.md`, `README.md` (auth/setup sections), `$script:Version` in `src/00-globals.ps1` to `1.4.0`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "release: 1.4.0 - multi-tenant support"
```

---

## Self-review notes

- Spec coverage: config v2 ✓ (T2), migration ✓ (T2/T4), paths ✓ (T3), switcher ✓ (T6/T8), setup tab list + remove ✓ (T9), remove with cert/cache/exports ✓ (T7/T9), cert uniqueness enforced implicitly by always generating new certs (existing wizard behaviour, unchanged).
- Placeholder scan: no TBDs; each code step includes runnable code or an explicit statement that no code change is needed (T10) with the test proving it.
- Type consistency: `ConvertTo-SsmTenantSlug`, `Set-SsmTenantPaths`, `Switch-SsmTenant`, `Remove-SsmTenantData`, `Get-SsmTenantNames`, `Add-SsmTenant`, `Remove-SsmTenant`, `Set-SsmDefaultTenant`, `Initialize-SsmTenancy` used consistently across tasks.
- Out of scope (flagged in spec, not planned): concurrent multi-tenant sessions; cross-tenant views.
