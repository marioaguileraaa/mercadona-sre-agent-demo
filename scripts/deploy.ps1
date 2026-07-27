#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $ResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $Location = 'eastus2',
    [string] $BackendAppName = 'ca-mercadona-retail-api',
    [string] $FrontendAppName = 'ca-mercadona-retail-web',
    [string] $ImageTag = (Get-Date -Format 'yyyyMMddHHmmss')
)

. "$PSScriptRoot\AzureDemo.Common.ps1"
. "$PSScriptRoot\SreAgent.WhatIf.ps1"

Assert-DemoAzureContext -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroupName", 'Run two-pass Bicep deployment with remote ACR builds and smoke tests')) {
    return
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$initialDeploymentName = "mercadona-sre-initial-$ImageTag"
$finalDeploymentName = "mercadona-sre-final-$ImageTag"
$retailResourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$arcResourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName"
$agentResourceId = "$retailResourceGroupId/providers/Microsoft.App/agents/sre-agent-mercadona-v1"
$requiredManagedResourceIds = @($retailResourceGroupId, $arcResourceGroupId)

function Invoke-GuardedGroupDeployment {
    param(
        [Parameter(Mandatory)]
        [string] $DeploymentName,
        [Parameter(Mandatory)]
        [string[]] $TemplateParameters,
        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    $baseArguments = @(
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $DeploymentName,
        '--template-file', "$repoRoot\infra\main.bicep",
        '--parameters'
    ) + $TemplateParameters
    $whatIfArguments = @(
        'deployment', 'group', 'what-if'
    ) + $baseArguments + @(
        '--result-format', 'FullResourcePayloads',
        '--output', 'json'
    )
    $whatIfJson = & az @whatIfArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment what-if failed for '$DeploymentName'."
    }
    try {
        $whatIf = ($whatIfJson -join [Environment]::NewLine) |
            ConvertFrom-Json -Depth 100
    } catch {
        throw "Deployment what-if for '$DeploymentName' did not return valid JSON."
    }
    Assert-SreAgentWhatIfSafe `
        -WhatIf $whatIf `
        -AgentResourceId $agentResourceId `
        -ArcResourceGroupId $arcResourceGroupId `
        -RequiredManagedResourceIds $requiredManagedResourceIds

    $createArguments = @(
        'deployment', 'group', 'create'
    ) + $baseArguments + @('--output', 'none')
    & az @createArguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

Invoke-GuardedGroupDeployment `
    -DeploymentName $initialDeploymentName `
    -TemplateParameters @(
        'environmentName=mercadona-sre-demo',
        "location=$Location",
        "resourceGroupName=$ResourceGroupName",
        "arcResourceGroupName=$ArcResourceGroupName"
    ) `
    -FailureMessage 'Initial placeholder infrastructure deployment failed.'

$initialOutputs = az deployment group show `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $initialDeploymentName `
    --query properties.outputs `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read initial deployment outputs.'
}

$registryName = $initialOutputs.AZURE_CONTAINER_REGISTRY_NAME.value
$registryServer = $initialOutputs.AZURE_CONTAINER_REGISTRY_ENDPOINT.value
$backendImage = "$registryServer/mercadona-retail-api:$ImageTag"
$frontendImage = "$registryServer/mercadona-retail-web:$ImageTag"

az acr build `
    --subscription $SubscriptionId `
    --registry $registryName `
    --image "mercadona-retail-api:$ImageTag" `
    "$repoRoot\MercadonaRetail.Api"
if ($LASTEXITCODE -ne 0) {
    throw 'Remote backend image build failed.'
}

az acr build `
    --subscription $SubscriptionId `
    --registry $registryName `
    --image "mercadona-retail-web:$ImageTag" `
    "$repoRoot\mercadona-retail-frontend"
if ($LASTEXITCODE -ne 0) {
    throw 'Remote frontend image build failed.'
}

Invoke-GuardedGroupDeployment `
    -DeploymentName $finalDeploymentName `
    -TemplateParameters @(
        'environmentName=mercadona-sre-demo',
        "location=$Location",
        "resourceGroupName=$ResourceGroupName",
        "arcResourceGroupName=$ArcResourceGroupName",
        "apiImage=$backendImage",
        "frontendImage=$frontendImage"
    ) `
    -FailureMessage 'Final image infrastructure deployment failed.'

$finalOutputs = az deployment group show `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $finalDeploymentName `
    --query properties.outputs `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read final deployment outputs.'
}

Wait-ContainerAppRevision `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $BackendAppName | Out-Null
Wait-ContainerAppRevision `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $FrontendAppName | Out-Null

$backendOrigin = $finalOutputs.API_BASE_URL.value
$frontendOrigin = $finalOutputs.FRONTEND_URL.value

$backendHealth = Invoke-WebRequest -Method Get -Uri "$backendOrigin/healthz" -SkipHttpErrorCheck
if ($backendHealth.StatusCode -ne 200) {
    throw "Backend health smoke expected HTTP 200 but received $($backendHealth.StatusCode)."
}

$stores = Invoke-WebRequest -Method Get -Uri "$backendOrigin/api/stores" -SkipHttpErrorCheck
if ($stores.StatusCode -ne 200) {
    throw "Stores smoke expected HTTP 200 but received $($stores.StatusCode)."
}

$cartResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "$backendOrigin/api/carts" `
    -ContentType 'application/json' `
    -Body ((New-DemoCartPayload) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -SkipHttpErrorCheck
if ($cartResponse.StatusCode -ne 201) {
    throw "Create cart smoke expected HTTP 201 but received $($cartResponse.StatusCode): $($cartResponse.Content)"
}
$cart = $cartResponse.Content | ConvertFrom-Json

$addResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "$backendOrigin/api/carts/$($cart.cart.id)/items" `
    -ContentType 'application/json' `
    -Body ((New-DemoAddItemPayload) | ConvertTo-Json -Compress) `
    -SkipHttpErrorCheck
if ($addResponse.StatusCode -ne 200) {
    throw "Add item smoke expected HTTP 200 but received $($addResponse.StatusCode): $($addResponse.Content)"
}

$orderResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "$backendOrigin/api/orders" `
    -ContentType 'application/json' `
    -Body ((New-DemoOrderPayload -CartId $cart.cart.id) | ConvertTo-Json -Compress) `
    -MaximumRedirection 0 `
    -SkipHttpErrorCheck
if ($orderResponse.StatusCode -ne 201) {
    throw "Order smoke expected HTTP 201 but received $($orderResponse.StatusCode): $($orderResponse.Content)"
}
$order = $orderResponse.Content | ConvertFrom-Json

$trackingResponse = Invoke-WebRequest `
    -Method Get `
    -Uri "$backendOrigin/api/orders/$($order.order.id)/tracking" `
    -SkipHttpErrorCheck
if ($trackingResponse.StatusCode -ne 200) {
    throw "Tracking smoke expected HTTP 200 but received $($trackingResponse.StatusCode)."
}

$frontendResponse = Invoke-WebRequest -Method Get -Uri "$frontendOrigin/" -SkipHttpErrorCheck
if ($frontendResponse.StatusCode -ne 200 -or $frontendResponse.Content -notmatch '<title>Mercado Verde') {
    throw "Frontend smoke failed. HTTP $($frontendResponse.StatusCode)."
}

$sameOriginHealth = Invoke-WebRequest -Method Get -Uri "$frontendOrigin/api/healthz" -SkipHttpErrorCheck
if ($sameOriginHealth.StatusCode -ne 200) {
    throw "Same-origin API smoke expected HTTP 200 but received $($sameOriginHealth.StatusCode)."
}

Write-Host "Frontend: $frontendOrigin"
Write-Host "API:      $backendOrigin"
Write-Host "ACR:      $registryName"
Write-Host "Order:    $($order.order.id)"
Write-Host 'SRE Agent: sre-agent-mercadona-v1'
