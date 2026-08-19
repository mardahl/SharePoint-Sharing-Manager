# View test: capture Add-SetupView output by stubbing Add-FrameLine.
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssm-test-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
$script:ConfigPath = Join-Path $script:TestRoot 'config.json'
@{
    Version = 2; DefaultTenant = 'contoso'
    Tenants = @{
        contoso = @{ AuthMode = 'AppOnly'; ClientId = 'abc'; Tenant = 'contoso.onmicrosoft.com'; AdminUrl = 'https://contoso-admin.sharepoint.com'; Thumbprint = 'THUMB'; CertPath = ''; CertExpires = '2027-01-01' }
        empty   = @{ AuthMode = ''; ClientId = ''; Tenant = ''; AdminUrl = ''; Thumbprint = ''; CertPath = ''; CertExpires = '' }
    }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8

$script:TenantName = 'contoso'
$script:T = @{ Ctx=''; Muted=''; Row=''; CtxHi=''; CursorBg=''; CursorFg=''; Ok=''; Warn=''; Reset='' }
$script:G = @{ Ell='...' }

function Add-FrameLine { param($Sb, [int]$Row, [string]$Content) $script:Captured[$Row] = $Content }
function Get-CertDaysLeft { $null }

function Capture-SetupView {
    $script:Captured = @{}
    $sb = New-Object System.Text.StringBuilder
    Add-SetupView -Sb $sb -W 100 -H 30
    return ($script:Captured.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Value }) -join "`n"
}

Invoke-SsmTest 'Test-SsmTenantConfigured: complete app-only entry passes' {
    $e = @{ AuthMode='AppOnly'; ClientId='x'; Tenant='t.onmicrosoft.com'; Thumbprint='th'; CertPath='' }
    Assert-Equal 'True' (Test-SsmTenantConfigured -Entry $e)
}

Invoke-SsmTest 'Test-SsmTenantConfigured: empty entry fails' {
    $e = @{ AuthMode=''; ClientId=''; Tenant=''; Thumbprint=''; CertPath='' }
    Assert-Equal 'False' (Test-SsmTenantConfigured -Entry $e)
}

Invoke-SsmTest 'Setup view lists tenants with active/default/configured markers' {
    $script:Tabs = @(@{ Kind='Targets' }, @{ Kind='Targets' }, @{ Kind='Tenant' }, @{ Kind='Setup'; Cursor=0 })
    $script:UI = @{ Tab = 3 }
    $out = Capture-SetupView
    if ($out -notmatch 'contoso \[active,default\] +AppOnly +configured') { throw "missing contoso row: $out" }
    if ($out -notmatch 'empty .*not configured') { throw "missing empty row: $out" }
}

Invoke-SsmTest 'Setup view shows PnP module status line' {
    $script:Tabs = @(@{ Kind='Targets' }, @{ Kind='Targets' }, @{ Kind='Tenant' }, @{ Kind='Setup'; Cursor=0 })
    $script:UI = @{ Tab = 3 }
    $out = Capture-SetupView
    if ($out -notmatch 'PnP module  : ') { throw "missing PnP line: $out" }
}

Invoke-SsmTest 'Setup view cursor clamps past end of list' {
    $script:Tabs = @(@{ Kind='Targets' }, @{ Kind='Targets' }, @{ Kind='Tenant' }, @{ Kind='Setup'; Cursor=99 })
    $script:UI = @{ Tab = 3 }
    $null = Capture-SetupView
    Assert-Equal 1 $script:Tabs[3]['Cursor']
}

Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
