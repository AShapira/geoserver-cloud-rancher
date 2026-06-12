param([switch]$Force)
. (Join-Path $PSScriptRoot 'Common.ps1')

New-Item -ItemType Directory -Force -Path (Get-ToolsDir) | Out-Null

$helm = Join-Path (Get-ToolsDir) 'helm.exe'
if ($Force -or -not (Test-Path -LiteralPath $helm)) {
    $zip = Join-Path $env:TEMP ('helm-v{0}-windows-amd64.zip' -f $script:Versions.Helm)
    Invoke-WebRequest -UseBasicParsing -Uri ('https://get.helm.sh/helm-v{0}-windows-amd64.zip' -f $script:Versions.Helm) -OutFile $zip
    $extract = Join-Path $env:TEMP ('helm-v{0}-extract' -f $script:Versions.Helm)
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $extract
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    Copy-Item -LiteralPath (Join-Path $extract 'windows-amd64\helm.exe') -Destination $helm -Force
}

$k3d = Join-Path (Get-ToolsDir) 'k3d.exe'
if ($Force -or -not (Test-Path -LiteralPath $k3d)) {
    Invoke-WebRequest -UseBasicParsing -Uri ('https://github.com/k3d-io/k3d/releases/download/v{0}/k3d-windows-amd64.exe' -f $script:Versions.K3d) -OutFile $k3d
}

Write-Host ('Helm: ' + (& $helm version --short))
Write-Host ('k3d: ' + (& $k3d version | Select-Object -First 1))
