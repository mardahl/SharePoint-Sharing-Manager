# ============================================================================
#region Update check (notify-only)
# ============================================================================
# Startup check against GitHub Releases. Notify-only: never downloads, never
# blocks startup. Any failure is logged and swallowed so the tool always boots.

$script:SsmReleasesApi = 'https://api.github.com/repos/mardahl/SharePoint-Sharing-Manager/releases/latest'
$script:SsmReleasesUrl = 'https://github.com/mardahl/SharePoint-Sharing-Manager/releases/latest'

function Get-SsmLatestVersion {
    # Latest release tag from GitHub as [version]; $null on any failure.
    # Tests shadow Invoke-RestMethod to drive the branches.
    try {
        $r = Invoke-RestMethod -Uri $script:SsmReleasesApi -TimeoutSec 5 -Headers @{ 'User-Agent' = 'SharePoint-Sharing-Manager' }
        $tag = [string]$r.tag_name -replace '^[vV]', ''
        return [version]$tag
    } catch {
        Write-SsmLog -Message ("Update check skipped: {0}" -f $_.Exception.Message) -Level DEBUG
        return $null
    }
}

function Test-SsmNewerVersion {
    param([Parameter(Mandatory)][version]$Latest, [Parameter(Mandatory)][version]$Current)
    return ($Latest -gt $Current)
}

function Show-SsmUpdateNotice {
    # Startup hook. Shows a modal only when GitHub has a newer release.
    # Y opens the releases page in the default browser; N/Esc just continues.
    $latest = Get-SsmLatestVersion
    if ($null -eq $latest) { return }
    if (-not (Test-SsmNewerVersion -Latest $latest -Current ([version]$script:Version))) { return }
    Write-SsmLog -Message ("Update available: v{0} -> v{1}" -f $script:Version, $latest) -Level INFO
    $open = Show-ConfirmModal -Title 'Update available' -Lines @(
        ("A newer version is available:  v{0} -> v{1}" -f $script:Version, $latest),
        '',
        'Download: github.com/mardahl/SharePoint-Sharing-Manager/releases/latest',
        '',
        'Updating replaces only the script file.',
        'Your settings (~/.sharepoint-sharing-manager.json),',
        'scan cache, and exports remain untouched.',
        '',
        'Open download page in browser?'
    )
    if ($open) { Open-SsmUrl -Url $script:SsmReleasesUrl }
}
