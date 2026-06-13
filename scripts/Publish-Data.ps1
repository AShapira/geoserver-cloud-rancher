[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$Source
)
. (Join-Path $PSScriptRoot 'Publishing.ps1')

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw ('Manifest not found: ' + $Manifest) }
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw ('Source not found: ' + $Source) }
$sourceItem = Get-Item -LiteralPath $Source
if ($sourceItem.Length -gt 2GB) { throw 'The POC publishing workflow accepts source files up to 2 GB.' }
$extension = $sourceItem.Extension.ToLowerInvariant()
if ($extension -notin @('.gpkg', '.geojson', '.json', '.tif', '.tiff')) { throw ('Unsupported source extension: ' + $extension) }

if (-not (Test-Path -LiteralPath $script:ConfigPath)) { & (Join-Path $PSScriptRoot 'Initialize-State.ps1') -SkipTrust }
$config = Get-Config
$runId = ([Guid]::NewGuid().ToString('N')).Substring(0, 12)
$stager = 'publish-stage-' + $runId
$jobName = 'publish-data-' + $runId
$requestDir = '/data/publishing/requests/' + $runId
$pod = @{
    apiVersion = 'v1'
    kind = 'Pod'
    metadata = @{ name = $stager; namespace = $config.GEOSERVER_NAMESPACE; labels = @{ 'app.kubernetes.io/name' = 'gscloud-publish-stager' } }
    spec = @{
        restartPolicy = 'Never'
        imagePullSecrets = @(@{ name = 'jcr-credentials' })
        securityContext = @{ fsGroup = 1000 }
        containers = @(@{
            name = 'stager'
            image = Get-PublisherImage -Config $config
            command = @('sh', '-c', 'sleep 3600')
            securityContext = @{ allowPrivilegeEscalation = $false; capabilities = @{ drop = @('ALL') } }
            volumeMounts = @(@{ name = 'geodata'; mountPath = '/data' })
        })
        volumes = @(@{ name = 'geodata'; persistentVolumeClaim = @{ claimName = 'gscloud-geodata' } })
    }
}
$podPath = Join-Path (Get-StateDir) ($stager + '.json')
Set-FileUtf8NoBom -Path $podPath -Content ($pod | ConvertTo-Json -Depth 20)

try {
    Invoke-Native kubectl apply -f $podPath
    Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE wait --for=condition=Ready ('pod/' + $stager) --timeout=5m
    Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE exec $stager '--' mkdir -p $requestDir
    Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE cp ([IO.Path]::GetFullPath($Manifest)) ($stager + ':' + $requestDir + '/manifest.yaml')
    Invoke-Native kubectl -n $config.GEOSERVER_NAMESPACE cp $sourceItem.FullName ($stager + ':' + $requestDir + '/source' + $extension)
} finally {
    [void](Test-NativeSuccess kubectl -n $config.GEOSERVER_NAMESPACE delete pod $stager --wait=false)
}

$job = New-PublisherJobObject -Name $jobName -Config $config -Arguments @(
    'publish', '--manifest', ($requestDir + '/manifest.yaml'), '--source', ($requestDir + '/source' + $extension)
)
Invoke-PublisherJob -Job $job -Config $config
Write-Host ('Published source through Job ' + $jobName)
