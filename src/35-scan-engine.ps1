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
    $script:ScanStats = @{ Clock = [System.Diagnostics.Stopwatch]::StartNew(); Kinds = @{}; Fallbacks = @{} }
}

function Add-SsmScanFallback {
    # Count one use of a per-call read because the bulk read did not give the data.
    param([string]$Kind)
    if ($null -eq $script:ScanStats) { return }
    $script:ScanStats.Fallbacks[$Kind] = 1 + [int]$script:ScanStats.Fallbacks[$Kind]
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
    $fb = ''
    if ($s.Fallbacks.Count -gt 0) { $fb = '; fell back to per-call reads: ' + (($s.Fallbacks.Keys | Sort-Object | ForEach-Object { '{0} {1}' -f $_, $s.Fallbacks[$_] }) -join ', ') }
    Write-SsmLog -Message ('Scan stats: {0} {1}, {2} requests in {3} s ({4} req/s); {5}' -f $Targets, $(if ($Targets -eq 1) { 'target' } else { 'targets' }),
        $calls, $wall.ToString('0.0', $inv), $rate.ToString('0.0', $inv), (($parts -join '; ') + $fb)) -Level INFO
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

# Bulk reads (one REST call for a whole site / all its lists) replace several
# per-call reads. Anything the bulk answer does not give reliably is read the
# per-call way, exactly as before. If a bulk read fails 3 times in a row while the
# per-call path then works, it is switched off for the rest of the run (it
# would otherwise add a failed call, plus retries, to every site).
$script:SsmBulkFailures = @{}

function Test-SsmBulkOk {
    param([string]$Kind)
    return ([int]$script:SsmBulkFailures[$Kind] -lt 3)
}

function Set-SsmBulkResult {
    param([string]$Kind, [bool]$Ok)
    if ($Ok) { $script:SsmBulkFailures[$Kind] = 0; return }
    $n = 1 + [int]$script:SsmBulkFailures[$Kind]
    $script:SsmBulkFailures[$Kind] = $n
    Add-SsmScanFallback -Kind $Kind
    if ($n -eq 3) {
        Write-SsmLog -Message ("The bulk '{0}' read failed 3 times in a row; it is switched off for the rest of this run and the per-call reads are used instead." -f $Kind) -Level WARN
    }
}

function Get-SsmProp {
    # Value of a property that may be missing (StrictMode-safe); $null when absent.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-SsmSiteInfo {
    # Site Url, Title and own-permission flag in ONE REST read. Falls back to
    # Get-PnPWeb (today's call, whose errors - e.g. a locked site - propagate
    # unchanged) when the read fails or lacks Url or Title. Unique is $null when
    # the answer did not carry HasUniqueRoleAssignments: the caller then reads it.
    # One attempt only: a locked site fails here too and must not wait for retries
    # before Get-PnPWeb reports it.
    $web = $null; $unique = $null; $bulkTried = $false; $template = $null
    if (Test-SsmBulkOk 'Web') {
        $bulkTried = $true
        try {
            $w = Invoke-SsmRetry -Kind 'Web' -MaxAttempts 1 -What 'Reading the site' -Action { Invoke-PnPSPRestMethod -Url "/_api/web?`$select=Url,Title,HasUniqueRoleAssignments,WebTemplate,Configuration" -Method Get }
            $url = [string](Get-SsmProp $w 'Url'); $title = Get-SsmProp $w 'Title'
            if ($url.Trim() -and $null -ne $title) {
                $web = [pscustomobject]@{ Url = $url; Title = [string]$title }
                $hu = Get-SsmProp $w 'HasUniqueRoleAssignments'
                if ($hu -is [bool]) { $unique = $hu }
                $wt = [string](Get-SsmProp $w 'WebTemplate'); $cf = Get-SsmProp $w 'Configuration'
                if ($wt.Trim() -and $null -ne $cf) { $template = '{0}#{1}' -f $wt.Trim(), $cf }   # same form as the tenant listing, e.g. SRCHCEN#0
            }
        } catch {
            Write-SsmLog -Message ("Bulk read of the site failed ({0}); using the per-call read." -f $_.Exception.Message) -Level INFO
        }
    }
    if ($web) { Set-SsmBulkResult 'Web' $true; return [pscustomobject]@{ Web = $web; Unique = $unique; Template = $template } }
    $web = Invoke-SsmRetry -Kind 'Web' -MaxAttempts 1 -What 'Reading the site' -Action { Get-PnPWeb }
    if ($bulkTried) { Set-SsmBulkResult 'Web' $false }
    return [pscustomobject]@{ Web = $web; Unique = $null; Template = $null }
}

function New-SsmLibraryDesc {
    # Id/Title of a document library plus what is already known about it.
    # Lib = the CSOM list object (needed only for the per-call reads); RootUrl,
    # Total and Unique are $null when unknown, which means "read it".
    param($Id, $Title, $Lib, $RootUrl, $Total, $Unique)
    return [pscustomobject]@{ Id = [string]$Id; Title = [string]$Title; Lib = $Lib; RootUrl = $RootUrl; Total = $Total; Unique = $Unique }
}

function Get-SsmListObject {
    # The CSOM list object of a library found by the bulk read (the per-call reads need it).
    param($Desc)
    if (-not $Desc.Lib) {
        $Desc.Lib = Invoke-SsmRetry -Kind 'Lists' -What ("Reading library '{0}'" -f $Desc.Title) -ArgumentList $Desc.Id -Action { param($id) Get-PnPList -Identity $id }
        if (-not $Desc.Lib) { throw ("library '{0}' not found" -f $Desc.Title) }
    }
    return $Desc.Lib
}

function Read-SsmBulkLibraries {
    # All lists of the site in one (paged) REST read; returns the visible document
    # libraries. Throws when the answer is unusable (no value, empty, or a list
    # without Id/Title/BaseType/Hidden): membership cannot be decided, so the
    # caller falls back to Get-PnPList for the whole site.
    param([string]$Base)
    $url = "$Base/_api/web/lists?`$select=Id,Title,BaseType,Hidden,ItemCount,HasUniqueRoleAssignments,RootFolder/ServerRelativeUrl&`$expand=RootFolder"
    $rows = [System.Collections.Generic.List[object]]::new()
    $pages = 0
    while ($url) {
        if (++$pages -gt 1000) { throw 'the lists answer has more than 1000 pages' }
        $resp = Invoke-SsmRetry -Kind 'Lists' -What 'Reading the lists' -ArgumentList $url -Action { param($u) Invoke-PnPSPRestMethod -Url $u -Method Get }
        $vp = $null
        if ($null -ne $resp) { $vp = $resp.PSObject.Properties['value'] }
        if (-not $vp) { throw 'unexpected answer: no value' }
        foreach ($r in @($vp.Value)) { if ($null -ne $r) { $rows.Add($r) } }
        $next = Get-SsmProp $resp 'odata.nextLink'
        $url = if ($next) { [string]$next } else { $null }
    }
    if ($rows.Count -eq 0) { throw 'the lists answer is empty' }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $rows) {
        $guid = [guid]::Empty
        if (-not [guid]::TryParse([string](Get-SsmProp $r 'Id'), [ref]$guid)) { throw 'a list without a valid Id' }
        $title = Get-SsmProp $r 'Title'; $bt = Get-SsmProp $r 'BaseType'; $hidden = Get-SsmProp $r 'Hidden'
        if ($null -eq $title -or $null -eq $bt -or $hidden -isnot [bool] -or "$bt" -notmatch '^(\d+|[A-Za-z]+)$') { throw 'a list without Title, BaseType or Hidden' }
        if (("$bt" -ne '1' -and "$bt" -ne 'DocumentLibrary') -or $hidden) { continue }
        $ru = Get-SsmProp (Get-SsmProp $r 'RootFolder') 'ServerRelativeUrl'
        $rootUrl = if ($ru -is [string] -and $ru.Trim()) { $ru } else { $null }
        $ic = Get-SsmProp $r 'ItemCount'; $total = $null; $n = 0L
        if ($null -ne $ic -and $ic -isnot [bool] -and [long]::TryParse([string]$ic, [ref]$n) -and $n -ge 0 -and $n -le [int]::MaxValue) { $total = [int]$n }
        $hu = Get-SsmProp $r 'HasUniqueRoleAssignments'
        $unique = if ($hu -is [bool]) { $hu } else { $null }
        $out.Add((New-SsmLibraryDesc -Id $guid.ToString() -Title $title -Lib $null -RootUrl $rootUrl -Total $total -Unique $unique))
    }
    return , $out.ToArray()
}

function Get-SsmSiteLibraries {
    # The visible document libraries of the site (BaseType DocumentLibrary, not
    # Hidden): from the bulk read when it works, else from Get-PnPList as before.
    param([string]$Base)
    $libs = $null; $bulkTried = $false
    if (Test-SsmBulkOk 'Lists') {
        $bulkTried = $true
        try { $libs = Read-SsmBulkLibraries -Base $Base }
        catch {
            $libs = $null
            Write-SsmLog -Message ("Bulk read of the lists failed ({0}); using the per-call reads." -f $_.Exception.Message) -Level INFO
        }
    }
    if ($null -ne $libs) { Set-SsmBulkResult 'Lists' $true; return $libs }   # the caller wraps the result in @()
    $all = @(Invoke-SsmRetry -Kind 'Lists' -MaxAttempts 1 -What 'Reading the lists' -Action { Get-PnPList })
    if ($bulkTried) { Set-SsmBulkResult 'Lists' $false }
    $out = @($all | Where-Object { $_.BaseType -eq 'DocumentLibrary' -and -not $_.Hidden } |
        ForEach-Object { New-SsmLibraryDesc -Id $_.Id.ToString() -Title $_.Title -Lib $_ -RootUrl $null -Total $null -Unique $null })
    return $out
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
    # -AllowEeeuRead: the site is a system site (see $script:SystemSiteTemplates); an EEEU grant
    # that carries only Read (RoleTypeKind 2, language-independent) is by design and not reported.
    param($RaUrl, $Site, $Location, $Name, $Path, $ListId, $ItemId, [string[]]$Categories, $Bag, [int]$Reach = 1, [switch]$AllowEeeuRead, [string]$Template = '')
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
        if ($AllowEeeuRead -and $key -eq 'EEEU' -and @($realRoles | Where-Object { [int]$_.RoleTypeKind -ne 2 }).Count -eq 0) {
            Write-SsmLog -Message ("Not flagged: 'Everyone except external users' has Read on a system site ({0}, template {1})." -f $Site, $Template) -Level INFO
            continue
        }
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

    $info = Get-SsmSiteInfo
    $web = $info.Web
    $base = $web.Url.TrimEnd('/')
    $raSelect = "`$expand=Member,RoleDefinitionBindings&`$select=PrincipalId,Member/LoginName,Member/Title,RoleDefinitionBindings/Name,RoleDefinitionBindings/RoleTypeKind"

    # Web-root direct grants
    try {
        if ($scanGrants) {
            $webUnique = $info.Unique
            if ($null -eq $webUnique) { $webUnique = Get-RestUnique "$base/_api/web?`$select=HasUniqueRoleAssignments" }
            if ($webUnique) {
                # Template: from the tenant listing (the target) or, when the URL was typed or imported, from the site read.
                $tpl = [string]$Target['Template']
                if (-not ($script:SystemSiteTemplates -contains $tpl) -and $info.Template) { $tpl = [string]$info.Template }
                $isSystemSite = ($script:SystemSiteTemplates -contains $tpl)
                Add-GrantsRest "$base/_api/web/roleassignments?$raSelect" $site 'Web' $web.Title $base $null $null $Categories $bag 0 -AllowEeeuRead:$isSystemSite -Template $tpl
            }
        }
    } catch { Set-ScanIncomplete -Target $Target -Part 'site-level permissions unreadable, direct grants on the site not checked' -ErrorRecord $_ }

    if (-not ($scanGrants -or $scanLinks)) { return Complete-SiteScan -Target $Target -Bag $bag -TotalItems $totalItems -LibCount $libCount -FileCount $fileCount }

    # $lib is a library descriptor (Id, Title and what the bulk read already told us).
    # Whatever it did not tell us is read the per-call way, exactly as before.
    $libs = @(Get-SsmSiteLibraries -Base $base)
    foreach ($lib in $libs) {
        $fromBulk = ($null -eq $lib.Lib)   # no CSOM list object yet: needed only by the per-call reads
        $rootUrl = $lib.RootUrl
        if (-not $rootUrl) {
            if ($fromBulk) { Add-SsmScanFallback -Kind 'LibRoot' }
            try {
                $csom = Get-SsmListObject $lib
                $rootUrl = Invoke-SsmRetry -What ("Reading the root folder of library '{0}'" -f $lib.Title) -Kind 'LibRoot' -Action { (Get-PnPProperty -ClientObject $csom -Property RootFolder).ServerRelativeUrl }
            }
            catch { Set-ScanIncomplete -Target $Target -Part ("library '{0}': root folder unreadable, library not scanned" -f $lib.Title) -ErrorRecord $_; continue }
        }
        # Excluded system libraries are dropped here, before any further per-library read.
        if ($rootUrl.Split('/')[-1] -in $script:ExcludedUrlNames) { continue }
        $listId = $lib.Id.ToString()
        # ItemCount feeds the progress text and the Reach of library-level findings
        # (the exposure score), so a failed read must not silently become 0.
        $total = 0; $countFailed = $false
        if ($null -ne $lib.Total) { $total = $lib.Total }
        else {
            if ($fromBulk) { Add-SsmScanFallback -Kind 'ItemCount' }
            try {
                $csom = Get-SsmListObject $lib
                $total = [int](Invoke-SsmRetry -What ("Reading the item count of library '{0}'" -f $lib.Title) -Kind 'ItemCount' -Action { Get-PnPProperty -ClientObject $csom -Property ItemCount })
            }
            catch {
                $countFailed = $true
                Write-SsmLog -Message ("Library '{0}': item count could not be read ({1}); the reach of library-level findings uses the number of items scanned instead" -f $lib.Title, $_.Exception.Message) -Level WARN
            }
        }
        Write-SsmLog -Message ("Library '{0}' (~{1} items)" -f $lib.Title, $total)

        # Library-root direct grants
        try {
            if ($scanGrants) {
                $libUnique = $lib.Unique   # $null = the bulk read did not say: never assume "inherits"
                if ($null -eq $libUnique) {
                    if ($fromBulk) { Add-SsmScanFallback -Kind 'PermState' }
                    $libUnique = Get-RestUnique "$base/_api/web/lists(guid'$listId')?`$select=HasUniqueRoleAssignments"
                }
                if ($libUnique) {
                    Add-GrantsRest "$base/_api/web/lists(guid'$listId')/roleassignments?$raSelect" $site 'Library' $lib.Title $rootUrl $listId $null $Categories $bag $total
                }
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
