$script:RuleCategories = [ordered]@{
    AnonymousLink = 'Anonymous link'
    OrgLink       = 'Organization link'
    GuestLink     = 'Guest-specific link'
    GuestGrant    = 'Guest grant'
    EEEU          = 'EEEU grant'
    Everyone      = 'Everyone grant'
}

function New-XlsxTestFinding {
    param([string]$Site, [string]$Key, [string]$Loc = 'File', [int]$Reach = 1, [string]$Access = 'View', [string]$Status = 'NotAttempted', [string]$Kind = 'Link')
    [pscustomobject]@{ Site=$Site; Location=$Loc; Name='doc.docx'; CategoryKey=$Key; Category=$script:RuleCategories[$Key]; Access=$Access; Principal='p'; Path="/x/$Site/doc.docx"; RemovalKind=$Kind; LinkId='1'; ListId='L'; ItemId=1; PrincipalId=$null; LinkCreated=''; Reach=$Reach; RevokeStatus=$Status; Selected=$false }
}

Invoke-SsmTest 'Exposure: 5 anonymous links in 1000 items -> 25 Medium' {
    $f = @(1..5 | ForEach-Object { New-XlsxTestFinding -Site 's1' -Key 'AnonymousLink' })
    $r = Get-ExposureScore -Findings $f -ItemsScanned 1000
    Assert-Equal 25 $r.WeightedReach
    Assert-Equal 25 $r.Score
    Assert-Equal 'Medium' $r.Band
    Assert-Equal 0.5 $r.ExposedPercent
}

Invoke-SsmTest 'Exposure: library EEEU reaching every item -> 100 Critical' {
    $f = @(New-XlsxTestFinding -Site 's1' -Key 'EEEU' -Loc 'Library' -Reach 1000 -Kind 'DirectGrant')
    $r = Get-ExposureScore -Findings $f -ItemsScanned 1000
    Assert-Equal 100 $r.Score
    Assert-Equal 'Critical' $r.Band
}

Invoke-SsmTest 'Exposure: zero items scanned -> n/a' {
    $r = Get-ExposureScore -Findings @(New-XlsxTestFinding -Site 's1' -Key 'OrgLink') -ItemsScanned 0
    Assert-Equal 0 $r.Score
    Assert-Equal 'n/a' $r.Band
}

Invoke-SsmTest 'Exposure: bands at boundaries' {
    # weight 1 (GuestGrant is 2; use unknown key for weight 1) reach 10 of 1000 -> 10 Low
    $low = @(New-XlsxTestFinding -Site 's1' -Key 'Everyone' -Reach 2)   # 5*2=10 -> 10 Low
    Assert-Equal 'Low' (Get-ExposureScore -Findings $low -ItemsScanned 1000).Band
    $high = @(New-XlsxTestFinding -Site 's1' -Key 'OrgLink' -Reach 20)  # 3*20=60 -> High
    Assert-Equal 'High' (Get-ExposureScore -Findings $high -ItemsScanned 1000).Band
}

Invoke-SsmTest 'Summary: counts, distinct sites, top sites ordering' {
    $f = @(
        (New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'AnonymousLink' -Access 'Edit'),
        (New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'OrgLink' -Status 'Removed'),
        (New-XlsxTestFinding -Site 'https://x/sites/b' -Key 'GuestGrant' -Kind 'DirectGrant' -Status 'Failed: 403')
    )
    $ta = New-Target -Url 'https://x/sites/a' -Title 'A'; $ta.ItemsScanned = 100
    $tb = New-Target -Url 'https://x/sites/b' -Title 'B'; $tb.ItemsScanned = 50
    $s = Get-FindingsSummary -Findings $f -Targets @($ta, $tb)
    Assert-Equal 3 $s.Total
    Assert-Equal 2 $s.SitesAffected
    Assert-Equal 2 $s.Links
    Assert-Equal 1 $s.DirectGrants
    Assert-Equal 1 $s.AnonymousLinks
    Assert-Equal 1 $s.Removed
    Assert-Equal 1 $s.Failed
    Assert-Equal 1 $s.NotAttempted
    Assert-Equal 150 $s.ItemsScanned
    Assert-Equal 'https://x/sites/a' $s.TopSites[0].Site
    Assert-Equal 'A' $s.TopSites[0].Title
    Assert-Equal 2 $s.TopSites[0].Count
    Assert-Equal 'Anonymous link' $s.ByCategory[0].Category
    Assert-Equal 2 @($s.ByAccess | Where-Object { $_.Access -eq 'View' })[0].Count
}
