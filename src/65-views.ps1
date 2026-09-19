# ============================================================================
#region Views
# ============================================================================

function Update-TabView {
    # Filter + sort targets. Filter: All | NotScanned | Clean | Findings | Failed | Unprovisioned.
    param($Tab)
    $items = @($Tab['Items'])
    # Placeholder rows (users without a personal site) only surface under the
    # dedicated Unprovisioned filter; every other filter hides them.
    if ($Tab['Filter'] -eq 'Unprovisioned') {
        $items = @($items | Where-Object { Test-SsmPlaceholderTarget -Target $_ })
    } else {
        $items = @($items | Where-Object { -not (Test-SsmPlaceholderTarget -Target $_) })
        switch ($Tab['Filter']) {
            'NotScanned' { $items = @($items | Where-Object { $_.Status -eq 'NotScanned' }) }
            'Clean'      { $items = @($items | Where-Object { $_.Status -eq 'Clean' }) }
            'Findings'   { $items = @($items | Where-Object { $_.Status -eq 'Findings' -or $_.Status -eq 'Revoked' }) }
            'Failed'     { $items = @($items | Where-Object { $_.Status -like '*Failed' }) }
        }
    }
    if (-not [string]::IsNullOrEmpty($Tab['Search'])) {
        $n = $Tab['Search']
        $items = @($items | Where-Object { ($_.Url -like "*$n*") -or ($_.Title -like "*$n*") })
    }
    $prop = $Tab['SortCol']   # Url | Title | Status | Findings
    $expr = switch ($prop) { 'Findings' { { $_.FindingCount } } default { { $_.$prop } } }
    # @() must wrap the whole if/else, not each branch: an if-expression that
    # streams zero or one object collapses to $null / a scalar on assignment
    # even when each branch's own output was array-cast (0 or 1 matches is
    # the common case - e.g. an empty tab, or a filter with a single hit).
    $items = @(if ($Tab['SortDesc']) { $items | Sort-Object -Property $expr -Descending } else { $items | Sort-Object -Property $expr })
    $Tab['View'] = $items
    if ($Tab['Cursor'] -ge $items.Count) { $Tab['Cursor'] = [Math]::Max(0, $items.Count - 1) }
    $script:UI.Dirty = $true
}

function Update-FindingsView {
    # Filter + sort the findings sub-view. Filter cycles category keys.
    param($Tab)
    $ft = $Tab['FTab']
    $items = @($ft['Items'])
    if ($ft['Filter'] -ne 'All') { $items = @($items | Where-Object { $_.CategoryKey -eq $ft['Filter'] }) }
    if (-not [string]::IsNullOrEmpty($ft['Search'])) {
        $n = $ft['Search']
        $items = @($items | Where-Object { ($_.Name -like "*$n*") -or ($_.Principal -like "*$n*") -or ($_.Path -like "*$n*") })
    }
    $ft['View'] = @($items | Sort-Object Category, Path)
    if ($ft['Cursor'] -ge @($ft['View']).Count) { $ft['Cursor'] = [Math]::Max(0, @($ft['View']).Count - 1) }
    $script:UI.Dirty = $true
}

function Add-TitleBar {
    param([System.Text.StringBuilder]$Sb, [int]$W)
    $t = $script:T; $g = $script:G
    $left = ' SharePoint Sharing Manager  v' + $script:Version
    if ($script:TenantName) { $left += ('  [' + $script:TenantName + ']') }
    $pieces = New-Object System.Collections.ArrayList

    $connGlyph = [string]$g.Ring; $connStyle = $t.TitleOff; $connText = 'Not connected'
    if ($script:Conn.Url) {
        $connGlyph = [string]$g.Dot; $connStyle = $t.TitleOk
        $connText = $script:Conn.Url
        if ($script:Conn.Account) { $connText += (' (' + $script:Conn.Account + ')') }
    }
    [void]$pieces.Add(@($connStyle, ($connGlyph + ' ' + $connText)))

    # App-only cert expiry piece: shown whenever a cert-expires date is known.
    $daysLeft = Get-CertDaysLeft
    if ($null -ne $daysLeft) {
        $certStyle = $t.TitleOk
        if ($daysLeft -lt 30) { $certStyle = $t.TitleDim + $t.Warn }
        [void]$pieces.Add(@($certStyle, ('cert ' + $script:Auth.CertExpires)))
    }

    $sep = '   '
    $plainRight = 0
    foreach ($p in $pieces) { $plainRight += ([string]$p[1]).Length }
    $plainRight += $sep.Length * [Math]::Max(0, ($pieces.Count - 1)) + 1   # trailing space

    $mid = $W - $left.Length - $plainRight
    if ($mid -lt 1) { $mid = 1 }
    $line = $t.TitleApp + $left + $t.TitleBg + (' ' * $mid)
    for ($i = 0; $i -lt $pieces.Count; $i++) {
        if ($i -gt 0) { $line += $t.TitleDim + $sep }
        $line += ([string]$pieces[$i][0]) + ([string]$pieces[$i][1])
    }
    $line += $t.TitleBg + ' '
    Add-FrameLine -Sb $Sb -Row 1 -Content $line
}

function Add-TabBar {
    param([System.Text.StringBuilder]$Sb, [int]$W)
    $t = $script:T
    $line = $t.TabBg + ' '
    $plain = 1
    for ($i = 0; $i -lt $script:Tabs.Count; $i++) {
        $tab = $script:Tabs[$i]
        $label = ' ' + ($i + 1) + ' ' + $tab['Name'] + ' '
        if ($i -eq $script:UI.Tab) { $line += $t.TabOn + $label + $t.TabBg }
        else { $line += $t.TabOff + $label + $t.TabBg }
        $line += ' '
        $plain += $label.Length + 1
    }
    if ($plain -lt $W) { $line += (' ' * ($W - $plain)) }
    Add-FrameLine -Sb $Sb -Row 2 -Content $line
}

function Get-TargetsLayout {
    param([int]$W)
    # ' ' sel(3) ' ' Title(flex 35%) '  ' Url(flex 65%) '  ' Findings(8) '  ' Status(15)
    $fixed = 1 + 3 + 1 + 2 + 2 + 8 + 2 + 15
    $flex = $W - $fixed - 1
    if ($flex -lt 20) { $flex = 20 }
    $titleW = [int]($flex * 0.35)
    $urlW = $flex - $titleW
    return @{ Title = $titleW; Url = $urlW; Findings = 8; Status = 15 }
}

function Add-TargetsView {
    param([System.Text.StringBuilder]$Sb, $Tab, [int]$W, [int]$H)
    $t = $script:T; $g = $script:G

    if (-not $Tab['Loaded']) {
        Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + ' not loaded')
        for ($r = 4; $r -le ($H - 1); $r++) { Add-FrameLine -Sb $Sb -Row $r -Content '' }
        $head = 'No targets yet.'
        $hint = 'Press Enter to enumerate from the tenant, U to add a URL, I to import a CSV.'
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add(@(($t.CtxHi + $head), $head.Length))
        [void]$lines.Add(@('', 0))
        [void]$lines.Add(@(($t.Row + $hint), $hint.Length))
        if ($script:UI.RestoreInfo) {
            [void]$lines.Add(@('', 0))
            $rmsg = ("Cached session available ({0} targets, saved {1}) - press L to restore." -f $script:UI.RestoreInfo.Count, $script:UI.RestoreInfo.SavedAt)
            [void]$lines.Add(@(($script:T.Good + $rmsg), $rmsg.Length))
        }
        if (-not (Test-SsmAuthReady)) {
            [void]$lines.Add(@('', 0))
            $warn = 'Sign-in is not configured - see the Setup tab (4).'
            [void]$lines.Add(@(($t.Warn + $warn), $warn.Length))
        }
        [void](Write-CenteredPanel -Sb $Sb -Lines $lines.ToArray() -Top 6 -Bottom ($H - 4) -Width $W)
        return
    }

    $view = @($Tab['View'])
    $selCount = @($Tab['Items'] | Where-Object { $_.Selected }).Count
    $dir = [string]$g.Up
    if ($Tab['SortDesc']) { $dir = [string]$g.Down }
    $ctx = (' {0} of {1} {2}   {3} selected   filter:{4}   sort:{5}{6}' -f @($view).Count, @($Tab['Items']).Count, $Tab['Noun'], $selCount, $Tab['Filter'], $Tab['SortCol'], $dir)
    # Persistent scan summary: visible at all times once anything is scanned.
    $done = @($Tab['Items'] | Where-Object { $_.Status -in @('Clean','Findings','Revoked') })
    if ($done.Count -gt 0) {
        $totalFindings = ($done | Measure-Object FindingCount -Sum).Sum
        $ctx += ('   scanned:{0} ({1} clean, {2} with findings, {3} total findings)' -f $done.Count, @($done | Where-Object { $_.FindingCount -eq 0 }).Count, @($done | Where-Object { $_.FindingCount -gt 0 }).Count, $totalFindings)
    }
    $unprov = @($Tab['Items'] | Where-Object { $_.Status -eq 'Unprovisioned' }).Count
    if ($unprov -gt 0) { $ctx += ('   unprovisioned:{0} (F to view)' -f $unprov) }
    if (-not [string]::IsNullOrEmpty($Tab['Search'])) { $ctx += ('   search:"' + $Tab['Search'] + '"') }
    if ($Tab['CachedAt']) {
        $saved = $Tab['CachedAt']
        try { $saved = ([datetime]$Tab['CachedAt']).ToString('yyyy-MM-dd HH:mm') } catch { }
        $ctx += ('   from cache (saved {0}, C reloads)' -f $saved)
    }
    Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + $ctx)

    $col = Get-TargetsLayout -W $W
    $head = ' ' + (Get-PadCell 'sel' 3) + ' ' + (Get-PadCell 'Title' $col.Title) + '  ' + (Get-PadCell 'Url' $col.Url) + '  ' + (Get-PadCell 'Findings' $col.Findings -AlignRight) + '  ' + (Get-PadCell 'Status' $col.Status)
    Add-FrameLine -Sb $Sb -Row 4 -Content ($t.ColHead + $head)

    $top = 5; $bottom = $H - 1
    $cap = $bottom - $top + 1
    if ($cap -lt 1) { $cap = 1 }

    # clamp scroll around cursor
    if ($Tab['Cursor'] -lt $Tab['Scroll']) { $Tab['Scroll'] = $Tab['Cursor'] }
    if ($Tab['Cursor'] -ge ($Tab['Scroll'] + $cap)) { $Tab['Scroll'] = $Tab['Cursor'] - $cap + 1 }
    $maxScroll = [Math]::Max(0, $view.Count - $cap)
    if ($Tab['Scroll'] -gt $maxScroll) { $Tab['Scroll'] = $maxScroll }
    if ($Tab['Scroll'] -lt 0) { $Tab['Scroll'] = 0 }

    for ($i = 0; $i -lt $cap; $i++) {
        $row = $top + $i
        $idx = $Tab['Scroll'] + $i
        if ($idx -ge $view.Count) { Add-FrameLine -Sb $Sb -Row $row -Content ''; continue }
        $item = $view[$idx]
        $isCursor = ($idx -eq $Tab['Cursor'])

        $chk = [string]$g.ChkOff
        if ($item.Selected) { $chk = [string]$g.ChkOn }

        $line = ''
        if ($isCursor) { $line += $t.CursorBg + $t.CursorFg }
        else { $line += $t.Row }

        if ($item.Selected) {
            if ($isCursor) { $line += ' ' + $chk + ' ' }
            else { $line += $t.SelMark + ' ' + $chk + ' ' + $t.Row }
        } else {
            $line += ' ' + $chk + ' '
        }
        $line += (Get-PadCell $item.Title $col.Title) + '  '
        if ($isCursor) { $line += (Get-PadCell $item.Url $col.Url) }
        else { $line += $t.RowDim + (Get-PadCell $item.Url $col.Url) + $t.Row }
        $line += '  ' + (Get-PadCell ([string]$item.FindingCount) $col.Findings -AlignRight)
        $line += '  ' + (Get-StatusBadge -Status $item.Status -Width $col.Status)
        Add-FrameLine -Sb $Sb -Row $row -Content $line
    }
}

function Get-FindingsLayout {
    param([int]$W, [bool]$Aggregate = $false)
    $siteW = if ($Aggregate) { 22 } else { 0 }
    $siteFixed = if ($Aggregate) { $siteW + 2 } else { 0 }
    # ' ' sel(3) ' ' [Site(22) '  '] Category(20) '  ' Loc(7) '  ' Name(flex 40%) '  ' Principal(flex 60%) '  ' Created(10) '  ' Status(12)
    $fixed = 1 + 3 + 1 + $siteFixed + 20 + 2 + 7 + 2 + 2 + 2 + 10 + 2 + 12
    $flex = $W - $fixed - 1
    if ($flex -lt 20) { $flex = 20 }
    $nameW = [int]($flex * 0.4)
    $principalW = $flex - $nameW
    return @{ Site = $siteW; Category = 20; Loc = 7; Name = $nameW; Principal = $principalW; Created = 10; Status = 12 }
}

function Add-FindingsView {
    param([System.Text.StringBuilder]$Sb, $Tab, [int]$W, [int]$H)
    $t = $script:T; $g = $script:G
    $ft = $Tab['FTab']
    $view = @($ft['View'])
    $selCount = @($ft['Items'] | Where-Object { $_.Selected }).Count
    $ctx = (' {0}   {1} of {2} findings   {3} selected   filter:{4}' -f $ft['Target'].Url, @($view).Count, @($ft['Items']).Count, $selCount, $ft['Filter'])
    if (-not [string]::IsNullOrEmpty($ft['Search'])) { $ctx += ('   search:"' + $ft['Search'] + '"') }
    Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + $ctx)

    $agg = [bool]$ft['Aggregate']
    $col = Get-FindingsLayout -W $W -Aggregate $agg
    $siteHead = if ($agg) { (Get-PadCell 'Site' $col.Site) + '  ' } else { '' }
    $head = ' ' + (Get-PadCell 'sel' 3) + ' ' + $siteHead + (Get-PadCell 'Category' $col.Category) + '  ' + (Get-PadCell 'Loc' $col.Loc) + '  ' + (Get-PadCell 'Name' $col.Name) + '  ' + (Get-PadCell 'Principal' $col.Principal) + '  ' + (Get-PadCell 'Created' $col.Created) + '  ' + (Get-PadCell 'Status' $col.Status)
    Add-FrameLine -Sb $Sb -Row 4 -Content ($t.ColHead + $head)

    $top = 5; $bottom = $H - 1
    $cap = $bottom - $top + 1
    if ($cap -lt 1) { $cap = 1 }

    if ($ft['Cursor'] -lt $ft['Scroll']) { $ft['Scroll'] = $ft['Cursor'] }
    if ($ft['Cursor'] -ge ($ft['Scroll'] + $cap)) { $ft['Scroll'] = $ft['Cursor'] - $cap + 1 }
    $maxScroll = [Math]::Max(0, $view.Count - $cap)
    if ($ft['Scroll'] -gt $maxScroll) { $ft['Scroll'] = $maxScroll }
    if ($ft['Scroll'] -lt 0) { $ft['Scroll'] = 0 }

    for ($i = 0; $i -lt $cap; $i++) {
        $row = $top + $i
        $idx = $ft['Scroll'] + $i
        if ($idx -ge $view.Count) { Add-FrameLine -Sb $Sb -Row $row -Content ''; continue }
        $item = $view[$idx]
        $isCursor = ($idx -eq $ft['Cursor'])

        $chk = [string]$g.ChkOff
        if ($item.Selected) { $chk = [string]$g.ChkOn }

        $line = ''
        if ($isCursor) { $line += $t.CursorBg + $t.CursorFg }
        else { $line += $t.Row }

        if ($item.Selected) {
            if ($isCursor) { $line += ' ' + $chk + ' ' }
            else { $line += $t.SelMark + ' ' + $chk + ' ' + $t.Row }
        } else {
            $line += ' ' + $chk + ' '
        }
        if ($agg) {
            $siteTag = ($item.Site.TrimEnd('/') -split '/')[-1]
            $line += (Get-PadCell $siteTag $col.Site) + '  '
        }
        $line += (Get-PadCell $item.Category $col.Category) + '  '
        $line += (Get-PadCell $item.Location $col.Loc) + '  '
        if ($isCursor) { $line += (Get-PadCell $item.Name $col.Name) }
        else { $line += $t.RowDim + (Get-PadCell $item.Name $col.Name) + $t.Row }
        $line += '  ' + (Get-PadCell $item.Principal $col.Principal)
        # Link creation date (only populated when link-date lookup is enabled
        # for the tenant). Date-only, yyyy-MM-dd, blank when unknown.
        $created = ''
        $lc = $item.PSObject.Properties['LinkCreated']
        if ($lc -and $lc.Value) {
            [datetime]$d = [datetime]::MinValue
            if ([datetime]::TryParse([string]$lc.Value, [ref]$d)) { $created = $d.ToString('yyyy-MM-dd') }
        }
        $line += '  ' + (Get-PadCell $created $col.Created)
        $statusStyle = $t.Muted
        if ($item.RevokeStatus -eq 'Removed') { $statusStyle = $t.Good }
        elseif ($item.RevokeStatus -like 'Failed:*') { $statusStyle = $t.Danger }
        $line += '  ' + $statusStyle + (Get-PadCell $item.RevokeStatus $col.Status) + $t.Row
        Add-FrameLine -Sb $Sb -Row $row -Content $line
    }
}

function Invoke-TabScan {
    # Scan all selected targets sequentially. Per-target failure isolation:
    # a failed connect/scan marks the target and the loop continues.
    param($Tab)
    $sel = @($Tab['Items'] | Where-Object { $_.Selected -and -not (Test-SsmPlaceholderTarget -Target $_) })
    $skipped = @($Tab['Items'] | Where-Object { $_.Selected -and (Test-SsmPlaceholderTarget -Target $_) }).Count
    if ($skipped -gt 0) { Write-SsmLog -Message ("Scan: skipped {0} unprovisioned placeholder row(s) - nothing to connect to yet." -f $skipped) -Level WARN }
    if ($sel.Count -eq 0) {
        $msg = if ($skipped -gt 0) { 'Only unprovisioned rows are selected - there is nothing to scan yet.' } else { 'Nothing selected. Space selects targets.' }
        Show-MsgModal -Title 'Scan' -Lines @($msg); return
    }
    $cats = @($Tab['Categories'])
    if ($cats.Count -eq 0) { Show-MsgModal -Title 'Scan' -Lines @('No rule categories enabled. Press T to enable some.') -Kind Warn; return }
    $i = 0
    foreach ($t in $sel) {
        $i++
        $t.Status = 'Scanning'; Write-Screen
        Start-LoadSpinner
        Write-ProgressModal -Title ("Scanning {0}/{1}" -f $i, $sel.Count) -Done 0 -Total 0 -Label $t.Url -Ok 0 -Failed 0
        $state = @{ LastTick = 0; Offset = 0; Total = 0; Cancel = $false }
        $cb = New-SsmProgressCallback -Title 'Scanning' -State $state -CancelMode 'Throw'
        try {
            if (-not (Connect-SsmSite -Url $t.Url)) { $t.Status = 'ConnectFailed'; continue }
            $findings = @(Invoke-SiteScan -Target $t -Categories $cats -Progress $cb)
            $t.Findings = $findings
            $t.FindingCount = $findings.Count
            $t.Status = if ($findings.Count -eq 0) { 'Clean' } else { 'Findings' }
            if ($findings.Count -gt 0) { [void](Export-FindingsCsv -Findings $findings -SiteUrl $t.Url -Phase 'BEFORE') }
        } catch [System.OperationCanceledException] {
            $t.Status = 'NotScanned'
            Write-SsmLog -Message 'Scan cancelled by user (Esc).' -Level WARN
            Stop-LoadSpinner
            break
        } catch {
            if (Test-SsmSiteLocked -ErrorRecord $_) {
                $t.Status = 'Skipped'
                Write-SsmLog -Message ("Skipped {0} - site is locked or inaccessible (deprovisioned OneDrive / LockState NoAccess)." -f $t.Url) -Level WARN
            } else {
                $t.Status = 'ScanFailed'
                Write-SsmErrorLog -Context ("Scan failed for {0}" -f $t.Url) -ErrorRecord $_
            }
        } finally {
            Stop-LoadSpinner
            if (Get-Command Save-SsmCache -ErrorAction SilentlyContinue) { Save-SsmCache }
        }
    }
    Update-TabView -Tab $Tab
}

function Invoke-TabEnumerate {
    # Enumerate tenant targets into an empty tab with a live progress modal.
    # Connect + first page is a blocking call, so a background spinner covers
    # the gap; after that the modal updates once per server page.
    param($Tab)
    $label = $Tab['OneDrive'] ? 'Loading OneDrives...' : 'Loading sites...'
    Start-LoadSpinner
    Write-ProgressModal -Title 'Enumerating tenant' -Done 0 -Total 0 -Label $label -Ok 0 -Failed 0
    $cb = { param($n) Write-ProgressModal -Title 'Enumerating tenant' -Done $n -Total 0 -Label $label -Ok 0 -Failed 0 }.GetNewClosure()
    try { $targets = Get-TenantTargets -OneDrive $Tab['OneDrive'] -Progress $cb } finally { Stop-LoadSpinner }
    Add-TargetsToTab -Tab $Tab -Targets $targets
    $script:UI.Dirty = $true
}

function Invoke-TabScanAll {
    # Enumerate if empty, then scan every NotScanned target. Cache is saved
    # after each target by Invoke-TabScan, so an interrupted run resumes.
    param($Tab)
    if (-not $Tab['Loaded'] -or @($Tab['Items']).Count -eq 0) {
        Invoke-TabEnumerate -Tab $Tab
    }
    $items = @($Tab['Items'])
    if ($items.Count -eq 0) {
        Show-MsgModal -Title 'Scan all' -Lines @('No targets found. Check your connection/sign-in and try again.')
        return
    }
    $prevSelected = @{}
    foreach ($it in $items) { $prevSelected[$it] = $it.Selected; $it.Selected = ($it.Status -eq 'NotScanned') }
    if (@($items | Where-Object { $_.Selected }).Count -eq 0) {
        foreach ($it in $items) { $it.Selected = $prevSelected[$it] }
        Show-MsgModal -Title 'Scan all' -Lines @('No unscanned targets remain. Everything here is already scanned.')
        return
    }
    try {
        Invoke-TabScan -Tab $Tab
    } finally {
        foreach ($it in $items) { $it.Selected = $prevSelected[$it] }
    }
}

function Enter-FindingsMode {
    param($Tab, $Target)
    $Tab['Mode'] = 'Findings'
    $Tab['FTab'] = @{ Target = $Target; Items = @($Target.Findings); View = @(); Cursor = 0; Scroll = 0; Search = ''; Filter = 'All' }
    Update-FindingsView -Tab $Tab
}

function Enter-AggregateMode {
    # Findings mode spanning every scanned target in the tab.
    param($Tab)
    $all = @(Get-TabFindings -Tab $Tab)
    if ($all.Count -eq 0) { Show-MsgModal -Title 'All findings' -Lines @('No findings yet. Scan targets first (S or X).'); return }
    $Tab['Mode'] = 'Findings'
    $Tab['FTab'] = @{ Target = @{ Url = ('All ' + $Tab['Noun']) }; Items = $all; View = @(); Cursor = 0; Scroll = 0; Search = ''; Filter = 'All'; Aggregate = $true }
    Update-FindingsView -Tab $Tab
}

function Exit-FindingsMode {
    param($Tab)
    $Tab['Mode'] = 'Targets'; $Tab['FTab'] = $null
    $script:UI.Dirty = $true
}

function Invoke-FindingsRevoke {
    # Revoke selected findings on the drilled target, typed confirmation first.
    param($Tab)
    $ft = $Tab['FTab']
    if ($ft['Aggregate']) {
        Invoke-BulkRevoke -Findings @($ft['Items'] | Where-Object { $_.Selected }) -Tab $Tab
        Update-FindingsView -Tab $Tab
        return
    }
    $target = $ft['Target']
    $sel = @($ft['Items'] | Where-Object { $_.Selected })
    if ($sel.Count -eq 0) { Show-MsgModal -Title 'Revoke' -Lines @('Nothing selected.'); return }
    $byCat = ($sel | Group-Object Category | ForEach-Object { "  {0}: {1}" -f $_.Name, $_.Count })
    $ok = Show-TypedConfirmModal -Title 'Revoke sharing' -Word 'REVOKE' -Lines (@(
        ("Remove {0} link(s)/grant(s) on" -f $sel.Count), $target.Url, '') + $byCat)
    if (-not $ok) { return }
    if (-not (Connect-SsmSite -Url $target.Url)) { return }
    $state = @{ LastTick = 0; Offset = 0; Total = $sel.Count; Cancel = $false }
    $cb = New-SsmProgressCallback -Title 'Revoking' -State $state -CancelMode 'Flag'
    Start-LoadSpinner
    try {
        Write-ProgressModal -Title 'Revoking' -Done 0 -Total $sel.Count -Label $target.Url -Ok 0 -Failed 0
        $removed = Invoke-Revoke -Findings $sel -Progress $cb -State $state
    } finally {
        Stop-LoadSpinner
    }
    [void](Export-FindingsCsv -Findings @($ft['Items']) -SiteUrl $target.Url -Phase 'REVOKED')
    $target.FindingCount = @($target.Findings | Where-Object { $_.RevokeStatus -ne 'Removed' -and $_.RevokeStatus -ne 'AlreadyRevoked' }).Count
    if ($target.FindingCount -eq 0) { $target.Status = 'Revoked' }
    if (Get-Command Save-SsmCache -ErrorAction SilentlyContinue) { Save-SsmCache }
    $report = @(("Removed {0} of {1}. Evidence CSV written." -f $removed, $sel.Count))
    if ($state.Cancel) { $report += 'Cancelled by operator; the remaining findings were not processed.' }
    Show-ReportModal -Title 'Revoke complete' -Lines $report
    Update-FindingsView -Tab $Tab
}

function Update-TabTargetStatuses {
    # Recompute per-target FindingCount/Status from live RevokeStatus values.
    param($Tab)
    foreach ($it in @($Tab['Items'])) {
        $remaining = @(@($it.Findings) | Where-Object { $_.RevokeStatus -ne 'Removed' -and $_.RevokeStatus -ne 'AlreadyRevoked' })
        $it.FindingCount = $remaining.Count
        if (@($it.Findings).Count -gt 0 -and $remaining.Count -eq 0) { $it.Status = 'Revoked' }
    }
}

function Invoke-BulkRevoke {
    # Revoke an explicit set of findings, grouped by site, with one typed
    # confirmation and a per-site connect/revoke/save loop.
    param($Findings, $Tab)
    $sel = @($Findings)
    if ($sel.Count -eq 0) { Show-MsgModal -Title 'Revoke' -Lines @('Nothing selected.'); return }
    $groups = Group-FindingsBySite -Findings $sel
    $lines = @(("Remove {0} link(s)/grant(s) across {1} site(s):" -f $sel.Count, $groups.Count), '')
    $prefix = Get-CommonUrlPrefix -Urls @($groups | ForEach-Object { $_.Name })
    if ($prefix) {
        # Print the shared site-collection prefix once so each site fits on one
        # line; full URLs wrap to two lines each at the modal's 64-char width.
        $lines += ("Under " + $prefix)
        foreach ($g in $groups) {
            $lines += ("  {0}: {1}" -f $g.Name.Substring($prefix.Length), @($g.Group).Count)
        }
    } else {
        foreach ($g in $groups) { $lines += ("  {0}: {1}" -f $g.Name, @($g.Group).Count) }
    }
    if (-not (Show-TypedConfirmModal -Title 'Bulk revoke sharing' -Word 'REVOKE' -Lines $lines)) { return }

    $totalRemoved = 0; $siteReport = @(); $siteNo = 0
    # One continuous bar across every site: Offset carries the running total of
    # findings completed in earlier sites, so the bar never resets to zero.
    $state = @{ LastTick = 0; Offset = 0; Total = $sel.Count; Cancel = $false }
    $cb = New-SsmProgressCallback -Title 'Revoking' -State $state -CancelMode 'Flag'
    Start-LoadSpinner
    try {
        foreach ($g in $groups) {
            $siteNo++
            $siteCount = @($g.Group).Count
            Write-ProgressModal -Title ("Revoking site {0}/{1}" -f $siteNo, $groups.Count) -Done $state.Offset -Total $sel.Count -Label $g.Name -Ok $totalRemoved -Failed 0
            if (-not (Connect-SsmSite -Url $g.Name)) {
                $siteReport += ("{0}: connect failed" -f $g.Name)
                $state.Offset += $siteCount
                continue
            }
            $removed = Invoke-Revoke -Findings @($g.Group) -Progress $cb -State $state
            [void](Export-FindingsCsv -Findings @($g.Group) -SiteUrl $g.Name -Phase 'REVOKED')
            $totalRemoved += $removed
            $state.Offset += $siteCount
            $siteReport += ("{0}: removed {1} of {2}" -f $g.Name, $removed, $siteCount)
            # Recompute Status/FindingCount from the just-updated RevokeStatus
            # values before saving, so the on-disk cache never lags behind a
            # restart/restore with a stale "Findings" status - Save-SsmCache
            # snapshots whatever Status the target currently holds.
            Update-TabTargetStatuses -Tab $Tab
            if (Get-Command Save-SsmCache -ErrorAction SilentlyContinue) { Save-SsmCache }
            # Checked after the evidence CSV and cache save, so a cancelled run
            # still records everything it actually did.
            if ($state.Cancel) { break }
        }
    } finally {
        Stop-LoadSpinner
    }
    $summary = @(("Removed {0} of {1} across {2} site(s)." -f $totalRemoved, $sel.Count, $groups.Count))
    if ($state.Cancel) {
        $summary += ("Cancelled after {0} of {1} site(s); the rest were not processed." -f $siteNo, $groups.Count)
    }
    Show-ReportModal -Title 'Bulk revoke complete' -Lines ($summary + @('') + $siteReport)
    Update-TabView -Tab $Tab
}

function Show-CategoryToggleModal {
    # Space toggles a category, Enter accepts. Simple numbered input loop
    # built on the ported src/20-modals.ps1 primitives (Write-ModalFrame
    # takes normalized @($style,$text) body lines, not raw @($Lines,$Width)).
    param($Tab)
    $keys = @($script:RuleCategories.Keys)
    while ($true) {
        $lines = @('Enabled rule categories (press 1-' + $keys.Count + ' to toggle, Enter to accept):', '')
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $on = ($Tab['Categories'] -contains $keys[$i])
            $mark = if ($on) { [string]$script:G.ChkOn } else { [string]$script:G.ChkOff }
            $lines += ("  {0} {1} {2}" -f ($i + 1), $mark, $script:RuleCategories[$keys[$i]])
        }
        $norm = ConvertTo-ModalLines -Lines $lines -Width 64
        [void](Write-ModalFrame -Title 'Scan rules' -BodyLines $norm -FooterHint 'Enter accept   Esc cancel' -BorderStyle $script:T.Border)
        $k = Read-ModalKey
        if ($k.Key -eq 'Enter' -or $k.Key -eq 'Escape') { break }
        $n = 0
        if ([int]::TryParse([string]$k.KeyChar, [ref]$n) -and $n -ge 1 -and $n -le $keys.Count) {
            $key = $keys[$n - 1]
            if ($Tab['Categories'] -contains $key) { [void]$Tab['Categories'].Remove($key) } else { [void]$Tab['Categories'].Add($key) }
        }
    }
    $script:UI.Dirty = $true
}

function Add-TenantView {
    param([System.Text.StringBuilder]$Sb, [int]$W, [int]$H)
    $t = $script:T
    Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + ' Tenant-wide sharing posture')
    for ($r = 4; $r -le ($H - 1); $r++) { Add-FrameLine -Sb $Sb -Row $r -Content '' }

    $tabState = $script:Tabs[2]
    if (-not $tabState['Loaded'] -or -not $tabState['Posture']) {
        $head = 'Tenant sharing posture not loaded.'
        $hint = 'Press Enter to connect to the tenant admin site and read the sharing posture.'
        $lines = @(
            @(($t.CtxHi + $head), $head.Length),
            @('', 0),
            @(($t.Row + $hint), $hint.Length)
        )
        [void](Write-CenteredPanel -Sb $Sb -Lines $lines -Top 6 -Bottom ($H - 4) -Width $W)
        return
    }

    $p = $tabState['Posture']
    $margin = 4
    $row = 5
    $pad = ' ' * $margin
    $cursor = if ($tabState.ContainsKey('Cursor')) { [int]$tabState['Cursor'] } else { 0 }

    # Rows come straight from $script:TenantSettings so display order, cursor
    # nav and Enter can never drift apart (labels/values computed per row).
    $capLabels = $script:SharingCapabilityLabels
    $rows = @($script:TenantSettings | ForEach-Object {
        $v = [string]$p[$_.Prop]
        if ($_.Prop -match 'SharingCapability$' -and $capLabels.ContainsKey($v)) { $v = '{0} ({1})' -f $v, $capLabels[$v] }
        @{ Prop = $_.Prop; Value = $v; Note = $_.Note }
    })

    # Scroll window: keep the cursor inside the visible band, show overflow
    # arrows so a clipped list is never mistaken for the whole list. Arrow
    # rows are reserved BEFORE the window is sized - otherwise the band
    # shrinks after scroll is computed and the cursor gets clipped.
    $top = 5; $bottom = $H - 2
    $cap = $bottom - $top + 1
    $scroll = if ($tabState.ContainsKey('Scroll')) { [int]$tabState['Scroll'] } else { 0 }
    $hasUp = $false; $hasDown = $false
    for ($pass = 0; $pass -lt 3; $pass++) {
        $bandCap = $cap - ([int]$hasUp) - ([int]$hasDown)
        if ($cursor -lt $scroll) { $scroll = $cursor }
        if ($cursor -ge ($scroll + $bandCap)) { $scroll = $cursor - $bandCap + 1 }
        $scroll = [Math]::Max(0, [Math]::Min($scroll, [Math]::Max(0, $rows.Count - $bandCap)))
        $newUp = $scroll -gt 0
        $newDown = ($scroll + $bandCap) -lt $rows.Count
        if ($newUp -eq $hasUp -and $newDown -eq $hasDown) { break }
        $hasUp = $newUp; $hasDown = $newDown
    }
    $tabState['Scroll'] = $scroll

    $row = $top
    if ($hasUp) {
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + [string]$script:G.Up + ' more above')
        $row++
    }
    $last = [Math]::Min($scroll + $bandCap - 1, $rows.Count - 1)
    for ($idx = $scroll; $idx -le $last; $idx++) {
        $r = $rows[$idx]
        $isCur = ($idx -eq $cursor)
        $arrow = [string]$script:G.Arrow
        $marker = if ($isCur) { $t.CtxHi + $arrow + ' ' } else { ' ' * ($arrow.Length + 1) }
        $labelStyle = if ($isCur) { $t.CursorFg } else { $t.CtxHi }
        # CIS 7.2.x alignment badge: green "CIS ✓" when the value meets the
        # benchmark's recommended state, dim "CIS ✗" when it does not, nothing
        # when CIS has no recommendation for the setting.
        $cis = Test-CisAlignment -Prop $r.Prop -Value ($r.Value -replace ' \(.*$', '')
        $badge = ''
        if ($cis -eq $true)       { $badge = '  ' + $t.Good  + 'CIS ' + [string]$script:G.AuditOk + $t.Reset }
        elseif ($cis -eq $false)  { $badge = '  ' + $t.Muted + 'CIS ' + [string]$script:G.AuditError + $t.Reset }
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $marker + $labelStyle + (Get-PadCell $r.Prop 38) + $t.Reset + $t.Row + ': ' + $r.Value + $badge); $row++
    }
    if ($hasDown -and $row -le $bottom) {
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + [string]$script:G.Down + ' more below')
    }
    # The highlighted setting's explanation rides the header line - per-row
    # note lines were dropped so the list fits twice as many rows.
    if ($cursor -lt $rows.Count -and $rows[$cursor].Note) {
        Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + ' Tenant-wide sharing posture   ' + $t.Muted + $rows[$cursor].Note)
    }
}

function Add-SetupView {
    param([System.Text.StringBuilder]$Sb, [int]$W, [int]$H)
    $t = $script:T
    Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + ' Tenants')
    for ($r = 4; $r -le ($H - 1); $r++) { Add-FrameLine -Sb $Sb -Row $r -Content '' }

    $tab = $script:Tabs[$script:UI.Tab]
    $names = @(Get-SsmTenantNames)
    if ($names.Count -eq 0) { $tab['Cursor'] = 0 }
    elseif ($tab['Cursor'] -ge $names.Count) { $tab['Cursor'] = $names.Count - 1 }
    if ($tab['Cursor'] -lt 0) { $tab['Cursor'] = 0 }
    $c = Get-SsmConfig

    $margin = 4; $pad = ' ' * $margin; $row = 5
    if ($names.Count -eq 0) {
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'No tenants configured. Press A to add one.'); $row += 2
    }
    for ($i = 0; $i -lt $names.Count -and $row -le ($H - 6); $i++) {
        $n = $names[$i]
        $e = $c.Tenants[$n]
        $tags = @()
        if ($n -eq $script:TenantName)   { $tags += 'active' }
        if ($n -eq $c.DefaultTenant)     { $tags += 'default' }
        $tagText = if ($tags) { ' [' + ($tags -join ',') + ']' } else { '' }
        $mode = if ($e.AuthMode) { $e.AuthMode } else { '-' }
        $state = if (Test-SsmTenantConfigured -Entry $e) { 'configured' } else { 'not configured' }
        $line = $pad + $n + $tagText + '  ' + $mode + '  ' + $state
        if ($i -eq $tab['Cursor']) { $line = $t.CursorFg + $line + $t.Reset }
        Add-FrameLine -Sb $Sb -Row $row -Content $line; $row++
    }
    $row++

    $valueW = [Math]::Max(20, $W - $margin - 14)
    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'Config file : ' + $t.Row + (Get-PadCell $script:ConfigPath $valueW)); $row += 2

    $pnp = Get-Module -ListAvailable -Name 'PnP.PowerShell' | Sort-Object Version -Descending | Select-Object -First 1
    $pnpText = if ($pnp) { 'installed (v' + $pnp.Version + ')' } else { 'not installed' }
    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'PnP module  : ' + $t.CtxHi + $pnpText); $row += 2

    $legend = @(
        'Enter  actions for the highlighted tenant',
        'A      add a tenant',
        'T      quick-switch tenant (works on most tabs)'
    )
    foreach ($ln in $legend) {
        if ($row -gt ($H - 1)) { break }
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Row + $ln); $row++
    }
}

function Add-AboutView {
    param([System.Text.StringBuilder]$Sb, [int]$W, [int]$H)
    $t = $script:T
    Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + ' About')
    for ($r = 4; $r -le ($H - 1); $r++) { Add-FrameLine -Sb $Sb -Row $r -Content '' }

    $margin = 4; $pad = ' ' * $margin; $row = 5
    $valueW = [Math]::Max(20, $W - $margin)

    $lines = @(
        @($t.TitleApp, ('SharePoint Sharing Manager  v' + $script:Version)),
        @($t.Row,   ''),
        @($t.Muted, 'A dependency-light PowerShell terminal UI that finds and revokes'),
        @($t.Muted, 'unwanted SharePoint Online and OneDrive for Business sharing across'),
        @($t.Muted, 'a tenant - anonymous links, org-wide links, guest sharing, and broad'),
        @($t.Muted, 'grants (EEEU, Everyone).'),
        @($t.Row,   ''),
        @($t.Muted, ('Author   : ' + $t.CtxHi + (Get-PadCell 'Michael Mardahl' ($valueW - 11)))),
        @($t.Muted, ('GitHub   : ' + $t.CtxHi + (Get-PadCell 'https://github.com/mardahl' ($valueW - 11)))),
        @($t.Muted, ('Releases : ' + $t.CtxHi + (Get-PadCell 'https://github.com/mardahl/SharePoint-Sharing-Manager/releases' ($valueW - 11)))),
        @($t.Row,   ''),
        @($t.Row,   'G  open the author''s GitHub profile in a browser'),
        @($t.Row,   'R  open the releases page in a browser')
    )
    foreach ($ln in $lines) {
        if ($row -gt ($H - 1)) { break }
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $ln[0] + $ln[1]); $row++
    }
}

function Add-LogView {
    param([System.Text.StringBuilder]$Sb, [int]$W, [int]$H)
    $t = $script:T
    Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + ' ' + $script:LogFile)
    $top = 4; $bottom = $H - 1
    $cap = $bottom - $top + 1
    $total = $script:LogBuffer.Count
    $maxScroll = [Math]::Max(0, $total - $cap)
    if ($script:UI.LogScroll -gt $maxScroll) { $script:UI.LogScroll = $maxScroll }
    $start = [Math]::Max(0, $total - $cap - $script:UI.LogScroll)
    for ($i = 0; $i -lt $cap; $i++) {
        $row = $top + $i
        $idx = $start + $i
        if ($idx -ge ($total - $script:UI.LogScroll)) { Add-FrameLine -Sb $Sb -Row $row -Content ''; continue }
        if ($idx -lt 0 -or $idx -ge $total) { Add-FrameLine -Sb $Sb -Row $row -Content ''; continue }
        $entry = $script:LogBuffer[$idx]
        $style = $t.Row
        switch ($entry['Level']) {
            'WARN'  { $style = $t.Warn }
            'ERROR' { $style = $t.Danger }
            'OK'    { $style = $t.Good }
        }
        $text = ' ' + $entry['Stamp'].Substring(11) + '  ' + (Get-PadCell $entry['Level'] 5) + ' ' + $entry['Message']
        Add-FrameLine -Sb $Sb -Row $row -Content ($style + (Get-PadCell $text ($W - 1)))
    }
}

function ConvertTo-SsmSafeDisplay {
    # Escapes C0/C1 control characters in externally-sourced display values
    # (directory display names, target titles) before they reach a modal,
    # report line, or log message. Canonical values used for CSV/API calls
    # are never passed through this - only rendering/log boundaries are.
    param([string]$Value)
    if (-not $Value) { return $Value }
    return [regex]::Replace($Value, '[\x00-\x1f\x7f-\x9f]', {
        param($m) ('\u{0:x4}' -f [int][char]$m.Value[0])
    })
}

function Get-SsmUtcNowStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-SsmOneDriveAdminSelectedTargets {
    # Freeze + dedupe (case/trailing-slash-insensitive) the selected targets
    # from every item in the tab, not the filtered/visible view - a filter
    # that hides a selected row must not silently drop it from scope.
    param($Tab)
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($it in @($Tab['Items'])) {
        if (-not $it.Selected -or (Test-SsmPlaceholderTarget -Target $it)) { continue }
        $norm = ([string]$it.Url).TrimEnd('/')
        $key = $norm.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$out.Add(@{ Url = $norm; Title = [string]$it.Title })
    }
    return $out.ToArray()
}

function New-SsmOneDriveAdminRow {
    # One evidence/result row per selected target. Extra (non-CSV) fields
    # carry the state needed to drive the batch (Snapshot/SiteConn/Eligible/
    # Classification/Title) - Export-SsmAdminCsv selects only its fixed
    # column set, so their presence here does not affect the CSV shape.
    # TimestampUtc is the preflight-row-creation time; ResultTimestampUtc is
    # refreshed at each point Result/AdminAfter is finalized, so the AFTER
    # evidence file records when each result actually happened, not only
    # when the row was first previewed.
    param($OperationId, $TenantId, $Actor, $Action, $TargetUrl, $Title, $EnteredUpn, $Identity)
    return [pscustomobject]@{
        OperationId     = "$OperationId"
        TimestampUtc    = (Get-SsmUtcNowStamp)
        ResultTimestampUtc = $null
        TenantId        = "$TenantId"
        Actor           = $Actor
        Action          = $Action
        TargetUrl       = $TargetUrl
        EnteredUpn      = $EnteredUpn
        ResolvedUpn     = $Identity.Upn
        ResolvedUserId  = "$($Identity.Id)"
        OwnerUpn        = $null
        OwnerId         = $null
        PrimaryAdminUpn = $null
        PrimaryAdminId  = $null
        AdminLogin      = $null
        AdminBefore     = $null
        AdminAfter      = $null
        Result          = 'NotAttempted'
        Error           = ''
        Title           = $Title
        Snapshot        = $null
        SiteConn        = $null
        Eligible        = $false
        Classification  = 'Failed'
    }
}

function Invoke-SsmOneDriveAdminList {
    # Read-only List action: every current site collection admin, grouped by
    # target, for the frozen selection. No UPN prompt, no confirmation, no
    # CSV/snapshot export, no directory/Graph lookups - Title/UPN/login and
    # the Entra object id (when the membership query resolves it) are shown
    # exactly as the site reports them. Unresolved principals stay visible;
    # nothing is guessed or hidden. A failure on one target logs and moves
    # on to the rest.
    param($Targets)

    $state = @{ LastTick = 0; Offset = 0; Total = $Targets.Count; Cancel = $false }
    $cb = New-SsmProgressCallback -Title 'Listing OneDrive Admins' -State $state -CancelMode 'Flag'

    $lines = New-Object System.Collections.ArrayList
    $done = 0
    $notListed = 0
    foreach ($tgt in $Targets) {
        if ($state.Cancel) { $notListed++; continue }
        $done++
        & $cb $done $Targets.Count (ConvertTo-SsmSafeDisplay $tgt.Title) $done 0
        # Cancel may also be raised synchronously inside the callback above
        # (matching the real Esc-then-confirm flow) - re-check before this
        # target is connected to or read, so a cancel noticed mid-callback
        # still stops before any further work, not just on the next loop turn.
        if ($state.Cancel) { $notListed++; continue }
        [void]$lines.Add(('{0}  {1}' -f (ConvertTo-SsmSafeDisplay $tgt.Title), (ConvertTo-SsmSafeDisplay $tgt.Url)))

        if (-not (Connect-SsmSite -Url $tgt.Url)) {
            Write-SsmLog -Message "Invoke-SsmOneDriveAdminList: site connection failed for target '$($tgt.Url)'" -Level WARN
            [void]$lines.Add('    -> site connection failed')
            [void]$lines.Add('')
            continue
        }
        # Explicit per-site connection, verified bound to the exact target
        # URL - never an imported/cached one - before the membership read is
        # trusted, matching Get-SsmOneDriveAdminState's own guard.
        $siteConn = Get-PnPConnection
        $connUrl = Get-SsmFieldValue -InputObject $siteConn -Name 'Url'
        if ($connUrl -and ([string]$connUrl).TrimEnd('/') -ne ([string]$tgt.Url).TrimEnd('/')) {
            Write-SsmLog -Message "Invoke-SsmOneDriveAdminList: connection bound to '$connUrl', not target '$($tgt.Url)'" -Level WARN
            [void]$lines.Add('    -> connection did not match target URL')
            [void]$lines.Add('')
            continue
        }

        try {
            $admins = @(Get-SsmOneDriveAdmins -Connection $siteConn)
        } catch {
            Write-SsmErrorLog -Context "Invoke-SsmOneDriveAdminList: admin read failed for target '$($tgt.Url)'" -ErrorRecord $_
            [void]$lines.Add(('    -> admin read failed: {0}' -f (ConvertTo-SsmSafeDisplay $_.Exception.Message)))
            [void]$lines.Add('')
            continue
        }

        if (@($admins).Count -eq 0) {
            [void]$lines.Add('    -> no administrators found')
            [void]$lines.Add('')
            continue
        }
        foreach ($a in $admins) {
            $title = [string](Get-SsmFieldValue -InputObject $a -Name 'Title')
            $upn = [string](Get-SsmFieldValue -InputObject $a -Name 'UserPrincipalName')
            $login = [string](Get-SsmFieldValue -InputObject $a -Name 'LoginName')
            $objId = $null
            $aadObj = Get-SsmFieldValue -InputObject $a -Name 'AadObjectId'
            if ($aadObj) {
                $nameId = Get-SsmFieldValue -InputObject $aadObj -Name 'NameId'
                if ($nameId) { $objId = [string]$nameId }
            }
            $parts = New-Object System.Collections.Generic.List[string]
            if ($title) { [void]$parts.Add((ConvertTo-SsmSafeDisplay $title)) } else { [void]$parts.Add('(unresolved)') }
            if ($upn) { [void]$parts.Add("<$(ConvertTo-SsmSafeDisplay $upn)>") }
            if ($login) { [void]$parts.Add("[$(ConvertTo-SsmSafeDisplay $login)]") }
            if ($objId) { [void]$parts.Add("{$(ConvertTo-SsmSafeDisplay $objId)}") }
            [void]$lines.Add('    - ' + ($parts -join ' '))
        }
        [void]$lines.Add('')
    }
    if ($notListed -gt 0) {
        [void]$lines.Add("Cancelled by operator; $notListed target(s) were not listed.")
    }

    Show-ReportModal -Title 'Current OneDrive Site Collection Admins' -Lines $lines.ToArray()
}

function Invoke-SsmOneDriveAdmin {
    # Sole UI entry point for OneDrive secondary-admin management. Consumes
    # Task 2/3's validation, preflight and guarded-mutation primitives
    # exactly as-is; this function owns selection freezing, confirmation,
    # sequential progress, evidence persistence and stop rules only.
    #
    # RELEASE-BLOCKED (see docs/superpowers/specs/2026-09-07-onedrive-admin-
    # api-validation.md): built and tested against mocked PnP/Graph calls
    # only, per the design's deferred live-validation gate.
    param($Tab)

    if (-not $Tab['OneDrive']) {
        Show-MsgModal -Title 'Manage Secondary Admin' -Lines @(
            'This action is only available on the OneDrives tab.') -Kind Warn
        return
    }

    $targets = @(Get-SsmOneDriveAdminSelectedTargets -Tab $Tab)
    if ($targets.Count -eq 0) {
        Show-MsgModal -Title 'Manage Secondary Admin' -Lines @('Nothing selected. Space selects targets.')
        return
    }

    $action = Show-ListModal -Title 'Manage Secondary Admin' `
        -Prompt 'Choose an operation' -Options @('List', 'Add', 'Remove')
    if (-not $action) { return }

    if ($action -eq 'List') {
        Invoke-SsmOneDriveAdminList -Targets $targets
        return
    }

    $enteredUpn = Show-InputModal -Title 'Secondary Admin Account' `
        -Prompt 'Enter the account UPN'
    if ($null -eq $enteredUpn) { return }
    $trimmedUpn = $enteredUpn.Trim()

    # Explicit tenant connection, captured before any per-target connect can
    # move the shared/default PnP connection elsewhere. Every read/write below
    # takes its connection object explicitly rather than relying on whichever
    # site Connect-SsmSite most recently cached as the default.
    if (-not (Connect-SsmAdmin)) {
        Show-MsgModal -Title 'Manage Secondary Admin' -Lines @(
            'Could not connect to the tenant admin site.') -Kind Error
        return
    }
    $adminConn = Get-PnPConnection

    try {
        $tenantId = Get-SsmConnectionTenantId -Connection $adminConn
    } catch {
        Write-SsmErrorLog -Context 'Invoke-SsmOneDriveAdmin: tenant identity lookup failed' -ErrorRecord $_
        Show-MsgModal -Title 'Manage Secondary Admin' -Lines @(
            'Could not determine the tenant identity - no changes were made:',
            (ConvertTo-SsmSafeDisplay $_.Exception.Message)) -Kind Error
        return
    }

    # Global account validation. A failure here stops the whole operation
    # before any target is touched, per the design's mandatory-validation
    # section.
    try {
        $identity = Resolve-SsmDirectoryUser -Upn $trimmedUpn -TenantId $tenantId -Connection $adminConn
    } catch {
        Write-SsmErrorLog -Context "Invoke-SsmOneDriveAdmin: account validation failed for '$trimmedUpn'" -ErrorRecord $_
        Show-MsgModal -Title 'Manage Secondary Admin' -Lines @(
            'Account validation failed - no changes were made:',
            (ConvertTo-SsmSafeDisplay $_.Exception.Message)) -Kind Error
        return
    }

    $actor = [string]$script:Conn.Account
    $operationId = [guid]::NewGuid()

    # Read-only preflight for every frozen target. A per-target connect or
    # state-read failure blocks only that target; the rest still reach
    # preview/confirmation.
    $rows = New-Object System.Collections.ArrayList
    foreach ($tgt in $targets) {
        $row = New-SsmOneDriveAdminRow -OperationId $operationId -TenantId $tenantId -Actor $actor `
            -Action $action -TargetUrl $tgt.Url -Title $tgt.Title -EnteredUpn $trimmedUpn -Identity $identity

        if (-not (Connect-SsmSite -Url $tgt.Url)) {
            $row.Result = 'Blocked'; $row.Classification = 'Failed'
            $row.Error = 'site connection failed'
            $row.ResultTimestampUtc = Get-SsmUtcNowStamp
            Write-SsmLog -Message "Invoke-SsmOneDriveAdmin: site connection failed for target '$($tgt.Url)'" -Level WARN
            [void]$rows.Add($row)
            continue
        }
        $siteConn = Get-PnPConnection
        try {
            $snapshot = Get-SsmOneDriveAdminState -Url $tgt.Url -Identity $identity -Connection $siteConn
        } catch {
            $row.Result = 'Blocked'; $row.Classification = 'Failed'
            $row.Error = "preflight read failed: $($_.Exception.Message)"
            $row.ResultTimestampUtc = Get-SsmUtcNowStamp
            Write-SsmErrorLog -Context "Invoke-SsmOneDriveAdmin: preflight read failed for target '$($tgt.Url)'" -ErrorRecord $_
            [void]$rows.Add($row)
            continue
        }
        $row.Snapshot = $snapshot
        $row.SiteConn = $siteConn
        $row.OwnerUpn = $snapshot.OwnerUpn
        $row.OwnerId = if ($snapshot.OwnerId) { "$($snapshot.OwnerId)" } else { $null }
        $row.PrimaryAdminUpn = $snapshot.PrimaryAdminUpn
        $row.PrimaryAdminId = if ($snapshot.PrimaryAdminId) { "$($snapshot.PrimaryAdminId)" } else { $null }
        $row.AdminLogin = $snapshot.AdminLogin
        $row.AdminBefore = $snapshot.AdminPresent

        $decision = Get-SsmOneDriveAdminDecision -Action $action -Identity $identity -Snapshot $snapshot
        $row.Classification = $decision
        $row.ResultTimestampUtc = Get-SsmUtcNowStamp
        switch ($decision) {
            'Eligible' { $row.Result = 'NotAttempted'; $row.Eligible = $true }
            'NoOp'     { $row.Result = 'NoOp'; $row.AdminAfter = $snapshot.AdminPresent }
            default    { $row.Result = 'Blocked'; $row.Error = "decision: $decision"; $row.AdminAfter = $snapshot.AdminPresent }
        }
        [void]$rows.Add($row)
    }
    $rows = @($rows)

    $eligible = @($rows | Where-Object { $_.Eligible })
    $blockedCount = @($rows | Where-Object { -not $_.Eligible -and $_.Classification -ne 'NoOp' -and $_.Classification -ne 'Failed' }).Count
    $failedCount = @($rows | Where-Object { $_.Classification -eq 'Failed' }).Count
    $noopCount = @($rows | Where-Object { $_.Classification -eq 'NoOp' }).Count

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(('{0}  <{1}>' -f (ConvertTo-SsmSafeDisplay $identity.DisplayName), $identity.Upn))
    [void]$lines.Add('Object ID : ' + $identity.Id)
    [void]$lines.Add('Tenant    : ' + $tenantId)
    [void]$lines.Add('')
    [void]$lines.Add('A secondary administrator has full access to the whole OneDrive.')
    [void]$lines.Add('')
    foreach ($row in $rows) {
        [void]$lines.Add(('[{0}] {1}  {2}' -f $row.Classification, (ConvertTo-SsmSafeDisplay $row.TargetUrl), (ConvertTo-SsmSafeDisplay $row.Title)))
        if (($row.Classification -eq 'Failed' -or $row.Classification -eq 'Blocked') -and $row.Error) {
            [void]$lines.Add(('    -> {0}' -f (ConvertTo-SsmSafeDisplay $row.Error)))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add(('Selected: {0}   Eligible: {1}   No-op: {2}   Blocked: {3}   Failed: {4}' `
        -f $rows.Count, $eligible.Count, $noopCount, $blockedCount, $failedCount))

    if ($eligible.Count -eq 0) {
        # Nothing destructive to confirm - still write both evidence reports,
        # and only ever claim a path was saved once the export call actually
        # returned it - a failed export must never be reported as saved.
        foreach ($row in $rows) {
            $detail = if ($row.Error) { " - $(ConvertTo-SsmSafeDisplay $row.Error)" } else { '' }
            Write-SsmLog -Message ("Manage Secondary Admin: action={0} target={1} result={2}{3}" `
                -f $action, $row.TargetUrl, $row.Result, $detail)
        }
        $beforePath = $null; $afterPath = $null; $exportError = $null
        try {
            $beforePath = Export-SsmAdminCsv -Rows $rows -OperationId $operationId -Phase BEFORE
            $afterPath = Export-SsmAdminCsv -Rows $rows -OperationId $operationId -Phase AFTER
        } catch {
            $exportError = $_
            Write-SsmErrorLog -Context 'Invoke-SsmOneDriveAdmin: zero-eligible evidence export failed' -ErrorRecord $_
        }
        if ($beforePath) { [void]$lines.Add("BEFORE evidence saved: $beforePath") }
        if ($afterPath) { [void]$lines.Add("AFTER evidence saved: $afterPath") }
        Show-ReportModal -Title 'Manage Secondary Admin' -Lines $lines.ToArray()
        if ($exportError) {
            Show-MsgModal -Title 'Manage Secondary Admin' -Lines @(
                'Evidence export failed:', (ConvertTo-SsmSafeDisplay $exportError.Exception.Message)) -Kind Error
        }
        return
    }

    $word = if ($action -eq 'Add') { 'ADDADMIN' } else { 'REMOVEADMIN' }
    if (-not (Show-TypedConfirmModal -Title 'Confirm Admin Change' -Lines $lines.ToArray() -Word $word)) { return }

    # BEFORE, then the initial AFTER (all rows NotAttempted/terminal), must
    # both succeed before the first mutation. Actual saved paths are kept so
    # the completion report can show real evidence locations, not an assumed
    # or fabricated one.
    $beforePath = $null; $afterPath = $null
    try {
        $beforePath = Export-SsmAdminCsv -Rows $rows -OperationId $operationId -Phase BEFORE
    } catch {
        Write-SsmErrorLog -Context 'Invoke-SsmOneDriveAdmin: BEFORE evidence export failed' -ErrorRecord $_
        Show-MsgModal -Title 'Manage Secondary Admin' -Lines @(
            'Could not write BEFORE evidence - no changes were made:', (ConvertTo-SsmSafeDisplay $_.Exception.Message)) -Kind Error
        return
    }
    try {
        $afterPath = Export-SsmAdminCsv -Rows $rows -OperationId $operationId -Phase AFTER
    } catch {
        Write-SsmErrorLog -Context 'Invoke-SsmOneDriveAdmin: initial AFTER evidence export failed' -ErrorRecord $_
        Show-MsgModal -Title 'Manage Secondary Admin' -Lines @(
            'Could not write initial AFTER evidence - no changes were made:', (ConvertTo-SsmSafeDisplay $_.Exception.Message)) -Kind Error
        return
    }

    $state = @{ LastTick = 0; Offset = 0; Total = $eligible.Count; Cancel = $false }
    $cb = New-SsmProgressCallback -Title 'Updating OneDrive Admins' -State $state -CancelMode 'Flag'
    $processed = 0; $ok = 0; $failed = 0
    $stopped = $false; $stopReason = ''
    Start-LoadSpinner
    try {
        Write-ProgressModal -Title 'Updating OneDrive Admins' -Done 0 -Total $eligible.Count -Label '' -Ok 0 -Failed 0
        foreach ($row in $eligible) {
            if ($state.Cancel) {
                $row.Result = 'Cancelled'; $row.Error = 'cancelled by operator'
                $row.ResultTimestampUtc = Get-SsmUtcNowStamp
                continue
            }
            if ($stopped) {
                $row.Error = "batch stopped: $stopReason"
                $row.ResultTimestampUtc = Get-SsmUtcNowStamp
                continue
            }
            $processed++
            & $cb $processed $eligible.Count (ConvertTo-SsmSafeDisplay $row.TargetUrl) $ok $failed

            $outcome = Invoke-SsmOneDriveAdminChange -Action $action -Identity $identity `
                -Snapshot $row.Snapshot -Connection $row.SiteConn
            $row.Result = $outcome.Result
            $row.Error = $outcome.Detail
            $row.ResultTimestampUtc = Get-SsmUtcNowStamp
            # outcome.After: read via Get-SsmFieldValue rather than dot
            # access - StrictMode throws on a missing hashtable key, and
            # older/partial mutation-result shapes (and several test stubs)
            # legitimately omit 'After'.
            $observedAfter = Get-SsmFieldValue -InputObject $outcome -Name 'After'
            switch ($outcome.Result) {
                'Success'    { $row.AdminAfter = $observedAfter; $ok++ }
                'NoOp'       { $row.AdminAfter = $observedAfter }
                'Blocked'    { $row.AdminAfter = $observedAfter; $failed++ }
                'Unverified' { $row.AdminAfter = $observedAfter; $failed++ }
                'Failed'     { $row.AdminAfter = $observedAfter; $failed++ }
                default {
                    $row.Result = 'Unverified'
                    $row.Error = "unexpected mutation result '$($outcome.Result)': $($outcome.Detail)"
                    $row.AdminAfter = $null
                    $failed++
                    $stopped = $true
                    $stopReason = $row.Error
                }
            }

            try {
                $afterPath = Export-SsmAdminCsv -Rows $rows -OperationId $operationId -Phase AFTER
            } catch {
                Write-SsmErrorLog -Context "Invoke-SsmOneDriveAdmin: post-mutation AFTER evidence export failed for target '$($row.TargetUrl)'" -ErrorRecord $_
                $stopped = $true
                $stopReason = "evidence write failed: $($_.Exception.Message)"
            }
            if (-not $stopped -and $outcome.StopBatch) {
                $stopped = $true
                $stopReason = $outcome.Detail
            }
        }
    } finally {
        Stop-LoadSpinner
    }
    # Final flush so Cancelled/stopped reasons on untouched rows are durable.
    # A failure here must be visible in the completion report, not only
    # logged - the operator needs to know the last AFTER evidence write may
    # be stale/incomplete, not silently assume it succeeded.
    $finalFlushError = $null
    try {
        $afterPath = Export-SsmAdminCsv -Rows $rows -OperationId $operationId -Phase AFTER
    } catch {
        Write-SsmErrorLog -Context 'Invoke-SsmOneDriveAdmin: final AFTER evidence flush failed' -ErrorRecord $_
        $finalFlushError = $_.Exception.Message
    }

    $summary = New-Object System.Collections.ArrayList
    [void]$summary.Add(("Processed {0} of {1} eligible target(s)." -f $processed, $eligible.Count))
    if ($state.Cancel) { [void]$summary.Add('Cancelled by operator; remaining eligible targets were not processed.') }
    elseif ($stopped) { [void]$summary.Add("Stopped: $(ConvertTo-SsmSafeDisplay $stopReason)") }
    if ($finalFlushError) {
        [void]$summary.Add("Evidence flush failed - the last AFTER evidence write may be stale: $(ConvertTo-SsmSafeDisplay $finalFlushError)")
    }
    if ($beforePath) { [void]$summary.Add("BEFORE evidence saved: $beforePath") }
    if ($afterPath) { [void]$summary.Add("AFTER evidence saved: $afterPath") }
    [void]$summary.Add('')
    foreach ($row in $rows) {
        $detail = if ($row.Error) { " - $(ConvertTo-SsmSafeDisplay $row.Error)" } else { '' }
        [void]$summary.Add(('{0}: {1}{2}' -f (ConvertTo-SsmSafeDisplay $row.TargetUrl), $row.Result, $detail))
        # Outcome classification summary per target (URL/action/result only -
        # never the entered/resolved UPN or any token/credential).
        Write-SsmLog -Message ("Manage Secondary Admin: action={0} target={1} result={2}{3}" `
            -f $action, $row.TargetUrl, $row.Result, $detail)
    }
    Show-ReportModal -Title 'Manage Secondary Admin complete' -Lines $summary.ToArray()
    Update-TabView -Tab $Tab
}

function Invoke-SsmOneDriveProvision {
    # P on the OneDrives tab. Context-aware:
    #   no placeholder rows loaded      -> query Graph + tenant, add rows, switch to Unprovisioned filter
    #   selected Unprovisioned rows     -> typed PROVISION, request only those
    #   rows loaded, nothing selected   -> hint
    param($Tab)
    $title = 'Pre-provision OneDrives'
    if (-not $Tab['OneDrive']) {
        Show-MsgModal -Title $title -Lines @('This action is only available on the OneDrives tab.') -Kind Warn
        return
    }

    $placeholders = @($Tab['Items'] | Where-Object { Test-SsmPlaceholderTarget -Target $_ })
    if ($placeholders.Count -eq 0) {
        # Connect first: a list restored from the session cache has not opened
        # any PnP connection yet, and the Graph call below uses the current one.
        # Connect-SsmAdmin reports its own failure.
        if (-not (Connect-SsmAdmin)) { return }
        Start-LoadSpinner
        Write-ProgressModal -Title $title -Done 0 -Total 0 -Label 'Querying Graph for licensed users' -Ok 0 -Failed 0
        try {
            $licensed = @(Get-SsmLicensedUsers -Progress { param($n)
                Write-ProgressModal -Title $title -Done $n -Total 0 -Label 'Querying Graph for licensed users' -Ok 0 -Failed 0 })
        } catch {
            Stop-LoadSpinner
            Write-SsmErrorLog -Context 'Pre-provision: Graph user query failed' -ErrorRecord $_
            $msg = $_.Exception.Message
            $lines = if ($msg -match '403|Forbidden|Authorization_RequestDenied') {
                @('Graph returned 403.', '', 'Delegated sign-in needs User.Read.All;',
                  'app-only registrations need the User.Read.All application permission.')
            } else { @('Graph user query failed:', $msg) }
            Show-MsgModal -Title $title -Lines $lines -Kind Error
            return
        }
        Write-ProgressModal -Title $title -Done 0 -Total 0 -Label 'Enumerating personal sites' -Ok 0 -Failed 0
        try {
            $ownerSet = Get-SsmProvisionedOwnerSet -Progress { param($n)
                Write-ProgressModal -Title $title -Done $n -Total 0 -Label 'Enumerating personal sites' -Ok 0 -Failed 0 }
        } finally { Stop-LoadSpinner }
        if ($null -eq $ownerSet) { return }   # Connect-SsmAdmin already reported the failure

        $missing = @(Get-SsmUnprovisionedUsers -Licensed $licensed -OwnerSet $ownerSet)
        Write-SsmLog -Message ("Pre-provision: {0} licensed, {1} personal sites, {2} unprovisioned." -f $licensed.Count, $ownerSet.Count, $missing.Count)
        if ($missing.Count -eq 0) {
            Show-MsgModal -Title $title -Lines @('No unprovisioned licensed users found.')
            return
        }
        $csv = Export-SsmProvisionCsv -Rows $missing -Phase UNPROVISIONED
        Add-TargetsToTab -Tab $Tab -Targets @($missing | ForEach-Object { New-SsmPlaceholderTarget -User $_ })
        $Tab['Filter'] = 'Unprovisioned'
        $Tab['Cursor'] = 0
        Update-TabView -Tab $Tab
        Show-MsgModal -Title $title -Lines @(
            ("{0} unprovisioned user(s) loaded under the Unprovisioned filter." -f $missing.Count),
            "CSV: $csv", '',
            'Space/A selects rows, P provisions the selection.')
        return
    }

    $chosen = @($placeholders | Where-Object { $_.Selected -and $_.Status -eq 'Unprovisioned' })
    if ($chosen.Count -eq 0) {
        Show-MsgModal -Title $title -Kind Warn -Lines @(
            'Nothing selected.', '',
            'F to the Unprovisioned filter, Space/A to select, then P.',
            'C clears the list so P can reload it.')
        return
    }

    $confirm = @(("Request OneDrive provisioning for {0} user(s)?" -f $chosen.Count), '',
        'SharePoint queues the work and provisions asynchronously (minutes to hours).', '',
        'After confirming, a browser sign-in opens: sign in as a SharePoint',
        'Administrator. Provisioning must go through Microsoft''s SharePoint Online',
        'Management Shell client - app-only and custom-app tokens are rejected by',
        'the service (pnp/powershell#4329). The tool''s own connection is unchanged.', '') +
        @($chosen | ForEach-Object { "  $($_.Upn)" })
    if (-not (Show-TypedConfirmModal -Title $title -Lines $confirm -Word 'PROVISION')) { return }

    try {
        $provConn = Connect-SsmProvisioningSession
        # Back from the main buffer: the alternate screen was cleared on
        # re-entry, so repaint before drawing progress on top of it.
        Write-Screen
    } catch {
        Write-SsmErrorLog -Context 'Pre-provision: interactive SPO Management Shell sign-in failed' -ErrorRecord $_
        Show-MsgModal -Title $title -Kind Error -Lines @('Sign-in for provisioning failed or was cancelled:', $_.Exception.Message, '', 'Nothing was submitted.')
        return
    }

    $upns = @($chosen | ForEach-Object { $_.Upn })
    # Each batch is one blocking Request-PnPPersonalSite call and the callback
    # only fires when a batch finishes, so paint the modal (with a background
    # spinner) before the first call or a single-batch run shows nothing.
    $batchTotal = [Math]::Ceiling($upns.Count / 200)
    Start-LoadSpinner
    Write-ProgressModal -Title $title -Done 0 -Total $batchTotal -Label 'Submitting provisioning batches' -Ok 0 -Failed 0
    try {
        $rows = @(Invoke-SsmPersonalSiteRequest -Upns $upns -Connection $provConn -Progress { param($b, $t)
            Write-ProgressModal -Title $title -Done $b -Total $t -Label 'Submitting provisioning batches' -Ok 0 -Failed 0 })
    } finally { Stop-LoadSpinner }
    $ok = @{}
    foreach ($r in $rows) { if ($r.Status -eq 'Requested') { $ok[$r.Upn] = $true } }
    foreach ($c in $chosen) {
        if ($ok.ContainsKey($c.Upn)) { $c.Status = 'ProvisionRequested'; $c.Selected = $false }
    }
    if ($Tab.ContainsKey('View')) { Update-TabView -Tab $Tab }
    $reqCsv = Export-SsmProvisionCsv -Rows $rows -Phase REQUESTED
    $failed = $rows.Count - $ok.Count
    $lines = @(
        ("Requested {0} user(s); {1} failed." -f $ok.Count, $failed),
        "CSV: $reqCsv", '',
        'SharePoint provisions personal sites asynchronously.',
        'Rows now show Requested. C then P reloads the list to verify later.')
    if ($failed -gt 0) {
        $firstErr = [string](@($rows | Where-Object { $_.Status -eq 'Failed' })[0].Error)
        $lines += @('', "First error: $firstErr", '') + (Get-SsmProvisionFailureHint)
    }
    Show-MsgModal -Title $title -Kind ($failed -gt 0 ? 'Warn' : 'Info') -Lines $lines
}

function Get-TabHints {
    param($Tab)
    if ($script:UI.SearchMode) { return @() }
    switch ($Tab['Kind']) {
        'Targets' {
            if ($Tab['Mode'] -eq 'Findings') {
                $revokeHint = if ($Tab['FTab']['Aggregate']) { 'revoke all sites' } else { 'revoke selected' }
                return @(@('Spc','select'),@('A','all'),@('N','none'),@('/','find'),@('F','filter'),
                         @('R',$revokeHint),@('E','export'),@('Esc','back'),@('?','help'),@('Q','quit'))
            }
            $base = @(@('Spc','select'),@('A','all'),@('N','none'),@('/','find'),@('F','filter'),
                     @('S','scan'),@('X','scan all'),@('T','rules'),@('G','all findings'),
                     @('R','revoke selected'),@('U','add url'),@('I','import csv'),
                     @('Enter','open/load'),@('C','reload'),@('L','restore'),@('E','export'))
            if ($Tab['OneDrive']) { $base += @(,@('M','manage admins'),@('P','pre-provision')) }
            return $base + @(@('?','help'),@('Q','quit'))
        }
        'Tenant' { return @(@('Up/Dn','move'),@('Enter','load/change'),@('R','refresh'),@('C','apply CIS'),@('Z','undo CIS'),@('T','switch'),@('1-6/←/→','tab'),@('?','help'),@('Q','quit')) }
        'Setup'  { return @(@('Up/Dn','move'),@('Enter','actions'),@('A','add tenant'),@('T','switch'),@('1-6/←/→','tab'),@('?','help'),@('Q','quit')) }
        'Log'    { return @(@('Up/Dn','scroll'),@('O','open log file'),@('T','switch'),@('←/→','tab'),@('?','help'),@('Q','quit')) }
        'About'  { return @(@('G','github'),@('R','releases'),@('T','switch'),@('←/→','tab'),@('?','help'),@('Q','quit')) }
    }
    return @()
}

function Write-Screen {
    $size = Get-ConsoleSize
    $W = $size[0]; $H = $size[1]
    $script:UI.W = $W; $script:UI.H = $H
    $sb = New-Object System.Text.StringBuilder

    if ($W -lt 80 -or $H -lt 20) {
        [void]$sb.Append("$script:ESC[2J$script:ESC[H")
        [void]$sb.Append($script:T.Warn + "Terminal too small ($W x $H). Please resize to at least 80x20." + $script:T.Reset)
        [Console]::Write($sb.ToString())
        return
    }

    Add-TitleBar -Sb $sb -W $W
    Add-TabBar -Sb $sb -W $W

    $tab = $script:Tabs[$script:UI.Tab]
    switch ($tab['Kind']) {
        'Targets' {
            if ($tab['Mode'] -eq 'Findings') { Add-FindingsView -Sb $sb -Tab $tab -W $W -H $H }
            else { Add-TargetsView -Sb $sb -Tab $tab -W $W -H $H }
        }
        'Tenant' { Add-TenantView -Sb $sb -W $W -H $H }
        'Setup'  { Add-SetupView -Sb $sb -W $W -H $H }
        'Log'    { Add-LogView -Sb $sb -W $W -H $H }
        'About'  { Add-AboutView -Sb $sb -W $W -H $H }
    }

    # footer
    $activeSearchState = if ($tab['Kind'] -eq 'Targets' -and $tab['Mode'] -eq 'Findings') { $tab['FTab'] } else { $tab }
    if ($script:UI.SearchMode -and $tab['Kind'] -eq 'Targets') {
        $t = $script:T
        $search = ' /' + $activeSearchState['Search'] + '_'
        $hint = '   Enter keep   Esc clear'
        $padLen = $script:UI.W - $search.Length - $hint.Length
        if ($padLen -lt 0) { $padLen = 0 }
        $footer = $t.FootBg + $t.FootKey + $search + $t.FootTxt + $hint + (' ' * $padLen)
        Add-FrameLine -Sb $sb -Row $H -Content $footer
    } else {
        Add-FrameLine -Sb $sb -Row $H -Content (Get-FooterBar -Hints (Get-TabHints -Tab $tab) -Width $W)
    }

    [Console]::Write($sb.ToString())
}

#endregion
