@{
    # PSScriptAnalyzer policy for devops-shared CI / deployment scripts.
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Deployment scripts run inside the Azure DevOps PowerShell task, which always
        # provides a host; Write-Host is the intended way to surface coloured progress in
        # the pipeline log. The "might not work when there is no host" caveat does not apply.
        'PSAvoidUsingWriteHost',

        # The state-changing helpers (Stop-/Set-/Update-*) are private, non-exported and
        # always run non-interactively in CI. Advertising -WhatIf/-Confirm they never honour
        # would be misleading, so ShouldProcess support is intentionally omitted.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
