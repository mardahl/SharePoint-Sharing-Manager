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

Invoke-SsmTest 'TenantSettings covers link/access expiration and resharing beyond anyone-link expiry' {
    $props = @($script:TenantSettings | Select-Object -ExpandProperty Prop)
    foreach ($expected in @('ExternalUserExpirationRequired','ExternalUserExpireInDays','PreventExternalUsersFromResharing','SharingDomainRestrictionMode','FileAnonymousLinkType','FolderAnonymousLinkType')) {
        if ($props -notcontains $expected) { throw "TenantSettings is missing $expected" }
    }
    if (@($script:TenantSettings).Count -ne 19) { throw "expected 19 tenant settings, got $(@($script:TenantSettings).Count)" }
}

Invoke-SsmTest 'SharingCapabilityLabels maps every enum value to the SPO admin UI wording' {
    $cap = @($script:TenantSettings | Where-Object { $_.Prop -eq 'SharingCapability' }).Values
    foreach ($v in $cap) {
        if (-not $script:SharingCapabilityLabels.ContainsKey($v)) { throw "no vanity label for $v" }
    }
    Assert-Equal 'Anyone' $script:SharingCapabilityLabels['ExternalUserAndGuestSharing']
    Assert-Equal 'Only people in your organization' $script:SharingCapabilityLabels['Disabled']
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

Invoke-SsmTest 'CIS baseline covers the CIS 7.2.x tenant knobs' {
    foreach ($k in @('SharingCapability','DefaultSharingLinkType','DefaultLinkPermission','ExternalUserExpireInDays','EmailAttestationReAuthDays')) {
        if (-not $script:CisBaselineL1.Contains($k)) { throw "L1 baseline missing $k" }
    }
    foreach ($k in @('OneDriveSharingCapability','PreventExternalUsersFromResharing')) {
        if (-not $script:CisBaselineL2.Contains($k)) { throw "L2 baseline missing $k" }
    }
    Assert-Equal 'ExternalUserSharingOnly' $script:CisBaselineL1['SharingCapability']
    Assert-Equal 'View' $script:CisBaselineL1['DefaultLinkPermission']
}

Invoke-SsmTest 'CIS snapshot saves and reloads current tenant values' {
    $script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssm-cis-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
    $savedDir = $script:CacheDir; $savedName = $script:TenantName
    $script:CacheDir = $script:TestRoot; $script:TenantName = 't1'
    $script:Tabs = @(@{}, @{}, @{ Kind='Tenant'; Loaded=$true; Posture=@{ SharingCapability='ExternalUserAndGuestSharing'; DefaultLinkPermission='Edit'; ExternalUserExpireInDays='60' } })
    try {
        Save-CisSnapshot -Props @('SharingCapability','DefaultLinkPermission','ExternalUserExpireInDays') | Out-Null
        $snap = Get-CisSnapshot
        Assert-Equal 'ExternalUserAndGuestSharing' $snap.Values.SharingCapability
        Assert-Equal 'Edit' $snap.Values.DefaultLinkPermission
        Assert-Equal '60' $snap.Values.ExternalUserExpireInDays
        Assert-Equal 't1' $snap.Tenant
    } finally {
        $script:CacheDir = $savedDir; $script:TenantName = $savedName
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
    }
}

Invoke-SsmTest 'TenantSettings surfaces every CIS baseline knob for manual adjustment' {
    $props = @($script:TenantSettings | Select-Object -ExpandProperty Prop)
    foreach ($k in @($script:CisBaselineL1.Keys) + @($script:CisBaselineL2.Keys)) {
        if ($props -notcontains $k) { throw "TenantSettings missing CIS knob $k" }
    }
}

Invoke-SsmTest 'Test-CisAlignment: aligned, misaligned, and unlisted settings' {
    Assert-Equal 'True'  (Test-CisAlignment 'SharingCapability' 'Disabled')                    # stricter than CIS
    Assert-Equal 'True'  (Test-CisAlignment 'SharingCapability' 'ExternalUserSharingOnly')     # exact match
    Assert-Equal 'False' (Test-CisAlignment 'SharingCapability' 'ExternalUserAndGuestSharing') # Anyone = fail
    Assert-Equal 'False' (Test-CisAlignment 'OneDriveSharingCapability' 'ExternalUserSharingOnly')
    Assert-Equal 'True'  (Test-CisAlignment 'LegacyAuthProtocolsEnabled' 'False')
    Assert-Equal 'False' (Test-CisAlignment 'LegacyAuthProtocolsEnabled' 'True')
    Assert-Equal 'True'  (Test-CisAlignment 'ExternalUserExpireInDays' '30')
    Assert-Equal 'True'  (Test-CisAlignment 'ExternalUserExpireInDays' '14')
    Assert-Equal 'False' (Test-CisAlignment 'ExternalUserExpireInDays' '31')
    Assert-Equal 'False' (Test-CisAlignment 'DefaultLinkPermission' 'Edit')
    Assert-Equal 'True'  (Test-CisAlignment 'DefaultSharingLinkType' 'Direct')
    Assert-Equal 'True'  (Test-CisAlignment 'DefaultSharingLinkType' 'Internal')
    Assert-Equal 'False' (Test-CisAlignment 'DefaultSharingLinkType' 'AnonymousAccess')
    Assert-Equal ''      (Test-CisAlignment 'ShowEveryoneClaim' 'True')   # no CIS rule -> null
    Assert-Equal ''      (Test-CisAlignment 'RequireAnonymousLinksExpireInDays' '14')
}

Invoke-SsmTest 'TenantSettings order matches Enter dispatch (no N-field drift)' {
    # Regression: view listed new CIS props at positions 12-15 while their N
    # values were 16-19, so Enter on LegacyAuthProtocolsEnabled opened the
    # ShowEveryoneClaim picker. Order-based lookup makes this impossible.
    Assert-Equal 'LegacyAuthProtocolsEnabled' $script:TenantSettings[11].Prop
    Assert-Equal 'EnableAzureADB2BIntegration' $script:TenantSettings[12].Prop
    Assert-Equal 'EmailAttestationRequired' $script:TenantSettings[13].Prop
    Assert-Equal 'EmailAttestationReAuthDays' $script:TenantSettings[14].Prop
    Assert-Equal 'ShowEveryoneClaim' $script:TenantSettings[15].Prop
    Assert-Equal 'AllowEveryoneExceptExternalUsersClaimInPrivateSite' $script:TenantSettings[18].Prop
    foreach ($s in $script:TenantSettings) {
        if ($s.ContainsKey('N')) { throw "stale N field on $($s.Prop) - order-based lookup in use" }
        if (-not $s.Note) { throw "missing Note on $($s.Prop) - shown in the header line" }
    }
}

Invoke-SsmTest 'Get-CisSnapshot returns null when no snapshot exists' {
    $script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssm-cis-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
    $savedDir = $script:CacheDir; $script:CacheDir = $script:TestRoot
    try { Assert-Equal '' "$(Get-CisSnapshot)" }
    finally { $script:CacheDir = $savedDir; Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
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
