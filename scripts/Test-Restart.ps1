param()
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$qgisPod = kubectl -n $config.GEOSERVER_NAMESPACE get pod -l app.kubernetes.io/name=gscloud-qgis -o jsonpath='{.items[0].metadata.name}'
$persistenceToken = 'qgis-persistence-' + (Get-Date -Format 'yyyyMMddHHmmss')
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' sh -c ('printf %s ' + $persistenceToken + ' > /data/restart-persistence.txt')
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' sh -c ('printf %s ' + $persistenceToken + ' > /home/kasm-user/restart-persistence.txt')
$pgadminPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=pgadmin -o jsonpath='{.items[0].metadata.name}'
$pgadminToken = 'pgadmin-persistence-' + (Get-Date -Format 'yyyyMMddHHmmss')
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE exec $pgadminPod '--' sh -c ('printf %s ' + $pgadminToken + ' > /var/lib/pgadmin/restart-persistence.txt')
$rabbitPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=rabbitmq -o jsonpath='{.items[0].metadata.name}'
$postgisPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=postgis -o jsonpath='{.items[0].metadata.name}'
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE delete pod $rabbitPod $postgisPod $pgadminPod
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE wait --for=condition=Ready pod -l app.kubernetes.io/component=rabbitmq --timeout=300s
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE wait --for=condition=Ready pod -l app.kubernetes.io/component=postgis --timeout=300s
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE rollout status deployment -l app.kubernetes.io/component=pgadmin --timeout=300s

$deployments = @((kubectl -n $config.GEOSERVER_NAMESPACE get deployment -o json | ConvertFrom-Json).items | ForEach-Object { $_.metadata.name })
foreach ($deployment in $deployments) { Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE rollout restart deployment $deployment }
foreach ($deployment in $deployments) {
    $deadline = (Get-Date).AddMinutes(10)
    do {
        if (Test-NativeSuccess kubectl -n $config.GEOSERVER_NAMESPACE rollout status deployment $deployment --timeout=30s) { break }
        if ((Get-Date) -ge $deadline) { throw ('Deployment did not complete its rollout: ' + $deployment) }
        Start-Sleep -Seconds 5
    } while ($true)
}

$bootstrapMembers = docker network inspect $config.AIRGAP_BOOTSTRAP_NETWORK --format '{{range .Containers}}{{.Name}} {{end}}'
$wasAirGapped = $bootstrapMembers -notmatch 'gscloud-jcr-proxy'
$server = 'k3d-' + $config.AIRGAP_CLUSTER_NAME + '-server-0'
Invoke-Native docker restart $server
$deadline = (Get-Date).AddMinutes(5)
do {
    if (Test-NativeSuccess kubectl get node $server --request-timeout=5s) { break }
    if ((Get-Date) -ge $deadline) { throw 'K3s node did not recover after restart.' }
    Start-Sleep -Seconds 5
} while ($true)
if ($wasAirGapped) { & (Join-Path $PSScriptRoot 'Enter-AirGap.ps1') }

& (Join-Path $PSScriptRoot 'Validate.ps1')
$qgisPod = kubectl -n $config.GEOSERVER_NAMESPACE get pod -l app.kubernetes.io/name=gscloud-qgis -o jsonpath='{.items[0].metadata.name}'
$dataToken = kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' cat /data/restart-persistence.txt
$profileToken = kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' cat /home/kasm-user/restart-persistence.txt
if (($dataToken -join '').Trim() -ne $persistenceToken -or ($profileToken -join '').Trim() -ne $persistenceToken) {
    throw 'QGIS profile or shared geodata did not persist across restart.'
}
$pgadminPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=pgadmin -o jsonpath='{.items[0].metadata.name}'
$observedPgadminToken = kubectl -n $config.PLATFORM_NAMESPACE exec $pgadminPod '--' cat /var/lib/pgadmin/restart-persistence.txt
if (($observedPgadminToken -join '').Trim() -ne $pgadminToken) { throw 'pgAdmin configuration data did not persist across restart.' }
Write-Host 'Restart and persistence validation completed.'
