<#
.SYNOPSIS
    把一份「發佈通道」的靜態內容部署到 IIS —— MSIX + .appinstaller、CLI 二進位、
    或 apt repository 的檔案樹。

.DESCRIPTION
    跟 Deploy-IisSite.ps1 的差別：那支是部署「會跑的 ASP.NET 應用程式」，這支部署
    「純靜態的下載檔案」，兩者對 app pool、健康檢查、內容替換策略的需求完全不同。

    內容替換是「疊加」而非「取代」：新版本加進去，舊版本保留到 RetainVersions 為止。
    這是刻意的 —— .appinstaller 與 apt 的使用者可能還停在舊版，直接砍掉舊檔案會讓
    他們的更新檢查 404。

.PARAMETER SiteName
    IIS 站台名稱，例如 'RichillCapital.Downloads.Integration'。

.PARAMETER Port
    站台繫結的埠。

.PARAMETER SourcePath
    要部署的資料夾，或一個 .zip。內容會直接對應到站台根目錄。

.PARAMETER Version
    這次發佈的版本，用來決定要保留/淘汰哪些版本資料夾。

.PARAMETER VersionedFolder
    站台根目錄下存放各版本的子資料夾名稱，預設 'packages'。
    在這個資料夾底下、名稱不在保留名單內的子資料夾會被淘汰。

.PARAMETER RetainVersions
    保留幾個歷史版本（含這次），預設 5。

.PARAMETER PhysicalPath
    站台實體路徑，預設 C:\inetpub\channels\<SiteName>。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SiteName,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$Version,
    [string]$EnvironmentName = 'Integration',
    [string]$VersionedFolder = 'packages',
    [int]$RetainVersions = 5,
    [string]$PhysicalPath,
    [string[]]$AdditionalIdentities = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module WebAdministration -ErrorAction Stop

if (-not $PhysicalPath) {
    $PhysicalPath = Join-Path 'C:\inetpub\channels' $SiteName
}

Write-Host "==> Deploying channel '$SiteName' ($EnvironmentName) version $Version"

# ---------------------------------------------------------------- 來源正規化
$stagedSource = $SourcePath

if ($SourcePath.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
    $stagedSource = Join-Path ([System.IO.Path]::GetTempPath()) "channel-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $stagedSource -Force | Out-Null
    Expand-Archive -LiteralPath $SourcePath -DestinationPath $stagedSource -Force
}

if (-not (Test-Path -LiteralPath $stagedSource)) {
    throw "Source path not found: $stagedSource"
}

$sourceItems = @(Get-ChildItem -LiteralPath $stagedSource -Force)
if ($sourceItems.Count -eq 0) {
    throw "Source path is empty: $stagedSource"
}

# ------------------------------------------------------------------ App pool
$appPoolName = $SiteName

if (-not (Test-Path "IIS:\AppPools\$appPoolName")) {
    Write-Host "    creating app pool '$appPoolName'"
    New-WebAppPool -Name $appPoolName | Out-Null
}

# 純靜態內容不需要 CLR。
Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name managedRuntimeVersion -Value ''

# ---------------------------------------------------------------------- Site
if (-not (Test-Path -LiteralPath $PhysicalPath)) {
    New-Item -ItemType Directory -Path $PhysicalPath -Force | Out-Null
}

$site = Get-Website -Name $SiteName -ErrorAction SilentlyContinue

if (-not $site) {
    Write-Host "    creating site '$SiteName' on port $Port"
    New-Website `
        -Name $SiteName `
        -Port $Port `
        -PhysicalPath $PhysicalPath `
        -ApplicationPool $appPoolName `
        -Force | Out-Null
}
else {
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $PhysicalPath
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $appPoolName
}

# ---------------------------------------------------------------- MIME types
# IIS 對未知副檔名一律回 404.3，所以每一種要送出去的檔案都得先登記。
#
# 兩個踩過的坑，不要改回去：
#
#   1. 絕對不要用 '.*' 當 catch-all。Remove-WebConfigurationProperty -AtElement
#      會把它當成萬用字元，一次刪光站台上所有繼承來的 mimeMap（web.config 會長出
#      幾百個 <remove>），結果 .json / .msix / .appinstaller 全部退化成
#      application/octet-stream。
#
#   2. apt repository 的 'Release' / 'InRelease' 沒有副檔名。IIS 對這種檔案的
#      對應鍵是單一個句點 '.'，不是 '.*'。
$mimeMaps = @(
    @{ Extension = '.msix';        Type = 'application/msix' }
    @{ Extension = '.msixbundle';  Type = 'application/msixbundle' }
    @{ Extension = '.appx';        Type = 'application/appx' }
    @{ Extension = '.appxbundle';  Type = 'application/appxbundle' }
    @{ Extension = '.appinstaller';Type = 'application/appinstaller' }
    @{ Extension = '.deb';         Type = 'application/vnd.debian.binary-package' }
    @{ Extension = '.apk';         Type = 'application/vnd.android.package-archive' }
    @{ Extension = '.aab';         Type = 'application/octet-stream' }
    @{ Extension = '.gz';          Type = 'application/gzip' }
    @{ Extension = '.json';        Type = 'application/json' }
    @{ Extension = '.';            Type = 'text/plain' }
)

# 先把站台層級的 staticContent 整段清掉，回到純繼承狀態。這讓這一步冪等，
# 也會自動修復先前錯誤設定留下的殘骸。
Clear-WebConfiguration `
    -PSPath "IIS:\Sites\$SiteName" `
    -Filter 'system.webServer/staticContent' `
    -ErrorAction SilentlyContinue

foreach ($map in $mimeMaps) {
    $existing = Get-WebConfiguration `
        -PSPath "IIS:\Sites\$SiteName" `
        -Filter "system.webServer/staticContent/mimeMap[@fileExtension='$($map.Extension)']" `
        -ErrorAction SilentlyContinue

    # 繼承來的設定已經對了就不要動它 —— 每一次多餘的 remove/add 都是一次踩坑機會。
    if ($existing -and $existing.mimeType -eq $map.Type) {
        continue
    }

    if ($existing) {
        Remove-WebConfigurationProperty `
            -PSPath "IIS:\Sites\$SiteName" `
            -Filter 'system.webServer/staticContent' `
            -Name '.' `
            -AtElement @{ fileExtension = $map.Extension }
    }

    Add-WebConfigurationProperty `
        -PSPath "IIS:\Sites\$SiteName" `
        -Filter 'system.webServer/staticContent' `
        -Name '.' `
        -Value @{ fileExtension = $map.Extension; mimeType = $map.Type }
}

# apt 需要能列出目錄以外的東西都靠絕對路徑，目錄瀏覽關掉即可。
Set-WebConfigurationProperty `
    -PSPath "IIS:\Sites\$SiteName" `
    -Filter 'system.webServer/directoryBrowse' `
    -Name enabled `
    -Value $false

# -------------------------------------------------------------- 內容同步（疊加）
Write-Host "    syncing content into $PhysicalPath"

# /E 遞迴含空資料夾，不用 /MIR —— 舊版本要留著。
$robocopyArgs = @($stagedSource, $PhysicalPath, '/E', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
& robocopy.exe @robocopyArgs | Out-Null

# robocopy 的 exit code 0-7 都算成功，8 以上才是真的失敗。
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

$global:LASTEXITCODE = 0

# ------------------------------------------------------------------ 版本淘汰
$versionsRoot = Join-Path $PhysicalPath $VersionedFolder

if (Test-Path -LiteralPath $versionsRoot) {
    $stale = @(
        Get-ChildItem -LiteralPath $versionsRoot -Directory |
            Sort-Object -Property LastWriteTimeUtc -Descending |
            Select-Object -Skip $RetainVersions
    )

    foreach ($folder in $stale) {
        Write-Host "    pruning old version: $($folder.Name)"
        Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------- 權限
foreach ($identity in @("IIS AppPool\$appPoolName") + $AdditionalIdentities) {
    if (-not $identity) { continue }

    & icacls.exe $PhysicalPath /grant "${identity}:(OI)(CI)(RX)" /T /C /Q | Out-Null
    $global:LASTEXITCODE = 0
}

# ------------------------------------------------------------------- 驗證
if ((Get-Website -Name $SiteName).State -ne 'Started') {
    Start-Website -Name $SiteName
}

$probeUri = "http://localhost:$Port/"

try {
    $response = Invoke-WebRequest -Uri $probeUri -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    Write-Host "    probe $probeUri -> $($response.StatusCode)"
}
catch {
    # 根目錄沒有 default document 時回 403/404 是正常的，站台本身仍然活著。
    Write-Host "    probe $probeUri -> $($_.Exception.Message)"
}

Write-Host "==> Channel '$SiteName' now serving version $Version on port $Port"
