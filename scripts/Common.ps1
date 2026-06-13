Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:StateDir = Join-Path $script:RepoRoot '.state'
$script:ToolsDir = Join-Path $script:RepoRoot '.tools'
$script:ConfigPath = Join-Path $script:StateDir 'config.env'

$script:Versions = @{
    Helm = '3.20.2'
    K3d = '5.9.0'
    Rancher = '2.14.2'
    K3s = 'v1.35.5+k3s1'
    K3sDockerTag = 'v1.35.5-k3s1'
    GeoServerChart = '3.0.0-rc'
    GeoServerImage = '3.0.0-RC'
    JcrImage = 'releases-docker.jfrog.io/jfrog/artifactory-jcr@sha256:f7a6173eb6886a9ed0383c0008b93d9a1be11faf763d19785b45c550a922b8b5'
    JcrProxyImage = 'nginxinc/nginx-unprivileged:1.27-alpine'
    JcrDatabaseImage = 'postgres:16-alpine'
    PostgisImage = 'postgis/postgis:16-3.4'
    PgadminImage = 'dpage/pgadmin4:9.15@sha256:81ec1626582010444351d81b25413c362b3b15536d1f5f9414c5d9666e54badd'
    RabbitImage = 'rabbitmq:3.13.7-management-alpine'
    CurlImage = 'curlimages/curl:8.12.1'
    K6Image = 'grafana/k6:0.54.0'
    CanaryImage = 'busybox:1.37.0'
    QgisBaseImage = 'kasmweb/core-ubuntu-noble:1.17.0@sha256:eeaab79e401c3b70977afba2f7ec0d166e95547fdbca1d070905532a1af70f8c'
    PgStacImage = 'ghcr.io/stac-utils/pgstac:v0.9.11'
    StacApiImage = 'ghcr.io/stac-utils/stac-fastapi-pgstac:6.2.1'
    StacBrowserVersion = '4.0.1'
    GdalImage = 'ghcr.io/osgeo/gdal:ubuntu-small-3.11.4'
    PlatformInfraChartVersion = '0.3.0'
    GeoServerChartVersion = '0.3.0'
}

function Get-RepoRoot { return $script:RepoRoot }
function Get-StateDir { return $script:StateDir }
function Get-ToolsDir { return $script:ToolsDir }

function Read-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed.Split('=', 2)
        if ($parts.Count -eq 2) { $values[$parts[0]] = $parts[1] }
    }
    return $values
}

function Write-EnvFile {
    param([Parameter(Mandatory = $true)][hashtable]$Values, [Parameter(Mandatory = $true)][string]$Path)
    $lines = @()
    foreach ($key in ($Values.Keys | Sort-Object)) { $lines += ('{0}={1}' -f $key, $Values[$key]) }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $lines, $utf8)
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw 'Missing .state/config.env. Run scripts/Initialize-State.ps1 first.'
    }
    return Read-EnvFile -Path $script:ConfigPath
}

function New-RandomSecret {
    param([int]$Bytes = 24)
    $buffer = New-Object byte[] $Bytes
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($buffer).TrimEnd('=').Replace('+', 'A').Replace('/', 'B'))
}

function New-HexSecret {
    param([int]$Bytes = 32)
    $buffer = New-Object byte[] $Bytes
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return (($buffer | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-OpenSslPath {
    $command = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $gitOpenSsl = 'C:\Program Files\Git\usr\bin\openssl.exe'
    if (Test-Path -LiteralPath $gitOpenSsl) { return $gitOpenSsl }
    throw 'OpenSSL was not found. Install Git for Windows or add openssl.exe to PATH.'
}

function Get-HelmPath {
    $local = Join-Path $script:ToolsDir 'helm.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $command = Get-Command helm.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'Helm was not found. Run scripts/Install-Tools.ps1.'
}

function Get-K3dPath {
    $local = Join-Path $script:ToolsDir 'k3d.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $command = Get-Command k3d.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'k3d was not found. Run scripts/Install-Tools.ps1.'
}

function Invoke-Native {
    param([string]$FilePath)
    $nativeArguments = @($args)
    & $FilePath @nativeArguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $FilePath $($nativeArguments -join ' ')" }
}

function Test-NativeSuccess {
    param([string]$FilePath)
    $nativeArguments = @($args)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @nativeArguments *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Ensure-DockerNetwork {
    param([string]$Name, [switch]$Internal)
    if (Test-NativeSuccess docker network inspect $Name) { return }
    if ($Internal) { Invoke-Native docker network create --internal $Name }
    else { Invoke-Native docker network create $Name }
}

function Convert-ToForwardSlashPath {
    param([string]$Path)
    return ([System.IO.Path]::GetFullPath($Path) -replace '\\', '/')
}

function Get-ImageParts {
    param([Parameter(Mandatory = $true)][string]$Image)
    $source = $Image.Trim()
    $digest = ''
    if ($source.Contains('@')) {
        $split = $source.Split('@', 2)
        $source = $split[0]
        $digest = $split[1]
    }
    $lastSlash = $source.LastIndexOf('/')
    $lastColon = $source.LastIndexOf(':')
    $tag = 'latest'
    if ($lastColon -gt $lastSlash) {
        $tag = $source.Substring($lastColon + 1)
        $source = $source.Substring(0, $lastColon)
    }
    $segments = $source.Split('/')
    $registry = 'docker.io'
    $repository = $source
    if ($segments.Count -gt 1 -and ($segments[0].Contains('.') -or $segments[0].Contains(':') -or $segments[0] -eq 'localhost')) {
        $registry = $segments[0]
        $repository = ($segments[1..($segments.Count - 1)] -join '/')
    } elseif ($segments.Count -eq 1) {
        $repository = 'library/' + $segments[0]
    }
    return @{ Registry = $registry; Repository = $repository; Tag = $tag; Digest = $digest }
}

function Get-MirrorPath {
    param([Parameter(Mandatory = $true)][string]$Image)
    $parts = Get-ImageParts -Image $Image
    $path = $parts.Repository
    if ($parts.Registry -ne 'docker.io') { $path = $parts.Registry + '/' + $parts.Repository }
    return ('{0}:{1}' -f $path, $parts.Tag)
}

function Get-JcrPushImage {
    param([string]$SourceImage, [hashtable]$Config)
    return ('{0}/{1}/{2}' -f (Get-JcrClientHost -Config $Config), $Config.JCR_DOCKER_REPOSITORY, (Get-MirrorPath $SourceImage))
}

function Get-JcrClientHost {
    param([hashtable]$Config)
    if ($Config.ContainsKey('JCR_DOCKER_HOST') -and $Config.JCR_DOCKER_HOST) { return $Config.JCR_DOCKER_HOST }
    return $Config.JCR_EXTERNAL_HOST
}

function Get-JcrRuntimeImage {
    param([string]$SourceImage, [hashtable]$Config)
    return ('{0}/{1}/{2}' -f $Config.JCR_INTERNAL_HOST, $Config.JCR_DOCKER_REPOSITORY, (Get-MirrorPath $SourceImage))
}

function Wait-ForUrl {
    param([string]$Url, [string]$CaCert, [int]$TimeoutSeconds = 300, [string]$UserPassword = '')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $args = @('--silent', '--show-error', '--fail', '--max-time', '10')
        if ($CaCert) { $args += @('--ssl-no-revoke', '--cacert', $CaCert) }
        if ($UserPassword) { $args += @('--user', $UserPassword) }
        $args += $Url
        if (Test-NativeSuccess curl.exe @args) { return }
        Start-Sleep -Seconds 5
    }
    throw "Timed out waiting for $Url"
}

function Set-FileUtf8NoBom {
    param([string]$Path, [string]$Content)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}
