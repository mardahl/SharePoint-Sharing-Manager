$script:T = @{ ModalTitle=''; Row=''; CtxHi=''; Muted='' }
$script:LogFile = 'x.log'; $script:ExportDir = 'x'
$script:Version = '9.9.9'
$script:CapturedHelp = ''
function Show-ReportModal { param($Title, $Lines) $script:CapturedHelp = ($Lines | ForEach-Object { $_[1] }) -join "`n" }

Invoke-SsmTest 'Help modal documents Sharing tab and tenant management' {
    Show-HelpModal
    if ($script:CapturedHelp -notmatch 'Sharing tab') { throw 'no Sharing section' }
    if ($script:CapturedHelp -match 'Tenant tab') { throw 'stale Tenant section' }
    if ($script:CapturedHelp -notmatch 'Tenants') { throw 'no Tenants section' }
    if ($script:CapturedHelp -notmatch 'quick-switch') { throw 'T switcher undocumented' }
    if ($script:CapturedHelp -notmatch 'Enter\s+actions for the highlighted tenant') { throw 'Setup Enter undocumented' }
}

Invoke-SsmTest 'Non-Targets tab hints advertise the T switcher' {
    $script:UI = @{ SearchMode = $false }
    foreach ($kind in @('Tenant','Log','About')) {
        $hints = Get-TabHints -Tab @{ Kind = $kind }
        $joined = ($hints | ForEach-Object { $_[0] + ':' + $_[1] }) -join ' '
        if ($joined -notmatch 'T:switch') { throw "$kind hints missing T switch: $joined" }
    }
}

Invoke-SsmTest 'Split-TextLines keeps key-column spacing and hangs continuation under the description' {
    $w = Split-TextLines -Text '  M                    manage secondary admin on the selected OneDrives only' -Width 50
    Assert-Equal '  M                    manage secondary admin on' $w[0]
    Assert-Equal ((' ' * 23) + 'the selected OneDrives only') $w[1]
}

Invoke-SsmTest 'Split-TextLines wraps plain prose at the leading indent' {
    $w = Split-TextLines -Text '  one two three four five six' -Width 16
    Assert-Equal '  one two three' $w[0]
    Assert-Equal '  four five six' $w[1]
}

Invoke-SsmTest 'Help modal lines fit the modal width (72) so nothing wraps' {
    Show-HelpModal
    $long = @($script:CapturedHelp -split "`n" | Where-Object { $_.Length -gt 72 -and $_ -notmatch '^\s+(Log file|Exports)' })
    Assert-Equal 0 $long.Count
}
