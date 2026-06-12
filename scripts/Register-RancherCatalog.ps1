param()
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$ca = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path (Get-StateDir) 'certs\ca.crt')))

kubectl -n $config.RANCHER_NAMESPACE create secret generic jcr-helm-credentials --type=kubernetes.io/basic-auth --from-literal=username=$($config.JCR_USERNAME) --from-literal=password=$($config.JCR_PASSWORD) --dry-run=client -o yaml | kubectl apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not create Rancher OCI credentials.' }

foreach ($chart in @('geoserver-cloud-sim', 'platform-infra')) {
    $resource = @"
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: $chart-airgap
spec:
  url: oci://$($config.JCR_INTERNAL_HOST)/$($config.JCR_HELM_REPOSITORY)/$chart
  clientSecret:
    name: jcr-helm-credentials
    namespace: $($config.RANCHER_NAMESPACE)
  caBundle: $ca
  OCIOptions:
    downloadAllTags: true
"@
    $resource | kubectl apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not register Rancher OCI chart $chart" }
}

Write-Host 'Registered JCR OCI charts in Rancher Apps repositories.'
