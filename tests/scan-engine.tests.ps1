Invoke-SsmTest 'EEEU login classified' {
    Assert-Equal 'EEEU' (Get-PrincipalCategory -Login 'c:0-.f|rolemanager|spo-grid-all-users/abc123' -Title 'Everyone except external users')
}
Invoke-SsmTest 'Everyone claim classified' {
    Assert-Equal 'Everyone' (Get-PrincipalCategory -Login 'c:0(.s|true' -Title 'Everyone')
}
Invoke-SsmTest 'Guest ext login classified' {
    Assert-Equal 'GuestGrant' (Get-PrincipalCategory -Login 'i:0#.f|membership|jane_gmail.com#ext#@contoso.onmicrosoft.com' -Title 'Jane Guest')
}
Invoke-SsmTest 'Internal member kept (null)' {
    Assert-Equal '' (Get-PrincipalCategory -Login 'i:0#.f|membership|bob@contoso.com' -Title 'Bob')
}
Invoke-SsmTest 'SharingLinks principal skipped' {
    Assert-Equal '' (Get-PrincipalCategory -Login 'x' -Title 'SharingLinks.abc.Flexible.def')
}
Invoke-SsmTest 'Empty principal skipped' {
    Assert-Equal '' (Get-PrincipalCategory -Login '' -Title '')
}
Invoke-SsmTest 'Guest grantees extracted from users-link' {
    $link = [pscustomobject]@{ GrantedToIdentitiesV2 = @(
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|g_x.com#ext#@t.onmicrosoft.com' }; User = [pscustomobject]@{ Email = 'g@x.com' } },
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|bob@contoso.com' }; User = [pscustomobject]@{ Email = 'bob@contoso.com' } }
    )}
    $g = @(Get-GuestGrantees -Link $link)
    Assert-Equal 1 $g.Count
    Assert-Equal 'g@x.com' $g[0]
}
Invoke-SsmTest 'Guest grantee with unresolved User identity (SiteUser only) does not throw' {
    $link = [pscustomobject]@{ GrantedToIdentitiesV2 = @(
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|g_x.com#ext#@t.onmicrosoft.com' }; User = $null }
    )}
    $g = @(Get-GuestGrantees -Link $link)
    Assert-Equal 1 $g.Count
    Assert-Equal 'i:0#.f|membership|g_x.com#ext#@t.onmicrosoft.com' $g[0]
}
Invoke-SsmTest 'Link categories: anonymous / organization / internal users-link' {
    $r = Get-LinkCategory -Scope 'anonymous' -Link ([pscustomobject]@{})
    Assert-Equal 'AnonymousLink' $r.Key
    $r = Get-LinkCategory -Scope 'organization' -Link ([pscustomobject]@{})
    Assert-Equal 'OrgLink' $r.Key
    $r = Get-LinkCategory -Scope 'users' -Link ([pscustomobject]@{ GrantedToIdentitiesV2 = @() })
    Assert-Equal '' $r    # internal-only specific-people link is KEPT
}
Invoke-SsmTest 'Guest users-link principal carries [guest] marker' {
    $link = [pscustomobject]@{ GrantedToIdentitiesV2 = @(
        [pscustomobject]@{ SiteUser = [pscustomobject]@{ LoginName = 'i:0#.f|membership|g_x.com#ext#@t.onmicrosoft.com' }; User = [pscustomobject]@{ Email = 'g@x.com' } }
    )}
    $r = Get-LinkCategory -Scope 'users' -Link $link
    Assert-Equal 'GuestLink' $r.Key
    Assert-Equal 'g@x.com [guest]' $r.Principal
}

Invoke-SsmTest 'New-Target defaults ItemsScanned and LibrariesScanned to 0' {
    $t = New-Target -Url 'https://x.sharepoint.com/sites/a'
    Assert-Equal 0 $t.ItemsScanned
    Assert-Equal 0 $t.LibrariesScanned
}

Invoke-SsmTest 'Cache round-trips ItemsScanned and finding Reach' {
    $t = New-Target -Url 'https://x.sharepoint.com/sites/a'
    $t.ItemsScanned = 1234; $t.LibrariesScanned = 2; $t.Status = 'Findings'; $t.FindingCount = 1
    $t.Findings = @([pscustomobject]@{ Site=$t.Url; Location='Library'; Name='Documents'; CategoryKey='EEEU'; Category='EEEU grant'; Access='Read'; Principal='Everyone except external users'; Path='/sites/a/Shared Documents'; RemovalKind='DirectGrant'; LinkId=$null; ListId='L'; ItemId=$null; PrincipalId=4; LinkCreated=''; Reach=1000; RevokeStatus='NotAttempted'; Selected=$false })
    $tab = @{ Kind='Targets'; Name='Sites'; Categories=@('EEEU'); Items=@($t) }
    $json = ConvertTo-SsmCacheObject -Tabs @($tab) | ConvertTo-Json -Depth 10
    $tab2 = @{ Kind='Targets'; Name='Sites'; Categories=@(); Items=@() }
    ConvertFrom-SsmCacheObject -Cache ($json | ConvertFrom-Json) -Tabs @($tab2)
    Assert-Equal 1234 $tab2['Items'][0].ItemsScanned
    Assert-Equal 2 $tab2['Items'][0].LibrariesScanned
    Assert-Equal 1000 $tab2['Items'][0].Findings[0].Reach
}

Invoke-SsmTest 'Cache restore tolerates old entries without ItemsScanned' {
    $old = [pscustomobject]@{ Tabs=@([pscustomobject]@{ Name='Sites'; Categories=@(); Items=@([pscustomobject]@{ Url='https://x/sites/a'; Title='a'; Template=''; Status='Clean'; FindingCount=0; Findings=@() }) }); SavedAt='2026-01-01T00:00:00Z' }
    $tab = @{ Kind='Targets'; Name='Sites'; Categories=@(); Items=@() }
    ConvertFrom-SsmCacheObject -Cache $old -Tabs @($tab)
    Assert-Equal 0 $tab['Items'][0].ItemsScanned
}

Invoke-SsmTest 'Complete-SiteScan sets ItemsScanned and web Reach' {
    $t = New-Target -Url 'https://x/sites/a'
    $bag = [System.Collections.Generic.List[object]]::new()
    $bag.Add([pscustomobject]@{ Location='Web'; Reach=0 })
    $bag.Add([pscustomobject]@{ Location='File'; Reach=1 })
    $out = @(Complete-SiteScan -Target $t -Bag $bag -TotalItems 500 -LibCount 3)
    Assert-Equal 500 $t.ItemsScanned
    Assert-Equal 3 $t.LibrariesScanned
    Assert-Equal 500 $out[0].Reach
    Assert-Equal 1 $out[1].Reach
}

