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


Invoke-SsmTest 'Get-SsmProvisionFailureHint names the missing SharePoint permission' {
    $h = @(Get-SsmProvisionFailureHint) -join ' '
    if ($h -notmatch 'User\.ReadWrite\.All') { throw "hint missing permission: $h" }
    if ($h -notmatch 'Grant admin consent') { throw "hint missing consent step: $h" }
}

Invoke-SsmTest 'Invoke-SsmPersonalSiteRequest falls back to New-PnPPersonalSite when Request-PnPPersonalSite fails' {
    $script:NewCalled = @()
    function Request-PnPPersonalSite { param($UserEmails) throw 'Attempted to perform an unauthorized operation.' }
    function New-PnPPersonalSite { param($Email) $script:NewCalled = @($Email) }
    $r = @(Invoke-SsmPersonalSiteRequest -Upns @('a@x.com', 'b@x.com'))
    Assert-Equal 2 $r.Count
    Assert-Equal 'Requested' $r[0].Status
    Assert-Equal 'New-PnPPersonalSite' $r[0].Method
    Assert-Equal 2 $script:NewCalled.Count
}

Invoke-SsmTest 'Invoke-SsmPersonalSiteRequest reports Failed with both errors when both cmdlets fail' {
    function Request-PnPPersonalSite { param($UserEmails) throw 'first' }
    function New-PnPPersonalSite { param($Email) throw 'second' }
    $r = @(Invoke-SsmPersonalSiteRequest -Upns @('a@x.com'))
    Assert-Equal 'Failed' $r[0].Status
    if ($r[0].Error -notmatch 'first' -or $r[0].Error -notmatch 'second') { throw "error missing detail: $($r[0].Error)" }
}

Invoke-SsmTest 'Invoke-SsmPersonalSiteRequest uses Request-PnPPersonalSite when it succeeds' {
    function Request-PnPPersonalSite { param($UserEmails) }
    function New-PnPPersonalSite { param($Email) throw 'must not fall back' }
    $r = @(Invoke-SsmPersonalSiteRequest -Upns @('a@x.com'))
    Assert-Equal 'Requested' $r[0].Status
    Assert-Equal 'Request-PnPPersonalSite' $r[0].Method
}
