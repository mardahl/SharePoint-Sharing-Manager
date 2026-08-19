# ============================================================================
#region Tenant actions
# ============================================================================

$script:TenantSettings = @(
    @{ N=1; Prop='SharingCapability';                 Values=@('Disabled','ExistingExternalUserSharingOnly','ExternalUserSharingOnly','ExternalUserAndGuestSharing') },
    @{ N=2; Prop='OneDriveSharingCapability';         Values=@('Disabled','ExistingExternalUserSharingOnly','ExternalUserSharingOnly','ExternalUserAndGuestSharing') },
    @{ N=3; Prop='DefaultSharingLinkType';            Values=@('None','Direct','Internal','AnonymousAccess') },
    @{ N=4; Prop='DefaultLinkPermission';             Values=@('None','View','Edit') },
    @{ N=5; Prop='RequireAnonymousLinksExpireInDays'; Values=@() },  # numeric, free input
    # Org-wide sharing claims + EEEU (Everyone Except External Users) grants in the People
    # Picker - hiding/disabling these stops users from re-creating the org-wide/EEEU grants
    # this tool's scan engine finds and revokes (see 35-scan-engine.ps1).
    @{ N=6; Prop='ShowEveryoneClaim';                              Values=@('True','False') },
    @{ N=7; Prop='ShowAllUsersClaim';                              Values=@('True','False') },
    @{ N=8; Prop='ShowEveryoneExceptExternalUsersClaim';           Values=@('True','False') },
    @{ N=9; Prop='AllowEveryoneExceptExternalUsersClaimInPrivateSite'; Values=@('True','False') }
)

function Get-TenantPosture {
    # Connect + Get-PnPTenant are blocking single-threaded calls, so drive the
    # same spinner/progress modal the target-enumeration path uses - otherwise
    # the TUI freezes on its last frame with no feedback while it connects.
    Start-LoadSpinner
    Write-ProgressModal -Title 'Tenant' -Done 0 -Total 0 -Label 'Reading tenant sharing posture...' -Ok 0 -Failed 0
    try {
        if (-not (Connect-SsmAdmin)) { return $false }
        $t = Get-PnPTenant -ErrorAction Stop
    } finally {
        Stop-LoadSpinner
    }
    $script:Tabs[2].Posture = @{
        SharingCapability                 = [string]$t.SharingCapability
        OneDriveSharingCapability         = [string]$t.OneDriveSharingCapability
        DefaultSharingLinkType            = [string]$t.DefaultSharingLinkType
        DefaultLinkPermission             = [string]$t.DefaultLinkPermission
        RequireAnonymousLinksExpireInDays = [string]$t.RequireAnonymousLinksExpireInDays
        ShowEveryoneClaim                              = [string]$t.ShowEveryoneClaim
        ShowAllUsersClaim                              = [string]$t.ShowAllUsersClaim
        ShowEveryoneExceptExternalUsersClaim           = [string]$t.ShowEveryoneExceptExternalUsersClaim
        AllowEveryoneExceptExternalUsersClaimInPrivateSite = [string]$t.AllowEveryoneExceptExternalUsersClaimInPrivateSite
        CheckedAt                         = Get-Date
    }
    $script:Tabs[2].Loaded = $true
    Write-SsmLog -Message 'Tenant sharing posture loaded.' -Level OK
    $script:UI.Dirty = $true
    return $true
}

function Invoke-TenantSetting {
    # ponytail: param named -Setting (not -Number) to match the call
    # signature already committed in Invoke-TenantKey (src/75-key-dispatch.ps1
    # Task 10), which invokes this as `Invoke-TenantSetting -Setting <n>`.
    param([int]$Setting)
    if (-not $script:Tabs[2].Loaded) { Show-MsgModal -Title 'Tenant' -Lines @('Load the posture first (Enter).'); return }
    $s = $script:TenantSettings | Where-Object { $_.N -eq $Setting }
    if (-not $s) { return }
    $current = $script:Tabs[2].Posture[$s.Prop]
    # Fixed-value settings get a navigable picker so the operator selects a
    # valid value instead of typing a raw string; only the numeric expiry
    # setting (empty Values) falls back to free-text input.
    if ($s.Values.Count -gt 0) {
        $new = Show-ListModal -Title $s.Prop -Prompt 'Select a value:' -Options $s.Values -Default $current
    } else {
        $new = Show-InputModal -Title $s.Prop -Prompt 'Number of days (0 = no requirement)' -Default $current
    }
    if (-not $new -or $new -eq $current) { return }
    $ok = Show-TypedConfirmModal -Title 'Change tenant setting' -Word 'APPLY' -Lines @(
        ("{0}: {1} {2} {3}" -f $s.Prop, $current, [string]$script:G.Arrow, $new), '',
        'This changes sharing behavior for the WHOLE tenant.')
    if (-not $ok) { return }
    try {
        $setArgs = @{ $s.Prop = $new }
        Set-PnPTenant @setArgs -ErrorAction Stop
        Write-SsmLog -Message ("Tenant setting changed: {0} = {1}" -f $s.Prop, $new) -Level OK
        [void](Get-TenantPosture)
    } catch {
        Write-SsmLog -Message ("Tenant setting failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @($_.Exception.Message) -Kind Error
    }
}

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
    $defaultOption = if ($names -contains $script:TenantName) { $options[[Array]::IndexOf($names, $script:TenantName)] } else { '' }
    $pick = Show-ListModal -Title 'Switch tenant' -Prompt 'Select tenant:' -Options $options -Default $defaultOption
    if (-not $pick) { return }
    # Match the picked decorated label back to its tenant name by index, not by
    # parsing the label (tenant names may contain ' - ').
    $idx = [Array]::IndexOf($options, $pick)
    if ($idx -lt 0) { return }
    $name = $names[$idx]
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

#endregion
