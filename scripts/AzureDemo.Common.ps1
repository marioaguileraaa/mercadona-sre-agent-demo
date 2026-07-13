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

function Get-ActiveContainerAppRevision {
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
        --all `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list revisions for '$ContainerAppName'."
    }

    $activeRevisions = @(
        $revisions | Where-Object {
            $propertiesProperty = $_.PSObject.Properties['properties']
            if ($null -eq $propertiesProperty -or $null -eq $propertiesProperty.Value) {
                return $false
            }
            $activeProperty = $propertiesProperty.Value.PSObject.Properties['active']
            return $null -ne $activeProperty -and $activeProperty.Value -eq $true
        }
    )
    if ($activeRevisions.Count -eq 0) {
        throw "Container App '$ContainerAppName' did not expose an active revision."
    }

    return $activeRevisions |
        Sort-Object { [DateTimeOffset]$_.properties.createdTime } -Descending |
        Select-Object -First 1
}

function Get-ContainerAppRevisionEnvironmentVariableValue {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $ContainerAppName,
        [Parameter(Mandatory)]
        [string] $RevisionName,
        [Parameter(Mandatory)]
        [string] $VariableName
    )

    $value = az containerapp revision show `
        --subscription $SubscriptionId `
        --resource-group $ResourceGroupName `
        --name $ContainerAppName `
        --revision $RevisionName `
        --query "properties.template.containers[0].env[?name=='$VariableName'].value | [0]" `
        --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Unable to resolve '$VariableName' for active revision '$RevisionName'."
    }

    return [string] $value
}

function Assert-ContainerAppSingleReadyRevision {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $ContainerAppName,
        [Parameter(Mandatory)]
        [string] $ExpectedRevisionName
    )

    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/$ContainerAppName"
    $containerApp = az rest `
        --method get `
        --url "https://management.azure.com${resourceId}?api-version=2025-01-01" `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to verify Container App '$ContainerAppName'."
    }
    if ($containerApp.properties.configuration.activeRevisionsMode -ne 'Single' -or
        $containerApp.properties.latestReadyRevisionName -ne $ExpectedRevisionName) {
        throw "Container App '$ContainerAppName' is not serving '$ExpectedRevisionName' in Single revision mode."
    }
}

function New-ContainerAppRevisionFromActiveTemplate {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $ContainerAppName,
        [Parameter(Mandatory)]
        [string] $SourceRevisionName,
        [Parameter(Mandatory)]
        [string] $ContainerName,
        [Parameter(Mandatory)]
        [string] $RevisionSuffix,
        [Parameter(Mandatory)]
        [hashtable] $EnvironmentVariables
    )

    $activeRevision = Get-ActiveContainerAppRevision `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ContainerAppName $ContainerAppName
    if ($activeRevision.name -ne $SourceRevisionName) {
        throw "Active revision changed from '$SourceRevisionName' to '$($activeRevision.name)' before rollout."
    }
    Assert-ContainerAppSingleReadyRevision `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -ContainerAppName $ContainerAppName `
        -ExpectedRevisionName $SourceRevisionName

    $sourceRevision = az containerapp revision show `
        --subscription $SubscriptionId `
        --resource-group $ResourceGroupName `
        --name $ContainerAppName `
        --revision $SourceRevisionName `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read source revision '$SourceRevisionName'."
    }

    $templateProperty = $sourceRevision.properties.PSObject.Properties['template']
    if ($null -eq $templateProperty -or $null -eq $templateProperty.Value) {
        throw "Source revision '$SourceRevisionName' did not expose a template."
    }
    $template = $templateProperty.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    foreach ($property in @($template.PSObject.Properties)) {
        if ($null -eq $property.Value) {
            $template.PSObject.Properties.Remove($property.Name)
        }
    }

    $revisionSuffixProperty = $template.PSObject.Properties['revisionSuffix']
    if ($null -eq $revisionSuffixProperty) {
        $template | Add-Member -NotePropertyName revisionSuffix -NotePropertyValue $RevisionSuffix
    } else {
        $revisionSuffixProperty.Value = $RevisionSuffix
    }

    $containersProperty = $template.PSObject.Properties['containers']
    if ($null -eq $containersProperty -or $null -eq $containersProperty.Value) {
        throw "Source revision '$SourceRevisionName' did not expose containers."
    }
    $container = @($containersProperty.Value) | Where-Object {
        $nameProperty = $_.PSObject.Properties['name']
        $null -ne $nameProperty -and $nameProperty.Value -eq $ContainerName
    } | Select-Object -First 1
    if ($null -eq $container) {
        throw "Source revision '$SourceRevisionName' did not expose container '$ContainerName'."
    }

    $environmentProperty = $container.PSObject.Properties['env']
    $environment = if ($null -ne $environmentProperty -and $null -ne $environmentProperty.Value) {
        @($environmentProperty.Value)
    } else {
        @()
    }
    $updatedEnvironment = [System.Collections.Generic.List[object]]::new()
    $updatedNames = @{}
    foreach ($item in $environment) {
        $nameProperty = $item.PSObject.Properties['name']
        $name = if ($null -ne $nameProperty) { [string] $nameProperty.Value } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($name) -and $EnvironmentVariables.ContainsKey($name)) {
            $updatedEnvironment.Add([PSCustomObject]@{
                    name = $name
                    value = [string] $EnvironmentVariables[$name]
                })
            $updatedNames[$name] = $true
        } else {
            $updatedEnvironment.Add($item)
        }
    }
    foreach ($name in $EnvironmentVariables.Keys) {
        if (-not $updatedNames.ContainsKey($name)) {
            $updatedEnvironment.Add([PSCustomObject]@{
                    name = $name
                    value = [string] $EnvironmentVariables[$name]
                })
        }
    }
    if ($null -eq $environmentProperty) {
        $container | Add-Member -NotePropertyName env -NotePropertyValue $updatedEnvironment.ToArray()
    } else {
        $environmentProperty.Value = $updatedEnvironment.ToArray()
    }

    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/$ContainerAppName"

    $body = @{
        properties = @{
            template = $template
        }
    } | ConvertTo-Json -Depth 100 -Compress
    $bodyFile = [IO.Path]::Combine(
        [IO.Path]::GetTempPath(),
        "container-app-revision-$([Guid]::NewGuid().ToString('N')).json"
    )
    try {
        [IO.File]::WriteAllText($bodyFile, $body, [Text.UTF8Encoding]::new($false))
        az rest `
            --method patch `
            --url "https://management.azure.com${resourceId}?api-version=2025-01-01" `
            --headers 'Content-Type=application/json' `
            --body "@$bodyFile" `
            --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to create revision '$ContainerAppName--$RevisionSuffix' from active revision '$SourceRevisionName'."
        }
    } finally {
        $body = $null
        if (Test-Path -LiteralPath $bodyFile -PathType Leaf) {
            Remove-Item -LiteralPath $bodyFile -Force
        }
    }
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
        [AllowNull()]
        [string] $ExpectedRevisionName,
        [int] $TimeoutSeconds = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $readyRunningStates = @('Running', 'RunningAtMinScale', 'RunningAtMaxScale')
    do {
        $activeRevision = Get-ActiveContainerAppRevision `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -ContainerAppName $ContainerAppName
        $isExpected = if (-not [string]::IsNullOrWhiteSpace($ExpectedRevisionName)) {
            $activeRevision.name -eq $ExpectedRevisionName
        } else {
            [string]::IsNullOrWhiteSpace($PreviousRevisionName) -or
                $activeRevision.name -ne $PreviousRevisionName
        }
        if ($isExpected -and
            $activeRevision.properties.healthState -eq 'Healthy' -and
            $activeRevision.properties.runningState -in $readyRunningStates) {
            Write-Host "Revision ready: $($activeRevision.name)"
            return $activeRevision
        }

        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    $target = if ([string]::IsNullOrWhiteSpace($ExpectedRevisionName)) {
        'a new active revision'
    } else {
        "active revision '$ExpectedRevisionName'"
    }
    throw "Container App '$ContainerAppName' did not expose $target as Healthy/Running in $TimeoutSeconds seconds."
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

function Get-MetricMaximumSamples {
    param(
        [AllowNull()]
        [object] $Metric
    )

    if ($null -eq $Metric) {
        return
    }

    $valueProperty = $Metric.PSObject.Properties['value']
    if ($null -eq $valueProperty -or $null -eq $valueProperty.Value) {
        return
    }

    foreach ($metricValue in @($valueProperty.Value)) {
        if ($null -eq $metricValue) {
            continue
        }
        $timeseriesProperty = $metricValue.PSObject.Properties['timeseries']
        if ($null -eq $timeseriesProperty -or $null -eq $timeseriesProperty.Value) {
            continue
        }

        foreach ($timeseries in @($timeseriesProperty.Value)) {
            if ($null -eq $timeseries) {
                continue
            }
            $dataProperty = $timeseries.PSObject.Properties['data']
            if ($null -eq $dataProperty -or $null -eq $dataProperty.Value) {
                continue
            }

            foreach ($sample in @($dataProperty.Value)) {
                if ($null -eq $sample) {
                    continue
                }
                $maximumProperty = $sample.PSObject.Properties['maximum']
                if ($null -eq $maximumProperty -or $null -eq $maximumProperty.Value) {
                    continue
                }
                $timestampProperty = $sample.PSObject.Properties['timeStamp']

                [PSCustomObject]@{
                    maximum = [double] $maximumProperty.Value
                    timeStamp = if ($null -ne $timestampProperty) {
                        $timestampProperty.Value
                    } else {
                        $null
                    }
                }
            }
        }
    }
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

    $samples = @(Get-MetricMaximumSamples -Metric $metric)
    if ($samples.Count -eq 0) {
        return $null
    }
    if ($Latest) {
        $latestSample = $samples |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_.timeStamp) } |
            Sort-Object { [DateTimeOffset]$_.timeStamp } -Descending |
            Select-Object -First 1
        if ($null -eq $latestSample) {
            return $null
        }
        return [double]$latestSample.maximum
    }
    return [double](($samples.maximum | Measure-Object -Maximum).Maximum)
}
