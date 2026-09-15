# ============================================================================
#region OneDrive pre-provisioning
# ============================================================================
# Finds OneDrive-licensed users without a provisioned personal site and
# requests provisioning in bulk. Pure helpers first (unit-tested), then the
# Graph/CSOM wrappers.

function ConvertTo-SsmPersonalSlug {
    # user@example.com -> user_example_com : the path segment SharePoint uses
    # under /personal/. Fallback match for sites whose Owner is empty.
    param([Parameter(Mandatory)][string]$Upn)
    return ($Upn -replace '[.@]', '_').ToLowerInvariant()
}

function Select-SsmSharePointLicensed {
    # Keep Graph users with an Enabled SharePoint service plan. Matching on
    # the assignedPlans.service name avoids maintaining a plan-GUID list.
    param([object[]]$Users)
    $out = @()
    foreach ($u in @($Users)) {
        $plans = @()
        if ($u.PSObject.Properties['assignedPlans'] -and $u.assignedPlans) { $plans = @($u.assignedPlans) }
        $hit = $plans | Where-Object { $_.service -eq 'SharePoint' -and $_.capabilityStatus -eq 'Enabled' } | Select-Object -First 1
        if (-not $hit) { continue }
        $out += [pscustomobject]@{
            Id          = [string]$u.id
            Upn         = [string]$u.userPrincipalName
            DisplayName = if ($u.PSObject.Properties['displayName']) { [string]$u.displayName } else { '' }
        }
    }
    return $out
}

function Get-SsmUnprovisionedUsers {
    # Licensed users absent from the owner set by both UPN and URL slug.
    param(
        [object[]]$Licensed,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$OwnerSet
    )
    $out = @()
    foreach ($u in @($Licensed)) {
        if ($OwnerSet.Contains($u.Upn)) { continue }
        if ($OwnerSet.Contains((ConvertTo-SsmPersonalSlug -Upn $u.Upn))) { continue }
        $out += $u
    }
    return $out
}

function Split-SsmBatch {
    param([string[]]$Items, [Parameter(Mandatory)][int]$Size)
    $out = @()
    $all = @($Items)
    for ($i = 0; $i -lt $all.Count; $i += $Size) {
        $end = [Math]::Min($i + $Size, $all.Count) - 1
        $out += ,@($all[$i..$end])
    }
    return $out
}

function Get-SsmProvisionedOwnerSet {
    # Every existing personal site, keyed by lowercased Owner UPN and by URL
    # slug (/personal/<slug>). Slug covers sites whose Owner is empty or
    # SID-shaped. Returns $null if the admin connection cannot be made.
    param([scriptblock]$Progress)
    if (-not (Connect-SsmAdmin)) { return $null }
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sites = Get-SsmTenantSiteProperties -IncludePersonal $true -Progress $Progress
    foreach ($s in $sites) {
        if ($s.Template -notlike 'SPSPERS*') { continue }
        $owner = [string]$s.Owner
        if ($owner) { [void]$set.Add($owner.ToLowerInvariant()) }
        $slug = ([string]$s.Url).TrimEnd('/') -split '/personal/' | Select-Object -Last 1
        if ($slug) { [void]$set.Add($slug.ToLowerInvariant()) }
    }
    Write-SsmLog -Message ("Pre-provision: {0} personal sites enumerated." -f $set.Count)
    return $set
}

#endregion
