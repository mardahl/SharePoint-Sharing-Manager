#Requires -Version 7.0
<#
    Revoke-OneDrive-NonMemberAccess.ps1   -   multi-OneDrive, CSV-driven

    The rule this enforces: no external sharing, and only named internal members keep access.
    Everything else gets pulled.

    Pulled:
      Links   - anonymous, organization, and specific-people links that include a guest
      Grants  - EEEU ("Everyone except external users"), "Everyone", and guests granted directly
    Left alone:
      Named internal members, the default site groups (Owners/Members/Visitors), system and app
      accounts, and specific-people links shared only with internal members.
    Organization links and EEEU are internal but not *named*, so they go too.

    It deletes the link or grant and nothing else. Files and folders are never removed and
    inheritance is never reset. "Limited Access" rows are skipped on purpose: that is not a real
    grant, it is the traversal stub SharePoint auto-creates so someone can reach a deeper item.
    Delete the real grant on the item itself and SharePoint clears the stub automatically.

    Known issues
      - A specific-people link that includes a guest is removed in full. If that link was also
        shared with an internal member, the member loses that link too (the item and any other
        grants stay).
      - Guest detection on specific-people links depends on the link exposing an external grantee
        (a login containing #ext#). A guest whose identity is not surfaced on the link can go
        unflagged; a follow-up -ReportOnly pass is the check - a clean pass means nothing in
        scope was missed.
      - EEEU or "Everyone" nested inside a site permission group (added to Members/Visitors, for
        example) is group membership rather than a direct grant, and is not removed here.

    This cleans up what is already there. It does not stop new sharing. To lock that down after:
      Set-SPOSite   -Identity <odUrl> -SharingCapability Disabled     # one OneDrive
      Set-SPOTenant -OneDriveSharingCapability Disabled               # whole tenant

    ---- One-time setup per tenant ----------------------------------------------------------
    PnP needs its own Entra app to sign in - the shared PnP app was retired on 9 Sep 2024. Run
    this once against the tenant (any user can create the app; a Global Admin consents to it):

      Register-PnPEntraIDAppForInteractiveLogin -ApplicationName "inciro-M365-Cleanup" -Tenant "<tenant>.onmicrosoft.com" -Interactive

    That makes a single-tenant app for interactive (delegated) sign-in and prints a Client Id at
    the end. Delegated is the whole point: the app can only do what the admin signing in could do
    anyway, and it leaves nothing standing behind - no app-only key sitting around. Default
    scopes are delegated AllSites.FullControl plus Graph Group/User/TermStore read-write. If you
    want least privilege, add -SharePointDelegatePermissions / -GraphDelegatePermissions to trim
    it and then test one link removal to be sure it still works.

    Pass the Client Id once with -ClientId and it gets written to the config file below; after
    that you can leave the parameter off. Both cleanup scripts read the same file, so it is a
    one-time thing per machine.

    Config file (shared with Revoke-OrgWideSharingLinks.ps1):
      %USERPROFILE%\.inciro-m365-cleanup.json    ->    { "ClientId": "<app-guid>" }

    ---- Running it -------------------------------------------------------------------------
    Input, pick one:
      -SiteUrl <odUrl>     one OneDrive
      -CsvPath <file.csv>  many; needs a column of URLs (header 'Url', or set -UrlColumn)

    Modes:
      -ReportOnly   scan and report, touch nothing
      (default)     per site: scan, show what turned up, type YES to revoke that site
      -AutoRemove   per site: scan and revoke with no prompt - use this after a -ReportOnly pass

    Needs PowerShell 7+ and PnP.PowerShell (installed for the current user if it is missing).
    You have to be Site Collection Admin on each OneDrive; being SharePoint Admin is not enough
    to read someone's OneDrive:
      Set-SPOUser -Site <odUrl> -LoginName you@domain -IsSiteCollectionAdmin $true
    A site that will not connect or scan is logged and skipped, and the run carries on.

    Examples (once the Client Id is saved, you can drop -ClientId):
      ./Revoke-OneDrive-NonMemberAccess.ps1 -SiteUrl "https://contoso-my.sharepoint.com/personal/jane_contoso_com" -ClientId "<app-guid>"
      ./Revoke-OneDrive-NonMemberAccess.ps1 -CsvPath ".\onedrives.csv" -ReportOnly
      ./Revoke-OneDrive-NonMemberAccess.ps1 -CsvPath ".\onedrives.csv" -AutoRemove
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName='Single', Mandatory)][string]$SiteUrl,
    [Parameter(ParameterSetName='Csv',    Mandatory)][string]$CsvPath,
    [string]$ClientId,
    [string]$Tenant,
    [string]$ConfigPath   = (Join-Path $HOME '.inciro-m365-cleanup.json'),
    [string]$UrlColumn    = 'Url',
    [string]$OutputFolder = (Get-Location).Path,
    [switch]$ReportOnly,
    [switch]$AutoRemove
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
        # Save it so the parameter can be left off next time (Revoke-OrgWideSharingLinks.ps1 reads this same file).
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

$stamp            = Get-Date -Format 'yyyyMMdd-HHmmss'
$displayCols      = 'Site','Location','Category','Name','Access','Principal','Path','RevokeStatus'
$excludedUrlNames = @('SiteAssets','SitePages','Style Library','FormServerTemplates','Teams Wiki Data')

# ---- Build the list of OneDrive URLs ----
if ($PSCmdlet.ParameterSetName -eq 'Csv') {
    if (-not (Test-Path -LiteralPath $CsvPath)) { throw "CSV not found: $CsvPath" }
    $rows = Import-Csv -LiteralPath $CsvPath
    $col  = $UrlColumn
    if (-not ($rows[0].PSObject.Properties.Name -contains $col)) { $col = $rows[0].PSObject.Properties.Name[0] }
    $urls = @($rows | ForEach-Object { $_.$col } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
} else {
    $urls = @($SiteUrl)
}
if ($urls.Count -eq 0) { throw "No OneDrive URLs to process." }

# ============================ HELPERS ============================

# Classify a role-assignment principal; return a category to remove, or $null to KEEP.
function Classify-Principal([string]$login, [string]$title) {
    if ([string]::IsNullOrWhiteSpace($login) -and [string]::IsNullOrWhiteSpace($title)) { return $null }
    if ($title -like 'SharingLinks.*' -or $login -like '*SharingLinks.*') { return $null }   # handled via link cmdlets
    if ($login -like 'c:0-.f|rolemanager|spo-grid-all-users/*')           { return 'EEEU grant' }
    if ($login -eq   'c:0(.s|true')                                       { return 'Everyone grant' }
    if ($login -like '*#ext#*')                                           { return 'Guest grant' }
    return $null   # internal member, default group, system/app -> KEEP
}

# Guest/external grantees on a "users" (specific people) sharing link.
function Get-GuestGrantees($link) {
    $out = @()
    foreach ($g in @($link.GrantedToIdentitiesV2)) {
        if (-not $g) { continue }
        $ln = $g.SiteUser.LoginName
        $em = $g.User.Email
        if     ($ln -and $ln -like '*#ext#*') { $out += ($em ? $em : $ln) }
        elseif ($em -and $em -match 'guest#') { $out += $em }
    }
    return $out
}

# Read HasUniqueRoleAssignments for a securable via REST (bool).
function Get-RestUnique([string]$Url) {
    try { $r = Invoke-PnPSPRestMethod -Url $Url -Method Get; return [bool]$r.HasUniqueRoleAssignments } catch { return $false }
}

# Read a roleassignments collection via REST and add bad direct grants to $Bag.
function Add-GrantsRest($RaUrl, $Site, $Location, $Name, $Path, $ListId, $ItemId, $Bag) {
    try { $resp = Invoke-PnPSPRestMethod -Url $RaUrl -Method Get } catch { return }
    foreach ($ra in @($resp.value)) {
        $cat = Classify-Principal $ra.Member.LoginName $ra.Member.Title
        if (-not $cat) { continue }
        # Keep only REAL grants. "Limited Access" (RoleType.Guest = 1) is system-managed
        # scaffolding that points to a real grant deeper down - never delete it directly;
        # removing the real leaf grant makes SharePoint clean the scaffolding automatically.
        $realRoles = @(@($ra.RoleDefinitionBindings) | Where-Object { [int]$_.RoleTypeKind -ne 1 })
        if ($realRoles.Count -eq 0) { continue }
        $roles = ($realRoles | ForEach-Object { $_.Name }) -join ';'
        $Bag.Add([pscustomobject]@{
            Site=$Site; Location=$Location; Name=$Name; Category=$cat; Access=$roles
            Principal=$ra.Member.Title; Path=$Path; RemovalKind='DirectGrant'
            LinkId=$null; ListId=$ListId; ItemId=$ItemId; PrincipalId=$ra.PrincipalId; RevokeStatus='NotAttempted'
        })
    }
}

# Scan the currently-connected OneDrive; return a List of findings.
function Scan-Site([string]$Site, [string[]]$ExcludedUrlNames) {
    $bag = New-Object System.Collections.Generic.List[object]
    $web = Get-PnPWeb
    $base = $web.Url.TrimEnd('/')
    $raSelect = "`$expand=Member,RoleDefinitionBindings&`$select=PrincipalId,Member/LoginName,Member/Title,RoleDefinitionBindings/Name,RoleDefinitionBindings/RoleTypeKind"

    # Web-root direct grants
    if (Get-RestUnique "$base/_api/web?`$select=HasUniqueRoleAssignments") {
        Add-GrantsRest "$base/_api/web/roleassignments?$raSelect" $Site 'Web' $web.Title $base $null $null $bag
    }

    $libs = Get-PnPList | Where-Object { $_.BaseType -eq 'DocumentLibrary' -and -not $_.Hidden }
    foreach ($lib in $libs) {
        $rootUrl = (Get-PnPProperty -ClientObject $lib -Property RootFolder).ServerRelativeUrl
        if ($rootUrl.Split('/')[-1] -in $ExcludedUrlNames) { continue }
        $listId = $lib.Id.ToString()
        $total  = 0; try { $total = [int](Get-PnPProperty -ClientObject $lib -Property ItemCount) } catch {}
        Write-Host "  Library '$($lib.Title)' (~$total items)" -ForegroundColor Cyan

        # Library-root direct grants
        if (Get-RestUnique "$base/_api/web/lists(guid'$listId')?`$select=HasUniqueRoleAssignments") {
            Add-GrantsRest "$base/_api/web/lists(guid'$listId')/roleassignments?$raSelect" $Site 'Library' $lib.Title $rootUrl $listId $null $bag
        }

        # Enumerate items by indexed Id range, collecting only unique-permission items
        $unique  = New-Object System.Collections.Generic.List[object]
        $lastId  = 0
        $scanned = 0
        do {
            $u = "$base/_api/web/lists(guid'$listId')/items?`$select=Id,FileRef,FileLeafRef,FSObjType,HasUniqueRoleAssignments&`$filter=Id%20gt%20$lastId&`$orderby=Id&`$top=5000"
            try { $resp = Invoke-PnPSPRestMethod -Url $u -Method Get } catch { Write-Host "    enumeration error: $($_.Exception.Message)" -ForegroundColor Red; break }
            $rows = @($resp.value)
            foreach ($r in $rows) {
                $scanned++
                if ($r.HasUniqueRoleAssignments) { $unique.Add($r) }
                if ($r.Id -gt $lastId) { $lastId = $r.Id }
            }
            $pct = if ($total -gt 0) { [math]::Min(100, [int]($scanned / $total * 100)) } else { 0 }
            Write-Progress -Id 2 -ParentId 1 -Activity "Enumerating '$($lib.Title)'" -Status "$scanned / ~$total scanned - $($unique.Count) with unique permissions" -PercentComplete $pct
        } while ($rows.Count -eq 5000)
        Write-Host "    $scanned scanned, $($unique.Count) with unique permissions - checking those..." -ForegroundColor DarkCyan

        # Check each unique-permission item: sharing links + direct grants
        $idx = 0
        foreach ($it in $unique) {
            $idx++
            if ($idx % 25 -eq 0 -or $idx -eq $unique.Count) {
                Write-Progress -Id 2 -ParentId 1 -Activity "Checking shared items in '$($lib.Title)'" -Status "$idx / $($unique.Count)" -PercentComplete ([int]($idx / [math]::Max(1,$unique.Count) * 100))
            }
            $isFolder = ($it.FSObjType -eq 1)
            $loc      = if ($isFolder) { 'Folder' } else { 'File' }
            $fileRef  = $it.FileRef
            $name     = $it.FileLeafRef

            # 1) Sharing links (Graph)
            try {
                $links = if ($isFolder) { Get-PnPFolderSharingLink -Folder $fileRef -ErrorAction Stop }
                         else           { Get-PnPFileSharingLink  -Identity $fileRef -ErrorAction Stop }
            } catch { $links = @() }
            foreach ($l in @($links)) {
                if (-not $l.Link) { continue }
                $cat = $null; $principal = ''
                switch (($l.Link.Scope).ToString().ToLower()) {
                    'anonymous'    { $cat = 'Anonymous link';    $principal = 'Anyone with the link' }
                    'organization' { $cat = 'Organization link'; $principal = 'People in your organization' }
                    'users'        { $g = Get-GuestGrantees $l; if (@($g).Count -gt 0) { $cat = 'Guest-specific link'; $principal = (@($g) -join ';') } }
                }
                if (-not $cat) { continue }
                $bag.Add([pscustomobject]@{
                    Site=$Site; Location=$loc; Name=$name; Category=$cat; Access=$l.Link.Type
                    Principal=$principal; Path=$fileRef; RemovalKind='Link'
                    LinkId=$l.Id; ListId=$listId; ItemId=$it.Id; PrincipalId=$null; RevokeStatus='NotAttempted'
                })
            }

            # 2) Direct grants on the item (EEEU / Everyone / guest granted directly, not via a link)
            Add-GrantsRest "$base/_api/web/lists(guid'$listId')/items($($it.Id))/roleassignments?$raSelect" $Site $loc $name $fileRef $listId $it.Id $bag
        }
        Write-Progress -Id 2 -Completed -Activity "done"
    }
    return $bag
}

# Remove all findings for the currently-connected site; returns count removed.
function Remove-Findings($Findings) {
    $removed = 0; $i = 0
    # Remove leaf grants first (File/Folder), then Library, then Web, and links before direct
    # grants. This means the real grant is gone before we ever touch a parent scope, so a single
    # claim principal (e.g. EEEU) isn't de-provisioned out from under later removals.
    $depth = @{ 'File'=0; 'Folder'=0; 'Library'=1; 'Web'=2 }
    $ordered = $Findings | Sort-Object `
        @{ Expression = { if ($_.RemovalKind -eq 'Link') { 0 } else { 1 } } }, `
        @{ Expression = { $depth[$_.Location] } }
    foreach ($f in $ordered) {
        $i++
        Write-Progress -Id 2 -ParentId 1 -Activity "Revoking" -Status "$i / $($Findings.Count): $($f.Name)" -PercentComplete ([int]($i / [math]::Max(1,$Findings.Count) * 100))
        try {
            if ($f.RemovalKind -eq 'Link') {
                if ([string]::IsNullOrWhiteSpace($f.LinkId)) { $f.RevokeStatus = 'Skipped: empty LinkId'; continue }
                if ($f.Location -eq 'File') { Remove-PnPFileSharingLink   -FileUrl $f.Path -Identity $f.LinkId -Force -ErrorAction Stop }
                else                        { Remove-PnPFolderSharingLink -Folder  $f.Path -Identity $f.LinkId -Force -ErrorAction Stop }
            }
            else {  # DirectGrant
                if (-not $f.PrincipalId) { $f.RevokeStatus = 'Skipped: no PrincipalId'; continue }
                $sec = switch ($f.Location) {
                    'Web'     { Get-PnPWeb }
                    'Library' { Get-PnPList -Identity $f.ListId }
                    default   { Get-PnPListItem -List $f.ListId -Id $f.ItemId }   # File / Folder
                }
                $sec.RoleAssignments.GetByPrincipalId([int]$f.PrincipalId).DeleteObject()
                Invoke-PnPQuery
            }
            $f.RevokeStatus = 'Removed'; $removed++
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'find the principal' -or $msg -match 'does not exist' -or $msg -match 'Cannot find') {
                # Principal already gone (e.g. a single claim like EEEU removed at its leaf grant
                # cascades away site-wide). End state is what we wanted, so count it as success.
                $f.RevokeStatus = 'AlreadyRevoked'; $removed++
            } else {
                $f.RevokeStatus = "Failed: $msg"
            }
        }
    }
    Write-Progress -Id 2 -Completed -Activity "done"
    return $removed
}

# ============================== RUN ==============================
$summary = New-Object System.Collections.Generic.List[object]
$siteNo  = 0

foreach ($url in $urls) {
    $siteNo++
    $siteTag = ($url.TrimEnd('/') -split '/')[-1]
    Write-Progress -Id 1 -Activity "OneDrive cleanup" -Status "Site $siteNo of $($urls.Count): $siteTag" -PercentComplete ([int](($siteNo-1) / $urls.Count * 100))
    Write-Host "`n=== [$siteNo/$($urls.Count)] $url ===" -ForegroundColor White

    try { Connect-PnPOnline -Url $url -Interactive -ClientId $ClientId -ErrorAction Stop }
    catch {
        Write-Host "  Connect failed (need Site Collection Admin?): $($_.Exception.Message)" -ForegroundColor Red
        $summary.Add([pscustomobject]@{ Site=$url; Findings=0; Removed=0; Status="ConnectFailed" }); continue
    }

    try { $findings = Scan-Site -Site $url -ExcludedUrlNames $excludedUrlNames }
    catch {
        Write-Host "  Scan failed: $($_.Exception.Message)" -ForegroundColor Red
        $summary.Add([pscustomobject]@{ Site=$url; Findings=0; Removed=0; Status="ScanFailed" }); continue
    }

    if ($findings.Count -eq 0) {
        Write-Host "  Clean - no non-member links or grants found." -ForegroundColor Green
        $summary.Add([pscustomobject]@{ Site=$url; Findings=0; Removed=0; Status='Clean' }); continue
    }

    $beforeCsv = Join-Path $OutputFolder "ODNonMember_BEFORE_${siteTag}_$stamp.csv"
    $findings | Select-Object $displayCols | Export-Csv -Path $beforeCsv -NoTypeInformation -Encoding UTF8BOM
    Write-Host "  Found $($findings.Count) non-member item(s). Report: $beforeCsv" -ForegroundColor Yellow
    $findings | Group-Object Category | Sort-Object Name | ForEach-Object { Write-Host ("    {0,-22} {1}" -f $_.Name, $_.Count) -ForegroundColor Yellow }

    if ($ReportOnly) { $summary.Add([pscustomobject]@{ Site=$url; Findings=$findings.Count; Removed=0; Status='ReportedOnly' }); continue }

    $proceed = $AutoRemove.IsPresent
    if (-not $proceed) {
        $findings | Select-Object Location, Category, Name, Principal | Format-Table -AutoSize
        $proceed = ((Read-Host "  Revoke ALL $($findings.Count) on '$siteTag'? Type YES to proceed") -eq 'YES')
    }
    if (-not $proceed) {
        Write-Host "  Skipped - nothing removed." -ForegroundColor Yellow
        $summary.Add([pscustomobject]@{ Site=$url; Findings=$findings.Count; Removed=0; Status='SkippedByUser' }); continue
    }

    $removed  = Remove-Findings -Findings $findings
    $afterCsv = Join-Path $OutputFolder "ODNonMember_REVOKED_${siteTag}_$stamp.csv"
    $findings | Select-Object $displayCols | Export-Csv -Path $afterCsv -NoTypeInformation -Encoding UTF8BOM
    Write-Host "  Removed $removed / $($findings.Count). Evidence: $afterCsv" -ForegroundColor Cyan
    $summary.Add([pscustomobject]@{ Site=$url; Findings=$findings.Count; Removed=$removed; Status='Processed' })
}

Write-Progress -Id 1 -Completed -Activity "OneDrive cleanup"
try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}

Write-Host "`n===== RUN SUMMARY =====" -ForegroundColor White
$summary | Format-Table Site, Findings, Removed, Status -AutoSize
$runCsv = Join-Path $OutputFolder "ODNonMember_RUNSUMMARY_$stamp.csv"
$summary | Export-Csv -Path $runCsv -NoTypeInformation -Encoding UTF8BOM
Write-Host "Run summary: $runCsv" -ForegroundColor Cyan
