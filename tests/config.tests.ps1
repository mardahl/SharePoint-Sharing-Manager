$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ssm-cfg-{0}.json" -f [guid]::NewGuid())

Invoke-SsmTest 'Get-SsmConfig returns null for missing file' {
    Assert-Equal '' (Get-SsmConfig -Path $tmp)
}
Invoke-SsmTest 'Save/Get round-trips all fields' {
    Save-SsmConfig -Path $tmp -Config @{
        AuthMode='AppOnly'; ClientId='11111111-1111-1111-1111-111111111111'
        Tenant='contoso.onmicrosoft.com'; AdminUrl='https://contoso-admin.sharepoint.com'
        Thumbprint='ABCD'; CertPath=''; CertExpires='2027-07-21'
    }
    $c = Get-SsmConfig -Path $tmp
    Assert-Equal 'AppOnly' $c.Tenants['contoso'].AuthMode
    Assert-Equal 'ABCD' $c.Tenants['contoso'].Thumbprint
    Assert-Equal '2027-07-21' $c.Tenants['contoso'].CertExpires
}
Invoke-SsmTest 'Get-SsmConfig survives corrupt JSON' {
    Set-Content -LiteralPath $tmp -Value '{not json'
    Assert-Equal '' (Get-SsmConfig -Path $tmp)
}
Invoke-SsmTest 'Test-SsmAuthReady: delegated needs ClientId only' {
    $script:Auth = @{ Loaded=$true; AuthMode='Delegated'; ClientId='x'; Tenant=''; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
    Assert-Equal 'True' (Test-SsmAuthReady)
}
Invoke-SsmTest 'Test-SsmAuthReady: app-only needs tenant + cert' {
    $script:Auth = @{ Loaded=$true; AuthMode='AppOnly'; ClientId='x'; Tenant=''; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
    Assert-Equal 'False' (Test-SsmAuthReady)
    $script:Auth.Tenant = 'contoso.onmicrosoft.com'; $script:Auth.Thumbprint = 'ABCD'
    Assert-Equal 'True' (Test-SsmAuthReady)
}
Invoke-SsmTest 'Get-CertDaysLeft parses ISO date' {
    $script:Auth.CertExpires = (Get-Date).AddDays(10).ToString('yyyy-MM-dd')
    $d = Get-CertDaysLeft
    if ($d -lt 9 -or $d -gt 10) { throw "expected ~10, got $d" }
}
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
Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue

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

Invoke-SsmTest 'Add/Remove/Default tenant helpers' {
    $p = Join-Path ([IO.Path]::GetTempPath()) ("ssm-crud-{0}.json" -f [guid]::NewGuid())
    $script:ConfigPath = $p
    Save-SsmConfig -Path $p -Config @{ Version=2; DefaultTenant=''; Tenants=@{} }
    Assert-Equal $true (Add-SsmTenant -Name 'contoso')
    Assert-Equal $true (Add-SsmTenant -Name 'fabrikam')
    Assert-Equal $false (Add-SsmTenant -Name 'contoso')          # exact dup
    Assert-Equal $true (Add-SsmTenant -Name 'Contoso Ltd')       # different slug ok
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

Invoke-SsmTest 'Remove-SsmTenantData deletes cache+exports per flags, removes config' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ssm-rm-{0}" -f [guid]::NewGuid())
    $script:Root = $root
    $p = Join-Path $root 'cfg.json'
    $script:ConfigPath = $p
    New-Item -ItemType Directory -Path $root -Force | Out-Null
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
    New-Item -ItemType Directory -Path $root -Force | Out-Null
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
