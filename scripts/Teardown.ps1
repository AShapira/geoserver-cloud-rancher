param([switch]$PurgeData)
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$helm = Get-HelmPath
$k3d = Get-K3dPath
[void](Test-NativeSuccess $helm uninstall gscloud -n $config.GEOSERVER_NAMESPACE)
[void](Test-NativeSuccess $helm uninstall platform -n $config.PLATFORM_NAMESPACE)
[void](Test-NativeSuccess $helm uninstall rancher -n $config.RANCHER_NAMESPACE)
[void](Test-NativeSuccess $k3d cluster delete $config.AIRGAP_CLUSTER_NAME)
[void](Test-NativeSuccess docker compose --env-file $script:ConfigPath -f (Join-Path (Get-RepoRoot) 'infra\jcr\docker-compose.yml') down)

if ($PurgeData) {
    $state = [IO.Path]::GetFullPath((Get-StateDir))
    $root = [IO.Path]::GetFullPath((Get-RepoRoot))
    if (-not $state.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove state outside the repository.' }
    Remove-Item -LiteralPath $state -Recurse -Force
    [void](Test-NativeSuccess docker network rm $config.AIRGAP_BOOTSTRAP_NETWORK $config.AIRGAP_RUNTIME_NETWORK)
    Write-Host 'Removed generated state and Docker networks.'
} else {
    Write-Host 'Stopped the environment and preserved generated state.'
}
