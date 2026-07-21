Invoke-SsmTest 'Evidence CSV written with expected name and columns' {
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssm-exp-{0}" -f [guid]::NewGuid())
    $f = @([pscustomobject]@{ Site='https://x/personal/y'; Location='File'; CategoryKey='OrgLink'; Category='Organization link'; Name='doc.docx'; Access='View'; Principal='People in your organization'; Path='/personal/y/Documents/doc.docx'; RemovalKind='Link'; LinkId='1'; ListId='L'; ItemId=3; PrincipalId=$null; RevokeStatus='NotAttempted'; Selected=$true })
    $path = Export-FindingsCsv -Findings $f -SiteUrl 'https://x/personal/y' -Phase 'BEFORE'
    if ($path -notmatch 'SSM_BEFORE_y_\d{8}-\d{6}\.csv$') { throw "bad name: $path" }
    $row = @(Import-Csv -LiteralPath $path)[0]
    Assert-Equal 'Organization link' $row.Category
    Assert-Equal 'NotAttempted' $row.RevokeStatus
    Remove-Item -Recurse -Force $script:ExportDir
}
