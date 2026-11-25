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
# call log. Default scenario: two document libraries, 'Library A' (item 2
# carries an anonymous link) and 'Library B' (item 1 carries an anonymous
# link). Tests add lists with Add-SimList.
#
# The REST stub is table driven: Sim.Routes entries @{ Match = <regex on the
# URL>; Respond = <scriptblock returning the response> | Throw = <message>;
# Remaining = <n, optional>; Calls = 0 } are consulted first. Sim.Calls logs
# every CSOM-style cmdlet and REST call in order.
#
# Bulk reads: the site is answered by /_api/web?$select=Url,Title,... and the
# lists by /_api/web/lists?... (paged by Sim.BulkPageSize). Use-LegacyScan opens
# the circuit breakers so the engine takes exactly the per-call path it used
# before the bulk reads existed.
$script:DefineScanStubs = {
    if (-not (Get-Variable -Name RuleCategories -Scope Script -ErrorAction SilentlyContinue)) {
        $script:RuleCategories = [ordered]@{ AnonymousLink = 'Anonymous link'; OrgLink = 'Organization link'; GuestLink = 'Guest link'; GuestGrant = 'Guest grant'; EEEU = 'EEEU grant'; Everyone = 'Everyone grant' }
    }
    if (-not (Get-Variable -Name ExcludedUrlNames -Scope Script -ErrorAction SilentlyContinue)) {
        $script:ExcludedUrlNames = @('SiteAssets', 'SitePages')
    }
    $script:SsmBulkFailures = @{}
    function New-ScanItem { param([int]$Id, [string]$Leaf, [bool]$Unique = $false, [int]$Type = 0)
        [pscustomobject]@{ Id = $Id; FileRef = "/sites/x/$Leaf"; FileLeafRef = $Leaf; FSObjType = $Type; HasUniqueRoleAssignments = $Unique } }
    $script:Sim = @{
        Lists     = [System.Collections.Generic.List[object]]::new()
        Items     = @{
            'Library A' = @((New-ScanItem 1 'a1.docx'), (New-ScanItem 2 'a2.docx' $true), (New-ScanItem 3 'folder' $false 1))
            'Library B' = @((New-ScanItem 1 'b1.docx' $true))
        }
        Routes    = [System.Collections.Generic.List[object]]::new()
        Calls     = [System.Collections.Generic.List[string]]::new()
        BulkPageSize = 100
        BulkOff   = $false   # the lists bulk read returns an unusable answer
        WebBulkOff = $false  # the web bulk read returns an unusable answer
        WebOmit   = @()      # properties left out of the web bulk answer
        WebUnique = $false   # the site has its own permissions (one EEEU grant)
        RootFail  = @{}      # library title -> number of root-folder reads that still fail
        RestFail  = [System.Collections.Generic.List[object]]::new()   # @{ Match = <regex on the URL>; Remaining = <n> }: throws while Remaining > 0
        ItemUrls  = [System.Collections.Generic.List[string]]::new()   # every items-page request of Library A
        LinkFail  = @{}      # item FileRef -> @{ Remaining = <n>; Make = <scriptblock returning the exception to throw> }
        LinkCalls = @{}      # item FileRef -> number of sharing-link reads
        CountFail = 0        # number of ItemCount reads that still fail
        LibAUnique = $false  # Library A has its own permissions, with one EEEU grant
        RootCalls = @{ 'Library A' = 0; 'Library B' = 0 }
        Sleeps    = [System.Collections.Generic.List[object]]::new()
        Log       = [System.Collections.Generic.List[string]]::new()
    }
    function Add-SimList { param([string]$Title, [string]$BaseType = 'DocumentLibrary', [bool]$Hidden = $false, [string[]]$Omit = @(), [string]$Root = '')
        $n = $script:Sim.Lists.Count + 1
        $script:Sim.Lists.Add([pscustomobject]@{ Title = $Title; Id = ("00000000-0000-0000-0000-{0:D12}" -f $n); BaseType = $BaseType; Hidden = $Hidden
            Root = $(if ($Root) { $Root } else { "/sites/x/$Title" }); Omit = $Omit })
    }
    Add-SimList 'Library A'
    Add-SimList 'Library B'
    function Get-SimList { param([string]$Url) $script:Sim.Lists[[int][regex]::Match($Url, "guid'0{8}-0{4}-0{4}-0{4}-(\d{12})'").Groups[1].Value - 1] }
    function Get-SimListUnique { param($List) return ($List.Title -eq 'Library A' -and $script:Sim.LibAUnique) }
    function Use-LegacyScan { $script:SsmBulkFailures = @{ Web = 3; Lists = 3 } }
    function New-SimGrant { param([int]$PrincipalId)
        [pscustomobject]@{ PrincipalId = $PrincipalId
            Member = [pscustomobject]@{ LoginName = 'c:0-.f|rolemanager|spo-grid-all-users/00000000-0000-0000-0000-000000000000'; Title = 'Everyone except external users' }
            RoleDefinitionBindings = @([pscustomobject]@{ Name = 'Read'; RoleTypeKind = 2 }) } }
    function Wait-SsmRetry { param([int]$Seconds) $script:Sim.Sleeps.Add($Seconds) }
    function Write-SsmLog { param([string]$Message, [string]$Level = 'INFO') $script:Sim.Log.Add("[$Level] $Message") }
    function Write-SsmErrorLog { param([string]$Context, $ErrorRecord) $script:Sim.Log.Add("[ERROR] $Context | $($ErrorRecord.Exception.Message)") }
    function Get-PnPWeb { $script:Sim.Calls.Add('CSOM Get-PnPWeb'); [pscustomobject]@{ Url = 'https://contoso.sharepoint.com/sites/x'; Title = 'Site X' } }
    function Get-PnPList { param($Identity)
        if ($Identity) {
            $script:Sim.Calls.Add("CSOM Get-PnPList -Identity $Identity")
            $l = @($script:Sim.Lists | Where-Object { $_.Id -eq "$Identity" })[0]
            if ($l) { return [pscustomobject]@{ Title = $l.Title; Id = [guid]$l.Id; BaseType = $l.BaseType; Hidden = $l.Hidden } }
            return
        }
        $script:Sim.Calls.Add('CSOM Get-PnPList')
        foreach ($l in $script:Sim.Lists) { [pscustomobject]@{ Title = $l.Title; Id = [guid]$l.Id; BaseType = $l.BaseType; Hidden = $l.Hidden } }
    }
    function Get-PnPProperty { param($ClientObject, $Property)
        $title = $ClientObject.Title
        if ($Property -eq 'RootFolder') {
            $script:Sim.Calls.Add("CSOM RootFolder $title")
            $script:Sim.RootCalls[$title] = 1 + [int]$script:Sim.RootCalls[$title]
            if ($script:Sim.RootFail.ContainsKey($title) -and $script:Sim.RootFail[$title] -gt 0) {
                $script:Sim.RootFail[$title]--
                throw 'The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing.'
            }
            $l = @($script:Sim.Lists | Where-Object { $_.Title -eq $title })[0]
            return [pscustomobject]@{ ServerRelativeUrl = $l.Root }
        }
        if ($Property -eq 'ItemCount') {
            $script:Sim.Calls.Add("CSOM ItemCount $title")
            if ($script:Sim.CountFail -gt 0) { $script:Sim.CountFail--; throw 'The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing.' }
            return 1000
        }
    }
    function Invoke-PnPSPRestMethod { param($Url, $Method)
        $null = $Method
        $script:Sim.Calls.Add("REST $Url")
        foreach ($route in $script:Sim.Routes) {
            if ($Url -match $route.Match -and ($null -eq $route.Remaining -or $route.Remaining -gt 0)) {
                $route.Calls++
                if ($null -ne $route.Remaining) { $route.Remaining-- }
                if ($route.Throw) { throw $route.Throw }
                return (& $route.Respond)
            }
        }
        if ($Url -match "guid'0{8}-0{4}-0{4}-0{4}-0{11}1'\)/items\?") { $script:Sim.ItemUrls.Add($Url) }
        foreach ($rule in $script:Sim.RestFail) {
            if ($rule.Remaining -gt 0 -and $Url -match $rule.Match) {
                $rule.Remaining--
                throw 'One or more errors occurred. (Error while copying content to a stream.)'
            }
        }
        # bulk site read
        if ($Url -match '^/_api/web\?') {
            if ($script:Sim.WebBulkOff) { return [pscustomobject]@{} }
            $w = [ordered]@{ Url = 'https://contoso.sharepoint.com/sites/x'; Title = 'Site X'; HasUniqueRoleAssignments = $script:Sim.WebUnique }
            foreach ($p in $script:Sim.WebOmit) { $w.Remove($p) }
            return [pscustomobject]$w
        }
        if ($Url -match '^https://.*/_api/web\?\$select=HasUniqueRoleAssignments') { return [pscustomobject]@{ HasUniqueRoleAssignments = $script:Sim.WebUnique } }
        if ($Url -match '/_api/web/roleassignments\?') { return [pscustomobject]@{ value = @((New-SimGrant 5)) } }
        # bulk lists read (paged)
        if ($Url -match '/_api/web/lists\?') {
            if ($script:Sim.BulkOff) { return [pscustomobject]@{} }
            $skip = [int][regex]::Match($Url, 'skiptoken=(\d+)').Groups[1].Value
            $all = @($script:Sim.Lists)
            $rows = @($all | Select-Object -Skip $skip -First $script:Sim.BulkPageSize | ForEach-Object {
                $o = [ordered]@{ Id = $_.Id; Title = $_.Title; BaseType = $(if ($_.BaseType -eq 'DocumentLibrary') { 1 } else { 0 }); Hidden = $_.Hidden
                    ItemCount = 1000; HasUniqueRoleAssignments = (Get-SimListUnique $_); RootFolder = [pscustomobject]@{ ServerRelativeUrl = $_.Root } }
                foreach ($p in $_.Omit) { $o.Remove($p) }
                [pscustomobject]$o })
            $resp = [ordered]@{ value = $rows }
            if ($skip + $rows.Count -lt $all.Count) { $resp['odata.nextLink'] = 'https://contoso.sharepoint.com/sites/x/_api/web/lists?$skiptoken=' + ($skip + $rows.Count) }
            return [pscustomobject]$resp
        }
        if ($Url -match "/lists\(guid'0{8}-0{4}-0{4}-0{4}-\d{12}'\)\?.*HasUniqueRoleAssignments") {
            return [pscustomobject]@{ HasUniqueRoleAssignments = (Get-SimListUnique (Get-SimList $Url)) }
        }
        if ($Url -match "/lists\(guid'0{8}-0{4}-0{4}-0{4}-\d{12}'\)/roleassignments\?") { return [pscustomobject]@{ value = @((New-SimGrant 8)) } }
        if ($Url -match "guid'0{8}-0{4}-0{4}-0{4}-0{11}1'\)/items\(2\)/roleassignments") { return [pscustomobject]@{ value = @((New-SimGrant 7)) } }
        if ($Url -match "/lists\(guid'0{8}-0{4}-0{4}-0{4}-\d{12}'\)/items\?") {
            $title = (Get-SimList $Url).Title
            $last = [int][regex]::Match($Url, 'Id%20gt%20(\d+)').Groups[1].Value
            return [pscustomobject]@{ value = @($script:Sim.Items[$title] | Where-Object { $_.Id -gt $last } | Select-Object -First 5000) }
        }
        if ($Url -match 'HasUniqueRoleAssignments') { return [pscustomobject]@{ HasUniqueRoleAssignments = $false } }
        return [pscustomobject]@{ value = @() }
    }
    function Invoke-SimLinkRead { param([string]$Path)
        $script:Sim.Calls.Add("LINKS $Path")
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
    Use-LegacyScan   # exercises the per-call reads, which are also the fallback of the bulk reads
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
    Use-LegacyScan   # exercises the per-call reads, which are also the fallback of the bulk reads
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
    Use-LegacyScan   # exercises the per-call reads, which are also the fallback of the bulk reads
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

# --- ItemCount (Reach of library-level findings) ------------------------------
Invoke-SsmTest 'Invoke-SiteScan: an ItemCount read that fails once is retried and sets the library finding Reach' {
    . $script:DefineScanStubs
    Use-LegacyScan   # exercises the per-call reads, which are also the fallback of the bulk reads
    $script:Sim.LibAUnique = $true
    $script:Sim.CountFail = 1
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('EEEU'))
    $lib = @($out | Where-Object { $_.Location -eq 'Library' })
    Assert-Equal 1 $lib.Count
    Assert-Equal 1000 $lib[0].Reach
    Assert-Equal 0 @($t['IncompleteParts']).Count
}

Invoke-SsmTest 'Invoke-SiteScan: when ItemCount keeps failing the library finding gets the scanned item count, not 0, and the failure is logged' {
    . $script:DefineScanStubs
    Use-LegacyScan   # exercises the per-call reads, which are also the fallback of the bulk reads
    $script:Sim.LibAUnique = $true
    $script:Sim.CountFail = 99
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('EEEU'))
    $lib = @($out | Where-Object { $_.Location -eq 'Library' })
    Assert-Equal 1 $lib.Count
    Assert-Equal 3 $lib[0].Reach 'Library A has 3 items'
    if (@($script:Sim.Log | Where-Object { $_ -match '^\[WARN\]' -and $_ -match 'Library A' -and $_ -match 'item count' }).Count -lt 1) { throw "no WARN line: $($script:Sim.Log -join ' / ')" }
}

# --- Scan statistics (Phase 0: measurement only) -------------------------------
Invoke-SsmTest 'Scan stats: every network read is counted by kind, with failed attempts and retries included' {
    . $script:DefineScanStubs
    Use-LegacyScan   # exercises the per-call reads, which are also the fallback of the bulk reads
    Start-SsmScanStats
    $script:Sim.LinkFail['/sites/x/a2.docx'] = @{ Remaining = 1; Make = { [SsmTestServiceException]::new('Microsoft Graph service exception', 503) } }
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    [void](Invoke-SiteScan -Target $t -Categories @('AnonymousLink', 'EEEU'))
    $k = $script:ScanStats.Kinds
    Assert-Equal 1 $k['Web'].Count
    Assert-Equal 1 $k['Lists'].Count
    Assert-Equal 2 $k['LibRoot'].Count
    Assert-Equal 2 $k['ItemCount'].Count
    Assert-Equal 2 $k['ItemsPage'].Count
    Assert-Equal 3 $k['Links'].Count 'two unique items, one of them retried once'
    Assert-Equal 1 $k['Links'].Failed
    Assert-Equal 3 $k['PermState'].Count 'web plus two libraries'
    Assert-Equal 2 $k['Grants'].Count 'item-level role assignments of the two unique items'
}

Invoke-SsmTest 'Scan stats: totals and max durations are recorded per kind' {
    Start-SsmScanStats
    Add-SsmScanStat -Kind 'ItemsPage' -Seconds 0.5 -Failed $false
    Add-SsmScanStat -Kind 'ItemsPage' -Seconds 1.5 -Failed $true
    $p = $script:ScanStats.Kinds['ItemsPage']
    Assert-Equal 2 $p.Count
    Assert-Equal 1 $p.Failed
    Assert-Equal 2 $p.Total
    Assert-Equal 1.5 $p.Max
    $script:ScanStats = $null
    Add-SsmScanStat -Kind 'ItemsPage' -Seconds 1 -Failed $false   # not started: must be a harmless no-op
}

Invoke-SsmTest 'Scan stats: one INFO line with per-kind count, total, average and requests per second, without URLs or titles' {
    . $script:DefineScanStubs
    Use-LegacyScan   # exercises the per-call reads, which are also the fallback of the bulk reads
    Start-SsmScanStats
    [void](Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories @('AnonymousLink'))
    $script:Sim.Log.Clear()
    Write-SsmScanStats -Targets 1
    $lines = @($script:Sim.Log | Where-Object { $_ -match 'Scan stats' })
    Assert-Equal 1 $script:Sim.Log.Count
    Assert-Equal 1 $lines.Count
    $line = $lines[0]
    if ($line -notmatch '^\[INFO\]') { throw "not INFO: $line" }
    foreach ($needle in 'ItemsPage 2 calls', 'LibRoot 2 calls', 'Web 1 call', 'req/s', '1 target', 'avg') { if ($line -notmatch [regex]::Escape($needle)) { throw "missing [$needle]: $line" } }
    foreach ($bad in 'http', 'contoso', 'sites/x', 'Library A', 'Library B', 'Site X', '_api') { if ($line -match [regex]::Escape($bad)) { throw "line leaks [$bad]: $line" } }
    Assert-Equal $true ($null -eq $script:ScanStats) 'stats are reset after they are written'
}

Invoke-SsmTest 'Scan stats: Invoke-TabScan writes exactly one stats line per run' {
    function Connect-SsmSite { param($Url) $null = $Url; $true }
    function Write-Screen { }
    function Start-LoadSpinner { }
    function Stop-LoadSpinner { }
    function Write-ProgressModal { }
    function New-SsmProgressCallback { param($Title, $State, $CancelMode) $null = $Title, $State, $CancelMode; { } }
    function Save-SsmCache { param([switch]$Throttle) $null = $Throttle }
    $script:StatLog = [System.Collections.Generic.List[string]]::new()
    function Write-SsmLog { param([string]$Message, [string]$Level = 'INFO') $script:StatLog.Add("[$Level] $Message") }
    function Invoke-SiteScan { param($Target, $Categories, $Progress)
        $null = $Categories, $Progress
        $Target['IncompleteParts'] = [System.Collections.Generic.List[string]]::new()
        [void](Invoke-SsmRetry -Kind 'Web' -MaxAttempts 1 -Action { 1 })
        return @()
    }
    $a = New-Target -Url 'https://x/sites/a'; $a.Selected = $true
    $b = New-Target -Url 'https://x/sites/b'; $b.Selected = $true
    $tab = @{ Items = @($a, $b); Categories = @('AnonymousLink'); Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0; View = @() }
    Invoke-TabScan -Tab $tab
    $lines = @($script:StatLog | Where-Object { $_ -match 'Scan stats' })
    Assert-Equal 1 $lines.Count
    if ($lines[0] -notmatch 'Web 2 calls' -or $lines[0] -notmatch '2 targets') { throw "unexpected: $($lines[0])" }
}

# --- Bulk site and lists reads (Phase 1) ----------------------------------------
# Rich site: an excluded system library, a hidden document library, a generic
# list, a library whose items page keeps failing, a library with two pages of
# items, and a 404 item.
$script:DefineRichScenario = {
    Add-SimList 'SiteAssets'
    Add-SimList 'Hidden Lib' -Hidden $true
    Add-SimList 'Tasks' -BaseType 'GenericList'
    Add-SimList 'Library C'
    Add-SimList 'Library D'
    $script:Sim.Items['SiteAssets'] = @((New-ScanItem 1 'sa.docx' $true))
    $script:Sim.Items['Hidden Lib'] = @((New-ScanItem 1 'h.docx' $true))
    $script:Sim.Items['Tasks'] = @((New-ScanItem 1 't' $true))
    $script:Sim.Items['Library C'] = @((New-ScanItem 1 'c1.docx' $true))
    $script:Sim.Items['Library D'] = @(1..5001 | ForEach-Object { New-ScanItem $_ "d$_.docx" ($_ -eq 5001) })
    $script:Sim.Items['Library B'] = @((New-ScanItem 1 'b1.docx' $true), (New-ScanItem 2 'b2.docx' $true))
    $script:Sim.LibAUnique = $true
    $script:Sim.LinkFail['/sites/x/b2.docx'] = @{ Remaining = 99; Make = { [SsmTestServiceException]::new('Microsoft Graph service exception', 404) } }
    $script:Sim.RestFail.Add(@{ Match = "guid'00000000-0000-0000-0000-000000000006'\)/items\?"; Remaining = 99 })
}

function ConvertTo-ScanFingerprint {
    param($Findings)
    (@($Findings) | Sort-Object Name, CategoryKey, Location | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}' -f $_.Site, $_.Location, $_.Name, $_.CategoryKey, $_.Category, $_.Access, $_.Principal, $_.Path, $_.RemovalKind, $_.LinkId, $_.ListId, $_.ItemId, $_.Reach
    }) -join "`n"
}

Invoke-SsmTest 'Bulk reads: identical findings, counts and incomplete marks as the per-call path on a multi-library site' {
    . $script:DefineScanStubs
    . $script:DefineRichScenario
    $cats = @('AnonymousLink', 'EEEU')
    Use-LegacyScan
    $old = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $oldOut = @(Invoke-SiteScan -Target $old -Categories $cats)
    $script:SsmBulkFailures = @{}
    $script:Sim.Calls.Clear()
    $new = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $newOut = @(Invoke-SiteScan -Target $new -Categories $cats)

    Assert-Equal 5 $oldOut.Count 'library grant + A2 link + A2 grant + B1 link + D5001 link'
    Assert-Equal (ConvertTo-ScanFingerprint $oldOut) (ConvertTo-ScanFingerprint $newOut)
    foreach ($n in 'sa.docx', 'h.docx', 't', 'c1.docx', 'b2.docx') { if (@($newOut | Where-Object { $_.Name -eq $n }).Count -ne 0) { throw "unexpected finding for $n" } }
    Assert-Equal 3 $new.LibrariesScanned 'A, B and D; C failed, the rest are excluded, hidden or not libraries'
    Assert-Equal 5006 $new.ItemsScanned
    Assert-Equal 5005 $new.FilesScanned
    foreach ($p in 'LibrariesScanned', 'ItemsScanned', 'FilesScanned') { Assert-Equal $old[$p] $new[$p] $p }
    Assert-Equal (@($old['IncompleteParts']) -join '|') (@($new['IncompleteParts']) -join '|')
    Assert-Equal 1 @($new['IncompleteParts']).Count
    if (@($new['IncompleteParts'])[0] -notlike '*Library C*') { throw "unexpected part: $(@($new['IncompleteParts'])[0])" }
    $lib = @($newOut | Where-Object { $_.Location -eq 'Library' })
    Assert-Equal 1 $lib.Count
    Assert-Equal 1000 $lib[0].Reach
}

Invoke-SsmTest 'Bulk reads: call budget per site and per library; excluded libraries cost no call' {
    . $script:DefineScanStubs
    Add-SimList 'SiteAssets'
    Add-SimList 'Hidden Lib' -Hidden $true
    Add-SimList 'Tasks' -BaseType 'GenericList'
    $cats = @('AnonymousLink', 'EEEU')
    $summary = { ($script:ScanStats.Kinds.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $script:ScanStats.Kinds[$_].Count }) -join ';' }
    $libACalls = { @($script:Sim.Calls | Where-Object { ($_ -match "guid'00000000-0000-0000-0000-000000000001'\)" -or $_ -match 'Library A') -and $_ -notmatch '/items\(' -and $_ -notmatch '^LINKS' }).Count }

    Use-LegacyScan
    Start-SsmScanStats
    [void](Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories $cats)
    $before = & $summary
    $beforeLibA = & $libACalls
    $beforeExcluded = @($script:Sim.Calls | Where-Object { $_ -match 'SiteAssets' }).Count
    $script:ScanStats = $null

    $script:SsmBulkFailures = @{}
    $script:Sim.Calls.Clear()
    Start-SsmScanStats
    [void](Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories $cats)
    $after = & $summary
    $afterLibA = & $libACalls
    $afterExcluded = @($script:Sim.Calls | Where-Object { $_ -match 'SiteAssets' -or $_ -match "guid'00000000-0000-0000-0000-000000000003'" }).Count
    $afterTotal = (($script:ScanStats.Kinds.Values | ForEach-Object { $_.Count }) | Measure-Object -Sum).Sum

    Assert-Equal 'Grants=2;ItemCount=2;ItemsPage=2;LibRoot=3;Links=2;Lists=1;PermState=3;Web=1' $before
    Assert-Equal 'Grants=2;ItemsPage=2;Links=2;Lists=1;PermState=1;Web=1' $after
    Assert-Equal 9 $afterTotal 'was 16 reads for this site'
    Assert-Equal 4 $beforeLibA 'root folder + item count + permission state + first items page'
    Assert-Equal 1 $afterLibA 'the first items page only'
    Assert-Equal 1 $beforeExcluded 'the excluded library cost a root-folder read before'
    Assert-Equal 0 $afterExcluded 'and costs no call now'
}

Invoke-SsmTest 'Bulk reads: when the bulk lists read keeps failing the per-call path gives the same findings' {
    . $script:DefineScanStubs
    $ref = @(Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories @('AnonymousLink'))
    Assert-Equal 2 $ref.Count
    $script:SsmBulkFailures = @{}
    $script:Sim.Calls.Clear(); $script:Sim.Sleeps.Clear()
    $script:Sim.RestFail.Add(@{ Match = '/_api/web/lists\?'; Remaining = 99 })
    Start-SsmScanStats
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal (ConvertTo-ScanFingerprint $ref) (ConvertTo-ScanFingerprint $out)
    Assert-Equal 0 @($t['IncompleteParts']).Count
    Assert-Equal 3 @($script:Sim.Calls | Where-Object { $_ -match '/_api/web/lists\?' }).Count 'the bulk read is retried (3 attempts) before falling back'
    Assert-Equal 2 $script:Sim.Sleeps.Count
    Assert-Equal 1 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM Get-PnPList' }).Count
    Assert-Equal 2 $script:ScanStats.Kinds['LibRoot'].Count 'per-library reads are back'
    $script:Sim.Log.Clear()
    Write-SsmScanStats -Targets 1
    if (@($script:Sim.Log | Where-Object { $_ -match 'Scan stats' -and $_ -match 'per-call reads' -and $_ -match 'Lists 1' }).Count -ne 1) { throw "fallback not shown in the stats line: $($script:Sim.Log -join ' / ')" }
}

Invoke-SsmTest 'Bulk reads: a library without a root folder in the bulk answer falls back for that library only and is still scanned' {
    . $script:DefineScanStubs
    $script:Sim.Lists[0].Omit = @('RootFolder')
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 2 $out.Count
    Assert-Equal 2 $t.LibrariesScanned
    Assert-Equal 1 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM RootFolder Library A' }).Count
    Assert-Equal 0 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM RootFolder Library B' }).Count
    Assert-Equal 0 @($t['IncompleteParts']).Count
}

Invoke-SsmTest 'Bulk reads: an excluded library with no root folder in the bulk answer is still found out and skipped' {
    . $script:DefineScanStubs
    Add-SimList 'SiteAssets' -Omit @('RootFolder')
    $script:Sim.Items['SiteAssets'] = @((New-ScanItem 1 'sa.docx' $true))
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 2 $out.Count
    Assert-Equal 1 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM RootFolder SiteAssets' }).Count
    Assert-Equal 0 @($script:Sim.Calls | Where-Object { $_ -match "guid'00000000-0000-0000-0000-000000000003'\)/items" }).Count
}

Invoke-SsmTest 'Bulk reads: a library whose root folder cannot be read at all is incomplete, as before' {
    . $script:DefineScanStubs
    $script:Sim.Lists[0].Omit = @('RootFolder')
    $script:Sim.RootFail['Library A'] = 99
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 1 $out.Count
    Assert-Equal 1 $t.LibrariesScanned
    Assert-Equal 1 @($t['IncompleteParts']).Count
    if (@($t['IncompleteParts'])[0] -notlike '*Library A*') { throw "not named: $(@($t['IncompleteParts'])[0])" }
}

Invoke-SsmTest 'Bulk reads: a library without ItemCount falls back to the item count read; 0 is never assumed' {
    . $script:DefineScanStubs
    $script:Sim.LibAUnique = $true
    $script:Sim.Lists[0].Omit = @('ItemCount')
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('EEEU'))
    Assert-Equal 1 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM ItemCount Library A' }).Count
    Assert-Equal 0 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM ItemCount Library B' }).Count
    $lib = @($out | Where-Object { $_.Location -eq 'Library' })
    Assert-Equal 1 $lib.Count
    Assert-Equal 1000 $lib[0].Reach
}

Invoke-SsmTest 'Bulk reads: a library without HasUniqueRoleAssignments is never treated as inheriting' {
    . $script:DefineScanStubs
    $script:Sim.LibAUnique = $true
    $script:Sim.Lists[0].Omit = @('HasUniqueRoleAssignments')
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('EEEU'))
    $lib = @($out | Where-Object { $_.Location -eq 'Library' })
    Assert-Equal 1 $lib.Count 'the library-level grant is found through the per-library read'
    Assert-Equal 1 @($script:Sim.Calls | Where-Object { $_ -match "guid'00000000-0000-0000-0000-000000000001'\)\?.*HasUniqueRoleAssignments" }).Count
    Assert-Equal 0 @($script:Sim.Calls | Where-Object { $_ -match "guid'00000000-0000-0000-0000-000000000002'\)\?.*HasUniqueRoleAssignments" }).Count
}

Invoke-SsmTest 'Bulk reads: a list without Hidden or BaseType, or an empty answer, makes the whole site fall back' {
    foreach ($omit in 'Hidden', 'BaseType', 'Title', 'Id') {
        . $script:DefineScanStubs
        $script:Sim.Lists[1].Omit = @($omit)
        $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
        $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
        Assert-Equal 2 $out.Count "omit $omit"
        Assert-Equal 1 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM Get-PnPList' }).Count "omit $omit"
        Assert-Equal 2 $t.LibrariesScanned "omit $omit"
    }
    . $script:DefineScanStubs
    $script:Sim.Routes.Add(@{ Match = '/_api/web/lists\?'; Calls = 0; Respond = { [pscustomobject]@{ value = @() } } })
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 2 $out.Count 'empty answer'
    Assert-Equal 1 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM Get-PnPList' }).Count 'empty answer'
}

Invoke-SsmTest 'Bulk reads: paging of the lists answer is followed to the end' {
    . $script:DefineScanStubs
    Add-SimList 'Library C'; Add-SimList 'Library D'; Add-SimList 'Library E'
    $script:Sim.Items['Library C'] = @((New-ScanItem 1 'c1.docx' $true))
    $script:Sim.Items['Library D'] = @((New-ScanItem 1 'd1.docx'))
    $script:Sim.Items['Library E'] = @((New-ScanItem 1 'e1.docx' $true))
    $script:Sim.BulkPageSize = 2
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    $bulk = @($script:Sim.Calls | Where-Object { $_ -match '/_api/web/lists\?' })
    Assert-Equal 3 $bulk.Count
    if ($bulk[1] -notmatch 'skiptoken=2' -or $bulk[2] -notmatch 'skiptoken=4') { throw "next links not followed: $($bulk -join ' / ')" }
    Assert-Equal 5 $t.LibrariesScanned
    Assert-Equal (@('a2.docx', 'b1.docx', 'c1.docx', 'e1.docx') -join ',') (($out | ForEach-Object { $_.Name } | Sort-Object) -join ',')
    Assert-Equal 0 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM Get-PnPList' }).Count
}

Invoke-SsmTest 'Bulk reads: a transient failure of the bulk lists read is retried and no per-library read is needed' {
    . $script:DefineScanStubs
    $script:Sim.RestFail.Add(@{ Match = '/_api/web/lists\?'; Remaining = 1 })
    Start-SsmScanStats
    $t = New-Target -Url 'https://contoso.sharepoint.com/sites/x'
    $out = @(Invoke-SiteScan -Target $t -Categories @('AnonymousLink'))
    Assert-Equal 2 $out.Count
    Assert-Equal 2 @($script:Sim.Calls | Where-Object { $_ -match '/_api/web/lists\?' }).Count
    Assert-Equal 1 $script:Sim.Sleeps.Count
    Assert-Equal 0 @($script:Sim.Calls | Where-Object { $_ -eq 'CSOM Get-PnPList' }).Count
    Assert-Equal $true (-not $script:ScanStats.Kinds.ContainsKey('LibRoot'))
}

Invoke-SsmTest 'Bulk reads: after 3 failed bulk reads in a row (the per-call path then worked) the bulk read is switched off for the run' {
    . $script:DefineScanStubs
    $script:Sim.RestFail.Add(@{ Match = '/_api/web/lists\?'; Remaining = 999 })
    foreach ($i in 1..3) { [void](Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories @('AnonymousLink')) }
    Assert-Equal 9 @($script:Sim.Calls | Where-Object { $_ -match '/_api/web/lists\?' }).Count
    $script:Sim.Calls.Clear()
    $out = @(Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories @('AnonymousLink'))
    Assert-Equal 2 $out.Count
    Assert-Equal 0 @($script:Sim.Calls | Where-Object { $_ -match '/_api/web/lists\?' }).Count 'switched off'
    Assert-Equal 1 @($script:Sim.Log | Where-Object { $_ -match '^\[WARN\]' -and $_ -match 'switched off' }).Count
}

Invoke-SsmTest 'Bulk reads: a success resets the failure count, and a site that fails both ways does not count' {
    . $script:DefineScanStubs
    $fail = @{ Match = '/_api/web/lists\?'; Remaining = 6 }
    $script:Sim.RestFail.Add($fail)
    foreach ($i in 1..2) { [void](Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories @('AnonymousLink')) }   # 2 failures
    $fail.Remaining = 0
    [void](Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories @('AnonymousLink'))                           # success resets
    Assert-Equal 0 ([int]$script:SsmBulkFailures['Lists'])
    $fail.Remaining = 999
    function Get-PnPList { param($Identity) $null = $Identity; throw 'site unreachable' }
    foreach ($i in 1..5) { try { [void](Invoke-SiteScan -Target (New-Target -Url 'https://contoso.sharepoint.com/sites/x') -Categories @('AnonymousLink')) } catch { $null = $_ } }
    Assert-Equal 0 ([int]$script:SsmBulkFailures['Lists']) 'the per-call path failed too, so the bulk read is not to blame'
}
