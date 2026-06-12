param([switch]$Force, [switch]$SkipTrust)
. (Join-Path $PSScriptRoot 'Common.ps1')

New-Item -ItemType Directory -Force -Path (Get-StateDir) | Out-Null
$certDir = Join-Path (Get-StateDir) 'certs'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null

if ((Test-Path -LiteralPath $script:ConfigPath) -and -not $Force) {
    Write-Host 'State already exists. Use -Force to regenerate secrets and certificates.'
    exit 0
}

$config = Read-EnvFile -Path (Join-Path (Get-RepoRoot) '.env.example')
$config.JCR_USERNAME = 'admin'
$config.JCR_PASSWORD = New-RandomSecret
$config.JCR_ADMIN_USERNAME = 'admin'
$config.JCR_INITIAL_ADMIN_PASSWORD = 'password'
$config.JCR_MASTER_KEY = New-HexSecret
$config.JCR_JOIN_KEY = New-HexSecret
$config.JCR_DB_USERNAME = 'artifactory'
$config.JCR_DB_PASSWORD = New-RandomSecret
$config.RANCHER_BOOTSTRAP_PASSWORD = New-RandomSecret
$config.RABBITMQ_USERNAME = 'geoserver'
$config.RABBITMQ_PASSWORD = New-RandomSecret
$config.RABBITMQ_ERLANG_COOKIE = New-RandomSecret -Bytes 32
$config.POSTGRES_SUPER_USERNAME = 'postgres'
$config.POSTGRES_SUPER_PASSWORD = New-RandomSecret
$config.GEOSERVER_DB_USERNAME = 'geoserver'
$config.GEOSERVER_DB_PASSWORD = New-RandomSecret
$config.GEOSERVER_ADMIN_USERNAME = 'admin'
$config.GEOSERVER_ADMIN_PASSWORD = New-RandomSecret
$config.STATE_DIR = Convert-ToForwardSlashPath (Get-StateDir)
Write-EnvFile -Values $config -Path $script:ConfigPath

$openssl = Get-OpenSslPath
$caKey = Join-Path $certDir 'ca.key'
$caCert = Join-Path $certDir 'ca.crt'
$serverKey = Join-Path $certDir 'server.key'
$serverCsr = Join-Path $certDir 'server.csr'
$serverCert = Join-Path $certDir 'server.crt'
$serial = Join-Path $certDir 'ca.srl'
$opensslConfig = Join-Path $certDir 'openssl.cnf'
$configText = @'
[req]
distinguished_name = dn
prompt = no
req_extensions = req_ext

[dn]
CN = GeoServer Airgap Local Endpoints
O = GeoServer Airgap Simulation

[req_ext]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = rancher.localhost
DNS.2 = maps.localhost
DNS.3 = jcr.localhost
DNS.4 = jcr-proxy
DNS.5 = host.k3d.internal
DNS.6 = localhost
IP.1 = 127.0.0.1
'@
Set-FileUtf8NoBom -Path $opensslConfig -Content $configText

Invoke-Native $openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -subj '/CN=GeoServer Airgap Development CA/O=GeoServer Airgap Simulation' -keyout $caKey -out $caCert
Invoke-Native $openssl req -new -newkey rsa:2048 -nodes -keyout $serverKey -out $serverCsr -config $opensslConfig
Invoke-Native $openssl x509 -req -in $serverCsr -CA $caCert -CAkey $caKey -CAcreateserial -CAserial $serial -out $serverCert -days 825 -sha256 -extensions req_ext -extfile $opensslConfig

if (-not $SkipTrust) {
    & certutil.exe -user -addstore Root $caCert | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not add the development CA to the current user trust store.' }
}

Write-Host "Generated state: $script:ConfigPath"
Write-Host "Development CA: $caCert"
