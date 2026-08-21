# Tests for the existing-app fallback paths (app already in Entra, local config lost it).
# Root cause under test: Get-PnPAzureADApp returns Model.AzureADApp whose client-id
# property is AppId - reading .AzureAppId returned null and the re-key always failed.
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssm-test-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
$script:ConfigPath = Join-Path $script:TestRoot 'config.json'

# Stubs: modal + operator-Graph layers. Get-PnPAzureADApp result faked with the
# real property name (AppId) the PnP 3.x cmdlet returns.
$script:FakeApp = $null
function Show-ConfirmModal  { param($Title, $Lines) $script:ConfirmAnswer }
function Show-MsgModal      { param($Title, $Lines, $Kind) $script:LastMsg = @{ Title = $Title; Lines = $Lines } }
function Invoke-OnMainBuffer { param([scriptblock]$Block) & $Block }
function Connect-SsmOperatorGraph { param([string]$Tenant) $script:ConnectedTenant = $Tenant }
function Write-SsmErrorLog { param([string]$Context, $ErrorRecord) }
function Write-SsmLog { param([string]$Message, [string]$Level = 'INFO') }
# connections.tests.ps1 (loads earlier) stubs Save-SsmAuth to a no-op; keep the
# no-op and assert in-memory state (disk persistence is covered by config tests).
function Save-SsmAuth {}
function Get-PnPAzureADApp { param([string]$Identity) $script:FakeApp }
function Get-PnPAzureADApp { param([string]$Identity) $script:FakeApp }
function New-PnPAzureCertificate { param($CommonName, $ValidYears, $OutPfx, $OutCert)
    [pscustomobject]@{
        Thumbprint = 'THUMB123'
        Certificate = [byte[]](1,2,3)
        KeyCredentials = (@{ customKeyIdentifier='x'; keyId='k'; type='AsymmetricX509Cert'; usage='Verify'; value='REVJQg==' } | ConvertTo-Json)
    } }
function Invoke-PnPGraphMethod { param($Method, $Url, $Content)
    $script:GraphCalls += "$Method $Url"
    $script:LastPatchContent = $Content
    if ($Method -eq 'Get') { return [pscustomobject]@{ keyCredentials = @(@{ type='AsymmetricX509Cert'; usage='Verify'; key='b2xk' }) } }
    [pscustomobject]@{} }

function Reset-AdoptState {
    $script:Auth = @{ AuthMode=''; ClientId=''; Tenant='t.onmicrosoft.com'; AdminUrl=''; Thumbprint=''; CertPath=''; CertExpires=''; IncludeLinkDates=''; Loaded=$true }
    $script:TenantName = 't'
    $script:IsWin = $false
    $script:GraphCalls = @()
    $script:ConfirmAnswer = $true
    $script:LastMsg = $null
    $script:FakeApp = [pscustomobject]@{ AppId = 'real-app-id-123'; DisplayName = 'SharePoint-Sharing-Manager' }
}

Invoke-SsmTest 'Find-SsmAppClientId reads AppId from the returned app object' {
    Reset-AdoptState
    $id = Find-SsmAppClientId -Tenant 't.onmicrosoft.com'
    Assert-Equal 'real-app-id-123' $id
}

Invoke-SsmTest 'Find-SsmAppClientId throws when no client id property exists' {
    Reset-AdoptState
    $script:FakeApp = [pscustomobject]@{ DisplayName = 'SharePoint-Sharing-Manager' }
    $threw = $false
    try { Find-SsmAppClientId -Tenant 't.onmicrosoft.com' } catch { $threw = $true }
    Assert-Equal 'True' $threw
}

Invoke-SsmTest 'Copy-SsmExistingAppId adopts the found app into config (delegated)' {
    Reset-AdoptState
    Copy-SsmExistingAppId -Tenant 't.onmicrosoft.com' -Mode 'Delegated'
    Assert-Equal 'Delegated' $script:Auth.AuthMode
    Assert-Equal 'real-app-id-123' $script:Auth.ClientId
}

Invoke-SsmTest 'Copy-SsmExistingAppId does nothing when the operator cancels' {
    Reset-AdoptState
    $script:ConfirmAnswer = $false
    Copy-SsmExistingAppId -Tenant 't.onmicrosoft.com' -Mode 'Delegated'
    Assert-Equal '' $script:Auth.ClientId
}

Invoke-SsmTest 'Add-SsmCertToExistingApp re-keys via PATCH keyCredentials and saves app-only config' {
    Reset-AdoptState
    Add-SsmCertToExistingApp -Tenant 't.onmicrosoft.com'
    Assert-Equal 'AppOnly' $script:Auth.AuthMode
    Assert-Equal 'real-app-id-123' $script:Auth.ClientId
    Assert-Equal 'Get applications(appId=''real-app-id-123'')?$select=keyCredentials' $script:GraphCalls[0]
    Assert-Equal 'Patch applications(appId=''real-app-id-123'')' $script:GraphCalls[1]
}

Invoke-SsmTest 'Add-SsmKeyCredentialToApp sends base64 DER, keeps existing keys' {
    Reset-AdoptState
    $cert = New-PnPAzureCertificate -CommonName 'x' -ValidYears 1 -OutPfx 'x.pfx' -OutCert 'x.cer'
    Add-SsmKeyCredentialToApp -AppId 'app-1' -Cert $cert
    Assert-Equal 2 $script:GraphCalls.Count
    Assert-Equal 'Patch applications(appId=''app-1'')' $script:GraphCalls[1]
    # new key is the parsed DER value from KeyCredentials, not the PEM string
    Assert-Equal 'REVJQg==' $script:LastPatchContent.keyCredentials[1].key
}

Invoke-SsmTest 'Add-SsmCertToExistingApp does nothing when the operator cancels' {
    Reset-AdoptState
    $script:ConfirmAnswer = $false
    Add-SsmCertToExistingApp -Tenant 't.onmicrosoft.com'
    Assert-Equal 0 $script:GraphCalls.Count
    Assert-Equal '' $script:Auth.ClientId
}

Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
