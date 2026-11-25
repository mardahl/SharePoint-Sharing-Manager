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
        if ($Url -match "/lists\(guid'0{8}-0{4}-0{4}-0{4}-(\d{12})'\)/items\?") {
            $title = $script:Sim.Libs[[int]$Matches[1] - 1]
            $last = [int][regex]::Match($Url, 'Id%20gt%20(\d+)').Groups[1].Value
            return [pscustomobject]@{ value = @($script:Sim.Items[$title] | Where-Object { $_.Id -gt $last } | Select-Object -First 5000) }
        }
        if ($Url -match 'HasUniqueRoleAssignments') { return [pscustomobject]@{ HasUniqueRoleAssignments = $false } }
        return [pscustomobject]@{ value = @() }
    }
    function Get-PnPFileSharingLink { [CmdletBinding()] param($Identity)
        $null = $Identity
        @([pscustomobject]@{ Id = 'lnk'; Link = [pscustomobject]@{ Scope = 'anonymous'; Type = 'View'; WebUrl = 'https://contoso.sharepoint.com/s/x' } }) }
    function Get-PnPFolderSharingLink { [CmdletBinding()] param($Folder) $null = $Folder; @() }
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
