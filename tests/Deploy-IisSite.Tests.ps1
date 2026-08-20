#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ScriptPath = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($PSScriptRoot, '..', 'scripts', 'iis', 'Deploy-IisSite.ps1'))

    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$null, [ref]$errors)
    $script:ParseErrors = $errors
    $script:Functions = $script:Ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

    function Get-Parameter {
        param ([string] $ParameterName)

        return $script:Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq $ParameterName }
    }

    function Get-ValidateSetValue {
        param ([string] $ParameterName)

        $attribute = (Get-Parameter -ParameterName $ParameterName).Attributes |
            Where-Object { $_.TypeName.Name -eq 'ValidateSet' }

        return $attribute.PositionalArguments.Value
    }

    function Test-ParameterIsMandatory {
        param ([string] $ParameterName)

        $attribute = (Get-Parameter -ParameterName $ParameterName).Attributes |
            Where-Object { $_.TypeName.Name -eq 'Parameter' }

        return [bool]($attribute.NamedArguments |
            Where-Object { $_.ArgumentName -eq 'Mandatory' })
    }

    # Returns the if-statements whose condition mentions $Text, so a test can assert that
    # something happens only inside that branch rather than merely somewhere in the file.
    function Get-GuardedBy {
        param ([string] $Text)

        return $script:Ast.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -like "*$Text*"
            }, $true)
    }
}

Describe 'Deploy-IisSite.ps1 static analysis' {

    It 'exists' {
        $script:ScriptPath | Should -Exist
    }

    It 'parses without syntax errors' {
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'requires the parameters a deployment cannot be inferred from' {
        foreach ($expected in @('SiteName', 'Port', 'EnvironmentName', 'SourcePath', 'Version')) {
            Test-ParameterIsMandatory -ParameterName $expected |
                Should -BeTrue -Because "'$expected' has no sensible default"
        }
    }

    It 'defines the expected helper functions' {
        $names = $script:Functions.Name
        foreach ($expected in @(
                'Copy-Payload',
                'Test-Health',
                'Resolve-PayloadDirectory',
                'Write-ReverseProxyWebConfig',
                'Write-ServiceDefinition',
                'Stop-NodeServiceIfRunning',
                'Install-NodeService')) {
            $names | Should -Contain $expected
        }
    }

    It 'uses only approved verbs for its functions' {
        $approved = (Get-Verb).Verb
        foreach ($function in $script:Functions) {
            $verb = $function.Name.Split('-')[0]
            $approved | Should -Contain $verb -Because "function '$($function.Name)' must use an approved verb"
        }
    }

    It 'offers the supported deployment modes' {
        Get-ValidateSetValue -ParameterName 'Mode' | Should -Be @('InPlace', 'Swap')
    }

    It 'offers the supported hosting models' {
        Get-ValidateSetValue -ParameterName 'HostingModel' | Should -Be @('AspNetCore', 'ReverseProxy')
    }

    It 'defaults to hosting the payload in the IIS worker process' {
        # The three .NET services pass no -HostingModel at all, so the default is what they
        # actually run.
        (Get-Parameter -ParameterName 'HostingModel').DefaultValue.Value | Should -Be 'AspNetCore'
        (Get-Parameter -ParameterName 'Mode').DefaultValue.Value | Should -Be 'InPlace'
    }
}

Describe 'Deploy-IisSite.ps1 reverse-proxy hosting' {

    It 'rejects the swap mode it cannot keep in step with the service' {
        # Swap repoints the site at a per-release directory, but the Windows service has one
        # working directory and one registered image path, so IIS would serve the new release
        # while the service still ran the old one - and the health check would pass against
        # the wrong bits.
        $script:Ast.Extent.Text |
            Should -Match "\`$Mode -eq 'Swap'" `
            -Because 'ReverseProxy must be guarded against -Mode Swap'
    }

    It 'requires the loopback port it has to forward to' {
        $script:Ast.Extent.Text |
            Should -Match "\`$NodePort -le 0" `
            -Because 'ReverseProxy without -NodePort would rewrite to nowhere'
    }

    It 'refuses a loopback port that collides with the public binding' {
        $script:Ast.Extent.Text |
            Should -Match "\`$NodePort -eq \`$Port" `
            -Because 'IIS owns the public port; the service cannot also bind it'
    }

    It 'resolves node.exe on the target when no explicit path is supplied' {
        (Get-Parameter -ParameterName 'NodeExePath').DefaultValue.Value | Should -Be ''

        $script:Ast.Extent.Text |
            Should -Match 'Get-Command node\.exe\s+`?\s*-CommandType Application' `
            -Because 'different target machines can install Node.js in different locations'
    }

    It 'validates the resolved node.exe before changing the deployed payload' {
        $script:Ast.Extent.Text |
            Should -Match 'Test-Path -LiteralPath \$NodeExePath -PathType Leaf'

        $script:Ast.Extent.Text |
            Should -Match 'Resolve-Path -LiteralPath \$NodeExePath'
    }

    It 'runs the entry point the payload actually ships' {
        # Every framework names it differently - server.js for Next, server/entry.mjs for
        # Astro, server/index.mjs for Nuxt, server/server.mjs for Angular - and it doubles
        # as the file the payload is recognised by, so a hardcoded name would silently
        # reject three of the four Node services.
        (Get-Parameter -ParameterName 'ServerEntryPoint').DefaultValue.Value | Should -Be 'server.js'

        $script:Ast.Extent.Text | Should -Match '<arguments>\$EntryPoint</arguments>'
        $script:Ast.Extent.Text | Should -Not -Match '<arguments>server\.js</arguments>'
    }

    It 'publishes the environment through the application pool only when IIS hosts the app' {
        # Under ReverseProxy the pool never loads the application, so the environment has to
        # reach the process through the service definition instead. Asserting the guard -
        # not just the presence of the call - is the point.
        $guards = Get-GuardedBy -Text "HostingModel -eq 'AspNetCore'"
        $guards | Should -Not -BeNullOrEmpty

        ($guards.Extent.Text -join "`n") |
            Should -Match 'ASPNETCORE_ENVIRONMENT'
    }
}

Describe 'Deploy-IisSite.ps1 reusability' {

    It 'names no application-specific assembly' {
        # Regression guard. The backup and both rollback paths were once gated on
        # 'RichillCapital.Identity.Web.dll' being present, which silently meant every other
        # service deployed with no backup and could not roll back at all - the failure only
        # appeared once a health check had already failed.
        $script:Ast.Extent.Text |
            Should -Not -Match 'RichillCapital\.[\w.]+\.dll' `
            -Because 'a shared script must not recognise one service by name'
    }

    It 'decides what a valid payload looks like from the hosting model' {
        $script:Ast.Extent.Text |
            Should -Match '\$payloadMarker' `
            -Because 'the backup and rollback gates read the marker rather than a fixed file name'
    }
}

# --- TODO: behavioural tests -------------------------------------------------
# The helper functions still share a file with the deploy logic, so they cannot be
# dot-sourced without executing it. To unit-test them (e.g. assert that a failed
# health check restores the backup, or that Install-NodeService reinstalls rather
# than restarts when the service already exists), extract the helpers into a
# dot-sourceable file such as scripts/iis/_IisCommon.ps1 and load it here:
#
#   BeforeAll { . ([System.IO.Path]::Combine($PSScriptRoot, '..', 'scripts', 'iis', '_IisCommon.ps1')) }
#
#   Describe 'Install-NodeService' {
#       It 'reinstalls an existing service so a changed port takes effect' {
#           Mock Get-ServiceState { 'Stopped' }
#           Mock Invoke-ServiceHost { }
#           # ... assert 'uninstall' was invoked before 'install'
#       }
#   }
