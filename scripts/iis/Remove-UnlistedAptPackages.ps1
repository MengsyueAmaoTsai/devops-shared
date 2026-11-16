<#
.SYNOPSIS
    Removes the files of an apt repository's pool that none of its Packages indexes lists.

.DESCRIPTION
    Deploy-StaticChannel.ps1 adds content and keeps what was there. A repository that its pipeline builds afresh
    each time, with the current version only (as the CLI's scripts/build-linux.sh does), therefore leaves every
    previous version's .deb files in pool/ on the site. Run after Deploy-StaticChannel.ps1, this keeps the files that
    a dists/<suite>/<component>/binary-<arch>/Packages lists, the ones apt can still be told to download, removes the
    rest, and removes the directories that leaves empty.

    It removes nothing, and fails, when no index lists a file, or when an index lists a file that is not in the
    pool: either means the path is not the repository that was just deployed.

    A client that read the indexes before the deployment and downloads a package after it gets 404 for a removed
    one, and has to run apt update again.

.PARAMETER RepositoryPath
    The repository's root on disk, the folder that holds dists/ and pool/, for example
    C:\inetpub\channels\RichillCapital.Downloads.Integration\apt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $RepositoryPath).ProviderPath.TrimEnd('\')
$pool = Join-Path $root 'pool'
$dists = Join-Path $root 'dists'

Write-Host "==> Pruning unlisted packages from $root"

if (-not (Test-Path -LiteralPath $pool -PathType Container)) {
    Write-Host "    no pool, nothing to prune"
    return
}

$indexes = @(
    if (Test-Path -LiteralPath $dists -PathType Container) {
        Get-ChildItem -LiteralPath $dists -Recurse -File -Filter 'Packages'
    }
)

$listed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

foreach ($index in $indexes) {
    foreach ($line in [System.IO.File]::ReadAllLines($index.FullName)) {
        if ($line -match '^Filename:\s*(\S+)\s*$') {
            [void]$listed.Add([System.IO.Path]::GetFullPath((Join-Path $root ($Matches[1] -replace '/', '\'))))
        }
    }
}

if ($listed.Count -eq 0) {
    throw "No Packages index under $dists lists a file. Refusing to prune $pool."
}

$missing = @($listed | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })

if ($missing.Count -gt 0) {
    throw "The Packages indexes under $dists list files that are not there, such as $($missing[0]). Refusing to prune $pool."
}

$removed = 0

foreach ($file in @(Get-ChildItem -LiteralPath $pool -Recurse -File)) {
    if ($listed.Contains($file.FullName)) {
        continue
    }

    # A file that is being downloaded may not be removable. It is left for the next deployment rather than
    # failing this one, which has already published the new version.
    try {
        Remove-Item -LiteralPath $file.FullName -Force
        Write-Host "    pruned $($file.FullName.Substring($root.Length + 1))"
        $removed++
    }
    catch {
        Write-Warning "Could not remove $($file.FullName): $($_.Exception.Message)"
    }
}

# Deepest first, so that a directory whose subdirectories were all empty goes too.
$directories = @(
    Get-ChildItem -LiteralPath $pool -Recurse -Directory |
        Sort-Object -Property { $_.FullName.Length } -Descending
)

foreach ($directory in $directories) {
    if (-not (Get-ChildItem -LiteralPath $directory.FullName -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $directory.FullName -Force
    }
}

Write-Host "==> Kept $($listed.Count) listed file(s), pruned $removed"
