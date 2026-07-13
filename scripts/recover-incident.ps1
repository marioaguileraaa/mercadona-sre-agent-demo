#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $ResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $BackendAppName = 'ca-mercadona-retail-api',
    [int] $MetricTimeoutSeconds = 300
)

. "$PSScriptRoot\AzureDemo.Common.ps1"

Assert-DemoAzureContext -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
$previousRevision = Get-LatestContainerAppRevision `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName
az containerapp update `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $BackendAppName `
    --set-env-vars DEMO_CART_MEMORY_MB_PER_ADD=0 DEMO_CART_MEMORY_MAX_MB=640 `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to disable the deterministic cart-memory incident.'
}

$revision = Wait-ContainerAppRevision `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -PreviousRevisionName $previousRevision.name
$recoveryStartedAt = [DateTimeOffset]::UtcNow

$fqdn = az containerapp show `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $BackendAppName `
    --query properties.configuration.ingress.fqdn `
    --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fqdn)) {
    throw 'Unable to resolve the backend FQDN.'
}

$cartResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/carts" `
    -ContentType 'application/json' `
    -Body ((New-DemoCartPayload) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -SkipHttpErrorCheck
if ($cartResponse.StatusCode -ne 201) {
    throw "Recovery cart expected HTTP 201 but received $($cartResponse.StatusCode)."
}
$cart = $cartResponse.Content | ConvertFrom-Json

$addResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/carts/$($cart.cart.id)/items" `
    -ContentType 'application/json' `
    -Body ((New-DemoAddItemPayload) | ConvertTo-Json -Compress) `
    -SkipHttpErrorCheck
if ($addResponse.StatusCode -ne 200) {
    throw "Recovery add expected HTTP 200 but received $($addResponse.StatusCode)."
}
$add = $addResponse.Content | ConvertFrom-Json
if ($add.allocationBytes -ne 0) {
    throw "Recovery add unexpectedly retained $($add.allocationBytes) bytes."
}

$orderResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/orders" `
    -ContentType 'application/json' `
    -Body ((New-DemoOrderPayload -CartId $cart.cart.id) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -SkipHttpErrorCheck
if ($orderResponse.StatusCode -ne 201) {
    throw "Recovery order expected HTTP 201 but received $($orderResponse.StatusCode)."
}
$order = $orderResponse.Content | ConvertFrom-Json

$trackingResponse = Invoke-WebRequest `
    -Method Get `
    -Uri "https://$fqdn/api/orders/$($order.order.id)/tracking" `
    -SkipHttpErrorCheck
if ($trackingResponse.StatusCode -ne 200) {
    throw "Recovery tracking expected HTTP 200 but received $($trackingResponse.StatusCode)."
}

$threshold = 629145600
$metricDeadline = (Get-Date).AddSeconds($MetricTimeoutSeconds)
do {
    $maximum = Get-ContainerAppWorkingSetMaximum `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ContainerAppName $BackendAppName `
        -StartTime $recoveryStartedAt `
        -Latest
    if ($null -ne $maximum) {
        Write-Host "revision=$($revision.name) WorkingSetBytes=$([long]$maximum)"
        if ($maximum -lt $threshold) {
            Write-Host "Recovery verified. orderId=$($order.order.id) correlationId=$($add.correlationId)"
            return
        }
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $metricDeadline)

Write-Warning "Healthy recovery flow passed on new revision '$($revision.name)', but a below-threshold metric sample was not available within $MetricTimeoutSeconds seconds."
