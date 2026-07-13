#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $ResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $BackendAppName = 'ca-mercadona-retail-api',
    [string] $BackendContainerName = 'mercadona-retail-api',
    [int] $RequestCount = 64,
    [int] $MetricTimeoutSeconds = 600
)

. "$PSScriptRoot\AzureDemo.Common.ps1"

if ($RequestCount -ne 64) {
    throw 'RequestCount must remain exactly 64 for the deterministic 640 MiB capped demonstration.'
}

Assert-DemoAzureContext -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
$previousRevision = Get-ActiveContainerAppRevision `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName
$currentMemoryPerAdd = Get-ContainerAppRevisionEnvironmentVariableValue `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -RevisionName $previousRevision.name `
    -VariableName 'DEMO_CART_MEMORY_MB_PER_ADD'
if ($currentMemoryPerAdd -ne '0') {
    throw "The incident requires DEMO_CART_MEMORY_MB_PER_ADD=0 as its healthy baseline, but found '$currentMemoryPerAdd'. Run recovery before starting another incident."
}

$revisionSuffix = "i-$([DateTimeOffset]::UtcNow.ToString('yyMMddHHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 4))"
$expectedRevisionName = "$BackendAppName--$revisionSuffix"

New-ContainerAppRevisionFromActiveTemplate `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -SourceRevisionName $previousRevision.name `
    -ContainerName $BackendContainerName `
    -RevisionSuffix $revisionSuffix `
    -EnvironmentVariables @{
        DEMO_CART_MEMORY_MB_PER_ADD = '10'
        DEMO_CART_MEMORY_MAX_MB = '640'
    }

$revision = Wait-ContainerAppRevision `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -ExpectedRevisionName $expectedRevisionName

$fqdn = az containerapp show `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $BackendAppName `
    --query properties.configuration.ingress.fqdn `
    --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fqdn)) {
    throw 'Unable to resolve the backend FQDN.'
}

$startedAt = [DateTimeOffset]::UtcNow
$cartResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/carts" `
    -ContentType 'application/json' `
    -Body ((New-DemoCartPayload) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -SkipHttpErrorCheck
if ($cartResponse.StatusCode -ne 201) {
    throw "Cart creation expected HTTP 201 but received $($cartResponse.StatusCode)."
}
$cart = $cartResponse.Content | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($cart.cart.id) -or [string]::IsNullOrWhiteSpace($cart.correlationId)) {
    throw 'Cart creation did not return safe synthetic identifiers.'
}

for ($index = 1; $index -le $RequestCount; $index++) {
    if (([DateTimeOffset]::UtcNow - $startedAt).TotalMinutes -ge 5) {
        throw 'The 64 bounded valid cart additions were not completed within five minutes.'
    }

    $response = Invoke-WebRequest `
        -Method Post `
        -Uri "https://$fqdn/api/carts/$($cart.cart.id)/items" `
        -ContentType 'application/json' `
        -Body ((New-DemoAddItemPayload) | ConvertTo-Json -Compress) `
        -SkipHttpErrorCheck
    if ($response.StatusCode -ne 200) {
        throw "Valid add $index expected HTTP 200 but received $($response.StatusCode)."
    }
    $add = $response.Content | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($add.correlationId)) {
        throw "Valid add $index did not return a correlation ID."
    }
    Write-Host "[$index/$RequestCount] cart=$($cart.cart.id) correlationId=$($add.correlationId) retainedBytes=$($add.retainedBytes)"
}

$threshold = 629145600
$metricDeadline = (Get-Date).AddSeconds($MetricTimeoutSeconds)
do {
    $maximum = Get-ContainerAppWorkingSetMaximum `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ContainerAppName $BackendAppName `
        -StartTime $startedAt
    if ($null -ne $maximum) {
        Write-Host "revision=$($revision.name) WorkingSetBytes=$([long]$maximum)"
        if ($maximum -gt $threshold) {
            Write-Host "Synthetic incident verified above 600 MiB. Run .\scripts\recover-incident.ps1 immediately after the demo."
            return
        }
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $metricDeadline)

throw "WorkingSetBytes did not exceed $threshold within $MetricTimeoutSeconds seconds. Run recovery before troubleshooting."
