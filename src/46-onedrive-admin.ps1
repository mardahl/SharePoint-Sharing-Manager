# ============================================================================
#region OneDrive secondary admin
# ============================================================================
# ponytail: RELEASE-BLOCKED. This region implements directory validation and
# read-only preflight for secondary-admin management against Task 1's
# documented-only API findings (see
# docs/superpowers/specs/2026-09-07-onedrive-admin-api-validation.md). No live
# tenant, sign-in, or credential discovery has proven owner-resolution or
# mutation-permission behavior. Do not enable, ship, or invoke this region
# against a real tenant until that deferred live validation passes.

function Get-SsmFieldValue {
    # StrictMode-safe field read that works for both a hashtable (used by
    # every test stub in this file) and a PSCustomObject (the real shape
    # Invoke-PnPGraphMethod/PnP cmdlets return). Hashtable.PSObject.Properties
    # reflects .NET Hashtable members (Keys/Values/Count/...), not its
    # entries, so a dictionary-aware branch is required here.
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    if ($InputObject.PSObject.Properties.Match($Name).Count -gt 0) {
        return $InputObject.PSObject.Properties[$Name].Value
    }
    return $null
}

function ConvertTo-SsmGuidOrNull {
    # Best-effort GUID coercion; returns $null instead of throwing on a
    # malformed or missing value, so callers can fail closed deliberately.
    param($Value)
    if (-not $Value) { return $null }
    try { return [guid]$Value } catch { return $null }
}

function Get-SsmConnectionTenantId {
    # Establish tenant identity from the connection's own Graph access token
    # rather than trusting a caller-supplied tenant name or a UPN domain
    # suffix (a tenant can have multiple verified domains). Decodes the JWT
    # payload locally/in-process only; the token itself is never logged or
    # returned.
    param([Parameter(Mandatory)]$Connection)
    $token = Get-PnPAccessToken -Connection $Connection -ErrorAction Stop
    if (-not $token) { throw 'Get-SsmConnectionTenantId: no access token available.' }
    $parts = ([string]$token).Split('.')
    if ($parts.Count -lt 2) { throw 'Get-SsmConnectionTenantId: malformed access token.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { throw 'Get-SsmConnectionTenantId: malformed access token payload.' }
    }
    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
    $claims = $json | ConvertFrom-Json
    $tid = Get-SsmFieldValue -InputObject $claims -Name 'tid'
    $guidTid = ConvertTo-SsmGuidOrNull -Value $tid
    if (-not $guidTid -or $guidTid -eq [guid]::Empty) {
        throw 'Get-SsmConnectionTenantId: token does not carry a usable tenant id.'
    }
    return $guidTid
}

function Test-SsmUpnSyntax {
    # UPN syntax checks only; does not assume every UPN is an email address,
    # but rejects the shapes the design explicitly calls out.
    param([string]$Upn)
    if (-not $Upn) { return $false }
    if ($Upn -match '[\x00-\x1f\x7f-\x9f]') { return $false }
    if ($Upn -match '\s') { return $false }
    if ($Upn -match '[,;]') { return $false }
    if ($Upn -match '[*?]') { return $false }
    if ($Upn -match '\|') { return $false }
    if ($Upn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return $false }
    return $true
}

function Resolve-SsmDirectoryUser {
    # Read-only exact directory lookup. Throws a terminating error on any
    # validation failure; never uses EnsureUser, invitations, or account
    # creation (design spec: mandatory UPN validation section).
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)]$Connection
    )
    if ($TenantId -eq [guid]::Empty) {
        throw 'Resolve-SsmDirectoryUser: TenantId must be a nonzero GUID.'
    }

    # Control-character check runs against the input after only literal
    # leading/trailing ASCII space/tab/CR/LF is stripped - the spec's
    # "surrounding whitespace" - never against .NET's Trim(), which silently
    # absorbs several Unicode whitespace-classified C1 control characters
    # (e.g. U+0085 NEL, U+00A0 NBSP) that must be rejected, not treated as
    # trimmable whitespace. The directory lookup itself is the sole
    # authority on the resulting UPN's shape.
    $trimmed = $Upn.Trim(" `t`r`n")
    if ($trimmed -match '[\x00-\x1f\x7f-\x9f]') {
        throw "Resolve-SsmDirectoryUser: '$Upn' contains control characters."
    }
    if (-not (Test-SsmUpnSyntax -Upn $trimmed)) {
        throw "Resolve-SsmDirectoryUser: '$Upn' is not an acceptable single UPN."
    }

    $connTenantId = Get-SsmConnectionTenantId -Connection $Connection
    if ($connTenantId -ne $TenantId) {
        throw "Resolve-SsmDirectoryUser: connection tenant '$connTenantId' does not match expected tenant '$TenantId'."
    }

    # Exact key lookup only. The literal apostrophe-escape + percent-encode
    # sequence is required per Graph's OData key syntax (a leading '$' or an
    # embedded '#' must never be interpolated raw into the URL).
    $escaped = $trimmed.Replace("'", "''")
    $key = [Uri]::EscapeDataString($escaped)
    $url = "users('$key')?`$select=id,userPrincipalName,displayName"

    try {
        $user = Invoke-PnPGraphMethod -Method Get -Url $url -Connection $Connection -ErrorAction Stop
    } catch {
        throw "Resolve-SsmDirectoryUser: directory lookup failed for '$trimmed': $($_.Exception.Message)"
    }
    if (-not $user) { throw "Resolve-SsmDirectoryUser: no directory result for '$trimmed'." }

    # A single exact-key lookup should return one object; guard against an
    # unexpected ambiguous collection shape anyway rather than assume it.
    if ($user -isnot [string] -and $user -isnot [System.Collections.IDictionary] -and
        ($user -is [System.Collections.IEnumerable])) {
        $all = @($user)
        if ($all.Count -ne 1) { throw "Resolve-SsmDirectoryUser: ambiguous directory result for '$trimmed'." }
        $user = $all[0]
    }

    $rawId = Get-SsmFieldValue -InputObject $user -Name 'id'
    $rawUpn = Get-SsmFieldValue -InputObject $user -Name 'userPrincipalName'
    $rawDisplay = Get-SsmFieldValue -InputObject $user -Name 'displayName'

    if (-not $rawId) { throw "Resolve-SsmDirectoryUser: directory result missing id for '$trimmed'." }
    $objectId = ConvertTo-SsmGuidOrNull -Value $rawId
    if (-not $objectId -or $objectId -eq [guid]::Empty) {
        throw "Resolve-SsmDirectoryUser: directory id is not a usable GUID for '$trimmed'."
    }
    if (-not $rawUpn) { throw "Resolve-SsmDirectoryUser: directory result missing userPrincipalName for '$trimmed'." }
    if (-not [string]::Equals([string]$rawUpn, $trimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolve-SsmDirectoryUser: entered UPN '$trimmed' does not match canonical UPN '$rawUpn'."
    }

    return @{
        Id = $objectId
        Upn = [string]$rawUpn
        DisplayName = [string]$rawDisplay
        TenantId = $TenantId
    }
}

function Get-SsmOneDriveAdminState {
    # Read-only live preflight snapshot. Any exception means "no trustworthy
    # state" - callers must treat that target as failed/blocked, never as an
    # implicit no-op (design spec: owner protection section - never infer
    # ownership from a URL slug, display name, email equality, or the first
    # administrator returned).
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][hashtable]$Identity,
        [Parameter(Mandatory)]$Connection
    )
    $norm = $Url.TrimEnd('/')

    $connTenantId = Get-SsmConnectionTenantId -Connection $Connection
    if ($connTenantId -eq [guid]::Empty) {
        throw 'Get-SsmOneDriveAdminState: connection tenant id is a zero GUID.'
    }

    # Site connection must be bound to the exact verified target URL, never a
    # cached/imported one, before any read below is trusted.
    $connUrl = Get-SsmFieldValue -InputObject $Connection -Name 'Url'
    if ($connUrl -and ([string]$connUrl).TrimEnd('/') -ne $norm) {
        throw "Get-SsmOneDriveAdminState: connection is bound to '$connUrl', not the target '$norm'."
    }

    # Tenant admin connection is captured explicitly for the tenant site
    # record only; the original site connection/object is used for every
    # other read below, so it is never replaced by the admin connection.
    # Connect-SsmAdmin/Connect-SsmSite return a boolean success flag, not a
    # PnPConnection - the explicit connection object must be pulled from
    # Get-PnPConnection immediately after, matching the pattern already used
    # at src/65-views.ps1:805-810.
    if (-not (Connect-SsmAdmin)) { throw 'Get-SsmOneDriveAdminState: no tenant admin connection available.' }
    $adminConn = Get-PnPConnection

    try {
        $tenantSite = Get-PnPTenantSite -Identity $norm -Detailed -Connection $adminConn -ErrorAction Stop
    } catch {
        throw "Get-SsmOneDriveAdminState: tenant site record read failed for '$norm': $($_.Exception.Message)"
    }
    if (-not $tenantSite) { throw "Get-SsmOneDriveAdminState: no tenant site record for '$norm'." }

    $isPersonal = ([string](Get-SsmFieldValue -InputObject $tenantSite -Name 'Template')) -like 'SPSPERS*'
    $unlocked = ([string](Get-SsmFieldValue -InputObject $tenantSite -Name 'LockState')) -eq 'Unlock'
    $primaryAdminUpn = Get-SsmFieldValue -InputObject $tenantSite -Name 'Owner'
    if ($primaryAdminUpn) { $primaryAdminUpn = [string]$primaryAdminUpn }

    # Site collection GUID and web GUID from the verified site connection -
    # never the admin connection, never a URL slug. Both are required to
    # build Graph's documented composite site id
    # ({hostname},{spSiteId},{spWebId} - see the site-get reference); a bare
    # CSOM Site.Id is not a valid /sites/{id} shape on its own.
    try {
        $site = Get-PnPSite -Includes Id -Connection $Connection -ErrorAction Stop
    } catch {
        throw "Get-SsmOneDriveAdminState: site read failed for '$norm': $($_.Exception.Message)"
    }
    $siteId = ConvertTo-SsmGuidOrNull -Value (Get-SsmFieldValue -InputObject $site -Name 'Id')
    if (-not $siteId -or $siteId -eq [guid]::Empty) {
        throw "Get-SsmOneDriveAdminState: could not resolve a site collection id for '$norm'."
    }
    try {
        $web = Get-PnPWeb -Includes Id -Connection $Connection -ErrorAction Stop
    } catch {
        throw "Get-SsmOneDriveAdminState: web read failed for '$norm': $($_.Exception.Message)"
    }
    $webId = ConvertTo-SsmGuidOrNull -Value (Get-SsmFieldValue -InputObject $web -Name 'Id')
    if (-not $webId -or $webId -eq [guid]::Empty) {
        throw "Get-SsmOneDriveAdminState: could not resolve a web id for '$norm'."
    }
    $hostName = ([Uri]$norm).Host
    if (-not $hostName) {
        throw "Get-SsmOneDriveAdminState: could not resolve a hostname for '$norm'."
    }
    $graphSiteId = "$hostName,$siteId,$webId"

    # Owner: site-bound List Drives (documented application-permission path;
    # Get drive documents "Not supported" for app-only), fully paginated,
    # bound to the resolved site AND web GUIDs via sharepointIds, requiring
    # exactly one matching business drive. The tenant Owner field above is
    # never used as ownership proof by itself.
    $drives = [System.Collections.ArrayList]::new()
    $next = "sites/$graphSiteId/drives?`$select=id,owner,sharepointIds,driveType"
    $guard = 0
    while ($next -and $guard -lt 50) {
        $guard++
        try {
            $page = Invoke-PnPGraphMethod -Method Get -Url $next -Connection $Connection -ErrorAction Stop
        } catch {
            throw "Get-SsmOneDriveAdminState: drive read failed for '$norm': $($_.Exception.Message)"
        }
        if (-not $page) { break }
        $items = Get-SsmFieldValue -InputObject $page -Name 'value'
        if ($items) { foreach ($it in @($items)) { [void]$drives.Add($it) } }
        $next = Get-SsmFieldValue -InputObject $page -Name '@odata.nextLink'
    }
    if ($guard -ge 50) { throw "Get-SsmOneDriveAdminState: drive listing did not terminate for '$norm'." }

    $bound = @()
    foreach ($d in $drives) {
        if ([string](Get-SsmFieldValue -InputObject $d -Name 'driveType') -ne 'business') { continue }
        $spIds = Get-SsmFieldValue -InputObject $d -Name 'sharepointIds'
        if (-not $spIds) { continue }
        $spSiteId = ConvertTo-SsmGuidOrNull -Value (Get-SsmFieldValue -InputObject $spIds -Name 'siteId')
        $spWebId = ConvertTo-SsmGuidOrNull -Value (Get-SsmFieldValue -InputObject $spIds -Name 'webId')
        if (-not $spSiteId -or $spSiteId -ne $siteId) { continue }
        if (-not $spWebId -or $spWebId -ne $webId) { continue }
        $bound += $d
    }
    if (@($bound).Count -ne 1) {
        throw "Get-SsmOneDriveAdminState: expected exactly one business drive bound to site '$siteId'/web '$webId' for '$norm', found $(@($bound).Count)."
    }
    $drive = $bound[0]

    $ownerId = $null
    $ownerUpn = $null
    $ownerObj = Get-SsmFieldValue -InputObject $drive -Name 'owner'
    if ($ownerObj) {
        $ownerUser = Get-SsmFieldValue -InputObject $ownerObj -Name 'user'
        if ($ownerUser) {
            $ownerId = ConvertTo-SsmGuidOrNull -Value (Get-SsmFieldValue -InputObject $ownerUser -Name 'id')
            $rawOwnerUpn = Get-SsmFieldValue -InputObject $ownerUser -Name 'userPrincipalName'
            if ($rawOwnerUpn) { $ownerUpn = [string]$rawOwnerUpn }
        }
    }

    # Membership: read live, then bind the validated account's directory
    # object ID to an actual SharePoint principal via AadObjectId - never
    # pass the full list to a removal cmdlet, never match on display name or
    # email alone. AadObjectId/UserPrincipalName are not in this cmdlet's
    # CSOM default retrieval set (reflected against installed
    # PnP.PowerShell 3.3.0 / pnp/powershell source) and must be requested
    # explicitly, including the nested AadObjectId.NameId/.NameIdIssuer
    # scalar paths - the parent AadObjectId include alone does not load them.
    try {
        $admins = @(Get-PnPSiteCollectionAdmin -Connection $Connection `
            -Includes AadObjectId.NameId, AadObjectId.NameIdIssuer, UserPrincipalName -ErrorAction Stop)
    } catch {
        throw "Get-SsmOneDriveAdminState: administrator membership read failed for '$norm': $($_.Exception.Message)"
    }

    $identityUpn = [string](Get-SsmFieldValue -InputObject $Identity -Name 'Upn')
    $adminPresent = $false
    $adminUserId = $null
    $adminLogin = ''
    $primaryAdminId = $null
    foreach ($a in $admins) {
        $aadObj = Get-SsmFieldValue -InputObject $a -Name 'AadObjectId'
        $aId = $null
        if ($aadObj) {
            $nameId = Get-SsmFieldValue -InputObject $aadObj -Name 'NameId'
            $aId = ConvertTo-SsmGuidOrNull -Value $nameId
        }
        $aLogin = [string](Get-SsmFieldValue -InputObject $a -Name 'LoginName')
        $aUpn = [string](Get-SsmFieldValue -InputObject $a -Name 'UserPrincipalName')
        $aEmail = Get-SsmFieldValue -InputObject $a -Name 'Email'

        if ($aId -and $Identity.Id -and $aId -eq $Identity.Id) {
            # Exact directory-object-id match - the only case that proves
            # this SharePoint principal is the validated account.
            $adminPresent = $true
            $adminUserId = $aId
            $adminLogin = $aLogin
        } elseif ($adminPresent -ne $true -and $identityUpn -and (
                ([string]::Equals($aUpn, $identityUpn, [System.StringComparison]::OrdinalIgnoreCase)) -or
                ($aLogin -and $aLogin -match ('\|' + [regex]::Escape($identityUpn) + '$'))
            )) {
            # A login/UPN name-only match with a missing or different
            # AadObjectId is a stale/recreated-account collision, not proof
            # of absence - membership is unknown, never false, so this
            # cannot mask an actual removal/no-op decision.
            $adminPresent = $null
        }
        if ($primaryAdminUpn -and -not $primaryAdminId) {
            if (([string]::Equals($aUpn, $primaryAdminUpn, [System.StringComparison]::OrdinalIgnoreCase)) -or
                ([string]::Equals([string]$aEmail, $primaryAdminUpn, [System.StringComparison]::OrdinalIgnoreCase))) {
                $primaryAdminId = $aId
            }
        }
    }

    return @{
        TenantId = $connTenantId
        Url = $norm
        SiteId = $siteId
        IsPersonalSite = $isPersonal
        Unlocked = $unlocked
        OwnerId = $ownerId
        OwnerUpn = $ownerUpn
        PrimaryAdminId = $primaryAdminId
        PrimaryAdminUpn = $primaryAdminUpn
        AdminPresent = $adminPresent
        AdminUserId = $adminUserId
        AdminLogin = $adminLogin
    }
}

function Get-SsmOneDriveAdminDecision {
    # Pure classification, no network calls. Guard order: tenant/personal-
    # site/unlocked -> owner completeness -> protected identity comparison
    # identity comparison (Remove only) -> known membership -> no-op ->
    # eligible. Both protected identities are required before either kind of
    # write so post-write verification can prove they stayed unchanged.
    param(
        [Parameter(Mandatory)][ValidateSet('Add', 'Remove')][string]$Action,
        [Parameter(Mandatory)][hashtable]$Identity,
        [Parameter(Mandatory)][hashtable]$Snapshot
    )

    if (-not $Snapshot.TenantId -or $Snapshot.TenantId -eq [guid]::Empty) { return 'Blocked' }
    if (-not $Identity.TenantId -or $Identity.TenantId -ne $Snapshot.TenantId) { return 'Blocked' }
    if (-not $Snapshot.IsPersonalSite) { return 'Blocked' }
    if (-not $Snapshot.Unlocked) { return 'Blocked' }

    $ownerKnown = ($Snapshot.OwnerId -and $Snapshot.OwnerId -ne [guid]::Empty)
    $primaryKnown = ($Snapshot.PrimaryAdminId -and $Snapshot.PrimaryAdminId -ne [guid]::Empty)
    if (-not $ownerKnown -or -not $primaryKnown) { return 'Blocked' }

    if ($Action -eq 'Remove') {
        if ($Identity.Id -eq $Snapshot.OwnerId) { return 'OwnerProtected' }
        if ($Identity.Id -eq $Snapshot.PrimaryAdminId) { return 'PrimaryProtected' }
    }

    if ($null -eq $Snapshot.AdminPresent) { return 'Blocked' }
    if ($Snapshot.AdminPresent -and (
            -not $Snapshot.AdminUserId -or -not $Snapshot.AdminLogin -or
            $Snapshot.AdminUserId -ne $Identity.Id)) {
        # Membership says the account is present but AdminUserId does not
        # equal the validated directory object ID, or no login is bound -
        # nothing reliably binds it to an actual SharePoint principal for
        # the requested identity - fail closed rather than remove/no-op on
        # an unresolved match.
        return 'Blocked'
    }

    if ($Action -eq 'Add') {
        if ($Snapshot.AdminPresent) { return 'NoOp' }
        return 'Eligible'
    }
    if (-not $Snapshot.AdminPresent) { return 'NoOp' }
    return 'Eligible'
}

function New-SsmOneDriveAdminChangeResult {
    # Before/After carry the actual observed AdminPresent snapshot values
    # (never inferred from the requested action) so a caller can record real
    # evidence instead of guessing an outcome from Result alone. Error
    # duplicates Detail for spec-contract callers; Detail is retained
    # unchanged for existing caller compatibility.
    param([string]$Result, [bool]$StopBatch, [string]$Detail = '', $Before = $null, $After = $null)
    return @{ Result = $Result; StopBatch = $StopBatch; Detail = $Detail; Error = $Detail; Before = $Before; After = $After }
}

function Invoke-SsmOneDriveAdminChange {
    # Guarded single-target mutation. The caller must already have obtained
    # typed batch confirmation and written evidence; this function still
    # re-proves everything immediately before writing:
    #  1. Re-resolve the originally-requested identity fresh (not the preview
    #     copy). Any drift in tenant, object id, or canonical UPN means the
    #     requested account itself is no longer what the operator confirmed
    #     -> stop the whole batch, not just this target.
    #  2. Re-read live state fresh (never trust the preview snapshot for the
    #     write decision).
    #  3. Compare the fresh read to the preview snapshot: a changed site,
    #     URL, actual owner, or primary admin since preview means only this
    #     target is unsafe to touch; the batch may continue elsewhere.
    #  4. Re-run the pure decision against the fresh read, not the preview.
    #  5. Write only the single validated principal - never
    #     -PrimarySiteCollectionAdmin, a wildcard, or the full admin list.
    #  6. Always attempt a post-write read, even if the write threw
    #     (timeout/denial). Ground truth comes from this read, not from
    #     whether the write call itself threw:
    #       - read fails            -> Unverified (StopBatch $false)
    #       - a protected identity
    #         (owner/primary admin)
    #         changed after write   -> Failed, StopBatch $true (safety)
    #       - membership now matches
    #         the requested action  -> Success (even if the write threw -
    #         a slow-but-successful PnP call must not be reported Failed)
    #       - membership still does
    #         not match             -> Failed (never Success on a mismatch,
    #         with or without a transport exception)
    # No write-retry layer is added here; PnP's own retry behavior is relied
    # on for a single call.
    param(
        [Parameter(Mandatory)][ValidateSet('Add', 'Remove')][string]$Action,
        [Parameter(Mandatory)][hashtable]$Identity,
        [Parameter(Mandatory)][hashtable]$Snapshot,
        [Parameter(Mandatory)]$Connection
    )

    # Step 1: re-resolve the originally-requested identity right now.
    try {
        $revalidated = Resolve-SsmDirectoryUser -Upn $Identity.Upn -TenantId $Identity.TenantId -Connection $Connection
    } catch {
        return New-SsmOneDriveAdminChangeResult -Result 'Blocked' -StopBatch $true `
            -Detail "requested identity could not be revalidated: $($_.Exception.Message)"
    }
    if ($revalidated.TenantId -ne $Identity.TenantId -or
        -not $revalidated.Id -or $revalidated.Id -eq [guid]::Empty -or
        $revalidated.Id -ne $Identity.Id) {
        return New-SsmOneDriveAdminChangeResult -Result 'Blocked' -StopBatch $true `
            -Detail 'requested identity drifted (tenant/object id changed) since preview'
    }

    # Step 2: fresh live read - never trust the preview snapshot for the
    # write decision.
    try {
        $fresh = Get-SsmOneDriveAdminState -Url $Snapshot.Url -Identity $revalidated -Connection $Connection
    } catch {
        return New-SsmOneDriveAdminChangeResult -Result 'Blocked' -StopBatch $false `
            -Detail "pre-write state read failed: $($_.Exception.Message)"
    }

    # Step 3: target/owner drift since preview blocks only this target.
    if ($fresh.SiteId -ne $Snapshot.SiteId -or
        ([string]$fresh.Url).TrimEnd('/') -ne ([string]$Snapshot.Url).TrimEnd('/') -or
        $fresh.OwnerId -ne $Snapshot.OwnerId -or
        $fresh.PrimaryAdminId -ne $Snapshot.PrimaryAdminId) {
        return New-SsmOneDriveAdminChangeResult -Result 'Blocked' -StopBatch $false `
            -Detail 'target or protected identity changed since preview'
    }

    # Step 4: re-run the pure decision against the fresh read.
    $decision = Get-SsmOneDriveAdminDecision -Action $Action -Identity $revalidated -Snapshot $fresh
    if ($decision -eq 'NoOp') {
        return New-SsmOneDriveAdminChangeResult -Result 'NoOp' -StopBatch $false -Before $fresh.AdminPresent -After $fresh.AdminPresent
    }
    if ($decision -ne 'Eligible') {
        return New-SsmOneDriveAdminChangeResult -Result 'Blocked' -StopBatch $false -Detail "decision: $decision" -Before $fresh.AdminPresent
    }

    # Step 5: write the single validated principal only.
    $writeThrew = $false
    $writeError = $null
    try {
        if ($Action -eq 'Add') {
            Add-PnPSiteCollectionAdmin -Owners $Identity['Upn'] -Connection $Connection -ErrorAction Stop | Out-Null
        } else {
            Remove-PnPSiteCollectionAdmin -Owners $fresh['AdminLogin'] -Connection $Connection -ErrorAction Stop | Out-Null
        }
    } catch {
        $writeThrew = $true
        $writeError = $_.Exception.Message
    }

    # Step 6: post-write read is always attempted, write exception or not.
    try {
        $after = Get-SsmOneDriveAdminState -Url $Snapshot.Url -Identity $revalidated -Connection $Connection
    } catch {
        $suffix = if ($writeThrew) { " (write also raised: $writeError)" } else { '' }
        return New-SsmOneDriveAdminChangeResult -Result 'Unverified' -StopBatch $false `
            -Detail "post-write verification read failed$suffix" -Before $fresh.AdminPresent
    }

    if ($after.TenantId -ne $fresh.TenantId -or
        $after.SiteId -ne $fresh.SiteId -or
        ([string]$after.Url).TrimEnd('/') -ne ([string]$fresh.Url).TrimEnd('/') -or
        $after.OwnerId -ne $fresh.OwnerId -or
        $after.PrimaryAdminId -ne $fresh.PrimaryAdminId) {
        return New-SsmOneDriveAdminChangeResult -Result 'Failed' -StopBatch $true `
            -Detail 'a protected identity or target changed after the write' -Before $fresh.AdminPresent -After $after.AdminPresent
    }

    if ($null -eq $after.AdminPresent) {
        # Postwrite membership could not be resolved reliably - unknown is
        # never reported as Failed or Success, only Unverified.
        return New-SsmOneDriveAdminChangeResult -Result 'Unverified' -StopBatch $false `
            -Detail 'post-write membership could not be verified reliably' -Before $fresh.AdminPresent -After $null
    }

    $expectedPresent = ($Action -eq 'Add')
    if ($after.AdminPresent -eq $expectedPresent) {
        return New-SsmOneDriveAdminChangeResult -Result 'Success' -StopBatch $false -Before $fresh.AdminPresent -After $after.AdminPresent
    }
    $suffix = if ($writeThrew) { " (write raised: $writeError)" } else { '' }
    return New-SsmOneDriveAdminChangeResult -Result 'Failed' -StopBatch $false `
        -Detail "membership after write does not match the requested action$suffix" -Before $fresh.AdminPresent -After $after.AdminPresent
}

#endregion
