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
