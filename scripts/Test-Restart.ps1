param()
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$qgisPod = kubectl -n $config.GEOSERVER_NAMESPACE get pod -l app.kubernetes.io/name=gscloud-qgis -o jsonpath='{.items[0].metadata.name}'
$persistenceToken = 'qgis-persistence-' + (Get-Date -Format 'yyyyMMddHHmmss')
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' sh -c ('printf %s ' + $persistenceToken + ' > /data/restart-persistence.txt')
Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $qgisPod '--' sh -c ('printf %s ' + $persistenceToken + ' > /home/kasm-user/restart-persistence.txt')
$rabbitPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=rabbitmq -o jsonpath='{.items[0].metadata.name}'
$postgisPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=postgis -o jsonpath='{.items[0].metadata.name}'
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE delete pod $rabbitPod $postgisPod
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE wait --for=condition=Ready pod -l app.kubernetes.io/component=rabbitmq --timeout=300s
Invoke-Native kubectl -n $config.PLATFORM_NAMESPACE wait --for=condition=Ready pod -l app.kubernetes.io/component=postgis --timeout=300s

$deployments = @((kubectl -n $config.GEOSERVER_NAMESPACE get deployment -o json | ConvertFrom-Json).items | ForEach-Object { $_.metadata.name })
foreach ($deployment in $deployments) { Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE rollout restart deployment $deployment }
foreach ($deployment in $deployments) { Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE rollout status deployment $deployment --timeout=600s }

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
Write-Host 'Restart and persistence validation completed.'
