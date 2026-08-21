# Update-check tests. Get-SsmLatestVersion is tested via a shadowed
# Invoke-RestMethod; Test-SsmNewerVersion is pure.

Invoke-SsmTest 'Test-SsmNewerVersion: newer patch returns true' {
    Assert-Equal 'True' (Test-SsmNewerVersion -Latest ([version]'1.6.1') -Current ([version]'1.6.0'))
}

Invoke-SsmTest 'Test-SsmNewerVersion: same version returns false' {
    Assert-Equal 'False' (Test-SsmNewerVersion -Latest ([version]'1.6.0') -Current ([version]'1.6.0'))
}

Invoke-SsmTest 'Test-SsmNewerVersion: older version returns false' {
    Assert-Equal 'False' (Test-SsmNewerVersion -Latest ([version]'1.5.9') -Current ([version]'1.6.0'))
}

Invoke-SsmTest 'Get-SsmLatestVersion parses v-prefixed tag_name' {
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) @{ tag_name = 'v1.7.0' } }
    $r = Get-SsmLatestVersion
    Assert-Equal '1.7.0' $r
}

Invoke-SsmTest 'Get-SsmLatestVersion parses bare tag_name' {
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) @{ tag_name = '1.7.2' } }
    $r = Get-SsmLatestVersion
    Assert-Equal '1.7.2' $r
}

Invoke-SsmTest 'Get-SsmLatestVersion returns null on network error' {
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) throw 'offline' }
    $r = Get-SsmLatestVersion
    Assert-Equal '' $r
}

Invoke-SsmTest 'Get-SsmLatestVersion returns null on garbage tag' {
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) @{ tag_name = 'not-a-version' } }
    $r = Get-SsmLatestVersion
    Assert-Equal '' $r
}

Invoke-SsmTest 'Show-SsmUpdateNotice shows modal when newer version exists' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { [version]'1.7.0' }
    $script:ModalTitle = $null
    function Show-ConfirmModal { param($Title, $Lines) $script:ModalTitle = $Title; return $false }
    Show-SsmUpdateNotice
    Assert-Equal 'Update available' $script:ModalTitle
}

Invoke-SsmTest 'Show-SsmUpdateNotice copy promises settings/cache/exports untouched' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { [version]'1.7.0' }
    $script:ModalLines = $null
    function Show-ConfirmModal { param($Title, $Lines) $script:ModalLines = $Lines; return $false }
    Show-SsmUpdateNotice
    $flat = $script:ModalLines -join ' '
    if ($flat -notmatch 'settings')        { throw 'copy missing settings assurance' }
    if ($flat -notmatch 'scan cache')      { throw 'copy missing cache assurance' }
    if ($flat -notmatch 'exports')         { throw 'copy missing exports assurance' }
    if ($flat -notmatch 'remain untouched'){ throw 'copy missing remain-untouched phrase' }
    if ($flat -notmatch '1\.6\.0')         { throw 'copy missing current version' }
    if ($flat -notmatch '1\.7\.0')         { throw 'copy missing new version' }
}

Invoke-SsmTest 'Show-SsmUpdateNotice opens browser on Y' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { [version]'1.7.0' }
    function Show-ConfirmModal { param($Title, $Lines) return $true }
    $script:OpenedUrl = $null
    function Open-SsmUrl { param([string]$Url) $script:OpenedUrl = $Url }
    Show-SsmUpdateNotice
    Assert-Equal 'https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest' $script:OpenedUrl
}

Invoke-SsmTest 'Show-SsmUpdateNotice silent when version is current' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { [version]'1.6.0' }
    $script:ModalTitle = $null
    function Show-ConfirmModal { param($Title, $Lines) $script:ModalTitle = $Title; return $false }
    Show-SsmUpdateNotice
    Assert-Equal '' $script:ModalTitle
}

Invoke-SsmTest 'Show-SsmUpdateNotice silent when check fails (offline)' {
    $script:Version = '1.6.0'
    function Get-SsmLatestVersion { return $null }
    $script:ModalTitle = $null
    function Show-ConfirmModal { param($Title, $Lines) $script:ModalTitle = $Title; return $false }
    Show-SsmUpdateNotice
    Assert-Equal '' $script:ModalTitle
}
