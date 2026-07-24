# ============================================================================
#region Key dispatch
# ============================================================================

function Get-SsmUrlLauncher {
    # Pure: choose the browser-launch command for a URL given platform flags.
    # Windows shell-associates the https URL directly (Exe = the URL, no args);
    # macOS/Linux pass the URL as an argument to open / xdg-open.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][bool]$IsWin,
        [Parameter(Mandatory)][bool]$IsMac
    )
    if ($IsWin) { return @{ Exe = $Url;        Args = @() } }
    if ($IsMac) { return @{ Exe = 'open';      Args = @($Url) } }
    return             @{ Exe = 'xdg-open'; Args = @($Url) }
}

function Open-SsmUrl {
    # Launch the default browser to $Url on any platform. Best-effort:
    # surfaces failures through the standard error modal.
    param([Parameter(Mandatory)][string]$Url)
    $isMac = [bool]($PSVersionTable.PSVersion.Major -ge 6 -and
              (Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS)
    $l = Get-SsmUrlLauncher -Url $Url -IsWin $script:IsWin -IsMac $isMac
    try {
        if (@($l.Args).Count -gt 0) { Start-Process $l.Exe -ArgumentList $l.Args }
        else                        { Start-Process $l.Exe }
        Write-SsmLog -Message ("Opened URL in browser: {0}" -f $Url)
    } catch {
        Show-MsgModal -Title 'About' -Lines @('Could not open the browser:', $_.Exception.Message) -Kind Error
    }
}

function Invoke-TargetsKey {
    param($Tab, [System.ConsoleKeyInfo]$K)

    # search mode captures input first
    if ($script:UI.SearchMode) {
        if ($K.Key -eq 'Escape') { $script:UI.SearchMode = $false; $Tab['Search'] = ''; Update-TabView -Tab $Tab; return }
        if ($K.Key -eq 'Enter')  { $script:UI.SearchMode = $false; return }
        if ($K.Key -eq 'Backspace') {
            if ($Tab['Search'].Length -gt 0) { $Tab['Search'] = $Tab['Search'].Substring(0, $Tab['Search'].Length - 1); Update-TabView -Tab $Tab }
            return
        }
        if ($K.KeyChar -and -not [char]::IsControl($K.KeyChar)) {
            $Tab['Search'] = $Tab['Search'] + $K.KeyChar
            $Tab['Cursor'] = 0
            Update-TabView -Tab $Tab
        }
        return
    }

    $view = @($Tab['View'])
    $cap = [Math]::Max(1, $script:UI.H - 5)

    switch ($K.Key) {
        'UpArrow'   { if ($Tab['Cursor'] -gt 0) { $Tab['Cursor']-- }; return }
        'DownArrow' { if ($Tab['Cursor'] -lt ($view.Count - 1)) { $Tab['Cursor']++ }; return }
        'PageUp'    { $Tab['Cursor'] = [Math]::Max(0, $Tab['Cursor'] - $cap); return }
        'PageDown'  { $Tab['Cursor'] = [Math]::Min([Math]::Max(0, $view.Count - 1), $Tab['Cursor'] + $cap); return }
        'Home'      { $Tab['Cursor'] = 0; return }
        'End'       { $Tab['Cursor'] = [Math]::Max(0, $view.Count - 1); return }
        'Spacebar'  {
            if ($view.Count -gt 0 -and $Tab['Cursor'] -lt $view.Count) {
                $item = $view[$Tab['Cursor']]
                $item.Selected = -not $item.Selected
                if ($Tab['Cursor'] -lt ($view.Count - 1)) { $Tab['Cursor']++ }
            }
            return
        }
        'Enter' {
            if ($view.Count -eq 0) {
                # Empty list: Enter enumerates targets from the tenant. This is a
                # blocking, single-threaded call (connect + Get-PnPTenantSite), so
                # show a spinner/progress modal the same way the scan path does -
                # otherwise the TUI just freezes on its last frame with no feedback.
                Start-LoadSpinner
                Write-ProgressModal -Title 'Enumerating tenant' -Done 0 -Total 0 -Label ($Tab['OneDrive'] ? 'Loading OneDrives...' : 'Loading sites...') -Ok 0 -Failed 0
                try {
                    $targets = Get-TenantTargets -OneDrive $Tab['OneDrive']
                } finally {
                    Stop-LoadSpinner
                }
                Add-TargetsToTab -Tab $Tab -Targets $targets
                $script:UI.Dirty = $true
                return
            }
            if ($Tab['Cursor'] -lt $view.Count) {
                $item = $view[$Tab['Cursor']]
                if ($item.Status -eq 'Findings' -or $item.Status -eq 'Revoked') { Enter-FindingsMode -Tab $Tab -Target $item }
            }
            return
        }
    }

    switch ([char]::ToUpper($K.KeyChar)) {
        'A' { foreach ($it in $view) { $it.Selected = $true }; return }
        'N' { foreach ($it in @($Tab['Items'])) { $it.Selected = $false }; return }
        '/' { $script:UI.SearchMode = $true; return }
        'F' {
            $order = @('All','NotScanned','Clean','Findings','Failed')
            $idx = [Array]::IndexOf($order, $Tab['Filter'])
            $Tab['Filter'] = $order[(($idx + 1) % $order.Count)]
            $Tab['Cursor'] = 0
            Update-TabView -Tab $Tab
            return
        }
        'S' { Invoke-TabScan -Tab $Tab; return }
        'X' { Invoke-TabScanAll -Tab $Tab; return }
        'T' { Show-CategoryToggleModal -Tab $Tab; return }
        'U' {
            $u = Show-InputModal -Title 'Add target URL' -Prompt 'Site or OneDrive URL:'
            if ($u) { Add-TargetsToTab -Tab $Tab -Targets @(New-Target -Url $u) }
            return
        }
        'I' {
            $path = Show-InputModal -Title 'Import CSV' -Prompt 'Path to a CSV with a Url column:'
            if ($path) {
                try {
                    $urls = @(Get-UrlsFromCsv -Path $path)
                    $targets = @($urls | ForEach-Object { New-Target -Url $_ })
                    Add-TargetsToTab -Tab $Tab -Targets $targets
                } catch {
                    Show-MsgModal -Title 'Import failed' -Lines @($_.Exception.Message) -Kind Error
                }
            }
            return
        }
        'E' { Export-ViewCsv -Tab $Tab; return }
        'G' { Enter-AggregateMode -Tab $Tab; return }
        'R' {
            $selTargets = @($Tab['Items'] | Where-Object { $_.Selected })
            if ($selTargets.Count -eq 0) { Show-MsgModal -Title 'Revoke' -Lines @('No targets selected. Space selects a drive.'); return }
            $findings = @()
            foreach ($tt in $selTargets) { if (@($tt.Findings).Count -gt 0) { $findings += @($tt.Findings) } }
            if ($findings.Count -eq 0) { Show-MsgModal -Title 'Revoke' -Lines @('Selected targets have no findings to revoke.'); return }
            Invoke-BulkRevoke -Findings $findings -Tab $Tab
            return
        }
        'L' {
            if (-not $script:UI.RestoreInfo) { Show-MsgModal -Title 'Restore' -Lines @('No saved session cache to restore.'); return }
            if (Restore-SsmCache) {
                $script:UI.RestoreInfo = $null
                Show-MsgModal -Title 'Restored' -Lines @('Scan cache restored from disk.')
            } else {
                Show-MsgModal -Title 'Restore failed' -Lines @('Could not read the session cache. See the Log tab.') -Kind Error
            }
            return
        }
    }
}

function Invoke-FindingsKey {
    param($Tab, [System.ConsoleKeyInfo]$K)
    $ft = $Tab['FTab']

    if ($script:UI.SearchMode) {
        if ($K.Key -eq 'Escape') { $script:UI.SearchMode = $false; $ft['Search'] = ''; Update-FindingsView -Tab $Tab; return }
        if ($K.Key -eq 'Enter')  { $script:UI.SearchMode = $false; return }
        if ($K.Key -eq 'Backspace') {
            if ($ft['Search'].Length -gt 0) { $ft['Search'] = $ft['Search'].Substring(0, $ft['Search'].Length - 1); Update-FindingsView -Tab $Tab }
            return
        }
        if ($K.KeyChar -and -not [char]::IsControl($K.KeyChar)) {
            $ft['Search'] = $ft['Search'] + $K.KeyChar
            $ft['Cursor'] = 0
            Update-FindingsView -Tab $Tab
        }
        return
    }

    if ($K.Key -eq 'Escape') { Exit-FindingsMode -Tab $Tab; return }

    $view = @($ft['View'])
    $cap = [Math]::Max(1, $script:UI.H - 5)

    switch ($K.Key) {
        'UpArrow'   { if ($ft['Cursor'] -gt 0) { $ft['Cursor']-- }; return }
        'DownArrow' { if ($ft['Cursor'] -lt ($view.Count - 1)) { $ft['Cursor']++ }; return }
        'PageUp'    { $ft['Cursor'] = [Math]::Max(0, $ft['Cursor'] - $cap); return }
        'PageDown'  { $ft['Cursor'] = [Math]::Min([Math]::Max(0, $view.Count - 1), $ft['Cursor'] + $cap); return }
        'Home'      { $ft['Cursor'] = 0; return }
        'End'       { $ft['Cursor'] = [Math]::Max(0, $view.Count - 1); return }
        'Spacebar'  {
            if ($view.Count -gt 0 -and $ft['Cursor'] -lt $view.Count) {
                $item = $view[$ft['Cursor']]
                $item.Selected = -not $item.Selected
                if ($ft['Cursor'] -lt ($view.Count - 1)) { $ft['Cursor']++ }
            }
            return
        }
    }

    switch ([char]::ToUpper($K.KeyChar)) {
        'A' { foreach ($it in $view) { $it.Selected = $true }; return }
        'N' { foreach ($it in @($ft['Items'])) { $it.Selected = $false }; return }
        '/' { $script:UI.SearchMode = $true; return }
        'F' {
            $keys = @($ft['Items'] | Select-Object -ExpandProperty CategoryKey -Unique)
            $order = @('All') + $keys
            $idx = [Array]::IndexOf($order, $ft['Filter'])
            if ($idx -lt 0) { $idx = 0 }
            $ft['Filter'] = $order[(($idx + 1) % $order.Count)]
            $ft['Cursor'] = 0
            Update-FindingsView -Tab $Tab
            return
        }
        'R' { Invoke-FindingsRevoke -Tab $Tab; return }
        'E' { Export-ViewCsv -Tab $Tab; return }
    }
}

function Invoke-TenantKey {
    # The Tenant tab is a navigable list: Up/Down move the cursor over the
    # sharing settings, Enter loads the posture (when unloaded) or opens the
    # value picker for the highlighted setting. Digit keys are intentionally
    # NOT captured here, so they stay available for tab switching in the main
    # menu (see Invoke-KeyDispatch).
    #
    # NOTE: Get-TenantPosture / Invoke-TenantSetting live in Task 11's file.
    # PowerShell resolves calls at execution time, so guard with Get-Command so
    # the tab stays usable (with a clear message) if exercised before it lands.
    param([System.ConsoleKeyInfo]$K)
    $tab = $script:Tabs[2]
    $count = @($script:TenantSettings).Count
    if ($count -lt 1) { $count = 9 }
    if (-not $tab.ContainsKey('Cursor')) { $tab['Cursor'] = 0 }

    switch ($K.Key) {
        'UpArrow'   { if ($tab['Cursor'] -gt 0) { $tab['Cursor']-- }; $script:UI.Dirty = $true; return }
        'DownArrow' { if ($tab['Cursor'] -lt ($count - 1)) { $tab['Cursor']++ }; $script:UI.Dirty = $true; return }
        'Home'      { $tab['Cursor'] = 0; $script:UI.Dirty = $true; return }
        'End'       { $tab['Cursor'] = $count - 1; $script:UI.Dirty = $true; return }
        'Enter' {
            if (-not $tab['Loaded']) {
                if (Get-Command Get-TenantPosture -ErrorAction SilentlyContinue) { Get-TenantPosture }
                else { Show-MsgModal -Title 'Tenant' -Lines @('Tenant posture loading is not yet available (lands in Task 11).') -Kind Warn }
            } elseif (Get-Command Invoke-TenantSetting -ErrorAction SilentlyContinue) {
                Invoke-TenantSetting -Setting ([int]$tab['Cursor'] + 1)
            } else {
                Show-MsgModal -Title 'Tenant' -Lines @('Changing tenant settings is not yet available (lands in Task 11).') -Kind Warn
            }
            return
        }
    }
    if ([char]::ToUpper($K.KeyChar) -eq 'R') {
        if (Get-Command Get-TenantPosture -ErrorAction SilentlyContinue) { Get-TenantPosture }
        else { Show-MsgModal -Title 'Tenant' -Lines @('Tenant posture loading is not yet available (lands in Task 11).') -Kind Warn }
        return
    }
}

function Invoke-SetupAction {
    # Stub for the Setup-tab actions until Task 12 wires the real handlers
    # (Register-SsmDelegatedApp / Register-SsmAppOnlyApp / Update-SsmCertificate / Edit-SsmConfig).
    param([string]$Key, [string]$Name)
    $map = @{ D = 'Register-SsmDelegatedApp'; C = 'Register-SsmAppOnlyApp'; W = 'Update-SsmCertificate'; X = 'Edit-SsmConfig' }
    $fn = $map[$Key]
    if ($fn -and (Get-Command $fn -ErrorAction SilentlyContinue)) {
        & $fn
    } else {
        Show-MsgModal -Title 'Setup' -Lines @(($Name + ' is not yet implemented (lands in Task 12).')) -Kind Warn
    }
}

function Invoke-SetupKey {
    param([System.ConsoleKeyInfo]$K)
    switch ([char]::ToUpper($K.KeyChar)) {
        'D' { Invoke-SetupAction -Key 'D' -Name 'Register delegated app'; return }
        'C' { Invoke-SetupAction -Key 'C' -Name 'Register cert app'; return }
        'W' { Invoke-SetupAction -Key 'W' -Name 'Renew certificate'; return }
        'X' { Invoke-SetupAction -Key 'X' -Name 'Edit config'; return }
    }
}

function Invoke-LogKey {
    param([System.ConsoleKeyInfo]$K)
    $cap = [Math]::Max(1, $script:UI.H - 4)
    $maxScroll = [Math]::Max(0, $script:LogBuffer.Count - $cap)
    switch ($K.Key) {
        'UpArrow'   { $script:UI.LogScroll = [Math]::Min($maxScroll, $script:UI.LogScroll + 1); return }
        'DownArrow' { $script:UI.LogScroll = [Math]::Max(0, $script:UI.LogScroll - 1); return }
        'PageUp'    { $script:UI.LogScroll = [Math]::Min($maxScroll, $script:UI.LogScroll + $cap); return }
        'PageDown'  { $script:UI.LogScroll = [Math]::Max(0, $script:UI.LogScroll - $cap); return }
        'Home'      { $script:UI.LogScroll = $maxScroll; return }
        'End'       { $script:UI.LogScroll = 0; return }
    }
    if ([char]::ToUpper($K.KeyChar) -eq 'O') {
        try {
            if ($script:IsWin) { Start-Process notepad.exe -ArgumentList $script:LogFile }
            elseif ($PSVersionTable.PSVersion.Major -ge 6 -and (Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS) { Start-Process open -ArgumentList $script:LogFile }
            else { Start-Process xdg-open -ArgumentList $script:LogFile }
            Write-SsmLog -Message 'Opened log file in external viewer.'
        } catch {
            Show-MsgModal -Title 'Log' -Lines @('Could not open the log file:', $_.Exception.Message) -Kind Error
        }
    }
}

function Invoke-KeyDispatch {
    param([System.ConsoleKeyInfo]$K)
    $tab = $script:Tabs[$script:UI.Tab]

    # Ctrl+C quits from anywhere
    if (($K.Modifiers -band [ConsoleModifiers]::Control) -and $K.Key -eq 'C') { $script:UI.Quit = $true; return }

    $inFindings = ($tab['Kind'] -eq 'Targets' -and $tab['Mode'] -eq 'Findings')

    # search mode owns nearly all keys
    if ($script:UI.SearchMode -and $tab['Kind'] -eq 'Targets') {
        if ($inFindings) { Invoke-FindingsKey -Tab $tab -K $K } else { Invoke-TargetsKey -Tab $tab -K $K }
        return
    }

    if ($K.Key -eq 'Tab') {
        $delta = 1
        if ($K.Modifiers -band [ConsoleModifiers]::Shift) { $delta = -1 }
        $script:UI.Tab = ($script:UI.Tab + $delta + $script:Tabs.Count) % $script:Tabs.Count
        return
    }
    # Digit keys jump to a tab by position. The Tenant tab no longer captures
    # digits for its own menu (it is arrow-navigated now), so digits switch
    # tabs from every tab.
    if ($K.KeyChar -ge '1' -and $K.KeyChar -le [char]([int][char]'0' + $script:Tabs.Count)) {
        $script:UI.Tab = [int][string]$K.KeyChar - 1
        return
    }
    if ($K.KeyChar -eq '?') { Show-HelpModal; return }
    $upper = [char]::ToUpper($K.KeyChar)
    if ($upper -eq 'Q') { $script:UI.Quit = $true; return }
    if ($upper -eq 'W' -and $tab['Kind'] -ne 'Setup') {
        if ($script:Conn.Url) {
            if (Show-ConfirmModal -Title 'Disconnect' -Lines @('Disconnect the current PnP session?')) {
                # Keep targets/findings loaded; only the connection state resets.
                Disconnect-SsmConnection
            }
        }
        return
    }

    switch ($tab['Kind']) {
        'Targets' {
            if ($inFindings) { Invoke-FindingsKey -Tab $tab -K $K } else { Invoke-TargetsKey -Tab $tab -K $K }
        }
        'Tenant' { Invoke-TenantKey -K $K }
        'Setup'  { Invoke-SetupKey -K $K }
        'Log'    { Invoke-LogKey -K $K }
    }
}

#endregion
