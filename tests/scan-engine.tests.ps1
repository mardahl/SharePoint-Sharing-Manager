Invoke-SsmTest 'EEEU login classified' {
    Assert-Equal 'EEEU' (Get-PrincipalCategory -Login 'c:0-.f|rolemanager|spo-grid-all-users/abc123' -Title 'Everyone except external users')
}
Invoke-SsmTest 'Everyone claim classified' {
    Assert-Equal 'Everyone' (Get-PrincipalCategory -Login 'c:0(.s|true' -Title 'Everyone')
}
Invoke-SsmTest 'Guest ext login classified' {
    Assert-Equal 'GuestGrant' (Get-PrincipalCategory -Login 'i:0#.f|membership|jane_gmail.com#ext#@contoso.onmicrosoft.com' -Title 'Jane Guest')
}
Invoke-SsmTest 'Internal member kept (null)' {
    Assert-Equal '' (Get-PrincipalCategory -Login 'i:0#.f|membership|bob@contoso.com' -Title 'Bob')
}
Invoke-SsmTest 'SharingLinks principal skipped' {
    Assert-Equal '' (Get-PrincipalCategory -Login 'x' -Title 'SharingLinks.abc.Flexible.def')
}
Invoke-SsmTest 'Empty principal skipped' {
    Assert-Equal '' (Get-PrincipalCategory -Login '' -Title '')
}
Invoke-SsmTest 'Guest grantees extracted from users-link' {
    $link = [pscustomobject]@{ GrantedToIdentitiesV2 = @(
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|g_x.com#ext#@t.onmicrosoft.com' }; User = [pscustomobject]@{ Email = 'g@x.com' } },
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|bob@contoso.com' }; User = [pscustomobject]@{ Email = 'bob@contoso.com' } }
    )}
    $g = @(Get-GuestGrantees -Link $link)
    Assert-Equal 1 $g.Count
    Assert-Equal 'g@x.com' $g[0]
}
Invoke-SsmTest 'Guest grantee with unresolved User identity (SiteUser only) does not throw' {
    $link = [pscustomobject]@{ GrantedToIdentitiesV2 = @(
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|g_x.com#ext#@t.onmicrosoft.com' }; User = $null }
    )}
    $g = @(Get-GuestGrantees -Link $link)
    Assert-Equal 1 $g.Count
    Assert-Equal 'i:0#.f|membership|g_x.com#ext#@t.onmicrosoft.com' $g[0]
}
Invoke-SsmTest 'Link categories: anonymous / organization / internal users-link' {
    $r = Get-LinkCategory -Scope 'anonymous' -Link ([pscustomobject]@{})
    Assert-Equal 'AnonymousLink' $r.Key
    $r = Get-LinkCategory -Scope 'organization' -Link ([pscustomobject]@{})
    Assert-Equal 'OrgLink' $r.Key
    $r = Get-LinkCategory -Scope 'users' -Link ([pscustomobject]@{ GrantedToIdentitiesV2 = @() })
    Assert-Equal '' $r    # internal-only specific-people link is KEPT
}
Invoke-SsmTest 'Guest users-link principal carries [guest] marker' {
    $link = [pscustomobject]@{ GrantedToIdentitiesV2 = @(
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|g_x.com#ext#@t.onmicrosoft.com' }; User = [pscustomobject]@{ Email = 'g@x.com' } }
    )}
    $r = Get-LinkCategory -Scope 'users' -Link $link
    Assert-Equal 'GuestLink' $r.Key
    Assert-Equal 'g@x.com [guest]' $r.Principal
}

Invoke-SsmTest 'New-Target defaults ItemsScanned and LibrariesScanned to 0' {
    $t = New-Target -Url 'https://x.sharepoint.com/sites/a'
    Assert-Equal 0 $t.ItemsScanned
    Assert-Equal 0 $t.LibrariesScanned
}

Invoke-SsmTest 'Cache round-trips ItemsScanned and finding Reach' {
    $t = New-Target -Url 'https://x.sharepoint.com/sites/a'
    $t.ItemsScanned = 1234; $t.LibrariesScanned = 2; $t.FilesScanned = 1200; $t.StorageMB = 5120; $t.Status = 'Findings'; $t.FindingCount = 1
    $t.Findings = @([pscustomobject]@{ Site=$t.Url; Location='Library'; Name='Documents'; CategoryKey='EEEU'; Category='EEEU grant'; Access='Read'; Principal='Everyone except external users'; Path='/sites/a/Shared Documents'; RemovalKind='DirectGrant'; LinkId=$null; ListId='L'; ItemId=$null; PrincipalId=4; LinkCreated=''; Reach=1000; RevokeStatus='NotAttempted'; Selected=$false })
    $tab = @{ Kind='Targets'; Name='Sites'; Categories=@('EEEU'); Items=@($t) }
    $json = ConvertTo-SsmCacheObject -Tabs @($tab) | ConvertTo-Json -Depth 10
    $tab2 = @{ Kind='Targets'; Name='Sites'; Categories=@(); Items=@() }
    ConvertFrom-SsmCacheObject -Cache ($json | ConvertFrom-Json) -Tabs @($tab2)
    Assert-Equal 1234 $tab2['Items'][0].ItemsScanned
    Assert-Equal 2 $tab2['Items'][0].LibrariesScanned
    Assert-Equal 1200 $tab2['Items'][0].FilesScanned
    Assert-Equal 5120 $tab2['Items'][0].StorageMB
    Assert-Equal ('{0:N1} GB' -f 5.0) (Format-SsmStorage -MB 5120)
    Assert-Equal 1000 $tab2['Items'][0].Findings[0].Reach
}

Invoke-SsmTest 'Cache restore tolerates old entries without ItemsScanned' {
    $old = [pscustomobject]@{ Tabs=@([pscustomobject]@{ Name='Sites'; Categories=@(); Items=@([pscustomobject]@{ Url='https://x/sites/a'; Title='a'; Template=''; Status='Clean'; FindingCount=0; Findings=@() }) }); SavedAt='2026-01-01T00:00:00Z' }
    $tab = @{ Kind='Targets'; Name='Sites'; Categories=@(); Items=@() }
    ConvertFrom-SsmCacheObject -Cache $old -Tabs @($tab)
    Assert-Equal 0 $tab['Items'][0].ItemsScanned
}

Invoke-SsmTest 'Complete-SiteScan sets ItemsScanned and web Reach' {
    $t = New-Target -Url 'https://x/sites/a'
    $bag = [System.Collections.Generic.List[object]]::new()
    $bag.Add([pscustomobject]@{ Location='Web'; Reach=0 })
    $bag.Add([pscustomobject]@{ Location='File'; Reach=1 })
    $out = @(Complete-SiteScan -Target $t -Bag $bag -TotalItems 500 -LibCount 3)
    Assert-Equal 500 $t.ItemsScanned
    Assert-Equal 3 $t.LibrariesScanned
    Assert-Equal 500 $out[0].Reach
    Assert-Equal 1 $out[1].Reach
}


# --- Invoke-SiteScan with stubbed PnP cmdlets ------------------------------
# Dot-source this inside a test block: the stubs then live in that block's
# scope and vanish with it. $script:Sim holds the scripted scenario and the
# call log. Two libraries: 'Library A' (item 2 carries an anonymous link) and
# 'Library B' (item 1 carries an anonymous link).
$script:DefineScanStubs = {
    if (-not (Get-Variable -Name RuleCategories -Scope Script -ErrorAction SilentlyContinue)) {
        $script:RuleCategories = [ordered]@{ AnonymousLink = 'Anonymous link'; OrgLink = 'Organization link'; GuestLink = 'Guest link'; GuestGrant = 'Guest grant'; EEEU = 'EEEU grant'; Everyone = 'Everyone grant' }
    }
    if (-not (Get-Variable -Name ExcludedUrlNames -Scope Script -ErrorAction SilentlyContinue)) {
        $script:ExcludedUrlNames = @('SiteAssets', 'SitePages')
    }
    function New-ScanItem { param([int]$Id, [string]$Leaf, [bool]$Unique = $false, [int]$Type = 0)
        [pscustomobject]@{ Id = $Id; FileRef = "/sites/x/$Leaf"; FileLeafRef = $Leaf; FSObjType = $Type; HasUniqueRoleAssignments = $Unique } }
    $script:Sim = @{
        Libs      = @('Library A', 'Library B')
        Items     = @{
            'Library A' = @((New-ScanItem 1 'a1.docx'), (New-ScanItem 2 'a2.docx' $true), (New-ScanItem 3 'folder' $false 1))
            'Library B' = @((New-ScanItem 1 'b1.docx' $true))
        }
        RootFail  = @{}      # library title -> number of root-folder reads that still fail
        RestFail  = [System.Collections.Generic.List[object]]::new()   # @{ Match = <regex on the URL>; Remaining = <n> }: throws while Remaining > 0
        ItemUrls  = [System.Collections.Generic.List[string]]::new()   # every items-page request
        LinkFail  = @{}      # item FileRef -> @{ Remaining = <n>; Make = <scriptblock returning the exception to throw> }
        LinkCalls = @{}      # item FileRef -> number of sharing-link reads
        RootCalls = @{ 'Library A' = 0; 'Library B' = 0 }
        Sleeps    = [System.Collections.Generic.List[object]]::new()
        Log       = [System.Collections.Generic.List[string]]::new()
    }
    function Wait-SsmRetry { param([int]$Seconds) $script:Sim.Sleeps.Add($Seconds) }
    function Write-SsmLog { param([string]$Message, [string]$Level = 'INFO') $script:Sim.Log.Add("[$Level] $Message") }
    function Write-SsmErrorLog { param([string]$Context, $ErrorRecord) $script:Sim.Log.Add("[ERROR] $Context | $($ErrorRecord.Exception.Message)") }
    function Get-PnPWeb { [pscustomobject]@{ Url = 'https://contoso.sharepoint.com/sites/x'; Title = 'Site X' } }
    function Get-PnPList {
        $i = 0
        foreach ($t in $script:Sim.Libs) { $i++; [pscustomobject]@{ Title = $t; Id = [guid]("00000000-0000-0000-0000-{0:D12}" -f $i); BaseType = 'DocumentLibrary'; Hidden = $false } }
    }
    function Get-PnPProperty { param($ClientObject, $Property)
        if ($Property -eq 'RootFolder') {
            $title = $ClientObject.Title
            $script:Sim.RootCalls[$title]++
            if ($script:Sim.RootFail.ContainsKey($title) -and $script:Sim.RootFail[$title] -gt 0) {
                $script:Sim.RootFail[$title]--
                throw 'The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing.'
            }
            return [pscustomobject]@{ ServerRelativeUrl = "/sites/x/$title" }
        }
        if ($Property -eq 'ItemCount') { return @($script:Sim.Items[$ClientObject.Title]).Count }
    }
    function Invoke-PnPSPRestMethod { param($Url, $Method)
        $null = $Method
        if ($Url -match "guid'0{8}-0{4}-0{4}-0{4}-0{11}1'\)/items\?") { $script:Sim.ItemUrls.Add($Url) }
        foreach ($rule in $script:Sim.RestFail) {
            if ($rule.Remaining -gt 0 -and $Url -match $rule.Match) {
                $rule.Remaining--
                throw 'One or more errors occurred. (Error while copying content to a stream.)'
            }
        }
        if ($Url -match "guid'0{8}-0{4}-0{4}-0{4}-0{11}1'\)/items\(2\)/roleassignments") {
            return [pscustomobject]@{ value = @([pscustomobject]@{ PrincipalId = 7
                Member = [pscustomobject]@{ LoginName = 'c:0-.f|rolemanager|spo-grid-all-users/00000000-0000-0000-0000-000000000000'; Title = 'Everyone except external users' }
                RoleDefinitionBindings = @([pscustomobject]@{ Name = 'Read'; RoleTypeKind = 2 }) }) }
        }
        if ($Url -match "/lists\(guid'0{8}-0{4}-0{4}-0{4}-(\d{12})'\)/items\?") {
            $title = $script:Sim.Libs[[int]$Matches[1] - 1]
            $last = [int][regex]::Match($Url, 'Id%20gt%20(\d+)').Groups[1].Value
            return [pscustomobject]@{ value = @($script:Sim.Items[$title] | Where-Object { $_.Id -gt $last } | Select-Object -First 5000) }
        }
        if ($Url -match 'HasUniqueRoleAssignments') { return [pscustomobject]@{ HasUniqueRoleAssignments = $false } }
        return [pscustomobject]@{ value = @() }
    }
    function Invoke-SimLinkRead { param([string]$Path)
        $script:Sim.LinkCalls[$Path] = 1 + [int]$script:Sim.LinkCalls[$Path]
        $rule = $script:Sim.LinkFail[$Path]
        if ($rule -and $rule.Remaining -gt 0) { $rule.Remaining--; throw (& $rule.Make) }
    }
    function Get-PnPFileSharingLink { [CmdletBinding()] param($Identity)
        Invoke-SimLinkRead -Path $Identity
        @([pscustomobject]@{ Id = 'lnk'; Link = [pscustomobject]@{ Scope = 'anonymous'; Type = 'View'; WebUrl = 'https://contoso.sharepoint.com/s/x' } }) }
    function Get-PnPFolderSharingLink { [CmdletBinding()] param($Folder) Invoke-SimLinkRead -Path $Folder; @() }
}

Invoke-SsmTest 'Invoke-SiteScan: root-folder timeout that succeeds on retry gives the same findings as no failure' {
    . $script:DefineScanStubs
    $base = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $ref = @(Invoke-SiteScan -Target $base -Categories @('AnonymousLink'))
    Assert-Equal 2 $ref.Count
    Assert-Equal 2 $base.LibrariesScanned

    $script:Sim.RootFail['Library A'] = 1
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $t['IncompleteParts'] = @('stale entry from an earlier scan')
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 2 $out.Count
    Assert-Equal (($ref | ForEach-Object { $_.Name } | Sort-Object) -join ',') (($out | ForEach-Object { $_.Name } | Sort-Object) -join ',')
    Assert-Equal 2 $t.LibrariesScanned
    Assert-Equal 0 @($t['IncompleteParts']).Count 'a successful rescan clears the incomplete marker'
    Assert-Equal 1 $script:Sim.Sleeps.Count 'one backoff pause before the retry'
}

Invoke-SsmTest 'Invoke-SiteScan: library whose root folder keeps failing is marked incomplete and named in the log' {
    . $script:DefineScanStubs
    $script:Sim.RootFail['Library A'] = 99
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 3 $script:Sim.RootCalls['Library A'] 'bounded: 3 attempts, then give up'
    Assert-Equal 2 $script:Sim.Sleeps.Count
    Assert-Equal 1 $out.Count 'Library B is still scanned'
    Assert-Equal 'b1.docx' $out[0].Name
    Assert-Equal 1 $t.LibrariesScanned
    $parts = @($t['IncompleteParts'])
    Assert-Equal 1 $parts.Count
    if ($parts[0] -notlike "*Library A*") { throw "incomplete part does not name the library: $($parts[0])" }
    $hit = @($script:Sim.Log | Where-Object { $_ -match '^\[(WARN|ERROR)\]' -and $_ -match 'Library A' })
    if ($hit.Count -lt 1) { throw "no WARN/ERROR log line names the failed library: $($script:Sim.Log -join ' / ')" }
}

Invoke-SsmTest 'Invoke-TabScan: an incomplete scan is never marked Clean, and keeps its findings' {
    function Connect-SsmSite { param($Url) $null = $Url; $true }
    function Write-Screen { }
    function Start-LoadSpinner { }
    function Stop-LoadSpinner { }
    function Write-ProgressModal { }
    function New-SsmProgressCallback { param($Title, $State, $CancelMode) $null = $Title, $State, $CancelMode; { } }
    function Save-SsmCache { param([switch]$Throttle) $null = $Throttle }
    function Export-FindingsCsv { param($Findings, $SiteUrl, $Phase) $null = $Findings, $SiteUrl, $Phase; 'x.csv' }
    function Show-MsgModal { param($Title, $Lines, $Kind) $null = $Title, $Lines, $Kind }
    $script:Fake = @{ 'https://x/sites/none' = @(); 'https://x/sites/some' = @([pscustomobject]@{ Name = 'f' }) }
    function Invoke-SiteScan { param($Target, $Categories, $Progress)
        $null = $Categories, $Progress
        $Target['IncompleteParts'] = @("library 'Library A'")
        return $script:Fake[$Target.Url] }
    $none = New-Target -Url 'https://x/sites/none'; $none.Selected = $true
    $some = New-Target -Url 'https://x/sites/some'; $some.Selected = $true
    $tab = @{ Items = @($none, $some); Categories = @('AnonymousLink'); Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0; View = @() }
    Invoke-TabScan -Tab $tab
    Assert-Equal 'Incomplete' $none.Status
    Assert-Equal 'Incomplete' $some.Status
    Assert-Equal 1 $some.FindingCount
    Assert-Equal 1 @($some.Findings).Count
}

# Library A with 5001 items (two pages); items 2 and 5001 carry an anonymous link.
function Set-ScanSimBigLibrary {
    $items = @(1..5001 | ForEach-Object { New-ScanItem $_ "a$_.docx" ($_ -eq 2 -or $_ -eq 5001) })
    $script:Sim.Items['Library A'] = $items
}
$script:LibAItems = "guid'00000000-0000-0000-0000-000000000001'\)/items\?"
$script:LibARoot  = "guid'00000000-0000-0000-0000-000000000001'\)\?"

Invoke-SsmTest 'Invoke-SiteScan: a failed items page is retried, resumes from the last Id, and finds the same items' {
    . $script:DefineScanStubs
    Set-ScanSimBigLibrary
    $ref = @(Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories @('AnonymousLink'))
    Assert-Equal 3 $ref.Count 'Library A items 2 and 5001, Library B item 1'

    $script:Sim.ItemUrls.Clear()
    $script:Sim.RestFail.Add(@{ Match = "$script:LibAItems.*Id%20gt%205000"; Remaining = 1 })
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal (($ref | ForEach-Object { "$($_.Name)" } | Sort-Object) -join ',') (($out | ForEach-Object { "$($_.Name)" } | Sort-Object) -join ',')
    Assert-Equal 0 @($t['IncompleteParts']).Count
    Assert-Equal 2 $t.LibrariesScanned
    Assert-Equal 5002 $t.ItemsScanned 'no item counted twice, none lost'
    $gt = @($script:Sim.ItemUrls | ForEach-Object { [regex]::Match($_, 'Id%20gt%20(\d+)').Groups[1].Value })
    Assert-Equal '0,5000,5000' ($gt -join ',') 'retry resumes at the last Id, not from scratch'
}

Invoke-SsmTest 'Invoke-SiteScan: items enumeration that fails on the first page is incomplete, not a clean 0-item library' {
    . $script:DefineScanStubs
    $script:Sim.RestFail.Add(@{ Match = "$script:LibAItems"; Remaining = 99 })
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    $gt = @($script:Sim.ItemUrls | ForEach-Object { [regex]::Match($_, 'Id%20gt%20(\d+)').Groups[1].Value })
    Assert-Equal '0,0,0' ($gt -join ',') 'bounded: 3 attempts'
    Assert-Equal 1 $out.Count 'Library B is still scanned'
    Assert-Equal 1 $t.LibrariesScanned 'the failed library is not counted as scanned'
    $parts = @($t['IncompleteParts'])
    Assert-Equal 1 $parts.Count
    if ($parts[0] -notlike '*Library A*') { throw "incomplete part does not name the library: $($parts[0])" }
    if (@($script:Sim.Log | Where-Object { $_ -match '^\[(WARN|ERROR)\]' -and $_ -match 'Library A' }).Count -lt 1) { throw "no WARN/ERROR line names the library: $($script:Sim.Log -join ' / ')" }
    $clean = @($script:Sim.Log | Where-Object { $_ -match "0 scanned, 0 with unique permissions in 'Library A'" })
    Assert-Equal 0 $clean.Count 'must not log a clean-looking 0 scanned result for a library that was never read'
}

Invoke-SsmTest 'Invoke-SiteScan: failure on a later page keeps the findings read so far and marks the library incomplete' {
    . $script:DefineScanStubs
    Set-ScanSimBigLibrary
    $script:Sim.RestFail.Add(@{ Match = "$script:LibAItems.*Id%20gt%205000"; Remaining = 99 })
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 2 $out.Count 'item 2 of Library A (page 1) and item 1 of Library B'
    Assert-Equal 1 $t.LibrariesScanned
    Assert-Equal 5001 $t.ItemsScanned 'the 5000 items of page 1 plus Library B'
    Assert-Equal 1 @($t['IncompleteParts']).Count
}

Invoke-SsmTest 'Invoke-SiteScan: library-level permission read that keeps failing is flagged, enumeration still runs' {
    . $script:DefineScanStubs
    $script:Sim.RestFail.Add(@{ Match = "$script:LibARoot.*HasUniqueRoleAssignments"; Remaining = 99 })
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink', 'EEEU'))
    Assert-Equal 2 $t.LibrariesScanned
    Assert-Equal 1 @($t['IncompleteParts']).Count
    if (@($t['IncompleteParts'])[0] -notlike '*Library A*') { throw "not named: $(@($t['IncompleteParts'])[0])" }
    Assert-Equal 3 $out.Count 'two links plus the item-level EEEU grant are still found'
}

Invoke-SsmTest 'Invoke-SiteScan: web-level permission read that keeps failing is flagged' {
    . $script:DefineScanStubs
    $script:Sim.RestFail.Add(@{ Match = '/_api/web\?'; Remaining = 99 })
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    [void](Invoke-SiteScan -Target $t -Categories @('EEEU'))
    Assert-Equal 1 @($t['IncompleteParts']).Count
    if (@($t['IncompleteParts'])[0] -notlike '*site*') { throw "unexpected part: $(@($t['IncompleteParts'])[0])" }
}

Invoke-SsmTest 'Invoke-SiteScan: item grant read that fails once is retried; one that keeps failing marks the target incomplete' {
    . $script:DefineScanStubs
    $item2 = "$script:LibAItems".Replace('/items\?', '/items\(2\)/roleassignments')
    $cats = @('AnonymousLink', 'EEEU')
    $ref = @(Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories $cats)
    Assert-Equal 3 $ref.Count 'link + EEEU grant on A2, link on B1'

    $script:Sim.RestFail.Add(@{ Match = $item2; Remaining = 1 })
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories $cats)
    Assert-Equal 3 $out.Count
    Assert-Equal 0 @($t['IncompleteParts']).Count

    $script:Sim.RestFail[0].Remaining = 99
    $t2 = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out2 = @(Invoke-SiteScan -Target $t2 -Categories $cats)
    Assert-Equal 1 @($t2['IncompleteParts']).Count
    if (@($t2['IncompleteParts'])[0] -notlike '*Library A*') { throw "not named: $(@($t2['IncompleteParts'])[0])" }
    if (@($out2 | Where-Object { $_.RemovalKind -eq 'DirectGrant' }).Count -ne 0) { throw 'grant must be missing when its read failed' }
}

Invoke-SsmTest 'Complete-SiteScan: the incomplete summary lists at most 5 parts' {
    . $script:DefineScanStubs
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    1..8 | ForEach-Object { $t['IncompleteParts'].Add("part $_") }
    [void](Complete-SiteScan -Target $t -Bag ([System.Collections.Generic.List[object]]::new()) -TotalItems 0 -LibCount 0 -FileCount 0)
    $line = @($script:Sim.Log | Where-Object { $_ -match 'INCOMPLETE' })
    Assert-Equal 1 $line.Count
    if ($line[0] -notmatch 'part 5' -or $line[0] -match 'part 6' -or $line[0] -notmatch '\+3 more') { throw "unexpected summary: $($line[0])" }
}

# --- Sharing-link read failures (per item) -----------------------------------
if (-not ('SsmTestServiceException' -as [type])) {
    Add-Type -TypeDefinition @"
public class SsmTestServiceError { public int HttpResponseCode { get; set; } }
public class SsmTestServiceException : System.Exception {
    public SsmTestServiceError Error { get; set; }
    public SsmTestServiceException(string message, int code) : base(message) { Error = new SsmTestServiceError { HttpResponseCode = code }; }
}
public class SsmTestHttpException : System.Exception {
    public System.Net.HttpStatusCode? StatusCode { get; set; }
    public SsmTestHttpException(string message, System.Net.HttpStatusCode code) : base(message) { StatusCode = code; }
}
"@
}

Invoke-SsmTest 'Test-SsmItemGone: only a 404 is "item gone" (PnP Core service error, HttpClient status, or wrapped)' {
    $caught = { param([scriptblock]$Throw) try { & $Throw } catch { $_ } }
    Assert-Equal $true  (Test-SsmItemGone (& $caught { throw [SsmTestServiceException]::new('Microsoft Graph service exception', 404) }))
    Assert-Equal $true  (Test-SsmItemGone (& $caught { throw [SsmTestHttpException]::new('Not found', [System.Net.HttpStatusCode]::NotFound) }))
    Assert-Equal $true  (Test-SsmItemGone (& $caught { throw [System.AggregateException]::new('wrapper', [SsmTestServiceException]::new('inner', 404)) }))
    Assert-Equal $false (Test-SsmItemGone (& $caught { throw [SsmTestServiceException]::new('Microsoft Graph service exception', 403) }))
    Assert-Equal $false (Test-SsmItemGone (& $caught { throw [SsmTestServiceException]::new('Microsoft Graph service exception', 429) }))
    Assert-Equal $false (Test-SsmItemGone (& $caught { throw [SsmTestHttpException]::new('Timeout', [System.Net.HttpStatusCode]::RequestTimeout) }))
    Assert-Equal $false (Test-SsmItemGone (& $caught { throw 'The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing.' }))
}

Invoke-SsmTest 'Invoke-SiteScan: a sharing-link read that fails once is retried and gives the same findings' {
    . $script:DefineScanStubs
    $ref = @(Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories @('AnonymousLink'))
    $script:Sim.LinkCalls.Clear()
    $script:Sim.LinkFail['/sites/x/a2.docx'] = @{ Remaining = 1; Make = { [SsmTestServiceException]::new('Microsoft Graph service exception', 503) } }
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 2 $ref.Count
    Assert-Equal (($ref | ForEach-Object { "$($_.Name)" } | Sort-Object) -join ',') (($out | ForEach-Object { "$($_.Name)" } | Sort-Object) -join ',')
    Assert-Equal 0 @($t['IncompleteParts']).Count
    Assert-Equal 2 $script:Sim.LinkCalls['/sites/x/a2.docx']
}

Invoke-SsmTest 'Invoke-SiteScan: a sharing-link read that keeps failing marks the target incomplete and logs the item id, not the file name' {
    . $script:DefineScanStubs
    $script:Sim.LinkFail['/sites/x/a2.docx'] = @{ Remaining = 99; Make = { [SsmTestServiceException]::new('Microsoft Graph service exception', 403) } }
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 3 $script:Sim.LinkCalls['/sites/x/a2.docx'] 'bounded: 3 attempts'
    Assert-Equal 1 $out.Count 'the unaffected item in Library B is still reported'
    $parts = @($t['IncompleteParts'])
    Assert-Equal 1 $parts.Count
    if ($parts[0] -notlike '*sharing links*' -or $parts[0] -notlike '*2*' -or $parts[0] -notlike '*Library A*') { throw "unexpected part: $($parts[0])" }
    $errs = @($script:Sim.Log | Where-Object { $_ -match '^\[(WARN|ERROR)\]' -and $_ -match 'item 2' })
    if ($errs.Count -lt 1) { throw "no WARN/ERROR line with the item id: $($script:Sim.Log -join ' / ')" }
    if (@($script:Sim.Log | Where-Object { $_ -match 'a2\.docx' }).Count -ne 0) { throw 'the file name must not be logged' }
}

Invoke-SsmTest 'Invoke-SiteScan: a unique folder whose sharing-link read keeps failing is incomplete too' {
    . $script:DefineScanStubs
    $script:Sim.Items['Library A'] = @((New-ScanItem 1 'folder1' $true 1))
    $script:Sim.LinkFail['/sites/x/folder1'] = @{ Remaining = 99; Make = { [SsmTestServiceException]::new('Microsoft Graph service exception', 500) } }
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    [void](Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 3 $script:Sim.LinkCalls['/sites/x/folder1']
    Assert-Equal 1 @($t['IncompleteParts']).Count
}

Invoke-SsmTest 'Invoke-SiteScan: an item deleted during the scan (404) is skipped without retry or incomplete mark, logged by id' {
    . $script:DefineScanStubs
    $script:Sim.LinkFail['/sites/x/a2.docx'] = @{ Remaining = 99; Make = { [SsmTestServiceException]::new('Microsoft Graph service exception', 404) } }
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 1 $script:Sim.LinkCalls['/sites/x/a2.docx'] 'a 404 is not retried'
    Assert-Equal 0 @($t['IncompleteParts']).Count
    Assert-Equal 1 $out.Count
    if (@($script:Sim.Log | Where-Object { $_ -match '^\[WARN\]' -and $_ -match 'item 2' -and $_ -match '404|no longer exists' }).Count -ne 1) { throw "expected exactly one WARN line for the gone item: $($script:Sim.Log -join ' / ')" }
    if (@($script:Sim.Log | Where-Object { $_ -match 'a2\.docx' }).Count -ne 0) { throw 'the file name must not be logged' }
}

Invoke-SsmTest 'Invoke-SiteScan: many failing sharing-link reads in one library give one short incomplete part' {
    . $script:DefineScanStubs
    $script:Sim.Items['Library A'] = @(1..8 | ForEach-Object { New-ScanItem $_ "a$_.docx" $true })
    foreach ($i in 1..8) { $script:Sim.LinkFail["/sites/x/a$i.docx"] = @{ Remaining = 99; Make = { [SsmTestServiceException]::new('Microsoft Graph service exception', 500) } } }
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    [void](Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    $parts = @($t['IncompleteParts'])
    Assert-Equal 1 $parts.Count
    if ($parts[0] -notmatch '8 items') { throw "count missing: $($parts[0])" }
    if ($parts[0] -notmatch 'first: 1, 2, 3' -or $parts[0] -match '\b4\b') { throw "id list not capped at 3: $($parts[0])" }
}
