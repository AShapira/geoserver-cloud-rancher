param([string]$Duration = '30s')
. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-Config
$reports = Join-Path (Get-RepoRoot) 'reports'
New-Item -ItemType Directory -Force -Path $reports | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $reports ('tuning-' + $stamp + '.md')
$k6Image = Get-JcrRuntimeImage -SourceImage $script:Versions.K6Image -Config $config
$scriptPath = Join-Path (Get-RepoRoot) 'tests\k6\protocol.js'

kubectl -n $config.GEOSERVER_NAMESPACE create configmap k6-protocol --from-file=protocol.js=$scriptPath --dry-run=client -o yaml | kubectl apply -f - | Out-Null
$lines = @('# GeoServer Cloud tuning report', '', ('Generated: ' + (Get-Date -Format o)), '', '| VUs | Result | Checks | HTTP failures | Avg latency | p95 latency |', '| ---: | --- | ---: | ---: | ---: | ---: |')

foreach ($vus in @(1, 5, 20)) {
    $job = 'k6-' + $vus + '-' + $stamp.ToLower()
    $yaml = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $($config.GEOSERVER_NAMESPACE)
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: jcr-credentials
      containers:
        - name: k6
          image: $k6Image
          args: ["run", "/scripts/protocol.js"]
          env:
            - name: VUS
              value: "$vus"
            - name: DURATION
              value: "$Duration"
            - name: BASE_URL
              value: http://gscloud-gsc-gateway.gscloud.svc.cluster.local:8080/geoserver-cloud
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: k6-protocol
"@
    $yaml | kubectl apply -f - | Out-Null
    & kubectl -n $config.GEOSERVER_NAMESPACE wait --for=condition=complete ('job/' + $job) --timeout=300s
    $status = if ($LASTEXITCODE -eq 0) { 'completed' } else { 'failed' }
    $logPath = Join-Path $reports ($job + '.log')
    kubectl -n $config.GEOSERVER_NAMESPACE logs ('job/' + $job) | Out-File -Encoding utf8 $logPath
    $log = Get-Content -Raw -LiteralPath $logPath
    $checks = [regex]::Match($log, 'checks\.*:\s+([0-9.]+%)').Groups[1].Value
    $failures = [regex]::Match($log, 'http_req_failed\.*:\s+([0-9.]+%)').Groups[1].Value
    $duration = [regex]::Match($log, 'http_req_duration\.*:\s+avg=([^\s]+).*?p\(95\)=([^\s]+)', [Text.RegularExpressions.RegexOptions]::Singleline)
    $average = $duration.Groups[1].Value
    $p95 = $duration.Groups[2].Value
    $lines += ('| {0} | {1}; `{2}` | {3} | {4} | {5} | {6} |' -f $vus, $status, [IO.Path]::GetFileName($logPath), $checks, $failures, $average, $p95)
}

$lines += @('', '## Pod resources', '```text')
$lines += @(kubectl top pods -n $config.GEOSERVER_NAMESPACE 2>&1)
$lines += @('```', '', '## PostgreSQL connections', '```text')
$postgisPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=postgis -o jsonpath='{.items[0].metadata.name}'
$lines += @(kubectl -n $config.PLATFORM_NAMESPACE exec $postgisPod -- psql -U postgres -d gscloud_config -tAc 'SELECT count(*) FROM pg_stat_activity;')
$lines += @('```', '', '## RabbitMQ queues', '```text')
$rabbitPod = kubectl -n $config.PLATFORM_NAMESPACE get pod -l app.kubernetes.io/component=rabbitmq -o jsonpath='{.items[0].metadata.name}'
$lines += @(kubectl -n $config.PLATFORM_NAMESPACE exec $rabbitPod -- rabbitmqctl list_queues name messages consumers)
$lines += '```'
[IO.File]::WriteAllLines($reportPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('Tuning report: ' + $reportPath)
