#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Behavioural tests: the script touches nothing but the folder it is given, so it runs as it is, against a
# repository built in TestDrive.

BeforeAll {
    $script:ScriptPath = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($PSScriptRoot, '..', 'scripts', 'iis', 'Remove-UnlistedAptPackages.ps1'))

    # Writes a file of the repository, creating its folders.
    function New-RepositoryFile {
        param ([string] $Repository, [string] $RelativePath, [string] $Content = 'x')

        $path = Join-Path $Repository ($RelativePath -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, $Content)
    }

    # A Packages index, as dpkg-scanpackages writes it, listing the given pool files.
    function New-PackagesIndex {
        param ([string] $Repository, [string] $Suite, [string] $Architecture, [string[]] $Filenames)

        $stanzas = foreach ($filename in $Filenames) {
            "Package: richillcapital-cli`nArchitecture: $Architecture`nFilename: $filename`nSize: 1`n"
        }

        New-RepositoryFile -Repository $Repository `
            -RelativePath "dists/$Suite/main/binary-$Architecture/Packages" `
            -Content ($stanzas -join "`n")
    }
}

Describe 'Remove-UnlistedAptPackages.ps1' {
    BeforeEach {
        $script:Repository = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:Repository | Out-Null
    }

    It 'keeps the files the indexes list and removes the others' {
        $current = @(
            'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~alpha.97_amd64.deb',
            'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~alpha.97_arm64.deb'
        )
        $previous = @(
            'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~alpha.96_amd64.deb',
            'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~alpha.96_arm64.deb'
        )

        foreach ($file in $current + $previous) { New-RepositoryFile -Repository $script:Repository -RelativePath $file }
        New-PackagesIndex -Repository $script:Repository -Suite 'staging' -Architecture 'amd64' -Filenames $current[0]
        New-PackagesIndex -Repository $script:Repository -Suite 'staging' -Architecture 'arm64' -Filenames $current[1]

        & $script:ScriptPath -RepositoryPath $script:Repository

        foreach ($file in $current) { Join-Path $script:Repository $file | Should -Exist }
        foreach ($file in $previous) { Join-Path $script:Repository $file | Should -Not -Exist }
        Join-Path $script:Repository 'dists/staging/main/binary-amd64/Packages' | Should -Exist
    }

    It 'keeps a file that any suite lists' {
        $stable = 'pool/main/r/richillcapital-cli/richillcapital-cli_4.1.0_amd64.deb'
        $staging = 'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~beta.1_amd64.deb'

        foreach ($file in @($stable, $staging)) { New-RepositoryFile -Repository $script:Repository -RelativePath $file }
        New-PackagesIndex -Repository $script:Repository -Suite 'stable' -Architecture 'amd64' -Filenames $stable
        New-PackagesIndex -Repository $script:Repository -Suite 'staging' -Architecture 'amd64' -Filenames $staging

        & $script:ScriptPath -RepositoryPath $script:Repository

        Join-Path $script:Repository $stable | Should -Exist
        Join-Path $script:Repository $staging | Should -Exist
    }

    It 'removes the directories it leaves empty' {
        $kept = 'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~alpha.97_amd64.deb'

        New-RepositoryFile -Repository $script:Repository -RelativePath $kept
        New-RepositoryFile -Repository $script:Repository -RelativePath 'pool/main/o/old-product/old-product_1.0.0_amd64.deb'
        New-PackagesIndex -Repository $script:Repository -Suite 'staging' -Architecture 'amd64' -Filenames $kept

        & $script:ScriptPath -RepositoryPath $script:Repository

        Join-Path $script:Repository 'pool/main/o' | Should -Not -Exist
        Join-Path $script:Repository $kept | Should -Exist
    }

    It 'reads indexes with CRLF line endings' {
        $kept = 'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~alpha.97_amd64.deb'

        New-RepositoryFile -Repository $script:Repository -RelativePath $kept
        New-RepositoryFile -Repository $script:Repository `
            -RelativePath 'dists/staging/main/binary-amd64/Packages' `
            -Content "Package: richillcapital-cli`r`nFilename: $kept`r`nSize: 1`r`n"

        & $script:ScriptPath -RepositoryPath $script:Repository

        Join-Path $script:Repository $kept | Should -Exist
    }

    It 'removes nothing and fails when there is no index' {
        $file = 'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~alpha.97_amd64.deb'
        New-RepositoryFile -Repository $script:Repository -RelativePath $file

        { & $script:ScriptPath -RepositoryPath $script:Repository } | Should -Throw '*lists a file*'

        Join-Path $script:Repository $file | Should -Exist
    }

    It 'removes nothing and fails when an index lists a file that is not in the pool' {
        $present = 'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~alpha.96_amd64.deb'
        New-RepositoryFile -Repository $script:Repository -RelativePath $present
        New-PackagesIndex -Repository $script:Repository -Suite 'staging' -Architecture 'amd64' `
            -Filenames 'pool/main/r/richillcapital-cli/richillcapital-cli_4.2.0~alpha.97_amd64.deb'

        { & $script:ScriptPath -RepositoryPath $script:Repository } | Should -Throw '*not there*'

        Join-Path $script:Repository $present | Should -Exist
    }

    It 'does nothing when the repository has no pool' {
        New-PackagesIndex -Repository $script:Repository -Suite 'staging' -Architecture 'amd64' -Filenames @()

        { & $script:ScriptPath -RepositoryPath $script:Repository } | Should -Not -Throw
    }
}
