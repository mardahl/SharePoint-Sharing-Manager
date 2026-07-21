# ============================================================================
#region Scan engine - classification (pure)
# ============================================================================

function Get-PrincipalCategory {
    # Classify a role-assignment principal; return a rule-category key to
    # remove, or $null to KEEP (named internal member, default group, system).
    param([string]$Login, [string]$Title)
    if ([string]::IsNullOrWhiteSpace($Login) -and [string]::IsNullOrWhiteSpace($Title)) { return $null }
    if ($Title -like 'SharingLinks.*' -or $Login -like '*SharingLinks.*') { return $null }  # handled via link cmdlets
    if ($Login -like 'c:0-.f|rolemanager|spo-grid-all-users/*') { return 'EEEU' }
    if ($Login -eq 'c:0(.s|true') { return 'Everyone' }
    if ($Login -like '*#ext#*') { return 'GuestGrant' }
    return $null
}

function Get-GuestGrantees {
    # External grantees on a "users" (specific people) sharing link.
    param($Link)
    $out = @()
    foreach ($g in @($Link.GrantedToIdentitiesV2)) {
        if (-not $g) { continue }
        $ln = $g.SiteUser.LoginName
        $em = $g.User.Email
        if     ($ln -and $ln -like '*#ext#*') { $out += ($em ? $em : $ln) }
        elseif ($em -and $em -match 'guest#') { $out += $em }
    }
    return $out
}

function Get-LinkCategory {
    # Map a sharing link to a rule-category key + display principal, or $null to keep.
    param([string]$Scope, $Link)
    switch ($Scope.ToLower()) {
        'anonymous'    { return @{ Key = 'AnonymousLink'; Principal = 'Anyone with the link' } }
        'organization' { return @{ Key = 'OrgLink'; Principal = 'People in your organization' } }
        'users'        {
            $g = @(Get-GuestGrantees -Link $Link)
            if ($g.Count -gt 0) { return @{ Key = 'GuestLink'; Principal = ($g -join ';') } }
            return $null
        }
    }
    return $null
}

#endregion
