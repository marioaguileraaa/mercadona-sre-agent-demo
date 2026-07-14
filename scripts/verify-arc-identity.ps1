#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $TenantId = '9b1d3cd8-5db7-4564-905d-4d2eba7b66d5',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $SreResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $Location = 'westeurope',
    [string] $WorkspaceName = 'law-arcbox-demo-001',
    [string] $ActionGroupName = 'ag-mercadona-sre-demo',
    [string] $AgentName = 'sre-agent-mercadona-v1',
    [string] $SreIdentityName = 'id-mercadona-sre-v1',
    [string[]] $MachineNames = @('ArcBox-Win2K22', 'ArcBox-Win2K25'),
    [string] $DataCollectionRuleName = 'dcr-arcbox-identity-ops',
    [string] $AssociationName = 'assoc-arcbox-identity-ops',
    [string] $ExistingVmInsightsDataCollectionRuleName = 'MSVMI-ama-vmi-default-dcr',
    [string] $TokenFailureAlertName = 'alert-arcbox-identity-token-failure-burst',
    [string] $DataFreshnessAlertName = 'alert-arcbox-identity-data-freshness',
    [ValidateRange(5, 60)]
    [int] $MaximumIngestionAgeMinutes = 15,
    [ValidateRange(60, 1800)]
    [int] $IngestionTimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ArcIdentity.Common.ps1"

$readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
$monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
$logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
$previewApiVersion = '2025-05-01-preview'

Assert-ArcIdentityAzureContext `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupNames @($ArcResourceGroupName, $SreResourceGroupName)

$null = Get-ArcIdentityTargetMachines `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ArcResourceGroupName `
    -Location $Location `
    -MachineNames $MachineNames
foreach ($machineName in $MachineNames) {
    $null = Assert-ArcIdentityAmaExtension `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $machineName
}

$workspace = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'monitor', 'log-analytics', 'workspace', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ArcResourceGroupName,
        '--workspace-name', $WorkspaceName,
        '--output', 'json'
    ) `
    -FailureMessage "Unable to read Log Analytics workspace '$WorkspaceName'."
$workspaceResourceId = [string] $workspace.id
$workspaceCustomerId = [string] $workspace.customerId
if ([string]::IsNullOrWhiteSpace($workspaceCustomerId)) {
    throw "Workspace '$WorkspaceName' did not expose a customerId."
}

$dcrResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$DataCollectionRuleName"
$dcr = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'rest',
        '--method', 'get',
        '--url', "https://management.azure.com${dcrResourceId}?api-version=2024-03-11",
        '--output', 'json'
    ) `
    -FailureMessage "Unable to read DCR '$DataCollectionRuleName'."
$dcrProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $dcr -PropertyName 'properties'
if ($null -eq $dcrProperties) {
    $dcrProperties = $dcr
}
$dcrDataSources = Get-ArcIdentityOptionalPropertyValue -InputObject $dcrProperties -PropertyName 'dataSources'
$windowsEventLogs = @(
    Get-ArcIdentityOptionalPropertyValue -InputObject $dcrDataSources -PropertyName 'windowsEventLogs'
)
$performanceCounters = @(
    Get-ArcIdentityOptionalPropertyValue -InputObject $dcrDataSources -PropertyName 'performanceCounters'
)
if ($windowsEventLogs.Count -ne 1 -or $performanceCounters.Count -ne 0) {
    throw 'The dedicated DCR must contain exactly one Windows event source and no duplicate performance-counter source.'
}
$xPathQueries = @($windowsEventLogs[0].xPathQueries)
foreach ($requiredXPathFragment in @(
        "Provider[@Name='Mercadona.IdentityOps']",
        'EventID=4101',
        'EventID=4102',
        'System!*[System[(Level=1 or Level=2 or Level=3)]]',
        "Provider[@Name!='Mercadona.IdentityOps']"
    )) {
    if ($null -eq ($xPathQueries | Where-Object { $_ -like "*$requiredXPathFragment*" } | Select-Object -First 1)) {
        throw "The dedicated DCR is missing XPath contract '$requiredXPathFragment'."
    }
}
if ($xPathQueries | Where-Object { $_ -match '^(?i)Security!' }) {
    throw 'The synthetic identity DCR must not collect the broad Windows Security log.'
}

$dcrDataFlows = @(
    Get-ArcIdentityOptionalPropertyValue -InputObject $dcrProperties -PropertyName 'dataFlows'
)
$eventStreams = @(
    Get-ArcIdentityOptionalPropertyValue -InputObject $dcrDataFlows[0] -PropertyName 'streams'
)
if ($dcrDataFlows.Count -ne 1 -or
    $eventStreams.Count -ne 1 -or
    $eventStreams[0] -ne 'Microsoft-Event') {
    throw 'The dedicated DCR must route only Microsoft-Event; performance remains in the existing VM Insights DCR.'
}

$destinations = Get-ArcIdentityOptionalPropertyValue -InputObject $dcrProperties -PropertyName 'destinations'
$logAnalyticsDestinations = @(
    Get-ArcIdentityOptionalPropertyValue -InputObject $destinations -PropertyName 'logAnalytics'
)
if ($logAnalyticsDestinations.Count -ne 1 -or
    -not [string]::Equals(
        [string] $logAnalyticsDestinations[0].workspaceResourceId,
        $workspaceResourceId,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The dedicated DCR does not target only the expected ArcBox workspace.'
}

$allMachines = @(
    Get-ArcIdentityResponseItems -Response (
        Invoke-ArcIdentityAzJson `
            -Arguments @(
                'connectedmachine', 'list',
                '--subscription', $SubscriptionId,
                '--resource-group', $ArcResourceGroupName,
                '--output', 'json'
            ) `
            -FailureMessage "Unable to list Arc machines in '$ArcResourceGroupName'."
    )
)
$dedicatedAssociationMachines = [System.Collections.Generic.List[string]]::new()
foreach ($machine in $allMachines) {
    $machineName = [string] $machine.name
    $associations = @(Get-ArcIdentityDcrAssociations `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ArcResourceGroupName `
            -MachineName $machineName)
    $dedicatedAssociations = @(
        $associations | Where-Object {
            $_.name -eq $AssociationName -or
            [string]::Equals(
                [string] $_.properties.dataCollectionRuleId,
                $dcrResourceId,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    )

    if ($machineName -in $MachineNames) {
        $vmInsightsAssociations = @(
            $associations | Where-Object {
                $associationProperties = Get-ArcIdentityOptionalPropertyValue `
                    -InputObject $_ `
                    -PropertyName 'properties'
                $associatedDcrId = [string] (
                    Get-ArcIdentityOptionalPropertyValue `
                        -InputObject $associationProperties `
                        -PropertyName 'dataCollectionRuleId'
                )
                $associatedDcrId.EndsWith(
                    "/$ExistingVmInsightsDataCollectionRuleName",
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
        )
        if ($vmInsightsAssociations.Count -ne 1) {
            throw "Target '$machineName' does not retain exactly one association to existing VM Insights DCR '$ExistingVmInsightsDataCollectionRuleName'."
        }
        if ($dedicatedAssociations.Count -ne 1 -or
            $dedicatedAssociations[0].name -ne $AssociationName -or
            -not [string]::Equals(
                [string] $dedicatedAssociations[0].properties.dataCollectionRuleId,
                $dcrResourceId,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Target Arc machine '$machineName' does not have exactly the expected dedicated DCR association."
        }
        $dedicatedAssociationMachines.Add($machineName)
    } elseif ($dedicatedAssociations.Count -ne 0) {
        throw "Non-target Arc machine '$machineName' unexpectedly has the dedicated identity DCR association."
    }

    $preservedAssociationCount = $associations.Count - $dedicatedAssociations.Count
    Write-Host "machine=$machineName dedicatedAssociations=$($dedicatedAssociations.Count) preservedOtherAssociations=$preservedAssociationCount"
}
if ($dedicatedAssociationMachines.Count -ne 2) {
    throw 'The dedicated DCR must be associated with exactly the two requested Arc machines.'
}

$targetResourceIds = @(
    $MachineNames | ForEach-Object {
        (Get-ArcIdentityMachineResourceId `
                -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ArcResourceGroupName `
                -MachineName $_).ToLowerInvariant()
    }
)
$targetResourceIdsJson = $targetResourceIds | ConvertTo-Json -Compress
$freshnessLookbackMinutes = $MaximumIngestionAgeMinutes + 5
$freshnessQuery = @"
let TargetResourceIds = dynamic($targetResourceIdsJson);
let Expected =
  print ResourceIds=TargetResourceIds
  | mv-expand ResourceId=ResourceIds to typeof(string)
  | project ResourceId=tolower(ResourceId);
let LatestHeartbeat =
  Heartbeat
  | where TimeGenerated >= ago(${freshnessLookbackMinutes}m)
  | where set_has_element(TargetResourceIds, tolower(_ResourceId))
  | summarize LastHeartbeat=max(TimeGenerated) by ResourceId=tolower(_ResourceId);
let LatestInsightsMetrics =
  InsightsMetrics
  | where TimeGenerated >= ago(${freshnessLookbackMinutes}m)
  | where set_has_element(TargetResourceIds, tolower(_ResourceId))
  | where Namespace == "Processor" and Name == "UtilizationPercentage"
  | summarize LastInsightsMetrics=max(TimeGenerated) by ResourceId=tolower(_ResourceId);
Expected
| join kind=leftouter LatestHeartbeat on ResourceId
| join kind=leftouter LatestInsightsMetrics on ResourceId
| project ResourceId,
    HeartbeatFresh=isnotnull(LastHeartbeat) and LastHeartbeat >= ago(${MaximumIngestionAgeMinutes}m),
    InsightsMetricsFresh=isnotnull(LastInsightsMetrics) and LastInsightsMetrics >= ago(${MaximumIngestionAgeMinutes}m),
    LastHeartbeat,
    LastInsightsMetrics
"@
$ingestionDeadline = (Get-Date).AddSeconds($IngestionTimeoutSeconds)
$freshnessRows = @()
do {
    $freshnessRows = @(
        Get-ArcIdentityResponseItems -Response (
            Invoke-ArcIdentityLogAnalyticsQuery `
                -SubscriptionId $SubscriptionId `
                -WorkspaceCustomerId $workspaceCustomerId `
                -Query $freshnessQuery
        ) -PropertyNames @('tables', 'value')
    )
    $allFresh = $freshnessRows.Count -eq 2 -and
        @($freshnessRows | Where-Object {
                $_.HeartbeatFresh -ne $true -or $_.InsightsMetricsFresh -ne $true
            }).Count -eq 0
    if ($allFresh) {
        break
    }
    Start-Sleep -Seconds 30
} while ((Get-Date) -lt $ingestionDeadline)
if (-not $allFresh) {
    throw "Heartbeat and existing InsightsMetrics ingestion did not become fresh for both target machines within $IngestionTimeoutSeconds seconds."
}

function Assert-ArcIdentityAlertRule {
    param(
        [Parameter(Mandatory)]
        [string] $AlertName,
        [Parameter(Mandatory)]
        [string[]] $RequiredQueryFragments,
        [Parameter(Mandatory)]
        [string] $ExpectedActionGroupResourceId,
        [Parameter(Mandatory)]
        [int] $ExpectedThreshold,
        [Parameter(Mandatory)]
        [string] $ExpectedEvaluationFrequency,
        [Parameter(Mandatory)]
        [string] $ExpectedWindowSize,
        [AllowNull()]
        [string] $ExpectedOverrideQueryTimeRange
    )

    $alert = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'rest',
            '--method', 'get',
            '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName/providers/Microsoft.Insights/scheduledQueryRules/${AlertName}?api-version=2023-12-01",
            '--output', 'json'
        ) `
        -FailureMessage "Unable to read scheduled-query alert '$AlertName'."
    $properties = Get-ArcIdentityOptionalPropertyValue -InputObject $alert -PropertyName 'properties'
    if ($null -eq $properties) {
        $properties = $alert
    }
    if ($properties.enabled -ne $true -or
        [int] $properties.severity -ne 2) {
        throw "Alert '$AlertName' must remain enabled and Sev2."
    }
    $autoMitigate = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $properties `
        -PropertyName 'autoMitigate'
    if ($null -ne $autoMitigate -and $autoMitigate -ne $true) {
        throw "Alert '$AlertName' returned autoMitigate='$autoMitigate', which conflicts with deterministic resolveConfiguration auto-resolution."
    }
    $provisioningState = Get-ArcIdentityFirstPropertyValue `
        -InputObjects @($properties, $alert) `
        -PropertyNames @('provisioningState')
    if ($null -ne $provisioningState -and $provisioningState -ne 'Succeeded') {
        throw "Alert '$AlertName' provisioning state is '$provisioningState'."
    }
    if (@($properties.scopes).Count -ne 1 -or
        -not [string]::Equals(
            [string] $properties.scopes[0],
            $workspaceResourceId,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Alert '$AlertName' is not scoped to the exact ArcBox workspace."
    }
    if (@($properties.actions.actionGroups).Count -ne 1 -or
        -not [string]::Equals(
            [string] $properties.actions.actionGroups[0],
            $ExpectedActionGroupResourceId,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Alert '$AlertName' does not reuse the expected action group."
    }
    $resolveConfiguration = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $properties `
        -PropertyName 'resolveConfiguration'
    if ($properties.evaluationFrequency -ne $ExpectedEvaluationFrequency -or
        $properties.windowSize -ne $ExpectedWindowSize -or
        (Get-ArcIdentityOptionalPropertyValue -InputObject $resolveConfiguration -PropertyName 'autoResolved') -ne $true -or
        (Get-ArcIdentityOptionalPropertyValue -InputObject $resolveConfiguration -PropertyName 'timeToResolve') -ne 'PT10M') {
        throw "Alert '$AlertName' does not preserve its deterministic evaluation and resolution timing."
    }
    if ($null -ne $ExpectedOverrideQueryTimeRange -and
        $properties.overrideQueryTimeRange -ne $ExpectedOverrideQueryTimeRange) {
        throw "Alert '$AlertName' does not preserve overrideQueryTimeRange '$ExpectedOverrideQueryTimeRange'."
    }

    $criteria = @($properties.criteria.allOf)
    if ($criteria.Count -ne 1 -or
        $criteria[0].timeAggregation -ne 'Count' -or
        $criteria[0].operator -ne 'GreaterThanOrEqual' -or
        [int] $criteria[0].threshold -ne $ExpectedThreshold -or
        [int] $criteria[0].failingPeriods.numberOfEvaluationPeriods -ne 1 -or
        [int] $criteria[0].failingPeriods.minFailingPeriodsToAlert -ne 1) {
        throw "Alert '$AlertName' does not preserve the exact static threshold contract."
    }
    $query = [string] $criteria[0].query
    foreach ($requiredQueryFragment in $RequiredQueryFragments) {
        if (-not $query.Contains($requiredQueryFragment, [StringComparison]::Ordinal)) {
            throw "Alert '$AlertName' query is missing '$requiredQueryFragment'."
        }
    }
    if ($query -match '\|\s*summarize\s+(?:EventCount|MissingOrStaleSignals)=') {
        throw "Alert '$AlertName' would count an aggregate result row instead of matching records."
    }
    Write-Host "alert=$AlertName enabled=true severity=Sev2 autoResolve=true"
}

$actionGroupResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$SreResourceGroupName/providers/Microsoft.Insights/actionGroups/$ActionGroupName"
Assert-ArcIdentityAlertRule `
    -AlertName $TokenFailureAlertName `
    -RequiredQueryFragments @('Mercadona.IdentityOps', 'demoSynthetic', 'EventID == 4101', 'project TimeGenerated, _ResourceId') `
    -ExpectedActionGroupResourceId $actionGroupResourceId `
    -ExpectedThreshold 8 `
    -ExpectedEvaluationFrequency 'PT1M' `
    -ExpectedWindowSize 'PT5M' `
    -ExpectedOverrideQueryTimeRange $null
Assert-ArcIdentityAlertRule `
    -AlertName $DataFreshnessAlertName `
    -RequiredQueryFragments @('Heartbeat', 'InsightsMetrics', 'UtilizationPercentage', 'ago(10m)', 'project ResourceId, Signal', 'datetime_utc_to_local(CurrentUtc, "Europe/Madrid")', 'MadridMinuteOfDay >= 500', 'datetime_part("Hour", CurrentUtc) < 18') `
    -ExpectedActionGroupResourceId $actionGroupResourceId `
    -ExpectedThreshold 1 `
    -ExpectedEvaluationFrequency 'PT5M' `
    -ExpectedWindowSize 'PT5M' `
    -ExpectedOverrideQueryTimeRange 'PT30M'

$sreIdentity = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'identity', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $SreResourceGroupName,
        '--name', $SreIdentityName,
        '--output', 'json'
    ) `
    -FailureMessage "Unable to read SRE managed identity '$SreIdentityName'."
$srePrincipalId = [string] $sreIdentity.principalId
$sreIdentityResourceId = [string] $sreIdentity.id
$arcResourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName"
$sreResourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$SreResourceGroupName"
foreach ($requiredRole in @(
        @{ Role = $readerRoleId; Scope = $arcResourceGroupId },
        @{ Role = $monitoringReaderRoleId; Scope = $arcResourceGroupId },
        @{ Role = $logAnalyticsReaderRoleId; Scope = $workspaceResourceId }
    )) {
    if (-not (Test-ArcIdentityRoleAssignment `
            -SubscriptionId $SubscriptionId `
            -PrincipalId $srePrincipalId `
            -RoleDefinitionId $requiredRole.Role `
            -Scope $requiredRole.Scope)) {
        throw "SRE identity is missing role '$($requiredRole.Role)' at '$($requiredRole.Scope)'."
    }
}

$agentResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$SreResourceGroupName/providers/Microsoft.App/agents/$AgentName"
$agent = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'rest',
        '--method', 'get',
        '--url', "https://management.azure.com${agentResourceId}?api-version=$previewApiVersion",
        '--output', 'json'
    ) `
    -FailureMessage "Unable to read SRE Agent '$AgentName'."
$agentProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $agent -PropertyName 'properties'
$actionConfiguration = Get-ArcIdentityOptionalPropertyValue `
    -InputObject $agentProperties `
    -PropertyName 'actionConfiguration'
if ((Get-ArcIdentityOptionalPropertyValue `
            -InputObject $actionConfiguration `
            -PropertyName 'mode') -ne 'Review' -or
    (Get-ArcIdentityOptionalPropertyValue `
            -InputObject $actionConfiguration `
            -PropertyName 'accessLevel') -ne 'Low') {
    throw 'Azure SRE Agent must remain in Review mode with Low access.'
}
$knowledgeGraphConfiguration = Get-ArcIdentityOptionalPropertyValue `
    -InputObject $agentProperties `
    -PropertyName 'knowledgeGraphConfiguration'
$managedResources = @(
    Get-ArcIdentityOptionalPropertyValue `
        -InputObject $knowledgeGraphConfiguration `
        -PropertyName 'managedResources'
)
foreach ($requiredManagedResource in @($sreResourceGroupId, $arcResourceGroupId)) {
    if ($null -eq ($managedResources | Where-Object {
                [string]::Equals(
                    [string] $_,
                    $requiredManagedResource,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } | Select-Object -First 1)) {
        throw "Azure SRE Agent managed resources are missing '$requiredManagedResource'."
    }
}

$connector = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'rest',
        '--method', 'get',
        '--url', "https://management.azure.com${agentResourceId}/connectors/arcbox-log-analytics?api-version=$previewApiVersion",
        '--output', 'json'
    ) `
    -FailureMessage 'Unable to read the ArcBox Log Analytics SRE Agent connector.'
$connectorProperties = Get-ArcIdentityOptionalPropertyValue `
    -InputObject $connector `
    -PropertyName 'properties'
if (-not [string]::Equals(
        [string] (
            Get-ArcIdentityOptionalPropertyValue `
                -InputObject $connectorProperties `
                -PropertyName 'dataSource'
        ),
        $workspaceResourceId,
        [StringComparison]::OrdinalIgnoreCase
    ) -or
    -not [string]::Equals(
        [string] (
            Get-ArcIdentityOptionalPropertyValue `
                -InputObject $connectorProperties `
                -PropertyName 'identity'
        ),
        $sreIdentityResourceId,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The ArcBox Log Analytics connector is not scoped to the expected workspace and UAMI.'
}

try {
    $null = Connect-ArcIdentitySreAgentApi `
        -SubscriptionId $SubscriptionId `
        -AgentResourceId $agentResourceId `
        -ApiVersion $previewApiVersion
    $subagent = Invoke-ArcIdentitySreAgentApi `
        -Method Get `
        -Path '/api/v2/extendedAgent/agents/identity-infrastructure-analyzer' `
        -Body $null
    $skill = Invoke-ArcIdentitySreAgentApi `
        -Method Get `
        -Path '/api/v2/extendedAgent/skills/identity-infrastructure-operations' `
        -Body $null
    $filter = Invoke-ArcIdentitySreAgentApi `
        -Method Get `
        -Path '/api/v2/extendedAgent/incidentFilters/identity-infrastructure-sev2' `
        -Body $null
    $scheduledTask = Invoke-ArcIdentitySreAgentApi `
        -Method Get `
        -Path '/api/v2/extendedAgent/scheduledtasks/identity-infrastructure-weekday-report' `
        -Body $null

    $subagentProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $subagent -PropertyName 'properties'
    $subagentTools = @(
        Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($subagentProperties, $subagent) `
            -PropertyNames @('tools')
    )
    if ('RunAzCliWriteCommands' -in $subagentTools -or
        'QueryLogAnalyticsByWorkspaceId' -notin $subagentTools -or
        'RunAzCliReadCommands' -notin $subagentTools) {
        throw 'The identity subagent tools are not read-only and Log Analytics focused.'
    }

    $skillProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $skill -PropertyName 'properties'
    $skillContent = [string] (
        Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($skillProperties, $skill) `
            -PropertyNames @('skillContent')
    )
    if (-not $skillContent.Contains('demoSynthetic=true', [StringComparison]::Ordinal) -or
        -not $skillContent.Contains('Microsoft Sentinel', [StringComparison]::Ordinal)) {
        throw 'The identity skill does not preserve the synthetic boundary and SOC handoff.'
    }

    $filterProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $filter -PropertyName 'properties'
    $filterMode = Get-ArcIdentityFirstPropertyValue `
        -InputObjects @($filterProperties, $filter) `
        -PropertyNames @('agentMode')
    $filterAgent = Get-ArcIdentityFirstPropertyValue `
        -InputObjects @($filterProperties, $filter) `
        -PropertyNames @('handlingAgent')
    $filterTitleContains = Get-ArcIdentityFirstPropertyValue `
        -InputObjects @($filterProperties, $filter) `
        -PropertyNames @('titleContains')
    $filterPriorities = @(
        Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($filterProperties, $filter) `
            -PropertyNames @('priorities')
    )
    if ($filterMode -ne 'Review' -or
        $filterAgent -ne 'identity-infrastructure-analyzer' -or
        $filterTitleContains -ne 'ArcBox IdentityOps' -or
        'Sev2' -notin $filterPriorities) {
        throw 'The identity incident filter is not Sev2, Review, and routed to the dedicated subagent.'
    }

    $scheduledTaskProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $scheduledTask -PropertyName 'properties'
    $scheduledTaskMode = Get-ArcIdentityFirstPropertyValue `
        -InputObjects @($scheduledTaskProperties, $scheduledTask) `
        -PropertyNames @('agentMode')
    $scheduledTaskCron = Get-ArcIdentityFirstPropertyValue `
        -InputObjects @($scheduledTaskProperties, $scheduledTask) `
        -PropertyNames @('cronExpression')
    $scheduledTaskEnabled = Get-ArcIdentityFirstPropertyValue `
        -InputObjects @($scheduledTaskProperties, $scheduledTask) `
        -PropertyNames @('isEnabled')
    if ($scheduledTaskMode -ne 'Review' -or
        $scheduledTaskCron -ne '30 7 * * 1-5' -or
        $scheduledTaskEnabled -ne $true) {
        throw 'The identity operational report must remain enabled, weekday-only, and Review mode.'
    }
} finally {
    Disconnect-ArcIdentitySreAgentApi
}

Write-Host 'Arc identity extension verified: exact DCR scope, AMA, fresh LAW data, Sev2 alerts, least privilege, and SRE Agent Review/Low.'
