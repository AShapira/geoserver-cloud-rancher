param([switch]$Recreate)
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-Path -LiteralPath $script:ConfigPath)) { & (Join-Path $PSScriptRoot 'Initialize-State.ps1') }
$config = Get-Config

if (-not $config.ContainsKey('JCR_MASTER_KEY')) {
    $config.JCR_MASTER_KEY = New-HexSecret
    $config.JCR_JOIN_KEY = New-HexSecret
    Write-EnvFile -Values $config -Path $script:ConfigPath
}
if (-not $config.ContainsKey('JCR_DB_PASSWORD')) {
    $config.JCR_DB_USERNAME = 'artifactory'
    $config.JCR_DB_PASSWORD = New-RandomSecret
    Write-EnvFile -Values $config -Path $script:ConfigPath
}
if (-not $config.ContainsKey('JCR_DOCKER_HOST')) {
    $config.JCR_DOCKER_HOST = 'localhost:5443'
    Write-EnvFile -Values $config -Path $script:ConfigPath
}
$securityDir = Join-Path (Get-StateDir) 'jcr\etc\security'
New-Item -ItemType Directory -Force -Path $securityDir | Out-Null
Set-FileUtf8NoBom -Path (Join-Path $securityDir 'master.key') -Content $config.JCR_MASTER_KEY
Set-FileUtf8NoBom -Path (Join-Path $securityDir 'join.key') -Content $config.JCR_JOIN_KEY
$systemYaml = @"
shared:
  database:
    type: postgresql
    driver: org.postgresql.Driver
    url: jdbc:postgresql://jcr-db:5432/artifactory
    username: $($config.JCR_DB_USERNAME)
    password: $($config.JCR_DB_PASSWORD)
"@
Set-FileUtf8NoBom -Path (Join-Path (Get-StateDir) 'jcr\etc\system.yaml') -Content $systemYaml

Ensure-DockerNetwork -Name $config.AIRGAP_BOOTSTRAP_NETWORK
Ensure-DockerNetwork -Name $config.AIRGAP_RUNTIME_NETWORK -Internal

$compose = Join-Path (Get-RepoRoot) 'infra\jcr\docker-compose.yml'
$args = @('compose', '--env-file', $script:ConfigPath, '-f', $compose, 'up', '-d')
if ($Recreate) { $args += '--force-recreate' }
Invoke-Native docker @args

$ca = Join-Path (Get-StateDir) 'certs\ca.crt'
$baseUrl = 'https://' + $config.JCR_EXTERNAL_HOST
$bootstrapCredentials = $config.JCR_ADMIN_USERNAME + ':' + $config.JCR_INITIAL_ADMIN_PASSWORD
$runtimeCredentials = $config.JCR_ADMIN_USERNAME + ':' + $config.JCR_PASSWORD
Write-Host 'Waiting for JCR. First startup can take several minutes.'
try {
    Wait-ForUrl -Url ($baseUrl + '/artifactory/api/system/ping') -CaCert $ca -TimeoutSeconds 30 -UserPassword $runtimeCredentials
    $adminCredentials = $runtimeCredentials
} catch {
    Wait-ForUrl -Url ($baseUrl + '/artifactory/api/system/ping') -CaCert $ca -TimeoutSeconds 900 -UserPassword $bootstrapCredentials
    $adminCredentials = $bootstrapCredentials
}

$apiDir = Join-Path (Get-StateDir) 'jcr-api'
New-Item -ItemType Directory -Force -Path $apiDir | Out-Null

function Invoke-JcrRequest {
    param(
        [string]$Method,
        [string]$Path,
        [string]$ContentType = 'application/json',
        [string]$Body = ''
    )
    $payload = $null
    if ($Body) {
        $payload = Join-Path $apiDir (([Guid]::NewGuid().ToString()) + '.payload')
        Set-FileUtf8NoBom -Path $payload -Content $Body
    }
    try {
        $curlArgs = @('--silent', '--show-error', '--fail', '--ssl-no-revoke', '--cacert', $ca, '--user', $adminCredentials, '--request', $Method)
        if ($Body) { $curlArgs += @('--header', ('Content-Type: ' + $ContentType), '--data-binary', ('@' + $payload)) }
        $curlArgs += ($baseUrl + $Path)
        Invoke-Native curl.exe @curlArgs
    } finally {
        if ($payload) { Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue }
    }
}

if (-not (Test-NativeSuccess curl.exe --silent --show-error --fail --ssl-no-revoke --cacert $ca --user $adminCredentials --request POST ($baseUrl + '/artifactory/ui/jcr/eula/accept'))) {
    Write-Verbose 'JCR EULA was already accepted or does not require acceptance.'
}

$repositoriesYaml = @"
localRepositories:
  $($config.JCR_DOCKER_REPOSITORY):
    type: docker
    description: Air-gapped container images
    repoLayout: simple-default
  $($config.JCR_HELM_REPOSITORY):
    type: docker
    description: OCI Helm charts
    repoLayout: simple-default
"@
Invoke-JcrRequest -Method PATCH -Path '/artifactory/api/system/configuration' -ContentType 'application/yaml' -Body $repositoriesYaml

if ($adminCredentials -eq $bootstrapCredentials) {
    $passwordBody = @{
        userName = $config.JCR_ADMIN_USERNAME
        oldPassword = $config.JCR_INITIAL_ADMIN_PASSWORD
        newPassword1 = $config.JCR_PASSWORD
        newPassword2 = $config.JCR_PASSWORD
    } | ConvertTo-Json
    Invoke-JcrRequest -Method POST -Path '/artifactory/api/security/users/authorization/changePassword' -Body $passwordBody
    $adminCredentials = $runtimeCredentials
}

$config.JCR_USERNAME = $config.JCR_ADMIN_USERNAME
Write-EnvFile -Values $config -Path $script:ConfigPath

$dockerHost = Get-JcrClientHost -Config $config
$config.JCR_PASSWORD | docker login $dockerHost --username $config.JCR_USERNAME --password-stdin
if ($LASTEXITCODE -ne 0) { throw 'Docker login to JCR failed.' }
Write-Host ('JCR is ready at ' + $baseUrl)
