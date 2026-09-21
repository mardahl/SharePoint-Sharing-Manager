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
    $cat = if ($script:RuleCategories.Contains($Key)) { $script:RuleCategories[$Key] } else { $Key }
    [pscustomobject]@{ Site=$Site; Location=$Loc; Name='doc.docx'; CategoryKey=$Key; Category=$cat; Access=$Access; Principal='p'; Path="/x/$Site/doc.docx"; RemovalKind=$Kind; LinkId='1'; ListId='L'; ItemId=1; PrincipalId=$null; LinkCreated=''; Reach=$Reach; RevokeStatus=$Status; Selected=$false }
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

Invoke-SsmTest 'Exposure: midpoint rounding at .5 boundary rounds away from zero' {
    # 141 findings of weight 1 (unknown CategoryKey 'Other') reach 1 in 2000 items:
    # 141 / 2000 * 1000 = 70.5 -> AwayFromZero rounds to 71 (Critical), not 70 (High).
    $f = @(1..141 | ForEach-Object { New-XlsxTestFinding -Site 's1' -Key 'Other' -Reach 1 })
    $r = Get-ExposureScore -Findings $f -ItemsScanned 2000
    Assert-Equal 141 $r.WeightedReach
    Assert-Equal 71 $r.Score
    Assert-Equal 'Critical' $r.Band
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

Invoke-SsmTest 'Report filename pattern' {
    $n = Get-ReportFileName -TabName 'OneDrives' -SiteTag 'ALL'
    if ($n -notmatch '^SSM_REPORT_OneDrive_ALL_\d{8}-\d{6}\.xlsx$') { throw "bad name: $n" }
    $n2 = Get-ReportFileName -TabName 'Sites' -SiteTag 'hr'
    if ($n2 -notmatch '^SSM_REPORT_SharePoint_hr_\d{8}-\d{6}\.xlsx$') { throw "bad name: $n2" }
}

Invoke-SsmTest 'Report rows carry title, sharing type, full path, reach, ids' {
    $t = New-Target -Url 'https://x/sites/a' -Title 'HR Site'
    $f = @(New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'OrgLink' -Reach 1)
    $f[0].LinkCreated = '2026-07-24T07:10:18.520Z'
    $rows = @(ConvertTo-ReportRows -Findings $f -Targets @($t))
    Assert-Equal 'HR Site' $rows[0].'Site Title'
    Assert-Equal 'https://x/sites/a' $rows[0].'Site URL'
    Assert-Equal 'Link' $rows[0].'Sharing Type'
    Assert-Equal '/x/https://x/sites/a/doc.docx' $rows[0].'Full Path'
    Assert-Equal '2026-07-24' $rows[0].'Link Created'
    Assert-Equal 1 $rows[0].'Reach (items)'
    Assert-Equal 'L' $rows[0].'List Id'
}

Invoke-SsmTest 'Report rows: direct grant label, blank date, title fallback' {
    $f = @(New-XlsxTestFinding -Site 'https://x/sites/zz' -Key 'EEEU' -Kind 'DirectGrant')
    $rows = @(ConvertTo-ReportRows -Findings $f -Targets @())
    Assert-Equal 'Direct grant' $rows[0].'Sharing Type'
    Assert-Equal '' $rows[0].'Link Created'
    Assert-Equal 'zz' $rows[0].'Site Title'
}

Invoke-SsmTest 'Export-FindingsXlsx writes workbook with three sheets (skipped without ImportExcel)' {
    if (-not (Get-Module -ListAvailable ImportExcel)) { Write-Host '  (skipped: ImportExcel not installed)'; return }
    Import-Module ImportExcel
    $prev = $script:ExportDir
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssm-xlsx-{0}" -f [guid]::NewGuid())
    try {
        $t = New-Target -Url 'https://x/sites/a' -Title 'A'; $t.ItemsScanned = 100; $t.Status = 'Findings'; $t.FindingCount = 1
        $f = @(New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'AnonymousLink')
        $t.Findings = $f
        $p = Export-FindingsXlsx -Findings $f -Targets @($t) -TabName 'Sites' -ScopeLabel 'All SharePoint sites' -SiteTag 'ALL' -IncludeSites $true
        if (-not (Test-Path -LiteralPath $p)) { throw "no file: $p" }
        $pkg = Open-ExcelPackage -Path $p
        $sheets = @($pkg.Workbook.Worksheets | ForEach-Object { $_.Name })
        Assert-Equal 'Summary,Findings,Sites' ($sheets -join ',')
        $findingsHeaderCols = @($pkg.Workbook.Worksheets['Findings'].Dimension.Columns)
        Assert-Equal 15 $findingsHeaderCols
        $a1 = [string]$pkg.Workbook.Worksheets['Summary'].Cells['A1'].Value
        if ($a1 -notmatch 'SharePoint Sharing Manager') { throw "Summary A1 missing title: $a1" }
        Close-ExcelPackage $pkg -NoSave
        $tmpLeftover = [IO.Path]::ChangeExtension($p, '.tmp.xlsx')
        if (Test-Path -LiteralPath $tmpLeftover) { throw 'temp file left behind' }
    } finally {
        if (Test-Path -LiteralPath $script:ExportDir) { Remove-Item -Recurse -Force $script:ExportDir }
        $script:ExportDir = $prev
    }
}

Invoke-SsmTest 'Export scope: target list = whole tab, findings view = current view' {
    $ta = New-Target -Url 'https://x/sites/a' -Title 'A'
    $ta.Findings = @((New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'OrgLink'), (New-XlsxTestFinding -Site 'https://x/sites/a' -Key 'AnonymousLink'))
    $tb = New-Target -Url 'https://x/sites/b' -Title 'B'
    $tb.Findings = @(New-XlsxTestFinding -Site 'https://x/sites/b' -Key 'EEEU')
    $tab = @{ Kind='Targets'; Name='Sites'; Noun='sites'; Mode='Targets'; Items=@($ta,$tb); View=@($ta,$tb) }
    $s = Get-ExportScope -Tab $tab
    Assert-Equal 3 @($s.Findings).Count
    Assert-Equal 'ALL' $s.SiteTag
    Assert-Equal $true $s.IncludeSites
    Assert-Equal 'All sites' $s.ScopeLabel

    $tab['Mode'] = 'Findings'
    $tab['FTab'] = @{ Target = $ta; Items = @($ta.Findings); View = @($ta.Findings[0]); Filter='OrgLink'; Search='' }
    $s2 = Get-ExportScope -Tab $tab
    Assert-Equal 1 @($s2.Findings).Count
    Assert-Equal 'a' $s2.SiteTag
    Assert-Equal $false $s2.IncludeSites

    $tab['FTab'] = @{ Target = @{ Url = 'All sites' }; Items = @($ta.Findings + $tb.Findings); View = @($ta.Findings + $tb.Findings); Filter='All'; Search=''; Aggregate=$true }
    $s3 = Get-ExportScope -Tab $tab
    Assert-Equal 'ALL' $s3.SiteTag
    Assert-Equal $true $s3.IncludeSites
}

