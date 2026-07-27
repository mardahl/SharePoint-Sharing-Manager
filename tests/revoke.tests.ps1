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
