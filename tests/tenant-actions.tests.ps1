# Stubs for the modal/UI functions Invoke-TenantSetting and Invoke-KeyDispatch
# call into; none of them should actually run for the cases exercised here.
function Show-MsgModal { param($Title, $Lines, $Kind) $script:LastMsgModal = $Lines -join ' ' }
function Show-InputModal { param($Title, $Prompt, $Default) $null }
function Show-TypedConfirmModal { param($Title, $Word, $Lines) $false }

function New-TestKey([string]$Char) {
    $key = [Enum]::Parse([System.ConsoleKey], ('D' + $Char))
    [System.ConsoleKeyInfo]::new($Char, $key, $false, $false, $false)
}

function Reset-TestUiState {
    $script:UI = @{ Tab = 2; SearchMode = $false; Dirty = $false; Quit = $false }
    $script:Tabs = @(
        @{ Kind = 'Targets' }, @{ Kind = 'Targets' },
        @{ Kind = 'Tenant'; Loaded = $false; Posture = $null },
        @{ Kind = 'Setup' }, @{ Kind = 'Log' }
    )
    $script:LastMsgModal = ''
}

Invoke-SsmTest 'TenantSettings covers the org-wide/EEEU claim hardening settings' {
    $props = @($script:TenantSettings | Select-Object -ExpandProperty Prop)
    foreach ($expected in @('ShowEveryoneClaim','ShowAllUsersClaim','ShowEveryoneExceptExternalUsersClaim','AllowEveryoneExceptExternalUsersClaimInPrivateSite')) {
        if ($props -notcontains $expected) { throw "TenantSettings is missing $expected" }
    }
}

Invoke-SsmTest 'Digit key on the Tenant tab jumps tabs (menu no longer captures digits)' {
    Reset-TestUiState
    Invoke-KeyDispatch -K (New-TestKey '2')
    Assert-Equal 1 $script:UI.Tab   # jumped to OneDrives (index 1), tab switching not blocked
}

Invoke-SsmTest 'Digit key on a non-Tenant tab still jumps tabs' {
    Reset-TestUiState
    $script:UI.Tab = 3   # Setup tab
    Invoke-KeyDispatch -K (New-TestKey '1')
    Assert-Equal 0 $script:UI.Tab   # jumped to Sites (index 0)
}

Invoke-SsmTest 'Down arrow on the Tenant tab moves the setting cursor' {
    Reset-TestUiState
    $script:Tabs[2]['Cursor'] = 0
    $down = [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::DownArrow, $false, $false, $false)
    Invoke-KeyDispatch -K $down
    Assert-Equal 1 $script:Tabs[2]['Cursor']
}

Invoke-SsmTest 'Switch-SsmTenant resets the Sharing tab posture (no stale cross-tenant display)' {
    $script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssm-test-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
    # ConfigPath/Root come from 00-globals.ps1, which the harness never loads
    # (this file may run before any test sets them). Initialize if absent.
    $script:ConfigPath = Join-Path $script:TestRoot 'config.json'
    $script:Root = $script:TestRoot
    # setup-keys.tests.ps1 (runs earlier, alphabetically) stubs Switch-SsmTenant
    # globally; re-source the real implementation for this test.
    . (Join-Path $PSScriptRoot '..' 'src' '25-config.ps1')
    try {
        @{
            Version = 2; DefaultTenant = 'a'
            Tenants = @{
                a = @{ AuthMode='Delegated'; ClientId='id-a'; Tenant='a.onmicrosoft.com' }
                b = @{ AuthMode='Delegated'; ClientId='id-b'; Tenant='b.onmicrosoft.com' }
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8

        $script:Auth = @{ AuthMode='Delegated'; ClientId='id-a'; Tenant='a.onmicrosoft.com'; Loaded=$true }
        $script:TenantName = 'a'
        $script:Conn = @{ Url=''; Admin=$false; Account='' }
        $script:Tabs = @(
            @{ Kind='Targets'; Items=@(); View=@(); Loaded=$false; Mode='Targets'; Search=''; Cursor=0; Scroll=0; FTab=$null },
            @{ Kind='Targets'; Items=@(); View=@(); Loaded=$false; Mode='Targets'; Search=''; Cursor=0; Scroll=0; FTab=$null },
            @{ Kind='Tenant'; Loaded=$true; Posture=@{ SharingCapability='ExternalUserAndGuestSharing' }; Cursor=3 }
        )

        $ok = Switch-SsmTenant -Name 'b'
        Assert-Equal 'True' $ok
        Assert-Equal 'False' $script:Tabs[2].Loaded 'Sharing tab must reload posture after switch'
        Assert-Equal '' "$($script:Tabs[2].Posture)" 'Sharing posture must be cleared'
        Assert-Equal 0 $script:Tabs[2]['Cursor'] 'Sharing cursor resets'
    } finally {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
    }
}

Invoke-SsmTest 'Tab 3 is named Sharing (Tenant rename)' {
    # Dot-sourcing 00-globals.ps1 reinitializes every global; save/restore the
    # ones other test files rely on (config.tests.ps1's Auth fixture predates
    # the full AuthKeys list and breaks under StrictMode otherwise).
    $savedAuth = $script:Auth; $savedAuthKeys = $script:AuthKeys
    $savedTabs = $script:Tabs; $savedTenantName = $script:TenantName
    $Ascii = $false
    . (Join-Path $PSScriptRoot '..' 'src' '00-globals.ps1')
    Assert-Equal 'Sharing' $script:Tabs[2].Name
    Assert-Equal 'Tenant' $script:Tabs[2].Kind   # Kind must NOT change
    $script:Auth = $savedAuth; $script:AuthKeys = $savedAuthKeys
    $script:Tabs = $savedTabs; $script:TenantName = $savedTenantName
}
