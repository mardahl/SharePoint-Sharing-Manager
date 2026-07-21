#Requires -Version 7.0
<#
    Revoke-OrgWideSharingLinks.ps1

    Reports, then (after you type YES) removes every organization-wide
    ("People in your organization") sharing link on one SharePoint Online site.

    Only org-wide links go. Anonymous links, specific-people links and direct user grants are
    left alone. Files and folders are never deleted and inheritance is never reset.

    Works whatever language the site is in, Danish included: detection keys off the API
    constants, not the display text, and system libraries are matched by their fixed URL name
    instead of their translated title.

    Known issues
      - Covers file- and folder-level sharing links in document libraries. Links attached to list
        items in non-document-library lists are not handled.

    ---- One-time setup per tenant ----------------------------------------------------------
    PnP needs its own Entra app to sign in - the shared PnP app was retired on 9 Sep 2024. Run
    this once against the tenant (any user can create it; a Global Admin consents to it):

      Register-PnPEntraIDAppForInteractiveLogin -ApplicationName "inciro-M365-Cleanup" -Tenant "<tenant>.onmicrosoft.com" -Interactive

    That makes a single-tenant app for interactive (delegated) sign-in and prints a Client Id.
    Delegated means it only ever does what the admin signing in can do, with nothing left
    standing behind it. Pass the Client Id once with -ClientId and it is written to the config
    file below; after that you can leave it off. The OneDrive cleanup script reads the same file.

    Config file (shared with Revoke-OneDrive-NonMemberAccess.ps1):
      %USERPROFILE%\.inciro-m365-cleanup.json    ->    { "ClientId": "<app-guid>" }

    Needs PowerShell 7+ and PnP.PowerShell (installed for the current user if missing), and you
    have to be Site Collection Admin on the site.

    Example (once the Client Id is saved, drop -ClientId):
      ./Revoke-OrgWideSharingLinks.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/Marketing" -ClientId "<app-guid>"
#>
param(
    [Parameter(Mandatory)][string]$SiteUrl,
    [string]$ClientId,
    [string]$Tenant,
    [string]$ConfigPath   = (Join-Path $HOME '.inciro-m365-cleanup.json'),
    [string]$OutputFolder = (Get-Location).Path
)

# --- Install PnP.PowerShell for the current user if it is not already here ---
$module = 'PnP.PowerShell'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Host "$module is not installed - getting it for the current user..." -ForegroundColor Yellow
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    Write-Host "$module installed." -ForegroundColor Green
}
Import-Module $module -ErrorAction Stop

# --- Which app to sign in with: the -ClientId parameter first, otherwise the saved config ---
function Resolve-ClientId([string]$ClientId, [string]$ConfigPath, [string]$Tenant) {
    if ($ClientId) {
        # Save it so the parameter can be left off next time (both scripts read this same file).
        try { @{ ClientId = $ClientId } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 }
        catch { Write-Host "Couldn't write $ConfigPath - using the id for this run only." -ForegroundColor DarkYellow }
        return $ClientId
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $saved = (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).ClientId
            if ($saved) { Write-Host "Using the Client Id saved in $ConfigPath" -ForegroundColor DarkGray; return $saved }
        } catch {}
    }
    $t = if ($Tenant) { $Tenant } else { '<tenant>.onmicrosoft.com' }
    Write-Host ""
    Write-Host "No -ClientId, and nothing saved in $ConfigPath." -ForegroundColor Yellow
    Write-Host "Register a PnP app once in the tenant (a Global Admin consents once):" -ForegroundColor Yellow
    Write-Host "  Register-PnPEntraIDAppForInteractiveLogin -ApplicationName 'inciro-M365-Cleanup' -Tenant '$t' -Interactive" -ForegroundColor White
    Write-Host "Then run this again with -ClientId <the id it printed>; it gets saved for next time." -ForegroundColor Yellow
    throw "No Client Id to sign in with."
}
$ClientId = Resolve-ClientId -ClientId $ClientId -ConfigPath $ConfigPath -Tenant $Tenant

Connect-PnPOnline -Url $SiteUrl -Interactive -ClientId $ClientId

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$siteTag   = ($SiteUrl.TrimEnd('/') -split '/')[-1]
$beforeCsv = Join-Path $OutputFolder "OrgLinks_BEFORE_${siteTag}_$stamp.csv"
$afterCsv  = Join-Path $OutputFolder "OrgLinks_REVOKED_${siteTag}_$stamp.csv"

# System libraries to skip - matched on INVARIANT URL names (not localized titles).
# Hidden galleries/catalogs (Master Page Gallery, Theme Gallery, App Packages, MicroFeed, etc.)
# are excluded automatically by the -not $_.Hidden filter below.
$excludedUrlNames = @('SiteAssets','SitePages','Style Library','FormServerTemplates','Teams Wiki Data')

$findings = New-Object System.Collections.Generic.List[object]

$libs = Get-PnPList | Where-Object {
    $_.BaseType -eq 'DocumentLibrary' -and -not $_.Hidden
}

foreach ($lib in $libs) {
    # Language-independent skip: compare the library's URL leaf, not its display title
    $leaf = (Get-PnPProperty -ClientObject $lib -Property RootFolder).ServerRelativeUrl.Split('/')[-1]
    if ($leaf -in $excludedUrlNames) { continue }

    Write-Host "Scanning: $($lib.Title)" -ForegroundColor Cyan
    $items = Get-PnPListItem -List $lib -PageSize 2000
    foreach ($item in $items) {
        $fsType = $item.FileSystemObjectType.ToString()      # File / Folder
        if ($fsType -ne 'File' -and $fsType -ne 'Folder') { continue }

        # Sharing links always break inheritance -> only unique-perm items can hold them
        try { $unique = Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments }
        catch { continue }
        if (-not $unique) { continue }

        $fileRef = $item.FieldValues.FileRef
        $name    = $item.FieldValues.FileLeafRef
        try {
            $links = if ($fsType -eq 'File') { Get-PnPFileSharingLink  -Identity $fileRef -ErrorAction Stop }
                     else                    { Get-PnPFolderSharingLink -Folder   $fileRef -ErrorAction Stop }
        } catch { continue }

        foreach ($l in $links) {
            if ($l.Link.Scope -ne 'Organization') { continue }   # org-wide links only
            $findings.Add([pscustomobject]@{
                Library      = $lib.Title
                ItemType     = $fsType
                Name         = $name
                FileRef      = $fileRef
                LinkId       = $l.Id
                Scope        = $l.Link.Scope
                Type         = $l.Link.Type                        # View / Edit / Review
                WebUrl       = $l.Link.WebUrl
                Roles        = ($l.Roles -join '|')
                Expiration   = $l.ExpirationDateTime
                HasPassword  = $l.HasPassword
                RevokeStatus = 'NotAttempted'
            })
        }
    }
}

# ---- Phase 1: report ----
if ($findings.Count -eq 0) {
    Write-Host "No organization-wide sharing links found." -ForegroundColor Green
    Disconnect-PnPOnline
    return
}

$findings | Export-Csv -Path $beforeCsv -NoTypeInformation -Encoding UTF8BOM
Write-Host ""
Write-Host "Found $($findings.Count) organization-wide link(s). BEFORE report: $beforeCsv" -ForegroundColor Yellow
$findings | Format-Table Library,ItemType,Name,Type,WebUrl -AutoSize

# ---- Phase 2: confirm + revoke all ----
$answer = Read-Host "Revoke ALL $($findings.Count) org-wide link(s)? Type YES to proceed"
if ($answer -ne 'YES') {
    Write-Host "Aborted. No links removed." -ForegroundColor Yellow
    Disconnect-PnPOnline
    return
}

foreach ($f in $findings) {
    if ([string]::IsNullOrWhiteSpace($f.LinkId)) {          # safety: never fall back to "remove ALL links on file"
        $f.RevokeStatus = 'Skipped: empty LinkId'
        Write-Host "Skipped (empty LinkId): $($f.Name)" -ForegroundColor DarkYellow
        continue
    }
    try {
        if ($f.ItemType -eq 'File') {
            Remove-PnPFileSharingLink   -FileUrl $f.FileRef -Identity $f.LinkId -Force -ErrorAction Stop
        } else {
            Remove-PnPFolderSharingLink -Folder  $f.FileRef -Identity $f.LinkId -Force -ErrorAction Stop
        }
        $f.RevokeStatus = 'Removed'
        Write-Host "Removed: $($f.Name)  [$($f.Type)]" -ForegroundColor Green
    } catch {
        $f.RevokeStatus = "Failed: $($_.Exception.Message)"
        Write-Host "Failed:  $($f.Name) -> $($_.Exception.Message)" -ForegroundColor Red
    }
}

$findings | Export-Csv -Path $afterCsv -NoTypeInformation -Encoding UTF8BOM
$removed = ($findings | Where-Object RevokeStatus -eq 'Removed').Count
Write-Host ""
Write-Host "Done. Removed $removed / $($findings.Count). Evidence: $afterCsv" -ForegroundColor Cyan
Disconnect-PnPOnline
