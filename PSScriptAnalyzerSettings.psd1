@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.0')
        }
    }
}
