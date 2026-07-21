#Requires -Version 7.4
# Assert-based test runner: dot-sources pure-logic src files, runs tests/*.tests.ps1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Minimal stubs so src files that log can load without the full TUI
$script:LogBuffer = New-Object System.Collections.ArrayList
$script:LogFile = Join-Path ([IO.Path]::GetTempPath()) 'ssm-test.log'
function Write-SsmLog { param([string]$Message, [string]$Level = 'INFO') }

# Pure-logic files only - keep in sync as files gain PnP-free helpers
foreach ($f in @('25-config','30-connections','35-scan-engine','40-revoke','45-targets')) {
    $p = Join-Path $root "src/$f.ps1"
    if (Test-Path $p) { . $p }
}

$script:Passed = 0; $script:Failed = 0
function Invoke-SsmTest {
    param([string]$Name, [scriptblock]$Block)
    try { & $Block; $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "expected [$Expected] got [$Actual] $Because" }
}

foreach ($tf in Get-ChildItem -Path $PSScriptRoot -Filter '*.tests.ps1') {
    Write-Host $tf.Name
    . $tf.FullName
}
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
