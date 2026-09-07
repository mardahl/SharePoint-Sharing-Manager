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
        $st = $State
        return { param($Count, $Total, $Label, $Ok, $Failed) if ($Count -ge 1) { $st.Cancel = $true } }.GetNewClosure()
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
