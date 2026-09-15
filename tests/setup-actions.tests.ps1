# Tests for Register-SsmAppOnlyApp/Register-SsmDelegatedApp permission
# requests. All PnP/Graph/module/modal calls stubbed locally - no live
# tenant call, sign-in, or credential discovery. See task-5-report.md for
# the researched PnP.PowerShell 3.3.0 default-scope evidence behind these
# assertions.

function Install-SsmModule { $true }
function Get-SsmTenantInput { $script:Auth.Tenant = 't.onmicrosoft.com'; 't.onmicrosoft.com' }
function Show-ConfirmModal { param($Title, $Lines) $script:LastConfirmLines = $Lines; $script:ConfirmAnswer }
function Show-MsgModal { param($Title, $Lines, $Kind) $script:LastMsg = @{ Title = $Title; Lines = $Lines; Kind = $Kind } }
function Invoke-OnMainBuffer { param([scriptblock]$Action) & $Action }
function Save-SsmAuth {}
function Write-SsmErrorLog { param([string]$Context, $ErrorRecord) }
function Write-SsmLog { param([string]$Message, [string]$Level = 'INFO') }
function Copy-SsmExistingAppId { param($Tenant, $Mode) $script:CopyExistingCalled = $true }
function Add-SsmCertToExistingApp { param($Tenant) $script:AddCertCalled = $true }

function Reset-SetupActionsState {
    $script:Auth = @{ AuthMode = ''; ClientId = ''; Tenant = ''; AdminUrl = ''; Thumbprint = ''; CertPath = ''; CertExpires = '' }
    $script:IsWin = $false
    $script:ConfirmAnswer = $true
    $script:LastConfirmLines = @()
    $script:LastMsg = $null
    $script:LastRegisterSplat = $null
    $script:CopyExistingCalled = $false
    $script:AddCertCalled = $false
    $HOME_dummy = $null
}

Invoke-SsmTest 'Register-SsmAppOnlyApp requests Sites.FullControl.All plus Graph User.Read.All, keeps SharePoint scope unchanged' {
    Reset-SetupActionsState
    function Register-PnPAzureADApp {
        param($ApplicationName, $Tenant, $ValidYears, $SharePointApplicationPermissions, $GraphApplicationPermissions, $OutPath, $Store)
        $script:LastRegisterSplat = @{
            SharePointApplicationPermissions = $SharePointApplicationPermissions
            GraphApplicationPermissions       = $GraphApplicationPermissions
        }
        [pscustomobject]@{ 'AzureAppId/ClientId' = 'app-1'; 'Certificate Thumbprint' = 'THUMB' }
    }
    Register-SsmAppOnlyApp
    Assert-Equal 'True' ($script:LastRegisterSplat.SharePointApplicationPermissions -contains 'Sites.FullControl.All')
    Assert-Equal 'True' ($script:LastRegisterSplat.SharePointApplicationPermissions -contains 'User.ReadWrite.All')
    Assert-Equal 'True' ($script:LastRegisterSplat.GraphApplicationPermissions -contains 'Sites.FullControl.All')
    Assert-Equal 'True' ($script:LastRegisterSplat.GraphApplicationPermissions -contains 'User.Read.All')
    Assert-Equal 'AppOnly' $script:Auth.AuthMode
}

Invoke-SsmTest 'Register-SsmAppOnlyApp explains the new User.Read.All scope before requesting confirmation' {
    Reset-SetupActionsState
    $script:ConfirmAnswer = $false
    function Register-PnPAzureADApp { throw 'must not be called when the operator declines' }
    Register-SsmAppOnlyApp
    $joined = ($script:LastConfirmLines -join "`n")
    Assert-Equal 'True' ($joined -like '*User.Read.All*')
    Assert-Equal 'True' ($joined -like '*OneDrive secondary-admin*' -or $joined -like '*secondary-admin*')
    Assert-Equal '' $script:Auth.AuthMode
}

Invoke-SsmTest 'Register-SsmAppOnlyApp adoption of an already-existing app does not silently PATCH new permissions in' {
    Reset-SetupActionsState
    function Register-PnPAzureADApp { throw [System.Exception]::new('Application already exists in this tenant.') }
    Register-SsmAppOnlyApp
    Assert-Equal 'True' $script:AddCertCalled
}

Invoke-SsmTest 'Register-SsmDelegatedApp does not override delegated permission defaults' {
    Reset-SetupActionsState
    $capturedKeys = $null
    function Register-PnPEntraIDAppForInteractiveLogin {
        param($ApplicationName, $Tenant)
        $script:capturedKeys = $PSBoundParameters.Keys
        [pscustomobject]@{ 'AzureAppId/ClientId' = 'app-2' }
    }
    Register-SsmDelegatedApp
    Assert-Equal 'False' ($script:capturedKeys -contains 'GraphDelegatePermissions')
    Assert-Equal 'False' ($script:capturedKeys -contains 'SharePointDelegatePermissions')
    Assert-Equal 'Delegated' $script:Auth.AuthMode
}
