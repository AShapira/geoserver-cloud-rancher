param([switch]$ForceMirror, [switch]$IncludeRancherReleaseImageSet)
. (Join-Path $PSScriptRoot 'Common.ps1')

& (Join-Path $PSScriptRoot 'Install-Tools.ps1')
& (Join-Path $PSScriptRoot 'Initialize-State.ps1')
& (Join-Path $PSScriptRoot 'Start-Jcr.ps1')
$config = Get-Config
$helm = Get-HelmPath

$dist = Join-Path (Get-RepoRoot) 'dist'
$chartDist = Join-Path $dist 'charts'
New-Item -ItemType Directory -Force -Path $chartDist | Out-Null
$rancherImagesFile = Join-Path (Get-StateDir) ('rancher-images-v' + $script:Versions.Rancher + '.txt')

if ($IncludeRancherReleaseImageSet) {
    Invoke-WebRequest -UseBasicParsing -Uri ('https://github.com/rancher/rancher/releases/download/v{0}/rancher-images.txt' -f $script:Versions.Rancher) -OutFile $rancherImagesFile
}

$images = New-Object System.Collections.Generic.List[string]
if ((Test-Path -LiteralPath $rancherImagesFile) -and $IncludeRancherReleaseImageSet) {
    foreach ($line in Get-Content -LiteralPath $rancherImagesFile) {
        $value = $line.Trim()
        if ($value -and -not $value.StartsWith('#')) { $images.Add($value) }
    }
}

$requiredImages = @(
    ('rancher/k3s:' + $script:Versions.K3sDockerTag),
    ('ghcr.io/k3d-io/k3d-proxy:' + $script:Versions.K3d),
    ('ghcr.io/k3d-io/k3d-tools:' + $script:Versions.K3d),
    ('rancher/rancher:v' + $script:Versions.Rancher),
    'rancher/mirrored-pause:3.6',
    'rancher/klipper-helm:v0.10.0-build20260513',
    'rancher/klipper-lb:v0.4.17',
    'rancher/local-path-provisioner:v0.0.36',
    'rancher/mirrored-coredns-coredns:1.14.3',
    'rancher/mirrored-metrics-server:v0.8.1',
    'rancher/mirrored-library-traefik:3.6.13',
    'rancher/mirrored-library-busybox:1.37.0',
    'rancher/shell:v0.7.0',
    'rancher/fleet:v0.15.2',
    'rancher/fleet-agent:v0.15.2',
    'rancher/cluster-api-controller:v1.12.7',
    'rancher/rancher-webhook:v0.10.6',
    'rancher/system-upgrade-controller:v0.19.1',
    'rancher/turtles:v0.26.2',
    'rancher/kuberlr-kubectl:v7.0.3',
    ('geoservercloud/geoserver-cloud-gateway:' + $script:Versions.GeoServerImage),
    ('geoservercloud/geoserver-cloud-webui:' + $script:Versions.GeoServerImage),
    ('geoservercloud/geoserver-cloud-rest:' + $script:Versions.GeoServerImage),
    ('geoservercloud/geoserver-cloud-wms:' + $script:Versions.GeoServerImage),
    ('geoservercloud/geoserver-cloud-wfs:' + $script:Versions.GeoServerImage),
    ('geoservercloud/geoserver-cloud-gwc:' + $script:Versions.GeoServerImage),
    $script:Versions.PostgisImage,
    $script:Versions.RabbitImage,
    $script:Versions.CurlImage,
    $script:Versions.K6Image,
    $script:Versions.CanaryImage,
    $script:Versions.JcrDatabaseImage,
    $script:Versions.JcrProxyImage,
    'node:22.14-alpine'
)
foreach ($image in $requiredImages) { $images.Add($image) }
$images = @($images | Sort-Object -Unique)
$hostBootstrapImages = @{
    ('rancher/k3s:' + $script:Versions.K3sDockerTag) = $true
    ('ghcr.io/k3d-io/k3d-proxy:' + $script:Versions.K3d) = $true
    ('ghcr.io/k3d-io/k3d-tools:' + $script:Versions.K3d) = $true
}

$manifest = New-Object System.Collections.Generic.List[object]
$singlePlatformDir = Join-Path (Get-StateDir) 'single-platform-image'
New-Item -ItemType Directory -Force -Path $singlePlatformDir | Out-Null
Set-FileUtf8NoBom -Path (Join-Path $singlePlatformDir 'Dockerfile') -Content "ARG BASE_IMAGE`nFROM `${BASE_IMAGE}`n"
$existingManifestPath = Join-Path $dist 'image-manifest.json'
$existing = @{}
if ((Test-Path -LiteralPath $existingManifestPath) -and -not $ForceMirror) {
    foreach ($entry in (Get-Content -Raw -LiteralPath $existingManifestPath | ConvertFrom-Json)) { $existing[$entry.source] = $entry }
}

function Write-MirrorCheckpoint {
    $records = @{}
    foreach ($entry in $existing.Values) { $records[$entry.source] = $entry }
    foreach ($entry in $manifest) { $records[$entry.source] = $entry }
    Set-FileUtf8NoBom -Path $existingManifestPath -Content (@($records.Values | Sort-Object source) | ConvertTo-Json -Depth 5)
}

$index = 0
foreach ($source in $images) {
    $index++
    $push = Get-JcrPushImage -SourceImage $source -Config $config
    $runtime = Get-JcrRuntimeImage -SourceImage $source -Config $config
    if ($existing.ContainsKey($source) -and -not $ForceMirror) {
        Write-Host ("[{0}/{1}] already recorded: {2}" -f $index, $images.Count, $source)
        $manifest.Add($existing[$source])
        continue
    }
    Write-Host ("[{0}/{1}] mirroring {2}" -f $index, $images.Count, $source)
    Invoke-Native docker pull --platform linux/amd64 $source
    Invoke-Native docker tag $source $push
    if (-not (Test-NativeSuccess docker push $push)) {
        Write-Host ('Repacking legacy multi-platform manifest as linux/amd64: ' + $source)
        Invoke-Native docker build --provenance=false --platform linux/amd64 --build-arg ('BASE_IMAGE=' + $source) --tag $push $singlePlatformDir
        Invoke-Native docker push $push
    }
    $digest = (& docker image inspect $source --format '{{index .RepoDigests 0}}' 2>$null)
    $manifest.Add([pscustomobject]@{ source = $source; push = $push; runtime = $runtime; digest = $digest })
    Write-MirrorCheckpoint
    if (-not $hostBootstrapImages.ContainsKey($source)) {
        [void](Test-NativeSuccess docker image rm $push)
        [void](Test-NativeSuccess docker image rm $source)
    }
}

$viewerPush = ('{0}/{1}/{2}:{3}' -f (Get-JcrClientHost -Config $config), $config.JCR_DOCKER_REPOSITORY, $config.VIEWER_IMAGE_NAME, $config.VIEWER_IMAGE_TAG)
$viewerRuntime = ('{0}/{1}/{2}:{3}' -f $config.JCR_INTERNAL_HOST, $config.JCR_DOCKER_REPOSITORY, $config.VIEWER_IMAGE_NAME, $config.VIEWER_IMAGE_TAG)
Invoke-Native docker build --tag $viewerPush (Join-Path (Get-RepoRoot) 'viewer')
Invoke-Native docker push $viewerPush
$viewerDigest = (& docker image inspect $viewerPush --format '{{index .RepoDigests 0}}' 2>$null)
$manifest.Add([pscustomobject]@{ source = 'local/viewer'; push = $viewerPush; runtime = $viewerRuntime; digest = $viewerDigest })

$qgisPush = ('{0}/{1}/{2}:{3}' -f (Get-JcrClientHost -Config $config), $config.JCR_DOCKER_REPOSITORY, $config.QGIS_IMAGE_NAME, $config.QGIS_IMAGE_TAG)
$qgisRuntime = ('{0}/{1}/{2}:{3}' -f $config.JCR_INTERNAL_HOST, $config.JCR_DOCKER_REPOSITORY, $config.QGIS_IMAGE_NAME, $config.QGIS_IMAGE_TAG)
Invoke-Native docker build --platform linux/amd64 --build-arg ('QGIS_BASE_IMAGE=' + $script:Versions.QgisBaseImage) --tag $qgisPush (Join-Path (Get-RepoRoot) 'qgis')
Invoke-Native docker push $qgisPush
$qgisDigest = (& docker image inspect $qgisPush --format '{{index .RepoDigests 0}}' 2>$null)
$manifest.Add([pscustomobject]@{ source = 'local/qgis'; push = $qgisPush; runtime = $qgisRuntime; digest = $qgisDigest })
Set-FileUtf8NoBom -Path $existingManifestPath -Content ($manifest | ConvertTo-Json -Depth 5)

$helmHome = Join-Path (Get-StateDir) 'helm'
$env:HELM_CONFIG_HOME = Join-Path $helmHome 'config'
$env:HELM_CACHE_HOME = Join-Path $helmHome 'cache'
$env:HELM_DATA_HOME = Join-Path $helmHome 'data'
New-Item -ItemType Directory -Force -Path $env:HELM_CONFIG_HOME, $env:HELM_CACHE_HOME, $env:HELM_DATA_HOME | Out-Null

& $helm repo add gscloud https://camptocamp.github.io/helm-geoserver-cloud --force-update | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not add GeoServer Cloud chart repository.' }
& $helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not add Rancher chart repository.' }
Invoke-Native $helm repo update

$geoChart = Join-Path (Get-RepoRoot) 'charts\geoserver-cloud-sim'
$infraChart = Join-Path (Get-RepoRoot) 'charts\platform-infra'
Invoke-Native $helm dependency update $geoChart
Invoke-Native $helm lint $infraChart
Invoke-Native $helm lint $geoChart
Invoke-Native $helm package $infraChart --destination $chartDist
Invoke-Native $helm package $geoChart --destination $chartDist

$rancherChart = Join-Path $chartDist ('rancher-' + $script:Versions.Rancher + '.tgz')
if (Test-Path -LiteralPath $rancherChart) { Remove-Item -LiteralPath $rancherChart -Force }
Invoke-Native $helm pull rancher-latest/rancher --version $script:Versions.Rancher --destination $chartDist

$config.JCR_PASSWORD | & $helm registry login (Get-JcrClientHost -Config $config) --username $config.JCR_USERNAME --password-stdin
if ($LASTEXITCODE -ne 0) { throw 'Helm registry login failed.' }
foreach ($package in Get-ChildItem -LiteralPath $chartDist -Filter '*.tgz') {
    if ($package.Name -like 'rancher-*') { continue }
    Invoke-Native $helm push $package.FullName ('oci://' + (Get-JcrClientHost -Config $config) + '/' + $config.JCR_HELM_REPOSITORY)
}

Copy-Item -LiteralPath $rancherChart -Destination (Join-Path (Get-StateDir) $rancherChart.Split([IO.Path]::DirectorySeparatorChar)[-1]) -Force
Write-Host ('Prepared image manifest: ' + $existingManifestPath)
Write-Host ('Prepared chart packages: ' + $chartDist)
