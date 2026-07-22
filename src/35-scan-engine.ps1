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
        $ln = if ($g.SiteUser) { $g.SiteUser.LoginName } else { $null }
        $em = if ($g.User) { $g.User.Email } else { $null }
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

# ============================================================================
#region Scan engine - live (PnP-bound, no unit tests)
# ============================================================================

function Get-RestUnique {
    # Read HasUniqueRoleAssignments for a securable via REST (bool).
    param([string]$Url)
    try { $r = Invoke-PnPSPRestMethod -Url $Url -Method Get; return [bool]$r.HasUniqueRoleAssignments }
    catch { return $false }
}

function Add-GrantsRest {
    # Read a roleassignments collection via REST and add bad direct grants to $Bag.
    param($RaUrl, $Site, $Location, $Name, $Path, $ListId, $ItemId, [string[]]$Categories, $Bag)
    try { $resp = Invoke-PnPSPRestMethod -Url $RaUrl -Method Get } catch { return }
    foreach ($ra in @($resp.value)) {
        $key = Get-PrincipalCategory -Login $ra.Member.LoginName -Title $ra.Member.Title
        if (-not $key) { continue }
        if ($Categories -notcontains $key) { continue }
        # Keep only REAL grants. "Limited Access" (RoleType.Guest = 1) is system-managed
        # scaffolding that points to a real grant deeper down - never delete it directly;
        # removing the real leaf grant makes SharePoint clean the scaffolding automatically.
        $realRoles = @(@($ra.RoleDefinitionBindings) | Where-Object { [int]$_.RoleTypeKind -ne 1 })
        if ($realRoles.Count -eq 0) { continue }
        $roles = ($realRoles | ForEach-Object { $_.Name }) -join ';'
        $Bag.Add([pscustomobject]@{
            Site = $Site; Location = $Location; Name = $Name
            CategoryKey = $key; Category = $script:RuleCategories[$key]
            Access = $roles; Principal = $ra.Member.Title; Path = $Path; RemovalKind = 'DirectGrant'
            LinkId = $null; ListId = $ListId; ItemId = $ItemId; PrincipalId = $ra.PrincipalId
            RevokeStatus = 'NotAttempted'; Selected = $false
        })
    }
}

function Invoke-SiteScan {
    # Scan the currently-connected site/OneDrive; return an array of findings.
    param($Target, [string[]]$Categories, [scriptblock]$Progress)
    $bag = New-Object System.Collections.Generic.List[object]
    $site = $Target.Url
    $grantKeys = @('GuestGrant', 'EEEU', 'Everyone')
    $linkKeys = @('AnonymousLink', 'OrgLink', 'GuestLink')
    $scanGrants = ([bool]@($Categories | Where-Object { $grantKeys -contains $_ }).Count)
    $scanLinks = ([bool]@($Categories | Where-Object { $linkKeys -contains $_ }).Count)

    $web = Get-PnPWeb
    $base = $web.Url.TrimEnd('/')
    $raSelect = "`$expand=Member,RoleDefinitionBindings&`$select=PrincipalId,Member/LoginName,Member/Title,RoleDefinitionBindings/Name,RoleDefinitionBindings/RoleTypeKind"

    # Web-root direct grants
    if ($scanGrants -and (Get-RestUnique "$base/_api/web?`$select=HasUniqueRoleAssignments")) {
        Add-GrantsRest "$base/_api/web/roleassignments?$raSelect" $site 'Web' $web.Title $base $null $null $Categories $bag
    }

    if (-not ($scanGrants -or $scanLinks)) { return @($bag) }

    $libs = @(Get-PnPList | Where-Object { $_.BaseType -eq 'DocumentLibrary' -and -not $_.Hidden })
    foreach ($lib in $libs) {
        try { $rootUrl = (Get-PnPProperty -ClientObject $lib -Property RootFolder).ServerRelativeUrl }
        catch { Write-SsmErrorLog -Context ("Skipping library '{0}' - could not read its root folder" -f $lib.Title) -ErrorRecord $_; continue }
        if ($rootUrl.Split('/')[-1] -in $script:ExcludedUrlNames) { continue }
        $listId = $lib.Id.ToString()
        $total = 0; try { $total = [int](Get-PnPProperty -ClientObject $lib -Property ItemCount) } catch {}
        Write-SsmLog -Message ("Library '{0}' (~{1} items)" -f $lib.Title, $total)

        # Library-root direct grants
        if ($scanGrants -and (Get-RestUnique "$base/_api/web/lists(guid'$listId')?`$select=HasUniqueRoleAssignments")) {
            Add-GrantsRest "$base/_api/web/lists(guid'$listId')/roleassignments?$raSelect" $site 'Library' $lib.Title $rootUrl $listId $null $Categories $bag
        }

        # Enumerate items by indexed Id range, collecting only unique-permission items
        $unique = New-Object System.Collections.Generic.List[object]
        $lastId = 0
        $scanned = 0
        do {
            $u = "$base/_api/web/lists(guid'$listId')/items?`$select=Id,FileRef,FileLeafRef,FSObjType,HasUniqueRoleAssignments&`$filter=Id%20gt%20$lastId&`$orderby=Id&`$top=5000"
            try { $resp = Invoke-PnPSPRestMethod -Url $u -Method Get }
            catch { Write-SsmLog -Message ("Enumeration error in '{0}': {1}" -f $lib.Title, $_.Exception.Message) -Level ERROR; break }
            $rows = @($resp.value)
            foreach ($r in $rows) {
                $scanned++
                if ($r.HasUniqueRoleAssignments) { $unique.Add($r) }
                if ($r.Id -gt $lastId) { $lastId = $r.Id }
            }
            if ($Progress) { & $Progress -Count $scanned -Label ("Enumerating '{0}': {1} / ~{2} scanned" -f $lib.Title, $scanned, $total) }
        } while ($rows.Count -eq 5000)
        Write-SsmLog -Message ("{0} scanned, {1} with unique permissions in '{2}'" -f $scanned, $unique.Count, $lib.Title)

        # Check each unique-permission item: sharing links + direct grants
        $idx = 0
        foreach ($it in $unique) {
            $idx++
            if ($Progress -and ($idx % 25 -eq 0 -or $idx -eq $unique.Count)) {
                & $Progress -Count $idx -Label ("Checking shared items in '{0}': {1} / {2}" -f $lib.Title, $idx, $unique.Count)
            }
            # Fault-isolate each item: one item with an unexpected shape must not
            # abort the whole scan. Log it in full (for diagnosis) and carry on.
            try {
            $isFolder = ($it.FSObjType -eq 1)
            $loc = if ($isFolder) { 'Folder' } else { 'File' }
            $fileRef = $it.FileRef
            $name = $it.FileLeafRef

            # 1) Sharing links (Graph)
            if ($scanLinks) {
                try {
                    $links = if ($isFolder) { Get-PnPFolderSharingLink -Folder $fileRef -ErrorAction Stop }
                             else { Get-PnPFileSharingLink -Identity $fileRef -ErrorAction Stop }
                } catch { $links = @() }
                foreach ($l in @($links)) {
                    if (-not $l.Link) { continue }
                    $cat = Get-LinkCategory -Scope $l.Link.Scope -Link $l
                    if (-not $cat) { continue }
                    if ($Categories -notcontains $cat.Key) { continue }
                    $bag.Add([pscustomobject]@{
                        Site = $site; Location = $loc; Name = $name
                        CategoryKey = $cat.Key; Category = $script:RuleCategories[$cat.Key]
                        Access = $l.Link.Type; Principal = $cat.Principal; Path = $fileRef; RemovalKind = 'Link'
                        LinkId = $l.Id; ListId = $listId; ItemId = $it.Id; PrincipalId = $null
                        RevokeStatus = 'NotAttempted'; Selected = $false
                    })
                }
            }

            # 2) Direct grants on the item (EEEU / Everyone / guest granted directly, not via a link)
            if ($scanGrants) {
                Add-GrantsRest "$base/_api/web/lists(guid'$listId')/items($($it.Id))/roleassignments?$raSelect" $site $loc $name $fileRef $listId $it.Id $Categories $bag
            }
            } catch {
                Write-SsmErrorLog -Context ("Skipping item {0} in '{1}' - unexpected error while checking its sharing" -f $it.Id, $lib.Title) -ErrorRecord $_
            }
        }
    }
    return @($bag)
}

#endregion
