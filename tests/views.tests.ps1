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
