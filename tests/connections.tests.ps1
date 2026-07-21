Invoke-SsmTest 'Connect params: delegated' {
    $script:Auth = @{ Loaded=$true; AuthMode='Delegated'; ClientId='cid'; Tenant=''; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
    $p = Get-ConnectParams -Url 'https://x.sharepoint.com/sites/a'
    Assert-Equal 'cid' $p.ClientId
    Assert-Equal 'True' $p.Interactive
    Assert-Equal 'False' $p.ContainsKey('Thumbprint')
}
Invoke-SsmTest 'Connect params: app-only thumbprint' {
    $script:Auth = @{ Loaded=$true; AuthMode='AppOnly'; ClientId='cid'; Tenant='contoso.onmicrosoft.com'; AdminUrl=''; Thumbprint='ABCD'; CertPath=''; CertExpires='' }
    $p = Get-ConnectParams -Url 'https://x.sharepoint.com/sites/a'
    Assert-Equal 'ABCD' $p.Thumbprint
    Assert-Equal 'contoso.onmicrosoft.com' $p.Tenant
    Assert-Equal 'False' $p.ContainsKey('Interactive')
}
Invoke-SsmTest 'Connect params: app-only pfx path when no thumbprint' {
    $script:Auth = @{ Loaded=$true; AuthMode='AppOnly'; ClientId='cid'; Tenant='contoso.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath='/tmp/a.pfx'; CertExpires='' }
    $p = Get-ConnectParams -Url 'https://x.sharepoint.com/sites/a'
    Assert-Equal '/tmp/a.pfx' $p.CertificatePath
}
