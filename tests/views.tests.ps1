Invoke-SsmTest 'Get-FooterBar keeps ? and Q visible when the width is too small for every hint' {
    $hints = @(@('Spc','select'),@('A','all'),@('N','none'),@('S','scan'),@('X','scan all'),@('?','help'),@('Q','quit'))
    $bar = Get-FooterBar -Hints $hints -Width 30
    $plain = $bar -replace "`e\[[0-9;]*m", ''
    Assert-Equal 'True' ([string]($plain -match ' \? help '))
    Assert-Equal 'True' ([string]($plain -match ' Q quit '))
    Assert-Equal 'False' ([string]($plain -match 'scan all'))
    Assert-Equal 30 $plain.Length
}

Invoke-SsmTest 'Update-TabView on an empty tab does not throw (regression)' {
    $tab = @{ Items = @(); Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0; View = @() }
    Update-TabView -Tab $tab
    Assert-Equal 0 @($tab['View']).Count
    Assert-Equal 0 $tab['Cursor']
}

Invoke-SsmTest 'Update-TabView with a filter matching zero items does not throw (regression)' {
    $tab = @{
        Items = @(@{ Url = 'https://x/a'; Title = 'a'; Status = 'Clean'; FindingCount = 0 })
        Filter = 'Findings'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0; View = @()
    }
    Update-TabView -Tab $tab
    Assert-Equal 0 @($tab['View']).Count
}

Invoke-SsmTest 'Update-TabView with a filter matching exactly one item does not throw (regression)' {
    $tab = @{
        Items = @(
            @{ Url = 'https://x/a'; Title = 'a'; Status = 'Clean'; FindingCount = 0 },
            @{ Url = 'https://x/b'; Title = 'b'; Status = 'Findings'; FindingCount = 1 }
        )
        Filter = 'Findings'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0; View = @()
    }
    Update-TabView -Tab $tab
    Assert-Equal 1 @($tab['View']).Count
    Assert-Equal 'https://x/b' $tab['View'][0].Url
}

Invoke-SsmTest 'Update-TabView cursor clamps to the shrunk view size' {
    $tab = @{
        Items = @(@{ Url = 'https://x/a'; Title = 'a'; Status = 'Clean'; FindingCount = 0 })
        Filter = 'Findings'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 5; View = @()
    }
    Update-TabView -Tab $tab
    Assert-Equal 0 $tab['Cursor']
}

Invoke-SsmTest 'Get-ModalScrollWindow: no pin, content fits, shows everything' {
    $w = Get-ModalScrollWindow -Total 5 -BodyH 10 -PinCount 0 -Scroll 0
    Assert-Equal 0 $w.Start
    Assert-Equal 5 $w.Count
    Assert-Equal 0 $w.Pin
}
Invoke-SsmTest 'Get-ModalScrollWindow: pinned lines are reserved out of the body height' {
    # 36 lines total, 5 pinned, 12 rows of box body -> 7 rows left to scroll 31 lines
    $w = Get-ModalScrollWindow -Total 36 -BodyH 12 -PinCount 5 -Scroll 0
    Assert-Equal 0 $w.Start
    Assert-Equal 7 $w.Count
    Assert-Equal 5 $w.Pin
}
Invoke-SsmTest 'Get-ModalScrollWindow: scroll advances the window start' {
    $w = Get-ModalScrollWindow -Total 36 -BodyH 12 -PinCount 5 -Scroll 3
    Assert-Equal 3 $w.Start
    Assert-Equal 7 $w.Count
}
Invoke-SsmTest 'Get-ModalScrollWindow: scroll past the end clamps to the last full window' {
    # 31 scrolling lines, 7 visible -> max start is 24
    $w = Get-ModalScrollWindow -Total 36 -BodyH 12 -PinCount 5 -Scroll 999
    Assert-Equal 24 $w.Start
    Assert-Equal 7 $w.Count
}
Invoke-SsmTest 'Get-ModalScrollWindow: negative scroll clamps to zero' {
    $w = Get-ModalScrollWindow -Total 36 -BodyH 12 -PinCount 5 -Scroll -4
    Assert-Equal 0 $w.Start
}
Invoke-SsmTest 'Get-ModalScrollWindow: pin larger than the body height keeps one scrolling row' {
    $w = Get-ModalScrollWindow -Total 20 -BodyH 4 -PinCount 9 -Scroll 0
    Assert-Equal 3 $w.Pin
    Assert-Equal 1 $w.Count
}
Invoke-SsmTest 'Get-ModalScrollWindow: pin larger than the total line count is clamped' {
    $w = Get-ModalScrollWindow -Total 3 -BodyH 10 -PinCount 8 -Scroll 0
    Assert-Equal 3 $w.Pin
    Assert-Equal 0 $w.Count
    Assert-Equal 0 $w.Start
}
Invoke-SsmTest 'Get-ModalScrollWindow: zero total is safe' {
    $w = Get-ModalScrollWindow -Total 0 -BodyH 10 -PinCount 0 -Scroll 0
    Assert-Equal 0 $w.Start
    Assert-Equal 0 $w.Count
}

# ---------------------------------------------------------------------------
# Invoke-SsmOneDriveAdmin
# ---------------------------------------------------------------------------
# Every test below stubs modals, connections, the Task 2/3 resolver/preflight
# functions, and Invoke-SsmOneDriveAdminChange locally (each Invoke-SsmTest
# block is its own scope, so these never leak between tests). Only the real
# Get-SsmOneDriveAdminDecision and Export-SsmAdminCsv run unstubbed unless a
# test needs to force a specific failure.

function New-SsmAdminTestItem {
    param($Url, $Title, [bool]$Selected = $true)
    return @{ Url = $Url; Title = $Title; Status = 'NotScanned'; FindingCount = 0; Selected = $Selected }
}

function New-SsmAdminTestTab {
    param($Items, $View = $null)
    if ($null -eq $View) { $View = @($Items | Where-Object { $_.Selected }) }
    return @{
        Kind = 'Targets'; Name = 'OneDrives'; OneDrive = $true; Noun = 'OneDrives'
        Items = $Items; View = @($View); Loaded = $true
        Cursor = 0; Scroll = 0; Search = ''; Filter = 'All'; SortCol = 'Url'; SortDesc = $false
        Mode = 'Targets'; FTab = $null
    }
}

function New-SsmAdminTestSnapshot {
    param($Url, [bool]$AdminPresent = $false)
    return @{
        TenantId = [guid]'11111111-1111-1111-1111-111111111111'; Url = $Url
        SiteId = [guid]'22222222-2222-2222-2222-222222222222'; IsPersonalSite = $true; Unlocked = $true
        OwnerId = [guid]'33333333-3333-3333-3333-333333333333'; OwnerUpn = 'owner@contoso.com'
        PrimaryAdminId = [guid]'33333333-3333-3333-3333-333333333333'; PrimaryAdminUpn = 'owner@contoso.com'
        AdminPresent = $AdminPresent; AdminUserId = [guid]'44444444-4444-4444-4444-444444444444'; AdminLogin = 'i:0#.f|membership|admin@contoso.com'
    }
}

function New-SsmAdminTestIdentity {
    return @{
        Id = [guid]'44444444-4444-4444-4444-444444444444'; Upn = 'admin@contoso.com'
        DisplayName = 'Admin User'; TenantId = [guid]'11111111-1111-1111-1111-111111111111'
    }
}

function Use-SsmAdminTestExportDir {
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssm-admin-view-{0}" -f [guid]::NewGuid())
    return $script:ExportDir
}

Invoke-SsmTest 'Positive path: order is validate -> preflight -> confirm -> BEFORE+initial AFTER -> mutation; hidden and unselected targets handled correctly' {
    $dir = Use-SsmAdminTestExportDir
    try {
        $script:CallOrder = New-Object System.Collections.ArrayList
        $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a' -Selected $true
        $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b' -Selected $true
        $c = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/c' -Title 'c' -Selected $false
        # b is selected but filtered out of the visible View - it must still
        # be frozen into scope because selection is read from Items, not View.
        $tab = New-SsmAdminTestTab -Items @($a, $b, $c) -View @($a)

        function Show-ListModal { param($Title, $Prompt, $Options) [void]$script:CallOrder.Add('ListModal'); return 'Add' }
        function Show-InputModal { param($Title, $Prompt) [void]$script:CallOrder.Add('InputModal'); return 'admin@contoso.com' }
        function Connect-SsmAdmin { [void]$script:CallOrder.Add('ConnectAdmin'); return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) [void]$script:CallOrder.Add('Resolve'); return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) [void]$script:CallOrder.Add("ConnectSite:$Url"); return $true }
        function Get-SsmOneDriveAdminState {
            param($Url, $Identity, $Connection)
            [void]$script:CallOrder.Add("Preflight:$Url")
            return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false
        }
        function Show-TypedConfirmModal { param($Title, $Lines, $Word) [void]$script:CallOrder.Add('Confirm'); return $true }
        function Export-SsmAdminCsv {
            param($Rows, $OperationId, $Phase)
            [void]$script:CallOrder.Add("Export:$Phase")
            return (Join-Path $script:ExportDir "SSM_ADMIN_${Phase}_$OperationId.csv")
        }
        function Invoke-SsmOneDriveAdminChange {
            param($Action, $Identity, $Snapshot, $Connection)
            [void]$script:CallOrder.Add("Mutate:$($Snapshot.Url)")
            return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
        }
        function Show-ReportModal { param($Title, $Lines) }
        function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
        function Start-LoadSpinner {}
        function Stop-LoadSpinner {}

        Invoke-SsmOneDriveAdmin -Tab $tab

        $order = $script:CallOrder.ToArray()
        Assert-Equal 'ListModal' $order[0]
        Assert-Equal 'InputModal' $order[1]
        Assert-Equal 'ConnectAdmin' $order[2]
        Assert-Equal 'Resolve' $order[3]
        # Both selected targets (a visible, b hidden) reach preflight; c never does.
        if ($order -notcontains 'Preflight:https://contoso-my.sharepoint.com/personal/a') { throw 'a missing from preflight' }
        if ($order -notcontains 'Preflight:https://contoso-my.sharepoint.com/personal/b') { throw 'b (hidden) missing from preflight' }
        if ($order -contains 'Preflight:https://contoso-my.sharepoint.com/personal/c') { throw 'unselected c must never be touched' }
        # Confirm comes after all preflight, before any evidence write.
        $confirmIdx = [array]::IndexOf($order, 'Confirm')
        $beforeIdx = [array]::IndexOf($order, 'Export:BEFORE')
        $afterIdx = [array]::IndexOf($order, 'Export:AFTER')
        if ($confirmIdx -lt 0 -or $beforeIdx -lt $confirmIdx -or $afterIdx -lt $beforeIdx) { throw "bad evidence order: $($order -join ',')" }
        # First mutation happens only after the initial BEFORE+AFTER pair.
        $firstMutateIdx = 0
        for ($i = 0; $i -lt $order.Count; $i++) { if ($order[$i] -like 'Mutate:*') { $firstMutateIdx = $i; break } }
        if ($firstMutateIdx -le $afterIdx) { throw 'mutation ran before initial evidence' }
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -Recurse -Force $dir }
    }
}

Invoke-SsmTest 'Cancelling the operation list modal makes no calls at all' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    function Show-ListModal { param($Title, $Prompt, $Options) return $null }
    function Show-InputModal { param($Title, $Prompt) throw 'must not be called' }
    function Connect-SsmAdmin { throw 'must not be called' }
    Invoke-SsmOneDriveAdmin -Tab $tab
}

Invoke-SsmTest 'Cancelling the typed confirmation prevents evidence writes and mutation' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $false }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) throw 'must not be called' }
    function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'Unexpected permission change' }
    Invoke-SsmOneDriveAdmin -Tab $tab
}

Invoke-SsmTest 'Failed global UPN validation prevents preflight and all writes' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'bogus' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) throw 'not found' }
    function Connect-SsmSite { param($Url) throw 'must not be called' }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) throw 'must not be called' }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not be called' }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) throw 'must not be called' }
    function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'must not be called' }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    Invoke-SsmOneDriveAdmin -Tab $tab
}

Invoke-SsmTest 'An all-blocked/no-op preflight writes both evidence reports without requesting typed confirmation' {
    $dir = Use-SsmAdminTestExportDir
    try {
        $blocked = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/blocked' -Title 'blocked'
        $noop = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/noop' -Title 'noop'
        $tab = New-SsmAdminTestTab -Items @($blocked, $noop)
        function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
        function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
        function Connect-SsmAdmin { return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) return $true }
        function Get-SsmOneDriveAdminState {
            param($Url, $Identity, $Connection)
            $s = New-SsmAdminTestSnapshot -Url $Url -AdminPresent $true
            # Add is already present at both targets: the owner-id override
            # makes 'blocked' a decision-Blocked case (owner id missing),
            # 'noop' keeps default Eligible owner data -> NoOp for Add-present.
            if ($Url -like '*blocked*') { $s.OwnerId = $null }
            return $s
        }
        function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not be called: nothing eligible' }
        function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'must not be called' }
        function Show-ReportModal { param($Title, $Lines) }

        Invoke-SsmOneDriveAdmin -Tab $tab

        $before = Join-Path $dir "SSM_ADMIN_BEFORE_*.csv"
        $after = Join-Path $dir "SSM_ADMIN_AFTER_*.csv"
        Assert-Equal 1 @(Get-ChildItem -Path $before).Count
        Assert-Equal 1 @(Get-ChildItem -Path $after).Count
        $rows = @(Import-Csv -LiteralPath (Get-ChildItem -Path $before)[0].FullName)
        Assert-Equal 2 $rows.Count
        $blockedRow = $rows | Where-Object { $_.TargetUrl -like '*blocked*' }
        $noopRow = $rows | Where-Object { $_.TargetUrl -like '*noop*' }
        Assert-Equal 'Blocked' $blockedRow.Result
        Assert-Equal 'NoOp' $noopRow.Result
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -Recurse -Force $dir }
    }
}

Invoke-SsmTest 'A BEFORE evidence write failure prevents every mutation' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) throw 'disk full' }
    function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'must not be called' }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    Invoke-SsmOneDriveAdmin -Tab $tab
}

Invoke-SsmTest 'A mid-batch evidence write failure stops further mutations without crashing' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b'
    $tab = New-SsmAdminTestTab -Items @($a, $b)
    $script:MutateCalls = New-Object System.Collections.ArrayList
    $script:ExportCalls = 0
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv {
        param($Rows, $OperationId, $Phase)
        $script:ExportCalls++
        # Succeed for BEFORE and the initial AFTER (calls 1-2), fail on the
        # first post-mutation AFTER update (call 3).
        if ($script:ExportCalls -eq 3) { throw 'evidence disk failure' }
        return 'stub-path'
    }
    function Invoke-SsmOneDriveAdminChange {
        param($Action, $Identity, $Snapshot, $Connection)
        [void]$script:MutateCalls.Add($Snapshot.Url)
        return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
    }
    function Show-ReportModal { param($Title, $Lines) }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}
    Invoke-SsmOneDriveAdmin -Tab $tab
    Assert-Equal 1 $script:MutateCalls.Count
}

Invoke-SsmTest 'An owner-protected target and an eligible target: only the eligible one is mutated' {
    $owned = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/owned' -Title 'owned'
    $ok = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/ok' -Title 'ok'
    $tab = New-SsmAdminTestTab -Items @($owned, $ok)
    $script:MutateCalls = New-Object System.Collections.ArrayList
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Remove' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $s = New-SsmAdminTestSnapshot -Url $Url -AdminPresent $true
        if ($Url -like '*owned*') { $s.OwnerId = $Identity.Id }   # candidate IS the owner
        return $s
    }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) return 'stub-path' }
    function Invoke-SsmOneDriveAdminChange {
        param($Action, $Identity, $Snapshot, $Connection)
        [void]$script:MutateCalls.Add($Snapshot.Url)
        return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
    }
    function Show-ReportModal { param($Title, $Lines) }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}
    Invoke-SsmOneDriveAdmin -Tab $tab
    Assert-Equal 1 $script:MutateCalls.Count
    Assert-Equal 'https://contoso-my.sharepoint.com/personal/ok' $script:MutateCalls[0]
}

Invoke-SsmTest 'A target-local Failed result continues the batch to the next target' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b'
    $tab = New-SsmAdminTestTab -Items @($a, $b)
    $script:MutateCalls = New-Object System.Collections.ArrayList
    $script:LastReport = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) $script:LastReport = $Rows; return 'stub-path' }
    function Invoke-SsmOneDriveAdminChange {
        param($Action, $Identity, $Snapshot, $Connection)
        [void]$script:MutateCalls.Add($Snapshot.Url)
        if ($Snapshot.Url -like '*a') { return @{ Result = 'Failed'; StopBatch = $false; Detail = 'denied' } }
        return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
    }
    function Show-ReportModal { param($Title, $Lines) }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}
    Invoke-SsmOneDriveAdmin -Tab $tab
    Assert-Equal 2 $script:MutateCalls.Count
    $rowA = $script:LastReport | Where-Object { $_.TargetUrl -like '*a' }
    $rowB = $script:LastReport | Where-Object { $_.TargetUrl -like '*b' }
    Assert-Equal 'Failed' $rowA.Result
    Assert-Equal 'Success' $rowB.Result
}

Invoke-SsmTest 'A StopBatch result (identity/evidence safety escalation) stops all later targets, marked not attempted' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b'
    $tab = New-SsmAdminTestTab -Items @($a, $b)
    $script:MutateCalls = New-Object System.Collections.ArrayList
    $script:LastReport = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Remove' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $true }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) $script:LastReport = $Rows; return 'stub-path' }
    function Invoke-SsmOneDriveAdminChange {
        param($Action, $Identity, $Snapshot, $Connection)
        [void]$script:MutateCalls.Add($Snapshot.Url)
        return @{ Result = 'Blocked'; StopBatch = $true; Detail = 'requested identity drifted since preview' }
    }
    function Show-ReportModal { param($Title, $Lines) }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}
    Invoke-SsmOneDriveAdmin -Tab $tab
    Assert-Equal 1 $script:MutateCalls.Count
    $rowB = $script:LastReport | Where-Object { $_.TargetUrl -like '*b' }
    Assert-Equal 'NotAttempted' $rowB.Result
    if ($rowB.Error -notlike '*batch stopped*') { throw "expected a batch-stopped reason, got [$($rowB.Error)]" }
}

Invoke-SsmTest 'Cancellation after the first target marks the remaining target Cancelled' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b'
    $tab = New-SsmAdminTestTab -Items @($a, $b)
    $script:MutateCalls = New-Object System.Collections.ArrayList
    $script:LastReport = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) $script:LastReport = $Rows; return 'stub-path' }
    function New-SsmProgressCallback {
        # Sets Cancel on the state the entry function owns, exactly as a real
        # Esc-then-confirm would, without needing a keyboard/console.
        param($Title, $State, $CancelMode)
        $st = $State; $ttl = $Title
        return { param($Count, $Total, $Label, $Ok, $Failed) if ($ttl -eq 'Updating OneDrive Admins' -and $Count -ge 1) { $st.Cancel = $true } }.GetNewClosure()
    }
    function Invoke-SsmOneDriveAdminChange {
        param($Action, $Identity, $Snapshot, $Connection)
        [void]$script:MutateCalls.Add($Snapshot.Url)
        return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
    }
    function Show-ReportModal { param($Title, $Lines) }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}
    Invoke-SsmOneDriveAdmin -Tab $tab
    Assert-Equal 1 $script:MutateCalls.Count
    $rowB = $script:LastReport | Where-Object { $_.TargetUrl -like '*b' }
    Assert-Equal 'Cancelled' $rowB.Result
}

Invoke-SsmTest 'Esc during preflight aborts before confirmation and mutates nothing' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b'
    $tab = New-SsmAdminTestTab -Items @($a, $b)
    $script:MutateCalls = New-Object System.Collections.ArrayList
    $script:ConfirmShown = $false
    $script:PreflightReads = 0
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) $script:PreflightReads++; return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) $script:ConfirmShown = $true; return $true }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) return 'stub-path' }
    function New-SsmProgressCallback {
        param($Title, $State, $CancelMode)
        $st = $State
        return { param($Count, $Total, $Label, $Ok, $Failed) if ($Count -ge 2) { $st.Cancel = $true } }.GetNewClosure()
    }
    function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) [void]$script:MutateCalls.Add($Snapshot.Url); return @{ Result = 'Success'; StopBatch = $false; Detail = '' } }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}
    Invoke-SsmOneDriveAdmin -Tab $tab
    Assert-Equal 1 $script:PreflightReads
    Assert-Equal $false $script:ConfirmShown
    Assert-Equal 0 $script:MutateCalls.Count
}

Invoke-SsmTest 'An Unverified mutation outcome records AdminAfter as unknown, not false' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    $script:LastReport = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) $script:LastReport = $Rows; return 'stub-path' }
    function Invoke-SsmOneDriveAdminChange {
        param($Action, $Identity, $Snapshot, $Connection)
        return @{ Result = 'Unverified'; StopBatch = $false; Detail = 'post-write verification read failed' }
    }
    function Show-ReportModal { param($Title, $Lines) }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}
    Invoke-SsmOneDriveAdmin -Tab $tab
    $row = $script:LastReport | Where-Object { $_.TargetUrl -like '*a' }
    Assert-Equal 'Unverified' $row.Result
    Assert-Equal '' $row.AdminAfter
}

Invoke-SsmTest 'CSV evidence carries actor/site/account details, no tokens, and escapes control characters in display text' {
    $dir = Use-SsmAdminTestExportDir
    try {
        $script:Conn = @{ Url = 'https://contoso-admin.sharepoint.com'; Account = 'operator@contoso.com' }
        # A control character in the target Title (external tenant data) must
        # never reach the confirmation preview unescaped.
        $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title "evil`u{0007}name"
        $tab = New-SsmAdminTestTab -Items @($a)
        $script:ReportedLines = $null
        function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
        function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
        function Connect-SsmAdmin { return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) return $true }
        function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
        function Show-TypedConfirmModal {
            param($Title, $Lines, $Word)
            $script:ReportedLines = $Lines
            return $true
        }
        function Invoke-SsmOneDriveAdminChange {
            param($Action, $Identity, $Snapshot, $Connection)
            return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
        }
        function Show-ReportModal { param($Title, $Lines) }
        function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
        function Start-LoadSpinner {}
        function Stop-LoadSpinner {}

        Invoke-SsmOneDriveAdmin -Tab $tab

        $joined = ($script:ReportedLines -join "`n")
        if ($joined -match "`u{0007}") { throw 'raw control character reached the confirmation preview' }
        if ($joined -notmatch '\\u0007') { throw 'control character was not escaped as \uXXXX' }

        $before = @(Get-ChildItem -Path (Join-Path $dir 'SSM_ADMIN_BEFORE_*.csv'))
        Assert-Equal 1 $before.Count
        $row = @(Import-Csv -LiteralPath $before[0].FullName)[0]
        Assert-Equal 'operator@contoso.com' $row.Actor
        Assert-Equal 'https://contoso-my.sharepoint.com/personal/a' $row.TargetUrl
        Assert-Equal 'admin@contoso.com' $row.ResolvedUpn
        if ($row.PSObject.Properties.Match('AccessToken').Count -gt 0) { throw 'evidence must never carry a token field' }
        foreach ($p in $row.PSObject.Properties) {
            if ("$($p.Value)" -match 'ey[A-Za-z0-9_-]{20,}\.') { throw "possible JWT-shaped value in $($p.Name)" }
        }
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -Recurse -Force $dir }
    }
}

Invoke-SsmTest 'A raw ESC/newline in a validation exception is escaped, not injected, into the error modal' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    $script:MsgLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'bogus' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser {
        param($Upn, $TenantId, $Connection)
        throw "lookup failed`e[31mFAKE-RED`e[0m`nsecond line"
    }
    function Connect-SsmSite { param($Url) throw 'must not be called' }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) throw 'must not be called' }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not be called' }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) throw 'must not be called' }
    function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'must not be called' }
    function Show-MsgModal { param($Title, $Lines, $Kind) $script:MsgLines = $Lines }

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:MsgLines -join "`n")
    if ($joined -match "`e") { throw 'raw ESC reached the error modal' }
    if ($joined -notmatch '\\u001b') { throw 'ESC was not escaped as \u001b' }
    if ($joined -notmatch '\\u000a') { throw 'embedded newline was not escaped as \u000a' }
}

Invoke-SsmTest 'A control character in a mutation Detail is escaped in the final report, not injected' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    $script:ReportLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) return 'stub-path' }
    function Invoke-SsmOneDriveAdminChange {
        param($Action, $Identity, $Snapshot, $Connection)
        return @{ Result = 'Failed'; StopBatch = $false; Detail = "denied`e[31minjected`e[0m" }
    }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:ReportLines -join "`n")
    if ($joined -match "`e") { throw 'raw ESC reached the final report modal' }
    if ($joined -notmatch '\\u001b') { throw 'ESC in the mutation Detail was not escaped in the final report' }
}

Invoke-SsmTest 'An ordinary Failed mutation result (no returned After snapshot) leaves AdminAfter blank, not inferred' {
    $dir = Use-SsmAdminTestExportDir
    try {
        $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
        $tab = New-SsmAdminTestTab -Items @($a)
        function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
        function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
        function Connect-SsmAdmin { return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) return $true }
        # AdminBefore = $false (Add, not yet present). If AdminAfter were still
        # inferred as "opposite of requested", it would come out $false here
        # too - this test asserts it is blank instead, since Task 3 never
        # returns a fresh snapshot to prove either value.
        function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
        function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
        function Invoke-SsmOneDriveAdminChange {
            param($Action, $Identity, $Snapshot, $Connection)
            return @{ Result = 'Failed'; StopBatch = $false; Detail = 'membership after write does not match the requested action' }
        }
        function Show-ReportModal { param($Title, $Lines) }
        function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
        function Start-LoadSpinner {}
        function Stop-LoadSpinner {}

        Invoke-SsmOneDriveAdmin -Tab $tab

        $row = @(Import-Csv -LiteralPath (Get-ChildItem -Path (Join-Path $dir 'SSM_ADMIN_AFTER_*.csv'))[0].FullName)[0]
        Assert-Equal 'Failed' $row.Result
        Assert-Equal '' $row.AdminAfter
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -Recurse -Force $dir }
    }
}

Invoke-SsmTest 'A Blocked mutation-time result (no returned After snapshot) leaves AdminAfter blank, not the preflight value' {
    $dir = Use-SsmAdminTestExportDir
    try {
        $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
        $tab = New-SsmAdminTestTab -Items @($a)
        function Show-ListModal { param($Title, $Prompt, $Options) return 'Remove' }
        function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
        function Connect-SsmAdmin { return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) return $true }
        function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $true }
        function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
        function Invoke-SsmOneDriveAdminChange {
            param($Action, $Identity, $Snapshot, $Connection)
            return @{ Result = 'Blocked'; StopBatch = $false; Detail = 'pre-write state read failed' }
        }
        function Show-ReportModal { param($Title, $Lines) }
        function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
        function Start-LoadSpinner {}
        function Stop-LoadSpinner {}

        Invoke-SsmOneDriveAdmin -Tab $tab

        $row = @(Import-Csv -LiteralPath (Get-ChildItem -Path (Join-Path $dir 'SSM_ADMIN_AFTER_*.csv'))[0].FullName)[0]
        Assert-Equal 'Blocked' $row.Result
        Assert-Equal '' $row.AdminAfter
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -Recurse -Force $dir }
    }
}

Invoke-SsmTest 'An unrecognized mutation Result is forced to Unverified, stops the batch, and never reads as Success' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b'
    $tab = New-SsmAdminTestTab -Items @($a, $b)
    $script:MutateCalls = New-Object System.Collections.ArrayList
    $script:LastReport = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) $script:LastReport = $Rows; return 'stub-path' }
    function Invoke-SsmOneDriveAdminChange {
        param($Action, $Identity, $Snapshot, $Connection)
        [void]$script:MutateCalls.Add($Snapshot.Url)
        return @{ Result = 'Weird'; StopBatch = $false; Detail = 'unexpected shape from a future Task 3 change' }
    }
    function Show-ReportModal { param($Title, $Lines) }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    Invoke-SsmOneDriveAdmin -Tab $tab

    # Only the first target was ever attempted - an unrecognized result must
    # stop the batch exactly like a StopBatch=true safety escalation, never
    # silently proceed to the next target.
    Assert-Equal 1 $script:MutateCalls.Count
    $rowA = $script:LastReport | Where-Object { $_.TargetUrl -like '*a' }
    $rowB = $script:LastReport | Where-Object { $_.TargetUrl -like '*b' }
    Assert-Equal 'Unverified' $rowA.Result
    Assert-Equal '' $rowA.AdminAfter
    Assert-Equal 'NotAttempted' $rowB.Result
}

Invoke-SsmTest 'M dispatch is restricted to OneDrive targets' {
    $savedUi = $script:UI
    $calls = [System.Collections.Generic.List[object]]::new()
    function Invoke-SsmOneDriveAdmin { param($Tab) $calls.Add($Tab) }
    try {
        $script:UI = @{ SearchMode = $false; H = 32 }
        $tab = @{ Kind = 'Targets'; Mode = 'Targets'; OneDrive = $false
                  View = @(); Items = @(); Cursor = 0; Search = '' }
        $key = [ConsoleKeyInfo]::new([char]'m', [ConsoleKey]::M, $false, $false, $false)
        Invoke-TargetsKey -Tab $tab -K $key
        Assert-Equal 0 $calls.Count
        $tab.OneDrive = $true
        Invoke-TargetsKey -Tab $tab -K $key
        Assert-Equal 1 $calls.Count
    } finally { $script:UI = $savedUi }
}

Invoke-SsmTest 'M dispatch never reaches findings-mode routing' {
    $calls = [System.Collections.Generic.List[object]]::new()
    function Invoke-SsmOneDriveAdmin { param($Tab) $calls.Add($Tab) }
    $script:UI = @{ SearchMode = $false; H = 32 }
    $ft = @{ Cursor = 0; View = @(); Items = @(); Search = ''; Aggregate = $false }
    $tab = @{ Kind = 'Targets'; Mode = 'Findings'; OneDrive = $true; FTab = $ft
              View = @(); Items = @(); Cursor = 0; Search = '' }
    $key = [ConsoleKeyInfo]::new([char]'m', [ConsoleKey]::M, $false, $false, $false)
    Invoke-FindingsKey -Tab $tab -K $key
    Assert-Equal 0 $calls.Count
}

Invoke-SsmTest 'Get-TabHints advertises M only for the OneDrive targets tab' {
    $script:UI = @{ SearchMode = $false }
    $siteTab = @{ Kind = 'Targets'; Mode = 'Targets'; OneDrive = $false }
    $odTab   = @{ Kind = 'Targets'; Mode = 'Targets'; OneDrive = $true }
    $siteHints = @(Get-TabHints -Tab $siteTab)
    $odHints   = @(Get-TabHints -Tab $odTab)
    Assert-Equal 'False' ([bool]($siteHints | Where-Object { $_[0] -eq 'M' }))
    Assert-Equal 'True'  ([bool]($odHints   | Where-Object { $_[0] -eq 'M' }))
}

# ---------------------------------------------------------------------------
# DIAGNOSTICS regressions - a preflight/evidence failure must be logged with
# the original exception (not silently swallowed), and the zero-eligible/
# mixed-batch previews must show the operator the actual reason, not a bare
# classification. Each test loads the real logger (src/05-logging.ps1)
# instead of the test-runner's no-op stub so it can assert real buffered
# content, then restores the stub logger and $script:LogFile in a `finally`
# via Enter-SsmTestLogFile/Exit-SsmTestLogFile (tests/run-tests.ps1) so later
# tests are unaffected and none of these ever write to a real log file on
# disk (isolated per-test via a unique temp path, not the ambient
# $script:LogFile - which an earlier *.tests.ps1 file may have left pointed
# at a relative path).
# ---------------------------------------------------------------------------

Invoke-SsmTest 'DIAGNOSTICS: a per-target preflight read failure (zero eligible) logs the original exception, not just a silent Blocked row' {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/05-logging.ps1')
    $script:LogBuffer.Clear()
    $prevLogFile = Enter-SsmTestLogFile
    $dir = Use-SsmAdminTestExportDir
    try {
            $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
            $tab = New-SsmAdminTestTab -Items @($a)
            $script:ReportLines = $null
            function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
            function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
            function Connect-SsmAdmin { return $true }
            function Get-PnPConnection { return @{ Url = 'admin-conn' } }
            function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
            function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
            function Connect-SsmSite { param($Url) return $true }
            function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) throw 'drive read failed: preflight-diagnostics-probe' }
            function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not be called: nothing eligible' }
            function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'must not be called' }
            function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }

            Invoke-SsmOneDriveAdmin -Tab $tab

            $errLines = @($script:LogBuffer | Where-Object { $_.Level -eq 'ERROR' })
            if (-not ($errLines | Where-Object { $_.Message -like '*preflight-diagnostics-probe*' })) {
                throw "original preflight exception was not logged; buffer: $(($errLines | ForEach-Object { $_.Message }) -join ' | ')"
            }
            $joined = ($script:ReportLines -join "`n")
            if ($joined -notlike '*preflight read failed*preflight-diagnostics-probe*') {
                throw "preview did not show the failure reason for the Failed row: $joined"
            }
        } finally {
            if (Test-Path -LiteralPath $dir) { Remove-Item -Recurse -Force $dir }
            Exit-SsmTestLogFile -Prev $prevLogFile
        }
}

Invoke-SsmTest 'DIAGNOSTICS: an evidence export failure in the zero-eligible path is logged, not silently swallowed' {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/05-logging.ps1')
    $script:LogBuffer.Clear()
    $prevLogFile = Enter-SsmTestLogFile
    try {
        $blocked = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/blocked' -Title 'blocked'
        $tab = New-SsmAdminTestTab -Items @($blocked)
        function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
        function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
        function Connect-SsmAdmin { return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) return $true }
        function Get-SsmOneDriveAdminState {
            param($Url, $Identity, $Connection)
            $s = New-SsmAdminTestSnapshot -Url $Url -AdminPresent $true
            $s.OwnerId = $null
            return $s
        }
        function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not be called: nothing eligible' }
        function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) throw 'disk full: zero-eligible-export-probe' }
        function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'must not be called' }
        function Show-ReportModal { param($Title, $Lines) }
        function Show-MsgModal { param($Title, $Lines, $Kind) }

        Invoke-SsmOneDriveAdmin -Tab $tab

        $errLines = @($script:LogBuffer | Where-Object { $_.Level -eq 'ERROR' })
        if (-not ($errLines | Where-Object { $_.Message -like '*zero-eligible-export-probe*' })) {
            throw "zero-eligible evidence export failure was not logged; buffer: $(($errLines | ForEach-Object { $_.Message }) -join ' | ')"
        }
    } finally {
        Exit-SsmTestLogFile -Prev $prevLogFile
    }
}

Invoke-SsmTest 'DIAGNOSTICS: a mixed batch preview shows the failed-target reason next to its row, not a bare classification' {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/05-logging.ps1')
    $script:LogBuffer.Clear()
    $prevLogFile = Enter-SsmTestLogFile
    try {
        $ok = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/ok' -Title 'ok'
        $bad = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/bad' -Title 'bad'
        $tab = New-SsmAdminTestTab -Items @($ok, $bad)
        $script:ReportedLines = $null
        function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
        function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
        function Connect-SsmAdmin { return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) return $true }
        function Get-SsmOneDriveAdminState {
            param($Url, $Identity, $Connection)
            if ($Url -like '*bad*') { throw 'site connect timed out: mixed-batch-probe' }
            return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false
        }
        function Show-TypedConfirmModal { param($Title, $Lines, $Word) $script:ReportedLines = $Lines; return $true }
        function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) return 'stub-path' }
        function Invoke-SsmOneDriveAdminChange {
            param($Action, $Identity, $Snapshot, $Connection)
            return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
        }
        function Show-ReportModal { param($Title, $Lines) }
        function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
        function Start-LoadSpinner {}
        function Stop-LoadSpinner {}

        Invoke-SsmOneDriveAdmin -Tab $tab

        $joined = ($script:ReportedLines -join "`n")
        if ($joined -notlike '*mixed-batch-probe*') {
            throw "mixed-batch preview did not show the failed target's reason: $joined"
        }
    } finally {
        Exit-SsmTestLogFile -Prev $prevLogFile
    }
}

Invoke-SsmTest 'DIAGNOSTICS: a final AFTER-flush failure after a stopped batch is logged, not silently swallowed' {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/05-logging.ps1')
    $script:LogBuffer.Clear()
    $prevLogFile = Enter-SsmTestLogFile
    try {
        $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
        $tab = New-SsmAdminTestTab -Items @($a)
        $script:ExportCalls = 0
        function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
        function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
        function Connect-SsmAdmin { return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) return $true }
        function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
        function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
        function Export-SsmAdminCsv {
            param($Rows, $OperationId, $Phase)
            $script:ExportCalls++
            # Succeed for BEFORE and the initial AFTER (1-2) and the
            # post-mutation AFTER (3); fail only on the trailing "final
            # flush" AFTER write (4) that the entry function currently
            # wraps in a bare `catch {}`.
            if ($script:ExportCalls -eq 4) { throw 'disk full: final-flush-probe' }
            return 'stub-path'
        }
        function Invoke-SsmOneDriveAdminChange {
            param($Action, $Identity, $Snapshot, $Connection)
            return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
        }
        function Show-ReportModal { param($Title, $Lines) }
        function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
        function Start-LoadSpinner {}
        function Stop-LoadSpinner {}

        Invoke-SsmOneDriveAdmin -Tab $tab

        $errLines = @($script:LogBuffer | Where-Object { $_.Level -eq 'ERROR' })
        if (-not ($errLines | Where-Object { $_.Message -like '*final-flush-probe*' })) {
            throw "final AFTER-flush failure was not logged; buffer: $(($errLines | ForEach-Object { $_.Message }) -join ' | ')"
        }
    } finally {
        Exit-SsmTestLogFile -Prev $prevLogFile
    }
}

Invoke-SsmTest 'DIAGNOSTICS: the final report logs an outcome summary line per target with action and result, no tokens' {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/05-logging.ps1')
    $script:LogBuffer.Clear()
    $prevLogFile = Enter-SsmTestLogFile
    try {
        $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
        $tab = New-SsmAdminTestTab -Items @($a)
        function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
        function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
        function Connect-SsmAdmin { return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) return $true }
        function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
        function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
        function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) return 'stub-path' }
        function Invoke-SsmOneDriveAdminChange {
            param($Action, $Identity, $Snapshot, $Connection)
            return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
        }
        function Show-ReportModal { param($Title, $Lines) }
        function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
        function Start-LoadSpinner {}
        function Stop-LoadSpinner {}

        Invoke-SsmOneDriveAdmin -Tab $tab

        $infoLines = @($script:LogBuffer | Where-Object { $_.Message -like '*Add*' -and $_.Message -like '*Success*' -and $_.Message -like '*personal/a*' })
        if (@($infoLines).Count -lt 1) {
            throw "no outcome summary line logged for the target; buffer: $(($script:LogBuffer | ForEach-Object { $_.Message }) -join ' | ')"
        }
        foreach ($e in $script:LogBuffer) {
            if ("$($e.Message)" -match 'ey[A-Za-z0-9_-]{20,}\.') { throw "possible token-shaped value logged: $($e.Message)" }
        }
    } finally {
        Exit-SsmTestLogFile -Prev $prevLogFile
    }
}

Invoke-SsmTest 'DIAGNOSTICS: the zero-eligible report shows the actual saved evidence paths, not an assumed one' {
    $blocked = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/blocked' -Title 'blocked'
    $tab = New-SsmAdminTestTab -Items @($blocked)
    $script:ReportLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $s = New-SsmAdminTestSnapshot -Url $Url -AdminPresent $true
        $s.OwnerId = $null
        return $s
    }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not be called: nothing eligible' }
    function Export-SsmAdminCsv {
        param($Rows, $OperationId, $Phase)
        return "/tmp/SSM_ADMIN_${Phase}_$OperationId.csv"
    }
    function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'must not be called' }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:ReportLines -join "`n")
    if ($joined -notlike '*BEFORE evidence saved: /tmp/SSM_ADMIN_BEFORE_*') {
        throw "zero-eligible report did not show the actual saved BEFORE path: $joined"
    }
    if ($joined -notlike '*AFTER evidence saved: /tmp/SSM_ADMIN_AFTER_*') {
        throw "zero-eligible report did not show the actual saved AFTER path: $joined"
    }
}

Invoke-SsmTest 'DIAGNOSTICS: a zero-eligible BEFORE export failure never claims AFTER was saved' {
    $blocked = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/blocked' -Title 'blocked'
    $tab = New-SsmAdminTestTab -Items @($blocked)
    $script:ReportLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $s = New-SsmAdminTestSnapshot -Url $Url -AdminPresent $true
        $s.OwnerId = $null
        return $s
    }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not be called: nothing eligible' }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) throw 'disk full: before-only-failure-probe' }
    function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'must not be called' }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }
    function Show-MsgModal { param($Title, $Lines, $Kind) }

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:ReportLines -join "`n")
    if ($joined -like '*evidence saved*') {
        throw "report falsely claimed evidence was saved after an export failure: $joined"
    }
}

Invoke-SsmTest 'DIAGNOSTICS: the completion report shows real saved evidence paths for a normal batch' {
    $dir = Use-SsmAdminTestExportDir
    try {
        $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
        $tab = New-SsmAdminTestTab -Items @($a)
        $script:CompletionLines = $null
        function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
        function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
        function Connect-SsmAdmin { return $true }
        function Get-PnPConnection { return @{ Url = 'admin-conn' } }
        function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
        function Connect-SsmSite { param($Url) return $true }
        function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
        function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
        function Export-SsmAdminCsv {
            param($Rows, $OperationId, $Phase)
            return (Join-Path $script:ExportDir "SSM_ADMIN_${Phase}_$OperationId.csv")
        }
        function Invoke-SsmOneDriveAdminChange {
            param($Action, $Identity, $Snapshot, $Connection)
            return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
        }
        function Show-ReportModal { param($Title, $Lines) $script:CompletionLines = $Lines }
        function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
        function Start-LoadSpinner {}
        function Stop-LoadSpinner {}

        Invoke-SsmOneDriveAdmin -Tab $tab

        $joined = ($script:CompletionLines -join "`n")
        if ($joined -notlike "*BEFORE evidence saved: $($script:ExportDir)*") {
            throw "completion report did not show the real saved BEFORE path: $joined"
        }
        if ($joined -notlike "*AFTER evidence saved: $($script:ExportDir)*") {
            throw "completion report did not show the real saved AFTER path: $joined"
        }
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -Recurse -Force $dir }
    }
}

Invoke-SsmTest 'DIAGNOSTICS: a final AFTER-flush failure is shown visibly in the completion report, not only logged' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    $script:ExportCalls = 0
    $script:CompletionLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'Add' }
    function Show-InputModal { param($Title, $Prompt) return 'admin@contoso.com' }
    function Connect-SsmAdmin { return $true }
    function Get-PnPConnection { return @{ Url = 'admin-conn' } }
    function Get-SsmConnectionTenantId { param($Connection) return [guid]'11111111-1111-1111-1111-111111111111' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) return New-SsmAdminTestIdentity }
    function Connect-SsmSite { param($Url) return $true }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) return New-SsmAdminTestSnapshot -Url $Url -AdminPresent $false }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) return $true }
    function Export-SsmAdminCsv {
        param($Rows, $OperationId, $Phase)
        $script:ExportCalls++
        if ($script:ExportCalls -eq 4) { throw 'disk full: visible-final-flush-probe' }
        return 'stub-path'
    }
    function Invoke-SsmOneDriveAdminChange {
        param($Action, $Identity, $Snapshot, $Connection)
        return @{ Result = 'Success'; StopBatch = $false; Detail = '' }
    }
    function Show-ReportModal { param($Title, $Lines) $script:CompletionLines = $Lines }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:CompletionLines -join "`n")
    if ($joined -notlike '*visible-final-flush-probe*') {
        throw "final-flush failure was not shown in the completion report: $joined"
    }
}

# ---------------------------------------------------------------------------
# Invoke-SsmOneDriveAdmin: List action (screen-only, read-only)
# ---------------------------------------------------------------------------

Invoke-SsmTest 'List: single target shows all current admins, no UPN/confirm/export/mutation/Graph calls' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    $script:ReportLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) Assert-Equal 'List' $Options[0]; return 'List' }
    function Show-InputModal { param($Title, $Prompt) throw 'must not be called' }
    function Connect-SsmAdmin { throw 'must not be called' }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) throw 'must not be called' }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not be called' }
    function Export-SsmAdminCsv { param($Rows, $OperationId, $Phase) throw 'must not be called' }
    function Invoke-SsmOneDriveAdminChange { param($Action, $Identity, $Snapshot, $Connection) throw 'must not be called' }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) throw 'must not be called' }
    function Invoke-PnPGraphMethod { param($Method, $Url, $Connection) throw 'must not be called' }
    function Connect-SsmSite { param($Url) return $true }
    function Get-PnPConnection { return @{ Url = 'https://contoso-my.sharepoint.com/personal/a' } }
    function Get-SsmOneDriveAdmins {
        param($Connection)
        return @(
            @{ Title = 'Admin One'; UserPrincipalName = 'admin1@contoso.com'; LoginName = 'i:0#.f|membership|admin1@contoso.com'; AadObjectId = @{ NameId = '11111111-1111-1111-1111-111111111111' } }
        )
    }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:ReportLines -join "`n")
    if ($joined -notlike '*admin1@contoso.com*') { throw "admin not shown: $joined" }
    if ($joined -notlike '*11111111-1111-1111-1111-111111111111*') { throw "object id not shown: $joined" }
}

Invoke-SsmTest 'List: bulk selection groups admins by target; hidden-selected included, unselected excluded' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a' -Selected $true
    $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b' -Selected $true
    $c = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/c' -Title 'c' -Selected $false
    $tab = New-SsmAdminTestTab -Items @($a, $b, $c) -View @($a)
    $script:ReportLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'List' }
    function Connect-SsmSite { param($Url) return $true }
    function Get-PnPConnection { return @{ Url = $script:CurrentConnUrl } }
    function Get-SsmOneDriveAdmins {
        param($Connection)
        if ($Connection.Url -like '*a') { return @(@{ Title = 'A Admin'; UserPrincipalName = 'a@contoso.com' }) }
        return @(@{ Title = 'B Admin'; UserPrincipalName = 'b@contoso.com' })
    }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    # Get-PnPConnection is stubbed globally per-call; bind the returned Url to
    # whichever site Connect-SsmSite was just told to connect to.
    function Connect-SsmSite { param($Url) $script:CurrentConnUrl = $Url; return $true }

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:ReportLines -join "`n")
    if ($joined -notlike '*a@contoso.com*') { throw "a's admin missing: $joined" }
    if ($joined -notlike '*b@contoso.com*') { throw "b's (hidden) admin missing: $joined" }
    if ($joined -like '*personal/c*') { throw "unselected c must never be listed: $joined" }
}

Invoke-SsmTest 'List: unresolved principal (no UPN/login/object id) still shows as unresolved, not hidden' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    $script:ReportLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'List' }
    function Connect-SsmSite { param($Url) return $true }
    function Get-PnPConnection { return @{ Url = 'https://contoso-my.sharepoint.com/personal/a' } }
    function Get-SsmOneDriveAdmins { param($Connection) return @(@{ Title = $null; UserPrincipalName = $null; LoginName = $null; AadObjectId = $null }) }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:ReportLines -join "`n")
    if ($joined -notlike '*(unresolved)*') { throw "unresolved principal was not shown: $joined" }
}

Invoke-SsmTest 'List: zero admins is reported explicitly as none found, not as a failure' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    $script:ReportLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'List' }
    function Connect-SsmSite { param($Url) return $true }
    function Get-PnPConnection { return @{ Url = 'https://contoso-my.sharepoint.com/personal/a' } }
    function Get-SsmOneDriveAdmins { param($Connection) return @() }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:ReportLines -join "`n")
    if ($joined -notlike '*no administrators found*') { throw "zero-admin target was not reported explicitly: $joined" }
}

Invoke-SsmTest 'List: a target read failure is logged and the remaining targets are still listed' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b'
    $tab = New-SsmAdminTestTab -Items @($a, $b)
    $script:ReportLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'List' }
    function Connect-SsmSite { param($Url) $script:CurrentConnUrl = $Url; return $true }
    function Get-PnPConnection { return @{ Url = $script:CurrentConnUrl } }
    function Get-SsmOneDriveAdmins {
        param($Connection)
        if ($Connection.Url -like '*a') { throw 'transient read failure' }
        return @(@{ Title = 'B Admin'; UserPrincipalName = 'b@contoso.com' })
    }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:ReportLines -join "`n")
    if ($joined -notlike '*admin read failed*transient read failure*') { throw "target failure was not reported: $joined" }
    if ($joined -notlike '*b@contoso.com*') { throw "remaining target after a failure was not listed: $joined" }
}

Invoke-SsmTest 'List: cancelling mid-batch stops before the next target is connected/read, and reports it as not listed rather than visited' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $b = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/b' -Title 'b'
    $c = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/c' -Title 'c'
    $tab = New-SsmAdminTestTab -Items @($a, $b, $c)
    $script:ReportLines = $null
    $script:ConnectedUrls = New-Object System.Collections.ArrayList
    function Show-ListModal { param($Title, $Prompt, $Options) return 'List' }
    function Connect-SsmSite { param($Url) [void]$script:ConnectedUrls.Add($Url); $script:CurrentConnUrl = $Url; return $true }
    function Get-PnPConnection { return @{ Url = $script:CurrentConnUrl } }
    function Get-SsmOneDriveAdmins { param($Connection) return @(@{ Title = 'Admin'; UserPrincipalName = 'admin@contoso.com' }) }
    function New-SsmProgressCallback {
        # Cancel is raised from inside the progress callback itself - as the
        # real Esc-then-confirm flow does - right as target 'b' starts (the
        # callback fires before that target is connected to/read). Target
        # 'a' finishes normally (matching Flag-mode semantics: finish the
        # unit of work in flight, stop before the next one); 'b' and 'c'
        # must never be connected to or read.
        param($Title, $State, $CancelMode)
        $st = $State
        return { param($Count, $Total, $Label, $Ok, $Failed) if ($Count -ge 2) { $st.Cancel = $true } }.GetNewClosure()
    }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    Invoke-SsmOneDriveAdmin -Tab $tab

    if (@($script:ConnectedUrls).Count -ne 1) {
        throw "expected exactly one target connected before cancel, got: $($script:ConnectedUrls -join ',')"
    }
    $joined = ($script:ReportLines -join "`n")
    if ($joined -like '*personal/b*' -or $joined -like '*personal/c*') {
        throw "cancelled-but-never-visited targets must not get their own header/row: $joined"
    }
    if ($joined -notlike '*not listed*') { throw "no trailing not-listed summary shown: $joined" }
}

Invoke-SsmTest 'List: a malicious control character in the Entra object id is sanitized, not injected raw' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    $script:ReportLines = $null
    function Show-ListModal { param($Title, $Prompt, $Options) return 'List' }
    function Connect-SsmSite { param($Url) return $true }
    function Get-PnPConnection { return @{ Url = 'https://contoso-my.sharepoint.com/personal/a' } }
    function Get-SsmOneDriveAdmins {
        param($Connection)
        return @(@{ Title = 'Admin'; UserPrincipalName = 'admin@contoso.com'; AadObjectId = @{ NameId = "evil`e[31mid" } })
    }
    function Show-ReportModal { param($Title, $Lines) $script:ReportLines = $Lines }
    function Write-ProgressModal { param($Title, $Done, $Total, $Label, $Ok, $Failed) }
    function Start-LoadSpinner {}
    function Stop-LoadSpinner {}

    Invoke-SsmOneDriveAdmin -Tab $tab

    $joined = ($script:ReportLines -join "`n")
    if ($joined -match "`e") { throw "raw escape character reached the report: $($joined | Format-Hex | Out-String)" }
    if ($joined -notlike '*\u001b*') { throw "object id control character was not sanitized/escaped: $joined" }
}

Invoke-SsmTest 'List: Esc/cancel from the operation menu makes no connection or read calls at all' {
    $a = New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a'
    $tab = New-SsmAdminTestTab -Items @($a)
    function Show-ListModal { param($Title, $Prompt, $Options) return $null }
    function Connect-SsmSite { param($Url) throw 'must not be called' }
    function Get-SsmOneDriveAdmins { param($Connection) throw 'must not be called' }
    Invoke-SsmOneDriveAdmin -Tab $tab
}

Invoke-SsmTest 'Get-TabHints/menu offers List for the OneDrive targets tab' {
    $tab = New-SsmAdminTestTab -Items @(New-SsmAdminTestItem -Url 'https://contoso-my.sharepoint.com/personal/a' -Title 'a')
    $captured = $null
    function Show-ListModal { param($Title, $Prompt, $Options) $script:CapturedOptions = $Options; return $null }
    Invoke-SsmOneDriveAdmin -Tab $tab
    if ($script:CapturedOptions -notcontains 'List') { throw "List option missing: $($script:CapturedOptions -join ',')" }
}

Invoke-SsmTest 'New-SsmPlaceholderTarget builds a predicted personal URL' {
    $script:Auth = @{ AdminUrl = 'https://contoso-admin.sharepoint.com' }
    $t = New-SsmPlaceholderTarget -User ([pscustomobject]@{ Id = '1'; Upn = 'John.Doe@contoso.com'; DisplayName = 'John Doe' })
    Assert-Equal 'https://contoso-my.sharepoint.com/personal/john_doe_contoso_com' $t.Url
    Assert-Equal 'John Doe' $t.Title
    Assert-Equal 'John.Doe@contoso.com' $t.Upn
    Assert-Equal 'Unprovisioned' $t.Status
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision refuses non-OneDrive tab' {
    $script:CapturedTitle = $null
    function Show-MsgModal { param($Title, $Lines, $Kind) $script:CapturedTitle = $Title }
    Invoke-SsmOneDriveProvision -Tab @{ OneDrive = $false; Items = @() }
    Assert-Equal 'Pre-provision OneDrives' $script:CapturedTitle
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision loads placeholder rows and switches filter when none loaded' {
    $script:Auth = @{ AdminUrl = 'https://contoso-admin.sharepoint.com' }
    $script:UI = @{ Dirty = $false }
    function Write-ProgressModal { }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    function Export-SsmProvisionCsv { param($Rows, $Phase) 'x.csv' }
    function Get-SsmLicensedUsers { param($Progress) @(
        [pscustomobject]@{ Id='1'; Upn='has@contoso.com'; DisplayName='Has' },
        [pscustomobject]@{ Id='2'; Upn='new@contoso.com'; DisplayName='New' }) }
    function Get-SsmProvisionedOwnerSet { param($Progress)
        $s = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); [void]$s.Add('has@contoso.com'); return ,$s }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) throw 'must not confirm' }
    $tab = @{ OneDrive = $true; Items = @(); View = @(); Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0 }
    Invoke-SsmOneDriveProvision -Tab $tab
    Assert-Equal 1 @($tab['Items']).Count
    Assert-Equal 'new@contoso.com' $tab['Items'][0].Upn
    Assert-Equal 'Unprovisioned' $tab['Filter']
    Assert-Equal 1 @($tab['View']).Count
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision provisions only selected Unprovisioned rows' {
    $script:UI = @{ Dirty = $false }
    $script:RequestedUpns = @()
    function Write-ProgressModal { }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    function Export-SsmProvisionCsv { param($Rows, $Phase) 'x.csv' }
    function Get-SsmLicensedUsers { param($Progress) throw 'must not reload' }
    function Show-TypedConfirmModal { param($Title, $Lines, $Word) Assert-Equal 'PROVISION' $Word; $true }
    function Connect-SsmProvisioningSession { [pscustomobject]@{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Write-Screen { }
    function Invoke-SsmPersonalSiteRequest { param($Upns, $Connection, $Progress) $script:RequestedUpns = @($Upns)
        @($Upns | ForEach-Object { [pscustomobject]@{ Upn=$_; Batch=1; Status='Requested'; Error='' } }) }
    $rows = @(
        @{ Url='https://x/a'; Title='a'; Status='Unprovisioned'; FindingCount=0; Findings=@(); Selected=$true;  Upn='a@x.com' },
        @{ Url='https://x/b'; Title='b'; Status='Unprovisioned'; FindingCount=0; Findings=@(); Selected=$false; Upn='b@x.com' },
        @{ Url='https://x/c'; Title='c'; Status='ProvisionRequested'; FindingCount=0; Findings=@(); Selected=$true; Upn='c@x.com' })
    $tab = @{ OneDrive = $true; Items = $rows; View = @(); Filter = 'Unprovisioned'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0 }
    Invoke-SsmOneDriveProvision -Tab $tab
    Assert-Equal 1 $script:RequestedUpns.Count
    Assert-Equal 'a@x.com' $script:RequestedUpns[0]
    Assert-Equal 'ProvisionRequested' $rows[0].Status
    Assert-Equal $false $rows[0].Selected
    Assert-Equal 'Unprovisioned' $rows[1].Status
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision with rows loaded but none selected shows a hint and does not request' {
    $script:CapturedKind = $null
    function Show-MsgModal { param($Title, $Lines, $Kind) $script:CapturedKind = $Kind }
    function Get-SsmLicensedUsers { param($Progress) throw 'must not reload' }
    function Invoke-SsmPersonalSiteRequest { param($Upns, $Progress) throw 'must not request' }
    $tab = @{ OneDrive = $true; Items = @(@{ Url='https://x/a'; Title='a'; Status='Unprovisioned'; FindingCount=0; Findings=@(); Selected=$false; Upn='a@x.com' }) }
    Invoke-SsmOneDriveProvision -Tab $tab
    Assert-Equal 'Warn' $script:CapturedKind
}

Invoke-SsmTest 'Enter on an empty Unprovisioned view loads placeholders instead of enumerating' {
    $script:UI = @{ Dirty = $false; SearchMode = $false; H = 24 }
    $script:Loaded = $false; $script:Enumerated = $false
    function Invoke-SsmOneDriveProvision { param($Tab) $script:Loaded = $true }
    function Invoke-TabEnumerate { param($Tab) $script:Enumerated = $true }
    $tab = @{ OneDrive = $true; Items = @(); View = @(); Filter = 'Unprovisioned'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0 }
    $k = [System.ConsoleKeyInfo]::new([char]13, [System.ConsoleKey]::Enter, $false, $false, $false)
    Invoke-TargetsKey -Tab $tab -K $k
    Assert-Equal $true $script:Loaded
    Assert-Equal $false $script:Enumerated
}

Invoke-SsmTest 'Update-TabView hides placeholder rows under All and shows only them under Unprovisioned' {
    $tab = @{
        Items = @(
            @{ Url = 'https://x/a'; Title = 'a'; Status = 'Clean'; FindingCount = 0 },
            @{ Url = 'https://x/p'; Title = 'p'; Status = 'Unprovisioned'; FindingCount = 0; Upn = 'p@x.com' },
            @{ Url = 'https://x/q'; Title = 'q'; Status = 'ProvisionRequested'; FindingCount = 0; Upn = 'q@x.com' }
        )
        Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0; View = @()
    }
    Update-TabView -Tab $tab
    Assert-Equal 1 @($tab['View']).Count
    Assert-Equal 'https://x/a' $tab['View'][0].Url
    $tab['Filter'] = 'NotScanned'; Update-TabView -Tab $tab
    Assert-Equal 0 @($tab['View']).Count
    $tab['Filter'] = 'Unprovisioned'; Update-TabView -Tab $tab
    Assert-Equal 2 @($tab['View']).Count
}

Invoke-SsmTest 'F cycles into Unprovisioned only on the OneDrives tab' {
    $mk = { param($od) @{ OneDrive = $od; Items = @(); View = @(); Filter = 'Failed'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0 } }
    $script:UI = @{ Dirty = $false; SearchMode = $false; H = 24 }
    $k = [System.ConsoleKeyInfo]::new('f', [System.ConsoleKey]::F, $false, $false, $false)
    $od = & $mk $true;  Invoke-TargetsKey -Tab $od -K $k;  Assert-Equal 'Unprovisioned' $od['Filter']
    Invoke-TargetsKey -Tab $od -K $k;  Assert-Equal 'All' $od['Filter']
    $st = & $mk $false; Invoke-TargetsKey -Tab $st -K $k;  Assert-Equal 'All' $st['Filter']
}

Invoke-SsmTest 'Invoke-TabScan skips placeholder rows' {
    $script:Connected = $false
    function Connect-SsmSite { param($Url) $script:Connected = $true; $false }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    function Write-Screen { }
    function Start-LoadSpinner { }
    function Stop-LoadSpinner { }
    function Write-ProgressModal { }
    function New-SsmProgressCallback { param($Title, $State, $CancelMode) { } }
    function Save-SsmCache { }
    function Update-TabTargetStatuses { param($Tab) }
    $tab = @{
        Items = @(@{ Url = 'https://x/p'; Title = 'p'; Status = 'Unprovisioned'; FindingCount = 0; Findings = @(); Selected = $true; Upn = 'p@x.com' })
        Categories = @('Links'); Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0; View = @()
    }
    Invoke-TabScan -Tab $tab
    Assert-Equal $false $script:Connected
    Assert-Equal 'Unprovisioned' $tab['Items'][0].Status
}

Invoke-SsmTest 'Get-SsmOneDriveAdminSelectedTargets ignores placeholder rows' {
    $tab = @{ Items = @(
        @{ Url = 'https://x/a'; Title = 'a'; Status = 'Clean'; Selected = $true },
        @{ Url = 'https://x/p'; Title = 'p'; Status = 'Unprovisioned'; Selected = $true; Upn = 'p@x.com' }) }
    $r = @(Get-SsmOneDriveAdminSelectedTargets -Tab $tab)
    Assert-Equal 1 $r.Count
    Assert-Equal 'https://x/a' $r[0].Url
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision connects to the admin site before querying Graph (cached-list start)' {
    $script:Auth = @{ AdminUrl = 'https://contoso-admin.sharepoint.com' }
    $script:UI = @{ Dirty = $false }
    $script:Order = @()
    function Write-ProgressModal { }
    function Show-MsgModal { param($Title, $Lines, $Kind) }
    function Export-SsmProvisionCsv { param($Rows, $Phase) 'x.csv' }
    function Connect-SsmAdmin { $script:Order += 'connect'; $true }
    function Get-SsmLicensedUsers { param($Progress) $script:Order += 'graph'; @() }
    function Get-SsmProvisionedOwnerSet { param($Progress) $script:Order += 'owners'; return ,([System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)) }
    $tab = @{ OneDrive = $true; Items = @(@{ Url='https://x/a'; Title='a'; Status='NotScanned'; FindingCount=0; Findings=@(); Selected=$false }); View = @(); Filter = 'All'; Search = ''; SortCol = 'Url'; SortDesc = $false; Cursor = 0 }
    Invoke-SsmOneDriveProvision -Tab $tab
    Assert-Equal 'connect' $script:Order[0]
    Assert-Equal 'graph' $script:Order[1]
}

Invoke-SsmTest 'Invoke-SsmOneDriveProvision aborts quietly when the admin connection fails' {
    $script:Graphed = $false
    function Write-ProgressModal { }
    function Connect-SsmAdmin { $false }
    function Get-SsmLicensedUsers { param($Progress) $script:Graphed = $true; @() }
    Invoke-SsmOneDriveProvision -Tab @{ OneDrive = $true; Items = @() }
    Assert-Equal $false $script:Graphed
}
