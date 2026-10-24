@{
    # Event handlers in the GUI receive (sender, args) whether they use them or not; internal
    # helpers are called positionally on purpose; best-effort UI calls (log file, shapes,
    # stopping a cancelled runspace) must never stop the window.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingPositionalParameters',
        'PSReviewUnusedParameter',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns'
    )
    Rules = @{
        PSAvoidUsingEmptyCatchBlock = @{ Enable = $true }
    }
}
