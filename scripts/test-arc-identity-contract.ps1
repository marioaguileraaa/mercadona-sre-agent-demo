#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$requiredDisclaimer = 'Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.'

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,
        [Parameter(Mandatory)]
        [string] $Case
    )

    if (-not $Condition) {
        throw "$Case failed."
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [string] $Source,
        [Parameter(Mandatory)]
        [string] $Expected,
        [Parameter(Mandatory)]
        [string] $Case
    )

    if (-not $Source.Contains($Expected, [StringComparison]::Ordinal)) {
        throw "$Case failed. Missing '$Expected'."
    }
}

function Assert-NotMatches {
    param(
        [Parameter(Mandatory)]
        [string] $Source,
        [Parameter(Mandatory)]
        [string] $Pattern,
        [Parameter(Mandatory)]
        [string] $Case
    )

    if ($Source -match $Pattern) {
        throw "$Case failed. Disallowed pattern '$Pattern' was found."
    }
}

function ConvertTo-CanonicalJson {
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $members = foreach ($key in @($Value.Keys | Sort-Object)) {
            if ([string] $key -eq '_generator') {
                continue
            }
            $encodedKey = ConvertTo-Json -InputObject ([string] $key) -Compress
            "$encodedKey`:$(ConvertTo-CanonicalJson -Value $Value[$key])"
        }
        return "{$($members -join ',')}"
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = foreach ($item in $Value) {
            ConvertTo-CanonicalJson -Value $item
        }
        return "[$($items -join ',')]"
    }
    return ConvertTo-Json -InputObject $Value -Compress
}

function Invoke-ArcIdentityDeploymentParameterProbe {
    param(
        [Parameter(Mandatory)]
        [string] $DeployScriptPath,
        [switch] $Apply,
        [switch] $FailWhatIf
    )

    $subscriptionId = '11111111-2222-3333-4444-555555555555'
    $tenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $arcResourceGroupName = 'rg-arc-parameter-probe'
    $sreResourceGroupName = 'rg-sre-parameter-probe'
    $location = 'northeurope'
    $workspaceName = 'law-parameter-probe'
    $actionGroupName = 'ag-parameter-probe'
    $machineNames = @('ArcBox-Quoted-"One"', 'ArcBox-Comma,Two')
    $dataCollectionRuleName = 'dcr-parameter-probe'
    $associationName = 'assoc-parameter-probe'
    $existingVmInsightsDcrName = 'existing-vm-insights-probe'
    $tokenFailureAlertName = 'alert-token-parameter-probe'
    $dataFreshnessAlertName = 'alert-freshness-parameter-probe'
    $deploymentCalls = [System.Collections.Generic.List[object]]::new()

    function Get-FakeAzArgumentValue {
        param(
            [Parameter(Mandatory)]
            [string[]] $Arguments,
            [Parameter(Mandatory)]
            [string] $Name
        )

        $index = [Array]::IndexOf($Arguments, $Name)
        if ($index -lt 0 -or $index -ge ($Arguments.Count - 1)) {
            throw "Fake Azure CLI call did not include '$Name'."
        }
        return $Arguments[$index + 1]
    }

    function ConvertTo-FakeAzJson {
        param(
            [Parameter(Mandatory)]
            [object] $InputObject
        )

        return ConvertTo-Json -InputObject $InputObject -Depth 20 -Compress
    }

    function az {
        [string[]] $azArguments = @($args | ForEach-Object { [string] $_ })
        $global:LASTEXITCODE = 0

        if ($azArguments[0] -eq 'account' -and $azArguments[1] -eq 'show') {
            return ConvertTo-FakeAzJson -InputObject ([ordered]@{
                    id = $subscriptionId
                    tenantId = $tenantId
                    name = 'Synthetic parameter probe'
                })
        }
        if ($azArguments[0] -eq 'group' -and $azArguments[1] -eq 'show') {
            return ConvertTo-FakeAzJson -InputObject ([ordered]@{
                    name = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--name'
                })
        }
        if ($azArguments[0] -eq 'connectedmachine' -and $azArguments[1] -eq 'list') {
            $machines = foreach ($machineName in $machineNames) {
                [ordered]@{
                    name = $machineName
                    location = $location
                    properties = [ordered]@{
                        status = 'Connected'
                        osType = 'Windows'
                    }
                }
            }
            return ConvertTo-FakeAzJson -InputObject @($machines)
        }
        if ($azArguments[0] -eq 'connectedmachine' -and
            $azArguments[1] -eq 'extension' -and
            $azArguments[2] -eq 'show') {
            return ConvertTo-FakeAzJson -InputObject ([ordered]@{
                    properties = [ordered]@{
                        provisioningState = 'Succeeded'
                    }
                })
        }
        if ($azArguments[0] -eq 'monitor' -and
            $azArguments[1] -eq 'log-analytics' -and
            $azArguments[2] -eq 'workspace' -and
            $azArguments[3] -eq 'show') {
            return ConvertTo-FakeAzJson -InputObject ([ordered]@{
                    id = "/subscriptions/$subscriptionId/resourceGroups/$arcResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"
                })
        }
        if ($azArguments[0] -eq 'monitor' -and
            $azArguments[1] -eq 'action-group' -and
            $azArguments[2] -eq 'show') {
            return ConvertTo-FakeAzJson -InputObject ([ordered]@{
                    id = "/subscriptions/$subscriptionId/resourceGroups/$sreResourceGroupName/providers/Microsoft.Insights/actionGroups/$actionGroupName"
                })
        }
        if ($azArguments[0] -eq 'rest') {
            $url = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--url'
            if ($url -like '*dataCollectionRuleAssociations*') {
                return ConvertTo-FakeAzJson -InputObject ([ordered]@{
                        value = @(
                            [ordered]@{
                                name = $existingVmInsightsDcrName
                                properties = [ordered]@{
                                    dataCollectionRuleId = "/subscriptions/$subscriptionId/resourceGroups/$arcResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$existingVmInsightsDcrName"
                                }
                            }
                        )
                    })
            }
            if ($url -like '*dataCollectionRules?*' -or $url -like '*scheduledQueryRules?*') {
                return ConvertTo-FakeAzJson -InputObject ([ordered]@{ value = @() })
            }
        }
        if ($azArguments[0] -eq 'deployment' -and $azArguments[1] -eq 'sub') {
            $parameterIndexes = @(
                for ($index = 0; $index -lt $azArguments.Count; $index++) {
                    if ($azArguments[$index] -eq '--parameters') {
                        $index
                    }
                }
            )
            if ($parameterIndexes.Count -ne 1) {
                throw 'Deployment must pass exactly one --parameters argument.'
            }
            $parameterIndex = $parameterIndexes[0]
            if ($parameterIndex -ge ($azArguments.Count - 1)) {
                throw 'Deployment --parameters argument did not include a value.'
            }
            $parameterArgument = $azArguments[$parameterIndex + 1]
            if (-not $parameterArgument.StartsWith('@', [StringComparison]::Ordinal)) {
                throw "Deployment parameters were not passed as an @file argument: '$parameterArgument'."
            }
            $parameterPath = $parameterArgument.Substring(1)
            if (-not [System.IO.Path]::IsPathFullyQualified($parameterPath)) {
                throw "Deployment parameters path was not absolute: '$parameterPath'."
            }
            if (-not (Test-Path -LiteralPath $parameterPath -PathType Leaf)) {
                throw "Deployment parameters file did not exist during the Azure CLI call: '$parameterPath'."
            }
            $parameterDocument = Get-Content -LiteralPath $parameterPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 100
            $deploymentCalls.Add([pscustomobject]@{
                    Operation = $azArguments[2]
                    ParameterArgument = $parameterArgument
                    ParameterPath = $parameterPath
                    ParameterDocument = $parameterDocument
                })

            if ($azArguments[2] -eq 'what-if') {
                if ($FailWhatIf) {
                    $global:LASTEXITCODE = 1
                }
                return
            }
            if ($azArguments[2] -eq 'create') {
                return ConvertTo-FakeAzJson -InputObject ([ordered]@{
                        properties = [ordered]@{
                            provisioningState = 'Succeeded'
                        }
                    })
            }
        }

        throw "Unexpected fake Azure CLI call: $($azArguments -join ' ')"
    }

    $errorMessage = $null
    try {
        & $DeployScriptPath `
            -SubscriptionId $subscriptionId `
            -TenantId $tenantId `
            -ArcResourceGroupName $arcResourceGroupName `
            -SreResourceGroupName $sreResourceGroupName `
            -Location $location `
            -WorkspaceName $workspaceName `
            -ActionGroupName $actionGroupName `
            -MachineNames $machineNames `
            -DataCollectionRuleName $dataCollectionRuleName `
            -AssociationName $associationName `
            -ExistingVmInsightsDataCollectionRuleName $existingVmInsightsDcrName `
            -TokenFailureAlertName $tokenFailureAlertName `
            -DataFreshnessAlertName $dataFreshnessAlertName `
            -Apply:$Apply `
            -Confirm:$false 6>$null
    } catch {
        $errorMessage = $_.Exception.Message
    } finally {
        $global:LASTEXITCODE = 0
    }

    return [pscustomobject]@{
        Calls = @($deploymentCalls)
        ErrorMessage = $errorMessage
        ExpectedParameters = [ordered]@{
            arcResourceGroupName = $arcResourceGroupName
            location = $location
            workspaceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$arcResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"
            actionGroupResourceId = "/subscriptions/$subscriptionId/resourceGroups/$sreResourceGroupName/providers/Microsoft.Insights/actionGroups/$actionGroupName"
            targetMachineNames = @($machineNames)
            dataCollectionRuleName = $dataCollectionRuleName
            dataCollectionRuleAssociationName = $associationName
            tokenFailureAlertName = $tokenFailureAlertName
            dataFreshnessAlertName = $dataFreshnessAlertName
        }
    }
}

function Invoke-ArcIdentityArmRestBodyProbe {
    $subscriptionId = '11111111-2222-3333-4444-555555555555'
    $existingManagedResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-existing-sre"
    $arcResourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/rg-arcbox-itpro-weu-002"
    $workspaceName = 'arcbox-log-analytics'
    $workspaceResourceId = "$arcResourceGroupId/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"
    $sreIdentityResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-existing-sre/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre-agent"
    $agentResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-existing-sre/providers/Microsoft.App/agents/sre-agent"
    $knowledgeGraphUrl = "https://management.azure.com${agentResourceId}?api-version=2025-05-01-preview"
    $connectorUrl = "https://management.azure.com${agentResourceId}/connectors/arcbox-log-analytics?api-version=2025-05-01-preview"
    $failureUrl = "https://management.azure.com${agentResourceId}/forced-failure?api-version=2025-05-01-preview"
    $knowledgeGraphBody = [ordered]@{
        properties = [ordered]@{
            knowledgeGraphConfiguration = [ordered]@{
                identity = $sreIdentityResourceId
                managedResources = @(
                    $existingManagedResourceId,
                    $arcResourceGroupId
                )
            }
        }
    }
    $connectorBody = [ordered]@{
        properties = [ordered]@{
            dataConnectorType = 'LogAnalytics'
            dataSource = $workspaceResourceId
            extendedProperties = [ordered]@{
                armResourceId = $workspaceResourceId
                resource = [ordered]@{
                    name = $workspaceName
                }
            }
            identity = $sreIdentityResourceId
        }
    }
    $calls = [System.Collections.Generic.List[object]]::new()

    function Get-FakeAzArgumentValue {
        param(
            [Parameter(Mandatory)]
            [string[]] $Arguments,
            [Parameter(Mandatory)]
            [string] $Name
        )

        $index = [Array]::IndexOf($Arguments, $Name)
        if ($index -lt 0 -or $index -ge ($Arguments.Count - 1)) {
            throw "Fake Azure CLI call did not include '$Name'."
        }
        return $Arguments[$index + 1]
    }

    function az {
        [string[]] $azArguments = @($args | ForEach-Object { [string] $_ })
        $global:LASTEXITCODE = 0
        if ($azArguments.Count -eq 0 -or $azArguments[0] -cne 'rest') {
            throw "Unexpected fake Azure CLI call: $($azArguments -join ' ')"
        }

        $bodyIndexes = @(
            for ($index = 0; $index -lt $azArguments.Count; $index++) {
                if ($azArguments[$index] -ceq '--body') {
                    $index
                }
            }
        )
        if ($bodyIndexes.Count -ne 1) {
            throw 'ARM REST must pass exactly one --body argument.'
        }
        $bodyIndex = $bodyIndexes[0]
        if ($bodyIndex -ge ($azArguments.Count - 1)) {
            throw 'ARM REST --body did not include a value.'
        }
        $bodyArgument = $azArguments[$bodyIndex + 1]
        if (-not $bodyArgument.StartsWith('@', [StringComparison]::Ordinal)) {
            throw "ARM REST body was not passed as an @file argument: '$bodyArgument'."
        }
        $bodyPath = $bodyArgument.Substring(1)
        if (-not [System.IO.Path]::IsPathFullyQualified($bodyPath)) {
            throw "ARM REST body path was not absolute: '$bodyPath'."
        }
        if (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
            throw "ARM REST body file did not exist during the Azure CLI call: '$bodyPath'."
        }

        $bodyBytes = [System.IO.File]::ReadAllBytes($bodyPath)
        $hasUtf8Bom = $bodyBytes.Count -ge 3 -and
            $bodyBytes[0] -eq 0xEF -and
            $bodyBytes[1] -eq 0xBB -and
            $bodyBytes[2] -eq 0xBF
        $bodyText = [System.Text.UTF8Encoding]::new($false, $true).GetString($bodyBytes)
        $bodyDocument = $bodyText | ConvertFrom-Json -AsHashtable -Depth 100
        $url = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--url'
        $calls.Add([pscustomobject]@{
                Arguments = [string[]] $azArguments.Clone()
                Method = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--method'
                Url = $url
                Header = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--headers'
                Output = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--output'
                BodyArgument = $bodyArgument
                BodyPath = $bodyPath
                BodyDocument = $bodyDocument
                HasUtf8Bom = $hasUtf8Bom
            })

        if ($url -ceq $failureUrl) {
            $global:LASTEXITCODE = 1
        }
    }

    $knowledgeGraphOutput = @(
        Invoke-ArcIdentityArmRestWithJsonBody `
            -Method 'patch' `
            -Url $knowledgeGraphUrl `
            -Headers @('Content-Type=application/json') `
            -Body $knowledgeGraphBody `
            -Output 'none' `
            -FailureMessage 'Unable to add the ArcBox resource group to SRE Agent managed resources.' *>&1
    )
    $connectorBodyJson = ConvertTo-Json -InputObject $connectorBody -Depth 10 -Compress
    $connectorOutput = @(
        Invoke-ArcIdentityArmRestWithJsonBody `
            -Method 'put' `
            -Url $connectorUrl `
            -Headers @('Content-Type=application/json') `
            -Body $connectorBodyJson `
            -Output 'none' `
            -FailureMessage 'Unable to configure the additive ArcBox Log Analytics connector.' *>&1
    )

    $failureMessage = $null
    try {
        Invoke-ArcIdentityArmRestWithJsonBody `
            -Method 'patch' `
            -Url $failureUrl `
            -Headers @('Content-Type=application/json') `
            -Body $knowledgeGraphBody `
            -Output 'none' `
            -FailureMessage 'Unable to add the ArcBox resource group to SRE Agent managed resources.'
    } catch {
        $failureMessage = $_.Exception.Message
    } finally {
        $global:LASTEXITCODE = 0
    }

    return [pscustomobject]@{
        Calls = @($calls)
        SuccessOutput = @($knowledgeGraphOutput) + @($connectorOutput)
        FailureMessage = $failureMessage
        KnowledgeGraphUrl = $knowledgeGraphUrl
        ConnectorUrl = $connectorUrl
        FailureUrl = $failureUrl
        ExpectedKnowledgeGraphBody = $knowledgeGraphBody
        ExpectedConnectorBody = $connectorBody
        ExistingManagedResourceId = $existingManagedResourceId
        ArcResourceGroupId = $arcResourceGroupId
        WorkspaceName = $workspaceName
        WorkspaceResourceId = $workspaceResourceId
        SreIdentityResourceId = $sreIdentityResourceId
    }
}

function Invoke-ArcIdentityLogAnalyticsQueryProbe {
    $subscriptionId = '11111111-2222-3333-4444-555555555555'
    $workspaceCustomerId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $firstResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-arcbox-itpro-weu-002/providers/Microsoft.HybridCompute/machines/ArcBox-Win2K22"
    $secondResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-arcbox-itpro-weu-002/providers/Microsoft.HybridCompute/machines/ArcBox-Win2K25"
    $successQuery = @"
Heartbeat
| where _ResourceId in (dynamic(["$firstResourceId", "$secondResourceId"]))
| project ResourceId = _ResourceId, Healthy = true
"@
    $singleRowQuery = "$successQuery`n| take 1"
    $emptyRowsQuery = "$successQuery`n| where false"
    $failureQuery = "$successQuery`n| where ResourceId != `"$firstResourceId`""
    $calls = [System.Collections.Generic.List[object]]::new()

    function Get-FakeAzArgumentValue {
        param(
            [Parameter(Mandatory)]
            [string[]] $Arguments,
            [Parameter(Mandatory)]
            [string] $Name
        )

        $index = [Array]::IndexOf($Arguments, $Name)
        if ($index -lt 0 -or $index -ge ($Arguments.Count - 1)) {
            throw "Fake Azure CLI call did not include '$Name'."
        }
        return $Arguments[$index + 1]
    }

    function az {
        [string[]] $azArguments = @($args | ForEach-Object { [string] $_ })
        $global:LASTEXITCODE = 0
        if ($azArguments.Count -eq 0 -or $azArguments[0] -cne 'rest') {
            throw "Unexpected fake Azure CLI call: $($azArguments -join ' ')"
        }

        $bodyIndexes = @(
            for ($index = 0; $index -lt $azArguments.Count; $index++) {
                if ($azArguments[$index] -ceq '--body') {
                    $index
                }
            }
        )
        if ($bodyIndexes.Count -ne 1) {
            throw 'Log Analytics REST must pass exactly one --body argument.'
        }
        $bodyIndex = $bodyIndexes[0]
        if ($bodyIndex -ge ($azArguments.Count - 1)) {
            throw 'Log Analytics REST --body did not include a value.'
        }
        $bodyArgument = $azArguments[$bodyIndex + 1]
        if (-not $bodyArgument.StartsWith('@', [StringComparison]::Ordinal)) {
            throw "Log Analytics REST body was not passed as an @file argument: '$bodyArgument'."
        }
        $bodyPath = $bodyArgument.Substring(1)
        if (-not [System.IO.Path]::IsPathFullyQualified($bodyPath)) {
            throw "Log Analytics REST body path was not absolute: '$bodyPath'."
        }
        if (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
            throw "Log Analytics REST body file did not exist during the Azure CLI call: '$bodyPath'."
        }

        $bodyBytes = [System.IO.File]::ReadAllBytes($bodyPath)
        $hasUtf8Bom = $bodyBytes.Count -ge 3 -and
            $bodyBytes[0] -eq 0xEF -and
            $bodyBytes[1] -eq 0xBB -and
            $bodyBytes[2] -eq 0xBF
        $bodyText = [System.Text.UTF8Encoding]::new($false, $true).GetString($bodyBytes)
        $bodyDocument = $bodyText | ConvertFrom-Json -AsHashtable -Depth 100
        $calls.Add([pscustomobject]@{
                Arguments = [string[]] $azArguments.Clone()
                Method = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--method'
                Subscription = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--subscription'
                Url = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--url'
                Resource = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--resource'
                Header = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--headers'
                Output = Get-FakeAzArgumentValue -Arguments $azArguments -Name '--output'
                BodyArgument = $bodyArgument
                BodyPath = $bodyPath
                BodyDocument = $bodyDocument
                HasUtf8Bom = $hasUtf8Bom
            })

        if ($bodyDocument['query'] -ceq $failureQuery) {
            $global:LASTEXITCODE = 1
            return
        }
        $responseRows = [System.Collections.Generic.List[object]]::new()
        if ($bodyDocument['query'] -ceq $successQuery) {
            $responseRows.Add([object[]]@($firstResourceId, $true))
            $responseRows.Add([object[]]@($secondResourceId, $false))
        } elseif ($bodyDocument['query'] -ceq $singleRowQuery) {
            $responseRows.Add([object[]]@($firstResourceId, $true))
        } elseif ($bodyDocument['query'] -cne $emptyRowsQuery) {
            throw 'Fake Azure CLI received an unexpected Log Analytics query.'
        }
        return ConvertTo-Json -InputObject ([ordered]@{
                tables = @(
                    [ordered]@{
                        name = 'PrimaryResult'
                        columns = @(
                            [ordered]@{ name = 'ResourceId'; type = 'string' },
                            [ordered]@{ name = 'Healthy'; type = 'bool' }
                        )
                        rows = $responseRows.ToArray()
                    }
                )
            }) -Depth 10 -Compress
    }

    $successRows = @(
        Invoke-ArcIdentityLogAnalyticsQuery `
            -SubscriptionId $subscriptionId `
            -WorkspaceCustomerId $workspaceCustomerId `
            -Query $successQuery
    )
    $singleRowRows = @(
        Invoke-ArcIdentityLogAnalyticsQuery `
            -SubscriptionId $subscriptionId `
            -WorkspaceCustomerId $workspaceCustomerId `
            -Query $singleRowQuery
    )
    $emptyRows = @(
        Invoke-ArcIdentityLogAnalyticsQuery `
            -SubscriptionId $subscriptionId `
            -WorkspaceCustomerId $workspaceCustomerId `
            -Query $emptyRowsQuery
    )
    $failureMessage = $null
    try {
        Invoke-ArcIdentityLogAnalyticsQuery `
            -SubscriptionId $subscriptionId `
            -WorkspaceCustomerId $workspaceCustomerId `
            -Query $failureQuery
    } catch {
        $failureMessage = $_.Exception.Message
    } finally {
        $global:LASTEXITCODE = 0
    }

    return [pscustomobject]@{
        Calls = @($calls)
        SuccessRows = @($successRows)
        SingleRowRows = @($singleRowRows)
        EmptyRows = @($emptyRows)
        FailureMessage = $failureMessage
        SubscriptionId = $subscriptionId
        WorkspaceCustomerId = $workspaceCustomerId
        SuccessQuery = $successQuery
        SingleRowQuery = $singleRowQuery
        EmptyRowsQuery = $emptyRowsQuery
        FailureQuery = $failureQuery
        FirstResourceId = $firstResourceId
        SecondResourceId = $secondResourceId
    }
}

function Invoke-ArcIdentitySreAgentWaitProbe {
    param(
        [Parameter(Mandatory)]
        [object[]] $ProvisioningStates,
        [int] $TimeoutSeconds = 1,
        [int] $PollIntervalSeconds = 0
    )

    $subscriptionId = '11111111-2222-3333-4444-555555555555'
    $agentResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-sre/providers/Microsoft.App/agents/sre-agent"
    $apiVersion = '2025-05-01-preview'
    $expectedUrl = "https://management.azure.com${agentResourceId}?api-version=$apiVersion"
    $states = [System.Collections.Generic.Queue[object]]::new()
    foreach ($state in $ProvisioningStates) {
        $states.Enqueue($state)
    }
    $calls = [System.Collections.Generic.List[object]]::new()

    function az {
        [string[]] $azArguments = @($args | ForEach-Object { [string] $_ })
        $global:LASTEXITCODE = 0
        $calls.Add([pscustomobject]@{
                Arguments = [string[]] $azArguments.Clone()
            })
        if ($states.Count -eq 0) {
            throw 'The fake Azure CLI provisioning-state queue was exhausted.'
        }

        $state = $states.Dequeue()
        $properties = [ordered]@{}
        if ([string] $state -cne '<missing>') {
            $properties.provisioningState = $state
        }
        return ConvertTo-Json -InputObject ([ordered]@{
                marker = $calls.Count
                properties = $properties
            }) -Depth 5 -Compress
    }

    $agent = $null
    $errorMessage = $null
    try {
        $agent = Wait-ArcIdentitySreAgentProvisioningSucceeded `
            -SubscriptionId $subscriptionId `
            -AgentResourceId $agentResourceId `
            -ApiVersion $apiVersion `
            -TimeoutSeconds $TimeoutSeconds `
            -PollIntervalSeconds $PollIntervalSeconds
    } catch {
        $errorMessage = $_.Exception.Message
    } finally {
        $global:LASTEXITCODE = 0
    }

    return [pscustomobject]@{
        Agent = $agent
        Calls = @($calls)
        ErrorMessage = $errorMessage
        ExpectedArguments = @(
            'rest',
            '--method', 'get',
            '--subscription', $subscriptionId,
            '--url', $expectedUrl,
            '--output', 'json'
        )
    }
}

$newScriptNames = @(
    'ArcIdentity.Common.ps1',
    'deploy-arc-identity.ps1',
    'verify-arc-identity.ps1',
    'configure-arc-identity-sre-agent.ps1',
    'start-arc-identity-incident.ps1',
    'recover-arc-identity-incident.ps1'
)
$scriptSources = @{}
foreach ($scriptName in $newScriptNames) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Case "Script exists: $scriptName"
    $tokens = $null
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref] $tokens,
        [ref] $parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "$scriptName has parser errors: $($parseErrors.Message -join '; ')"
    }
    $source = Get-Content -LiteralPath $scriptPath -Raw
    $scriptSources[$scriptName] = $source
    Assert-Contains -Source $source -Expected 'Set-StrictMode -Version Latest' -Case "$scriptName strict mode"
    Assert-Contains -Source $source -Expected '$ErrorActionPreference = ''Stop''' -Case "$scriptName stop-on-error"

    $remoteScriptStrings = $scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Value.Contains('Write-EventLog', [StringComparison]::Ordinal)
    }, $true)
    foreach ($remoteScriptString in $remoteScriptStrings) {
        $remoteTokens = $null
        $remoteErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $remoteScriptString.Value,
            [ref] $remoteTokens,
            [ref] $remoteErrors
        ) | Out-Null
        if ($remoteErrors.Count -gt 0) {
            throw "Embedded Run Command script in $scriptName has parser errors: $($remoteErrors.Message -join '; ')"
        }
        if ($IsWindows) {
            $remoteSourceBase64 = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($remoteScriptString.Value)
            )
            $windowsParserProbe = @"
`$remoteSource = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$remoteSourceBase64'))
`$tokens = `$null
`$errors = `$null
[System.Management.Automation.Language.Parser]::ParseInput(
    `$remoteSource,
    [ref] `$tokens,
    [ref] `$errors
) | Out-Null
if (`$errors.Count -gt 0) {
    [Console]::Error.WriteLine((`$errors.Message -join '; '))
    exit 1
}
"@
            $encodedParserProbe = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($windowsParserProbe)
            )
            & powershell.exe `
                -NoLogo `
                -NoProfile `
                -NonInteractive `
                -EncodedCommand $encodedParserProbe
            if ($LASTEXITCODE -ne 0) {
                throw "Embedded Run Command script in $scriptName is not valid Windows PowerShell 5.1."
            }
        }
    }
}

. "$PSScriptRoot\ArcIdentity.Common.ps1"
$testObject = '{"properties":{"value":"expected"}}' | ConvertFrom-Json
Assert-True `
    -Condition (
        (Get-ArcIdentityOptionalPropertyValue -InputObject $testObject -PropertyName 'missing') -eq $null
    ) `
    -Case 'Optional strict-mode property lookup'
Assert-True `
    -Condition (
        (Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($testObject, $testObject.properties) `
            -PropertyNames @('missing', 'value')) -eq 'expected'
    ) `
    -Case 'First strict-mode property lookup'

$logAnalyticsQueryProbe = Invoke-ArcIdentityLogAnalyticsQueryProbe
$logAnalyticsQueryCalls = @($logAnalyticsQueryProbe.Calls)
Assert-True `
    -Condition ($logAnalyticsQueryCalls.Count -eq 4) `
    -Case 'Log Analytics query row-shape and failure calls'
Assert-True `
    -Condition ((@($logAnalyticsQueryCalls.BodyPath | Sort-Object -Unique)).Count -eq 4) `
    -Case 'Log Analytics calls use unique temporary body files'
$expectedLogAnalyticsQueries = @(
    $logAnalyticsQueryProbe.SuccessQuery,
    $logAnalyticsQueryProbe.SingleRowQuery,
    $logAnalyticsQueryProbe.EmptyRowsQuery,
    $logAnalyticsQueryProbe.FailureQuery
)
for ($callIndex = 0; $callIndex -lt $logAnalyticsQueryCalls.Count; $callIndex++) {
    $logAnalyticsQueryCall = $logAnalyticsQueryCalls[$callIndex]
    $expectedQuery = $expectedLogAnalyticsQueries[$callIndex]
    $bodyArgumentIndexes = @(
        for ($argumentIndex = 0; $argumentIndex -lt $logAnalyticsQueryCall.Arguments.Count; $argumentIndex++) {
            if ($logAnalyticsQueryCall.Arguments[$argumentIndex] -ceq '--body') {
                $argumentIndex
            }
        }
    )
    Assert-True `
        -Condition ($bodyArgumentIndexes.Count -eq 1) `
        -Case 'Single Log Analytics --body option'
    Assert-True `
        -Condition ($logAnalyticsQueryCall.BodyArgument -ceq "@$($logAnalyticsQueryCall.BodyPath)") `
        -Case 'Log Analytics --body is exactly one @file argument'
    Assert-True `
        -Condition ([System.IO.Path]::IsPathFullyQualified($logAnalyticsQueryCall.BodyPath)) `
        -Case 'Log Analytics body file path is absolute'
    Assert-True `
        -Condition (-not $logAnalyticsQueryCall.HasUtf8Bom) `
        -Case 'Log Analytics body file is UTF-8 without BOM'
    Assert-True `
        -Condition (-not (Test-Path -LiteralPath $logAnalyticsQueryCall.BodyPath)) `
        -Case 'Log Analytics body file cleanup after Azure CLI returns'
    Assert-True `
        -Condition (
            $logAnalyticsQueryCall.BodyDocument.Keys.Count -eq 1 -and
            $logAnalyticsQueryCall.BodyDocument.Contains('query') -and
            $logAnalyticsQueryCall.BodyDocument['query'] -ceq $expectedQuery
        ) `
        -Case 'Log Analytics JSON body preserves exact KQL'
    Assert-True `
        -Condition ($logAnalyticsQueryCall.Method -ceq 'post') `
        -Case 'Log Analytics REST POST method'
    Assert-True `
        -Condition ($logAnalyticsQueryCall.Subscription -ceq $logAnalyticsQueryProbe.SubscriptionId) `
        -Case 'Log Analytics subscription context'
    Assert-True `
        -Condition (
            $logAnalyticsQueryCall.Url -ceq
            "https://api.loganalytics.azure.com/v1/workspaces/$($logAnalyticsQueryProbe.WorkspaceCustomerId)/query"
        ) `
        -Case 'Log Analytics query URL'
    Assert-True `
        -Condition ($logAnalyticsQueryCall.Resource -ceq 'https://api.loganalytics.io') `
        -Case 'Log Analytics token resource'
    Assert-True `
        -Condition ($logAnalyticsQueryCall.Header -ceq 'Content-Type=application/json') `
        -Case 'Log Analytics content-type header'
    Assert-True `
        -Condition ($logAnalyticsQueryCall.Output -ceq 'json') `
        -Case 'Log Analytics JSON output'
    Assert-True `
        -Condition (
            @($logAnalyticsQueryCall.Arguments | Where-Object {
                    $_ -ceq '--analytics-query' -or $_ -ceq $expectedQuery
                }).Count -eq 0
        ) `
        -Case 'Log Analytics KQL is not passed through the command line'
}
Assert-True `
    -Condition (
        $logAnalyticsQueryProbe.SuccessQuery.Contains(
            "dynamic([`"$($logAnalyticsQueryProbe.FirstResourceId)`", `"$($logAnalyticsQueryProbe.SecondResourceId)`"])",
            [StringComparison]::Ordinal
        )
    ) `
    -Case 'Log Analytics probe covers quoted resource IDs'
$compatibleLogAnalyticsRows = @(
    Get-ArcIdentityResponseItems `
        -Response $logAnalyticsQueryProbe.SuccessRows `
        -PropertyNames @('tables', 'value')
)
Assert-True `
    -Condition (
        $compatibleLogAnalyticsRows.Count -eq 2 -and
        $compatibleLogAnalyticsRows[0].ResourceId -ceq $logAnalyticsQueryProbe.FirstResourceId -and
        $compatibleLogAnalyticsRows[0].Healthy -eq $true -and
        $compatibleLogAnalyticsRows[1].ResourceId -ceq $logAnalyticsQueryProbe.SecondResourceId -and
        $compatibleLogAnalyticsRows[1].Healthy -eq $false
    ) `
    -Case 'Log Analytics REST rows remain response-item compatible'
$compatibleSingleLogAnalyticsRow = @(
    Get-ArcIdentityResponseItems `
        -Response $logAnalyticsQueryProbe.SingleRowRows `
        -PropertyNames @('tables', 'value')
)
Assert-True `
    -Condition (
        $compatibleSingleLogAnalyticsRow.Count -eq 1 -and
        $compatibleSingleLogAnalyticsRow[0].ResourceId -ceq $logAnalyticsQueryProbe.FirstResourceId -and
        $compatibleSingleLogAnalyticsRow[0].Healthy -eq $true
    ) `
    -Case 'Single Log Analytics REST row preserves its columns'
$compatibleEmptyLogAnalyticsRows = @(
    Get-ArcIdentityResponseItems `
        -Response $logAnalyticsQueryProbe.EmptyRows `
        -PropertyNames @('tables', 'value')
)
Assert-True `
    -Condition ($compatibleEmptyLogAnalyticsRows.Count -eq 0) `
    -Case 'Empty Log Analytics REST rows remain empty'
Assert-True `
    -Condition (
        $logAnalyticsQueryProbe.FailureMessage -ceq
        'Unable to query the ArcBox Log Analytics workspace.'
    ) `
    -Case 'Log Analytics query failure remains explicit'

$expectedSkillFilePaths = @(
    'kql/arc-identity/fleet-heartbeat.kql',
    'kql/arc-identity/data-freshness.kql',
    'kql/arc-identity/synthetic-token-failure-burst.kql',
    'kql/arc-identity/performance-correlation.kql',
    'kql/arc-identity/extension-health.arg.kql',
    'kql/arc-identity/change-tracking.kql'
)
$configureContractTokens = $null
$configureContractErrors = $null
$configureContractAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $scriptSources['configure-arc-identity-sre-agent.ps1'],
    [ref] $configureContractTokens,
    [ref] $configureContractErrors
)
Assert-True `
    -Condition ($configureContractErrors.Count -eq 0) `
    -Case 'Configurator parses for skill payload probe'
$skillPathAssignments = @(
    $configureContractAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$skillAdditionalFilePaths'
    }, $true)
)
Assert-True `
    -Condition ($skillPathAssignments.Count -eq 1) `
    -Case 'Configurator has one skill additional file allowlist'
$configuredSkillFilePaths = @(
    & ([scriptblock]::Create($skillPathAssignments[0].Right.Extent.Text))
)
Assert-True `
    -Condition (
        ($configuredSkillFilePaths -join "`0") -ceq
        ($expectedSkillFilePaths -join "`0")
    ) `
    -Case 'Configurator exact skill file allowlist and order'
$skillAdditionalFiles = @(
    Get-ArcIdentitySkillAdditionalFiles `
        -RepositoryRoot $repoRoot `
        -RelativePaths $configuredSkillFilePaths
)
$serializedSkillProbe = [ordered]@{
    name = 'identity-infrastructure-operations'
    type = 'Skill'
    properties = [ordered]@{
        additionalFiles = $skillAdditionalFiles
    }
} | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable -Depth 10
$skillAdditionalFiles = @($serializedSkillProbe['properties']['additionalFiles'])
Assert-True -Condition ($skillAdditionalFiles.Count -eq 6) -Case 'Six skill additional files'
$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
for ($index = 0; $index -lt $expectedSkillFilePaths.Count; $index++) {
    $expectedRelativePath = $expectedSkillFilePaths[$index]
    $additionalFile = $skillAdditionalFiles[$index]
    Assert-True `
        -Condition ($additionalFile -is [System.Collections.IDictionary]) `
        -Case "Skill additional file is an object: $expectedRelativePath"
    Assert-True `
        -Condition ($additionalFile -isnot [string]) `
        -Case "Skill additional file is not a path string: $expectedRelativePath"
    Assert-True `
        -Condition (
            @($additionalFile.Keys).Count -eq 2 -and
            $additionalFile.Contains('filePath') -and
            $additionalFile.Contains('content')
        ) `
        -Case "Skill additional file has filePath and content: $expectedRelativePath"
    Assert-True `
        -Condition ($additionalFile['filePath'] -ceq $expectedRelativePath) `
        -Case "Skill additional file allowlist order: $expectedRelativePath"
    $expectedContent = $strictUtf8.GetString(
        [System.IO.File]::ReadAllBytes(
            (Join-Path $repoRoot $expectedRelativePath)
        )
    )
    Assert-True `
        -Condition (
            -not [string]::IsNullOrWhiteSpace([string] $additionalFile['content']) -and
            [string] $additionalFile['content'] -ceq $expectedContent
        ) `
        -Case "Skill additional file exact UTF-8 content: $expectedRelativePath"
}
$missingSkillFileError = $null
try {
    $null = @(
        Get-ArcIdentitySkillAdditionalFiles `
            -RepositoryRoot $repoRoot `
            -RelativePaths @('kql/arc-identity/missing-required-file.kql')
    )
} catch {
    $missingSkillFileError = $_.Exception.Message
}
Assert-True `
    -Condition (
        $missingSkillFileError -ceq
        "Required SRE Agent skill file 'kql/arc-identity/missing-required-file.kql' does not exist."
    ) `
    -Case 'Missing skill file fails explicitly'
$escapedSkillFileError = $null
try {
    $null = @(
        Get-ArcIdentitySkillAdditionalFiles `
            -RepositoryRoot $repoRoot `
            -RelativePaths @('../outside-repository.kql')
    )
} catch {
    $escapedSkillFileError = $_.Exception.Message
}
Assert-True `
    -Condition (
        $escapedSkillFileError -ceq
        "Required SRE Agent skill file '../outside-repository.kql' resolves outside the repository root."
    ) `
    -Case 'Skill file path cannot escape repository root'

$connectorName = 'arcbox-log-analytics'
$connectorSubscriptionId = '11111111-2222-3333-4444-555555555555'
$connectorWorkspaceName = 'law-arcbox-demo-001'
$connectorWorkspaceResourceId = "/subscriptions/$connectorSubscriptionId/resourceGroups/rg-arc/providers/Microsoft.OperationalInsights/workspaces/$connectorWorkspaceName"
$connectorIdentityResourceId = "/subscriptions/$connectorSubscriptionId/resourceGroups/rg-sre/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre"
$visibleConnector = [pscustomobject]@{
    name = "sre-agent/$connectorName"
    properties = [pscustomobject]@{
        dataConnectorType = 'LogAnalytics'
        dataSource = $connectorWorkspaceResourceId.ToUpperInvariant()
        extendedProperties = [pscustomobject]@{
            armResourceId = $connectorWorkspaceResourceId
            resource = [pscustomobject]@{
                name = $connectorWorkspaceName
            }
        }
        identity = $connectorIdentityResourceId.ToUpperInvariant()
        source = 'Agent'
        provisioningState = 'Succeeded'
        deploymentError = ''
    }
}
$redactedConnector = [pscustomobject]@{
    name = $connectorName
    properties = [pscustomobject]@{
        dataConnectorType = 'LogAnalytics'
        dataSource = $null
        extendedProperties = [pscustomobject]@{
            armResourceId = ''
            resource = [pscustomobject]@{
                name = ' '
            }
        }
        identity = $connectorIdentityResourceId
        source = 'Agent'
        provisioningState = 'Succeeded'
        deploymentError = $null
    }
}
foreach ($connectorContract in @(
        @{ Name = 'Visible exact connector accepted'; Connector = $visibleConnector },
        @{ Name = 'Provider-redacted connector accepted'; Connector = $redactedConnector }
    )) {
    $connectorContractError = $null
    try {
        Assert-ArcIdentityLogAnalyticsConnector `
            -Connector $connectorContract.Connector `
            -ExpectedName $connectorName `
            -ExpectedWorkspaceResourceId $connectorWorkspaceResourceId `
            -ExpectedWorkspaceName $connectorWorkspaceName `
            -ExpectedIdentity $connectorIdentityResourceId
    } catch {
        $connectorContractError = $_.Exception.Message
    }
    Assert-True `
        -Condition ($null -eq $connectorContractError) `
        -Case $connectorContract.Name
}
$connectorMismatchCases = @(
    @{
        Name = 'Connector name mismatch rejected'
        Field = 'name'
        Mutate = { param($connector) $connector.name = 'different-connector' }
    },
    @{
        Name = 'Connector name case mismatch rejected'
        Field = 'name'
        Mutate = { param($connector) $connector.name = 'ARCBOX-LOG-ANALYTICS' }
    },
    @{
        Name = 'Connector type mismatch rejected'
        Field = 'dataConnectorType'
        Mutate = { param($connector) $connector.properties.dataConnectorType = 'ApplicationInsights' }
    },
    @{
        Name = 'Connector identity mismatch rejected'
        Field = 'identity'
        Mutate = { param($connector) $connector.properties.identity = '/subscriptions/other/identities/other' }
    },
    @{
        Name = 'Connector source mismatch rejected'
        Field = 'source'
        Mutate = { param($connector) $connector.properties.source = 'User' }
    },
    @{
        Name = 'Connector blank source rejected'
        Field = 'source'
        Mutate = { param($connector) $connector.properties.source = ' ' }
    },
    @{
        Name = 'Connector provisioning mismatch rejected'
        Field = 'provisioningState'
        Mutate = { param($connector) $connector.properties.provisioningState = 'Failed' }
    },
    @{
        Name = 'Connector blank provisioning state rejected'
        Field = 'provisioningState'
        Mutate = { param($connector) $connector.properties.provisioningState = '' }
    },
    @{
        Name = 'Connector deployment error rejected'
        Field = 'deploymentError'
        Mutate = { param($connector) $connector.properties.deploymentError = 'Synthetic connector failure' }
    },
    @{
        Name = 'Connector whitespace deployment error rejected'
        Field = 'deploymentError'
        Mutate = { param($connector) $connector.properties.deploymentError = ' ' }
    },
    @{
        Name = 'Connector visible data source mismatch rejected'
        Field = 'dataSource'
        Mutate = { param($connector) $connector.properties.dataSource = '/subscriptions/other/workspaces/other' }
    },
    @{
        Name = 'Connector visible ARM resource mismatch rejected'
        Field = 'extendedProperties.armResourceId'
        Mutate = { param($connector) $connector.properties.extendedProperties.armResourceId = '/subscriptions/other/workspaces/other' }
    },
    @{
        Name = 'Connector visible resource name mismatch rejected'
        Field = 'extendedProperties.resource.name'
        Mutate = { param($connector) $connector.properties.extendedProperties.resource.name = 'other-workspace' }
    }
)
foreach ($mismatchCase in $connectorMismatchCases) {
    $mismatchedConnector = $visibleConnector |
        ConvertTo-Json -Depth 10 |
        ConvertFrom-Json -Depth 10
    & $mismatchCase.Mutate $mismatchedConnector
    $mismatchError = $null
    try {
        Assert-ArcIdentityLogAnalyticsConnector `
            -Connector $mismatchedConnector `
            -ExpectedName $connectorName `
            -ExpectedWorkspaceResourceId $connectorWorkspaceResourceId `
            -ExpectedWorkspaceName $connectorWorkspaceName `
            -ExpectedIdentity $connectorIdentityResourceId
    } catch {
        $mismatchError = $_.Exception.Message
    }
    Assert-True `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($mismatchError) -and
            $mismatchError.Contains([string] $mismatchCase.Field, [StringComparison]::Ordinal) -and
            $mismatchError.Contains('refusing to accept or overwrite it', [StringComparison]::Ordinal)
        ) `
        -Case $mismatchCase.Name
}

if ($null -eq ('ArcIdentityContractHttpMessageHandler' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class ArcIdentityContractHttpMessageHandler : HttpMessageHandler
{
    private readonly HttpStatusCode statusCode;
    private readonly string reasonPhrase;
    private readonly string responseBody;

    public int RequestCount { get; private set; }
    public string LastAuthorization { get; private set; }
    public string LastRequestBody { get; private set; }

    public ArcIdentityContractHttpMessageHandler(
        int statusCode,
        string reasonPhrase,
        string responseBody)
    {
        this.statusCode = (HttpStatusCode)statusCode;
        this.reasonPhrase = reasonPhrase;
        this.responseBody = responseBody;
    }

    private HttpResponseMessage CreateResponse(HttpRequestMessage request)
    {
        RequestCount++;
        LastAuthorization = request.Headers.Contains("Authorization")
            ? string.Join(",", request.Headers.GetValues("Authorization"))
            : null;
        LastRequestBody = request.Content == null
            ? null
            : request.Content.ReadAsStringAsync().GetAwaiter().GetResult();
        var response = new HttpResponseMessage(statusCode)
        {
            ReasonPhrase = reasonPhrase
        };
        if (responseBody != null)
        {
            response.Content = new StringContent(responseBody, Encoding.UTF8, "application/json");
        }
        return response;
    }

    protected override HttpResponseMessage Send(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        return CreateResponse(request);
    }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        return Task.FromResult(CreateResponse(request));
    }
}
'@
}

function Invoke-ArcIdentityDataPlaneResponseProbe {
    param(
        [Parameter(Mandatory)]
        [int] $StatusCode,
        [Parameter(Mandatory)]
        [string] $ReasonPhrase,
        [AllowNull()]
        [string] $ResponseBody,
        [switch] $AllowNotFound
    )

    $tokenMarker = 'TOKEN_MUST_NOT_BE_ECHOED'
    $requestBodyMarker = 'REQUEST_BODY_MUST_NOT_BE_ECHOED'
    $handlerType = 'ArcIdentityContractHttpMessageHandler' -as [type]
    $handler = [Activator]::CreateInstance(
        $handlerType,
        @($StatusCode, $ReasonPhrase, $ResponseBody)
    )
    Disconnect-ArcIdentitySreAgentApi
    $script:ArcIdentitySreHttpClient = [System.Net.Http.HttpClient]::new($handler, $true)
    $script:ArcIdentitySreEndpoint = 'https://sre-agent.invalid'
    $script:ArcIdentitySreHeaders = @{
        Authorization = "Bearer $tokenMarker"
    }

    $result = $null
    $errorMessage = $null
    try {
        $result = Invoke-ArcIdentitySreAgentApi `
            -Method Put `
            -Path '/api/v2/extendedAgent/skills/identity-infrastructure-operations' `
            -Body @{ marker = $requestBodyMarker } `
            -AllowNotFound:$AllowNotFound
    } catch {
        $errorMessage = $_.Exception.Message
    } finally {
        Disconnect-ArcIdentitySreAgentApi
    }

    return [pscustomobject]@{
        Result = $result
        ErrorMessage = $errorMessage
        RequestCount = $handler.RequestCount
        LastAuthorization = $handler.LastAuthorization
        LastRequestBody = $handler.LastRequestBody
        TokenMarker = $tokenMarker
        RequestBodyMarker = $requestBodyMarker
    }
}

$validationResponseBody = '{"detail":"The JSON value could not be converted to Agent.Web.Views.v2.SkillSubFileView. Path: $[0]"}'
$dataPlaneFailureProbe = Invoke-ArcIdentityDataPlaneResponseProbe `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody $validationResponseBody
Assert-True -Condition ($dataPlaneFailureProbe.RequestCount -eq 1) -Case 'Data-plane failure sends one request'
Assert-True `
    -Condition (
        $dataPlaneFailureProbe.LastAuthorization.Contains(
            $dataPlaneFailureProbe.TokenMarker,
            [StringComparison]::Ordinal
        ) -and
        $dataPlaneFailureProbe.LastRequestBody.Contains(
            $dataPlaneFailureProbe.RequestBodyMarker,
            [StringComparison]::Ordinal
        )
    ) `
    -Case 'Data-plane safety probe includes private request markers'
Assert-True `
    -Condition (
        $dataPlaneFailureProbe.ErrorMessage.Contains('HTTP 400 (Bad Request)', [StringComparison]::Ordinal) -and
        $dataPlaneFailureProbe.ErrorMessage.Contains('Agent.Web.Views.v2.SkillSubFileView', [StringComparison]::Ordinal) -and
        $dataPlaneFailureProbe.ErrorMessage.Contains('Path: $[0]', [StringComparison]::Ordinal)
    ) `
    -Case 'Data-plane failure reports status and validation response'
Assert-True `
    -Condition (
        -not $dataPlaneFailureProbe.ErrorMessage.Contains(
            $dataPlaneFailureProbe.TokenMarker,
            [StringComparison]::Ordinal
        ) -and
        -not $dataPlaneFailureProbe.ErrorMessage.Contains(
            $dataPlaneFailureProbe.RequestBodyMarker,
            [StringComparison]::Ordinal
        )
    ) `
    -Case 'Data-plane failure omits authorization and request body'

$emptyDataPlaneFailureProbe = Invoke-ArcIdentityDataPlaneResponseProbe `
    -StatusCode 500 `
    -ReasonPhrase 'Internal Server Error' `
    -ResponseBody ' '
Assert-True `
    -Condition (
        $emptyDataPlaneFailureProbe.ErrorMessage -ceq
        'Azure SRE Agent data-plane request failed with HTTP 500 (Internal Server Error). Response body was empty.'
    ) `
    -Case 'Data-plane failure reports empty response body'
$notFoundProbe = Invoke-ArcIdentityDataPlaneResponseProbe `
    -StatusCode 404 `
    -ReasonPhrase 'Not Found' `
    -ResponseBody '{"detail":"not found"}' `
    -AllowNotFound
Assert-True `
    -Condition ($null -eq $notFoundProbe.ErrorMessage -and $null -eq $notFoundProbe.Result) `
    -Case 'AllowNotFound remains nonthrowing'
$boundedDataPlaneError = Format-ArcIdentitySreAgentApiError `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody ('x' * 5000) `
    -MaxResponseBodyBytes 128
Assert-True `
    -Condition (
        $boundedDataPlaneError.Contains('x' * 128, [StringComparison]::Ordinal) -and
        -not $boundedDataPlaneError.Contains('x' * 129, [StringComparison]::Ordinal) -and
        $boundedDataPlaneError.Contains('[truncated at 128 UTF-8 bytes]', [StringComparison]::Ordinal)
    ) `
    -Case 'Data-plane error response is bounded'
$unicodeDataPlaneError = Format-ArcIdentitySreAgentApiError `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody ([string] ([char] 0x00E9) * 4096)
$unicodeBodyPrefix = 'Response body: '
$unicodeBodyStart = $unicodeDataPlaneError.IndexOf(
    $unicodeBodyPrefix,
    [StringComparison]::Ordinal
) + $unicodeBodyPrefix.Length
$unicodeBodySuffix = ' [truncated at 4096 UTF-8 bytes]'
$unicodeBodyEnd = $unicodeDataPlaneError.LastIndexOf(
    $unicodeBodySuffix,
    [StringComparison]::Ordinal
)
$unicodeResponseDetails = $unicodeDataPlaneError.Substring(
    $unicodeBodyStart,
    $unicodeBodyEnd - $unicodeBodyStart
)
Assert-True `
    -Condition (
        [System.Text.Encoding]::UTF8.GetByteCount($unicodeResponseDetails) -eq 4096 -and
        -not $unicodeResponseDetails.Contains([string] ([char] 0xFFFD), [StringComparison]::Ordinal)
    ) `
    -Case 'Data-plane error cap is UTF-8 byte bounded'

Assert-True `
    -Condition (
        (Get-ArcIdentityMachineResourceId `
            -SubscriptionId 'sub' `
            -ResourceGroupName 'rg' `
            -MachineName 'machine') -eq
        '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.HybridCompute/machines/machine'
    ) `
    -Case 'Arc machine resource ID'
$wrappedItems = '{"value":[{"name":"one"},{"name":"two"}]}' | ConvertFrom-Json
$responseItems = @(Get-ArcIdentityResponseItems -Response $wrappedItems)
Assert-True -Condition ($responseItems.Count -eq 2) -Case 'Wrapped Azure list response'
Assert-True -Condition ($responseItems[1].name -eq 'two') -Case 'Wrapped Azure list item shape'

$immediateWaitProbe = Invoke-ArcIdentitySreAgentWaitProbe -ProvisioningStates @('Succeeded')
Assert-True -Condition ($null -eq $immediateWaitProbe.ErrorMessage) -Case 'Immediate SRE Agent success'
Assert-True -Condition ($immediateWaitProbe.Calls.Count -eq 1) -Case 'Immediate SRE Agent single GET'
Assert-True `
    -Condition (
        ($immediateWaitProbe.Calls[0].Arguments -join "`0") -ceq
        ($immediateWaitProbe.ExpectedArguments -join "`0")
    ) `
    -Case 'SRE Agent wait exact subscription resource ID and API'
Assert-True -Condition ($immediateWaitProbe.Agent.marker -eq 1) -Case 'Immediate SRE Agent object return'

$transitionWaitProbe = Invoke-ArcIdentitySreAgentWaitProbe `
    -ProvisioningStates @('InProgress', 'Succeeded')
Assert-True -Condition ($null -eq $transitionWaitProbe.ErrorMessage) -Case 'SRE Agent transition success'
Assert-True -Condition ($transitionWaitProbe.Calls.Count -eq 2) -Case 'SRE Agent transition polls once'
Assert-True -Condition ($transitionWaitProbe.Agent.marker -eq 2) -Case 'SRE Agent refreshed object return'

$failureWaitProbe = Invoke-ArcIdentitySreAgentWaitProbe -ProvisioningStates @('Failed')
Assert-True -Condition ($failureWaitProbe.Calls.Count -eq 1) -Case 'SRE Agent terminal failure is immediate'
Assert-True `
    -Condition (
        $failureWaitProbe.ErrorMessage -ceq
        "Azure SRE Agent provisioning reached terminal state 'Failed'."
    ) `
    -Case 'SRE Agent terminal failure message'

$timeoutWaitProbe = Invoke-ArcIdentitySreAgentWaitProbe `
    -ProvisioningStates @('InProgress') `
    -TimeoutSeconds 0
Assert-True -Condition ($timeoutWaitProbe.Calls.Count -eq 1) -Case 'SRE Agent zero-timeout single GET'
Assert-True `
    -Condition (
        $timeoutWaitProbe.ErrorMessage -ceq
        "Azure SRE Agent did not reach provisioning state 'Succeeded' within 0 seconds. Last observed state: 'InProgress'."
    ) `
    -Case 'SRE Agent timeout includes last state'

$missingStateWaitProbe = Invoke-ArcIdentitySreAgentWaitProbe -ProvisioningStates @('<missing>')
Assert-True -Condition ($missingStateWaitProbe.Calls.Count -eq 1) -Case 'Missing SRE Agent state is immediate'
Assert-True `
    -Condition (
        $missingStateWaitProbe.ErrorMessage -ceq
        "Azure SRE Agent provisioning state was missing or invalid. Last observed state: '<missing>'."
    ) `
    -Case 'Missing SRE Agent state error'

$invalidStateWaitProbe = Invoke-ArcIdentitySreAgentWaitProbe -ProvisioningStates @(42)
Assert-True -Condition ($invalidStateWaitProbe.Calls.Count -eq 1) -Case 'Invalid SRE Agent state is immediate'
Assert-True `
    -Condition (
        $invalidStateWaitProbe.ErrorMessage -ceq
        "Azure SRE Agent provisioning state was missing or invalid. Last observed state: '42'."
    ) `
    -Case 'Invalid SRE Agent state error includes observed value'

$knowledgeGraphSubscriptionId = '11111111-2222-3333-4444-555555555555'
$knowledgeGraphSreResourceGroupId = "/subscriptions/$knowledgeGraphSubscriptionId/resourceGroups/rg-sre"
$knowledgeGraphArcResourceGroupId = "/subscriptions/$knowledgeGraphSubscriptionId/resourceGroups/rg-arc"
$knowledgeGraphExistingResourceGroupId = "/subscriptions/$knowledgeGraphSubscriptionId/resourceGroups/rg-existing"
$knowledgeGraphIdentityId = "$knowledgeGraphSreResourceGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre"
$exactKnowledgeGraphPlan = Get-ArcIdentityKnowledgeGraphConfigurationPlan `
    -ExistingConfiguration ([pscustomobject]@{
        identity = $knowledgeGraphIdentityId.ToUpperInvariant()
        managedResources = @(
            $knowledgeGraphArcResourceGroupId.ToUpperInvariant(),
            $knowledgeGraphSreResourceGroupId.ToUpperInvariant()
        )
    }) `
    -ExpectedIdentity $knowledgeGraphIdentityId `
    -RequiredManagedResources @(
        $knowledgeGraphSreResourceGroupId,
        $knowledgeGraphArcResourceGroupId
    )
Assert-True -Condition (-not $exactKnowledgeGraphPlan.RequiresPatch) -Case 'Exact knowledge graph skips PATCH'
Assert-True `
    -Condition (
        ($exactKnowledgeGraphPlan.ManagedResources -join "`0") -ceq
        (@(
                $knowledgeGraphArcResourceGroupId.ToUpperInvariant(),
                $knowledgeGraphSreResourceGroupId.ToUpperInvariant()
            ) -join "`0")
    ) `
    -Case 'Exact knowledge graph preserves existing resource order'

$missingKnowledgeGraphPlan = Get-ArcIdentityKnowledgeGraphConfigurationPlan `
    -ExistingConfiguration ([pscustomobject]@{
        identity = $knowledgeGraphIdentityId
        managedResources = @(
            $knowledgeGraphExistingResourceGroupId,
            $knowledgeGraphSreResourceGroupId.ToUpperInvariant(),
            ' ',
            $knowledgeGraphExistingResourceGroupId.ToUpperInvariant()
        )
    }) `
    -ExpectedIdentity $knowledgeGraphIdentityId `
    -RequiredManagedResources @(
        $knowledgeGraphSreResourceGroupId,
        $knowledgeGraphArcResourceGroupId
    )
Assert-True -Condition $missingKnowledgeGraphPlan.RequiresPatch -Case 'Missing resource causes one PATCH decision'
Assert-True `
    -Condition (
        ($missingKnowledgeGraphPlan.ManagedResources -join "`0") -ceq
        (@(
                $knowledgeGraphExistingResourceGroupId,
                $knowledgeGraphSreResourceGroupId.ToUpperInvariant(),
                $knowledgeGraphArcResourceGroupId
            ) -join "`0")
    ) `
    -Case 'Knowledge graph appends one missing required scope without duplicates'

$armRestBodyProbe = Invoke-ArcIdentityArmRestBodyProbe
$armRestCalls = @($armRestBodyProbe.Calls)
Assert-True -Condition ($armRestCalls.Count -eq 3) -Case 'Two successful and one failed ARM body calls'
Assert-True -Condition ($armRestBodyProbe.SuccessOutput.Count -eq 0) -Case 'ARM request bodies are not emitted'
Assert-True `
    -Condition (
        $armRestBodyProbe.FailureMessage -ceq
        'Unable to add the ArcBox resource group to SRE Agent managed resources.'
    ) `
    -Case 'ARM helper preserves the caller-specific failure message'
Assert-True `
    -Condition ((@($armRestCalls.BodyPath | Sort-Object -Unique)).Count -eq 3) `
    -Case 'ARM calls use separate temporary body files'
foreach ($armRestCall in $armRestCalls) {
    $bodyArgumentIndexes = @(
        for ($index = 0; $index -lt $armRestCall.Arguments.Count; $index++) {
            if ($armRestCall.Arguments[$index] -ceq '--body') {
                $index
            }
        }
    )
    Assert-True -Condition ($bodyArgumentIndexes.Count -eq 1) -Case 'Single ARM --body option'
    Assert-True `
        -Condition ($armRestCall.BodyArgument -ceq "@$($armRestCall.BodyPath)") `
        -Case 'ARM --body is exactly one @file argument'
    Assert-True `
        -Condition ([System.IO.Path]::IsPathFullyQualified($armRestCall.BodyPath)) `
        -Case 'ARM body file path is absolute'
    Assert-True -Condition (-not $armRestCall.HasUtf8Bom) -Case 'ARM body file is UTF-8 without BOM'
    Assert-True `
        -Condition (-not (Test-Path -LiteralPath $armRestCall.BodyPath)) `
        -Case 'ARM body file cleanup after Azure CLI returns'
    Assert-True `
        -Condition ($armRestCall.Header -ceq 'Content-Type=application/json') `
        -Case 'ARM content-type header is preserved'
    Assert-True -Condition ($armRestCall.Output -ceq 'none') -Case 'ARM output mode is preserved'
    Assert-True `
        -Condition (
            @($armRestCall.Arguments | Where-Object {
                    $_.TrimStart().StartsWith('{', [StringComparison]::Ordinal) -or
                    $_.TrimStart().StartsWith('[', [StringComparison]::Ordinal)
                }).Count -eq 0
        ) `
        -Case 'No inline JSON remains in Azure CLI arguments'
}
Assert-True -Condition ($armRestCalls[0].Method -ceq 'patch') -Case 'Knowledge graph PATCH method'
Assert-True `
    -Condition ($armRestCalls[0].Url -ceq $armRestBodyProbe.KnowledgeGraphUrl) `
    -Case 'Knowledge graph PATCH URL'
Assert-True `
    -Condition (
        (ConvertTo-CanonicalJson -Value $armRestCalls[0].BodyDocument) -ceq
        (ConvertTo-CanonicalJson -Value $armRestBodyProbe.ExpectedKnowledgeGraphBody)
    ) `
    -Case 'Exact managed resources union payload'
$managedResources = @(
    $armRestCalls[0].BodyDocument['properties']['knowledgeGraphConfiguration']['managedResources']
)
Assert-True `
    -Condition (
        ($managedResources -join "`0") -ceq
        (@(
                $armRestBodyProbe.ExistingManagedResourceId,
                $armRestBodyProbe.ArcResourceGroupId
            ) -join "`0")
    ) `
    -Case 'Existing and ArcBox managed resources are preserved in order'
Assert-True -Condition ($armRestCalls[1].Method -ceq 'put') -Case 'Connector PUT method'
Assert-True `
    -Condition ($armRestCalls[1].Url -ceq $armRestBodyProbe.ConnectorUrl) `
    -Case 'Connector PUT URL'
Assert-True `
    -Condition (
        (ConvertTo-CanonicalJson -Value $armRestCalls[1].BodyDocument) -ceq
        (ConvertTo-CanonicalJson -Value $armRestBodyProbe.ExpectedConnectorBody)
    ) `
    -Case 'Exact Log Analytics connector payload'
$connectorProperties = $armRestCalls[1].BodyDocument['properties']
Assert-True `
    -Condition ($connectorProperties['dataConnectorType'] -ceq 'LogAnalytics') `
    -Case 'Connector remains LogAnalytics'
Assert-True `
    -Condition ($connectorProperties['dataSource'] -ceq $armRestBodyProbe.WorkspaceResourceId) `
    -Case 'Connector exact workspace data source'
Assert-True `
    -Condition ($connectorProperties['identity'] -ceq $armRestBodyProbe.SreIdentityResourceId) `
    -Case 'Connector exact managed identity'
Assert-True `
    -Condition (
        (ConvertTo-CanonicalJson -Value $connectorProperties['extendedProperties']) -ceq
        (ConvertTo-CanonicalJson -Value ([ordered]@{
                    armResourceId = $armRestBodyProbe.WorkspaceResourceId
                    resource = [ordered]@{
                        name = $armRestBodyProbe.WorkspaceName
                    }
                }))
    ) `
    -Case 'Connector exact extended properties'
Assert-True -Condition ($armRestCalls[2].Url -ceq $armRestBodyProbe.FailureUrl) -Case 'Forced failure call'
Assert-True `
    -Condition (
        (ConvertTo-CanonicalJson -Value $armRestCalls[2].BodyDocument) -ceq
        (ConvertTo-CanonicalJson -Value $armRestBodyProbe.ExpectedKnowledgeGraphBody)
    ) `
    -Case 'Failed ARM call receives the expected body file'

$orchestrationPath = Join-Path $repoRoot 'infra\arc-identity.bicep'
$modulePath = Join-Path $repoRoot 'infra\core\arc-identity-monitoring.bicep'
$orchestrationSource = Get-Content -LiteralPath $orchestrationPath -Raw
$moduleSource = Get-Content -LiteralPath $modulePath -Raw
Assert-Contains -Source $orchestrationSource -Expected "targetScope = 'subscription'" -Case 'Subscription orchestration scope'
Assert-Contains -Source $orchestrationSource -Expected 'scope: resourceGroup(arcResourceGroupName)' -Case 'Existing ArcBox RG module scope'
Assert-Contains -Source $moduleSource -Expected 'Microsoft.Insights/dataCollectionRules@2024-03-11' -Case 'Stable DCR API'
Assert-Contains -Source $moduleSource -Expected 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' -Case 'Stable DCRA API'
Assert-Contains -Source $moduleSource -Expected 'Microsoft.Insights/scheduledQueryRules@2023-12-01' -Case 'Stable scheduled query API'
Assert-Contains -Source $moduleSource -Expected 'Microsoft.HybridCompute/machines@2025-01-13'' existing' -Case 'Existing Arc machines'
Assert-Contains -Source $moduleSource -Expected "kind: 'Windows'" -Case 'Windows-only DCR'
Assert-Contains -Source $moduleSource -Expected "Provider[@Name=\'Mercadona.IdentityOps\']" -Case 'Dedicated event provider XPath'
Assert-Contains -Source $moduleSource -Expected "Provider[@Name!=\'Mercadona.IdentityOps\']" -Case 'No duplicate generic provider XPath'
Assert-NotMatches -Source $moduleSource -Pattern '(?i)\bperformanceCounters\b|Microsoft-Perf' -Case 'No duplicate performance ingestion'
Assert-Contains -Source $moduleSource -Expected 'InsightsMetrics' -Case 'Freshness reuses existing VM Insights data'
Assert-Contains -Source $moduleSource -Expected 'Namespace == "Processor" and Name == "UtilizationPercentage"' -Case 'Stable existing metric freshness signal'
Assert-Contains -Source $moduleSource -Expected "operator: 'GreaterThanOrEqual'" -Case 'Deterministic static alert threshold'
Assert-Contains -Source $moduleSource -Expected 'threshold: 8' -Case 'Bounded burst alert threshold'
Assert-Contains -Source $moduleSource -Expected '| project TimeGenerated, _ResourceId' -Case 'Burst alert returns one row per event'
Assert-Contains -Source $moduleSource -Expected '| project ResourceId, Signal' -Case 'Freshness alert returns one row per stale signal'
Assert-NotMatches -Source $moduleSource -Pattern '\|\s*summarize\s+(?:EventCount|MissingOrStaleSignals)=' -Case 'Count alerts do not count aggregate result rows'
Assert-Contains -Source $moduleSource -Expected 'datetime_utc_to_local(CurrentUtc, "Europe/Madrid")' -Case 'DST-aware Madrid startup window'
Assert-Contains -Source $moduleSource -Expected 'MadridMinuteOfDay >= 500' -Case 'Twenty-minute startup grace'
Assert-Contains -Source $moduleSource -Expected 'datetime_part("Hour", CurrentUtc) < 18' -Case 'Fixed UTC shutdown suppression'
Assert-Contains -Source $moduleSource -Expected "displayName: 'ArcBox IdentityOps synthetic AD FS token-failure burst'" -Case 'Identity alert title namespace'
Assert-Contains -Source $moduleSource -Expected "displayName: 'ArcBox IdentityOps heartbeat or data freshness loss'" -Case 'Freshness alert title namespace'
Assert-NotMatches -Source $moduleSource -Pattern "displayName:\s*'Mercadona IdentityOps" -Case 'No overlap with retail Mercadona alert filter'
Assert-NotMatches -Source $moduleSource -Pattern '\bCounterValue\b' -Case 'No performance-value alert threshold'
Assert-Contains -Source $moduleSource -Expected 'severity: 2' -Case 'Sev2 alerts'
Assert-Contains -Source $moduleSource -Expected 'resolveConfiguration:' -Case 'Deterministic alert resolution'
Assert-Contains -Source $moduleSource -Expected "overrideQueryTimeRange: 'PT30M'" -Case 'Supported freshness query override'
Assert-NotMatches -Source $moduleSource -Pattern '\bPT20M\b' -Case 'Unsupported freshness query override'
Assert-NotMatches -Source $moduleSource -Pattern '(?m)^\s*autoMitigate\s*:' -Case 'Resolve configuration omits mutually exclusive autoMitigate'
Assert-Contains -Source $moduleSource -Expected 'actionGroupResourceId' -Case 'Existing action group parameter'
Assert-NotMatches -Source $moduleSource -Pattern '(?im)^\s*''?Security!' -Case 'No broad Security channel'
Assert-NotMatches -Source ($orchestrationSource + $moduleSource) `
    -Pattern '(?i)Microsoft\.Resources/resourceGroups|Microsoft\.HybridCompute/machines/extensions|Microsoft\.OperationalInsights/workspaces@|Microsoft\.Insights/actionGroups@' `
    -Case 'No Jumpstart RG, machine extension, workspace, or action group creation'

$compiledTemplateJson = & az bicep build --file $orchestrationPath --stdout
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $compiledTemplateJson)) {
    throw 'Arc identity Bicep build failed inside the contract test.'
}
$compiledTemplate = $compiledTemplateJson | ConvertFrom-Json -AsHashtable -Depth 100
Assert-True -Condition ($compiledTemplate['$schema'] -like '*subscriptionDeploymentTemplate.json#') -Case 'Compiled subscription template'
$generatedTemplatePath = Join-Path $repoRoot 'infra\arc-identity.json'
Assert-True -Condition (Test-Path -LiteralPath $generatedTemplatePath -PathType Leaf) -Case 'Generated ARM template exists'
$generatedTemplate = Get-Content -LiteralPath $generatedTemplatePath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 100
Assert-True `
    -Condition (
        (ConvertTo-CanonicalJson -Value $generatedTemplate) -ceq
        (ConvertTo-CanonicalJson -Value $compiledTemplate)
    ) `
    -Case 'Generated ARM template is synchronized with Bicep'
$deploymentResources = @($compiledTemplate['resources'])
Assert-True -Condition ($deploymentResources.Count -eq 1) -Case 'Single isolated resource-group deployment module'
Assert-True -Condition ($deploymentResources[0]['type'] -eq 'Microsoft.Resources/deployments') -Case 'Compiled orchestration uses nested deployment'
Assert-True -Condition ($deploymentResources[0]['properties']['mode'] -eq 'Incremental') -Case 'Incremental-only deployment mode'
$nestedResources = @($deploymentResources[0]['properties']['template']['resources'])
$alertResources = @(
    $nestedResources | Where-Object {
        $_['type'] -eq 'Microsoft.Insights/scheduledQueryRules'
    }
)
Assert-True -Condition ($alertResources.Count -eq 2) -Case 'Exactly two scheduled-query alert resources'
$expectedResolveConfiguration = [ordered]@{
    autoResolved = $true
    timeToResolve = 'PT10M'
}
foreach ($alertResource in $alertResources) {
    $alertProperties = $alertResource['properties']
    Assert-True `
        -Condition (-not $alertProperties.ContainsKey('autoMitigate')) `
        -Case "Alert '$($alertResource['name'])' omits mutually exclusive autoMitigate"
    Assert-True `
        -Condition (
            (ConvertTo-CanonicalJson -Value $alertProperties['resolveConfiguration']) -ceq
            (ConvertTo-CanonicalJson -Value $expectedResolveConfiguration)
        ) `
        -Case "Alert '$($alertResource['name'])' exact resolveConfiguration"
}
$freshnessAlertResources = @(
    $alertResources | Where-Object {
        $_['name'] -eq "[parameters('dataFreshnessAlertName')]"
    }
)
Assert-True -Condition ($freshnessAlertResources.Count -eq 1) -Case 'Single freshness alert resource'
Assert-True `
    -Condition ($freshnessAlertResources[0]['properties']['overrideQueryTimeRange'] -eq 'PT30M') `
    -Case 'Compiled freshness override uses supported PT30M'
$tokenAlertResources = @(
    $alertResources | Where-Object {
        $_['name'] -eq "[parameters('tokenFailureAlertName')]"
    }
)
Assert-True -Condition ($tokenAlertResources.Count -eq 1) -Case 'Single token-failure alert resource'
Assert-True `
    -Condition (-not $tokenAlertResources[0]['properties'].ContainsKey('overrideQueryTimeRange')) `
    -Case 'Token-failure alert preserves default query range'

$parameterPath = Join-Path $repoRoot 'infra\arc-identity.parameters.json'
$parameters = Get-Content -LiteralPath $parameterPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$targetMachines = @($parameters['parameters']['targetMachineNames']['value'])
Assert-True -Condition ($targetMachines.Count -eq 2) -Case 'Exactly two parameterized target machines'
Assert-True -Condition ('ArcBox-Win2K22' -in $targetMachines) -Case 'ArcBox-Win2K22 target'
Assert-True -Condition ('ArcBox-Win2K25' -in $targetMachines) -Case 'ArcBox-Win2K25 target'

$deploySource = $scriptSources['deploy-arc-identity.ps1']
Assert-Contains -Source $deploySource -Expected '[switch] $Apply' -Case 'Deployment explicit apply switch'
Assert-Contains -Source $deploySource -Expected 'deployment sub what-if' -Case 'Azure deployment what-if'
Assert-Contains -Source $deploySource -Expected 'if (-not $Apply)' -Case 'Deployment defaults to no change'
Assert-True `
    -Condition (
        $deploySource.IndexOf('deployment sub what-if', [StringComparison]::Ordinal) -lt
        $deploySource.IndexOf('deployment'', ''sub'', ''create', [StringComparison]::Ordinal)
    ) `
    -Case 'What-if precedes deployment create'
Assert-Contains -Source $deploySource -Expected 'refusing to overwrite' -Case 'Collision refusal'
Assert-Contains -Source $deploySource -Expected 'scheduledQueryRules?api-version=2023-12-01' -Case 'Alert collision preflight'
Assert-Contains -Source $deploySource -Expected 'MSVMI-ama-vmi-default-dcr' -Case 'Existing VM Insights association preflight'
Assert-Contains -Source $deploySource -Expected '[System.IO.Path]::GetTempFileName()' -Case 'Temporary deployment parameters file'
Assert-Contains -Source $deploySource -Expected '--parameters $deploymentParameterFileArgument' -Case 'What-if parameter file argument'
Assert-Contains -Source $deploySource -Expected "'--parameters', `$deploymentParameterFileArgument" -Case 'Create parameter file argument'
Assert-NotMatches `
    -Source $deploySource `
    -Pattern 'targetMachineNames\s*=\s*\$machineNamesJson|targetMachineNames=\$machineNamesJson|--parameters\s+@deploymentParameters' `
    -Case 'No inline native deployment parameter JSON'

$deployScriptPath = Join-Path $PSScriptRoot 'deploy-arc-identity.ps1'
$deployTokens = $null
$deployParseErrors = $null
$deployAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $deployScriptPath,
    [ref] $deployTokens,
    [ref] $deployParseErrors
)
$cleanupTryStatement = $deployAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.TryStatementAst] -and
            $null -ne $node.Finally -and
            $node.Body.Extent.Text.Contains('deployment sub what-if', [StringComparison]::Ordinal) -and
            $node.Body.Extent.Text.Contains("'deployment', 'sub', 'create'", [StringComparison]::Ordinal) -and
            $node.Finally.Extent.Text.Contains(
                'Remove-Item -LiteralPath $deploymentParameterFile -Force',
                [StringComparison]::Ordinal
            )
    }, $true)
Assert-True -Condition ($null -ne $cleanupTryStatement) -Case 'Deployment parameter file cleanup in finally'

$applyProbe = Invoke-ArcIdentityDeploymentParameterProbe -DeployScriptPath $deployScriptPath -Apply
Assert-True -Condition ($null -eq $applyProbe.ErrorMessage) -Case 'Fake Azure CLI apply execution'
$applyCalls = @($applyProbe.Calls)
Assert-True -Condition ($applyCalls.Count -eq 2) -Case 'What-if and create fake Azure CLI calls'
Assert-True -Condition ($applyCalls[0].Operation -ceq 'what-if') -Case 'What-if remains first'
Assert-True -Condition ($applyCalls[1].Operation -ceq 'create') -Case 'Create follows approved what-if'
Assert-True `
    -Condition ($applyCalls[0].ParameterArgument -ceq $applyCalls[1].ParameterArgument) `
    -Case 'What-if and create share one parameter file argument'
Assert-True `
    -Condition ($applyCalls[0].ParameterPath -ceq $applyCalls[1].ParameterPath) `
    -Case 'What-if and create share one parameter file path'
Assert-True `
    -Condition (-not (Test-Path -LiteralPath $applyCalls[0].ParameterPath)) `
    -Case 'Apply parameter file cleanup'
Assert-True `
    -Condition (
        (ConvertTo-CanonicalJson -Value $applyCalls[0].ParameterDocument) -ceq
        (ConvertTo-CanonicalJson -Value $applyCalls[1].ParameterDocument)
    ) `
    -Case 'What-if and create share one parameter document'
$applyParameterValues = $applyCalls[0].ParameterDocument['parameters']
Assert-True `
    -Condition (
        $applyCalls[0].ParameterDocument['$schema'] -ceq
        'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    ) `
    -Case 'ARM deployment parameters schema'
Assert-True `
    -Condition ($applyCalls[0].ParameterDocument['contentVersion'] -ceq '1.0.0.0') `
    -Case 'ARM deployment parameters content version'
foreach ($expectedParameter in $applyProbe.ExpectedParameters.GetEnumerator()) {
    if ($expectedParameter.Key -eq 'targetMachineNames') {
        $actualMachineNames = @($applyParameterValues[$expectedParameter.Key]['value'])
        Assert-True `
            -Condition (
                ($actualMachineNames -join "`0") -ceq
                (@($expectedParameter.Value) -join "`0")
            ) `
            -Case 'Deployment target machine JSON array shape'
        continue
    }
    Assert-True `
        -Condition ($applyParameterValues[$expectedParameter.Key]['value'] -ceq $expectedParameter.Value) `
        -Case "Deployment parameter override: $($expectedParameter.Key)"
}

$planProbe = Invoke-ArcIdentityDeploymentParameterProbe -DeployScriptPath $deployScriptPath
Assert-True -Condition ($null -eq $planProbe.ErrorMessage) -Case 'Fake Azure CLI plan execution'
$planCalls = @($planProbe.Calls)
Assert-True -Condition ($planCalls.Count -eq 1) -Case 'Plan mode invokes only what-if'
Assert-True -Condition ($planCalls[0].Operation -ceq 'what-if') -Case 'Plan mode has no create'
Assert-True `
    -Condition (-not (Test-Path -LiteralPath $planCalls[0].ParameterPath)) `
    -Case 'Plan parameter file cleanup'

$failureProbe = Invoke-ArcIdentityDeploymentParameterProbe -DeployScriptPath $deployScriptPath -FailWhatIf
$failureCalls = @($failureProbe.Calls)
Assert-True `
    -Condition ($failureProbe.ErrorMessage -ceq 'Arc identity subscription deployment what-if failed.') `
    -Case 'What-if failure propagation'
Assert-True -Condition ($failureCalls.Count -eq 1) -Case 'Failed what-if prevents create'
Assert-True `
    -Condition (-not (Test-Path -LiteralPath $failureCalls[0].ParameterPath)) `
    -Case 'Failed what-if parameter file cleanup'

$incidentSource = $scriptSources['start-arc-identity-incident.ps1']
$recoverySource = $scriptSources['recover-arc-identity-incident.ps1']
$commonSource = $scriptSources['ArcIdentity.Common.ps1']
foreach ($source in @($incidentSource, $recoverySource)) {
    Assert-Contains -Source $source -Expected "Mercadona.IdentityOps" -Case 'Dedicated synthetic event source'
    Assert-Contains -Source $source -Expected 'demoSynthetic = $true' -Case 'Synthetic JSON marker'
    Assert-Contains -Source $source -Expected 'correlationId = $correlationId' -Case 'Synthetic correlation ID'
    Assert-Contains -Source $source -Expected "'S-1-5-18'" -Case 'LocalSystem execution guard'
    Assert-Contains -Source $source -Expected 'Write-EventLog' -Case 'Application event write'
    Assert-NotMatches -Source $source -Pattern '(?i)Install-WindowsFeature|Set-AdfsProperties|New-ADUser|logon|auditpol|Clear-EventLog|wevtutil\s+cl|New-ScheduledTask|Register-ScheduledTask' -Case 'No identity attack, role install, log tampering, or persistent task'
    Assert-NotMatches -Source $source -Pattern '(?i)while\s*\(\s*\$true\s*\)|for\s*\(\s*;\s*;\s*\)' -Case 'No unbounded loop'
}
Assert-Contains -Source $incidentSource -Expected '[ValidateRange(8, 20)]' -Case 'Bounded event count parameter'
Assert-Contains -Source $incidentSource -Expected '$sequence -le $burstCount' -Case 'Bounded event write loop'
Assert-Contains -Source $incidentSource -Expected '$expectedEvents = $MachineNames.Count * $EventsPerMachine' -Case 'Exact ingestion count'
Assert-Contains -Source $recoverySource -Expected '$recoveryCount -gt 1' -Case 'Single recovery invariant'
Assert-Contains -Source $incidentSource -Expected '[DateTimeOffset]::ParseExact' -Case 'Correlation-scoped retry window'
Assert-Contains -Source $recoverySource -Expected '[DateTimeOffset]::ParseExact' -Case 'Recovery correlation retry window'
Assert-Contains -Source $incidentSource -Expected 'ForEach-Object {' -Case 'Streaming incident retry inspection'
Assert-Contains -Source $recoverySource -Expected 'ForEach-Object {' -Case 'Streaming recovery retry inspection'
Assert-NotMatches -Source ($incidentSource + $recoverySource) -Pattern '\$candidateEvents\s*=\s*@\(' -Case 'No materialized event-history collection'
Assert-NotMatches -Source ($incidentSource + $recoverySource) -Pattern 'ConvertFrom-Json\s+-AsHashtable|\?\?|\?\s*[^:\r\n]+\s*:|&&|\|\|' -Case 'Embedded Run Command remains Windows PowerShell 5.1 compatible'
Assert-Contains -Source $commonSource -Expected "'connectedmachine', 'run-command', 'delete'" -Case 'Run Command cleanup'
Assert-Contains -Source $commonSource -Expected "[ValidatePattern('^identityops-" -Case 'Dedicated Run Command name guard'
Assert-Contains -Source $commonSource -Expected '[switch] $AllowNotFound' -Case 'Non-destructive SRE resource preflight'
Assert-Contains -Source $commonSource -Expected "'--timeout-in-seconds', [string] `$TimeoutSeconds" -Case 'Bounded guest Run Command execution'
Assert-Contains -Source $commonSource -Expected "'--no-wait'" -Case 'Nonblocking Run Command control-plane operations'
Assert-Contains -Source $commonSource -Expected '$cleanupDeadline = (Get-Date).AddSeconds(120)' -Case 'Bounded Run Command cleanup'
Assert-True `
    -Condition (
        $commonSource.IndexOf('$deadline = (Get-Date).AddSeconds($TimeoutSeconds)', [StringComparison]::Ordinal) -lt
        $commonSource.IndexOf("'connectedmachine', 'run-command', 'create'", [StringComparison]::Ordinal)
    ) `
    -Case 'Run Command deadline starts before create'
if ($IsWindows) {
    $windowsPowerShellProbe = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$payload = '{"demoSynthetic":true,"correlationId":"SYNTH-ID-20260714T080000Z-ABCDEF12","eventType":"SyntheticAdfsTokenFailure"}' | ConvertFrom-Json
if ($payload.demoSynthetic -ne $true -or
    $payload.correlationId -ne 'SYNTH-ID-20260714T080000Z-ABCDEF12' -or
    $payload.eventType -ne 'SyntheticAdfsTokenFailure') {
    exit 1
}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('AsHashtable')) {
    exit 2
}
'@
    & powershell.exe -NoLogo -NoProfile -NonInteractive -Command $windowsPowerShellProbe
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Case 'Windows PowerShell 5.1 event payload compatibility'
}

$allNewSources = ($scriptSources.Values -join "`n") + "`n$orchestrationSource`n$moduleSource"
foreach ($destructivePattern in @(
        '(?i)az\s+group\s+delete',
        '(?i)connectedmachine'',\s*''delete',
        '(?i)extension'',\s*''delete',
        '(?i)Microsoft\.HybridCompute/machines/delete',
        '(?i)Remove-AzConnectedMachine',
        '(?i)Remove-EventLog',
        '(?i)mode\s*:\s*[''"]Complete[''"]'
    )) {
    Assert-NotMatches -Source $allNewSources -Pattern $destructivePattern -Case 'No destructive Jumpstart operation'
}

$configureSource = $scriptSources['configure-arc-identity-sre-agent.ps1']
$armRestHelperCallCount = [regex]::Matches(
    $configureSource,
    '(?m)^\s*Invoke-ArcIdentityArmRestWithJsonBody\s+`'
).Count
Assert-True -Condition ($armRestHelperCallCount -eq 2) -Case 'Exactly two ARM JSON helper call sites'
Assert-Contains -Source $configureSource -Expected '-Body $knowledgeGraphPatch' -Case 'Knowledge graph helper body'
Assert-Contains -Source $configureSource -Expected "-Method 'patch'" -Case 'Knowledge graph helper method'
Assert-Contains -Source $configureSource -Expected '-Body $connectorBody' -Case 'Connector helper body'
Assert-Contains -Source $configureSource -Expected "-Method 'put'" -Case 'Connector helper method'
Assert-Contains `
    -Source $configureSource `
    -Expected 'if ($knowledgeGraphPlan.RequiresPatch)' `
    -Case 'Knowledge graph PATCH decision'
Assert-Contains `
    -Source $configureSource `
    -Expected 'Reusing existing exact SRE Agent knowledge graph configuration.' `
    -Case 'Exact knowledge graph reuse'
Assert-Contains `
    -Source $configureSource `
    -Expected 'if ($null -eq $existingConnector)' `
    -Case 'Missing connector PUT decision'
Assert-Contains `
    -Source $configureSource `
    -Expected "Reusing existing exact-scope connector '`$connectorName'." `
    -Case 'Exact connector reuse'
$initialAgentWaitIndex = $configureSource.IndexOf(
    '$agent = Wait-ArcIdentitySreAgentProvisioningSucceeded',
    [StringComparison]::Ordinal
)
$knowledgeGraphPatchIndex = $configureSource.IndexOf(
    '$knowledgeGraphPatch = $null',
    [StringComparison]::Ordinal
)
$knowledgeGraphMutationIndex = $configureSource.IndexOf(
    "-FailureMessage 'Unable to add the ArcBox resource group to SRE Agent managed resources.'",
    [StringComparison]::Ordinal
)
$postKnowledgeGraphWaitIndex = $configureSource.IndexOf(
    '$agentAfterKnowledgeGraphPatch = Wait-ArcIdentitySreAgentProvisioningSucceeded',
    [StringComparison]::Ordinal
)
$connectorMutationIndex = $configureSource.IndexOf(
    "-FailureMessage 'Unable to configure the additive ArcBox Log Analytics connector.'",
    [StringComparison]::Ordinal
)
$postConnectorWaitIndex = $configureSource.IndexOf(
    '$agentAfterConnectorPut = Wait-ArcIdentitySreAgentProvisioningSucceeded',
    [StringComparison]::Ordinal
)
$postConnectorValidationIndex = $configureSource.IndexOf(
    '$createdConnector = Invoke-ArcIdentityAzJson',
    [StringComparison]::Ordinal
)
$applyDataPlaneBoundaryIndex = $configureSource.IndexOf(
    'Assert-ArcIdentitySreExtensionResourceCollisions `',
    $postConnectorWaitIndex,
    [StringComparison]::Ordinal
)
Assert-True `
    -Condition (
        $initialAgentWaitIndex -ge 0 -and
        $initialAgentWaitIndex -lt $knowledgeGraphPatchIndex
    ) `
    -Case 'Pre-existing agent operation wait precedes mutation decisions'
Assert-True `
    -Condition (
        $knowledgeGraphMutationIndex -lt $postKnowledgeGraphWaitIndex -and
        $postKnowledgeGraphWaitIndex -lt $connectorMutationIndex
    ) `
    -Case 'Knowledge graph PATCH wait precedes connector PUT'
Assert-True `
    -Condition (
        $connectorMutationIndex -lt $postConnectorWaitIndex -and
        $postConnectorWaitIndex -lt $postConnectorValidationIndex -and
        $postConnectorValidationIndex -lt $applyDataPlaneBoundaryIndex
    ) `
    -Case 'Connector PUT wait and validation precede SRE data-plane boundary'
Assert-True `
    -Condition (
        [regex]::Matches(
            $configureSource,
            '(?m)^\s*Ensure-ArcIdentityRoleAssignment\s+`'
        ).Count -eq 3
    ) `
    -Case 'Exactly three intended read-only role assignments'
Assert-NotMatches `
    -Source $configureSource `
    -Pattern '(?m)^\s*[''"]?--body[''"]?\s*[, ]' `
    -Case 'Configurator has no legacy inline Azure CLI body argument'
Assert-Contains `
    -Source $commonSource `
    -Expected 'function Invoke-ArcIdentityArmRestWithJsonBody' `
    -Case 'Shared ARM JSON body helper'
Assert-Contains `
    -Source $commonSource `
    -Expected '[System.Text.UTF8Encoding]::new($false)' `
    -Case 'ARM body UTF-8 without BOM'
Assert-Contains `
    -Source $commonSource `
    -Expected '$bodyFileArgument = "@$bodyFile"' `
    -Case 'ARM body @file argument'
Assert-Contains `
    -Source $commonSource `
    -Expected 'Remove-Item -LiteralPath $bodyFile -Force' `
    -Case 'ARM body file cleanup'
Assert-Contains `
    -Source $commonSource `
    -Expected '[int] $TimeoutSeconds = 600' `
    -Case 'SRE Agent wait ten-minute default timeout'
Assert-Contains `
    -Source $commonSource `
    -Expected '[int] $PollIntervalSeconds = 10' `
    -Case 'SRE Agent wait default poll interval'
Assert-Contains `
    -Source $commonSource `
    -Expected 'function Assert-ArcIdentityLogAnalyticsConnector' `
    -Case 'Shared connector assertion'
Assert-Contains `
    -Source $commonSource `
    -Expected 'function Get-ArcIdentitySkillAdditionalFiles' `
    -Case 'Shared skill file loader'
Assert-Contains `
    -Source $commonSource `
    -Expected 'function Format-ArcIdentitySreAgentApiError' `
    -Case 'Bounded data-plane error formatter'
Assert-NotMatches `
    -Source $commonSource `
    -Pattern '\.EnsureSuccessStatusCode\(' `
    -Case 'Data-plane errors are read before disposal'
Assert-NotMatches `
    -Source $commonSource `
    -Pattern '(?i)Write-(?:Host|Output|Verbose|Debug|Information|Warning)[^\r\n]*(?:bodyJson|\$Body)' `
    -Case 'ARM helper does not print request bodies'
Assert-NotMatches `
    -Source $commonSource `
    -Pattern '(?i)throw[^\r\n]*(?:Authorization|Bearer|ArcIdentitySreHeaders|\$Body(?:\W|$))' `
    -Case 'Data-plane errors do not echo authorization or request bodies'
foreach ($requiredContract in @(
        'identity-infrastructure-analyzer',
        'identity-infrastructure-operations',
        'identity-infrastructure-sev2',
        'identity-infrastructure-weekday-report',
        "titleContains = 'ArcBox IdentityOps'",
        "cronExpression = '30 7 * * 1-5'",
        "agentMode = 'Review'",
        'Microsoft Sentinel',
        'SOC',
        'demoSynthetic=true',
        '$readerRoleId = ''acdd72a7-3385-48ef-bd42-f606fba81ae7''',
        '$monitoringReaderRoleId = ''43d0d8ad-25c7-4714-9337-8ba259a9fe05''',
        '$logAnalyticsReaderRoleId = ''73c42c96-874c-492b-b04d-ab87d138a893'''
    )) {
    Assert-Contains -Source $configureSource -Expected ([string] $requiredContract) -Case 'SRE Agent identity contract'
}
Assert-NotMatches -Source $configureSource -Pattern '(?i)RunAzCliWriteCommands|\bOwner\b|\bContributor\b' -Case 'Read-only SRE Agent tools and roles'
Assert-Contains -Source $configureSource -Expected "-PropertyName 'mode') -ne 'Review'" -Case 'Review mode preflight'
Assert-Contains -Source $configureSource -Expected "-PropertyName 'accessLevel') -ne 'Low'" -Case 'Low access preflight'
Assert-Contains -Source $configureSource -Expected 'refusing to overwrite it' -Case 'SRE resource collision refusal'
Assert-Contains -Source $configureSource -Expected 'Perf table is expected' -Case 'SRE instructions preserve existing InsightsMetrics source'
Assert-Contains `
    -Source $configureSource `
    -Expected 'Get-ArcIdentitySkillAdditionalFiles' `
    -Case 'Configurator loads checked-in skill files'
Assert-Contains `
    -Source $configureSource `
    -Expected 'additionalFiles = $skillAdditionalFiles' `
    -Case 'Skill payload uses file objects'
Assert-NotMatches `
    -Source $configureSource `
    -Pattern '(?s)additionalFiles\s*=\s*@\(\s*[''"]kql/arc-identity/' `
    -Case 'Skill payload has no string-only additionalFiles'
Assert-Contains `
    -Source $configureSource `
    -Expected 'Assert-ArcIdentityLogAnalyticsConnector' `
    -Case 'Configurator uses shared connector assertion'
Assert-True `
    -Condition (
        [regex]::Matches(
            $configureSource,
            '(?m)^\s*Assert-ArcIdentityLogAnalyticsConnector\s+`'
        ).Count -eq 2
    ) `
    -Case 'Configurator validates existing and newly created connectors'
$retailConfigureSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'configure-sre-agent.ps1') -Raw
Assert-Contains -Source $retailConfigureSource -Expected "titleContains = 'mercadona'" -Case 'Existing retail filter baseline'
Assert-NotMatches -Source $configureSource -Pattern "titleContains\s*=\s*'mercadona'" -Case 'Identity filter does not overlap retail namespace'
$verifySource = $scriptSources['verify-arc-identity.ps1']
Assert-Contains -Source $verifySource -Expected '$freshnessLookbackMinutes = $MaximumIngestionAgeMinutes + 5' -Case 'Verification lookback follows accepted freshness threshold'
Assert-Contains -Source $verifySource -Expected 'MSVMI-ama-vmi-default-dcr' -Case 'Verification preserves existing VM Insights DCR'
Assert-Contains -Source $verifySource -Expected 'no duplicate performance-counter source' -Case 'Verification rejects duplicate counters'
$verifyContractTokens = $null
$verifyContractErrors = $null
$verifyContractAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $verifySource,
    [ref] $verifyContractTokens,
    [ref] $verifyContractErrors
)
Assert-True `
    -Condition ($verifyContractErrors.Count -eq 0) `
    -Case 'Verifier parses for DCR source cardinality probe'
$verifyXPathFragmentLoops = @(
    $verifyContractAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Extent.Text.Contains(
            'The dedicated DCR is missing XPath contract',
            [StringComparison]::Ordinal
        )
    }, $true)
)
$verifyXPathSecurityChecks = @(
    $verifyContractAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains(
            'The synthetic identity DCR must not collect the broad Windows Security log.',
            [StringComparison]::Ordinal
        )
    }, $true)
)
Assert-True `
    -Condition ($verifyXPathFragmentLoops.Count -eq 1 -and $verifyXPathSecurityChecks.Count -eq 1) `
    -Case 'Verifier has one XPath fragment and Security rejection block'
$verifyXPathContractStart = $verifyXPathFragmentLoops[0].Extent.StartOffset
$verifyXPathContractEnd = $verifyXPathSecurityChecks[0].Extent.EndOffset
Assert-True `
    -Condition ($verifyXPathContractStart -lt $verifyXPathContractEnd) `
    -Case 'Verifier XPath checks preserve fragment-before-Security order'
$verifyXPathContract = [scriptblock]::Create(
    "param([string[]] `$xPathQueries)`n" +
    $verifySource.Substring(
        $verifyXPathContractStart,
        $verifyXPathContractEnd - $verifyXPathContractStart
    )
)
$liveXPathQueries = @(
    "Application!*[System[Provider[@Name='Mercadona.IdentityOps'] and (EventID=4101 or EventID=4102)]]"
    'System!*[System[(Level=1 or Level=2 or Level=3)]]'
    "Application!*[System[(Level=1 or Level=2 or Level=3) and Provider[@Name!='Mercadona.IdentityOps']]]"
)
$requiredXPathFragments = @(
    "Provider[@Name='Mercadona.IdentityOps']"
    'EventID=4101'
    'EventID=4102'
    'System!*[System[(Level=1 or Level=2 or Level=3)]]'
    "Provider[@Name!='Mercadona.IdentityOps']"
)
$liveXPathError = $null
try {
    & $verifyXPathContract -xPathQueries $liveXPathQueries
} catch {
    $liveXPathError = $_.Exception.Message
}
Assert-True `
    -Condition ($null -eq $liveXPathError) `
    -Case 'Verifier accepts exact live XPath queries with brackets and inequality'
foreach ($missingXPathFragment in $requiredXPathFragments) {
    $missingXPathQueries = @(
        $liveXPathQueries | ForEach-Object {
            ([string] $_).Replace($missingXPathFragment, '<missing>')
        }
    )
    $missingXPathError = $null
    try {
        & $verifyXPathContract -xPathQueries $missingXPathQueries
    } catch {
        $missingXPathError = $_.Exception.Message
    }
    Assert-True `
        -Condition (
            $missingXPathError -ceq
            "The dedicated DCR is missing XPath contract '$missingXPathFragment'."
        ) `
        -Case "Verifier rejects missing XPath fragment '$missingXPathFragment'"
}
$securityXPathError = $null
try {
    & $verifyXPathContract -xPathQueries (
        @($liveXPathQueries) + 'Security!*[System[(Level=1 or Level=2 or Level=3)]]'
    )
} catch {
    $securityXPathError = $_.Exception.Message
}
Assert-True `
    -Condition (
        $securityXPathError -ceq
        'The synthetic identity DCR must not collect the broad Windows Security log.'
    ) `
    -Case 'Verifier preserves broad Security log rejection'
$countValidatedOptionalArrayNames = @(
    '$windowsEventLogs',
    '$performanceCounters',
    '$dcrDataFlows',
    '$eventStreams',
    '$logAnalyticsDestinations'
)
$countValidatedOptionalArrayAssignments = @(
    $verifyContractAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -in $countValidatedOptionalArrayNames
    }, $true)
)
Assert-True `
    -Condition ($countValidatedOptionalArrayAssignments.Count -eq $countValidatedOptionalArrayNames.Count) `
    -Case 'Verifier has all count-validated optional array assignments'
foreach ($assignment in $countValidatedOptionalArrayAssignments) {
    Assert-Contains `
        -Source $assignment.Right.Extent.Text `
        -Expected 'Where-Object { $null -ne $_ }' `
        -Case "Verifier excludes nulls from $($assignment.Left.Extent.Text)"
}
$verifySourceAssignments = @(
    $countValidatedOptionalArrayAssignments |
        Where-Object { $_.Left.Extent.Text -in @('$windowsEventLogs', '$performanceCounters') }
)
$verifySourceCardinalityChecks = @(
    $verifyContractAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains('$windowsEventLogs.Count -ne 1', [StringComparison]::Ordinal) -and
        $node.Extent.Text.Contains('$performanceCounters.Count -ne 0', [StringComparison]::Ordinal)
    }, $true)
)
Assert-True `
    -Condition ($verifySourceAssignments.Count -eq 2 -and $verifySourceCardinalityChecks.Count -eq 1) `
    -Case 'Verifier has one DCR source cardinality contract'
$verifySourceContractStart = ($verifySourceAssignments | Sort-Object {
        $_.Extent.StartOffset
    } | Select-Object -First 1).Extent.StartOffset
$verifySourceContractEnd = $verifySourceCardinalityChecks[0].Extent.EndOffset
$verifySourceContract = [scriptblock]::Create(
    "param([AllowNull()][object] `$dcrDataSources)`n" +
    $verifySource.Substring(
        $verifySourceContractStart,
        $verifySourceContractEnd - $verifySourceContractStart
    )
)
$windowsEventSource = [pscustomobject]@{ name = 'SyntheticWindowsEvents' }
$validDcrDataSources = [pscustomobject]@{
    windowsEventLogs = @($windowsEventSource)
}
$validDcrError = $null
try {
    & $verifySourceContract $validDcrDataSources
} catch {
    $validDcrError = $_.Exception.Message
}
Assert-True `
    -Condition ($null -eq $validDcrError) `
    -Case 'Verifier accepts an absent performanceCounters property'
$performanceDcrError = $null
try {
    & $verifySourceContract ([pscustomobject]@{
            windowsEventLogs = @($windowsEventSource)
            performanceCounters = @([pscustomobject]@{ name = 'SyntheticPerformance' })
        })
} catch {
    $performanceDcrError = $_.Exception.Message
}
Assert-True `
    -Condition ($performanceDcrError -ceq 'The dedicated DCR must contain exactly one Windows event source and no duplicate performance-counter source.') `
    -Case 'Verifier rejects an actual performanceCounters entry'
$invalidWindowsEventLogCases = @(
    [pscustomobject]@{
        Name = 'missing'
        Values = @()
    }
    [pscustomobject]@{
        Name = 'multiple'
        Values = @($windowsEventSource, $windowsEventSource)
    }
)
foreach ($invalidWindowsEventLogCase in $invalidWindowsEventLogCases) {
    $windowsEventDcrError = $null
    try {
        & $verifySourceContract ([pscustomobject]@{
                windowsEventLogs = $invalidWindowsEventLogCase.Values
            })
    } catch {
        $windowsEventDcrError = $_.Exception.Message
    }
    Assert-True `
        -Condition ($windowsEventDcrError -ceq 'The dedicated DCR must contain exactly one Windows event source and no duplicate performance-counter source.') `
        -Case "Verifier rejects $($invalidWindowsEventLogCase.Name) windowsEventLogs entries"
}
$scheduledTaskEnabledFunctions = @(
    $verifyContractAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Test-ArcIdentityScheduledTaskEnabled'
    }, $true)
)
$scheduledTaskPropertyAssignments = @(
    $verifyContractAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$scheduledTaskProperties'
    }, $true)
)
$scheduledTaskContractChecks = @(
    $verifyContractAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains('$scheduledTaskMode -ne ''Review''', [StringComparison]::Ordinal) -and
        $node.Extent.Text.Contains('$scheduledTaskCron -ne ''30 7 * * 1-5''', [StringComparison]::Ordinal) -and
        $node.Extent.Text.Contains('-not $scheduledTaskEnabledStateIsValid', [StringComparison]::Ordinal)
    }, $true)
)
Assert-True `
    -Condition (
        $scheduledTaskEnabledFunctions.Count -eq 1 -and
        $scheduledTaskPropertyAssignments.Count -eq 1 -and
        $scheduledTaskContractChecks.Count -eq 1
    ) `
    -Case 'Verifier has one normalized scheduled task contract'
$scheduledTaskValidationContract = [scriptblock]::Create(
    "param([AllowNull()][object] `$scheduledTask)`n" +
    $scheduledTaskEnabledFunctions[0].Extent.Text +
    "`n" +
    $verifySource.Substring(
        $scheduledTaskPropertyAssignments[0].Extent.StartOffset,
        $scheduledTaskContractChecks[0].Extent.EndOffset -
        $scheduledTaskPropertyAssignments[0].Extent.StartOffset
    )
)

function New-ArcIdentityScheduledTaskProbeResponse {
    param(
        [hashtable] $Properties = @{},
        [hashtable] $TopLevel = @{}
    )

    $taskProperties = [ordered]@{
        agentMode = 'Review'
        cronExpression = '30 7 * * 1-5'
    }
    foreach ($key in $Properties.Keys) {
        $taskProperties[$key] = $Properties[$key]
    }
    $response = [ordered]@{
        properties = [pscustomobject] $taskProperties
    }
    foreach ($key in $TopLevel.Keys) {
        $response[$key] = $TopLevel[$key]
    }
    return [pscustomobject] $response
}

$scheduledTaskStateCases = @(
    [pscustomobject]@{ Name = 'live Active status'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ status = 'Active' }; ExpectedValid = $true }
    [pscustomobject]@{ Name = 'top-level Active status'; Task = New-ArcIdentityScheduledTaskProbeResponse -TopLevel @{ status = 'Active' }; ExpectedValid = $true }
    [pscustomobject]@{ Name = 'explicit true'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ isEnabled = $true }; ExpectedValid = $true }
    [pscustomobject]@{ Name = 'aligned true and Active'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ isEnabled = $true; status = 'Active' }; ExpectedValid = $true }
    [pscustomobject]@{ Name = 'aligned nested and top-level state'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ isEnabled = $true; status = 'Active' } -TopLevel @{ isEnabled = $true; status = 'Active' }; ExpectedValid = $true }
    [pscustomobject]@{ Name = 'explicit false'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ isEnabled = $false }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'false conflicting with Active'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ isEnabled = $false; status = 'Active' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'true conflicting with Inactive'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ isEnabled = $true; status = 'Inactive' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'nested true conflicting with top-level false'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ isEnabled = $true; status = 'Active' } -TopLevel @{ isEnabled = $false; status = 'Active' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'nested Active conflicting with top-level Disabled'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ status = 'Active' } -TopLevel @{ status = 'Disabled' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'nested Active conflicting with wrong-case top-level status'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ status = 'Active' } -TopLevel @{ status = 'active' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'Inactive status'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ status = 'Inactive' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'Disabled status'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ status = 'Disabled' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'wrong-case active status'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ status = 'active' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'explicit null'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ isEnabled = $null; status = 'Active' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'non-boolean explicit value'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ isEnabled = 'true'; status = 'Active' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'explicit null status'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ status = $null }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'missing enabled state'; Task = New-ArcIdentityScheduledTaskProbeResponse; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'wrong cron'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ status = 'Active'; cronExpression = '0 7 * * 1-5' }; ExpectedValid = $false }
    [pscustomobject]@{ Name = 'non-Review mode'; Task = New-ArcIdentityScheduledTaskProbeResponse -Properties @{ status = 'Active'; agentMode = 'Autonomous' }; ExpectedValid = $false }
)
foreach ($scheduledTaskStateCase in $scheduledTaskStateCases) {
    $scheduledTaskValidationError = $null
    try {
        $null = & $scheduledTaskValidationContract $scheduledTaskStateCase.Task
    } catch {
        $scheduledTaskValidationError = $_.Exception.Message
    }
    if ($scheduledTaskStateCase.ExpectedValid) {
        Assert-True `
            -Condition ($null -eq $scheduledTaskValidationError) `
            -Case "Verifier accepts scheduled task: $($scheduledTaskStateCase.Name)"
    } else {
        Assert-True `
            -Condition (
                $scheduledTaskValidationError -ceq
                'The identity operational report must remain enabled, weekday-only, and Review mode.'
            ) `
            -Case "Verifier rejects scheduled task: $($scheduledTaskStateCase.Name)"
    }
}
Assert-Contains -Source $verifySource -Expected '$autoMitigate = Get-ArcIdentityOptionalPropertyValue' -Case 'Verification tolerates absent autoMitigate'
Assert-Contains -Source $verifySource -Expected '$null -ne $autoMitigate -and $autoMitigate -ne $true' -Case 'Verification rejects conflicting autoMitigate'
Assert-NotMatches -Source $verifySource -Pattern '\$properties\.autoMitigate' -Case 'Verification does not require autoMitigate response'
Assert-Contains -Source $verifySource -Expected "-ExpectedOverrideQueryTimeRange 'PT30M'" -Case 'Verification expects supported freshness override'
Assert-Contains `
    -Source $verifySource `
    -Expected 'Assert-ArcIdentityLogAnalyticsConnector' `
    -Case 'Verifier uses shared connector assertion'

$kqlDirectory = Join-Path $repoRoot 'kql\arc-identity'
$requiredKqlFiles = @($expectedSkillFilePaths | ForEach-Object { Split-Path -Leaf $_ })
foreach ($kqlFileName in $requiredKqlFiles) {
    $kqlPath = Join-Path $kqlDirectory $kqlFileName
    Assert-True -Condition (Test-Path -LiteralPath $kqlPath -PathType Leaf) -Case "KQL asset exists: $kqlFileName"
    $kql = Get-Content -LiteralPath $kqlPath -Raw
    Assert-Contains -Source $kql -Expected 'rg-arcbox-itpro-weu-002' -Case "$kqlFileName exact ArcBox scope"
    Assert-NotMatches -Source $kql -Pattern '(?i)\bUserName\b|\bAccountName\b|\bTargetUserName\b|\|\s*project\s+\*' -Case "$kqlFileName no user identity or wildcard projection"
    Assert-NotMatches -Source $kql -Pattern '(?im)\|\s*project[^\r\n]*(RenderedDescription|EventData|Message)' -Case "$kqlFileName no raw event message projection"
}
$syntheticKql = Get-Content -LiteralPath (Join-Path $kqlDirectory 'synthetic-token-failure-burst.kql') -Raw
Assert-Contains -Source $syntheticKql -Expected 'demoSynthetic' -Case 'Synthetic KQL marker'
Assert-Contains -Source $syntheticKql -Expected '| summarize' -Case 'Synthetic KQL aggregate'
$performanceKql = Get-Content -LiteralPath (Join-Path $kqlDirectory 'performance-correlation.kql') -Raw
Assert-Contains -Source $performanceKql -Expected '| summarize' -Case 'Performance KQL remains informational and aggregate'
Assert-Contains -Source $performanceKql -Expected 'InsightsMetrics' -Case 'Performance KQL reuses VM Insights'
Assert-Contains -Source $performanceKql -Expected 'UtilizationPercentage' -Case 'Performance KQL includes CPU'
Assert-Contains -Source $performanceKql -Expected 'AvailableMB' -Case 'Performance KQL includes available memory'
Assert-Contains -Source $performanceKql -Expected 'ReadLatencyMs' -Case 'Performance KQL includes disk latency'
Assert-Contains -Source $performanceKql -Expected 'FreeSpacePercentage' -Case 'Performance KQL includes disk free space'
Assert-Contains -Source $performanceKql -Expected 'ReadBytesPerSecond' -Case 'Performance KQL includes network'
Assert-NotMatches -Source $performanceKql -Pattern '\|\s*where\s+Val\s*(?:[<>]=?|==|!=)' -Case 'Performance KQL has no threshold predicate'
$freshnessKql = Get-Content -LiteralPath (Join-Path $kqlDirectory 'data-freshness.kql') -Raw
Assert-Contains -Source $freshnessKql -Expected '["Heartbeat", "InsightsMetrics"]' -Case 'Freshness requires existing continuous signals only'
Assert-NotMatches -Source $freshnessKql -Pattern '\bPerf\b' -Case 'Freshness does not query intentionally empty Perf'
Assert-NotMatches -Source $freshnessKql -Pattern 'Signal="Event"' -Case 'Sporadic Event data is not marked stale'
Assert-Contains -Source $freshnessKql -Expected 'datetime_utc_to_local(CurrentUtc, "Europe/Madrid")' -Case 'Operator freshness query observes DST'
Assert-Contains -Source $freshnessKql -Expected 'MadridMinuteOfDay >= 500' -Case 'Operator query observes startup grace'
Assert-Contains -Source $freshnessKql -Expected 'datetime_part("Hour", CurrentUtc) < 18' -Case 'Operator query observes UTC shutdown'

$excludedPathPattern = '[\\/](?:node_modules|build|bin|obj|\.git)[\\/]'
$jsonFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.json' |
    Where-Object { $_.FullName -notmatch $excludedPathPattern }
foreach ($jsonFile in $jsonFiles) {
    try {
        Get-Content -LiteralPath $jsonFile.FullName -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100 |
            Out-Null
    } catch {
        throw "JSON parse failed for '$($jsonFile.FullName)': $($_.Exception.Message)"
    }
}

$yamlFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
    Where-Object {
        $_.Extension -in @('.yml', '.yaml') -and
        $_.FullName -notmatch $excludedPathPattern
    }
foreach ($yamlFile in $yamlFiles) {
    & python -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' $yamlFile.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "YAML parse failed for '$($yamlFile.FullName)'."
    }
}

$newDocs = @(
    (Join-Path $repoRoot 'docs\arquitectura-identidad-arc.md')
    (Join-Path $repoRoot 'docs\runbooks\arc-identidad-operaciones.md')
    (Join-Path $repoRoot 'docs\guia-demo-identidad-arc.md')
)
$newFilePaths = @(
    $newScriptNames | ForEach-Object { Join-Path $PSScriptRoot $_ }
) + @(
    $orchestrationPath,
    $modulePath,
    $parameterPath,
    $generatedTemplatePath,
    (Join-Path $repoRoot 'README.md')
) + @(
    $requiredKqlFiles | ForEach-Object { Join-Path $kqlDirectory $_ }
) + $newDocs
$newContent = $newFilePaths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }
$newContentText = $newContent -join "`n"
Assert-NotMatches -Source $newContentText -Pattern '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----' -Case 'No private key'
Assert-NotMatches -Source $newContentText -Pattern '(?i)\b(?:ghp|github_pat|azd)_[A-Za-z0-9_]{20,}\b' -Case 'No access token'
Assert-NotMatches -Source $newContentText -Pattern '(?i)(?:clientSecret|password)\s*[:=]\s*[''"][^$][^''"]{8,}[''"]' -Case 'No embedded credential'
Assert-NotMatches -Source $newContentText -Pattern '(?i)[?&]sig=[A-Za-z0-9%/+_-]{12,}' -Case 'No SAS signature'

foreach ($docPath in $newDocs) {
    $doc = Get-Content -LiteralPath $docPath -Raw
    Assert-Contains -Source $doc -Expected $requiredDisclaimer -Case "Visible disclaimer: $docPath"
}
$documentationText = $newDocs |
    ForEach-Object { Get-Content -LiteralPath $_ -Raw } |
    Join-String -Separator "`n"
foreach ($documentedBaseline in @(
        'la-start-arcbox-client',
        'Romance Standard Time',
        'shutdown-computevm-ArcBox-Client',
        '18:00 UTC',
        '07:30 UTC',
        'InsightsMetrics',
        'cero receptores',
        'ninguna fila en `Event`, `SecurityEvent` o `Perf`',
        '4,38 % / 11,51 %',
        '9,71 % / 19,32 %',
        'no son umbrales de alerta',
        'Perf` permanece vacío por diseño',
        '174 000 filas',
        'No notifica al SRE Agent'
    )) {
    Assert-Contains -Source $documentationText -Expected $documentedBaseline -Case 'Audited ArcBox baseline documentation'
}
$madridTimeZoneId = if ($IsWindows) { 'Romance Standard Time' } else { 'Europe/Madrid' }
$madridTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById($madridTimeZoneId)
$winterReportTime = [TimeZoneInfo]::ConvertTime(
    [DateTimeOffset]::Parse('2026-01-15T07:30:00Z'),
    $madridTimeZone
)
$summerReportTime = [TimeZoneInfo]::ConvertTime(
    [DateTimeOffset]::Parse('2026-07-15T07:30:00Z'),
    $madridTimeZone
)
Assert-True `
    -Condition ($winterReportTime.Hour -eq 8 -and $winterReportTime.Minute -eq 30) `
    -Case 'Weekday report follows winter startup grace'
Assert-True `
    -Condition ($summerReportTime.Hour -eq 9 -and $summerReportTime.Minute -eq 30) `
    -Case 'Weekday report follows summer startup grace'

Write-Host 'Arc identity infrastructure contract passed.'
