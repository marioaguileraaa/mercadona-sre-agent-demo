#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $ResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $BackendAppName = 'ca-mercadona-retail-api',
    [string] $BackendContainerName = 'mercadona-retail-api',
    [string] $AgentName = 'sre-agent-mercadona-v1',
    [ValidateRange(6, 200)]
    [int] $MaxRequests = 80,
    [ValidateRange(30, 600)]
    [int] $LoadTimeoutSeconds = 300,
    [ValidateRange(5, 60)]
    [int] $RequestTimeoutSeconds = 15,
    [ValidateRange(60, 1800)]
    [int] $MetricTimeoutSeconds = 600,
    [ValidateRange(60, 1800)]
    [int] $ThreadTimeoutSeconds = 600
)

. "$PSScriptRoot\AzureDemo.Common.ps1"

$alertName = 'alert-mercadona-cart-5xx-sev3'
$alertRuleId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/metricAlerts/$alertName"
$backendResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/$BackendAppName"
$responsePlanName = 'mercadona-cart-5xx-sev3'
$required5xx = 6

Assert-DemoAzureContext -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
& "$PSScriptRoot\verify-sre-agent.ps1" `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -AgentName $AgentName `
    -BackendAppName $BackendAppName
if (-not $?) {
    throw 'SRE Agent verification failed before incident mutation.'
}

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
    throw "Healthy baseline requires DEMO_CART_MEMORY_MB_PER_ADD=0, DEMO_CART_MEMORY_FAILURE_MB=0 and DEMO_CART_MEMORY_MAX_MB=640. Found '$currentMemoryPerAdd', '$currentFailureThreshold', '$currentMemoryCap'. Run recovery first."
}

$fqdn = Get-ContainerAppFqdn `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName
$baselineStart = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$baseline5xx = Get-ContainerAppRequest5xxTotal `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -StartTime $baselineStart
if ($baseline5xx -gt 0) {
    throw "Healthy baseline contains $baseline5xx recent 5xx requests. Wait for the five-minute window or recover before starting."
}
$existingAlert = @(Get-FiredContainerAppAlert `
        -SubscriptionId $SubscriptionId `
        -AlertRuleId $alertRuleId `
        -TargetResourceId $backendResourceId `
        -StartTime ([DateTimeOffset]::MinValue))
if ($existingAlert.Count -gt 0) {
    throw "The exact retail alert '$alertName' is already Fired. Recover and wait for resolution before starting."
}

$baselineCorrelation = "SYNTH-BASELINE-$([Guid]::NewGuid().ToString('N'))"
$baselineCartResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/carts" `
    -ContentType 'application/json' `
    -Headers @{ 'X-Correlation-ID' = $baselineCorrelation } `
    -Body ((New-DemoCartPayload) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -TimeoutSec $RequestTimeoutSeconds `
    -SkipHttpErrorCheck
if ($baselineCartResponse.StatusCode -ne 201) {
    throw "Healthy baseline cart expected HTTP 201 but received $($baselineCartResponse.StatusCode)."
}
$baselineCart = $baselineCartResponse.Content | ConvertFrom-Json
$baselineAddResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/carts/$($baselineCart.cart.id)/items" `
    -ContentType 'application/json' `
    -Headers @{ 'X-Correlation-ID' = $baselineCorrelation } `
    -Body ((New-DemoAddItemPayload) | ConvertTo-Json -Compress) `
    -TimeoutSec $RequestTimeoutSeconds `
    -SkipHttpErrorCheck
if ($baselineAddResponse.StatusCode -ne 200) {
    throw "Healthy baseline add expected HTTP 200 but received $($baselineAddResponse.StatusCode)."
}
$baselineAdd = $baselineAddResponse.Content | ConvertFrom-Json
if ($baselineAdd.correlationId -ne $baselineCorrelation -or [long]$baselineAdd.allocationBytes -ne 0) {
    throw 'Healthy baseline did not preserve correlation ID or unexpectedly retained memory.'
}
$baselineOrderResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/orders" `
    -ContentType 'application/json' `
    -Headers @{ 'X-Correlation-ID' = $baselineCorrelation } `
    -Body ((New-DemoOrderPayload -CartId $baselineCart.cart.id) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -TimeoutSec $RequestTimeoutSeconds `
    -SkipHttpErrorCheck
if ($baselineOrderResponse.StatusCode -ne 201) {
    throw "Healthy baseline order expected HTTP 201 but received $($baselineOrderResponse.StatusCode)."
}
$baselineOrder = $baselineOrderResponse.Content | ConvertFrom-Json
$baselineTrackingResponse = Invoke-WebRequest `
    -Method Get `
    -Uri "https://$fqdn/api/orders/$($baselineOrder.order.id)/tracking" `
    -Headers @{ 'X-Correlation-ID' = $baselineCorrelation } `
    -TimeoutSec $RequestTimeoutSeconds `
    -SkipHttpErrorCheck
if ($baselineTrackingResponse.StatusCode -ne 200) {
    throw "Healthy baseline tracking expected HTTP 200 but received $($baselineTrackingResponse.StatusCode)."
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
        DEMO_CART_MEMORY_FAILURE_MB = '600'
    }

$revision = Wait-ContainerAppRevision `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName `
    -ExpectedRevisionName $expectedRevisionName
$startedAt = [DateTimeOffset]::UtcNow

$cartCorrelation = "SYNTH-CART-$([Guid]::NewGuid().ToString('N'))"
$cartResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://$fqdn/api/carts" `
    -ContentType 'application/json' `
    -Headers @{ 'X-Correlation-ID' = $cartCorrelation } `
    -Body ((New-DemoCartPayload) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -TimeoutSec $RequestTimeoutSeconds `
    -SkipHttpErrorCheck
if ($cartResponse.StatusCode -ne 201) {
    throw "Incident cart creation expected HTTP 201 but received $($cartResponse.StatusCode). Run recovery before troubleshooting."
}
$cart = $cartResponse.Content | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($cart.cart.id) -or $cart.correlationId -ne $cartCorrelation) {
    throw 'Incident cart creation did not preserve its synthetic correlation ID.'
}

$loadDeadline = (Get-Date).AddSeconds($LoadTimeoutSeconds)
$fiveXxCount = 0
$requestCount = 0
while ($requestCount -lt $MaxRequests -and (Get-Date) -lt $loadDeadline -and $fiveXxCount -lt $required5xx) {
    $requestCount++
    $correlationId = "SYNTH-CART5XX-$requestCount-$([Guid]::NewGuid().ToString('N'))"
    $response = Invoke-WebRequest `
        -Method Post `
        -Uri "https://$fqdn/api/carts/$($cart.cart.id)/items" `
        -ContentType 'application/json' `
        -Headers @{ 'X-Correlation-ID' = $correlationId } `
        -Body ((New-DemoAddItemPayload) | ConvertTo-Json -Compress) `
        -MaximumRedirection 0 `
        -TimeoutSec $RequestTimeoutSeconds `
        -SkipHttpErrorCheck

    $body = $response.Content | ConvertFrom-Json
    $responseCorrelation = [string]$body.correlationId
    $headerCorrelation = [string]$response.Headers['X-Correlation-ID']
    if ($responseCorrelation -ne $correlationId -or $headerCorrelation -ne $correlationId) {
        throw "Request $requestCount did not preserve correlation ID '$correlationId'. Run recovery before troubleshooting."
    }

    if ($response.StatusCode -ge 500 -and $response.StatusCode -le 599) {
        if ($response.StatusCode -ne 503 -or
            $body.errorCode -ne 'DEMO_CART_MEMORY_CAPACITY_EXHAUSTED' -or
            [long]$body.allocationBytes -ne 0) {
            throw "Request $requestCount returned unexpected HTTP $($response.StatusCode) or an invalid capacity payload."
        }
        $fiveXxCount++
        Write-Host "[$requestCount/$MaxRequests] http=$($response.StatusCode) fiveXx=$fiveXxCount correlationId=$correlationId retainedBytes=$($body.retainedBytes)"
    } elseif ($response.StatusCode -eq 200) {
        Write-Host "[$requestCount/$MaxRequests] http=200 correlationId=$correlationId retainedBytes=$($body.retainedBytes)"
    } else {
        throw "Request $requestCount returned unexpected HTTP $($response.StatusCode). Run recovery before troubleshooting."
    }
}

if ($fiveXxCount -lt $required5xx) {
    throw "Finite injector stopped after $requestCount requests and $fiveXxCount HTTP 5xx responses. Required $required5xx. Run recovery before troubleshooting."
}
Write-Host "Finite injector stopped automatically after confirming $fiveXxCount HTTP 5xx responses."

$metricDeadline = (Get-Date).AddSeconds($MetricTimeoutSeconds)
$metric5xx = 0
do {
    $metric5xx = Get-ContainerAppRequest5xxTotal `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ContainerAppName $BackendAppName `
        -StartTime $startedAt
    Write-Host "revision=$($revision.name) Requests5xx=$metric5xx"
    if ($metric5xx -gt 5) {
        break
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $metricDeadline)
if ($metric5xx -le 5) {
    throw "Requests 5xx did not exceed 5 within $MetricTimeoutSeconds seconds. Run recovery before troubleshooting."
}

$firedAlert = $null
$alertDeadline = (Get-Date).AddSeconds($MetricTimeoutSeconds)
do {
    $matchingAlerts = @(Get-FiredContainerAppAlert `
            -SubscriptionId $SubscriptionId `
            -AlertRuleId $alertRuleId `
            -TargetResourceId $backendResourceId `
            -StartTime $startedAt)
    if ($matchingAlerts.Count -gt 0) {
        $firedAlert = $matchingAlerts[0]
        break
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $alertDeadline)
if ($null -eq $firedAlert) {
    throw "Exact Sev3 alert '$alertName' did not reach Fired within $MetricTimeoutSeconds seconds. Do not start a second incident; recover first."
}
Write-Host "Alert Fired: rule=$alertName resource=$BackendAppName severity=Sev3"

$endpoint = Get-SreAgentEndpoint `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -AgentName $AgentName
$thread = $null
$threadDeadline = (Get-Date).AddSeconds($ThreadTimeoutSeconds)
do {
    $thread = @(Get-SreAgentThreads -Endpoint $endpoint | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.title) -and
            $_.title.Contains($alertName, [StringComparison]::OrdinalIgnoreCase) -and
            [DateTimeOffset]$_.createdTimestamp -ge $startedAt
        } | Sort-Object { [DateTimeOffset]$_.createdTimestamp } -Descending | Select-Object -First 1)[0]
    if ($null -ne $thread) {
        break
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $threadDeadline)
if ($null -eq $thread) {
    throw "Azure SRE Agent did not create a new thread for '$alertName' within $ThreadTimeoutSeconds seconds. The incident remains active; recover before retrying."
}

$threadDetails = Invoke-SreAgentRead -Endpoint $endpoint -Path "/api/v1/threads/$($thread.id)"
$threadJson = $threadDetails | ConvertTo-Json -Depth 30 -Compress
if ($threadJson.Contains($responsePlanName, [StringComparison]::OrdinalIgnoreCase) -and
    ($threadJson.Contains($alertRuleId, [StringComparison]::OrdinalIgnoreCase) -or
     $threadJson.Contains($alertName, [StringComparison]::OrdinalIgnoreCase))) {
    Write-Host "Thread association verified: threadId=$($thread.id) responsePlan=$responsePlanName"
} else {
    Write-Warning "Thread '$($thread.id)' was created for the exact alert, but this preview API did not expose response-plan metadata. Manual check: Azure SRE Agent portal > thread > Details > Response plan must be '$responsePlanName'."
}

Write-Host "Synthetic incident verified without automatic recovery. threadId=$($thread.id) cartId=$($cart.cart.id). Run .\scripts\recover-incident.ps1 only when the demo operator chooses to recover."
