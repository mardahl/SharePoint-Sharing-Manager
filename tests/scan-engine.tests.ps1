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
Invoke-SsmTest 'Link categories: anonymous / organization / internal users-link' {
    $r = Get-LinkCategory -Scope 'anonymous' -Link ([pscustomobject]@{})
    Assert-Equal 'AnonymousLink' $r.Key
    $r = Get-LinkCategory -Scope 'organization' -Link ([pscustomobject]@{})
    Assert-Equal 'OrgLink' $r.Key
    $r = Get-LinkCategory -Scope 'users' -Link ([pscustomobject]@{ GrantedToIdentitiesV2 = @() })
    Assert-Equal '' $r    # internal-only specific-people link is KEPT
}
