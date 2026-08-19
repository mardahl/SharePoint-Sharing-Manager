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
