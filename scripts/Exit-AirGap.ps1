param()
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
Ensure-DockerNetwork -Name $config.AIRGAP_BOOTSTRAP_NETWORK
$server = 'k3d-' + $config.AIRGAP_CLUSTER_NAME + '-server-0'
$firewall = @'
iptables -D OUTPUT -j AIRGAP_NODE 2>/dev/null || true
iptables -D FORWARD -s 10.42.0.0/16 -j AIRGAP_POD 2>/dev/null || true
iptables -F AIRGAP_NODE 2>/dev/null || true
iptables -X AIRGAP_NODE 2>/dev/null || true
iptables -F AIRGAP_POD 2>/dev/null || true
iptables -X AIRGAP_POD 2>/dev/null || true
'@
if (Test-NativeSuccess docker inspect $server) {
    & docker exec $server sh -c $firewall
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove air-gap firewall rules.' }
}
$namespaces = @((kubectl get namespace -o json | ConvertFrom-Json).items | ForEach-Object { $_.metadata.name })
foreach ($namespace in $namespaces) {
    kubectl -n $namespace delete networkpolicy airgap-egress --ignore-not-found | Out-Null
}
$fleetPolicy = kubectl -n cattle-fleet-local-system get networkpolicy default-allow-all --ignore-not-found -o name
if ($fleetPolicy) {
    $patchPath = Join-Path (Get-StateDir) 'fleet-online-patch.json'
    Set-FileUtf8NoBom -Path $patchPath -Content '{"spec":{"egress":[{}],"policyTypes":["Ingress","Egress"]}}'
    Invoke-Native kubectl -n cattle-fleet-local-system patch networkpolicy default-allow-all --type=merge --patch-file $patchPath
}
$containers = @('gscloud-jcr', 'gscloud-jcr-proxy', 'gscloud-jcr-db')
foreach ($container in $containers) {
    [void](Test-NativeSuccess docker network connect $config.AIRGAP_BOOTSTRAP_NETWORK $container)
}
Invoke-Native docker restart gscloud-jcr-proxy
Write-Host 'Bootstrap egress is connected. Run Enter-AirGap.ps1 after online maintenance.'
