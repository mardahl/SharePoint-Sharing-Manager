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
