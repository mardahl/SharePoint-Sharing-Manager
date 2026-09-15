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
    param([string[]]$Items, [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Size)
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
        # Only SPSPERS* sites reach here, so the URL always contains /personal/.
        $slug = ([string]$s.Url).TrimEnd('/') -split '/personal/' | Select-Object -Last 1
        if ($slug) { [void]$set.Add($slug.ToLowerInvariant()) }
    }
    Write-SsmLog -Message ("Pre-provision: {0} personal sites enumerated." -f $set.Count)
    return ,$set   # unary comma: HashSet is IEnumerable, bare return would flatten it into the pipeline
}

function Get-SsmLicensedUsers {
    # Page through enabled member users, filter client-side to those with an
    # Enabled SharePoint plan. One request per 999 users; no per-user calls.
    # Throws on Graph failure - the view maps 403 to a permissions message.
    param([scriptblock]$Progress)
    $url = "users?`$filter=accountEnabled eq true and userType eq 'Member'&`$select=id,userPrincipalName,displayName,assignedPlans&`$top=999"
    $raw = [System.Collections.ArrayList]::new()
    do {
        $resp = Invoke-PnPGraphMethod -Method Get -Url $url -ErrorAction Stop
        $items = @()
        if ($resp.PSObject.Properties['value']) { $items = @($resp.value) }
        foreach ($i in $items) { [void]$raw.Add($i) }
        $url = if ($resp.PSObject.Properties['@odata.nextLink']) { [string]$resp.'@odata.nextLink' } else { $null }
        if ($Progress) { & $Progress $raw.Count }
    } while ($url)
    $licensed = @(Select-SsmSharePointLicensed -Users $raw.ToArray())
    Write-SsmLog -Message ("Pre-provision: {0} enabled members, {1} with SharePoint plan." -f $raw.Count, $licensed.Count)
    return $licensed
}

function Invoke-SsmPersonalSiteRequest {
    # Request-PnPPersonalSite accepts up to 200 UPNs per call and queues the
    # work server-side; SharePoint provisions asynchronously afterwards.
    # A failed batch marks every UPN in it Failed and the run continues.
    # ponytail: no retry/backoff; add if 429 throttling shows up in the log.
    param([string[]]$Upns, [scriptblock]$Progress)
    $rows = @()
    $batches = @(Split-SsmBatch -Items $Upns -Size 200)
    $n = 0
    foreach ($b in $batches) {
        $n++
        $status = 'Requested'; $err = ''
        try {
            Request-PnPPersonalSite -UserEmails @($b) -ErrorAction Stop
            Write-SsmLog -Message ("Pre-provision: batch {0}/{1} requested ({2} users)." -f $n, $batches.Count, @($b).Count) -Level OK
        } catch {
            $status = 'Failed'; $err = $_.Exception.Message
            Write-SsmErrorLog -Context ("Pre-provision: batch {0}/{1} failed" -f $n, $batches.Count) -ErrorRecord $_
        }
        foreach ($u in @($b)) { $rows += [pscustomobject]@{ Upn=$u; Batch=$n; Status=$status; Error=$err } }
        if ($Progress) { & $Progress $n $batches.Count }
    }
    return $rows
}

function Test-SsmPlaceholderTarget {
    # Rows that represent a user without a personal site yet (or one just
    # requested). They have no reachable URL: never scan, connect, or cache them.
    param([Parameter(Mandatory)]$Target)
    return ([string]$Target.Status -in @('Unprovisioned', 'ProvisionRequested'))
}

function New-SsmPlaceholderTarget {
    # A list row for a licensed user with no personal site yet. The URL is
    # the address SharePoint will normally assign; it is a display/dedup
    # value only - nothing connects to it until provisioning completes.
    param([Parameter(Mandatory)]$User)
    $prefix = ([string]$script:Auth.AdminUrl) -replace '^https://', '' -replace '-admin\.sharepoint\.com/?$', ''
    $url = 'https://{0}-my.sharepoint.com/personal/{1}' -f $prefix, (ConvertTo-SsmPersonalSlug -Upn $User.Upn)
    $title = if ($User.DisplayName) { [string]$User.DisplayName } else { [string]$User.Upn }
    $t = New-Target -Url $url -Title $title -Template 'SPSPERS#10'
    $t['Upn'] = [string]$User.Upn
    $t['Status'] = 'Unprovisioned'
    return $t
}

function Get-SsmProvisionFailureHint {
    # Request-PnPPersonalSite talks to the User Profile Service, which needs
    # the SharePoint permission User.ReadWrite.All on top of
    # Sites.FullControl.All. App-only registrations created before v1.10.0
    # lack it and fail with a localized "access denied ... profile" message.
    return @(
        'Most common cause: the app registration lacks the SharePoint',
        'APPLICATION permission User.ReadWrite.All (needed by the User',
        'Profile Service). New app-only registrations from v1.10.0 include it.',
        'To fix an existing app: Entra portal > App registrations >',
        'SharePoint-Sharing-Manager > API permissions > Add a permission >',
        'SharePoint > Application permissions > User.ReadWrite.All >',
        'Grant admin consent. Delegated sign-in already has this scope.')
}

#endregion
