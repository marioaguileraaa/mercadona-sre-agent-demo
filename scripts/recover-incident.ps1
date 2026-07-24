#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $ResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $BackendAppName = 'ca-mercadona-retail-api',
    [string] $BackendContainerName = 'mercadona-retail-api',
    [ValidateRange(30, 900)]
    [int] $AlertTimeoutSeconds = 300
)

. "$PSScriptRoot\AzureDemo.Common.ps1"

$alertName = 'alert-mercadona-cart-5xx-sev3'
$alertRuleId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/metricAlerts/$alertName"
$backendResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/$BackendAppName"

Assert-DemoAzureContext -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
$previousRevision = Get-ActiveContainerAppRevision `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName
Assert-ContainerAppSingleReadyRevision `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -ExpectedRevisionName $previousRevision.name

$currentMemoryPerAdd = Get-ContainerAppRevisionEnvironmentVariableValue `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -RevisionName $previousRevision.name `
    -VariableName 'DEMO_CART_MEMORY_MB_PER_ADD'
$currentFailureThreshold = Get-ContainerAppRevisionEnvironmentVariableValue `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -RevisionName $previousRevision.name `
    -VariableName 'DEMO_CART_MEMORY_FAILURE_MB'
$currentMemoryCap = Get-ContainerAppRevisionEnvironmentVariableValue `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -RevisionName $previousRevision.name `
    -VariableName 'DEMO_CART_MEMORY_MAX_MB'

if ($currentMemoryPerAdd -ne '0' -or $currentFailureThreshold -ne '0' -or $currentMemoryCap -ne '640') {
    $revisionSuffix = "r-$([DateTimeOffset]::UtcNow.ToString('yyMMddHHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 4))"
    $expectedRevisionName = "$BackendAppName--$revisionSuffix"
    New-ContainerAppRevisionFromActiveTemplate `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ContainerAppName $BackendAppName `
        -SourceRevisionName $previousRevision.name `
        -ContainerName $BackendContainerName `
        -RevisionSuffix $revisionSuffix `
        -EnvironmentVariables @{
            DEMO_CART_MEMORY_MB_PER_ADD = '0'
            DEMO_CART_MEMORY_MAX_MB = '640'
            DEMO_CART_MEMORY_FAILURE_MB = '0'
        }

    $revision = Wait-ContainerAppRevision `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ContainerAppName $BackendAppName `
        -ExpectedRevisionName $expectedRevisionName
} else {
    $revision = Wait-ContainerAppRevision `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ContainerAppName $BackendAppName `
        -ExpectedRevisionName $previousRevision.name
    Write-Host 'Memory injection and controlled failure were already disabled; reusing the healthy active revision.'
}

$fqdn = Get-ContainerAppFqdn `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName
$correlationId = "SYNTH-RECOVERY-$([Guid]::NewGuid().ToString('N'))"

$cartResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/carts" `
    -ContentType 'application/json' `
    -Headers @{ 'X-Correlation-ID' = $correlationId } `
    -Body ((New-DemoCartPayload) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -TimeoutSec 15 `
    -SkipHttpErrorCheck
if ($cartResponse.StatusCode -ne 201) {
    throw "Recovery cart expected HTTP 201 but received $($cartResponse.StatusCode)."
}
$cart = $cartResponse.Content | ConvertFrom-Json

$addResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/carts/$($cart.cart.id)/items" `
    -ContentType 'application/json' `
    -Headers @{ 'X-Correlation-ID' = $correlationId } `
    -Body ((New-DemoAddItemPayload) | ConvertTo-Json -Compress) `
    -TimeoutSec 15 `
    -SkipHttpErrorCheck
if ($addResponse.StatusCode -ne 200) {
    throw "Recovery add expected HTTP 200 but received $($addResponse.StatusCode)."
}
$add = $addResponse.Content | ConvertFrom-Json
if ($add.correlationId -ne $correlationId -or [long]$add.allocationBytes -ne 0) {
    throw 'Recovery add did not preserve correlation ID or unexpectedly retained memory.'
}

$orderResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/orders" `
    -ContentType 'application/json' `
    -Headers @{ 'X-Correlation-ID' = $correlationId } `
    -Body ((New-DemoOrderPayload -CartId $cart.cart.id) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -TimeoutSec 15 `
    -SkipHttpErrorCheck
if ($orderResponse.StatusCode -ne 201) {
    throw "Recovery order expected HTTP 201 but received $($orderResponse.StatusCode)."
}
$order = $orderResponse.Content | ConvertFrom-Json

$trackingResponse = Invoke-WebRequest `
    -Method Get `
    -Uri "https://$fqdn/api/orders/$($order.order.id)/tracking" `
    -Headers @{ 'X-Correlation-ID' = $correlationId } `
    -TimeoutSec 15 `
    -SkipHttpErrorCheck
if ($trackingResponse.StatusCode -ne 200) {
    throw "Recovery tracking expected HTTP 200 but received $($trackingResponse.StatusCode)."
}

$alertDeadline = (Get-Date).AddSeconds($AlertTimeoutSeconds)
do {
    $fired = @(Get-FiredContainerAppAlert `
            -SubscriptionId $SubscriptionId `
            -AlertRuleId $alertRuleId `
            -TargetResourceId $backendResourceId `
            -StartTime ([DateTimeOffset]::MinValue))
    if ($fired.Count -eq 0) {
        Write-Host "Recovery verified. revision=$($revision.name) orderId=$($order.order.id) correlationId=$correlationId"
        return
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $alertDeadline)

Write-Warning "Healthy cart-to-tracking recovery passed on '$($revision.name)', but Azure Monitor still reports the exact 5xx alert Fired after $AlertTimeoutSeconds seconds. Do not inject another incident until it resolves."
