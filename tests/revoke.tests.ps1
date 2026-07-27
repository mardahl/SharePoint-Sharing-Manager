Invoke-SsmTest 'Revoke order: links first, leaf before web' {
    $f = @(
        [pscustomobject]@{ RemovalKind='DirectGrant'; Location='Web';    Name='w' },
        [pscustomobject]@{ RemovalKind='DirectGrant'; Location='File';   Name='fg' },
        [pscustomobject]@{ RemovalKind='Link';        Location='Folder'; Name='fl' },
        [pscustomobject]@{ RemovalKind='DirectGrant'; Location='Library';Name='lib' },
        [pscustomobject]@{ RemovalKind='Link';        Location='File';   Name='fi' }
    )
    $o = @(Get-RevokeOrder -Findings $f)
    Assert-Equal 'Link' $o[0].RemovalKind
    Assert-Equal 'Link' $o[1].RemovalKind
    Assert-Equal 'fg'  $o[2].Name
    Assert-Equal 'lib' $o[3].Name
    Assert-Equal 'w'   $o[4].Name
}
Invoke-SsmTest 'Group-FindingsBySite groups by Site' {
    $f = @(
        [pscustomobject]@{ Site='https://x/a'; Name='f1' },
        [pscustomobject]@{ Site='https://x/b'; Name='f2' },
        [pscustomobject]@{ Site='https://x/a'; Name='f3' }
    )
    $groups = @(Group-FindingsBySite -Findings $f)
    Assert-Equal 2 $groups.Count
    $a = $groups | Where-Object { $_.Name -eq 'https://x/a' }
    Assert-Equal 2 @($a.Group).Count
}
Invoke-SsmTest 'Get-CommonUrlPrefix: shared OneDrive prefix is factored out' {
    $u = @(
        'https://contoso-my.sharepoint.com/personal/ann_contoso_com',
        'https://contoso-my.sharepoint.com/personal/bob_contoso_com',
        'https://contoso-my.sharepoint.com/personal/cat_contoso_com'
    )
    Assert-Equal 'https://contoso-my.sharepoint.com/personal/' (Get-CommonUrlPrefix -Urls $u)
}
Invoke-SsmTest 'Get-CommonUrlPrefix: prefix is truncated back to a slash boundary' {
    # 'ann' and 'anna' share 'anna'/'ann' mid-segment; only the /personal/ part is usable
    $u = @(
        'https://contoso-my.sharepoint.com/personal/ann_contoso_com',
        'https://contoso-my.sharepoint.com/personal/anna_contoso_com'
    )
    Assert-Equal 'https://contoso-my.sharepoint.com/personal/' (Get-CommonUrlPrefix -Urls $u)
}
Invoke-SsmTest 'Get-CommonUrlPrefix: different hosts share nothing usable' {
    $u = @('https://alpha.example.com/sites/a', 'https://beta.example.org/sites/b')
    Assert-Equal '' (Get-CommonUrlPrefix -Urls $u)
}
Invoke-SsmTest 'Get-CommonUrlPrefix: a single URL yields no prefix' {
    Assert-Equal '' (Get-CommonUrlPrefix -Urls @('https://contoso.sharepoint.com/sites/hr'))
}
Invoke-SsmTest 'Get-CommonUrlPrefix: empty input yields no prefix' {
    Assert-Equal '' (Get-CommonUrlPrefix -Urls @())
}
Invoke-SsmTest 'Get-CommonUrlPrefix: a short shared prefix is rejected' {
    # 'https://a/' is 10 chars, at or below the 16-char floor
    $u = @('https://a/one', 'https://a/two')
    Assert-Equal '' (Get-CommonUrlPrefix -Urls $u)
}
Invoke-SsmTest 'Get-CommonUrlPrefix: identical URLs yield the parent path' {
    $u = @(
        'https://contoso.sharepoint.com/sites/finance',
        'https://contoso.sharepoint.com/sites/finance'
    )
    Assert-Equal 'https://contoso.sharepoint.com/sites/' (Get-CommonUrlPrefix -Urls $u)
}

# Stub the PnP removal cmdlets so Invoke-Revoke can run headless. Defined at
# script scope, these shadow the real PnP.PowerShell commands.
function Remove-PnPFileSharingLink   { param($FileUrl, $Identity, [switch]$Force) }
function Remove-PnPFolderSharingLink { param($Folder, $Identity, [switch]$Force) }

Invoke-SsmTest 'Invoke-Revoke reports progress for every finding' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='c'; Path='/c'; LinkId='3'; RevokeStatus='' }
    )
    $seen = New-Object System.Collections.ArrayList
    $cb = { param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0) [void]$seen.Add($Count) }.GetNewClosure()
    $removed = Invoke-Revoke -Findings $f -Progress $cb
    Assert-Equal 3 $removed
    Assert-Equal 3 $seen.Count
    Assert-Equal '1 2 3' ($seen -join ' ')
}
Invoke-SsmTest 'Invoke-Revoke passes a Total matching the finding count' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' }
    )
    $totals = New-Object System.Collections.ArrayList
    $cb = { param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0) [void]$totals.Add($Total) }.GetNewClosure()
    [void](Invoke-Revoke -Findings $f -Progress $cb)
    Assert-Equal '2 2' ($totals -join ' ')
}
Invoke-SsmTest 'Invoke-Revoke reports a running Ok count' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='c'; Path='/c'; LinkId='3'; RevokeStatus='' }
    )
    $oks = New-Object System.Collections.ArrayList
    $cb = { param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0) [void]$oks.Add($Ok) }.GetNewClosure()
    [void](Invoke-Revoke -Findings $f -Progress $cb)
    # Reported before the current item is attempted: 0 removed, then 1, then 2.
    Assert-Equal '0 1 2' ($oks -join ' ')
}
Invoke-SsmTest 'Invoke-Revoke skips a finding with an empty LinkId and continues' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId=''; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' }
    )
    $removed = Invoke-Revoke -Findings $f
    Assert-Equal 1 $removed
    # Get-RevokeOrder sorts, and Sort-Object gives no stability guarantee, so
    # assert on the end state rather than on per-item ordering.
    Assert-Equal 'Skipped: empty LinkId' ($f | Where-Object { $_.Name -eq 'a' }).RevokeStatus
    Assert-Equal 'Removed' ($f | Where-Object { $_.Name -eq 'b' }).RevokeStatus
}
Invoke-SsmTest 'Invoke-Revoke stops after the current finding when State.Cancel is set' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='c'; Path='/c'; LinkId='3'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='d'; Path='/d'; LinkId='4'; RevokeStatus='' }
    )
    $state = @{ LastTick = 0; Offset = 0; Total = 4; Cancel = $false }
    $cb = { param($Count, $Total = 0, $Label = '', $Ok = 0, $Failed = 0) if ($Count -ge 2) { $state.Cancel = $true } }.GetNewClosure()
    $removed = Invoke-Revoke -Findings $f -Progress $cb -State $state
    # The second item completes, then the loop breaks before the third.
    Assert-Equal 2 $removed
    Assert-Equal 2 @($f | Where-Object { $_.RevokeStatus -eq 'Removed' }).Count
    Assert-Equal 2 @($f | Where-Object { $_.RevokeStatus -eq '' }).Count
}
Invoke-SsmTest 'Invoke-Revoke without -State or -Progress still revokes everything' {
    $f = @(
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='a'; Path='/a'; LinkId='1'; RevokeStatus='' },
        [pscustomobject]@{ RemovalKind='Link'; Location='File'; Name='b'; Path='/b'; LinkId='2'; RevokeStatus='' }
    )
    Assert-Equal 2 (Invoke-Revoke -Findings $f)
}

# Stub the modal/connection layer so the two higher-level revoke entry points
# (Invoke-FindingsRevoke, Invoke-BulkRevoke) can run headless. Defined at
# script scope, these shadow the real 20-modals/30-connections functions.
function Show-TypedConfirmModal { param($Title, $Word, $Lines) return $true }
function Write-ProgressModal    { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
function Start-LoadSpinner      {}
function Stop-LoadSpinner       {}
function Show-ReportModal       { param($Title, $Lines) }
function Show-MsgModal          { param($Title, $Lines, $Kind) }
function Connect-SsmSite        { param($Url) return $true }
function New-SsmProgressCallback { param($Title, $State, $CancelMode) return { param($Count, $Total, $Label, $Ok, $Failed) } }

function New-SsmRevokeTestTab {
    # Minimal Targets tab with one OneDrive target and one pending finding,
    # shaped the way Update-TabView/Update-TabTargetStatuses expect.
    $finding = @{
        Site='https://x/personal/a'; Location='File'; Name='f1'; CategoryKey='OrgLink'
        Category='Organization link'; Access='View'; Principal='People in your organization'
        Path='/a/f1'; RemovalKind='Link'; LinkId='l1'; ListId=$null; ItemId=$null; PrincipalId=$null
        RevokeStatus='NotAttempted'; Selected=$true
    }
    $item = @{
        Url='https://x/personal/a'; Title='a'; Template='SPSPERS'; Status='Findings'; FindingCount=1
        Findings=@($finding); Selected=$true
    }
    return @{
        Kind='Targets'; Name='OneDrives'; Categories=[System.Collections.ArrayList]@('OrgLink')
        Items=@($item); View=@(); Loaded=$true; Cursor=0; Scroll=0; Search=''
        Filter='All'; SortCol='Url'; SortDesc=$false; Mode='Targets'; FTab=$null
    }
}

Invoke-SsmTest 'Invoke-FindingsRevoke persists the revoke to the session cache (regression)' {
    # Bug: the single-target drill-down revoke path updated Status/FindingCount
    # in memory but never called Save-SsmCache, so a later cache restore (or
    # app restart) showed "Findings" again despite a successful revoke.
    $script:Version = '9.9.9'
    $script:CacheDir  = Join-Path ([IO.Path]::GetTempPath()) ("ssmcache-{0}" -f [guid]::NewGuid())
    $script:CacheFile = Join-Path $script:CacheDir 'session.json'
    $script:CacheWarning = 'test-warning'
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssmexport-{0}" -f [guid]::NewGuid())

    $tab = New-SsmRevokeTestTab
    $target = $tab['Items'][0]
    $script:Tabs = @($tab)

    Enter-FindingsMode -Tab $tab -Target $target
    Invoke-FindingsRevoke -Tab $tab
    Assert-Equal 'Revoked' $target.Status   # in-memory: already worked before the fix

    $freshTab = New-SsmRevokeTestTab
    $freshTab['Items'] = @()
    $freshTab['Loaded'] = $false
    $script:Tabs = @($freshTab)
    [void](Restore-SsmCache)

    Assert-Equal 'Revoked' $script:Tabs[0]['Items'][0].Status
    Assert-Equal 0 $script:Tabs[0]['Items'][0].FindingCount

    Remove-Item -LiteralPath $script:CacheDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:ExportDir -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-SsmTest 'Invoke-BulkRevoke saves the cache with the recomputed Status, not a stale one (regression)' {
    # Bug: Save-SsmCache ran per-site inside the loop, before the post-loop
    # Update-TabTargetStatuses recomputed Status/FindingCount, and nothing
    # saved again afterward - the on-disk cache stayed "Findings" forever.
    $script:Version = '9.9.9'
    $script:CacheDir  = Join-Path ([IO.Path]::GetTempPath()) ("ssmcache-{0}" -f [guid]::NewGuid())
    $script:CacheFile = Join-Path $script:CacheDir 'session.json'
    $script:CacheWarning = 'test-warning'
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssmexport-{0}" -f [guid]::NewGuid())

    $tab = New-SsmRevokeTestTab
    $target = $tab['Items'][0]
    $script:Tabs = @($tab)

    Invoke-BulkRevoke -Findings @($target.Findings) -Tab $tab
    Assert-Equal 'Revoked' $target.Status   # in-memory: already worked before the fix

    $onDisk = Get-Content -LiteralPath $script:CacheFile -Raw | ConvertFrom-Json
    Assert-Equal 'Revoked' $onDisk.Tabs[0].Items[0].Status
    Assert-Equal 0 $onDisk.Tabs[0].Items[0].FindingCount

    Remove-Item -LiteralPath $script:CacheDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:ExportDir -Recurse -Force -ErrorAction SilentlyContinue
}
