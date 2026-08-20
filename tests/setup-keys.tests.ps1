# Key-dispatch tests for the redesigned Setup tab. All modals/actions stubbed.
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssm-test-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
$script:ConfigPath = Join-Path $script:TestRoot 'config.json'
@{
    Version = 2; DefaultTenant = 'a'
    Tenants = @{
        a = @{ AuthMode='Delegated'; ClientId='id-a'; Tenant='a.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
        b = @{ AuthMode=''; ClientId=''; Tenant=''; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires='' }
    }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8

$script:Calls = @()
function Show-MsgModal    { param($Title, $Lines, $Kind) }
function Show-ListModal   { param($Title, $Prompt, $Options) $script:Calls += "list:$Title"; $script:SeenOptions = $Options; $script:NextPick }
function Show-InputModal  { param($Title, $Prompt, $Default) $script:NextInput }
function Switch-SsmTenant { param([string]$Name) $script:Calls += "switch:$Name"; $script:TenantName = $Name; $true }
function Edit-SsmConfig   { $script:Calls += 'edit' }
function Register-SsmDelegatedApp { $script:Calls += 'regdel' }
function Register-SsmAppOnlyApp   { $script:Calls += 'regcert' }
function Update-SsmCertificate    { $script:Calls += 'renew' }
function Set-SsmDefaultTenant     { param([string]$Name) $script:Calls += "default:$Name"; $true }
function Invoke-RemoveTenantFlow  { param([string]$Name) $script:Calls += "remove:$Name" }
function Disconnect-SsmConnection { }

function Reset-SetupUi {
    $script:UI = @{ Tab = 3; SearchMode = $false; Dirty = $false; Quit = $false }
    $script:Tabs = @(
        @{ Kind='Targets' }, @{ Kind='Targets' }, @{ Kind='Tenant' },
        @{ Kind='Setup'; Cursor = 0 }, @{ Kind='Log' }, @{ Kind='About' }
    )
    $script:TenantName = 'a'
    $script:Calls = @()
    $script:NextPick = $null
    $script:NextInput = $null
}

function Key([string]$Char) { [System.ConsoleKeyInfo]::new($Char, [Enum]::Parse([System.ConsoleKey], $Char.ToUpper()), $false, $false, $false) }
function Arrow([System.ConsoleKey]$K) { [System.ConsoleKeyInfo]::new([char]0, $K, $false, $false, $false) }

Invoke-SsmTest 'Down arrow moves Setup cursor, clamps at last tenant' {
    Reset-SetupUi
    Invoke-SetupKey -K (Arrow DownArrow)
    Assert-Equal 1 $script:Tabs[3]['Cursor']
    Invoke-SetupKey -K (Arrow DownArrow)
    Assert-Equal 1 $script:Tabs[3]['Cursor']   # clamped
}

Invoke-SsmTest 'Up arrow clamps at zero' {
    Reset-SetupUi
    Invoke-SetupKey -K (Arrow UpArrow)
    Assert-Equal 0 $script:Tabs[3]['Cursor']
}

Invoke-SsmTest 'Enter on tenant opens the action modal with its name' {
    Reset-SetupUi
    $script:Tabs[3]['Cursor'] = 1
    Invoke-SetupKey -K ([System.ConsoleKeyInfo]::new("`r", [System.ConsoleKey]::Enter, $false,$false,$false))
    Assert-Equal 'list:b' $script:Calls[0]
}

Invoke-SsmTest 'Action modal: edit config on non-active tenant switches first' {
    Reset-SetupUi
    $script:NextPick = 'Edit config'
    Show-TenantActionsModal -Name 'b'
    Assert-Equal 'switch:b' $script:Calls[1]
    Assert-Equal 'edit' $script:Calls[2]
}

Invoke-SsmTest 'Action modal: switch option hidden for active tenant' {
    Reset-SetupUi
    $script:SeenOptions = $null
    $script:NextPick = 'Cancel'
    Show-TenantActionsModal -Name 'a'
    Assert-Equal $null ($script:SeenOptions | Where-Object { $_ -like 'Switch*' })
}

Invoke-SsmTest 'Action modal: remove routes to Invoke-RemoveTenantFlow' {
    Reset-SetupUi
    $script:NextPick = 'Remove tenant'
    Show-TenantActionsModal -Name 'b'
    Assert-Equal 'remove:b' $script:Calls[1]
}

Invoke-SsmTest 'A key runs add-tenant flow' {
    Reset-SetupUi
    $script:NextInput = 'newco'
    Invoke-SetupKey -K (Key 'a')
    $c = Get-SsmConfig
    Assert-Equal 'True' $c.Tenants.ContainsKey('newco')
}

Invoke-SsmTest 'Old flat keys D/C/W/X/L no longer fire on Setup' {
    Reset-SetupUi
    foreach ($ch in @('d','c','w','x','l')) { Invoke-SetupKey -K (Key $ch) }
    Assert-Equal 0 $script:Calls.Count
}

Invoke-SsmTest 'Action modal: toggle link-date lookup flips config for active tenant' {
    Reset-SetupUi
    $script:Auth = @{ AuthMode='Delegated'; ClientId='id-a'; Tenant='a.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires=''; IncludeLinkDates=''; Loaded=$true }
    $script:NextPick = 'Enable link-date lookup'
    Show-TenantActionsModal -Name 'a'
    Assert-Equal 'True' $script:Auth['IncludeLinkDates']
    # Label flips with state (Save-SsmAuth persistence is covered by config tests)
    Show-TenantActionsModal -Name 'a'
    Assert-Equal 'Disable link-date lookup' ($script:SeenOptions | Where-Object { $_ -like '*link-date*' })
    $script:Auth['IncludeLinkDates'] = ''
}

Invoke-SsmTest 'Action modal: toggle on non-active tenant switches first' {
    Reset-SetupUi
    $script:Auth = @{ AuthMode='Delegated'; ClientId='id-a'; Tenant='a.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires=''; IncludeLinkDates=''; Loaded=$true }
    $script:NextPick = 'Enable link-date lookup'
    Show-TenantActionsModal -Name 'b'
    Assert-Equal 'switch:b' $script:Calls[1]
    Assert-Equal 'True' $script:Auth['IncludeLinkDates']
    $script:Auth['IncludeLinkDates'] = ''
}

Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
