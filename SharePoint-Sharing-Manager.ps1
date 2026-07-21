<#
.SYNOPSIS
    SharePoint Sharing Manager - a terminal UI that finds and revokes
    unwanted SharePoint/OneDrive sharing.

.DESCRIPTION
    A dependency-light PowerShell TUI to audit and lock down SharePoint
    Online and OneDrive for Business sharing across a tenant:

      * Anonymous ("Anyone") links
      * Organization-wide links
      * Guest-specific sharing links
      * Guest user grants
      * Everyone Except External Users (EEEU) grants
      * Everyone grants

    Features:
      * Pure PowerShell terminal UI (VT/ANSI) - no WinForms, no DLLs.
      * PnP.PowerShell (v3) as the only dependency, installed on demand at
        CurrentUser scope.
      * App-only (certificate) or delegated sign-in, configured once via
        the in-app Setup tab and cached in a local config file.
      * Site and OneDrive target lists, scanned for findings against a
        configurable set of sharing-rule categories, with in-app revoke.
      * Search, status filters, sorting, multi-select, batch operations.
      * CSV export of the current view and CSV import of target URLs.
      * Timestamped log file and in-app log viewer.

.PARAMETER Ascii
    Use plain ASCII glyphs instead of Unicode box drawing characters.
    Helpful for legacy consoles with raster fonts.

.PARAMETER NoDisconnect
    Keep the PnP Online session alive when the tool exits.

.PARAMETER ConfigPath
    Path to the sign-in configuration file. Defaults to
    ~/.sharepoint-sharing-manager.json.

.EXAMPLE
    .\SharePoint-Sharing-Manager.ps1

.NOTES
    Version : 1.0.2
    License : MIT

.LINK
    https://learn.microsoft.com/sharepoint/turn-external-sharing-on-or-off
#>

#Requires -Version 7.4

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Terminal UI: Console.Write is the renderer; Write-Host is used for main-buffer auth prompts.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Best-effort cleanup paths (console restore, disconnect, log fallback).')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helpers; the TUI has its own confirmation dialogs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Internal helpers, not exported cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Ascii', Justification = 'Consumed in dot-sourced src/00-globals.ps1 at script scope; not visible to per-file static analysis.')]
param(
    [switch]$Ascii,
    [switch]$NoDisconnect,
    [string]$ConfigPath = (Join-Path $HOME '.sharepoint-sharing-manager.json')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:ConfigPath = $ConfigPath
$script:KeepSessions = [bool]$NoDisconnect

# ==== BEGIN SRC LOAD ==== (the release build replaces this block with the inlined files)
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.ps1' | Sort-Object Name)) {
    . $f.FullName
}
# ==== END SRC LOAD ====

# ============================================================================
#region Main
# ============================================================================

Write-SsmLog -Message ('=' * 60)
Write-SsmLog -Message ("SharePoint Sharing Manager v{0} started (PS {1})" -f $script:Version, $PSVersionTable.PSVersion)
Write-SsmLog -Message ("OS: {0}" -f [System.Environment]::OSVersion.VersionString)
foreach ($modName in @('PnP.PowerShell')) {
    $installed = Get-Module -ListAvailable -Name $modName | Sort-Object Version -Descending | Select-Object -First 1
    if ($installed) {
        Write-SsmLog -Message ("Module installed: {0} v{1}" -f $modName, $installed.Version)
    } else {
        Write-SsmLog -Message ("Module installed: {0} NOT INSTALLED" -f $modName) -Level WARN
    }
}
Write-SsmLog -Message ('=' * 60)

try {
    Enter-Tui
    $lastW = 0; $lastH = 0
    while (-not $script:UI.Quit) {
        $size = Get-ConsoleSize
        if ($size[0] -ne $lastW -or $size[1] -ne $lastH) {
            $lastW = $size[0]; $lastH = $size[1]
            [Console]::Write("$script:ESC[2J")
            $script:UI.Dirty = $true
        }
        if ($script:UI.Dirty) {
            Write-Screen
            $script:UI.Dirty = $false
        }
        if ([Console]::KeyAvailable) {
            while ([Console]::KeyAvailable -and -not $script:UI.Quit) {
                $k = [Console]::ReadKey($true)
                Invoke-KeyDispatch -K $k
            }
            $script:UI.Dirty = $true
        } else {
            Start-Sleep -Milliseconds 25
        }
    }
} finally {
    Exit-Tui
    if (-not $script:KeepSessions) {
        Write-Host 'Closing sessions...' -ForegroundColor DarkGray
        Disconnect-SsmConnection
    } else {
        Write-SsmLog -Message 'Sessions left open (-NoDisconnect).'
    }
    Write-SsmLog -Message 'SharePoint Sharing Manager ended.'
    Write-Host ''
    Write-Host 'SharePoint Sharing Manager closed.' -ForegroundColor Cyan
    Write-Host ("  Log     : " + $script:LogFile) -ForegroundColor DarkGray
    if (Test-Path -LiteralPath $script:ExportDir)  { Write-Host ("  Exports : " + $script:ExportDir) -ForegroundColor DarkGray }
}

#endregion
