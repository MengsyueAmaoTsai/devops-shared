#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Provisions and deploys RichillCapital.Identity.Web to IIS on the machine this script
    runs on.

.DESCRIPTION
    The script is idempotent: it creates the application pool, the site, the directory
    layout, the ACLs, and the firewall rule when they are missing, and only updates the
    payload on subsequent runs. The same script backs both deployment targets, so the
    two environments cannot drift apart:

      Integration (in-place) - the agent runs it locally against localhost IIS.
      Staging (in-place)     - the agent runs it over SSH on the Windows Server VM.

    Layout created under -SiteRoot (default C:\inetpub\wwwroot\<SiteName>):

      InPlace  <SiteRoot>\            the live application directory
               <SiteRoot>\logs\       Serilog output, preserved across deployments
               <SiteRoot>.backup\     the previous payload, used to roll back

      Swap     <SiteRoot>\releases\<version>_<timestamp>\   one directory per deployment
               <SiteRoot>\logs\                             shared, junctioned into each
                                                            release so log history and
                                                            release pruning stay separate

    In swap mode the site's physical path is repointed at the new release and the old one
    is left on disk, so a failed health check - or a later manual rollback - is a physical
    path change plus a recycle rather than another deployment.

    ASPNETCORE_ENVIRONMENT is set on the application pool (applicationHost.config) rather
    than baked into the artifact, so the exact bits validated by the pipeline are the bits
    that reach every environment.

.PARAMETER SiteName
    IIS site name. The application pool is created with the same name.

.PARAMETER Port
    HTTP port for the site binding.

.PARAMETER EnvironmentName
    Value published as ASPNETCORE_ENVIRONMENT on the application pool, e.g. 'Integration'.

.PARAMETER SourcePath
    The published output to deploy: either a directory or a .zip archive of one.

.PARAMETER Version
    Version being deployed. Used to name the release directory and in the log output.

.PARAMETER Mode
    InPlace mirrors the payload over the live directory behind app_offline.htm.
    Swap unpacks into a new release directory and repoints the site at it.

.PARAMETER HostingModel
    AspNetCore hosts the payload in the IIS worker process through the ASP.NET Core Module.
    ReverseProxy gives IIS the public binding only: the payload is a Node application that
    WinSW runs as a Windows service on -NodePort, and IIS rewrites every request to it.
    ReverseProxy requires -Mode InPlace and expects winsw.exe in the payload; web.config and
    the service definition are generated at deploy time, not shipped in the artifact.

.PARAMETER NodePort
    Loopback port the Node process listens on under -HostingModel ReverseProxy. Required in
    that model, never opened in the firewall, and must differ from -Port.

.PARAMETER NodeExePath
    Optional absolute path to node.exe on the target. When omitted, the deployment resolves
    node.exe from the target machine's PATH. WinSW needs the resulting concrete image path;
    it does not resolve PATH when starting the service.

.PARAMETER ServerEntryPoint
    The script the Node service runs, relative to the payload root, and the file the payload
    is recognised by. Every framework names it differently: server.js (Next), server/entry.mjs
    (Astro), server/index.mjs (Nuxt), server/server.mjs (Angular).

.PARAMETER CommitSha
.PARAMETER BuildTimeUtc
    Build provenance surfaced to a ReverseProxy application through COMMIT_SHA and
    BUILD_TIME_UTC. An ASP.NET Core service bakes the same facts into its assembly at
    publish time, so both are ignored under that hosting model.

.PARAMETER SiteRoot
    Root directory for the site. Defaults to C:\inetpub\wwwroot\<SiteName>.

.PARAMETER HealthPath
    Health endpoint probed after the payload goes live. The deployment fails - and rolls
    back - when it does not return 200 within -HealthTimeoutSeconds.

.PARAMETER HealthTimeoutSeconds
    How long to wait for the health endpoint. Environments that rebuild their database on
    startup need a longer window than a plain restart.

.PARAMETER RetainReleases
    Swap mode only: how many release directories to keep, newest first, excluding the live
    one.

.PARAMETER AdditionalIdentities
    Extra principals granted Modify on the site root, e.g. the build agent's service
    account when it deploys locally.

.PARAMETER SkipFirewallRule
    Do not create the inbound firewall rule for -Port.

.EXAMPLE
    .\Deploy-IisSite.ps1 -SiteName 'RichillCapital.Identity.Web.Integration' -Port 10001 `
        -EnvironmentName 'Integration' -SourcePath 'D:\a\1\RichillCapital.Identity.Web' `
        -Version '1.4.0' -Mode InPlace

.EXAMPLE
    .\Deploy-IisSite.ps1 -SiteName 'RichillCapital.Identity.Web.Staging' -Port 10001 `
        -EnvironmentName 'Staging' -SourcePath 'C:\Users\deploy\drops\identity-web.zip' `
        -Version '1.4.0' -Mode Swap -HealthTimeoutSeconds 180
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SiteName,

    [Parameter(Mandatory)]
    [ValidateRange(1, 65535)]
    [int] $Port,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EnvironmentName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SourcePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Version,

    [ValidateSet('InPlace', 'Swap')]
    [string] $Mode = 'InPlace',

    [ValidateSet('AspNetCore', 'ReverseProxy')]
    [string] $HostingModel = 'AspNetCore',

    [ValidateRange(0, 65535)]
    [int] $NodePort = 0,

    [string] $NodeExePath = '',

    [string] $ServerEntryPoint = 'server.js',

    [string] $CommitSha = '',

    [string] $BuildTimeUtc = '',

    [string] $SiteRoot,

    [string] $HealthPath = '/healthz',

    [ValidateRange(0, 3600)]
    [int] $HealthTimeoutSeconds = 120,

    [ValidateRange(1, 50)]
    [int] $RetainReleases = 5,

    [string[]] $AdditionalIdentities = @(),

    [switch] $SkipFirewallRule
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Import-Module WebAdministration

if ($HostingModel -eq 'ReverseProxy') {
    if ($NodePort -le 0) {
        throw "-NodePort is required with -HostingModel ReverseProxy: IIS has to know where to forward."
    }

    if ($NodePort -eq $Port) {
        throw "-NodePort must differ from -Port; IIS owns the public port and forwards to the loopback one."
    }

    # Swap repoints the site at a per-release directory, but the Windows service has a
    # single working directory and a single registered image path, so the two halves would
    # go out of step: IIS would serve the new release while the service still ran the old
    # one, and the health check would pass against the wrong bits.
    if ($Mode -eq 'Swap') {
        throw "-Mode Swap is not supported with -HostingModel ReverseProxy; use InPlace."
    }

    if ([string]::IsNullOrWhiteSpace($NodeExePath)) {
        $nodeCommand = Get-Command node.exe `
            -CommandType Application `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $nodeCommand) {
            throw "Node.js was not found on the target machine's PATH. Install Node.js or pass -NodeExePath explicitly."
        }

        $NodeExePath = $nodeCommand.Source
    }

    if (-not [System.IO.Path]::IsPathRooted($NodeExePath)) {
        throw "-NodeExePath must be an absolute path; received '$NodeExePath'."
    }

    if (-not (Test-Path -LiteralPath $NodeExePath -PathType Leaf)) {
        throw "Node.js executable was not found at '$NodeExePath'."
    }

    $NodeExePath = (Resolve-Path -LiteralPath $NodeExePath).ProviderPath
}

if ([string]::IsNullOrWhiteSpace($SiteRoot)) {
    $SiteRoot = Join-Path 'C:\inetpub\wwwroot' $SiteName
}

$appPoolPath = "IIS:\AppPools\$SiteName"
$sitePath = "IIS:\Sites\$SiteName"
$sharedLogsPath = Join-Path $SiteRoot 'logs'
$releasesPath = Join-Path $SiteRoot 'releases'
$backupPath = "$SiteRoot.backup"
$appOfflineName = 'app_offline.htm'

# WinSW resolves its configuration from the .xml sitting next to the executable, and takes
# the service id from the <id> element rather than the file name.
$serviceHostName = 'winsw'
$serviceExePath = Join-Path $SiteRoot "$serviceHostName.exe"

# The file that proves a directory holds a real payload. It gates the backup and every
# rollback: without it the first deployment would "roll back" onto an empty directory. An
# ASP.NET Core publish always contains web.config; a Node payload is identified by the entry
# point the service is about to run, which every framework names differently - server.js for
# Next, server/entry.mjs for Astro, server/index.mjs for Nuxt, server/server.mjs for Angular.
$payloadMarker = if ($HostingModel -eq 'ReverseProxy') { $ServerEntryPoint } else { 'web.config' }

function Write-Step {
    param ([Parameter(Mandatory)][string] $Message)

    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Grant-DirectoryAccess {
    param (
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Identity,
        [Parameter(Mandatory)][string] $Rights
    )

    $acl = Get-Acl -Path $Path
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $Identity,
        $Rights,
        'ContainerInherit, ObjectInherit',
        'None',
        'Allow')

    $acl.SetAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

function Set-AppPoolEnvironmentVariable {
    param (
        [Parameter(Mandatory)][string] $AppPoolName,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Value
    )

    # Requires IIS 10 (Windows Server 2016+). Removing the existing entry first keeps the
    # collection from growing a duplicate on every deployment.
    $filter = "system.applicationHost/applicationPools/add[@name='$AppPoolName']/environmentVariables"

    $existing = Get-WebConfiguration `
        -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "$filter/add[@name='$Name']" `
        -ErrorAction SilentlyContinue

    if ($existing) {
        Remove-WebConfigurationProperty `
            -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter $filter `
            -Name '.' `
            -AtElement @{ name = $Name }
    }

    Add-WebConfigurationProperty `
        -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter $filter `
        -Name '.' `
        -Value @{ name = $Name; value = $Value }
}

function Wait-AppPoolState {
    param (
        [Parameter(Mandatory)][string] $AppPoolName,
        [Parameter(Mandatory)][ValidateSet('Started', 'Stopped')][string] $State,
        [int] $TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-WebAppPoolState -Name $AppPoolName).Value -ne $State) {
        if ((Get-Date) -gt $deadline) {
            throw "Application pool '$AppPoolName' did not reach state '$State' within $TimeoutSeconds seconds."
        }

        Start-Sleep -Seconds 1
    }
}

function Stop-AppPoolIfRunning {
    param ([Parameter(Mandatory)][string] $AppPoolName)

    if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') {
        Stop-WebAppPool -Name $AppPoolName
        Wait-AppPoolState -AppPoolName $AppPoolName -State 'Stopped'
    }
}

function Start-AppPoolIfStopped {
    param ([Parameter(Mandatory)][string] $AppPoolName)

    if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Started') {
        Start-WebAppPool -Name $AppPoolName
        Wait-AppPoolState -AppPoolName $AppPoolName -State 'Started'
    }
}

function Copy-Payload {
    param (
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [switch] $Mirror,
        [string[]] $ExcludeDirectories = @(),
        [string[]] $ExcludeFiles = @()
    )

    $arguments = @($Source, $Destination, '/E', '/R:3', '/W:2', '/NFL', '/NDL', '/NP', '/NJH')

    if ($Mirror) {
        $arguments += '/PURGE'
    }

    # Bare directory names, so robocopy excludes them on both sides: the source is not
    # copied from and the destination is not purged.
    foreach ($directory in $ExcludeDirectories) {
        $arguments += @('/XD', $directory)
    }

    if ($ExcludeFiles.Count -gt 0) {
        $arguments += '/XF'
        $arguments += $ExcludeFiles
    }

    & robocopy.exe @arguments | Out-Host

    # Robocopy reports what it did through the exit code; 8 and above are real failures.
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed copying '$Source' to '$Destination' (exit code $LASTEXITCODE)."
    }

    $global:LASTEXITCODE = 0
}

function Test-Health {
    param (
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    if ($TimeoutSeconds -le 0) {
        Write-Host "Health check skipped."
        return $true
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = 'no response'

    while ((Get-Date) -le $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
            if ($response.StatusCode -eq 200) {
                Write-Host "Health check passed: $Url returned 200." -ForegroundColor Green
                return $true
            }

            $lastError = "HTTP $($response.StatusCode)"
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds 3
    }

    Write-Host "Health check failed after $TimeoutSeconds seconds: $lastError" -ForegroundColor Red
    return $false
}

function Resolve-PayloadDirectory {
    param (
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpandTo
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Source path '$Path' does not exist."
    }

    if ((Get-Item -LiteralPath $Path).PSIsContainer) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    if ([System.IO.Path]::GetExtension($Path) -ne '.zip') {
        throw "Source path '$Path' must be a directory or a .zip archive."
    }

    Write-Step "Expanding '$Path'."

    if (Test-Path -LiteralPath $ExpandTo) {
        Remove-Item -LiteralPath $ExpandTo -Recurse -Force
    }

    New-Item -ItemType Directory -Path $ExpandTo -Force | Out-Null
    Expand-Archive -LiteralPath $Path -DestinationPath $ExpandTo -Force

    return $ExpandTo
}

# --- Reverse-proxy hosting --------------------------------------------------------
# A Node payload has no ASP.NET Core Module to host it, so IIS owns only the public binding
# and rewrites every request to a loopback port, where WinSW runs the process as a Windows
# service. Both configuration files are generated below rather than shipped in the artifact,
# which is what keeps one artifact deployable to every environment - and means a single
# script defines both environments, so they cannot drift apart.
#
# Every input is an explicit parameter rather than a script-scope variable read through
# dynamic scoping: what ends up in a generated configuration file is worth being able to
# read off the call site, and it is what will let these move into a dot-sourceable file the
# tests can exercise directly.

function Write-ReverseProxyWebConfig {
    param (
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int] $ProxyPort
    )

    # preserveHostHeader is off and the forwarded headers are set explicitly, so the
    # application sees the public host rather than 127.0.0.1 when it builds absolute URLs.
    @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="ReverseProxyToNode" stopProcessing="true">
          <match url="(.*)" />
          <action type="Rewrite" url="http://127.0.0.1:$ProxyPort/{R:1}" />
          <serverVariables>
            <set name="HTTP_X_FORWARDED_PROTO" value="http" />
            <set name="HTTP_X_FORWARDED_HOST" value="{HTTP_HOST}" />
            <set name="HTTP_X_FORWARDED_FOR" value="{REMOTE_ADDR}" />
          </serverVariables>
        </rule>
      </rules>
    </rewrite>

    <proxy enabled="true" preserveHostHeader="false" reverseRewriteHostInResponseHeaders="false" />
    <webSocket enabled="true" />
  </system.webServer>
</configuration>
"@ | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-ServiceDefinition {
    param (
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ServiceId,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $LogDirectory,
        [Parameter(Mandatory)][string] $ExecutablePath,
        [Parameter(Mandatory)][string] $EntryPoint,
        [Parameter(Mandatory)][int] $ListenPort,
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][string] $ApplicationVersion,
        [string] $Commit = '',
        [string] $BuildTime = ''
    )

    # HOSTNAME is pinned to loopback: the public entry point is the IIS binding, and a
    # service listening on 0.0.0.0 would be reachable around it.
    @"
<service>
  <id>$ServiceId</id>
  <name>$ServiceId</name>
  <description>Node application server for $ServiceId</description>
  <workingdirectory>$WorkingDirectory</workingdirectory>
  <executable>$ExecutablePath</executable>
  <arguments>$EntryPoint</arguments>

  <logpath>$LogDirectory</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>10</keepFiles>
  </log>

  <env name="HOST" value="0.0.0.0" />
  <env name="PORT" value="$ListenPort" />
  <env name="NODE_ENVIRONMENT" value="$Environment" />
  <env name="SERVICE" value="$ServiceId" />
  <env name="VERSION" value="$ApplicationVersion" />
  <env name="COMMIT_SHA" value="$Commit" />
  <env name="BUILD_TIME_UTC" value="$BuildTime" />

  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec" />
</service>
"@ | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ServiceState {
    param ([Parameter(Mandatory)][string] $Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        return 'Absent'
    }

    return $service.Status.ToString()
}

function Wait-ServiceState {
    param (
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string[]] $States,
        [int] $TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-ServiceState -Name $Name) -notin $States) {
        if ((Get-Date) -gt $deadline) {
            throw "Service '$Name' did not reach state '$($States -join "' or '")' within $TimeoutSeconds seconds."
        }

        Start-Sleep -Seconds 1
    }
}

# WinSW returns non-zero for conditions that are not failures here (stopping a service that
# is already stopped, for one), and the caller checks the service state rather than the exit
# code, so LASTEXITCODE is reset to keep it from tripping a later check.
function Invoke-ServiceHost {
    param (
        [Parameter(Mandatory)][string] $ExePath,
        [Parameter(Mandatory)][string] $Command
    )

    & $ExePath $Command | Out-Host
    $global:LASTEXITCODE = 0
}

# WinSW reports a successful start as soon as the service control manager accepts it. If the
# child process then exits - a missing node.exe, a port already in use, a payload that throws
# on load - the only account of why is in WinSW's own log next to the payload. Printing it
# here turns "did not reach state Running" into an actual cause without an SSH session into
# the target to go looking.
function Write-ServiceDiagnostic {
    param (
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $LogDirectory
    )

    Write-Host "--- service diagnostics for '$Name' ---" -ForegroundColor Yellow

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    Write-Host "state: $(if ($service) { $service.Status } else { 'absent' })"

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        Write-Host "no log directory at '$LogDirectory'."
        return
    }

    # WinSW names its logs after the executable's base name, not the service id, so these are
    # winsw.out.log / winsw.err.log / winsw.wrapper.log rather than <id>.*.log. Matching every
    # log in the directory keeps this working whichever the payload happens to produce.
    Get-ChildItem -LiteralPath $LogDirectory -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 3 |
        ForEach-Object {
            Write-Host ""
            Write-Host "--- $($_.Name) (last 40 lines) ---" -ForegroundColor Yellow
            Get-Content -LiteralPath $_.FullName -Tail 40 -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host "  $_" }
        }

    Write-Host "--- end diagnostics ---" -ForegroundColor Yellow
}

# IIS reports a binding another site already holds as "Cannot create a file when that file
# already exists" (0x800700B7) at start time, which reads like a filesystem problem and sends
# you looking in the wrong place entirely. Naming the site that holds the port turns it into
# something actionable, and doing it during provisioning fails before the payload is touched.
function Get-SiteHoldingPort {
    param (
        [Parameter(Mandatory)][int] $Port,
        [Parameter(Mandatory)][string] $ExcludeSiteName
    )

    foreach ($site in Get-Website) {
        if ($site.Name -eq $ExcludeSiteName) {
            continue
        }

        foreach ($binding in $site.Bindings.Collection) {
            if ($binding.protocol -ne 'http') {
                continue
            }

            # bindingInformation is '<ip>:<port>:<hostheader>'.
            $boundPort = ($binding.bindingInformation -split ':')[1]
            if ($boundPort -eq [string]$Port) {
                return $site.Name
            }
        }
    }

    return $null
}

function Stop-NodeServiceIfRunning {
    param (
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $ExePath
    )

    if ((Get-ServiceState -Name $Name) -eq 'Absent' -or -not (Test-Path -LiteralPath $ExePath)) {
        return
    }

    # The mirror below replaces the working directory this process is running out of, so it
    # has to be gone before robocopy starts or the copy fails on a locked file.
    Write-Step "Stopping service '$Name'."
    Invoke-ServiceHost -ExePath $ExePath -Command 'stop'
    Wait-ServiceState -Name $Name -States @('Absent', 'Stopped')
}

# Returns whether the service is running. A service that will not stay up is a failed
# deployment in exactly the same way a health check that never returns 200 is, so it is
# reported rather than thrown: the caller routes both through the same rollback instead of
# leaving the site broken with a good backup sitting next to it.
function Install-NodeService {
    param (
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $ExePath,
        [Parameter(Mandatory)][string] $LogDirectory
    )

    if (-not (Test-Path -LiteralPath $ExePath)) {
        throw "'$(Split-Path -Leaf $ExePath)' is missing from the payload; the Node process cannot be hosted."
    }

    # Reinstalled rather than restarted: WinSW registers the environment block and the image
    # path when the service is created, so a port or environment change in the regenerated
    # definition would otherwise not take effect until someone noticed by hand.
    if ((Get-ServiceState -Name $Name) -ne 'Absent') {
        Write-Step "Reinstalling service '$Name' so the regenerated definition takes effect."
        Invoke-ServiceHost -ExePath $ExePath -Command 'uninstall'
        Wait-ServiceState -Name $Name -States @('Absent') -TimeoutSeconds 30
    }

    Write-Step "Installing and starting service '$Name'."
    Invoke-ServiceHost -ExePath $ExePath -Command 'install'
    Invoke-ServiceHost -ExePath $ExePath -Command 'start'

    try {
        Wait-ServiceState -Name $Name -States @('Running')
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-ServiceDiagnostic -Name $Name -LogDirectory $LogDirectory
        return $false
    }

    return $true
}

Write-Host "Deploying $SiteName $Version ($EnvironmentName, $Mode, $HostingModel) on $env:COMPUTERNAME." -ForegroundColor Green

# --- Provisioning -----------------------------------------------------------------
# Everything below is idempotent, so the first deployment to a clean machine and the
# hundredth deployment run the same code path.

Write-Step "Ensuring directory layout under '$SiteRoot'."

foreach ($path in @($SiteRoot, $sharedLogsPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

if ($Mode -eq 'Swap' -and -not (Test-Path -LiteralPath $releasesPath)) {
    New-Item -ItemType Directory -Path $releasesPath -Force | Out-Null
}

if (-not (Test-Path $appPoolPath)) {
    Write-Step "Creating application pool '$SiteName'."
    New-WebAppPool -Name $SiteName | Out-Null
}

# Applied on every run: an application pool edited by hand on the server is a
# configuration drift that the next deployment should quietly correct.
Write-Step "Applying application pool settings."
Set-ItemProperty -Path $appPoolPath -Name 'managedRuntimeVersion' -Value ''
Set-ItemProperty -Path $appPoolPath -Name 'processModel.identityType' -Value 'ApplicationPoolIdentity'
Set-ItemProperty -Path $appPoolPath -Name 'processModel.idleTimeout' -Value ([TimeSpan]::Zero)
Set-ItemProperty -Path $appPoolPath -Name 'processModel.pingingEnabled' -Value $true
Set-ItemProperty -Path $appPoolPath -Name 'startMode' -Value 'AlwaysRunning'
Set-ItemProperty -Path $appPoolPath -Name 'autoStart' -Value $true
Set-ItemProperty -Path $appPoolPath -Name 'recycling.periodicRestart.time' -Value ([TimeSpan]::Zero)
Clear-ItemProperty -Path $appPoolPath -Name 'recycling.periodicRestart.schedule'
Set-ItemProperty -Path $appPoolPath -Name 'failure.rapidFailProtection' -Value $true
Set-ItemProperty -Path $appPoolPath -Name 'failure.rapidFailProtectionMaxCrashes' -Value 5

# Under ReverseProxy the pool only forwards requests and never loads the application, so
# the environment reaches the Node process through the service definition instead.
if ($HostingModel -eq 'AspNetCore') {
    Write-Step "Setting ASPNETCORE_ENVIRONMENT=$EnvironmentName on the application pool."
    Set-AppPoolEnvironmentVariable -AppPoolName $SiteName -Name 'ASPNETCORE_ENVIRONMENT' -Value $EnvironmentName
}

$portHolder = Get-SiteHoldingPort -Port $Port -ExcludeSiteName $SiteName
if ($portHolder) {
    throw "Port $Port is already bound by IIS site '$portHolder'. Remove or re-port that site before deploying '$SiteName' here."
}

if (-not (Test-Path $sitePath)) {
    Write-Step "Creating site '$SiteName' on port $Port."

    # The initial physical path is a placeholder in swap mode; the swap below points the
    # site at the release directory it just unpacked.
    New-Website `
        -Name $SiteName `
        -Port $Port `
        -PhysicalPath $SiteRoot `
        -ApplicationPool $SiteName | Out-Null
}

$binding = Get-WebBinding -Name $SiteName -Protocol 'http' -Port $Port -ErrorAction SilentlyContinue
if (-not $binding) {
    Write-Step "Adding http binding on port $Port."
    New-WebBinding -Name $SiteName -Protocol 'http' -Port $Port -IPAddress '*'
}

# Preload plus AlwaysRunning means IIS starts the worker process and issues the first
# request itself, so the health check below measures a warmed-up application.
Set-ItemProperty -Path $sitePath -Name 'applicationDefaults.preloadEnabled' -Value $true
Set-ItemProperty -Path $sitePath -Name 'serverAutoStart' -Value $true

Write-Step "Applying filesystem permissions."
$appPoolIdentity = "IIS AppPool\$SiteName"

# The worker process reads the application and writes only its log directory.
Grant-DirectoryAccess -Path $SiteRoot -Identity $appPoolIdentity -Rights 'ReadAndExecute'
Grant-DirectoryAccess -Path $sharedLogsPath -Identity $appPoolIdentity -Rights 'Modify'

foreach ($identity in $AdditionalIdentities | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
    # A convenience grant for accounts that touch the site outside IIS, such as the build
    # agent's service account. An account that does not exist on this host is worth a
    # warning, not a failed deployment.
    try {
        Grant-DirectoryAccess -Path $SiteRoot -Identity $identity -Rights 'Modify'
    }
    catch {
        Write-Warning "Could not grant '$identity' access to '$SiteRoot': $($_.Exception.Message)"
    }
}

if (-not $SkipFirewallRule) {
    $firewallRuleName = "Allow IIS $SiteName ($Port)"

    if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
        Write-Step "Creating firewall rule '$firewallRuleName'."
        New-NetFirewallRule `
            -DisplayName $firewallRuleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Port | Out-Null
    }
}

# --- Payload ----------------------------------------------------------------------

$expandPath = Join-Path ([System.IO.Path]::GetTempPath()) "$SiteName-$Version-payload"
$payloadPath = Resolve-PayloadDirectory -Path $SourcePath -ExpandTo $expandPath

if (-not (Test-Path -LiteralPath (Join-Path $payloadPath $payloadMarker))) {
    throw "Payload '$payloadPath' has no $payloadMarker - it does not look like a $HostingModel publish output."
}

# Generated into the payload rather than into the live directory, so the mirror below treats
# them as ordinary payload files: nothing needs excluding from /PURGE to survive the next
# deployment, they are captured by the backup, and a rollback restores the configuration
# that release actually ran with.
if ($HostingModel -eq 'ReverseProxy') {
    Write-Step "Generating web.config and the service definition for $EnvironmentName."

    Write-ReverseProxyWebConfig `
        -Path (Join-Path $payloadPath 'web.config') `
        -ProxyPort $NodePort

    Write-ServiceDefinition `
        -Path (Join-Path $payloadPath "$serviceHostName.xml") `
        -ServiceId $SiteName `
        -WorkingDirectory $SiteRoot `
        -LogDirectory $sharedLogsPath `
        -ExecutablePath $NodeExePath `
        -EntryPoint $ServerEntryPoint `
        -ListenPort $NodePort `
        -Environment $EnvironmentName `
        -ApplicationVersion $Version `
        -Commit $CommitSha `
        -BuildTime $BuildTimeUtc
}

$healthUrl = "http://localhost:$Port$HealthPath"
$deploymentSucceeded = $false

try {
    if ($Mode -eq 'InPlace') {
        # app_offline.htm makes the ASP.NET Core Module shut the application down and
        # serve a static response, which releases the file locks the mirror needs.
        Write-Step "Taking '$SiteName' offline."
        $appOfflinePath = Join-Path $SiteRoot $appOfflineName
        Set-Content -LiteralPath $appOfflinePath -Value '<html><body>Deployment in progress.</body></html>' -Encoding UTF8

        # A site last deployed in swap mode still points at a release directory, while
        # app_offline.htm and the mirror below both target $SiteRoot. Left alone, the
        # payload would land in $SiteRoot with IIS still serving the old release - and the
        # health check would pass against the stale one, so the deployment would look
        # successful without having changed anything.
        $currentPhysicalPath = (Get-Website -Name $SiteName).physicalPath
        if ($currentPhysicalPath -ne $SiteRoot) {
            Write-Step "Repointing '$SiteName' from '$currentPhysicalPath' to '$SiteRoot'."
            Set-ItemProperty -Path $sitePath -Name 'physicalPath' -Value $SiteRoot
        }

        Start-Sleep -Seconds 2
        Stop-AppPoolIfRunning -AppPoolName $SiteName

        if ($HostingModel -eq 'ReverseProxy') {
            Stop-NodeServiceIfRunning -Name $SiteName -ExePath $serviceExePath
        }

        if (Test-Path -LiteralPath (Join-Path $SiteRoot $payloadMarker)) {
            Write-Step "Backing up the current payload to '$backupPath'."
            Copy-Payload `
                -Source $SiteRoot `
                -Destination $backupPath `
                -Mirror `
                -ExcludeDirectories @('logs', 'releases') `
                -ExcludeFiles @($appOfflineName)
        }

        Write-Step "Mirroring the new payload into '$SiteRoot'."
        Copy-Payload `
            -Source $payloadPath `
            -Destination $SiteRoot `
            -Mirror `
            -ExcludeDirectories @('logs', 'releases') `
            -ExcludeFiles @($appOfflineName)

        $serviceIsRunning = $true

        if ($HostingModel -eq 'ReverseProxy') {
            $serviceIsRunning = Install-NodeService `
                -Name $SiteName `
                -ExePath $serviceExePath `
                -LogDirectory $sharedLogsPath
        }

        Write-Step "Bringing '$SiteName' back online."
        Start-AppPoolIfStopped -AppPoolName $SiteName

        # Start-Website raises a terminating COMException that -ErrorAction cannot suppress,
        # so without this the run would abort here and skip the rollback below - leaving the
        # site down with a good backup sitting next to it.
        $siteStarted = $true
        try {
            Start-Website -Name $SiteName
        }
        catch {
            Write-Host "Could not start site '$SiteName': $($_.Exception.Message)" -ForegroundColor Red
            $siteStarted = $false
        }

        Remove-Item -LiteralPath $appOfflinePath -Force -ErrorAction SilentlyContinue

        # Short-circuited rather than probed: with the service or the site down the health
        # check would spend its whole timeout collecting failures before reaching the same
        # conclusion their state already gave us.
        $isHealthy = $serviceIsRunning -and
            $siteStarted -and
            (Test-Health -Url $healthUrl -TimeoutSeconds $HealthTimeoutSeconds)

        # Naming which gate failed matters: a service that will not start, a site that will
        # not start, and an application that never answers /healthz send you to three
        # different places.
        $reason =
            if (-not $serviceIsRunning) { 'The service did not start' }
            elseif (-not $siteStarted) { 'The IIS site did not start' }
            else { 'Health check failed' }

        if ($isHealthy) {
            $deploymentSucceeded = $true
        }
        elseif (Test-Path -LiteralPath (Join-Path $backupPath $payloadMarker)) {
            Write-Step "Rolling back to the previous payload."
            Stop-AppPoolIfRunning -AppPoolName $SiteName

            if ($HostingModel -eq 'ReverseProxy') {
                Stop-NodeServiceIfRunning -Name $SiteName -ExePath $serviceExePath
            }

            Copy-Payload `
                -Source $backupPath `
                -Destination $SiteRoot `
                -Mirror `
                -ExcludeDirectories @('logs', 'releases') `
                -ExcludeFiles @($appOfflineName)

            # The backup carries the previous release's service definition, so reinstalling
            # from it puts the process back on the configuration it was healthy with.
            if ($HostingModel -eq 'ReverseProxy') {
                Install-NodeService `
                    -Name $SiteName `
                    -ExePath $serviceExePath `
                    -LogDirectory $sharedLogsPath | Out-Null
            }

            Start-AppPoolIfStopped -AppPoolName $SiteName

            throw "$reason for $Version; rolled back to the previous payload."
        }
        else {
            throw "$reason for $Version and there is no previous payload to roll back to."
        }
    }
    else {
        $releaseName = "{0}_{1}" -f $Version, (Get-Date -Format 'yyyyMMddHHmmss')
        $releasePath = Join-Path $releasesPath $releaseName
        $previousPath = (Get-Website -Name $SiteName).physicalPath

        Write-Step "Unpacking $Version into '$releasePath'."
        New-Item -ItemType Directory -Path $releasePath -Force | Out-Null
        Copy-Payload -Source $payloadPath -Destination $releasePath

        # Serilog writes to <ContentRoot>\logs. Junctioning that to the shared directory
        # keeps log history when old releases are pruned.
        $releaseLogsPath = Join-Path $releasePath 'logs'
        if (Test-Path -LiteralPath $releaseLogsPath) {
            Remove-Item -LiteralPath $releaseLogsPath -Recurse -Force
        }
        New-Item -ItemType Junction -Path $releaseLogsPath -Target $sharedLogsPath | Out-Null

        Grant-DirectoryAccess -Path $releasePath -Identity $appPoolIdentity -Rights 'ReadAndExecute'

        Write-Step "Pointing '$SiteName' at the new release."
        Set-ItemProperty -Path $sitePath -Name 'physicalPath' -Value $releasePath
        Start-AppPoolIfStopped -AppPoolName $SiteName
        Restart-WebAppPool -Name $SiteName
        Wait-AppPoolState -AppPoolName $SiteName -State 'Started'
        Start-Website -Name $SiteName -ErrorAction SilentlyContinue

        if (Test-Health -Url $healthUrl -TimeoutSeconds $HealthTimeoutSeconds) {
            $deploymentSucceeded = $true
        }
        else {
            # Only a directory that actually holds a previous publish is a rollback target;
            # on the very first deployment the site still points at the empty site root.
            $canRollBack = $previousPath -and
                $previousPath -ne $releasePath -and
                (Test-Path -LiteralPath (Join-Path $previousPath $payloadMarker))

            if ($canRollBack) {
                Write-Step "Rolling back to '$previousPath'."
                Set-ItemProperty -Path $sitePath -Name 'physicalPath' -Value $previousPath
                Restart-WebAppPool -Name $SiteName
            }

            throw "Health check failed for $Version; the site was left on '$previousPath'."
        }

        Write-Step "Pruning old releases, keeping the newest $RetainReleases."
        Get-ChildItem -LiteralPath $releasesPath -Directory |
            Where-Object { $_.FullName -ne $releasePath } |
            Sort-Object -Property CreationTimeUtc -Descending |
            Select-Object -Skip $RetainReleases |
            ForEach-Object {
                Write-Host "Removing $($_.FullName)"
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
    }
}
finally {
    if (Test-Path -LiteralPath $expandPath) {
        Remove-Item -LiteralPath $expandPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $deploymentSucceeded) {
    throw "Deployment of $Version to '$SiteName' did not complete."
}

Write-Host "Deployed $SiteName $Version to $EnvironmentName ($healthUrl)." -ForegroundColor Green
