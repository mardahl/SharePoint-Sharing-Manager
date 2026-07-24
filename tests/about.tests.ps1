Invoke-SsmTest 'Get-SsmUrlLauncher picks the shell URL on Windows' {
    $l = Get-SsmUrlLauncher -Url 'https://github.com/mardahl' -IsWin $true -IsMac $false
    Assert-Equal 'https://github.com/mardahl' $l.Exe
    Assert-Equal 0 (@($l.Args).Count)
}

Invoke-SsmTest 'Get-SsmUrlLauncher uses open + URL arg on macOS' {
    $l = Get-SsmUrlLauncher -Url 'https://example.com' -IsWin $false -IsMac $true
    Assert-Equal 'open' $l.Exe
    Assert-Equal 'https://example.com' (@($l.Args)[0])
}

Invoke-SsmTest 'Get-SsmUrlLauncher uses xdg-open + URL arg on Linux' {
    $l = Get-SsmUrlLauncher -Url 'https://example.com' -IsWin $false -IsMac $false
    Assert-Equal 'xdg-open' $l.Exe
    Assert-Equal 'https://example.com' (@($l.Args)[0])
}

Invoke-SsmTest 'Invoke-AboutKey G opens the author GitHub profile' {
    $script:CapturedUrl = $null
    function Open-SsmUrl { param([string]$Url) $script:CapturedUrl = $Url }
    $k = [System.ConsoleKeyInfo]::new('g', [System.ConsoleKey]::G, $false, $false, $false)
    Invoke-AboutKey -K $k
    Assert-Equal 'https://github.com/mardahl' $script:CapturedUrl
}

Invoke-SsmTest 'Invoke-AboutKey R opens the releases page' {
    $script:CapturedUrl = $null
    function Open-SsmUrl { param([string]$Url) $script:CapturedUrl = $Url }
    $k = [System.ConsoleKeyInfo]::new('r', [System.ConsoleKey]::R, $false, $false, $false)
    Invoke-AboutKey -K $k
    Assert-Equal 'https://github.com/mardahl/SharePoint-Sharing-Manager/releases' $script:CapturedUrl
}
