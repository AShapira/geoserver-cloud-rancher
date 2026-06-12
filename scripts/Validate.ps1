param([switch]$Deep)
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$ca = Join-Path (Get-StateDir) 'certs\ca.crt'
$base = 'https://' + $config.MAPS_HOSTNAME + '/geoserver-cloud'
$auth = $config.GEOSERVER_ADMIN_USERNAME + ':' + $config.GEOSERVER_ADMIN_PASSWORD
$out = Join-Path (Get-StateDir) 'validation'
New-Item -ItemType Directory -Force -Path $out | Out-Null
kubectl -n $config.GEOSERVER_NAMESPACE delete pod propagation-probe --ignore-not-found | Out-Null

$deadline = (Get-Date).AddMinutes(10)
do {
    $pending = New-Object System.Collections.Generic.List[string]
    $pods = (kubectl get pods --all-namespaces -o json | ConvertFrom-Json).items
    foreach ($pod in $pods) {
        if ($pod.status.phase -eq 'Failed') {
            $pending.Add($pod.metadata.namespace + '/' + $pod.metadata.name + ' (Failed)')
            continue
        }
        if ($pod.status.phase -eq 'Succeeded') { continue }
        $statuses = @()
        if ($pod.status.PSObject.Properties.Name -contains 'containerStatuses') {
            $statuses = @($pod.status.containerStatuses)
        }
        if ($statuses.Count -eq 0 -or @($statuses | Where-Object { -not $_.ready }).Count -gt 0) {
            $pending.Add($pod.metadata.namespace + '/' + $pod.metadata.name)
        }
    }
    if ($pending.Count -eq 0) { break }
    if ((Get-Date) -ge $deadline) { throw ('Pods did not become ready: ' + ($pending -join ', ')) }
    Start-Sleep -Seconds 5
} while ($true)
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ('https://' + $config.RANCHER_HOSTNAME + '/ping')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ('https://' + $config.MAPS_HOSTNAME + '/healthz')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca --user ('kasm_user:' + $config.QGIS_PASSWORD) ('https://' + $config.QGIS_HOSTNAME + '/') --output (Join-Path $out 'qgis-desktop.html')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ('https://' + $config.PGADMIN_HOSTNAME + '/misc/ping')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/wms?service=WMS&version=1.3.0&request=GetCapabilities') --output (Join-Path $out 'wms-capabilities.xml')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/wms?service=WMS&version=1.3.0&request=GetMap&layers=demo:demo_places&styles=&crs=EPSG:4326&bbox=34,31,36,33&width=512&height=512&format=image/png') --output (Join-Path $out 'wms-map.png')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=demo:demo_places&outputFormat=application%2Fjson') --output (Join-Path $out 'wfs-features.json')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/gwc/service/wmts?SERVICE=WMTS&REQUEST=GetCapabilities') --output (Join-Path $out 'wmts-capabilities.xml')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/gwc/service/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=demo%3Ademo_places&STYLE=demo%3Ademo_places&TILEMATRIXSET=EPSG%3A900913&TILEMATRIX=EPSG%3A900913%3A7&TILEROW=51&TILECOL=76&FORMAT=image%2Fpng') --output (Join-Path $out 'wmts-tile.png')

$features = Get-Content -Raw -LiteralPath (Join-Path $out 'wfs-features.json') | ConvertFrom-Json
if ($features.features.Count -ne 3) { throw ('Expected 3 WFS features, found ' + $features.features.Count) }
$wmtsCapabilities = Get-Content -Raw -LiteralPath (Join-Path $out 'wmts-capabilities.xml')
if ($wmtsCapabilities -notmatch [regex]::Escape('demo:demo_places')) { throw 'WMTS capabilities do not advertise demo:demo_places.' }
if ((Get-Item -LiteralPath (Join-Path $out 'wmts-tile.png')).Length -lt 100) { throw 'WMTS GetTile returned an unexpectedly small response.' }

$postgisPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=postgis -o jsonpath='{.items[0].metadata.name}'
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE exec $postgisPod '--' psql -U postgres -d gisdata -tAc 'SELECT count(*) FROM demo_places;'
$pgadminPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=pgadmin -o jsonpath='{.items[0].metadata.name}'
$pgadminStorageUser = $config.PGADMIN_DEFAULT_EMAIL.Replace('@', '_')
$pgpassPath = '/var/lib/pgadmin/storage/' + $pgadminStorageUser + '/.pgpass'
$pgadminServers = (kubectl -n $config.PLATFORM_NAMESPACE exec $pgadminPod '--' cat /pgadmin4/servers.json | Out-String) | ConvertFrom-Json
$pgadminServer = $pgadminServers.Servers.'1'
if ($pgadminServer.Name -ne 'PostGIS POC' -or $pgadminServer.Host -ne 'platform-platform-infra-postgis.platform-infra.svc.cluster.local' -or $pgadminServer.Username -ne $config.POSTGRES_SUPER_USERNAME) {
    throw 'pgAdmin server definition does not target the internal PostGIS service as the generated superuser.'
}
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE exec $pgadminPod '--' sh -c ('test -s ' + $pgpassPath + ' && PGPASSFILE=' + $pgpassPath + ' /usr/local/pgsql-16/psql -h platform-platform-infra-postgis.platform-infra.svc.cluster.local -U ' + $config.POSTGRES_SUPER_USERNAME + ' -d gisdata -tAc "SELECT count(*) FROM demo_places WHERE PostGIS_Version() IS NOT NULL;" | grep -q 3')
$qgisPod = kubectl -n $config.GEOSERVER_NAMESPACE get pod -l app.kubernetes.io/name=gscloud-qgis -o jsonpath='{.items[0].metadata.name}'
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' qgis --version
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' geoserver-rest GET about/version.json
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' sh -c 'PGPASSWORD="$POSTGIS_PASSWORD" psql -h "$POSTGIS_HOST" -U "$POSTGIS_USERNAME" -d "$POSTGIS_DATABASE" -tAc "SELECT count(*) FROM demo_places;" | grep -q 3'
$marker = 'qgis-shared-data-' + (Get-Date -Format 'yyyyMMddHHmmss')
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' sh -c ('printf %s ' + $marker + ' > /data/validation-marker.txt')
$wmsPodForData = kubectl -n $config.GEOSERVER_NAMESPACE get pod -l app.kubernetes.io/component=wms -o jsonpath='{.items[0].metadata.name}'
$observedMarker = kubectl -n $config.GEOSERVER_NAMESPACE exec $wmsPodForData '--' cat /data/validation-marker.txt
if (($observedMarker -join '').Trim() -ne $marker) { throw 'QGIS and GeoServer do not observe the same /data volume.' }
$rabbitPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=rabbitmq -o jsonpath='{.items[0].metadata.name}'
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE exec $rabbitPod '--' rabbitmqctl list_queues name messages consumers

if ($Deep) {
    $wmsDeployment = kubectl -n $config.GEOSERVER_NAMESPACE get deployment -l app.kubernetes.io/component=wms -o jsonpath='{.items[0].metadata.name}'
    Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE scale deployment $wmsDeployment --replicas=2
    Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE rollout status deployment $wmsDeployment --timeout=300s
    $token = 'Rabbit-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $bodyPath = Join-Path $out 'featuretype-update.json'
    Set-FileUtf8NoBom -Path $bodyPath -Content ('{"featureType":{"title":"' + $token + '"}}')
    Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca --user $auth --request PUT --header 'Content-Type: application/json' --data-binary ('@' + $bodyPath) ($base + '/rest/workspaces/demo/datastores/gisdata/featuretypes/demo_places')
    Start-Sleep -Seconds 10

    $probeImage = Get-JcrRuntimeImage -SourceImage $script:Versions.CurlImage -Config $config
    kubectl -n $config.GEOSERVER_NAMESPACE delete pod propagation-probe --ignore-not-found | Out-Null
    Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE run propagation-probe --image=$probeImage --restart=Never --command -- sleep 300
    Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE wait --for=condition=Ready pod/propagation-probe --timeout=120s
    $pods = (kubectl -n $config.GEOSERVER_NAMESPACE get pod -l app.kubernetes.io/component=wms -o json | ConvertFrom-Json).items
    if ($pods.Count -lt 2) { throw 'Expected at least two WMS pods for propagation validation.' }
    foreach ($pod in $pods) {
        $ip = $pod.status.podIP
        $capabilities = kubectl -n $config.GEOSERVER_NAMESPACE exec propagation-probe '--' curl -fsS ("http://$ip`:8080/wms?service=WMS&request=GetCapabilities")
        if (($capabilities -join "`n") -notmatch [regex]::Escape($token)) { throw ('Configuration update was not observed by ' + $pod.metadata.name) }
    }
    kubectl -n $config.GEOSERVER_NAMESPACE delete pod propagation-probe --ignore-not-found | Out-Null
    Write-Host 'RabbitMQ configuration propagation verified on both WMS replicas.'
}

Write-Host ('Validation artifacts: ' + $out)
