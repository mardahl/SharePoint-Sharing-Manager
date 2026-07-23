Invoke-SsmTest 'Cache round-trips a target and finding' {
    $script:Version = '9.9.9'
    $finding = [pscustomobject]@{
        Site='https://x/personal/a'; Location='File'; Name='q.xlsx'
        CategoryKey='OrgLink'; Category='Organization link'; Access='View'
        Principal='People in your organization'; Path='/p/q.xlsx'; RemovalKind='Link'
        LinkId='L1'; ListId='LI1'; ItemId=5; PrincipalId=$null
        RevokeStatus='NotAttempted'; Selected=$true
    }
    $srcTabs = @(
        @{ Kind='Targets'; Name='OneDrives'; Categories=[System.Collections.ArrayList]@('OrgLink')
           Items=@(@{ Url='https://x/personal/a'; Title='a'; Template='SPSPERS'
                      Status='Findings'; FindingCount=1; Findings=@($finding); Selected=$true }) }
    )
    $obj  = ConvertTo-SsmCacheObject -Tabs $srcTabs
    $json = $obj | ConvertTo-Json -Depth 8
    $back = $json | ConvertFrom-Json

    $dstTabs = @(
        @{ Kind='Targets'; Name='OneDrives'; Categories=[System.Collections.ArrayList]@(); Items=@(); Loaded=$false }
    )
    ConvertFrom-SsmCacheObject -Cache $back -Tabs $dstTabs

    Assert-Equal 1 @($dstTabs[0].Items).Count
    Assert-Equal 'https://x/personal/a' $dstTabs[0].Items[0].Url
    Assert-Equal 'Findings' $dstTabs[0].Items[0].Status
    Assert-Equal 1 @($dstTabs[0].Items[0].Findings).Count
    Assert-Equal 'q.xlsx' $dstTabs[0].Items[0].Findings[0].Name
    Assert-Equal 'False' $dstTabs[0].Items[0].Findings[0].Selected   # reset on restore
    Assert-Equal 'True'  $dstTabs[0].Loaded
    Assert-Equal 'OrgLink' $dstTabs[0].Categories[0]
}

Invoke-SsmTest 'Save then restore via disk round-trips' {
    $script:Version = '9.9.9'
    $script:CacheDir  = Join-Path ([IO.Path]::GetTempPath()) ("ssmcache-{0}" -f [guid]::NewGuid())
    $script:CacheFile = Join-Path $script:CacheDir 'session.json'
    $script:CacheWarning = 'test-warning'
    $script:Tabs = @(
        @{ Kind='Targets'; Name='OneDrives'; Categories=[System.Collections.ArrayList]@('OrgLink')
           Items=@(@{ Url='https://x/personal/a'; Title='a'; Template='SPSPERS'
                      Status='Clean'; FindingCount=0; Findings=@(); Selected=$false }) }
    )
    Save-SsmCache
    Assert-Equal 'True' ([string](Test-Path -LiteralPath $script:CacheFile))

    $avail = Test-SsmCacheAvailable
    Assert-Equal 1 $avail.Count

    $script:Tabs = @(
        @{ Kind='Targets'; Name='OneDrives'; Categories=[System.Collections.ArrayList]@(); Items=@(); Loaded=$false }
    )
    $ok = Restore-SsmCache
    Assert-Equal 'True' ([string]$ok)
    Assert-Equal 'https://x/personal/a' $script:Tabs[0].Items[0].Url
    Assert-Equal 'Clean' $script:Tabs[0].Items[0].Status

    Remove-Item -LiteralPath $script:CacheDir -Recurse -Force -ErrorAction SilentlyContinue
}
