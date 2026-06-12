param()
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$helm = Get-HelmPath
$chart = Join-Path (Get-StateDir) ('rancher-' + $script:Versions.Rancher + '.tgz')
if (-not (Test-Path -LiteralPath $chart)) { throw 'Rancher chart is missing. Run Prepare-Online.ps1 first.' }

Invoke-Native kubectl create namespace $config.RANCHER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f - | Out-Null

kubectl -n $config.RANCHER_NAMESPACE create secret docker-registry jcr-credentials --docker-server=$($config.JCR_INTERNAL_HOST) --docker-username=$($config.JCR_USERNAME) --docker-password=$($config.JCR_PASSWORD) --dry-run=client -o yaml | kubectl apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not create Rancher registry secret.' }

$cert = Join-Path (Get-StateDir) 'certs\server.crt'
$key = Join-Path (Get-StateDir) 'certs\server.key'
$ca = Join-Path (Get-StateDir) 'certs\ca.crt'
kubectl -n $config.RANCHER_NAMESPACE create secret tls tls-rancher-ingress --cert=$cert --key=$key --dry-run=client -o yaml | kubectl apply -f - | Out-Null
kubectl -n $config.RANCHER_NAMESPACE create secret generic tls-ca --from-file=cacerts.pem=$ca --dry-run=client -o yaml | kubectl apply -f - | Out-Null

$args = @(
    'upgrade', '--install', 'rancher', $chart,
    '--namespace', $config.RANCHER_NAMESPACE,
    '--set-string', ('hostname=' + $config.RANCHER_HOSTNAME),
    '--set-string', ('bootstrapPassword=' + $config.RANCHER_BOOTSTRAP_PASSWORD),
    '--set', 'replicas=1',
    '--set-string', ('systemDefaultRegistry=' + $config.JCR_INTERNAL_HOST + '/' + $config.JCR_DOCKER_REPOSITORY),
    '--set', 'ingress.tls.source=secret',
    '--set', 'privateCA=true',
    '--set', 'useBundledSystemChart=true',
    '--set', 'imagePullSecrets[0].name=jcr-credentials',
    '--set', 'resources.requests.cpu=250m',
    '--set', 'resources.requests.memory=512Mi',
    '--set', 'resources.limits.cpu=2',
    '--set', 'resources.limits.memory=2Gi',
    '--wait', '--timeout', '15m'
)
Invoke-Native $helm @args
Invoke-Native kubectl -n $config.RANCHER_NAMESPACE rollout status deployment/rancher --timeout=600s
Write-Host ('Rancher is available at https://' + $config.RANCHER_HOSTNAME)
