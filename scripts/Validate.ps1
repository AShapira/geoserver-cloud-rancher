param([switch]$Deep)
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$ca = Join-Path (Get-StateDir) 'certs\ca.crt'
$base = 'https://' + $config.MAPS_HOSTNAME + '/geoserver-cloud'
$auth = $config.GEOSERVER_ADMIN_USERNAME + ':' + $config.GEOSERVER_ADMIN_PASSWORD
$out = Join-Path (Get-StateDir) 'validation'
New-Item -ItemType Directory -Force -Path $out | Out-Null
kubectl -n $config.GEOSERVER_NAMESPACE delete pod propagation-probe --ignore-not-found | Out-Null
$validatedNamespaces = @($config.PLATFORM_NAMESPACE, $config.GEOSERVER_NAMESPACE)

$deadline = (Get-Date).AddMinutes(10)
do {
    $pending = New-Object System.Collections.Generic.List[string]
    $pods = @((kubectl get pods --all-namespaces -o json | ConvertFrom-Json).items | Where-Object {
        $validatedNamespaces -contains $_.metadata.namespace
    })
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
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ('https://' + $config.MAPS_HOSTNAME + '/stac/') --output (Join-Path $out 'stac-browser.html')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ('https://' + $config.MAPS_HOSTNAME + '/api/stac/') --output (Join-Path $out 'stac-landing.json')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ('https://' + $config.MAPS_HOSTNAME + '/api/stac/collections') --output (Join-Path $out 'stac-collections.json')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ('https://' + $config.MAPS_HOSTNAME + '/api/stac/search?limit=100') --output (Join-Path $out 'stac-items.json')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca --user ('kasm_user:' + $config.QGIS_PASSWORD) ('https://' + $config.QGIS_HOSTNAME + '/') --output (Join-Path $out 'qgis-desktop.html')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ('https://' + $config.PGADMIN_HOSTNAME + '/misc/ping')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/wms?service=WMS&version=1.3.0&request=GetCapabilities') --output (Join-Path $out 'wms-capabilities.xml')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/wms?service=WMS&version=1.3.0&request=GetMap&layers=demo:demo_places_1_0_0&styles=&crs=EPSG:4326&bbox=34,31,36,33&width=512&height=512&format=image/png') --output (Join-Path $out 'wms-map.png')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=demo:demo_places_1_0_0&outputFormat=application%2Fjson') --output (Join-Path $out 'wfs-features.json')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/gwc/service/wmts?SERVICE=WMTS&REQUEST=GetCapabilities') --output (Join-Path $out 'wmts-capabilities.xml')
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca ($base + '/wcs?service=WCS&version=2.0.1&request=GetCapabilities') --output (Join-Path $out 'wcs-capabilities.xml')

$features = Get-Content -Raw -LiteralPath (Join-Path $out 'wfs-features.json') | ConvertFrom-Json
if ($features.features.Count -ne 3) { throw ('Expected 3 WFS features, found ' + $features.features.Count) }
$wmtsCapabilities = Get-Content -Raw -LiteralPath (Join-Path $out 'wmts-capabilities.xml')
if ($wmtsCapabilities -notmatch [regex]::Escape('demo:demo_places_1_0_0') -or $wmtsCapabilities -notmatch [regex]::Escape('demo:demo_raster_1_0_0')) { throw 'WMTS capabilities do not advertise both STAC demo releases.' }
$wcsCapabilities = Get-Content -Raw -LiteralPath (Join-Path $out 'wcs-capabilities.xml')
if ($wcsCapabilities -notmatch [regex]::Escape('demo__demo_raster_1_0_0')) { throw 'WCS capabilities do not advertise the raster release.' }

$collections = Get-Content -Raw -LiteralPath (Join-Path $out 'stac-collections.json') | ConvertFrom-Json
$collectionIds = @($collections.collections | ForEach-Object { $_.id } | Sort-Object)
if (($collectionIds -join ',') -ne 'demo-places,demo-raster') { throw ('Unexpected STAC Collections: ' + ($collectionIds -join ', ')) }
$items = Get-Content -Raw -LiteralPath (Join-Path $out 'stac-items.json') | ConvertFrom-Json
$itemIds = @($items.features | ForEach-Object { $_.id } | Sort-Object)
if (($itemIds -join ',') -ne 'demo-places-1_0_0,demo-raster-1_0_0') { throw ('Unexpected STAC Items: ' + ($itemIds -join ', ')) }
foreach ($item in $items.features) {
    $asset = $item.assets.data.href
    if (-not $asset.StartsWith('https://' + $config.MAPS_HOSTNAME + '/stac-assets/')) { throw ('Unexpected STAC asset URL: ' + $asset) }
    Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca $asset --output (Join-Path $out ($item.id + '-asset'))
}
$searchBody = Join-Path $out 'stac-search.json'
Set-FileUtf8NoBom -Path $searchBody -Content '{"collections":["demo-places"],"filter-lang":"cql2-json","filter":{"op":"like","args":[{"property":"gscloud:search_text"},"%cities%"]}}'
Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca --request POST --header 'Content-Type: application/json' --data-binary ('@' + $searchBody) ('https://' + $config.MAPS_HOSTNAME + '/api/stac/search') --output (Join-Path $out 'stac-filter-results.json')
$filtered = Get-Content -Raw -LiteralPath (Join-Path $out 'stac-filter-results.json') | ConvertFrom-Json
if (@($filtered.features).Count -ne 1 -or $filtered.features[0].id -ne 'demo-places-1_0_0') { throw 'CQL2 metadata search did not return the vector demo release.' }

$postgisPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=postgis -o jsonpath='{.items[0].metadata.name}'
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE exec $postgisPod '--' psql -U postgres -d gisdata -tAc 'SELECT count(*) FROM demo_places_1_0_0;'
$pgadminPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=pgadmin -o jsonpath='{.items[0].metadata.name}'
$pgadminStorageUser = $config.PGADMIN_DEFAULT_EMAIL.Replace('@', '_')
$pgpassPath = '/var/lib/pgadmin/storage/' + $pgadminStorageUser + '/.pgpass'
$pgadminServers = (kubectl -n $config.PLATFORM_NAMESPACE exec $pgadminPod '--' cat /pgadmin4/servers.json | Out-String) | ConvertFrom-Json
$pgadminServer = $pgadminServers.Servers.'1'
if ($pgadminServer.Name -ne 'PostGIS POC' -or $pgadminServer.Host -ne 'platform-platform-infra-postgis.platform-infra.svc.cluster.local' -or $pgadminServer.Username -ne $config.POSTGRES_SUPER_USERNAME) {
    throw 'pgAdmin server definition does not target the internal PostGIS service as the generated superuser.'
}
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE exec $pgadminPod '--' sh -c ('test -s ' + $pgpassPath + ' && PGPASSFILE=' + $pgpassPath + ' /usr/local/pgsql-16/psql -h platform-platform-infra-postgis.platform-infra.svc.cluster.local -U ' + $config.POSTGRES_SUPER_USERNAME + ' -d gisdata -tAc "SELECT count(*) FROM demo_places_1_0_0 WHERE PostGIS_Version() IS NOT NULL;" | grep -q 3')
$qgisPod = kubectl -n $config.GEOSERVER_NAMESPACE get pod -l app.kubernetes.io/name=gscloud-qgis -o jsonpath='{.items[0].metadata.name}'
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' qgis --version
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' geoserver-rest GET about/version.json
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' sh -c 'PGPASSWORD="$POSTGIS_PASSWORD" psql -h "$POSTGIS_HOST" -U "$POSTGIS_USERNAME" -d "$POSTGIS_DATABASE" -tAc "SELECT count(*) FROM demo_places_1_0_0;" | grep -q 3'
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
    Invoke-Native curl.exe --fail --silent --show-error --ssl-no-revoke --cacert $ca --user $auth --request PUT --header 'Content-Type: application/json' --data-binary ('@' + $bodyPath) ($base + '/rest/workspaces/demo/datastores/demo_places_1_0_0/featuretypes/demo_places_1_0_0')
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
