[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CollectionId,
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$RemoveCollection,
    [switch]$Force
)
. (Join-Path $PSScriptRoot 'Publishing.ps1')

if (-not $Force) {
    $expected = $CollectionId + '/' + $Version
    $confirmation = Read-Host ('Type ' + $expected + ' to confirm full unpublish')
    if ($confirmation -ne $expected) { throw 'Unpublish cancelled.' }
}
if (-not (Test-Path -LiteralPath $script:ConfigPath)) { & (Join-Path $PSScriptRoot 'Initialize-State.ps1') -SkipTrust }
$config = Get-Config
$runId = ([Guid]::NewGuid().ToString('N')).Substring(0, 12)
$arguments = @('unpublish', '--collection', $CollectionId, '--version', $Version)
if ($RemoveCollection) { $arguments += '--remove-collection' }
$job = New-PublisherJobObject -Name ('unpublish-data-' + $runId) -Config $config -Arguments $arguments
Invoke-PublisherJob -Job $job -Config $config
Write-Host ('Unpublished ' + $CollectionId + '/' + $Version)
