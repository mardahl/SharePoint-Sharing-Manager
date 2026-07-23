# ============================================================================
#region Views
# ============================================================================

function Update-TabView {
    # Filter + sort targets. Filter: All | NotScanned | Clean | Findings | Failed.
    param($Tab)
    $items = @($Tab['Items'])
    switch ($Tab['Filter']) {
        'NotScanned' { $items = @($items | Where-Object { $_.Status -eq 'NotScanned' }) }
        'Clean'      { $items = @($items | Where-Object { $_.Status -eq 'Clean' }) }
        'Findings'   { $items = @($items | Where-Object { $_.Status -eq 'Findings' -or $_.Status -eq 'Revoked' }) }
        'Failed'     { $items = @($items | Where-Object { $_.Status -like '*Failed' }) }
    }
    if (-not [string]::IsNullOrEmpty($Tab['Search'])) {
        $n = $Tab['Search']
        $items = @($items | Where-Object { ($_.Url -like "*$n*") -or ($_.Title -like "*$n*") })
    }
    $prop = $Tab['SortCol']   # Url | Title | Status | Findings
    $expr = switch ($prop) { 'Findings' { { $_.FindingCount } } default { { $_.$prop } } }
    $items = if ($Tab['SortDesc']) { @($items | Sort-Object -Property $expr -Descending) } else { @($items | Sort-Object -Property $expr) }
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
    # ' ' sel(3) ' ' Title(flex 35%) '  ' Url(flex 65%) '  ' Findings(8) '  ' Status(13)
    $fixed = 1 + 3 + 1 + 2 + 2 + 8 + 2 + 13
    $flex = $W - $fixed - 1
    if ($flex -lt 20) { $flex = 20 }
    $titleW = [int]($flex * 0.35)
    $urlW = $flex - $titleW
    return @{ Title = $titleW; Url = $urlW; Findings = 8; Status = 13 }
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
    if (-not [string]::IsNullOrEmpty($Tab['Search'])) { $ctx += ('   search:"' + $Tab['Search'] + '"') }
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
    # ' ' sel(3) ' ' [Site(22) '  '] Category(20) '  ' Loc(7) '  ' Name(flex 40%) '  ' Principal(flex 60%) '  ' Status(12)
    $fixed = 1 + 3 + 1 + $siteFixed + 20 + 2 + 7 + 2 + 2 + 2 + 12
    $flex = $W - $fixed - 1
    if ($flex -lt 20) { $flex = 20 }
    $nameW = [int]($flex * 0.4)
    $principalW = $flex - $nameW
    return @{ Site = $siteW; Category = 20; Loc = 7; Name = $nameW; Principal = $principalW; Status = 12 }
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
    $head = ' ' + (Get-PadCell 'sel' 3) + ' ' + $siteHead + (Get-PadCell 'Category' $col.Category) + '  ' + (Get-PadCell 'Loc' $col.Loc) + '  ' + (Get-PadCell 'Name' $col.Name) + '  ' + (Get-PadCell 'Principal' $col.Principal) + '  ' + (Get-PadCell 'Status' $col.Status)
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
    $sel = @($Tab['Items'] | Where-Object { $_.Selected })
    if ($sel.Count -eq 0) { Show-MsgModal -Title 'Scan' -Lines @('Nothing selected. Space selects targets.') ; return }
    $cats = @($Tab['Categories'])
    if ($cats.Count -eq 0) { Show-MsgModal -Title 'Scan' -Lines @('No rule categories enabled. Press T to enable some.') -Kind Warn; return }
    $i = 0
    foreach ($t in $sel) {
        $i++
        $t.Status = 'Scanning'; Write-Screen
        Start-LoadSpinner
        Write-ProgressModal -Title ("Scanning {0}/{1}" -f $i, $sel.Count) -Done 0 -Total 0 -Label $t.Url -Ok 0 -Failed 0
        $fnProgress = ${function:Write-ProgressModal}
        $state = @{ LastTick = 0 }
        $cb = {
            param($Count, $Label)
            while ([Console]::KeyAvailable) {
                if ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Escape) { throw (New-Object System.OperationCanceledException 'Scan cancelled.') }
            }
            $now = [Environment]::TickCount
            if (($now - $state.LastTick) -lt 150) { return }
            $state.LastTick = $now
            & $fnProgress -Title 'Scanning' -Done $Count -Total 0 -Label $Label -Ok 0 -Failed 0
        }.GetNewClosure()
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

function Invoke-TabScanAll {
    # Enumerate if empty, then scan every NotScanned target. Cache is saved
    # after each target by Invoke-TabScan, so an interrupted run resumes.
    param($Tab)
    if (-not $Tab['Loaded'] -or @($Tab['Items']).Count -eq 0) {
        Start-LoadSpinner
        Write-ProgressModal -Title 'Enumerating tenant' -Done 0 -Total 0 -Label ($Tab['OneDrive'] ? 'Loading OneDrives...' : 'Loading sites...') -Ok 0 -Failed 0
        try { $targets = Get-TenantTargets -OneDrive $Tab['OneDrive'] } finally { Stop-LoadSpinner }
        Add-TargetsToTab -Tab $Tab -Targets $targets
    }
    foreach ($it in @($Tab['Items'])) { $it.Selected = ($it.Status -eq 'NotScanned') }
    if (@($Tab['Items'] | Where-Object { $_.Selected }).Count -eq 0) {
        Show-MsgModal -Title 'Scan all' -Lines @('No unscanned targets remain. Everything here is already scanned.')
        return
    }
    Invoke-TabScan -Tab $Tab
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
        ("Remove {0} link(s)/grant(s) on" -f $sel.Count), $target.Url, '') + $byCat + @('', 'Files and folders are never deleted. This cannot be undone.'))
    if (-not $ok) { return }
    if (-not (Connect-SsmSite -Url $target.Url)) { return }
    $removed = Invoke-Revoke -Findings $sel
    [void](Export-FindingsCsv -Findings @($ft['Items']) -SiteUrl $target.Url -Phase 'REVOKED')
    $target.FindingCount = @($target.Findings | Where-Object { $_.RevokeStatus -ne 'Removed' -and $_.RevokeStatus -ne 'AlreadyRevoked' }).Count
    if ($target.FindingCount -eq 0) { $target.Status = 'Revoked' }
    Show-ReportModal -Title 'Revoke complete' -Lines @(("Removed {0} of {1}. Evidence CSV written." -f $removed, $sel.Count))
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
    $lines  = @(("Remove {0} link(s)/grant(s) across {1} site(s):" -f $sel.Count, $groups.Count), '')
    foreach ($g in $groups) { $lines += ("  {0}: {1}" -f $g.Name, @($g.Group).Count) }
    $lines += @('', 'Files and folders are never deleted. This cannot be undone.')
    if (-not (Show-TypedConfirmModal -Title 'Bulk revoke sharing' -Word 'REVOKE' -Lines $lines)) { return }

    $totalRemoved = 0; $siteReport = @()
    foreach ($g in $groups) {
        if (-not (Connect-SsmSite -Url $g.Name)) {
            $siteReport += ("{0}: connect failed" -f $g.Name); continue
        }
        $removed = Invoke-Revoke -Findings @($g.Group)
        [void](Export-FindingsCsv -Findings @($g.Group) -SiteUrl $g.Name -Phase 'REVOKED')
        $totalRemoved += $removed
        $siteReport += ("{0}: removed {1} of {2}" -f $g.Name, $removed, @($g.Group).Count)
        if (Get-Command Save-SsmCache -ErrorAction SilentlyContinue) { Save-SsmCache }
    }
    Update-TabTargetStatuses -Tab $Tab
    Show-ReportModal -Title 'Bulk revoke complete' -Lines (@(("Removed {0} of {1} across {2} site(s)." -f $totalRemoved, $sel.Count, $groups.Count), '') + $siteReport)
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

    $rows = @(
        @{ Label = 'SharingCapability';                  Value = $p.SharingCapability;                  Note = 'Tenant-wide external sharing level for SharePoint sites.' }
        @{ Label = 'OneDriveSharingCapability';           Value = $p.OneDriveSharingCapability;          Note = 'External sharing level for OneDrive for Business.' }
        @{ Label = 'DefaultSharingLinkType';              Value = $p.DefaultSharingLinkType;             Note = 'Link type pre-selected in the sharing dialog.' }
        @{ Label = 'DefaultLinkPermission';               Value = $p.DefaultLinkPermission;              Note = 'Permission pre-selected in the sharing dialog.' }
        @{ Label = 'RequireAnonymousLinksExpireInDays';   Value = $p.RequireAnonymousLinksExpireInDays;  Note = 'Days before anonymous links auto-expire (-1 = never).' }
        @{ Label = 'ShowEveryoneClaim';                    Value = $p.ShowEveryoneClaim;                  Note = 'Show "Everyone" in People Picker (False = hidden, recommended).' }
        @{ Label = 'ShowAllUsersClaim';                    Value = $p.ShowAllUsersClaim;                  Note = 'Show "All Users (x)" org-wide claims in People Picker.' }
        @{ Label = 'ShowEveryoneExceptExternalUsersClaim'; Value = $p.ShowEveryoneExceptExternalUsersClaim; Note = 'Show "Everyone except external users" (EEEU) in People Picker.' }
        @{ Label = 'AllowEEEUClaimInPrivateSite';          Value = $p.AllowEveryoneExceptExternalUsersClaimInPrivateSite; Note = 'Allow EEEU claim in private sites specifically.' }
    )
    $idx = 0
    foreach ($r in $rows) {
        if ($row -gt ($H - 3)) { break }
        $isCur = ($idx -eq $cursor)
        $arrow = [string]$script:G.Arrow
        $marker = if ($isCur) { $t.CtxHi + $arrow + ' ' } else { ' ' * ($arrow.Length + 1) }
        $labelStyle = if ($isCur) { $t.CursorFg } else { $t.CtxHi }
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $marker + $labelStyle + (Get-PadCell $r.Label 38) + $t.Reset + $t.Row + ': ' + $r.Value); $row++
        if ($row -le ($H - 2)) { Add-FrameLine -Sb $Sb -Row $row -Content ($pad + '   ' + $t.Muted + $r.Note); $row++ }
        $row++
        $idx++
    }
}

function Add-SetupView {
    param([System.Text.StringBuilder]$Sb, [int]$W, [int]$H)
    $t = $script:T
    Add-FrameLine -Sb $Sb -Row 3 -Content ($t.Ctx + ' Sign-in configuration')
    for ($r = 4; $r -le ($H - 1); $r++) { Add-FrameLine -Sb $Sb -Row $r -Content '' }

    $margin = 4; $row = 5; $pad = ' ' * $margin
    $valueW = [Math]::Max(20, $W - $margin - 14)
    $a = $script:Auth

    $modeText = if ($a.AuthMode) { $a.AuthMode } else { '(not configured)' }
    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'Auth mode   : ' + $t.CtxHi + $modeText); $row++
    $clientIdText = if ($a.ClientId) { $a.ClientId } else { '(none)' }
    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'Client Id   : ' + $t.CtxHi + $clientIdText); $row++
    $tenantText = if ($a.Tenant) { $a.Tenant } else { '(none)' }
    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'Tenant      : ' + $t.CtxHi + $tenantText); $row++
    $adminText = if ($a.AdminUrl) { Get-PadCell $a.AdminUrl $valueW } else { '(none)' }
    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'Admin URL   : ' + $t.CtxHi + $adminText); $row++

    $certRef = if ($a.Thumbprint) { $a.Thumbprint } elseif ($a.CertPath) { $a.CertPath } else { '' }
    $certText = if ($certRef) { $certRef } else { '(none)' }
    $daysLeft = Get-CertDaysLeft
    $certStyle = $t.CtxHi
    if ($null -ne $daysLeft) {
        if ($daysLeft -lt 30) { $certStyle = $t.Warn }
        $certText += (' (expires {0}, {1} days left)' -f $a.CertExpires, $daysLeft)
    }
    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'Certificate : ' + $certStyle + $certText); $row++
    $row++

    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'Config file : ' + $t.Row + (Get-PadCell $script:ConfigPath $valueW)); $row++
    $row++

    $pnp = Get-Module -ListAvailable -Name 'PnP.PowerShell' | Sort-Object Version -Descending | Select-Object -First 1
    $pnpText = if ($pnp) { 'installed (v' + $pnp.Version + ')' } else { 'not installed' }
    Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Muted + 'PnP module  : ' + $t.CtxHi + $pnpText); $row++
    $row++

    $legend = @(
        'D  register a delegated (interactive) app registration',
        'C  register a certificate (app-only) app registration',
        'W  renew the app-only certificate',
        'X  edit the config file directly'
    )
    foreach ($ln in $legend) {
        if ($row -gt ($H - 1)) { break }
        Add-FrameLine -Sb $Sb -Row $row -Content ($pad + $t.Row + $ln); $row++
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

function Get-TabHints {
    param($Tab)
    if ($script:UI.SearchMode) { return @() }
    switch ($Tab['Kind']) {
        'Targets' {
            if ($Tab['Mode'] -eq 'Findings') {
                return @(@('Spc','select'),@('A','all'),@('N','none'),@('/','find'),@('F','filter'),
                         @('R','revoke selected'),@('E','export'),@('Esc','back'),@('?','help'),@('Q','quit'))
            }
            return @(@('Spc','select'),@('A','all'),@('N','none'),@('/','find'),@('F','filter'),
                     @('S','scan'),@('T','rules'),@('U','add url'),@('I','import csv'),
                     @('Enter','open/load'),@('E','export'),@('?','help'),@('Q','quit'))
        }
        'Tenant' { return @(@('Up/Dn','move'),@('Enter','load/change'),@('R','refresh'),@('1-5','tab'),@('?','help'),@('Q','quit')) }
        'Setup'  { return @(@('D','delegated app'),@('C','cert app'),@('W','renew cert'),@('X','edit config'),@('?','help'),@('Q','quit')) }
        'Log'    { return @(@('Up/Dn','scroll'),@('O','open log file'),@('?','help'),@('Q','quit')) }
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
