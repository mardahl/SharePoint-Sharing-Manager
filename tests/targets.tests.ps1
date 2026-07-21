$csv = Join-Path ([IO.Path]::GetTempPath()) ("ssm-{0}.csv" -f [guid]::NewGuid())

Invoke-SsmTest 'CSV import: Url header' {
    @('Url','https://a/ ',' https://b',''), '' | Out-Null
    Set-Content -LiteralPath $csv -Value "Url`nhttps://a/ `n https://b`n"
    $u = @(Get-UrlsFromCsv -Path $csv)
    Assert-Equal 2 $u.Count
    Assert-Equal 'https://a/' $u[0].TrimEnd()   # trimmed of spaces, not slash
    Assert-Equal 'https://b' $u[1]
}
Invoke-SsmTest 'CSV import: falls back to first column' {
    Set-Content -LiteralPath $csv -Value "SiteUrl`nhttps://c`n"
    $u = @(Get-UrlsFromCsv -Path $csv)
    Assert-Equal 'https://c' $u[0]
}
Invoke-SsmTest 'CSV import: missing file throws' {
    $threw = $false
    try { Get-UrlsFromCsv -Path '/nonexistent/x.csv' } catch { $threw = $true }
    Assert-Equal 'True' $threw
}
Invoke-SsmTest 'Add-TargetsToTab dedupes by URL' {
    $tab = @{ Items = @(); View = @(); Cursor = 0; Search=''; Filter='All'; SortCol='Url'; SortDesc=$false }
    Add-TargetsToTab -Tab $tab -Targets @((New-Target -Url 'https://a'), (New-Target -Url 'https://a/'), (New-Target -Url 'https://b'))
    Assert-Equal 2 @($tab.Items).Count
}
Remove-Item -LiteralPath $csv -ErrorAction SilentlyContinue
