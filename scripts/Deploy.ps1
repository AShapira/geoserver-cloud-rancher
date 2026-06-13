param([switch]$Tuned, [switch]$EnableWmsHpa)
. (Join-Path $PSScriptRoot 'Common.ps1')

& (Join-Path $PSScriptRoot 'Initialize-State.ps1')
$config = Get-Config
$helm = Get-HelmPath
$ca = Join-Path (Get-StateDir) 'certs\ca.crt'
$cert = Join-Path (Get-StateDir) 'certs\server.crt'
$key = Join-Path (Get-StateDir) 'certs\server.key'

$config.JCR_PASSWORD | & $helm registry login (Get-JcrClientHost -Config $config) --username $config.JCR_USERNAME --password-stdin
if ($LASTEXITCODE -ne 0) { throw 'Helm registry login failed.' }

foreach ($namespace in @($config.PLATFORM_NAMESPACE, $config.GEOSERVER_NAMESPACE)) {
    kubectl create namespace $namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    $role = if ($namespace -eq $config.GEOSERVER_NAMESPACE) { 'geoserver' } else { 'platform' }
    kubectl label namespace $namespace airgap.geoserver/role=$role --overwrite | Out-Null
    kubectl -n $namespace create secret docker-registry jcr-credentials --docker-server=$($config.JCR_INTERNAL_HOST) --docker-username=$($config.JCR_USERNAME) --docker-password=$($config.JCR_PASSWORD) --dry-run=client -o yaml | kubectl apply -f - | Out-Null
}
kubectl -n $config.GEOSERVER_NAMESPACE create secret tls maps-tls --cert=$cert --key=$key --dry-run=client -o yaml | kubectl apply -f - | Out-Null
kubectl -n $config.GEOSERVER_NAMESPACE create secret tls qgis-tls --cert=$cert --key=$key --dry-run=client -o yaml | kubectl apply -f - | Out-Null
kubectl -n $config.PLATFORM_NAMESPACE create secret tls pgadmin-tls --cert=$cert --key=$key --dry-run=client -o yaml | kubectl apply -f - | Out-Null
kubectl -n $config.GEOSERVER_NAMESPACE create configmap airgap-ca --from-file=ca.crt=$ca --dry-run=client -o yaml | kubectl apply -f - | Out-Null

$infraArgs = @(
    'upgrade', '--install', 'platform', ('oci://' + (Get-JcrClientHost -Config $config) + '/' + $config.JCR_HELM_REPOSITORY + '/platform-infra'),
    '--version', $script:Versions.PlatformInfraChartVersion, '--namespace', $config.PLATFORM_NAMESPACE,
    '--set-string', ('images.pgadmin=' + (Get-JcrRuntimeImage -SourceImage $script:Versions.PgadminImage -Config $config)),
    '--set-string', ('images.pgstac=' + (Get-JcrRuntimeImage -SourceImage $script:Versions.PgStacImage -Config $config)),
    '--set-string', ('secrets.postgresSuperUsername=' + $config.POSTGRES_SUPER_USERNAME),
    '--set-string', ('secrets.postgresSuperPassword=' + $config.POSTGRES_SUPER_PASSWORD),
    '--set-string', ('secrets.geoserverUsername=' + $config.GEOSERVER_DB_USERNAME),
    '--set-string', ('secrets.geoserverPassword=' + $config.GEOSERVER_DB_PASSWORD),
    '--set-string', ('secrets.rabbitmqUsername=' + $config.RABBITMQ_USERNAME),
    '--set-string', ('secrets.rabbitmqPassword=' + $config.RABBITMQ_PASSWORD),
    '--set-string', ('secrets.rabbitmqErlangCookie=' + $config.RABBITMQ_ERLANG_COOKIE),
    '--set-string', ('secrets.pgadminPassword=' + $config.PGADMIN_PASSWORD),
    '--set-string', ('secrets.stacUsername=' + $config.STAC_DB_USERNAME),
    '--set-string', ('secrets.stacPassword=' + $config.STAC_DB_PASSWORD),
    '--set-string', ('pgadmin.host=' + $config.PGADMIN_HOSTNAME),
    '--set-string', ('pgadmin.email=' + $config.PGADMIN_DEFAULT_EMAIL),
    '--wait', '--timeout', '10m'
)
Invoke-Native $helm @infraArgs

$geoArgs = @(
    'upgrade', '--install', 'gscloud', ('oci://' + (Get-JcrClientHost -Config $config) + '/' + $config.JCR_HELM_REPOSITORY + '/geoserver-cloud-sim'),
    '--version', $script:Versions.GeoServerChartVersion, '--namespace', $config.GEOSERVER_NAMESPACE,
    '--set-string', ('runtimeSecrets.rabbitmqUsername=' + $config.RABBITMQ_USERNAME),
    '--set-string', ('runtimeSecrets.rabbitmqPassword=' + $config.RABBITMQ_PASSWORD),
    '--set-string', ('runtimeSecrets.pgconfigUsername=' + $config.GEOSERVER_DB_USERNAME),
    '--set-string', ('runtimeSecrets.pgconfigPassword=' + $config.GEOSERVER_DB_PASSWORD),
    '--set-string', ('runtimeSecrets.geoserverAdminUsername=' + $config.GEOSERVER_ADMIN_USERNAME),
    '--set-string', ('runtimeSecrets.geoserverAdminPassword=' + $config.GEOSERVER_ADMIN_PASSWORD),
    '--set-string', ('runtimeSecrets.qgisPassword=' + $config.QGIS_PASSWORD),
    '--set-string', ('runtimeSecrets.stacUsername=' + $config.STAC_DB_USERNAME),
    '--set-string', ('runtimeSecrets.stacPassword=' + $config.STAC_DB_PASSWORD),
    '--set-string', ('qgis.host=' + $config.QGIS_HOSTNAME),
    '--set-string', ('qgis.image=' + $config.JCR_INTERNAL_HOST + '/' + $config.JCR_DOCKER_REPOSITORY + '/' + $config.QGIS_IMAGE_NAME + ':' + $config.QGIS_IMAGE_TAG),
    '--set-string', ('stac.host=' + $config.MAPS_HOSTNAME),
    '--set-string', ('stac.apiImage=' + (Get-JcrRuntimeImage -SourceImage $script:Versions.StacApiImage -Config $config)),
    '--set-string', ('stac.browserImage=' + $config.JCR_INTERNAL_HOST + '/' + $config.JCR_DOCKER_REPOSITORY + '/' + $config.STAC_BROWSER_IMAGE_NAME + ':' + $config.STAC_BROWSER_IMAGE_TAG),
    '--set-string', ('publisher.image=' + $config.JCR_INTERNAL_HOST + '/' + $config.JCR_DOCKER_REPOSITORY + '/' + $config.PUBLISHER_IMAGE_NAME + ':' + $config.PUBLISHER_IMAGE_TAG),
    '--set-string', ('publisher.publicBaseUrl=https://' + $config.MAPS_HOSTNAME)
)
if ($Tuned) { $geoArgs += @('--values', (Join-Path (Get-RepoRoot) 'charts\geoserver-cloud-sim\values-tuning.yaml')) }
if ($EnableWmsHpa) { $geoArgs += @('--set', 'geoservercloud.geoserver.services.wms.hpa.enabled=true') }
$geoArgs += @('--wait', '--timeout', '20m')
Invoke-Native $helm @geoArgs

& (Join-Path $PSScriptRoot 'Register-RancherCatalog.ps1')
Write-Host ('Viewer: https://' + $config.MAPS_HOSTNAME)
Write-Host ('STAC Browser: https://' + $config.MAPS_HOSTNAME + '/stac/')
Write-Host ('QGIS: https://' + $config.QGIS_HOSTNAME + ' (user: kasm_user)')
Write-Host ('pgAdmin: https://' + $config.PGADMIN_HOSTNAME + ' (user: ' + $config.PGADMIN_DEFAULT_EMAIL + ')')
