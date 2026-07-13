Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DemoAzureContext {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName
    )

    $account = az account show --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $account.id -ne $SubscriptionId) {
        throw "Azure CLI must be signed in to expected subscription '$SubscriptionId'. Current: '$($account.id)'."
    }

    $resourceGroup = az group show --subscription $SubscriptionId --name $ResourceGroupName --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $resourceGroup.name -ne $ResourceGroupName) {
        throw "Expected pre-created resource group '$ResourceGroupName' is not accessible in subscription '$SubscriptionId'."
    }

    Write-Host "Safeguard passed: $($account.name) / $SubscriptionId / $ResourceGroupName"
}

function Get-LatestContainerAppRevision {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $ContainerAppName
    )

    $revisions = az containerapp revision list `
        --subscription $SubscriptionId `
        --resource-group $ResourceGroupName `
        --name $ContainerAppName `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list revisions for '$ContainerAppName'."
    }

    return $revisions |
        Sort-Object { [DateTimeOffset]$_.properties.createdTime } -Descending |
        Select-Object -First 1
}

function Wait-ContainerAppRevision {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $ContainerAppName,
        [AllowNull()]
        [string] $PreviousRevisionName,
        [int] $TimeoutSeconds = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $readyRunningStates = @('Running', 'RunningAtMinScale', 'RunningAtMaxScale')
    do {
        $latest = Get-LatestContainerAppRevision `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -ContainerAppName $ContainerAppName
        $isNew = [string]::IsNullOrWhiteSpace($PreviousRevisionName) -or $latest.name -ne $PreviousRevisionName
        if ($isNew -and
            $latest.properties.healthState -eq 'Healthy' -and
            $latest.properties.runningState -in $readyRunningStates) {
            Write-Host "Revision ready: $($latest.name)"
            return $latest
        }

        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "A new revision for '$ContainerAppName' did not become Healthy/Running in $TimeoutSeconds seconds."
}

function New-DemoCartPayload {
    param([string] $StoreId = 'store-river')

    return @{ storeId = $StoreId }
}

function New-DemoAddItemPayload {
    param(
        [string] $ProductId = 'product-apples',
        [int] $Quantity = 1
    )

    return @{
        productId = $ProductId
        quantity = $Quantity
    }
}

function New-DemoOrderPayload {
    param([Parameter(Mandatory)][string] $CartId)

    return @{ cartId = $CartId }
}

function Get-ContainerAppWorkingSetMaximum {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $ContainerAppName,
        [Parameter(Mandatory)]
        [DateTimeOffset] $StartTime,
        [switch] $Latest
    )

    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/$ContainerAppName"
    $metric = az monitor metrics list `
        --subscription $SubscriptionId `
        --resource $resourceId `
        --metric WorkingSetBytes `
        --aggregation Maximum `
        --interval PT1M `
        --start-time $StartTime.UtcDateTime.ToString('o') `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query WorkingSetBytes for '$ContainerAppName'."
    }

    $samples = @(
        $metric.value |
            ForEach-Object { $_.timeseries } |
            ForEach-Object { $_.data } |
            Where-Object { $null -ne $_.maximum }
    )
    if ($samples.Count -eq 0) {
        return $null
    }
    if ($Latest) {
        $latestSample = $samples |
            Sort-Object { [DateTimeOffset]$_.timeStamp } -Descending |
            Select-Object -First 1
        return [double]$latestSample.maximum
    }
    return [double](($samples.maximum | Measure-Object -Maximum).Maximum)
}
