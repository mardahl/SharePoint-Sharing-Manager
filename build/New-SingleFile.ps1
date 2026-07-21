#Requires -Version 7.4
# Builds the single-file release artifact: replaces the dot-source block in the
# bootstrap with the inlined contents of every src/*.ps1 (in name order).
param([string]$OutDir = 'dist')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$boot = Get-Content -LiteralPath (Join-Path $root 'SharePoint-Sharing-Manager.ps1') -Raw
$begin = '# ==== BEGIN SRC LOAD ===='
$end   = '# ==== END SRC LOAD ===='
$i = $boot.IndexOf($begin); $j = $boot.IndexOf($end)
if ($i -lt 0 -or $j -lt 0) { throw 'Concat markers not found in bootstrap.' }
$srcBody = (Get-ChildItem (Join-Path $root 'src/*.ps1') | Sort-Object Name | ForEach-Object {
    "# ---- inlined: $($_.Name) ----`n" + (Get-Content -LiteralPath $_.FullName -Raw)
}) -join "`n"
$single = $boot.Substring(0, $i) + $srcBody + $boot.Substring($j + $end.Length)
if (-not (Test-Path (Join-Path $root $OutDir))) { New-Item -ItemType Directory -Path (Join-Path $root $OutDir) | Out-Null }
$outFile = Join-Path $root "$OutDir/SharePoint-Sharing-Manager.ps1"
Set-Content -LiteralPath $outFile -Value $single -Encoding UTF8BOM
# Parse-verify the artifact
$errs = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($outFile, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) { $errs | ForEach-Object { Write-Host $_.Message }; throw 'Single-file artifact has parse errors.' }
Write-Host "Built and parse-verified: $outFile"
