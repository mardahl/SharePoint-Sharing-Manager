# ============================================================================
#region Tenant actions
# ============================================================================

$script:TenantSettings = @(
    @{ N=1; Prop='SharingCapability';                 Values=@('Disabled','ExistingExternalUserSharingOnly','ExternalUserSharingOnly','ExternalUserAndGuestSharing') },
    @{ N=2; Prop='OneDriveSharingCapability';         Values=@('Disabled','ExistingExternalUserSharingOnly','ExternalUserSharingOnly','ExternalUserAndGuestSharing') },
    @{ N=3; Prop='DefaultSharingLinkType';            Values=@('None','Direct','Internal','AnonymousAccess') },
    @{ N=4; Prop='DefaultLinkPermission';             Values=@('None','View','Edit') },
    @{ N=5; Prop='RequireAnonymousLinksExpireInDays'; Values=@() }   # numeric, free input
)

function Get-TenantPosture {
    if (-not (Connect-SsmAdmin)) { return $false }
    $t = Get-PnPTenant -ErrorAction Stop
    $script:Tabs[2].Posture = @{
        SharingCapability                 = [string]$t.SharingCapability
        OneDriveSharingCapability         = [string]$t.OneDriveSharingCapability
        DefaultSharingLinkType            = [string]$t.DefaultSharingLinkType
        DefaultLinkPermission             = [string]$t.DefaultLinkPermission
        RequireAnonymousLinksExpireInDays = [string]$t.RequireAnonymousLinksExpireInDays
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
    $prompt = if ($s.Values.Count -gt 0) { 'One of: ' + ($s.Values -join ' | ') } else { 'Number of days (0 = no requirement)' }
    $new = Show-InputModal -Title $s.Prop -Prompt $prompt -Default $current
    if (-not $new -or $new -eq $current) { return }
    if ($s.Values.Count -gt 0 -and $s.Values -notcontains $new) {
        Show-MsgModal -Title 'Invalid value' -Lines @("'$new' is not one of:", ($s.Values -join ', ')) -Kind Warn
        return
    }
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

#endregion
