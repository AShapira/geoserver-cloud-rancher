param([switch]$Recreate)
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$k3d = Get-K3dPath
Ensure-DockerNetwork -Name $config.AIRGAP_RUNTIME_NETWORK -Internal

if (Test-NativeSuccess $k3d cluster get $config.AIRGAP_CLUSTER_NAME) {
    if (-not $Recreate) {
        Write-Host ('Cluster already exists: ' + $config.AIRGAP_CLUSTER_NAME)
        exit 0
    }
    Invoke-Native $k3d cluster delete $config.AIRGAP_CLUSTER_NAME
}

$caPath = Convert-ToForwardSlashPath (Join-Path (Get-StateDir) 'certs\ca.crt')
$clusterConfig = Join-Path (Get-StateDir) 'k3d-config.yaml'
$registryConfigPath = Join-Path (Get-StateDir) 'registries.yaml'
$registryConfig = @"
mirrors:
  "docker.io":
    endpoint:
      - "https://$($config.JCR_INTERNAL_HOST)/artifactory/api/docker/$($config.JCR_DOCKER_REPOSITORY)/v2"
  "ghcr.io":
    endpoint:
      - "https://$($config.JCR_INTERNAL_HOST)/artifactory/api/docker/$($config.JCR_DOCKER_REPOSITORY)/v2"
    rewrite:
      "^(.*)": "ghcr.io/`$1"
  "quay.io":
    endpoint:
      - "https://$($config.JCR_INTERNAL_HOST)/artifactory/api/docker/$($config.JCR_DOCKER_REPOSITORY)/v2"
    rewrite:
      "^(.*)": "quay.io/`$1"
  "registry.k8s.io":
    endpoint:
      - "https://$($config.JCR_INTERNAL_HOST)/artifactory/api/docker/$($config.JCR_DOCKER_REPOSITORY)/v2"
    rewrite:
      "^(.*)": "registry.k8s.io/`$1"
configs:
  "$($config.JCR_INTERNAL_HOST)":
    auth:
      username: "$($config.JCR_USERNAME)"
      password: "$($config.JCR_PASSWORD)"
    tls:
      ca_file: /etc/ssl/certs/airgap-ca.crt
"@
Set-FileUtf8NoBom -Path $registryConfigPath -Content $registryConfig

$yaml = @"
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: $($config.AIRGAP_CLUSTER_NAME)
servers: 1
agents: 0
image: rancher/k3s:$($script:Versions.K3sDockerTag)
network: $($config.AIRGAP_BOOTSTRAP_NETWORK)
ports:
  - port: 80:80
    nodeFilters:
      - loadbalancer
  - port: 443:443
    nodeFilters:
      - loadbalancer
volumes:
  - volume: $($caPath):/etc/ssl/certs/airgap-ca.crt
    nodeFilters:
      - all
  - volume: $((Convert-ToForwardSlashPath (Join-Path (Get-RepoRoot) 'infra\k3d\disable-dns-fix.sh'))):/bin/k3d-entrypoint-dns.sh
    nodeFilters:
      - all
  - volume: $((Convert-ToForwardSlashPath $registryConfigPath)):/etc/rancher/k3s/registries.yaml
    nodeFilters:
      - all
options:
  k3s:
    extraArgs:
      - arg: --disable-default-registry-endpoint
        nodeFilters:
          - server:*
"@
Set-FileUtf8NoBom -Path $clusterConfig -Content $yaml

Invoke-Native $k3d cluster create --config $clusterConfig --wait
$loadBalancer = 'k3d-' + $config.AIRGAP_CLUSTER_NAME + '-serverlb'
$apiBinding = (& docker port $loadBalancer '6443/tcp' | Select-Object -First 1)
if (-not $apiBinding) { throw 'Could not determine the published Kubernetes API port.' }
$apiPort = $apiBinding.Substring($apiBinding.LastIndexOf(':') + 1)
Invoke-Native kubectl config set-cluster ('k3d-' + $config.AIRGAP_CLUSTER_NAME) ('--server=https://127.0.0.1:' + $apiPort)
$clusterContainers = @(docker ps -a --format '{{.Names}}' | Where-Object { $_ -like ('k3d-' + $config.AIRGAP_CLUSTER_NAME + '-*') })
foreach ($container in $clusterContainers) {
    if (-not (Test-NativeSuccess docker network connect $config.AIRGAP_RUNTIME_NETWORK $container)) {
        $attached = docker inspect $container --format '{{json .NetworkSettings.Networks}}'
        if ($attached -notmatch [regex]::Escape($config.AIRGAP_RUNTIME_NETWORK)) { throw "Could not attach $container to the runtime network." }
    }
}
Invoke-Native kubectl config use-context ('k3d-' + $config.AIRGAP_CLUSTER_NAME)
Invoke-Native kubectl wait --for=condition=Ready node --all --timeout=180s
Write-Host ('Created cluster on bootstrap and runtime networks; run Enter-AirGap.ps1 to remove egress.')
