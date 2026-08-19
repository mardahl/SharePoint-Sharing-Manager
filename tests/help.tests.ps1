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
