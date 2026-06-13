param()
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-Path -LiteralPath $script:ConfigPath)) { & (Join-Path $PSScriptRoot 'Initialize-State.ps1') -SkipTrust }
$helm = Get-HelmPath
$errors = @()

foreach ($file in Get-ChildItem -Path (Join-Path (Get-RepoRoot) 'scripts') -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { $errors += $parseErrors | ForEach-Object { $file.Name + ': ' + $_.Message } }
}
if ($errors.Count) { throw ($errors -join "`n") }

Invoke-Native python -m py_compile (Join-Path (Get-RepoRoot) 'publisher\publisher.py') (Join-Path (Get-RepoRoot) 'publisher\generate_demo.py')
[void](Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'publishing\dataset-release.schema.json') | ConvertFrom-Json)
if ((Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'stac-browser\basemaps.config.js')) -match 'https?://') { throw 'STAC Browser basemap configuration contains a remote URL.' }

Push-Location (Join-Path (Get-RepoRoot) 'viewer')
try {
    Invoke-Native npm.cmd ci --ignore-scripts
    Invoke-Native npm.cmd audit --audit-level=high
    Invoke-Native npm.cmd run build
} finally { Pop-Location }

$geo = Join-Path (Get-RepoRoot) 'charts\geoserver-cloud-sim'
$infra = Join-Path (Get-RepoRoot) 'charts\platform-infra'
$helmHome = Join-Path (Get-StateDir) 'helm-static'
$env:HELM_CONFIG_HOME = Join-Path $helmHome 'config'
$env:HELM_CACHE_HOME = Join-Path $helmHome 'cache'
$env:HELM_DATA_HOME = Join-Path $helmHome 'data'
New-Item -ItemType Directory -Force -Path $env:HELM_CONFIG_HOME, $env:HELM_CACHE_HOME, $env:HELM_DATA_HOME | Out-Null
& $helm repo add gscloud https://camptocamp.github.io/helm-geoserver-cloud --force-update | Out-Null
Invoke-Native $helm dependency update $geo
Invoke-Native $helm lint $infra
Invoke-Native $helm lint $geo

$rendered = Join-Path (Get-StateDir) 'rendered.yaml'
& $helm template gscloud $geo --namespace gscloud | Out-File -Encoding utf8 $rendered
if ($LASTEXITCODE -ne 0) { throw 'GeoServer chart rendering failed.' }
& $helm template platform $infra --namespace platform-infra | Out-File -Encoding utf8 -Append $rendered
if ($LASTEXITCODE -ne 0) { throw 'Platform chart rendering failed.' }

$publicImages = Select-String -Path $rendered -Pattern '^\s*image:\s*["'']?(?!jcr-proxy:8443/docker-local)([^"''\s]+)' | ForEach-Object { $_.Line.Trim() }
if ($publicImages) { throw ('Rendered public image references remain: ' + ($publicImages -join ', ')) }

Invoke-Native docker compose --env-file $script:ConfigPath -f (Join-Path (Get-RepoRoot) 'infra\jcr\docker-compose.yml') config --quiet
Write-Host 'Static checks passed: PowerShell, npm audit/build, Helm lint/render, image policy, and Compose config.'
