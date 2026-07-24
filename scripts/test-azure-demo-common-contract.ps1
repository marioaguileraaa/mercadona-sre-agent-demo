#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\AzureDemo.Common.ps1"

function Assert-Equal {
    param(
        [AllowNull()]
        [object] $Actual,
        [AllowNull()]
        [object] $Expected,
        [Parameter(Mandatory)]
        [string] $Case
    )

    if ($Actual -ne $Expected) {
        throw "$Case failed. Expected '$Expected', got '$Actual'."
    }
}

$metric = @'
{
  "value": [
    {
      "timeseries": [
        {
          "data": [
            { "timeStamp": "2026-07-13T13:20:00Z" },
            { "timeStamp": "2026-07-13T13:21:00Z", "maximum": null },
            { "timeStamp": "2026-07-13T13:22:00Z", "maximum": 650117120 },
            { "timeStamp": "2026-07-13T13:23:00Z", "maximum": 671088640 }
          ]
        }
      ]
    }
  ]
}
'@ | ConvertFrom-Json

$samples = @(Get-MetricMaximumSamples -Metric $metric)
Assert-Equal -Actual $samples.Count -Expected 2 -Case 'Missing and null maximum samples'
Assert-Equal -Actual $samples[0].maximum -Expected 650117120 -Case 'First maximum value'
Assert-Equal -Actual $samples[1].maximum -Expected 671088640 -Case 'Second maximum value'
Assert-Equal `
    -Actual $samples[1].timeStamp.ToUniversalTime().ToString('o') `
    -Expected '2026-07-13T13:23:00.0000000Z' `
    -Case 'Maximum timestamp'

$missingSeries = '{"value":[{},{"timeseries":[{},{"data":null}]}]}' | ConvertFrom-Json
Assert-Equal `
    -Actual @(Get-MetricMaximumSamples -Metric $missingSeries).Count `
    -Expected 0 `
    -Case 'Missing metric series properties'
Assert-Equal `
    -Actual @(Get-MetricMaximumSamples -Metric $null).Count `
    -Expected 0 `
    -Case 'Null metric response'

$requestMetric = @'
{
  "value": [
    {
      "timeseries": [
        {
          "data": [
            { "timeStamp": "2026-07-13T13:20:00Z", "total": 2 },
            { "timeStamp": "2026-07-13T13:21:00Z", "total": 4 }
          ]
        }
      ]
    }
  ]
}
'@ | ConvertFrom-Json
$totalSamples = @(Get-MetricTotalSamples -Metric $requestMetric)
Assert-Equal -Actual $totalSamples.Count -Expected 2 -Case '5xx total sample count'
Assert-Equal -Actual (($totalSamples.total | Measure-Object -Sum).Sum) -Expected 6 -Case '5xx total sum'

$commonSource = Get-Content -LiteralPath "$PSScriptRoot\AzureDemo.Common.ps1" -Raw
$startSource = Get-Content -LiteralPath "$PSScriptRoot\start-incident.ps1" -Raw
$recoverySource = Get-Content -LiteralPath "$PSScriptRoot\recover-incident.ps1" -Raw
foreach ($source in @($startSource, $recoverySource)) {
    foreach ($requiredContract in @(
            'Get-ActiveContainerAppRevision',
            'Get-ContainerAppRevisionEnvironmentVariableValue',
            'New-ContainerAppRevisionFromActiveTemplate',
            '-SourceRevisionName $previousRevision.name',
            '-RevisionSuffix $revisionSuffix',
            '-ExpectedRevisionName',
            'DEMO_CART_MEMORY_FAILURE_MB'
        )) {
        if (-not $source.Contains($requiredContract, [StringComparison]::Ordinal)) {
            throw "Incident lifecycle script did not preserve '$requiredContract'."
        }
    }
}
if (-not $commonSource.Contains('--all', [StringComparison]::Ordinal) -or
    -not $commonSource.Contains("PSObject.Properties['active']", [StringComparison]::Ordinal) -or
    -not $commonSource.Contains('--method patch', [StringComparison]::Ordinal) -or
    -not $commonSource.Contains('latestReadyRevisionName', [StringComparison]::Ordinal)) {
    throw 'Active revision filtering contract was not found.'
}
if (-not $commonSource.Contains('function Assert-ContainerAppSingleReadyRevision', [StringComparison]::Ordinal) -or
    -not $recoverySource.Contains('Assert-ContainerAppSingleReadyRevision', [StringComparison]::Ordinal)) {
    throw 'Idempotent recovery no longer validates Single mode and the latest ready revision.'
}
if (-not $commonSource.Contains('Authorization = "Bearer $token"', [StringComparison]::Ordinal)) {
    throw 'SRE Agent data-plane reads do not use the acquired bearer token.'
}
if ($commonSource.Contains('Authorization = "******"', [StringComparison]::Ordinal)) {
    throw 'SRE Agent data-plane reads use a masked placeholder instead of the acquired bearer token.'
}
if ($recoverySource.Contains("-notin @('0', '10')", [StringComparison]::Ordinal)) {
    throw 'Recovery still rejects supported nonzero retention settings.'
}
if ($startSource.Contains('az containerapp revision copy', [StringComparison]::Ordinal) -or
    $recoverySource.Contains('az containerapp revision copy', [StringComparison]::Ordinal)) {
    throw 'Incident lifecycle still depends on the Azure CLI revision-copy container merge path.'
}
if (-not $startSource.Contains('$BackendAppName--$revisionSuffix', [StringComparison]::Ordinal) -or
    -not $recoverySource.Contains('$BackendAppName--$revisionSuffix', [StringComparison]::Ordinal)) {
    throw 'Expected custom revision names no longer match the Container Apps name format.'
}

$script:capturedAuthorization = $null
function az {
    if (($args -join ' ') -notmatch '^account get-access-token ') {
        throw "Unexpected fake Azure CLI call: $($args -join ' ')"
    }
    $global:LASTEXITCODE = 0
    return 'fake-token'
}
function Invoke-RestMethod {
    param(
        [string] $Method,
        [string] $Uri,
        [hashtable] $Headers,
        [int] $MaximumRedirection
    )

    $script:capturedAuthorization = $Headers.Authorization
    return [pscustomobject]@{ status = 'synthetic-ok' }
}

Invoke-SreAgentRead -Endpoint 'https://synthetic.invalid' -Path '/api/v1/threads' | Out-Null
Assert-Equal `
    -Actual $script:capturedAuthorization `
    -Expected 'Bearer fake-token' `
    -Case 'SRE Agent read sends acquired bearer token'

Write-Host 'Azure demo common metric contract passed.'
