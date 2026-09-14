#Requires -Version 7.4
# Assert-based test runner: dot-sources pure-logic src files, runs tests/*.tests.ps1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Minimal stubs so src files that log can load without the full TUI
$script:LogBuffer = New-Object System.Collections.ArrayList
$script:LogFile = Join-Path ([IO.Path]::GetTempPath()) 'ssm-test.log'
$script:UI = @{ Dirty = $false }
function Write-SsmLog { param([string]$Message, [string]$Level = 'INFO') }
function Write-SsmErrorLog { param([string]$Context, $ErrorRecord) }

function Enter-SsmTestLogFile {
    # Isolates $script:LogFile for a single test that loads the real logger
    # (src/05-logging.ps1) instead of the no-op stub above. $script:LogFile
    # is script-scoped to this file regardless of call depth, so a test
    # that never resets it would otherwise inherit whatever value an
    # earlier *.tests.ps1 file left behind (e.g. help.tests.ps1 sets
    # $script:LogFile = 'x.log' with no restore, for its own unrelated
    # stub-only tests) - and the real Write-SsmLog would then physically
    # write to that relative path under the repo's working directory.
    # Returns the previous value; the caller must restore it via
    # Exit-SsmTestLogFile in a `finally` block.
    $prev = $script:LogFile
    $script:LogFile = Join-Path ([IO.Path]::GetTempPath()) ("ssm-test-{0}.log" -f ([guid]::NewGuid()))
    return $prev
}

function Exit-SsmTestLogFile {
    param($Prev)
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        Remove-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
    }
    $script:LogFile = $Prev
}

# Pure-logic files only - keep in sync as files gain PnP-free helpers
foreach ($f in @('15-drawing','20-modals','25-config','30-connections','35-scan-engine','40-revoke','45-targets','46-onedrive-admin','50-csv','55-tenant-actions','60-setup-actions','65-views','70-cache','72-update-check','75-key-dispatch')) {
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
