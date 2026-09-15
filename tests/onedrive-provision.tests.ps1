Invoke-SsmTest 'ConvertTo-SsmPersonalSlug replaces . and @ with _ and lowercases' {
    Assert-Equal 'john_doe_contoso_com' (ConvertTo-SsmPersonalSlug -Upn 'John.Doe@Contoso.com')
}

Invoke-SsmTest 'Select-SsmSharePointLicensed keeps only enabled SharePoint plans' {
    $users = @(
        [pscustomobject]@{ id='1'; userPrincipalName='a@x.com'; displayName='A'; assignedPlans=@(
            [pscustomobject]@{ service='SharePoint'; capabilityStatus='Enabled' }) },
        [pscustomobject]@{ id='2'; userPrincipalName='b@x.com'; displayName='B'; assignedPlans=@(
            [pscustomobject]@{ service='SharePoint'; capabilityStatus='Deleted' }) },
        [pscustomobject]@{ id='3'; userPrincipalName='c@x.com'; displayName='C'; assignedPlans=@(
            [pscustomobject]@{ service='exchange'; capabilityStatus='Enabled' }) },
        [pscustomobject]@{ id='4'; userPrincipalName='d@x.com'; displayName='D'; assignedPlans=@() }
    )
    $r = @(Select-SsmSharePointLicensed -Users $users)
    Assert-Equal 1 $r.Count
    Assert-Equal 'a@x.com' $r[0].Upn
    Assert-Equal '1' $r[0].Id
    Assert-Equal 'A' $r[0].DisplayName
}

Invoke-SsmTest 'Get-SsmUnprovisionedUsers matches by UPN, by slug, case-insensitive' {
    $lic = @(
        [pscustomobject]@{ Id='1'; Upn='Has.Owner@x.com'; DisplayName='' },
        [pscustomobject]@{ Id='2'; Upn='slug.only@x.com'; DisplayName='' },
        [pscustomobject]@{ Id='3'; Upn='missing@x.com'; DisplayName='' }
    )
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$set.Add('has.owner@x.com')
    [void]$set.Add('slug_only_x_com')
    $r = @(Get-SsmUnprovisionedUsers -Licensed $lic -OwnerSet $set)
    Assert-Equal 1 $r.Count
    Assert-Equal 'missing@x.com' $r[0].Upn
}

Invoke-SsmTest 'Get-SsmUnprovisionedUsers returns empty for empty input' {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Assert-Equal 0 (@(Get-SsmUnprovisionedUsers -Licensed @() -OwnerSet $set)).Count
}

Invoke-SsmTest 'Split-SsmBatch chunks into fixed sizes with remainder' {
    $b = @(Split-SsmBatch -Items @(1..5 | ForEach-Object { "u$_" }) -Size 2)
    Assert-Equal 3 $b.Count
    Assert-Equal 2 (@($b[0])).Count
    Assert-Equal 1 (@($b[2])).Count
    Assert-Equal 'u5' (@($b[2]))[0]
}

Invoke-SsmTest 'Test-SsmPlaceholderTarget is true only for provisioning statuses' {
    Assert-Equal $true  (Test-SsmPlaceholderTarget -Target @{ Status = 'Unprovisioned' })
    Assert-Equal $true  (Test-SsmPlaceholderTarget -Target @{ Status = 'ProvisionRequested' })
    Assert-Equal $false (Test-SsmPlaceholderTarget -Target @{ Status = 'NotScanned' })
    Assert-Equal $false (Test-SsmPlaceholderTarget -Target @{ Status = 'Clean' })
}

Invoke-SsmTest 'Get-StatusBadge renders Unprovisioned and Requested badges' {
    $prevT = Get-Variable -Name T -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $prevG = Get-Variable -Name G -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $script:T = @{ Attention = '<A>'; Cloud = '<C>'; Muted = ''; Row = '' }
    $script:G = @{ Bang = '!'; Half = '~'; Ring = 'o'; Dot = '*' }
    try {
        $u = Get-StatusBadge -Status 'Unprovisioned' -Width 16
        if ($u -notlike '<A>! Unprovisioned*') { throw "unexpected: $u" }
        $r = Get-StatusBadge -Status 'ProvisionRequested' -Width 16
        if ($r -notlike '<C>~ Requested*') { throw "unexpected: $r" }
    } finally { $script:T = $prevT; $script:G = $prevG }
}


Invoke-SsmTest 'Get-SsmProvisionFailureHint explains the SPO Management Shell sign-in requirement' {
    $h = @(Get-SsmProvisionFailureHint) -join ' '
    if ($h -notmatch 'SharePoint Administrator') { throw "hint missing role: $h" }
    if ($h -notmatch '4329') { throw "hint missing issue ref: $h" }
}

Invoke-SsmTest 'Invoke-SsmPersonalSiteRequest passes the provisioning connection to Request-PnPPersonalSite' {
    $script:SeenConn = $null; $script:SeenEmails = @()
    function Request-PnPPersonalSite { param($UserEmails, $Connection) $script:SeenConn = $Connection; $script:SeenEmails = @($UserEmails) }
    $conn = [pscustomobject]@{ Url = 'https://contoso-admin.sharepoint.com' }
    $r = @(Invoke-SsmPersonalSiteRequest -Upns @('a@x.com', 'b@x.com') -Connection $conn)
    Assert-Equal 2 $r.Count
    Assert-Equal 'Requested' $r[0].Status
    Assert-Equal 'https://contoso-admin.sharepoint.com' $script:SeenConn.Url
    Assert-Equal 2 $script:SeenEmails.Count
}

Invoke-SsmTest 'Invoke-SsmPersonalSiteRequest marks the whole batch Failed on error and continues' {
    function Request-PnPPersonalSite { param($UserEmails, $Connection) throw 'Attempted to perform an unauthorized operation.' }
    $r = @(Invoke-SsmPersonalSiteRequest -Upns @('a@x.com') -Connection ([pscustomobject]@{}))
    Assert-Equal 'Failed' $r[0].Status
    if ($r[0].Error -notmatch 'unauthorized') { throw "error not captured: $($r[0].Error)" }
}

Invoke-SsmTest 'Connect-SsmProvisioningSession uses the SPO Management Shell client id and caches the connection' {
    $script:ProvConn = $null
    $script:Auth = @{ AdminUrl = 'https://contoso-admin.sharepoint.com'; Tenant = 'contoso.onmicrosoft.com' }
    $script:Calls = 0
    function Invoke-OnMainBuffer { param([scriptblock]$Action) & $Action }
    function Write-Host { }
    function Start-Sleep { }
    function Connect-PnPOnline { param($Url, $Interactive, $ClientId, $ReturnConnection, $Tenant, $ErrorAction)
        $script:Calls++; [pscustomobject]@{ Url = $Url; ClientId = $ClientId } }
    try {
        $c1 = Connect-SsmProvisioningSession
        $c2 = Connect-SsmProvisioningSession
        Assert-Equal '9bc3ab49-b65d-410a-85ad-de819febfddc' $c1.ClientId
        Assert-Equal 'https://contoso-admin.sharepoint.com' $c1.Url
        Assert-Equal 1 $script:Calls
        Assert-Equal $c1.Url $c2.Url
    } finally { $script:ProvConn = $null }
}
