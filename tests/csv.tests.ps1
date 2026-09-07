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

Invoke-SsmTest 'Export-SsmAdminCsv writes a named, columned round-trippable evidence file (BEFORE)' {
    $prevExportDir = $script:ExportDir
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssm-admin-exp-{0}" -f [guid]::NewGuid())
    try {
        $row = [pscustomobject]@{
            OperationId = '44444444-4444-4444-4444-444444444444'
            TimestampUtc = '2026-09-07T00:00:00Z'; TenantId = '11111111-1111-1111-1111-111111111111'
            Actor = 'operator@contoso.com'; Action = 'Remove'
            TargetUrl = 'https://contoso-my.sharepoint.com/personal/user'
            EnteredUpn = 'admin@contoso.com'; ResolvedUpn = 'admin@contoso.com'
            ResolvedUserId = '22222222-2222-2222-2222-222222222222'
            OwnerUpn = 'user@contoso.com'; OwnerId = '33333333-3333-3333-3333-333333333333'
            PrimaryAdminUpn = 'user@contoso.com'; PrimaryAdminId = '33333333-3333-3333-3333-333333333333'
            AdminLogin = 'i:0#.f|membership|admin@contoso.com'; AdminBefore = $true
            AdminAfter = $null; Result = 'Unverified'; Error = "Read failed, reported `"timeout`"`nRetry read"
        }
        $operationId = [guid]'44444444-4444-4444-4444-444444444444'
        $path = Export-SsmAdminCsv -Rows @($row) -OperationId $operationId -Phase BEFORE
        Assert-Equal "SSM_ADMIN_BEFORE_$operationId.csv" ([IO.Path]::GetFileName($path))
        $readBack = @(Import-Csv -LiteralPath $path)
        Assert-Equal 1 $readBack.Count
        Assert-Equal $row.TargetUrl $readBack[0].TargetUrl
        Assert-Equal $row.EnteredUpn $readBack[0].EnteredUpn
        Assert-Equal $row.ResolvedUpn $readBack[0].ResolvedUpn
        Assert-Equal $row.ResolvedUserId $readBack[0].ResolvedUserId
        Assert-Equal $row.OwnerUpn $readBack[0].OwnerUpn
        Assert-Equal $row.OwnerId $readBack[0].OwnerId
        Assert-Equal $row.PrimaryAdminUpn $readBack[0].PrimaryAdminUpn
        Assert-Equal $row.PrimaryAdminId $readBack[0].PrimaryAdminId
        Assert-Equal $row.AdminLogin $readBack[0].AdminLogin
        Assert-Equal 'True' $readBack[0].AdminBefore
        Assert-Equal '' $readBack[0].AdminAfter
        Assert-Equal $row.Result $readBack[0].Result
        Assert-Equal $row.Error $readBack[0].Error
    } finally {
        if (Test-Path -LiteralPath $script:ExportDir) { Remove-Item -Recurse -Force $script:ExportDir }
        $script:ExportDir = $prevExportDir
    }
}

Invoke-SsmTest 'Export-SsmAdminCsv AFTER phase uses its own filename, both round-trip the same row set' {
    $prevExportDir = $script:ExportDir
    $script:ExportDir = Join-Path ([IO.Path]::GetTempPath()) ("ssm-admin-exp-{0}" -f [guid]::NewGuid())
    try {
        $operationId = [guid]'55555555-5555-5555-5555-555555555555'
        $row = [pscustomobject]@{
            OperationId = "$operationId"; TimestampUtc = '2026-09-07T00:00:00Z'
            TenantId = '11111111-1111-1111-1111-111111111111'; Actor = 'operator@contoso.com'
            Action = 'Add'; TargetUrl = 'https://contoso-my.sharepoint.com/personal/user2'
            EnteredUpn = 'admin@contoso.com'; ResolvedUpn = 'admin@contoso.com'
            ResolvedUserId = '22222222-2222-2222-2222-222222222222'
            OwnerUpn = 'user2@contoso.com'; OwnerId = '33333333-3333-3333-3333-333333333333'
            PrimaryAdminUpn = 'user2@contoso.com'; PrimaryAdminId = '33333333-3333-3333-3333-333333333333'
            AdminLogin = ''; AdminBefore = $false; AdminAfter = $true
            Result = 'Success'; Error = ''
        }
        $beforePath = Export-SsmAdminCsv -Rows @($row) -OperationId $operationId -Phase BEFORE
        $afterPath = Export-SsmAdminCsv -Rows @($row) -OperationId $operationId -Phase AFTER
        Assert-Equal "SSM_ADMIN_AFTER_$operationId.csv" ([IO.Path]::GetFileName($afterPath))
        if ($beforePath -eq $afterPath) { throw 'BEFORE and AFTER must not share a filename' }
        $after = @(Import-Csv -LiteralPath $afterPath)
        Assert-Equal 'True' $after[0].AdminAfter
        Assert-Equal 'Success' $after[0].Result
    } finally {
        if (Test-Path -LiteralPath $script:ExportDir) { Remove-Item -Recurse -Force $script:ExportDir }
        $script:ExportDir = $prevExportDir
    }
}
