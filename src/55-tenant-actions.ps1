# ============================================================================
#region Tenant actions
# ============================================================================

# SharingCapability enum values shown in the SPO admin UI (Sharing > External sharing):
#   Disabled                            = Only people in your organization
#   ExistingExternalUserSharingOnly     = Existing guests
#   ExternalUserSharingOnly             = New and existing guests
#   ExternalUserAndGuestSharing         = Anyone
$script:SharingCapabilityLabels = @{
    'Disabled'                          = 'Only people in your organization'
    'ExistingExternalUserSharingOnly'   = 'Existing guests'
    'ExternalUserSharingOnly'           = 'New and existing guests'
    'ExternalUserAndGuestSharing'       = 'Anyone'
}

$script:TenantSettings = @(
    # Row order = display order on the Sharing tab. The view, cursor nav and
    # Enter all index into this array - there is no separate numbering to drift.
    @{ Prop='SharingCapability';                 Values=@('Disabled','ExistingExternalUserSharingOnly','ExternalUserSharingOnly','ExternalUserAndGuestSharing'); Note='SPO admin UI: Sharing > External sharing > SharePoint.' },
    @{ Prop='OneDriveSharingCapability';         Values=@('Disabled','ExistingExternalUserSharingOnly','ExternalUserSharingOnly','ExternalUserAndGuestSharing'); Note='SPO admin UI: Sharing > External sharing > OneDrive (must be <= SharePoint).' },
    @{ Prop='DefaultSharingLinkType';            Values=@('None','Direct','Internal','AnonymousAccess'); Note='Link type pre-selected in the sharing dialog (AnonymousAccess = "Anyone").' },
    @{ Prop='DefaultLinkPermission';             Values=@('None','View','Edit'); Note='Permission pre-selected in the sharing dialog.' },
    @{ Prop='RequireAnonymousLinksExpireInDays'; Values=@(); Note='Expiration for ANONYMOUS (Anyone) links only; guest/org links unaffected. 0/blank = never.' },
    @{ Prop='SharingDomainRestrictionMode';      Values=@('None','AllowList','BlockList'); Note='Limit sharing by domain (AllowList/BlockList); lists editable in SPO admin UI.' },
    @{ Prop='FileAnonymousLinkType';             Values=@('None','View','Edit'); Note='Default permission for anonymous file links (View/Edit).' },
    @{ Prop='FolderAnonymousLinkType';           Values=@('None','View','Edit'); Note='Default permission for anonymous folder links (View/Edit).' },
    @{ Prop='PreventExternalUsersFromResharing'; Values=@('True','False'); Note='Block guests from resharing items with others (True = block, recommended).' },
    @{ Prop='ExternalUserExpirationRequired';    Values=@('True','False'); Note='Guest ACCESS to sites expires after N days (not a link setting).' },
    @{ Prop='ExternalUserExpireInDays';          Values=@(); Note='Days until guest site access expires (only if expiration required above).' },
    # CIS 7.2.x knobs the baseline applies - surfaced so they can be adjusted
    # individually instead of only via the C bulk-apply.
    @{ Prop='LegacyAuthProtocolsEnabled';        Values=@('False','True'); Note='CIS 7.2.1: legacy auth off (False) = modern authentication required.' },
    @{ Prop='EnableAzureADB2BIntegration';       Values=@('True','False'); Note='CIS 7.2.2: Entra B2B integration for guest management.' },
    @{ Prop='EmailAttestationRequired';          Values=@('True','False'); Note='CIS 7.2.10: guests reauthenticate with a verification code.' },
    @{ Prop='EmailAttestationReAuthDays';        Values=@(); Note='CIS 7.2.10: days between guest verification-code reauthentication.' },
    # Org-wide sharing claims + EEEU (Everyone Except External Users) grants in the People
    # Picker - hiding/disabling these stops users from re-creating the org-wide/EEEU grants
    # this tool's scan engine finds and revokes (see 35-scan-engine.ps1).
    @{ Prop='ShowEveryoneClaim';                              Values=@('True','False'); Note='Show "Everyone" in People Picker (False = hidden, recommended).' },
    @{ Prop='ShowAllUsersClaim';                              Values=@('True','False'); Note='Show "All Users (x)" org-wide claims in People Picker.' },
    @{ Prop='ShowEveryoneExceptExternalUsersClaim';           Values=@('True','False'); Note='Show "Everyone except external users" (EEEU) in People Picker.' },
    @{ Prop='AllowEveryoneExceptExternalUsersClaimInPrivateSite'; Values=@('True','False'); Note='Allow EEEU claim in private sites specifically.' }
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
        SharingDomainRestrictionMode      = [string]$t.SharingDomainRestrictionMode
        FileAnonymousLinkType             = [string]$t.FileAnonymousLinkType
        FolderAnonymousLinkType           = [string]$t.FolderAnonymousLinkType
        PreventExternalUsersFromResharing = [string]$t.PreventExternalUsersFromResharing
        ExternalUserExpirationRequired    = [string]$t.ExternalUserExpirationRequired
        ExternalUserExpireInDays          = [string]$t.ExternalUserExpireInDays
        LegacyAuthProtocolsEnabled        = [string]$t.LegacyAuthProtocolsEnabled
        EnableAzureADB2BIntegration       = [string]$t.EnableAzureADB2BIntegration
        EmailAttestationRequired          = [string]$t.EmailAttestationRequired
        EmailAttestationReAuthDays        = [string]$t.EmailAttestationReAuthDays
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
    $s = $script:TenantSettings[$Setting - 1]
    if (-not $s) { return }
    $current = $script:Tabs[2].Posture[$s.Prop]
    # Fixed-value settings get a navigable picker so the operator selects a
    # valid value instead of typing a raw string; only the numeric expiry
    # setting (empty Values) falls back to free-text input.
    if ($s.Values.Count -gt 0) {
        # Capability enums are cryptic; label them with the SPO admin UI wording.
        if ($s.Prop -match 'SharingCapability$') {
            $options = @($s.Values | ForEach-Object { '{0} ({1})' -f $_, $script:SharingCapabilityLabels[$_] })
            $default = if ($script:SharingCapabilityLabels.ContainsKey($current)) { '{0} ({1})' -f $current, $script:SharingCapabilityLabels[$current] } else { $current }
            $picked = Show-ListModal -Title $s.Prop -Prompt 'Select a value:' -Options $options -Default $default
            $new = if ($picked) { ($picked -replace ' \(.*$', '') } else { $null }
        } else {
            $new = Show-ListModal -Title $s.Prop -Prompt 'Select a value:' -Options $s.Values -Default $current
        }
    } else {
        $new = Show-InputModal -Title $s.Prop -Prompt 'Number of days (0 = disabled / no requirement)' -Default $current
    }
    if (-not $new -or $new -eq $current) { return }
    $ok = Show-TypedConfirmModal -Title 'Change tenant setting' -Word 'APPLY' -Lines @(
        ("{0}: {1} {2} {3}" -f $s.Prop, $current, [string]$script:G.Arrow, $new), '',
        'This changes sharing behavior for the WHOLE tenant.')
    if (-not $ok) { return }
    try {
        # Enum params coerce from strings, but Nullable[bool] params (e.g.
        # ShowEveryoneExceptExternalUsersClaim) do not - cast those first.
        $val = if ($new -eq 'True') { [bool]$true } elseif ($new -eq 'False') { [bool]$false } else { $new }
        $setArgs = @{ $s.Prop = $val }
        Set-PnPTenant @setArgs -ErrorAction Stop
        Write-SsmLog -Message ("Tenant setting changed: {0} = {1}" -f $s.Prop, $new) -Level OK
        [void](Get-TenantPosture)
    } catch {
        Write-SsmLog -Message ("Tenant setting failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @($_.Exception.Message) -Kind Error
    }
}

# CIS Microsoft 365 Foundations Benchmark, section 7.2 (SharePoint/OneDrive).
# Values are the benchmark's recommended states; L2 entries are only applied
# when the operator picks the L1+L2 profile. 7.2.6 (domain allowlist) and
# 7.2.8 (sharing by security group) are intentionally NOT in the baseline:
# both need org-specific lists this tool cannot know.
$script:CisBaselineL1 = [ordered]@{
    LegacyAuthProtocolsEnabled    = $true   # 7.2.1: negate below (see Invoke-CisBaseline)
    EnableAzureADB2BIntegration   = $true   # 7.2.2
    SharingCapability             = 'ExternalUserSharingOnly'  # 7.2.3
    DefaultSharingLinkType        = 'Direct'                   # 7.2.7
    ExternalUserExpirationRequired= $true                      # 7.2.9
    ExternalUserExpireInDays      = 30                         # 7.2.9
    EmailAttestationRequired      = $true                      # 7.2.10
    EmailAttestationReAuthDays    = 15                         # 7.2.10
    DefaultLinkPermission         = 'View'                     # 7.2.11
}
$script:CisBaselineL2 = [ordered]@{
    OneDriveSharingCapability        = 'Disabled'  # 7.2.4
    PreventExternalUsersFromResharing= $true       # 7.2.5
}

function Test-CisAlignment {
    # Returns $true when a posture value meets the CIS 7.2.x recommended state,
    # $false when it does not, $null when CIS has no recommendation for it.
    # Capability checks use "recommended or less permissive" per the benchmark.
    param([string]$Prop, [string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    $capRank = @{ Disabled = 0; ExistingExternalUserSharingOnly = 1; ExternalUserSharingOnly = 2; ExternalUserAndGuestSharing = 3 }
    switch ($Prop) {
        'LegacyAuthProtocolsEnabled'      { return ($Value -eq 'False') }                                  # 7.2.1
        'EnableAzureADB2BIntegration'     { return ($Value -eq 'True') }                                   # 7.2.2
        'SharingCapability'               { return ($capRank[$Value] -le $capRank['ExternalUserSharingOnly']) }  # 7.2.3
        'OneDriveSharingCapability'       { return ($Value -eq 'Disabled') }                               # 7.2.4 (L2)
        'PreventExternalUsersFromResharing' { return ($Value -eq 'True') }                                 # 7.2.5 (L2)
        'SharingDomainRestrictionMode'    { return ($Value -eq 'AllowList') }                              # 7.2.6 (L2, list not checkable)
        'DefaultSharingLinkType'          { return ($Value -eq 'Direct' -or $Value -eq 'Internal') }       # 7.2.7
        'ExternalUserExpirationRequired'  { return ($Value -eq 'True') }                                   # 7.2.9
        'ExternalUserExpireInDays'        { $n = 0; return ([int]::TryParse($Value, [ref]$n) -and $n -le 30 -and $n -gt 0) }  # 7.2.9
        'EmailAttestationRequired'        { return ($Value -eq 'True') }                                   # 7.2.10
        'EmailAttestationReAuthDays'      { $n = 0; return ([int]::TryParse($Value, [ref]$n) -and $n -le 15 -and $n -gt 0) }  # 7.2.10
        'DefaultLinkPermission'           { return ($Value -eq 'View') }                                   # 7.2.11
    }
    return $null
}

function Save-CisSnapshot {
    # Record the tenant's current values for every CIS-touched property BEFORE
    # applying the baseline, so Invoke-CisRevert can restore them. One snapshot
    # per apply, kept per-tenant in the existing cache dir.
    param([string[]]$Props)
    if (-not (Test-Path -LiteralPath $script:CacheDir)) { New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null }
    $p = $script:Tabs[2].Posture
    $snap = [ordered]@{ TakenAt = (Get-Date).ToString('o'); Tenant = $script:TenantName; Values = @{} }
    foreach ($k in $Props) { $snap.Values[$k] = if ($null -ne $p[$k]) { "$($p[$k])" } else { $null } }
    $file = Join-Path $script:CacheDir ('cis-snapshot-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $snap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8
    Write-SsmLog -Message ("CIS snapshot saved: {0}" -f $file) -Level OK
    return $file
}

function Get-CisSnapshot {
    # Newest snapshot for the active tenant, or $null.
    if (-not (Test-Path -LiteralPath $script:CacheDir)) { return $null }
    $f = Get-ChildItem -LiteralPath $script:CacheDir -Filter 'cis-snapshot-*.json' | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $f) { return $null }
    try { return (Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json) } catch { return $null }
}

function Invoke-CisBaseline {
    if (-not $script:Tabs[2].Loaded) { Show-MsgModal -Title 'CIS baseline' -Lines @('Load the posture first (Enter).'); return }
    $profile = Show-ListModal -Title 'Apply CIS baseline' -Prompt 'Profile:' -Options @(
        'L1 only - recommended states that should not break workflows',
        'L1 + L2 - adds: OneDrive sharing Disabled, guest resharing blocked')
    if (-not $profile) { return }
    $includeL2 = $profile.StartsWith('L1 +')

    $lines = @('The following CIS 7.2.x recommended states will be applied:', '')
    foreach ($k in $script:CisBaselineL1.Keys) { $lines += ("  {0} = {1}" -f $k, $script:CisBaselineL1[$k]) }
    if ($includeL2) { foreach ($k in $script:CisBaselineL2.Keys) { $lines += ("  {0} = {1}" -f $k, $script:CisBaselineL2[$k]) } }
    $lines += @('',
        'A snapshot of the current values is saved first (undo with Z).', '',
        'NOTE: CIS 7.2.6 also recommends limiting external sharing by domain',
        '(SharingDomainRestrictionMode = AllowList). That list is org-specific',
        'and beyond this tool - set it in the SharePoint admin center.')
    $ok = Show-TypedConfirmModal -Title 'Apply CIS baseline' -Word 'CIS' -Lines $lines
    if (-not $ok) { return }

    $setArgs = @{}
    foreach ($k in $script:CisBaselineL1.Keys) { $setArgs[$k] = $script:CisBaselineL1[$k] }
    if ($includeL2) { foreach ($k in $script:CisBaselineL2.Keys) { $setArgs[$k] = $script:CisBaselineL2[$k] } }
    # 7.2.1: CIS wants modern auth REQUIRED; the tenant knob is inverse.
    $setArgs.Remove('LegacyAuthProtocolsEnabled'); $setArgs['LegacyAuthProtocolsEnabled'] = $false

    try {
        Save-CisSnapshot -Props ([string[]]$setArgs.Keys) | Out-Null
        Set-PnPTenant @setArgs -ErrorAction Stop
        Write-SsmLog -Message ("CIS baseline applied ({0})." -f ($includeL2 ? 'L1+L2' : 'L1')) -Level OK
        Show-MsgModal -Title 'CIS baseline' -Lines @('Baseline applied. Press Z on this tab to revert to the snapshot.')
        [void](Get-TenantPosture)
    } catch {
        Write-SsmLog -Message ("CIS baseline failed: {0}" -f $_.Exception.Message) -Level ERROR
        Show-MsgModal -Title 'Failed' -Lines @($_.Exception.Message) -Kind Error
    }
}

function Invoke-CisRevert {
    $snap = Get-CisSnapshot
    if (-not $snap) { Show-MsgModal -Title 'Undo CIS baseline' -Lines @('No CIS snapshot found for this tenant.') -Kind Warn; return }
    $lines = @(("Snapshot taken {0}:" -f $snap.TakenAt), '')
    foreach ($kv in $snap.Values.PSObject.Properties) { $lines += ("  {0} = {1}" -f $kv.Name, $kv.Value) }
    $lines += @('', 'These values will be restored.')
    $ok = Show-TypedConfirmModal -Title 'Undo CIS baseline' -Word 'REVERT' -Lines $lines
    if (-not $ok) { return }
    try {
        $setArgs = @{}
        foreach ($kv in $snap.Values.PSObject.Properties) {
            $v = $kv.Value
            if ($null -eq $v -or $v -eq '') { continue }  # was unset; leave current
            $setArgs[$kv.Name] = if ($v -eq 'True') { [bool]$true } elseif ($v -eq 'False') { [bool]$false } elseif ($v -match '^\d+$') { [int]$v } else { $v }
        }
        Set-PnPTenant @setArgs -ErrorAction Stop
        Write-SsmLog -Message ("CIS baseline reverted to snapshot {0}." -f $snap.TakenAt) -Level OK
        [void](Get-TenantPosture)
    } catch {
        Write-SsmLog -Message ("CIS revert failed: {0}" -f $_.Exception.Message) -Level ERROR
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
