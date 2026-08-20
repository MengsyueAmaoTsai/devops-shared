<#
.SYNOPSIS
    把 GitVersion 產出的 SemVer 轉成各發佈通道要求的版本格式。

.DESCRIPTION
    三種通道對版本字串的要求互斥，而且錯了都不會在 build 期爆掉，只會在使用者端
    造成「新版被舊版蓋掉」這種很難追的問題：

      * MSIX / Store : 必須是四段純數字，不能帶 prerelease；Store 另外要求第四段為 0。
      * Debian       : '-' 是 upstream/revision 的分隔符，所以 '1.2.3-rc.1' 在 dpkg
                       眼中「比 1.2.3 新」，會讓 rc 覆蓋正式版。prerelease 必須改用 '~'。
      * Android      : versionCode 必須是單調遞增整數，且 Play 拒收重複值，
                       所以它不從 SemVer 推導，一律由 Build.BuildId 帶入。

.PARAMETER SemVer
    來源版本，例如 '1.2.3'、'1.2.3-integration.5'。

.PARAMETER Channel
    目標通道。

.PARAMETER VariableName
    若指定，額外輸出 ##vso[task.setvariable] 讓後續 task 取用。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SemVer,

    [Parameter(Mandatory)]
    [ValidateSet('Msix', 'Debian', 'NuGet', 'AndroidDisplay', 'WinGet')]
    [string]$Channel,

    [string]$VariableName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ChannelVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SemVer,
        [Parameter(Mandatory)][string]$Channel
    )

    $pattern = '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<pre>[0-9A-Za-z.-]+))?(?:\+(?<meta>[0-9A-Za-z.-]+))?$'
    $match = [regex]::Match($SemVer, $pattern)

    if (-not $match.Success) {
        throw "'$SemVer' is not a valid SemVer 2.0 version."
    }

    $major = $match.Groups['major'].Value
    $minor = $match.Groups['minor'].Value
    $patch = $match.Groups['patch'].Value
    $pre = if ($match.Groups['pre'].Success) { $match.Groups['pre'].Value } else { $null }

    switch ($Channel) {
        'Msix' {
            # 四段純數字。prerelease 資訊在這裡一定會遺失 —— 這是 MSIX 的限制，
            # 不是 bug，所以三個 ring 必須靠 Identity.Name 後綴而不是版本號來區分。
            return "$major.$minor.$patch.0"
        }
        'Debian' {
            if ($pre) {
                # '~' 在 dpkg 的排序規則裡小於空字串，所以 1.2.3~rc.1 < 1.2.3，符合直覺。
                return "$major.$minor.$patch~$pre"
            }
            return "$major.$minor.$patch"
        }
        'NuGet' {
            return $SemVer
        }
        'AndroidDisplay' {
            return "$major.$minor.$patch"
        }
        'WinGet' {
            return $SemVer
        }
        default {
            throw "Unsupported channel '$Channel'."
        }
    }
}

$converted = ConvertTo-ChannelVersion -SemVer $SemVer -Channel $Channel

if ($VariableName) {
    Write-Host "##vso[task.setvariable variable=$VariableName]$converted"
}

Write-Host "$Channel version: $converted"
$converted
