. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-PublisherImage {
    param([hashtable]$Config)
    return ('{0}/{1}/{2}:{3}' -f $Config.JCR_INTERNAL_HOST, $Config.JCR_DOCKER_REPOSITORY, $Config.PUBLISHER_IMAGE_NAME, $Config.PUBLISHER_IMAGE_TAG)
}
function New-PublisherEnvironment {
    param([hashtable]$Config)
    return @(
        @{ name = 'GEOSERVER_URL'; value = 'http://gscloud-gsc-gateway:8080/geoserver-cloud' },
        @{ name = 'GEOSERVER_USER'; valueFrom = @{ secretKeyRef = @{ name = 'gscloud-runtime'; key = 'geoserver-admin-username' } } },
        @{ name = 'GEOSERVER_PASSWORD'; valueFrom = @{ secretKeyRef = @{ name = 'gscloud-runtime'; key = 'geoserver-admin-password' } } },
        @{ name = 'PUBLIC_BASE_URL'; value = ('https://' + $Config.MAPS_HOSTNAME) },
        @{ name = 'POSTGIS_HOST'; value = 'platform-platform-infra-postgis.platform-infra.svc.cluster.local' },
        @{ name = 'POSTGIS_PORT'; value = '5432' },
        @{ name = 'POSTGIS_DATABASE'; value = 'gisdata' },
        @{ name = 'POSTGIS_USER'; valueFrom = @{ secretKeyRef = @{ name = 'gscloud-runtime'; key = 'pgconfig-username' } } },
        @{ name = 'POSTGIS_PASSWORD'; valueFrom = @{ secretKeyRef = @{ name = 'gscloud-runtime'; key = 'pgconfig-password' } } },
        @{ name = 'PGSTAC_HOST'; value = 'platform-platform-infra-pgstac.platform-infra.svc.cluster.local' },
        @{ name = 'PGSTAC_PORT'; value = '5432' },
        @{ name = 'PGSTAC_DATABASE'; value = 'stac' },
        @{ name = 'PGSTAC_USER'; valueFrom = @{ secretKeyRef = @{ name = 'gscloud-runtime'; key = 'stac-username' } } },
        @{ name = 'PGSTAC_PASSWORD'; valueFrom = @{ secretKeyRef = @{ name = 'gscloud-runtime'; key = 'stac-password' } } }
    )
}

function New-PublisherJobObject {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )
    return @{
        apiVersion = 'batch/v1'
        kind = 'Job'
        metadata = @{ name = $Name; namespace = $Config.GEOSERVER_NAMESPACE; labels = @{ 'app.kubernetes.io/name' = 'gscloud-publisher' } }
        spec = @{
            backoffLimit = 0
            ttlSecondsAfterFinished = 86400
            template = @{
                metadata = @{ labels = @{ 'app.kubernetes.io/name' = 'gscloud-publisher' } }
                spec = @{
                    restartPolicy = 'Never'
                    imagePullSecrets = @(@{ name = 'jcr-credentials' })
                    securityContext = @{ fsGroup = 1000 }
                    containers = @(@{
                        name = 'publisher'
                        image = Get-PublisherImage -Config $Config
                        imagePullPolicy = 'IfNotPresent'
                        args = $Arguments
                        env = New-PublisherEnvironment -Config $Config
                        securityContext = @{ allowPrivilegeEscalation = $false; capabilities = @{ drop = @('ALL') } }
                        volumeMounts = @(@{ name = 'geodata'; mountPath = '/data' })
                    })
                    volumes = @(@{ name = 'geodata'; persistentVolumeClaim = @{ claimName = 'gscloud-geodata' } })
                }
            }
        }
    }
}

function Invoke-PublisherJob {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Job,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )
    $name = $Job.metadata.name
    $path = Join-Path (Get-StateDir) ($name + '.json')
    Set-FileUtf8NoBom -Path $path -Content ($Job | ConvertTo-Json -Depth 20)
    Invoke-Native kubectl apply -f $path
    & kubectl -n $Config.GEOSERVER_NAMESPACE wait --for=condition=complete ('job/' + $name) --timeout=30m
    $completed = $LASTEXITCODE -eq 0
    kubectl -n $Config.GEOSERVER_NAMESPACE logs ('job/' + $name)
    if (-not $completed) { throw ('Publisher Job failed or timed out: ' + $name) }
}
