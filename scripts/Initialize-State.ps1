param([switch]$Force, [switch]$SkipTrust)
. (Join-Path $PSScriptRoot 'Common.ps1')

New-Item -ItemType Directory -Force -Path (Get-StateDir) | Out-Null
$certDir = Join-Path (Get-StateDir) 'certs'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null

$defaults = Read-EnvFile -Path (Join-Path (Get-RepoRoot) '.env.example')
$stateExists = Test-Path -LiteralPath $script:ConfigPath
$config = if ($stateExists -and -not $Force) { Read-EnvFile -Path $script:ConfigPath } else { $defaults }
$changed = -not $stateExists -or $Force

foreach ($key in $defaults.Keys) {
    if (-not $config.ContainsKey($key) -or -not $config[$key]) {
        $config[$key] = $defaults[$key]
        $changed = $true
    }
}

if (-not $stateExists -or $Force) {
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
}
if (-not $config.ContainsKey('QGIS_PASSWORD') -or -not $config.QGIS_PASSWORD) {
    $config.QGIS_PASSWORD = New-RandomSecret -Bytes 18
    $changed = $true
}
if (-not $config.ContainsKey('PGADMIN_PASSWORD') -or -not $config.PGADMIN_PASSWORD) {
    $config.PGADMIN_PASSWORD = New-RandomSecret -Bytes 18
    $changed = $true
}
$config.STATE_DIR = Convert-ToForwardSlashPath (Get-StateDir)
if ($changed) { Write-EnvFile -Values $config -Path $script:ConfigPath }

$openssl = Get-OpenSslPath
$caKey = Join-Path $certDir 'ca.key'
$caCert = Join-Path $certDir 'ca.crt'
$serverKey = Join-Path $certDir 'server.key'
$serverCsr = Join-Path $certDir 'server.csr'
$serverCert = Join-Path $certDir 'server.crt'
$serial = Join-Path $certDir 'ca.srl'
$opensslConfig = Join-Path $certDir 'openssl.cnf'
$configText = @"
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
DNS.1 = $($config.RANCHER_HOSTNAME)
DNS.2 = $($config.MAPS_HOSTNAME)
DNS.3 = $($config.QGIS_HOSTNAME)
DNS.4 = $($config.PGADMIN_HOSTNAME)
DNS.5 = jcr.localhost
DNS.6 = jcr-proxy
DNS.7 = host.k3d.internal
DNS.8 = localhost
IP.1 = 127.0.0.1
"@
Set-FileUtf8NoBom -Path $opensslConfig -Content $configText

$newCa = $Force -or -not (Test-Path -LiteralPath $caCert) -or -not (Test-Path -LiteralPath $caKey)
if ($newCa) {
    Invoke-Native $openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -subj '/CN=GeoServer Airgap Development CA/O=GeoServer Airgap Simulation' -keyout $caKey -out $caCert
}

$certificateNames = if (Test-Path -LiteralPath $serverCert) { (& $openssl x509 -in $serverCert -noout -ext subjectAltName 2>$null) -join "`n" } else { '' }
$needsServerCertificate = $Force -or -not (Test-Path -LiteralPath $serverKey) -or -not (Test-Path -LiteralPath $serverCert) -or $certificateNames -notmatch [regex]::Escape($config.QGIS_HOSTNAME) -or $certificateNames -notmatch [regex]::Escape($config.PGADMIN_HOSTNAME)
if ($needsServerCertificate) {
    Invoke-Native $openssl req -new -newkey rsa:2048 -nodes -keyout $serverKey -out $serverCsr -config $opensslConfig
    if (Test-Path -LiteralPath $serial) {
        Invoke-Native $openssl x509 -req -in $serverCsr -CA $caCert -CAkey $caKey -CAserial $serial -out $serverCert -days 825 -sha256 -extensions req_ext -extfile $opensslConfig
    } else {
        Invoke-Native $openssl x509 -req -in $serverCsr -CA $caCert -CAkey $caKey -CAcreateserial -CAserial $serial -out $serverCert -days 825 -sha256 -extensions req_ext -extfile $opensslConfig
    }
}

if ($newCa -and -not $SkipTrust) {
    & certutil.exe -user -addstore Root $caCert | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not add the development CA to the current user trust store.' }
}

Write-Host "Generated state: $script:ConfigPath"
Write-Host "Development CA: $caCert"
Write-Host ('QGIS browser password is stored in ' + $script:ConfigPath)
Write-Host ('pgAdmin browser password is stored in ' + $script:ConfigPath)
