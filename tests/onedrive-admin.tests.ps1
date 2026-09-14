function New-SsmFakeToken {
    # Builds a syntactically valid (unsigned) JWT string carrying only the
    # claims needed to exercise Get-SsmConnectionTenantId's payload decode.
    param([hashtable]$Claims)
    $json = $Claims | ConvertTo-Json -Compress
    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    $b64url = $b64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "header.$b64url.signature"
}

# ---------------------------------------------------------------------------
# Resolve-SsmDirectoryUser
# ---------------------------------------------------------------------------

Invoke-SsmTest 'Admin input rejects aliases returned as another canonical UPN' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ id = '22222222-2222-2222-2222-222222222222'
           userPrincipalName = 'canonical@contoso.com'; displayName = 'Admin' }
    }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn 'alias@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Admin input resolves a mixed-case, whitespace-padded UPN to the canonical identity' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ id = '22222222-2222-2222-2222-222222222222'
           userPrincipalName = 'admin@contoso.com'; displayName = 'Admin' }
    }
    $r = Resolve-SsmDirectoryUser -Upn ' ADMIN@contoso.com ' `
        -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{}
    Assert-Equal '22222222-2222-2222-2222-222222222222' $r.Id
    Assert-Equal 'admin@contoso.com' $r.Upn
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser rejects empty input before any Graph call' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod { param($Method, $Url, $Connection, $ErrorAction) throw 'must not be called' }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn '   ' -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser rejects a list of UPNs before any Graph call' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod { param($Method, $Url, $Connection, $ErrorAction) throw 'must not be called' }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn 'a@contoso.com,b@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser rejects a wildcard expression before any Graph call' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod { param($Method, $Url, $Connection, $ErrorAction) throw 'must not be called' }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn '*@contoso.com' -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser rejects a claims-encoded login before any Graph call' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod { param($Method, $Url, $Connection, $ErrorAction) throw 'must not be called' }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn 'i:0#.f|membership|admin@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser encodes a leading dollar and an embedded hash without broadening the query' {
    $script:capturedUrl = $null
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        $script:capturedUrl = $Url
        @{ id = '22222222-2222-2222-2222-222222222222'
           userPrincipalName = '$weird#user@contoso.com'; displayName = 'Weird' }
    }
    try {
        $r = Resolve-SsmDirectoryUser -Upn '$weird#user@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{}
        Assert-Equal '22222222-2222-2222-2222-222222222222' $r.Id
        Assert-Equal $true ($script:capturedUrl -like "users('*")
        Assert-Equal $false ($script:capturedUrl -match '(?<!%23)#(?!%)' )
    } finally { Remove-Variable -Scope Script -Name capturedUrl -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser escapes an embedded apostrophe rather than breaking out of the OData key' {
    $script:capturedUrl = $null
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        $script:capturedUrl = $Url
        @{ id = '22222222-2222-2222-2222-222222222222'
           userPrincipalName = "o'brien@contoso.com"; displayName = "O'Brien" }
    }
    try {
        $r = Resolve-SsmDirectoryUser -Upn "o'brien@contoso.com" `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{}
        Assert-Equal '22222222-2222-2222-2222-222222222222' $r.Id
        Assert-Equal $true ($script:capturedUrl -like "*%27%27*")
    } finally { Remove-Variable -Scope Script -Name capturedUrl -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser fails closed on a missing directory object id' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ userPrincipalName = 'admin@contoso.com'; displayName = 'Admin' }
    }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn 'admin@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser fails closed on a malformed directory object id' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ id = 'not-a-guid'; userPrincipalName = 'admin@contoso.com'; displayName = 'Admin' }
    }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn 'admin@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser stops on a wrong-tenant connection before any Graph lookup' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'99999999-9999-9999-9999-999999999999' }
    function Invoke-PnPGraphMethod { param($Method, $Url, $Connection, $ErrorAction) throw 'must not be called' }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn 'admin@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser surfaces a directory permission denial as a validation failure' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        throw 'Forbidden (403): Insufficient privileges'
    }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn 'admin@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser accepts a legitimate guest #EXT# UPN (not a claims login)' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ id = '22222222-2222-2222-2222-222222222222'
           userPrincipalName = 'guest_contoso.com#EXT#@fabrikam.onmicrosoft.com'; displayName = 'Guest' }
    }
    $r = Resolve-SsmDirectoryUser -Upn 'guest_contoso.com#EXT#@fabrikam.onmicrosoft.com' `
        -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{}
    Assert-Equal '22222222-2222-2222-2222-222222222222' $r.Id
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser rejects a control character even though Trim() would silently absorb it as edge whitespace' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod { param($Method, $Url, $Connection, $ErrorAction) throw 'must not be called' }
    # U+0085 (NEL) is classified as Unicode whitespace by .NET's Trim() but is
    # a C1 control character - it must not be silently trimmed away and
    # accepted as ordinary surrounding whitespace.
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn "$([char]0x0085)admin@contoso.com" `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Resolve-SsmDirectoryUser accepts and trims ordinary leading/trailing ASCII whitespace' {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ id = '22222222-2222-2222-2222-222222222222'
           userPrincipalName = 'admin@contoso.com'; displayName = 'Admin' }
    }
    $r = Resolve-SsmDirectoryUser -Upn " `tadmin@contoso.com`t " `
        -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{}
    Assert-Equal '22222222-2222-2222-2222-222222222222' $r.Id
}

Invoke-SsmTest 'DIAGNOSTICS: Resolve-SsmDirectoryUser logs the original ErrorRecord (Graph error body, not just the wrapped message)' {
    # Regression: the directory-lookup catch wraps the exception into a
    # short "throw " string, discarding the rich Graph error body
    # (ErrorDetails.Message) entirely. This loads the real logger (not the
    # test-runner's no-op stub) and asserts the full original error body
    # reached the log before the short wrapped message was thrown.
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/05-logging.ps1')
    $script:LogBuffer.Clear()
    $prevLogFile = Enter-SsmTestLogFile
    try {
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        $err = New-Object System.Management.Automation.ErrorRecord(
            [Exception]::new('Graph request failed'), 'GraphError',
            [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $err.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
            '{"error":{"code":"AccessDenied","message":"resolve-diagnostics-json-body-probe"}}')
        throw $err
    }
    $caught = $false
    try {
        Resolve-SsmDirectoryUser -Upn 'admin@contoso.com' `
            -TenantId '11111111-1111-1111-1111-111111111111' -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
    $errLines = @($script:LogBuffer | Where-Object { $_.Level -eq 'ERROR' })
    if (-not ($errLines | Where-Object { $_.Message -like '*resolve-diagnostics-json-body-probe*' })) {
        throw "original Graph error body was not logged; buffer: $(($errLines | ForEach-Object { $_.Message }) -join ' | ')"
    }
    } finally {
        Exit-SsmTestLogFile -Prev $prevLogFile
    }
}

# ---------------------------------------------------------------------------
# Get-SsmConnectionTenantId
# ---------------------------------------------------------------------------

Invoke-SsmTest 'Get-SsmConnectionTenantId decodes tid from the access token payload' {
    function Get-PnPAccessToken {
        param($Connection, $ErrorAction)
        New-SsmFakeToken -Claims @{ tid = '11111111-1111-1111-1111-111111111111'; aud = 'https://graph.microsoft.com' }
    }
    $tid = Get-SsmConnectionTenantId -Connection @{}
    Assert-Equal '11111111-1111-1111-1111-111111111111' $tid
}

Invoke-SsmTest 'Get-SsmConnectionTenantId fails closed on a zero-GUID tenant claim' {
    function Get-PnPAccessToken {
        param($Connection, $ErrorAction)
        New-SsmFakeToken -Claims @{ tid = '00000000-0000-0000-0000-000000000000' }
    }
    $caught = $false
    try { Get-SsmConnectionTenantId -Connection @{} | Out-Null } catch { $caught = $true }
    Assert-Equal $true $caught
}

# ---------------------------------------------------------------------------
# Get-SsmOneDriveAdminDecision
# ---------------------------------------------------------------------------

function New-SsmTestSnapshot {
    param([hashtable]$Overrides = @{})
    $base = @{
        TenantId = [guid]'11111111-1111-1111-1111-111111111111'
        Url = 'https://contoso-my.sharepoint.com/personal/user'
        SiteId = [guid]'44444444-4444-4444-4444-444444444444'
        IsPersonalSite = $true; Unlocked = $true
        OwnerId = [guid]'22222222-2222-2222-2222-222222222222'; OwnerUpn = 'user@contoso.com'
        PrimaryAdminId = [guid]'33333333-3333-3333-3333-333333333333'; PrimaryAdminUpn = 'primary@contoso.com'
        AdminPresent = $false; AdminUserId = $null; AdminLogin = ''
    }
    foreach ($k in $Overrides.Keys) { $base[$k] = $Overrides[$k] }
    return $base
}

Invoke-SsmTest 'Actual owner removal is blocked before absent-admin no-op' {
    $id = [guid]'22222222-2222-2222-2222-222222222222'
    $tenant = [guid]'11111111-1111-1111-1111-111111111111'
    $identity = @{ Id = $id; TenantId = $tenant }
    $snapshot = @{
        TenantId = $tenant; Url = 'https://contoso-my.sharepoint.com/personal/user'
        SiteId = 'known-site'; IsPersonalSite = $true; Unlocked = $true
        OwnerId = $id; OwnerUpn = 'user@contoso.com'
        PrimaryAdminId = [guid]'33333333-3333-3333-3333-333333333333'
        PrimaryAdminUpn = 'primary@contoso.com'
        AdminPresent = $false; AdminUserId = $null; AdminLogin = ''
    }
    Assert-Equal 'OwnerProtected' (Get-SsmOneDriveAdminDecision `
        -Action Remove -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'Primary administrator removal is blocked even when the account is not the actual owner' {
    $identity = @{ Id = [guid]'33333333-3333-3333-3333-333333333333'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ AdminPresent = $true; AdminUserId = 7; AdminLogin = 'i:0#.f|membership|primary@contoso.com' }
    Assert-Equal 'PrimaryProtected' (Get-SsmOneDriveAdminDecision -Action Remove -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'A wrong-tenant identity is blocked regardless of owner/admin state' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'99999999-9999-9999-9999-999999999999' }
    $snapshot = New-SsmTestSnapshot
    Assert-Equal 'Blocked' (Get-SsmOneDriveAdminDecision -Action Add -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'A non-personal target is blocked' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ IsPersonalSite = $false }
    Assert-Equal 'Blocked' (Get-SsmOneDriveAdminDecision -Action Add -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'A locked target is blocked' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ Unlocked = $false }
    Assert-Equal 'Blocked' (Get-SsmOneDriveAdminDecision -Action Add -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'A missing actual owner is blocked' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ OwnerId = $null }
    Assert-Equal 'Blocked' (Get-SsmOneDriveAdminDecision -Action Remove -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'A missing primary administrator is blocked' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ PrimaryAdminId = $null }
    Assert-Equal 'Blocked' (Get-SsmOneDriveAdminDecision -Action Remove -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'Present membership that cannot be bound to a SharePoint principal is blocked, not removed' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ AdminPresent = $true; AdminUserId = $null; AdminLogin = '' }
    Assert-Equal 'Blocked' (Get-SsmOneDriveAdminDecision -Action Remove -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'Present membership whose bound AdminUserId does not equal the requested identity is blocked, never removed' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ AdminPresent = $true; AdminUserId = [guid]'99999999-9999-9999-9999-999999999999'; AdminLogin = 'i:0#.f|membership|other@contoso.com' }
    Assert-Equal 'Blocked' (Get-SsmOneDriveAdminDecision -Action Remove -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'Unresolved membership (AdminPresent unknown/null) is blocked, never treated as absent' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ AdminPresent = $null }
    Assert-Equal 'Blocked' (Get-SsmOneDriveAdminDecision -Action Remove -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'Adding an already-present administrator is a no-op' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ AdminPresent = $true; AdminUserId = $identity.Id; AdminLogin = 'i:0#.f|membership|other@contoso.com' }
    Assert-Equal 'NoOp' (Get-SsmOneDriveAdminDecision -Action Add -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'Removing an absent secondary administrator is a no-op' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ AdminPresent = $false }
    Assert-Equal 'NoOp' (Get-SsmOneDriveAdminDecision -Action Remove -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'Add is eligible for a non-owner, non-primary, absent candidate on a healthy target' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ AdminPresent = $false }
    Assert-Equal 'Eligible' (Get-SsmOneDriveAdminDecision -Action Add -Identity $identity -Snapshot $snapshot)
}

Invoke-SsmTest 'Remove is eligible for a non-owner, non-primary, present candidate on a healthy target' {
    $identity = @{ Id = [guid]'55555555-5555-5555-5555-555555555555'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    $snapshot = New-SsmTestSnapshot -Overrides @{ AdminPresent = $true; AdminUserId = $identity.Id; AdminLogin = 'i:0#.f|membership|other@contoso.com' }
    Assert-Equal 'Eligible' (Get-SsmOneDriveAdminDecision -Action Remove -Identity $identity -Snapshot $snapshot)
}

# ---------------------------------------------------------------------------
# Get-SsmOneDriveAdminState
# ---------------------------------------------------------------------------

Invoke-SsmTest 'Get-SsmOneDriveAdminState binds the owner-bearing drive via paginated List Drives and never calls a mutation cmdlet' {
    $identity = @{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Upn = 'user@contoso.com'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Connect-SsmAdmin { $true }
    function Get-PnPConnection { @{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Get-PnPTenantSite {
        param($Identity, [switch]$Detailed, $Connection, $ErrorAction)
        @{ Template = 'SPSPERS#10'; LockState = 'Unlock'; Owner = 'primary@contoso.com' }
    }
    function Get-PnPSite { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'44444444-4444-4444-4444-444444444444' } }
    function Get-PnPWeb { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'66666666-6666-6666-6666-666666666666' } }
    $script:pageCalls = 0
    $script:capturedGraphUrl = $null
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        $script:pageCalls++
        if (-not $script:capturedGraphUrl) { $script:capturedGraphUrl = $Url }
        if ($Url -like '*page2*') {
            return @{
                value = @(
                    @{ id = 'd2'; driveType = 'business'
                       owner = @{ user = @{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'user@contoso.com' } }
                       sharepointIds = @{ siteId = '44444444-4444-4444-4444-444444444444'; webId = '66666666-6666-6666-6666-666666666666' } }
                )
            }
        }
        return @{
            value = @(
                @{ id = 'd1'; driveType = 'business'
                   owner = @{ user = @{ id = '99999999-9999-9999-9999-999999999999'; userPrincipalName = 'unrelated@contoso.com' } }
                   sharepointIds = @{ siteId = '55555555-5555-5555-5555-555555555555'; webId = '66666666-6666-6666-6666-666666666666' } }
            )
            '@odata.nextLink' = 'sites/contoso-my.sharepoint.com,44444444-4444-4444-4444-444444444444,66666666-6666-6666-6666-666666666666/drives?page2'
        }
    }
    $script:capturedIncludes = $null
    function Get-PnPSiteCollectionAdmin {
        param($Connection, $Includes, $ErrorAction)
        $script:capturedIncludes = $Includes
        @(
            @{ Id = 1; LoginName = 'i:0#.f|membership|primary@contoso.com'; UserPrincipalName = 'primary@contoso.com'; Email = 'primary@contoso.com'; AadObjectId = @{ NameId = '33333333-3333-3333-3333-333333333333' } }
        )
    }
    function Add-PnPSiteCollectionAdmin { throw 'must not be called during preflight' }
    function Remove-PnPSiteCollectionAdmin { throw 'must not be called during preflight' }
    try {
        $s = Get-SsmOneDriveAdminState -Url 'https://contoso-my.sharepoint.com/personal/user' -Identity $identity -Connection @{}
        Assert-Equal '44444444-4444-4444-4444-444444444444' $s.SiteId
        Assert-Equal $true $s.IsPersonalSite
        Assert-Equal $true $s.Unlocked
        Assert-Equal '22222222-2222-2222-2222-222222222222' $s.OwnerId
        Assert-Equal 'user@contoso.com' $s.OwnerUpn
        Assert-Equal '33333333-3333-3333-3333-333333333333' $s.PrimaryAdminId
        Assert-Equal $false $s.AdminPresent
        Assert-Equal $true ($script:pageCalls -eq 2)
        Assert-Equal $true ($script:capturedGraphUrl -like 'sites/contoso-my.sharepoint.com,44444444-4444-4444-4444-444444444444,66666666-6666-6666-6666-666666666666/drives*')
        # AadObjectId must be requested as a bare top-level scalar - PnP.PowerShell's
        # CSOM query translator (ClientContext.LoadQuery) throws
        # InvalidQueryExpressionException ("The query expression is not
        # supported.") for a dotted nested path through a ClientValueObject
        # such as AadObjectId.NameId/.NameIdIssuer, even though the cmdlet's
        # -Includes ValidateSet lists those dotted names as accepted strings
        # (see tests/onedrive-admin-csom.ps1 for the live CSOM-translator
        # proof). Requesting the parent AadObjectId scalar alone already
        # hydrates all of its own fields (NameId/NameIdIssuer/TypeId).
        Assert-Equal $true (@($script:capturedIncludes) -contains 'AadObjectId')
        Assert-Equal $false (@($script:capturedIncludes) -contains 'AadObjectId.NameId')
        Assert-Equal $false (@($script:capturedIncludes) -contains 'AadObjectId.NameIdIssuer')
        Assert-Equal $true (@($script:capturedIncludes) -contains 'UserPrincipalName')
    } finally {
        Remove-Variable -Scope Script -Name pageCalls, capturedGraphUrl, capturedIncludes -ErrorAction SilentlyContinue
    }
}

Invoke-SsmTest 'Get-SsmOneDriveAdminState fails closed when zero drives bind to the resolved site' {
    $identity = @{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Upn = 'user@contoso.com'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Connect-SsmAdmin { $true }
    function Get-PnPConnection { @{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Get-PnPTenantSite { param($Identity, [switch]$Detailed, $Connection, $ErrorAction) @{ Template = 'SPSPERS#10'; LockState = 'Unlock'; Owner = 'primary@contoso.com' } }
    function Get-PnPSite { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'44444444-4444-4444-4444-444444444444' } }
    function Get-PnPWeb { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'66666666-6666-6666-6666-666666666666' } }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ value = @(@{ id = 'd1'; driveType = 'business'
                         owner = @{ user = @{ id = '99999999-9999-9999-9999-999999999999'; userPrincipalName = 'unrelated@contoso.com' } }
                         sharepointIds = @{ siteId = '55555555-5555-5555-5555-555555555555'; webId = '66666666-6666-6666-6666-666666666666' } }) }
    }
    $caught = $false
    try {
        Get-SsmOneDriveAdminState -Url 'https://contoso-my.sharepoint.com/personal/user' -Identity $identity -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Get-SsmOneDriveAdminState fails closed when a drive matches siteId but not webId' {
    $identity = @{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Upn = 'user@contoso.com'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Connect-SsmAdmin { $true }
    function Get-PnPConnection { @{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Get-PnPTenantSite { param($Identity, [switch]$Detailed, $Connection, $ErrorAction) @{ Template = 'SPSPERS#10'; LockState = 'Unlock'; Owner = 'primary@contoso.com' } }
    function Get-PnPSite { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'44444444-4444-4444-4444-444444444444' } }
    function Get-PnPWeb { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'66666666-6666-6666-6666-666666666666' } }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        # Matches the resolved site GUID but a different web GUID - must not
        # be treated as bound to this exact personal site/web.
        @{ value = @(@{ id = 'd1'; driveType = 'business'
                         owner = @{ user = @{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'user@contoso.com' } }
                         sharepointIds = @{ siteId = '44444444-4444-4444-4444-444444444444'; webId = '77777777-7777-7777-7777-777777777777' } }) }
    }
    $caught = $false
    try {
        Get-SsmOneDriveAdminState -Url 'https://contoso-my.sharepoint.com/personal/user' -Identity $identity -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
}

Invoke-SsmTest 'Get-SsmOneDriveAdminState returns Unlocked=$false for a locked target with an otherwise-valid owner/drive/admin fixture' {
    # Isolates the LockState->Unlocked mapping: everything else in the
    # fixture (Template, the single bound business drive, its owner, and
    # admin membership) is identical to the healthy happy-path fixture, so
    # this cannot pass for the unrelated "zero bound drives" reason the
    # prior version of this test actually exercised.
    $identity = @{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Upn = 'user@contoso.com'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Connect-SsmAdmin { $true }
    function Get-PnPConnection { @{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Get-PnPTenantSite { param($Identity, [switch]$Detailed, $Connection, $ErrorAction) @{ Template = 'SPSPERS#10'; LockState = 'NoAccess'; Owner = 'primary@contoso.com' } }
    function Get-PnPSite { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'44444444-4444-4444-4444-444444444444' } }
    function Get-PnPWeb { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'66666666-6666-6666-6666-666666666666' } }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ value = @(@{ id = 'd1'; driveType = 'business'
                         owner = @{ user = @{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'user@contoso.com' } }
                         sharepointIds = @{ siteId = '44444444-4444-4444-4444-444444444444'; webId = '66666666-6666-6666-6666-666666666666' } }) }
    }
    function Get-PnPSiteCollectionAdmin { param($Connection, $Includes, $ErrorAction) @() }
    $s = Get-SsmOneDriveAdminState -Url 'https://contoso-my.sharepoint.com/personal/user' -Identity $identity -Connection @{}
    Assert-Equal $true $s.IsPersonalSite
    Assert-Equal $false $s.Unlocked
    Assert-Equal '22222222-2222-2222-2222-222222222222' $s.OwnerId
}

Invoke-SsmTest 'Get-SsmOneDriveAdminState returns IsPersonalSite=$false for a non-personal site with an otherwise-valid owner/drive/admin fixture' {
    # Isolates the Template->IsPersonalSite mapping the same way, changing
    # only Template from the healthy happy-path fixture.
    $identity = @{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Upn = 'user@contoso.com'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Connect-SsmAdmin { $true }
    function Get-PnPConnection { @{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Get-PnPTenantSite { param($Identity, [switch]$Detailed, $Connection, $ErrorAction) @{ Template = 'STS#0'; LockState = 'Unlock'; Owner = 'primary@contoso.com' } }
    function Get-PnPSite { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'44444444-4444-4444-4444-444444444444' } }
    function Get-PnPWeb { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'66666666-6666-6666-6666-666666666666' } }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ value = @(@{ id = 'd1'; driveType = 'business'
                         owner = @{ user = @{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'user@contoso.com' } }
                         sharepointIds = @{ siteId = '44444444-4444-4444-4444-444444444444'; webId = '66666666-6666-6666-6666-666666666666' } }) }
    }
    function Get-PnPSiteCollectionAdmin { param($Connection, $Includes, $ErrorAction) @() }
    $s = Get-SsmOneDriveAdminState -Url 'https://contoso-my.sharepoint.com/personal/user' -Identity $identity -Connection @{}
    Assert-Equal $false $s.IsPersonalSite
    Assert-Equal $true $s.Unlocked
    Assert-Equal '22222222-2222-2222-2222-222222222222' $s.OwnerId
}

Invoke-SsmTest 'Get-SsmOneDriveAdminState leaves OwnerId/OwnerUpn null when the drive has no owner field, without throwing' {
    $identity = @{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Upn = 'user@contoso.com'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Connect-SsmAdmin { $true }
    function Get-PnPConnection { @{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Get-PnPTenantSite { param($Identity, [switch]$Detailed, $Connection, $ErrorAction) @{ Template = 'SPSPERS#10'; LockState = 'Unlock'; Owner = 'primary@contoso.com' } }
    function Get-PnPSite { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'44444444-4444-4444-4444-444444444444' } }
    function Get-PnPWeb { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'66666666-6666-6666-6666-666666666666' } }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        # No 'owner' key at all - matches Graph's documented-optional field.
        @{ value = @(@{ id = 'd1'; driveType = 'business'
                         sharepointIds = @{ siteId = '44444444-4444-4444-4444-444444444444'; webId = '66666666-6666-6666-6666-666666666666' } }) }
    }
    function Get-PnPSiteCollectionAdmin { param($Connection, $Includes, $ErrorAction) @() }
    $s = Get-SsmOneDriveAdminState -Url 'https://contoso-my.sharepoint.com/personal/user' -Identity $identity -Connection @{}
    Assert-Equal '' $s.OwnerId
    Assert-Equal '' $s.OwnerUpn
}

Invoke-SsmTest 'Get-SsmOneDriveAdminState leaves OwnerId/OwnerUpn null when the drive owner is a group, not a user, without throwing' {
    $identity = @{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Upn = 'user@contoso.com'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Connect-SsmAdmin { $true }
    function Get-PnPConnection { @{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Get-PnPTenantSite { param($Identity, [switch]$Detailed, $Connection, $ErrorAction) @{ Template = 'SPSPERS#10'; LockState = 'Unlock'; Owner = 'primary@contoso.com' } }
    function Get-PnPSite { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'44444444-4444-4444-4444-444444444444' } }
    function Get-PnPWeb { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'66666666-6666-6666-6666-666666666666' } }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ value = @(@{ id = 'd1'; driveType = 'business'
                         owner = @{ group = @{ id = '66666666-6666-6666-6666-666666666666'; displayName = 'Some Group' } }
                         sharepointIds = @{ siteId = '44444444-4444-4444-4444-444444444444'; webId = '66666666-6666-6666-6666-666666666666' } }) }
    }
    function Get-PnPSiteCollectionAdmin { param($Connection, $Includes, $ErrorAction) @() }
    $s = Get-SsmOneDriveAdminState -Url 'https://contoso-my.sharepoint.com/personal/user' -Identity $identity -Connection @{}
    Assert-Equal '' $s.OwnerId
    Assert-Equal '' $s.OwnerUpn
}

Invoke-SsmTest 'Get-SsmOneDriveAdminState reports AdminPresent=$null (not $false) for a recreated/stale account with a matching UPN but a different AadObjectId' {
    # A membership entry whose LoginName/UPN matches the requested account's
    # UPN but whose AadObjectId does not (or is missing) is a stale/recreated
    # directory collision, not proof the requested account is absent - a
    # false AdminPresent here would let a decision silently no-op a removal
    # or mask a real removal-block, so it must surface as unknown ($null).
    $identity = @{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Upn = 'admin@contoso.com'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Connect-SsmAdmin { $true }
    function Get-PnPConnection { @{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Get-PnPTenantSite { param($Identity, [switch]$Detailed, $Connection, $ErrorAction) @{ Template = 'SPSPERS#10'; LockState = 'Unlock'; Owner = 'primary@contoso.com' } }
    function Get-PnPSite { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'44444444-4444-4444-4444-444444444444' } }
    function Get-PnPWeb { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'66666666-6666-6666-6666-666666666666' } }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        @{ value = @(@{ id = 'd1'; driveType = 'business'
                         owner = @{ user = @{ id = '33333333-3333-3333-3333-333333333333'; userPrincipalName = 'owner@contoso.com' } }
                         sharepointIds = @{ siteId = '44444444-4444-4444-4444-444444444444'; webId = '66666666-6666-6666-6666-666666666666' } }) }
    }
    function Get-PnPSiteCollectionAdmin {
        param($Connection, $Includes, $ErrorAction)
        @(
            # Same UPN as the requested account, but AadObjectId belongs to a
            # different (recreated/stale) directory object.
            @{ Id = 5; LoginName = 'i:0#.f|membership|admin@contoso.com'; UserPrincipalName = 'admin@contoso.com'
               Email = 'admin@contoso.com'; AadObjectId = @{ NameId = '99999999-9999-9999-9999-999999999999' } }
        )
    }
    $s = Get-SsmOneDriveAdminState -Url 'https://contoso-my.sharepoint.com/personal/user' -Identity $identity -Connection @{}
    Assert-Equal '' $s.AdminPresent
    $decision = Get-SsmOneDriveAdminDecision -Action Remove -Identity $identity -Snapshot $s
    Assert-Equal 'Blocked' $decision
}

Invoke-SsmTest 'DIAGNOSTICS: Get-SsmOneDriveAdminState logs the original ErrorRecord (Graph error body, not just the wrapped message) for a drive-read failure' {
    # Regression: the drive-listing catch previously threw only
    # "$($_.Exception.Message)", discarding ErrorDetails/inner-exception
    # detail entirely. Loads the real logger to assert the full original
    # error body reached the log before the short wrapped message is thrown.
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/05-logging.ps1')
    $script:LogBuffer.Clear()
    $prevLogFile = Enter-SsmTestLogFile
    try {
    $identity = @{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Upn = 'user@contoso.com'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    function Get-SsmConnectionTenantId { param($Connection) [guid]'11111111-1111-1111-1111-111111111111' }
    function Connect-SsmAdmin { $true }
    function Get-PnPConnection { @{ Url = 'https://contoso-admin.sharepoint.com' } }
    function Get-PnPTenantSite { param($Identity, [switch]$Detailed, $Connection, $ErrorAction) @{ Template = 'SPSPERS#10'; LockState = 'Unlock'; Owner = 'primary@contoso.com' } }
    function Get-PnPSite { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'44444444-4444-4444-4444-444444444444' } }
    function Get-PnPWeb { param($Includes, $Connection, $ErrorAction) @{ Id = [guid]'66666666-6666-6666-6666-666666666666' } }
    function Invoke-PnPGraphMethod {
        param($Method, $Url, $Connection, $ErrorAction)
        $err = New-Object System.Management.Automation.ErrorRecord(
            [Exception]::new('Graph request failed'), 'GraphError',
            [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $err.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
            '{"error":{"code":"ServiceUnavailable","message":"drivestate-diagnostics-json-body-probe"}}')
        throw $err
    }
    $caught = $false
    try {
        Get-SsmOneDriveAdminState -Url 'https://contoso-my.sharepoint.com/personal/user' -Identity $identity -Connection @{} | Out-Null
    } catch { $caught = $true }
    Assert-Equal $true $caught
    $errLines = @($script:LogBuffer | Where-Object { $_.Level -eq 'ERROR' })
    if (-not ($errLines | Where-Object { $_.Message -like '*drivestate-diagnostics-json-body-probe*' })) {
        throw "original Graph error body was not logged; buffer: $(($errLines | ForEach-Object { $_.Message }) -join ' | ')"
    }
    } finally {
        Exit-SsmTestLogFile -Prev $prevLogFile
    }
}

# ---------------------------------------------------------------------------
# Invoke-SsmOneDriveAdminChange
# ---------------------------------------------------------------------------

function New-SsmChangeFixture {
    # Shared healthy fixture: candidate is a non-owner, non-primary account.
    # Tests override only what they need via the returned hashtable copies.
    @{
        Candidate = @{
            TenantId = [guid]'11111111-1111-1111-1111-111111111111'
            Id = [guid]'22222222-2222-2222-2222-222222222222'
            Upn = 'admin@contoso.com'; EnteredUpn = 'admin@contoso.com'; DisplayName = 'Admin'
        }
        Preview = @{
            TenantId = [guid]'11111111-1111-1111-1111-111111111111'
            Url = 'https://contoso-my.sharepoint.com/personal/user'
            SiteId = 'known-site'; IsPersonalSite = $true; Unlocked = $true
            OwnerId = [guid]'33333333-3333-3333-3333-333333333333'; OwnerUpn = 'user@contoso.com'
            PrimaryAdminId = [guid]'33333333-3333-3333-3333-333333333333'
            PrimaryAdminUpn = 'user@contoso.com'; AdminPresent = $true
            AdminUserId = [guid]'22222222-2222-2222-2222-222222222222'; AdminLogin = 'i:0#.f|membership|admin@contoso.com'
        }
    }
}

Invoke-SsmTest 'Secondary removal revalidates and verifies the exact principal' {
    $events = [System.Collections.Generic.List[string]]::new()
    $written = @{ Value = $false }
    $candidate = @{
        TenantId = [guid]'11111111-1111-1111-1111-111111111111'
        Id = [guid]'22222222-2222-2222-2222-222222222222'
        Upn = 'admin@contoso.com'; EnteredUpn = 'admin@contoso.com'; DisplayName = 'Admin'
    }
    $preview = @{
        TenantId = $candidate.TenantId; Url = 'https://contoso-my.sharepoint.com/personal/user'
        SiteId = 'known-site'; IsPersonalSite = $true; Unlocked = $true
        OwnerId = [guid]'33333333-3333-3333-3333-333333333333'; OwnerUpn = 'user@contoso.com'
        PrimaryAdminId = [guid]'33333333-3333-3333-3333-333333333333'
        PrimaryAdminUpn = 'user@contoso.com'; AdminPresent = $true
        AdminUserId = $candidate.Id; AdminLogin = 'i:0#.f|membership|admin@contoso.com'
    }
    function Resolve-SsmDirectoryUser {
        param($Upn, $TenantId, $Connection)
        $events.Add('ResolveIdentity'); return $candidate.Clone()
    }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $preview.Clone()
        if ($written.Value) {
            $events.Add('ReadAfter'); $state.AdminPresent = $false
            $state.AdminUserId = $null; $state.AdminLogin = ''
        } else { $events.Add('ReadBefore') }
        return $state
    }
    function Remove-PnPSiteCollectionAdmin {
        param($Owners, $Connection, $ErrorAction)
        Assert-Equal $preview.AdminLogin $Owners
        Assert-Equal 'site-connection' $Connection
        $events.Add('Write'); $written.Value = $true
    }
    $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $candidate `
        -Snapshot $preview -Connection 'site-connection'
    Assert-Equal 'ResolveIdentity,ReadBefore,Write,ReadAfter' ($events -join ',')
    Assert-Equal 'Success' $result.Result
    Assert-Equal $false $result.StopBatch
}

Invoke-SsmTest 'Secondary add revalidates and writes only the validated UPN, never a list' {
    $f = New-SsmChangeFixture
    $f.Preview.AdminPresent = $false; $f.Preview.AdminUserId = $null; $f.Preview.AdminLogin = ''
    $written = @{ Value = $false }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $script:f.Preview.Clone()
        if ($script:written.Value) { $state.AdminPresent = $true; $state.AdminUserId = 7; $state.AdminLogin = 'i:0#.f|membership|admin@contoso.com' }
        return $state
    }
    function Add-PnPSiteCollectionAdmin {
        param($Owners, $Connection, $ErrorAction)
        Assert-Equal $true ($Owners -is [string])
        Assert-Equal 'admin@contoso.com' $Owners
        $script:written.Value = $true
    }
    $script:f = $f; $script:written = $written
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Add -Identity $f.Candidate -Snapshot $f.Preview -Connection 'site-connection'
        Assert-Equal 'Success' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally {
        Remove-Variable -Scope Script -Name f, written -ErrorAction SilentlyContinue
    }
}

Invoke-SsmTest 'Requested identity drift (recreated account, same UPN) stops the whole batch, no write' {
    $f = New-SsmChangeFixture
    function Resolve-SsmDirectoryUser {
        param($Upn, $TenantId, $Connection)
        @{ Id = [guid]'99999999-9999-9999-9999-999999999999'; Upn = 'admin@contoso.com'
           DisplayName = 'Admin'; TenantId = [guid]'11111111-1111-1111-1111-111111111111' }
    }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) throw 'must not be called' }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) $script:wrote = $true }
    $script:wrote = $false
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Blocked' $result.Result
        Assert-Equal $true $result.StopBatch
        Assert-Equal $false $script:wrote
    } finally { Remove-Variable -Scope Script -Name wrote -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'A wrong-tenant revalidation result stops the whole batch, no write' {
    $f = New-SsmChangeFixture
    function Resolve-SsmDirectoryUser {
        param($Upn, $TenantId, $Connection)
        @{ Id = $script:f.Candidate.Id; Upn = 'admin@contoso.com'; DisplayName = 'Admin'
           TenantId = [guid]'99999999-9999-9999-9999-999999999999' }
    }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) throw 'must not be called' }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Blocked' $result.Result
        Assert-Equal $true $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'A resolver failure during revalidation stops the whole batch, no write' {
    $f = New-SsmChangeFixture
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) throw 'account not found' }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) throw 'must not be called' }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
    Assert-Equal 'Blocked' $result.Result
    Assert-Equal $true $result.StopBatch
}

Invoke-SsmTest 'DIAGNOSTICS: a revalidation failure inside Invoke-SsmOneDriveAdminChange logs the original exception, not only the stringified Detail' {
    # Regression for the swallowed-error bug: the mutation function only
    # ever surfaced $_.Exception.Message inside a Detail string. This test
    # loads the real logger (not the test-runner's no-op stub) so it can
    # assert the full original error - type, message, stack trace - reached
    # the log, matching what Write-SsmErrorLog produces at every other
    # boundary in this file.
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/05-logging.ps1')
    $script:LogBuffer.Clear()
    $prevLogFile = Enter-SsmTestLogFile
    try {
        $f = New-SsmChangeFixture
        function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) throw 'account not found: revalidation-diagnostics-probe' }
        function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) throw 'must not be called' }
        function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Blocked' $result.Result
        $errLines = @($script:LogBuffer | Where-Object { $_.Level -eq 'ERROR' })
        if (-not ($errLines | Where-Object { $_.Message -like '*revalidation-diagnostics-probe*' })) {
            throw "original exception was not logged; buffer: $(($errLines | ForEach-Object { $_.Message }) -join ' | ')"
        }
    } finally {
        Exit-SsmTestLogFile -Prev $prevLogFile
    }
}

Invoke-SsmTest 'A stale target (SiteId changed since preview) blocks only this target, no write' {
    $f = New-SsmChangeFixture
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $script:f.Preview.Clone(); $state.SiteId = 'a-different-site'; return $state
    }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Blocked' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'An owner change since preview blocks only this target, no write' {
    $f = New-SsmChangeFixture
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $script:f.Preview.Clone(); $state.OwnerId = [guid]'88888888-8888-8888-8888-888888888888'; return $state
    }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Blocked' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'A pre-write read failure blocks only this target, no write' {
    $f = New-SsmChangeFixture
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) throw 'wrong connection / read failed' }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Blocked' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'Removal blocked when the candidate is the actual owner, no write' {
    $f = New-SsmChangeFixture
    $f.Preview.OwnerId = $f.Candidate.Id
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) $script:f.Preview.Clone() }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Blocked' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'Removal blocked when the candidate is the primary administrator, no write' {
    $f = New-SsmChangeFixture
    $f.Preview.PrimaryAdminId = $f.Candidate.Id
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) $script:f.Preview.Clone() }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Blocked' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'Unknown membership (present but unbound) blocks the removal, no write' {
    $f = New-SsmChangeFixture
    $f.Preview.AdminUserId = $null; $f.Preview.AdminLogin = ''
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) $script:f.Preview.Clone() }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Blocked' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'Add already present is a no-op, no write' {
    $f = New-SsmChangeFixture
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) $script:f.Preview.Clone() }
    function Add-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Add -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'NoOp' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'Remove already absent is a no-op, no write' {
    $f = New-SsmChangeFixture
    $f.Preview.AdminPresent = $false; $f.Preview.AdminUserId = $null; $f.Preview.AdminLogin = ''
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) $script:f.Preview.Clone() }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'must not be called' }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'NoOp' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'A denied write (no exception, membership unchanged) is Failed, never Success' {
    $f = New-SsmChangeFixture
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState { param($Url, $Identity, $Connection) $script:f.Preview.Clone() }
    function Remove-PnPSiteCollectionAdmin {
        param($Owners, $Connection, $ErrorAction)
        # Write cmdlet returns normally (no exception) but the tenant silently denied it.
    }
    $script:f = $f
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Failed' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'A write timeout with membership actually changed verifies Success' {
    $f = New-SsmChangeFixture
    $written = @{ Value = $false }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $script:f.Preview.Clone()
        if ($script:written.Value) { $state.AdminPresent = $false; $state.AdminUserId = $null; $state.AdminLogin = '' }
        return $state
    }
    function Remove-PnPSiteCollectionAdmin {
        param($Owners, $Connection, $ErrorAction)
        $script:written.Value = $true
        throw 'The operation has timed out.'
    }
    $script:f = $f; $script:written = $written
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Success' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f, written -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'A write timeout with no readable post-write state is Unverified' {
    $f = New-SsmChangeFixture
    $calls = @{ Count = 0 }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $script:calls.Count++
        if ($script:calls.Count -eq 1) { return $script:f.Preview.Clone() }
        throw 'read failed after timeout'
    }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) throw 'The operation has timed out.' }
    $script:f = $f; $script:calls = $calls
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Unverified' $result.Result
        Assert-Equal $false $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f, calls -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'A protected identity changed after write is Failed with StopBatch true' {
    $f = New-SsmChangeFixture
    $written = @{ Value = $false }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $script:f.Preview.Clone()
        if ($script:written.Value) {
            $state.AdminPresent = $false; $state.AdminUserId = $null; $state.AdminLogin = ''
            $state.OwnerId = [guid]'77777777-7777-7777-7777-777777777777'
        }
        return $state
    }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) $script:written.Value = $true }
    $script:f = $f; $script:written = $written
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Failed' $result.Result
        Assert-Equal $true $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f, written -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'Unresolved (null) postwrite membership is Unverified, never Failed or Success' {
    $f = New-SsmChangeFixture
    $written = @{ Value = $false }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $script:f.Preview.Clone()
        if ($script:written.Value) {
            # Post-write membership could not be reliably bound to a
            # principal - unknown, not proof of failure or success.
            $state.AdminPresent = $null; $state.AdminUserId = $null; $state.AdminLogin = ''
        }
        return $state
    }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) $script:written.Value = $true }
    $script:f = $f; $script:written = $written
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Unverified' $result.Result
        Assert-Equal $false $result.StopBatch
        Assert-Equal '' $result.After
    } finally { Remove-Variable -Scope Script -Name f, written -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'A tenant/site change observed only at post-write verification is Failed with StopBatch true' {
    $f = New-SsmChangeFixture
    $written = @{ Value = $false }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $script:f.Preview.Clone()
        if ($script:written.Value) {
            $state.AdminPresent = $false; $state.AdminUserId = $null; $state.AdminLogin = ''
            $state.SiteId = 'a-different-site-observed-only-after-write'
        }
        return $state
    }
    function Remove-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) $script:written.Value = $true }
    $script:f = $f; $script:written = $written
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Remove -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Failed' $result.Result
        Assert-Equal $true $result.StopBatch
    } finally { Remove-Variable -Scope Script -Name f, written -ErrorAction SilentlyContinue }
}

Invoke-SsmTest 'A successful mutation reports the actual observed Before/After membership values in the result contract' {
    $f = New-SsmChangeFixture
    $f.Preview.AdminPresent = $false; $f.Preview.AdminUserId = $null; $f.Preview.AdminLogin = ''
    $written = @{ Value = $false }
    function Resolve-SsmDirectoryUser { param($Upn, $TenantId, $Connection) $script:f.Candidate.Clone() }
    function Get-SsmOneDriveAdminState {
        param($Url, $Identity, $Connection)
        $state = $script:f.Preview.Clone()
        if ($script:written.Value) { $state.AdminPresent = $true; $state.AdminUserId = $script:f.Candidate.Id; $state.AdminLogin = 'i:0#.f|membership|admin@contoso.com' }
        return $state
    }
    function Add-PnPSiteCollectionAdmin { param($Owners, $Connection, $ErrorAction) $script:written.Value = $true }
    $script:f = $f; $script:written = $written
    try {
        $result = Invoke-SsmOneDriveAdminChange -Action Add -Identity $f.Candidate -Snapshot $f.Preview -Connection 'c'
        Assert-Equal 'Success' $result.Result
        Assert-Equal 'False' $result.Before
        Assert-Equal 'True' $result.After
    } finally { Remove-Variable -Scope Script -Name f, written -ErrorAction SilentlyContinue }
}
