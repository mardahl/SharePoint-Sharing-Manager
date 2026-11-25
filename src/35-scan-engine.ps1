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
            if ($g.Count -gt 0) { return @{ Key = 'GuestLink'; Principal = (($g -join ';') + ' [guest]') } }
            return $null
        }
    }
    return $null
}

#endregion

# ============================================================================
#region Scan engine - live (PnP-bound, no unit tests)
# ============================================================================

function Wait-SsmRetry {
    # The backoff pause between retries (a function so tests can skip the wait).
    param([int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

# Per-run request statistics: counts and durations per call KIND only (no URLs,
# site or library names). $null = not collecting; Start-SsmScanStats begins a run.
$script:ScanStats = $null

function Start-SsmScanStats {
    $script:ScanStats = @{ Clock = [System.Diagnostics.Stopwatch]::StartNew(); Kinds = @{} }
}

function Add-SsmScanStat {
    param([string]$Kind, [double]$Seconds, [bool]$Failed)
    if ($null -eq $script:ScanStats) { return }
    $k = $script:ScanStats.Kinds[$Kind]
    if (-not $k) { $k = @{ Count = 0; Failed = 0; Total = 0.0; Max = 0.0 }; $script:ScanStats.Kinds[$Kind] = $k }
    $k.Count++
    if ($Failed) { $k.Failed++ }
    $k.Total += $Seconds
    if ($Seconds -gt $k.Max) { $k.Max = $Seconds }
}

function Write-SsmScanStats {
    # One INFO line for the run: requests, wall time, requests/s, then per kind
    # the count, total seconds, average and max. Resets the collector.
    param([int]$Targets)
    $s = $script:ScanStats
    $script:ScanStats = $null
    if ($null -eq $s) { return }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $wall = $s.Clock.Elapsed.TotalSeconds
    $calls = 0; $failed = 0
    foreach ($k in $s.Kinds.Values) { $calls += $k.Count; $failed += $k.Failed }
    $rate = if ($wall -gt 0) { $calls / $wall } else { 0 }
    $parts = foreach ($name in ($s.Kinds.Keys | Sort-Object { -$s.Kinds[$_].Total })) {
        $k = $s.Kinds[$name]
        '{0} {1} {2} total {3}s avg {4}s max {5}s{6}' -f $name, $k.Count, $(if ($k.Count -eq 1) { 'call' } else { 'calls' }),
            $k.Total.ToString('0.0', $inv), ($k.Total / $k.Count).ToString('0.000', $inv), $k.Max.ToString('0.00', $inv),
            $(if ($k.Failed -gt 0) { ", $($k.Failed) failed" } else { '' })
    }
    Write-SsmLog -Message ('Scan stats: {0} {1}, {2} requests in {3} s ({4} req/s); {5}' -f $Targets, $(if ($Targets -eq 1) { 'target' } else { 'targets' }),
        $calls, $wall.ToString('0.0', $inv), $rate.ToString('0.0', $inv), ($parts -join '; ')) -Level INFO
}

function Invoke-SsmRetry {
    # Run a read; on failure try again (3 attempts in total, 2 s then 4 s
    # backoff) so a transient timeout or dropped connection does not lose
    # data, then rethrow. $Action runs in the caller's scope, so it sees the
    # caller's variables as they are at each attempt.
    # -Permanent: optional test ($ErrorRecord) for errors that retrying cannot fix.
    # -Kind: name of the call kind; every attempt is timed and counted under it
    # (see Start-SsmScanStats). Network reads of the scan engine all go through here.
    param([scriptblock]$Action, [object[]]$ArgumentList, [string]$What, [int]$MaxAttempts = 3, [scriptblock]$Permanent, [string]$Kind)
    for ($attempt = 1; ; $attempt++) {
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $result = (& $Action @ArgumentList)
            if ($Kind) { Add-SsmScanStat -Kind $Kind -Seconds $clock.Elapsed.TotalSeconds -Failed $false }
            if ($null -eq $result) { return }   # nothing, not a lone $null
            return $result
        }
        catch {
            if ($Kind) { Add-SsmScanStat -Kind $Kind -Seconds $clock.Elapsed.TotalSeconds -Failed $true }
            if ($attempt -ge $MaxAttempts -or ($Permanent -and (& $Permanent $_))) { throw }
            Write-SsmLog -Message ("{0} failed (attempt {1}/{2}), retrying: {3}" -f $What, $attempt, $MaxAttempts, $_.Exception.Message) -Level WARN
            Wait-SsmRetry -Seconds (2 * $attempt)
        }
    }
}

function Set-ScanIncomplete {
    # Record a part of the site that could not be checked, so the target is
    # reported Incomplete and never looks like a clean scan.
    param($Target, [string]$Part, $ErrorRecord)
    $Target['IncompleteParts'].Add($Part)
    Write-SsmErrorLog -Context ("Scan incomplete: {0}" -f $Part) -ErrorRecord $ErrorRecord
}

function Test-SsmItemGone {
    # $true when the error is an HTTP 404: the item was deleted or moved after
    # it was enumerated. That is the only sharing-link read failure treated as
    # benign. Get-PnPFileSharingLink / Get-PnPFolderSharingLink return an empty
    # set (no error) for an item without links, so any other failure is a real
    # failure to read. PnP Core service errors carry the status in
    # Error.HttpResponseCode (the exception message is generic); plain HTTP
    # exceptions carry StatusCode. Inner exceptions are searched as well.
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        $err = $ex.PSObject.Properties['Error']
        if ($err -and $err.Value -and $err.Value.PSObject.Properties['HttpResponseCode'] -and [int]$err.Value.HttpResponseCode -eq 404) { return $true }
        $sc = $ex.PSObject.Properties['StatusCode']
        if ($sc -and $null -ne $sc.Value -and "$($sc.Value)" -in @('404', 'NotFound')) { return $true }
        $ex = $ex.InnerException
    }
    return $false
}

function Get-RestUnique {
    # Read HasUniqueRoleAssignments for a securable via REST (bool). Retried;
    # throws if it still fails, because $false would read as 'inherits, nothing
    # to check' - the caller must mark the scan incomplete instead.
    param([string]$Url)
    $r = Invoke-SsmRetry -What 'Reading permission state' -Kind 'PermState' -ArgumentList $Url -Action { param($u) Invoke-PnPSPRestMethod -Url $u -Method Get }
    return [bool]$r.HasUniqueRoleAssignments
}

function Get-SharingLinkInfo {
    # CSOM ObjectSharingInformation.SharingLinks carries Created (the REST
    # GetSharingInformation twin takes no JSON request fields on current
    # tenants, and the Graph permission resource has no created date).
    # Returns map of link Url -> Created ISO string, or $null.
    param([string]$ListId, [int]$ItemId)
    try {
        $ctx = Get-PnPContext
        $osi = Invoke-SsmRetry -Kind 'LinkDates' -MaxAttempts 1 -What 'Reading link dates' -ArgumentList $ListId, $ItemId -Action { param($lid, $iid)
            $o = [Microsoft.SharePoint.Client.ObjectSharingInformation]::GetListItemSharingInformation(
                $ctx, [guid]$lid, $iid, $false, $false, $false, $true, $true, $false)
            $ctx.Load($o)
            $ctx.ExecuteQuery()
            $o
        }
        $map = @{}
        foreach ($sl in @($osi.SharingLinks)) {
            # Created comes back as a plain string ("2026-07-24T07:10:18.520Z") - keep as-is.
            if ($sl.Url -and $sl.Created) { $map[$sl.Url] = [string]$sl.Created }
        }
        return $map
    } catch {
        Write-SsmLog -Message ("SharingLinks lookup failed for item {0}: {1}" -f $ItemId, $_.Exception.Message) -Level WARN
        return $null
    }
}

function Add-GrantsRest {
    # Read a roleassignments collection via REST and add bad direct grants to $Bag.
    # Retried; throws if the read still fails (the caller marks the scan incomplete).
    param($RaUrl, $Site, $Location, $Name, $Path, $ListId, $ItemId, [string[]]$Categories, $Bag, [int]$Reach = 1)
    $resp = Invoke-SsmRetry -What 'Reading role assignments' -Kind 'Grants' -ArgumentList $RaUrl -Action { param($u) Invoke-PnPSPRestMethod -Url $u -Method Get }
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
        $principal = [string]$ra.Member.Title
        if ($key -eq 'GuestGrant') { $principal += ' [guest]' }
        $Bag.Add([pscustomobject]@{
            Site = $Site; Location = $Location; Name = $Name
            CategoryKey = $key; Category = $script:RuleCategories[$key]
            Access = $roles; Principal = $principal; Path = $Path; RemovalKind = 'DirectGrant'
            LinkId = $null; ListId = $ListId; ItemId = $ItemId; PrincipalId = $ra.PrincipalId
            LinkCreated = ''
            Reach = $Reach
            RevokeStatus = 'NotAttempted'; Selected = $false
        })
    }
}

function Complete-SiteScan {
    # Record totals on the target and give web-level findings the full site reach.
    param($Target, $Bag, [int]$TotalItems, [int]$LibCount, [int]$FileCount)
    $Target.ItemsScanned = $TotalItems
    $Target.FilesScanned = $FileCount
    $Target.LibrariesScanned = $LibCount
    foreach ($f in $Bag) { if ($f.Location -eq 'Web') { $f.Reach = $TotalItems } }
    $parts = $Target['IncompleteParts']
    if ($null -ne $parts -and @($parts).Count -gt 0) {
        Write-SsmLog -Message ("Scan of {0} is INCOMPLETE - not fully checked: {1}" -f $Target.Url, ((@($parts | Select-Object -First 5) -join '; ') + $(if (@($parts).Count -gt 5) { ' (+{0} more)' -f (@($parts).Count - 5) }))) -Level WARN
    }
    return $Bag.ToArray()
}

function Invoke-SiteScan {
    # Scan the currently-connected site/OneDrive; return an array of findings.
    param($Target, [string[]]$Categories, [scriptblock]$Progress)
    $bag = New-Object System.Collections.Generic.List[object]
    $totalItems = 0; $libCount = 0; $fileCount = 0
    $Target['IncompleteParts'] = [System.Collections.Generic.List[string]]::new()
    $site = $Target.Url
    $grantKeys = @('GuestGrant', 'EEEU', 'Everyone')
    $linkKeys = @('AnonymousLink', 'OrgLink', 'GuestLink')
    $scanGrants = ([bool]@($Categories | Where-Object { $grantKeys -contains $_ }).Count)
    $scanLinks = ([bool]@($Categories | Where-Object { $linkKeys -contains $_ }).Count)
    $wantLinkDates = ($script:Auth -and $script:Auth.Contains('IncludeLinkDates') -and $script:Auth.IncludeLinkDates -eq 'True')

    $web = Invoke-SsmRetry -Kind 'Web' -MaxAttempts 1 -What 'Reading the site' -Action { Get-PnPWeb }
    $base = $web.Url.TrimEnd('/')
    $raSelect = "`$expand=Member,RoleDefinitionBindings&`$select=PrincipalId,Member/LoginName,Member/Title,RoleDefinitionBindings/Name,RoleDefinitionBindings/RoleTypeKind"

    # Web-root direct grants
    try {
        if ($scanGrants -and (Get-RestUnique "$base/_api/web?`$select=HasUniqueRoleAssignments")) {
            Add-GrantsRest "$base/_api/web/roleassignments?$raSelect" $site 'Web' $web.Title $base $null $null $Categories $bag 0
        }
    } catch { Set-ScanIncomplete -Target $Target -Part 'site-level permissions unreadable, direct grants on the site not checked' -ErrorRecord $_ }

    if (-not ($scanGrants -or $scanLinks)) { return Complete-SiteScan -Target $Target -Bag $bag -TotalItems $totalItems -LibCount $libCount -FileCount $fileCount }

    $libs = @(Invoke-SsmRetry -Kind 'Lists' -MaxAttempts 1 -What 'Reading the lists' -Action { Get-PnPList } | Where-Object { $_.BaseType -eq 'DocumentLibrary' -and -not $_.Hidden })
    foreach ($lib in $libs) {
        try { $rootUrl = Invoke-SsmRetry -What ("Reading the root folder of library '{0}'" -f $lib.Title) -Kind 'LibRoot' -Action { (Get-PnPProperty -ClientObject $lib -Property RootFolder).ServerRelativeUrl } }
        catch { Set-ScanIncomplete -Target $Target -Part ("library '{0}': root folder unreadable, library not scanned" -f $lib.Title) -ErrorRecord $_; continue }
        if ($rootUrl.Split('/')[-1] -in $script:ExcludedUrlNames) { continue }
        $listId = $lib.Id.ToString()
        # ItemCount feeds the progress text and the Reach of library-level findings
        # (the exposure score), so a failed read must not silently become 0.
        $total = 0; $countFailed = $false
        try { $total = [int](Invoke-SsmRetry -What ("Reading the item count of library '{0}'" -f $lib.Title) -Kind 'ItemCount' -Action { Get-PnPProperty -ClientObject $lib -Property ItemCount }) }
        catch {
            $countFailed = $true
            Write-SsmLog -Message ("Library '{0}': item count could not be read ({1}); the reach of library-level findings uses the number of items scanned instead" -f $lib.Title, $_.Exception.Message) -Level WARN
        }
        Write-SsmLog -Message ("Library '{0}' (~{1} items)" -f $lib.Title, $total)

        # Library-root direct grants
        try {
            if ($scanGrants -and (Get-RestUnique "$base/_api/web/lists(guid'$listId')?`$select=HasUniqueRoleAssignments")) {
                Add-GrantsRest "$base/_api/web/lists(guid'$listId')/roleassignments?$raSelect" $site 'Library' $lib.Title $rootUrl $listId $null $Categories $bag $total
            }
        } catch { Set-ScanIncomplete -Target $Target -Part ("library '{0}': library-level permissions unreadable, direct grants on the library not checked" -f $lib.Title) -ErrorRecord $_ }

        # Enumerate items by indexed Id range, collecting only unique-permission items
        $unique = New-Object System.Collections.Generic.List[object]
        $lastId = 0
        $scanned = 0
        $enumFailed = $false
        do {
            # Each page is retried on its own and starts at the current $lastId,
            # so a failed page never restarts the library from the beginning.
            $u = "$base/_api/web/lists(guid'$listId')/items?`$select=Id,FileRef,FileLeafRef,FSObjType,HasUniqueRoleAssignments&`$filter=Id%20gt%20$lastId&`$orderby=Id&`$top=5000"
            try { $resp = Invoke-SsmRetry -What ("Reading items of library '{0}' after Id {1}" -f $lib.Title, $lastId) -Kind 'ItemsPage' -Action { Invoke-PnPSPRestMethod -Url $u -Method Get } }
            catch {
                Set-ScanIncomplete -Target $Target -Part ("library '{0}': item enumeration failed after {1} items, the rest of the library was not checked" -f $lib.Title, $scanned) -ErrorRecord $_
                $enumFailed = $true; break
            }
            $rows = @($resp.value)
            foreach ($r in $rows) {
                $scanned++
                if ([int]$r.FSObjType -eq 0) { $fileCount++ }
                if ($r.HasUniqueRoleAssignments) { $unique.Add($r) }
                if ($r.Id -gt $lastId) { $lastId = $r.Id }
            }
            if ($Progress) { & $Progress -Count $scanned -Label ("Enumerating '{0}': {1} / ~{2} scanned" -f $lib.Title, $scanned, $total) }
        } while ($rows.Count -eq 5000)
        if ($countFailed) {
            foreach ($f in $bag) { if ($f.Location -eq 'Library' -and $f.ListId -eq $listId) { $f.Reach = $scanned } }
        }
        if ($enumFailed) {
            Write-SsmLog -Message ("'{0}' only partly scanned: {1} items read, {2} with unique permissions (the rest of the library was not checked)" -f $lib.Title, $scanned, $unique.Count) -Level WARN
            $totalItems += $scanned
        } else {
            Write-SsmLog -Message ("{0} scanned, {1} with unique permissions in '{2}'" -f $scanned, $unique.Count, $lib.Title)
            $totalItems += $scanned; $libCount++
        }

        # Check each unique-permission item: sharing links + direct grants
        $idx = 0
        $linkFailIds = [System.Collections.Generic.List[object]]::new()
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
                # A failed read must never look like "no links": retry, then either
                # skip a deleted item (404, logged by id) or flag the target incomplete.
                $links = @()
                try {
                    $links = @(Invoke-SsmRetry -What ("Reading sharing links of item {0}" -f $it.Id) -Kind 'Links' -Permanent { param($e) Test-SsmItemGone $e } -Action {
                        if ($isFolder) { Get-PnPFolderSharingLink -Folder $fileRef -ErrorAction Stop }
                        else { Get-PnPFileSharingLink -Identity $fileRef -ErrorAction Stop }
                    })
                } catch {
                    if (Test-SsmItemGone $_) {
                        Write-SsmLog -Message ("Item {0} in '{1}' no longer exists (404), skipped" -f $it.Id, $lib.Title) -Level WARN
                    } else {
                        Write-SsmErrorLog -Context ("Sharing links of item {0} in '{1}' could not be read" -f $it.Id, $lib.Title) -ErrorRecord $_
                        $linkFailIds.Add($it.Id)
                    }
                }
                # Optional per-tenant: one extra CSOM call per item for link Created date.
                $infoMap = $null
                if ($wantLinkDates -and @($links).Count -gt 0) { $infoMap = Get-SharingLinkInfo -ListId $listId -ItemId $it.Id }
                foreach ($l in @($links)) {
                    if (-not $l.Link) { continue }
                    $cat = Get-LinkCategory -Scope $l.Link.Scope -Link $l
                    if (-not $cat) { continue }
                    if ($Categories -notcontains $cat.Key) { continue }
                    $created = ''
                    if ($infoMap -and $l.Link.WebUrl -and $infoMap.ContainsKey($l.Link.WebUrl)) {
                        $created = [string]$infoMap[$l.Link.WebUrl]
                    }
                    $bag.Add([pscustomobject]@{
                        Site = $site; Location = $loc; Name = $name
                        CategoryKey = $cat.Key; Category = $script:RuleCategories[$cat.Key]
                        Access = $l.Link.Type; Principal = $cat.Principal; Path = $fileRef; RemovalKind = 'Link'
                        LinkId = $l.Id; ListId = $listId; ItemId = $it.Id; PrincipalId = $null
                        LinkCreated = $created
                        Reach = 1
                        RevokeStatus = 'NotAttempted'; Selected = $false
                    })
                }
            }

            # 2) Direct grants on the item (EEEU / Everyone / guest granted directly, not via a link)
            if ($scanGrants) {
                Add-GrantsRest "$base/_api/web/lists(guid'$listId')/items($($it.Id))/roleassignments?$raSelect" $site $loc $name $fileRef $listId $it.Id $Categories $bag
            }
            } catch {
                Set-ScanIncomplete -Target $Target -Part ("library '{0}': item {1} skipped, an error stopped its sharing check" -f $lib.Title, $it.Id) -ErrorRecord $_
            }
        }
        # One short part per library however many items failed (each failure was logged in full above).
        if ($linkFailIds.Count -gt 0) {
            $Target['IncompleteParts'].Add(("library '{0}': sharing links could not be read for {1} {3} (first: {2})" -f $lib.Title, $linkFailIds.Count, (@($linkFailIds | Select-Object -First 3) -join ', '), $(if ($linkFailIds.Count -eq 1) { 'item' } else { 'items' })))
        }
    }
    return Complete-SiteScan -Target $Target -Bag $bag -TotalItems $totalItems -LibCount $libCount -FileCount $fileCount
}

#endregion
