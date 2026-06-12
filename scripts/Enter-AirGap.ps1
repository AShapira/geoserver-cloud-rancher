param()
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$containers = @('gscloud-jcr', 'gscloud-jcr-proxy', 'gscloud-jcr-db')
foreach ($container in $containers) {
    [void](Test-NativeSuccess docker network disconnect $config.AIRGAP_BOOTSTRAP_NETWORK $container)
}
Invoke-Native docker restart gscloud-jcr-proxy

$server = 'k3d-' + $config.AIRGAP_CLUSTER_NAME + '-server-0'
$firewall = @'
set -eu
iptables -D OUTPUT -j AIRGAP_NODE 2>/dev/null || true
iptables -D FORWARD -s 10.42.0.0/16 -j AIRGAP_POD 2>/dev/null || true
iptables -F AIRGAP_POD 2>/dev/null || true
iptables -X AIRGAP_POD 2>/dev/null || true
iptables -F AIRGAP_NODE 2>/dev/null || iptables -N AIRGAP_NODE
for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16; do
  iptables -A AIRGAP_NODE -d "$cidr" -j RETURN
done
iptables -A AIRGAP_NODE -j REJECT
iptables -I OUTPUT 1 -j AIRGAP_NODE
'@
& docker exec $server sh -c $firewall
if ($LASTEXITCODE -ne 0) { throw 'Could not apply air-gap firewall rules.' }

$policy = @'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: airgap-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.0/8
        - ipBlock:
            cidr: 172.16.0.0/12
'@
$namespaces = @((kubectl get namespace -o json | ConvertFrom-Json).items | ForEach-Object { $_.metadata.name })
foreach ($namespace in $namespaces) {
    $policy | kubectl -n $namespace apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Could not apply air-gap NetworkPolicy in ' + $namespace) }
}
$fleetPolicy = kubectl -n cattle-fleet-local-system get networkpolicy default-allow-all --ignore-not-found -o name
if ($fleetPolicy) {
    $patchPath = Join-Path (Get-StateDir) 'fleet-airgap-patch.json'
    Set-FileUtf8NoBom -Path $patchPath -Content '{"spec":{"egress":null,"policyTypes":["Ingress"]}}'
    Invoke-Native kubectl -n cattle-fleet-local-system patch networkpolicy default-allow-all --type=merge --patch-file $patchPath
}

$canary = Get-JcrRuntimeImage -SourceImage $script:Versions.CanaryImage -Config $config
[void](Test-NativeSuccess docker exec $server crictl rmi $canary)
kubectl -n default delete pod airgap-canary --ignore-not-found | Out-Null
Invoke-Native kubectl -n default run airgap-canary --image=$canary --restart=Never --command '--' sh -c 'sleep 300'
Invoke-Native kubectl -n default wait --for=condition=Ready pod/airgap-canary --timeout=120s

if (Test-NativeSuccess kubectl -n default exec airgap-canary '--' wget -q -T 5 -O /dev/null https://example.com) {
    throw 'Air-gap validation failed: the canary pod reached example.com.'
}

Write-Host 'Air-gap mode is active: JCR bootstrap egress is disconnected, cluster egress is blocked, and a cold JCR pull succeeded.'
