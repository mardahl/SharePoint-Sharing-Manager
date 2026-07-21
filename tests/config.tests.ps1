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
    Assert-Equal 'AppOnly' $c.AuthMode
    Assert-Equal 'ABCD' $c.Thumbprint
    Assert-Equal '2027-07-21' $c.CertExpires
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
Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
