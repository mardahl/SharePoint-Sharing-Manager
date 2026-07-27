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
