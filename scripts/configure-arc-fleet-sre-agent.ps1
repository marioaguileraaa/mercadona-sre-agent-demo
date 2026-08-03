#requires -Version 7.2
<#
    Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices,
    carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.

    Adds the additive Arc fleet observability configuration to the existing Azure SRE Agent: one
    read-only skill, one subagent, one Sev2 incident filter and two Review scheduled reports.
    The agent must already be Review/Low and this script never broadens that posture.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $TenantId = '9b1d3cd8-5db7-4564-905d-4d2eba7b66d5',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $SreResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $WorkspaceName = 'law-arcbox-demo-001',
    [string] $AgentName = 'sre-agent-mercadona-v1',
    [string] $SreIdentityName = 'id-mercadona-sre-v1',
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ArcIdentity.Common.ps1"
. "$PSScriptRoot\ArcFleet.Common.ps1"

$thresholds = Get-ArcFleetThresholdContract
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$skillAdditionalFilePaths = @(
    'kql/arc-fleet/fleet-inventory.arg.kql',
    'kql/arc-fleet/agent-extension-health.arg.kql',
    'kql/arc-fleet/fleet-heartbeat-freshness.kql',
    'kql/arc-fleet/cpu-saturation.kql',
    'kql/arc-fleet/memory-pressure.kql',
    'kql/arc-fleet/disk-capacity.kql',
    'kql/arc-fleet/fleet-performance-summary.kql',
    'kql/arc-fleet/resource-pressure-timeline.kql',
    'kql/arc-fleet/change-inventory.kql',
    'kql/arc-fleet/capacity-trend.kql'
)
$skillAdditionalFiles = @(
    Get-ArcIdentitySkillAdditionalFiles `
        -RepositoryRoot $repoRoot `
        -RelativePaths $skillAdditionalFilePaths
)

function Assert-ArcFleetOwnedSreResource {
    param(
        [AllowNull()]
        [object] $ExistingResource,
        [Parameter(Mandatory)]
        [string] $ExpectedName,
        [Parameter(Mandatory)]
        [string] $ExpectedType
    )

    if ($null -eq $ExistingResource) {
        return
    }

    $properties = Get-ArcIdentityOptionalPropertyValue -InputObject $ExistingResource -PropertyName 'properties'
    $actualName = [string] (
        Get-ArcIdentityFirstPropertyValue -InputObjects @($ExistingResource, $properties) -PropertyNames @('name')
    )
    $actualType = [string] (
        Get-ArcIdentityFirstPropertyValue -InputObjects @($ExistingResource, $properties) -PropertyNames @('type')
    )
    $tags = @(
        Get-ArcIdentityFirstPropertyValue -InputObjects @($ExistingResource, $properties) -PropertyNames @('tags')
    )
    if ((-not [string]::IsNullOrWhiteSpace($actualName) -and
            -not [string]::Equals($actualName, $ExpectedName, [StringComparison]::Ordinal)) -or
        (-not [string]::IsNullOrWhiteSpace($actualType) -and
            -not [string]::Equals($actualType, $ExpectedType, [StringComparison]::Ordinal)) -or
        'synthetic-identity' -notin $tags -or
        'azure-arc' -notin $tags -or
        'arc-fleet' -notin $tags) {
        throw "SRE Agent resource '$ExpectedName' already exists without the dedicated Arc fleet ownership contract; refusing to overwrite it."
    }
}

function Assert-ArcFleetSreAgentSafety {
    param(
        [Parameter(Mandatory)]
        [object] $Agent,
        [Parameter(Mandatory)]
        [string] $ExpectedIdentity
    )

    $agentProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $Agent -PropertyName 'properties'
    $actionConfiguration = Get-ArcIdentityOptionalPropertyValue -InputObject $agentProperties -PropertyName 'actionConfiguration'
    if ((Get-ArcIdentityOptionalPropertyValue -InputObject $actionConfiguration -PropertyName 'mode') -ne 'Review' -or
        (Get-ArcIdentityOptionalPropertyValue -InputObject $actionConfiguration -PropertyName 'accessLevel') -ne 'Low') {
        throw 'Azure SRE Agent must already be configured as Review/Low; this script will not broaden it.'
    }
    if (-not [string]::Equals(
            [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $actionConfiguration -PropertyName 'identity'),
            $ExpectedIdentity,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Azure SRE Agent action identity is not the expected existing UAMI.'
    }
}

function Assert-ArcFleetSreExtensionResourceCollisions {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $AgentResourceId,
        [Parameter(Mandatory)]
        [string] $ApiVersion,
        [Parameter(Mandatory)]
        [object[]] $ResourceContracts
    )

    try {
        $null = Connect-ArcIdentitySreAgentApi `
            -SubscriptionId $SubscriptionId `
            -AgentResourceId $AgentResourceId `
            -ApiVersion $ApiVersion
        foreach ($resourceContract in $ResourceContracts) {
            $existingResource = Invoke-ArcIdentitySreAgentApi `
                -Method Get `
                -Path $resourceContract.Path `
                -Body $null `
                -AllowNotFound
            Assert-ArcFleetOwnedSreResource `
                -ExistingResource $existingResource `
                -ExpectedName $resourceContract.Name `
                -ExpectedType $resourceContract.Type
        }
    } finally {
        Disconnect-ArcIdentitySreAgentApi
    }
}

$readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
$monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
$logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
$previewApiVersion = '2025-05-01-preview'
$arcResourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName"
$sreResourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$SreResourceGroupName"
$agentResourceId = "$sreResourceGroupId/providers/Microsoft.App/agents/$AgentName"

Assert-ArcIdentityAzureContext `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupNames @($ArcResourceGroupName, $SreResourceGroupName)

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
if ([string]::IsNullOrWhiteSpace($srePrincipalId) -or
    [string]::IsNullOrWhiteSpace($sreIdentityResourceId)) {
    throw "Managed identity '$SreIdentityName' did not expose principal and resource IDs."
}

$agent = Wait-ArcIdentitySreAgentProvisioningSucceeded `
    -SubscriptionId $SubscriptionId `
    -AgentResourceId $agentResourceId `
    -ApiVersion $previewApiVersion
Assert-ArcFleetSreAgentSafety -Agent $agent -ExpectedIdentity $sreIdentityResourceId
$agentProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $agent -PropertyName 'properties'

$knowledgeGraphConfiguration = Get-ArcIdentityOptionalPropertyValue `
    -InputObject $agentProperties `
    -PropertyName 'knowledgeGraphConfiguration'
$knowledgeGraphPlan = Get-ArcIdentityKnowledgeGraphConfigurationPlan `
    -ExistingConfiguration $knowledgeGraphConfiguration `
    -ExpectedIdentity $sreIdentityResourceId `
    -RequiredManagedResources @($sreResourceGroupId, $arcResourceGroupId)
if ($knowledgeGraphPlan.RequiresPatch) {
    throw 'The ArcBox resource group is not yet in the SRE Agent knowledge graph. Run configure-arc-identity-sre-agent.ps1 -Apply first; this additive script never rewrites the knowledge graph.'
}

$connectorName = 'arcbox-log-analytics'
$connectorList = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'rest',
        '--method', 'get',
        '--url', "https://management.azure.com${agentResourceId}/connectors?api-version=$previewApiVersion",
        '--output', 'json'
    ) `
    -FailureMessage 'Unable to list existing SRE Agent ARM connectors.'
$existingConnector = @(Get-ArcIdentityResponseItems -Response $connectorList) |
    Where-Object {
        $candidateName = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $_ -PropertyName 'name')
        [string]::Equals([string] (($candidateName -split '/')[-1]), $connectorName, [StringComparison]::OrdinalIgnoreCase)
    } |
    Select-Object -First 1
if ($null -eq $existingConnector) {
    throw "The '$connectorName' connector does not exist yet. Run configure-arc-identity-sre-agent.ps1 -Apply first; this additive script never creates connectors."
}
Assert-ArcIdentityLogAnalyticsConnector `
    -Connector $existingConnector `
    -ExpectedName $connectorName `
    -ExpectedWorkspaceResourceId $workspaceResourceId `
    -ExpectedWorkspaceName $WorkspaceName `
    -ExpectedIdentity $sreIdentityResourceId

$skillName = 'arc-fleet-observability'
$subagentName = 'arc-fleet-analyzer'
$incidentFilterName = 'arc-fleet-performance-sev2'
$weekdayReportName = 'arc-fleet-weekday-health-report'
$weeklyCapacityReportName = 'arc-fleet-weekly-capacity-report'
$ownershipTags = @('mercadona-demo', 'synthetic-identity', 'azure-arc', 'arc-fleet')

$sreExtensionResources = @(
    @{ Name = $skillName; Type = 'Skill'; Path = "/api/v2/extendedAgent/skills/$skillName" },
    @{ Name = $subagentName; Type = 'ExtendedAgent'; Path = "/api/v2/extendedAgent/agents/$subagentName" },
    @{ Name = $incidentFilterName; Type = 'IncidentFilter'; Path = "/api/v2/extendedAgent/incidentFilters/$incidentFilterName" },
    @{ Name = $weekdayReportName; Type = 'ScheduledTask'; Path = "/api/v2/extendedAgent/scheduledtasks/$weekdayReportName" },
    @{ Name = $weeklyCapacityReportName; Type = 'ScheduledTask'; Path = "/api/v2/extendedAgent/scheduledtasks/$weeklyCapacityReportName" }
)

Write-Host 'Planned additive Arc fleet SRE Agent configuration:'
Write-Host "- Reader and Monitoring Reader at $arcResourceGroupId"
Write-Host "- Log Analytics Reader at $workspaceResourceId"
Write-Host "- Skill '$skillName' with $($skillAdditionalFiles.Count) reviewed aggregate KQL assets"
Write-Host "- Subagent '$subagentName' and Sev2 filter '$incidentFilterName' matching '$($thresholds.AlertDisplayNamePrefix)'"
Write-Host "- Scheduled Review reports '$weekdayReportName' and '$weeklyCapacityReportName'"
Write-Host '- No Autonomous mode, High access, remediation, receiver, connector or knowledge-graph change'
if (-not $Apply) {
    Assert-ArcFleetSreExtensionResourceCollisions `
        -SubscriptionId $SubscriptionId `
        -AgentResourceId $agentResourceId `
        -ApiVersion $previewApiVersion `
        -ResourceContracts $sreExtensionResources
    Write-Host 'No Azure configuration was changed. Rerun with -Apply after reviewing this plan.'
    return
}
if (-not $PSCmdlet.ShouldProcess(
        $agentResourceId,
        'Add exact-scope read roles and idempotent Arc fleet observability SRE Agent configuration'
    )) {
    return
}

Ensure-ArcIdentityRoleAssignment `
    -SubscriptionId $SubscriptionId `
    -PrincipalId $srePrincipalId `
    -RoleDefinitionId $readerRoleId `
    -Scope $arcResourceGroupId
Ensure-ArcIdentityRoleAssignment `
    -SubscriptionId $SubscriptionId `
    -PrincipalId $srePrincipalId `
    -RoleDefinitionId $monitoringReaderRoleId `
    -Scope $arcResourceGroupId
Ensure-ArcIdentityRoleAssignment `
    -SubscriptionId $SubscriptionId `
    -PrincipalId $srePrincipalId `
    -RoleDefinitionId $logAnalyticsReaderRoleId `
    -Scope $workspaceResourceId

Assert-ArcFleetSreExtensionResourceCollisions `
    -SubscriptionId $SubscriptionId `
    -AgentResourceId $agentResourceId `
    -ApiVersion $previewApiVersion `
    -ResourceContracts $sreExtensionResources

$skill = @{
    name = $skillName
    type = 'Skill'
    tags = $ownershipTags
    properties = @{
        name = $skillName
        description = 'Read-only Azure Arc fleet observability: inventory, agent posture, telemetry freshness, CPU, memory, disk, change tracking and capacity trends using aggregate KQL and exact Azure scopes.'
        tools = @(
            'RunAzCliReadCommands',
            'QueryLogAnalyticsByWorkspaceId',
            'SearchMemory'
        )
        skillContent = @"
Fictional technical SRE demo. Not an official Mercadona system. Every store, product, price, cart, order, correlation ID and metric in this scenario is synthetic and no claim is made about real operations.

Scope. Use only the existing Log Analytics workspace $WorkspaceName (customer ID $workspaceCustomerId) and the five Arc-enabled machines in ${ArcResourceGroupName}: ArcBox-Win2K22, ArcBox-Win2K25, ArcBox-SQL, Arcbox-Ubuntu-01 and Arcbox-Ubuntu-02. Join telemetry to resources on the lowercased _ResourceId because the Computer column casing does not always match the Arc resource name.

Demo role labels. ArcBox-Win2K22 is presented as adfs/adfs-01, ArcBox-Win2K25 as domain-controller/dc-01, ArcBox-SQL as identity-sql/sql-01, and both Ubuntu hosts as linux-edge/edge-01 and edge-02. These labels are presentation only. The machines do not run AD FS or AD DS, so never describe their telemetry as genuine federation or directory-service activity.

Signals. Performance comes from the pre-existing VM Insights rule MSVMI-ama-vmi-default-dcr and lands in InsightsMetrics at a 60 second sampling interval. CPU is Namespace Processor, Name UtilizationPercentage. Memory used percentage must be derived as 100 * (totalMemoryMb - AvailableMB) / totalMemoryMb, where totalMemoryMb comes from the InsightsMetrics tag vm.azm.ms/memorySizeMB; there is no direct memory-used counter. Disk uses Namespace LogicalDisk with the tag vm.azm.ms/mountId, and Linux pseudo-mounts beginning with /snap/, /sys/ or /run/ must always be excluded because a read-only squashfs mount permanently reports zero percent free. The Perf and SecurityEvent tables are intentionally empty; an empty result there is expected and is not an incident.

Thresholds. alert-arcbox-fleet-cpu-saturation is Sev2 and fires when a machine reports at least $($thresholds.MinimumBreachingSamples) samples at or above $($thresholds.CpuSaturationPercent) percent CPU inside a $($thresholds.WindowMinutes) minute window. alert-arcbox-fleet-memory-pressure is Sev2 and fires when a machine reports at least $($thresholds.MinimumBreachingSamples) samples at or above $($thresholds.MemoryPressurePercent) percent memory used inside the same window. Both thresholds were derived from a real seven-day baseline in which neither rule would have fired once, so a firing means genuinely anomalous sustained pressure rather than a normal peak.

Operating window. The ArcBox estate starts around 08:00 Europe/Madrid and is automatically shut down at 18:00 UTC. Absence of telemetry outside that window is expected and must never be reported as an incident or as a fleet outage.

Queries. Use the aggregate-only reviewed queries attached to this skill: fleet-inventory.arg.kql and agent-extension-health.arg.kql run against Azure Resource Graph; fleet-heartbeat-freshness.kql, cpu-saturation.kql, memory-pressure.kql, disk-capacity.kql, fleet-performance-summary.kql, resource-pressure-timeline.kql, change-inventory.kql and capacity-trend.kql run against the workspace. Change tracking is optional and must be reported as unavailable when the table has no data; never enable it autonomously.

Synthetic pressure marker. Application events from source Mercadona.FleetOps with event IDs 5101 and 5102 and demoSynthetic=true describe the bounded demo pressure injection, including its correlationId, mode, requested memory and CPU worker count. Treat them as the demo's own annotation, correlate them with the metric anomaly, and never present them as a real production fault.

Reporting. Report aggregate counts, percentiles, freshness timestamps and machine-level status. Never include user names, event-message samples, authentication material, secrets or raw RenderedDescription values. Remain read-only: do not install or upgrade extensions, do not change data collection rules, do not restart services, do not resize or reconfigure machines and do not run remediation. Every recommendation stays under human review, and any evidence of a genuine security incident is handed off to the SOC and Microsoft Sentinel.
"@
        additionalFiles = $skillAdditionalFiles
    }
}

$subagent = @{
    name = $subagentName
    type = 'ExtendedAgent'
    tags = $ownershipTags
    properties = @{
        instructions = @"
Fictional technical SRE demo. Investigate only the additive Azure Arc fleet observability scenario in $ArcResourceGroupName, scoped to the workspace $WorkspaceName and the five Arc-enabled machines ArcBox-Win2K22, ArcBox-Win2K25, ArcBox-SQL, Arcbox-Ubuntu-01 and Arcbox-Ubuntu-02.

When an ArcBox FleetOps Sev2 alert arrives, answer four questions in order. Which machines and demo roles are affected. How far the observed value is from the documented seven-day baseline, quoting the p95 for that machine. Whether the pressure is sustained or a normal peak, using the count of breaching 60 second samples inside the 15 minute window. What else changed at the same time, correlating extension provisioning state, Heartbeat and InsightsMetrics freshness, disk free space, change tracking and Mercadona.FleetOps events 5101 and 5102 with demoSynthetic=true.

Always state the baseline explicitly. Documented seven-day p95 values are: ArcBox-Win2K22 CPU 9.0 percent and memory 46.5 percent, ArcBox-Win2K25 CPU 16.6 percent and memory 60.5 percent, ArcBox-SQL CPU 11.3 percent and memory 59.6 percent, and both Ubuntu hosts CPU about 1.5 percent and memory about 19 percent. A sustained value above the alert threshold is therefore several times the normal load for that machine.

Use aggregate counts, percentiles, freshness timestamps and machine-level status only. Never expose user names, event messages, authentication data, secrets or raw message samples. Never claim these hosts run AD FS or AD DS; the adfs and domain-controller labels are presentation only. Treat the absence of telemetry outside 08:00 Europe/Madrid to 18:00 UTC as expected, and an empty Perf or SecurityEvent table as expected.

Recommendations must be concrete, ranked and reversible, and must remain proposals. Typical valid recommendations are: identify the top consuming process and hand it to the application owner, right-size the guest, review the memory or CPU quota of the workload, escalate any extension that is not in the Succeeded provisioning state to the platform team, and confirm free disk headroom before any change. Remain read-only. Do not install or upgrade extensions, change data collection rules, restart services, reconfigure or resize machines, or execute any remediation. Route suspected genuine security incidents to the SOC and Microsoft Sentinel.
"@
        handoffDescription = 'Investigates aggregate Azure Arc fleet health, saturation and capacity signals while keeping every recommendation read-only and under human review.'
        handoffs = @()
        tools = @(
            'SearchMemory',
            'RunAzCliReadCommands',
            'GetAzCliHelp',
            'QueryLogAnalyticsByWorkspaceId',
            'FindConnectedGitHubRepo'
        )
        mcpTools = @()
        allowParallelToolCalls = $true
        enableSkills = $true
        allowedSkills = @($skillName)
    }
}

$incidentFilter = @{
    name = $incidentFilterName
    type = 'IncidentFilter'
    tags = $ownershipTags
    properties = @{
        incidentPlatform = 'AzMonitor'
        isEnabled = $true
        priorities = @('Sev2')
        titleContains = $thresholds.AlertDisplayNamePrefix
        handlingAgent = $subagentName
        agentMode = 'Review'
        mergeEnabled = $true
        mergeWindowHours = 3
        maxAutomatedInvestigationAttempts = 3
    }
}

$weekdayReport = @{
    name = $weekdayReportName
    type = 'ScheduledTask'
    tags = $ownershipTags
    properties = @{
        name = $weekdayReportName
        description = 'Weekday morning health report for the whole Arc-enabled fleet: connectivity, agent posture, telemetry freshness and resource headroom.'
        cronExpression = '45 7 * * 1-5'
        agentPrompt = @"
Use the $subagentName subagent and the $skillName skill to produce a weekday morning health report for all five Arc-enabled machines in $ArcResourceGroupName using the workspace $WorkspaceName. This 07:45 UTC schedule runs after the daily ArcBox startup grace in both CET and CEST.

Report, in this order: Arc connectivity and agent version per machine with its demo role label; extension provisioning state grouped by capability, explicitly listing anything not in Succeeded state; Heartbeat and InsightsMetrics freshness per machine; CPU and memory-used averages, p95 values and maxima for the last 24 hours next to the documented seven-day p95 baseline; disk free space per real mount point, excluding Linux pseudo-mounts under /snap/, /sys/ and /run/; and aggregate change-tracking counts when that table has data, otherwise state that change tracking is unavailable for the Linux hosts and do not enable it.

Flag any machine whose 24 hour p95 exceeds its documented baseline p95 by more than 15 percentage points, and any machine with less than 20 percent free space on a real mount. Do not treat missing telemetry outside 08:00 Europe/Madrid to 18:00 UTC as an incident, and do not treat an empty Perf or SecurityEvent table as a problem. Label the demo roles as presentation-only. Do not include user names or event-message samples. Do not remediate; keep all recommendations in Review and hand genuine security concerns to the SOC and Microsoft Sentinel.
"@
        agentMode = 'Review'
        isEnabled = $true
    }
}

$weeklyCapacityReport = @{
    name = $weeklyCapacityReportName
    type = 'ScheduledTask'
    tags = $ownershipTags
    properties = @{
        name = $weeklyCapacityReportName
        description = 'Monday capacity and drift report comparing the last seven days against the documented Arc fleet baseline.'
        cronExpression = '0 8 * * 1'
        agentPrompt = @"
Use the $subagentName subagent and the $skillName skill to produce a Monday capacity report for all five Arc-enabled machines in $ArcResourceGroupName using the workspace $WorkspaceName.

For each machine compute the daily p95 of CPU and of memory used over the last seven days and compare it with the documented baseline p95: ArcBox-Win2K22 CPU 9.0 and memory 46.5, ArcBox-Win2K25 CPU 16.6 and memory 60.5, ArcBox-SQL CPU 11.3 and memory 59.6, Arcbox-Ubuntu-01 CPU 1.5 and memory 19.5, Arcbox-Ubuntu-02 CPU 1.5 and memory 19.3. Report the drift per day and per machine, call out any sustained upward trend across three or more consecutive days, and state how much headroom remains before the Sev2 thresholds of $($thresholds.CpuSaturationPercent) percent CPU and $($thresholds.MemoryPressurePercent) percent memory used.

Add a short capacity narrative for each demo role, remembering that the adfs and domain-controller labels are presentation only. List days with reduced sample counts caused by the daily shutdown window rather than treating them as data loss. Include the current disk free space per real mount point. Keep every recommendation in Review, propose no automated change, and route genuine security concerns to the SOC and Microsoft Sentinel.
"@
        agentMode = 'Review'
        isEnabled = $true
    }
}

try {
    $null = Connect-ArcIdentitySreAgentApi `
        -SubscriptionId $SubscriptionId `
        -AgentResourceId $agentResourceId `
        -ApiVersion $previewApiVersion

    Invoke-ArcIdentitySreAgentApi -Method Put -Path "/api/v2/extendedAgent/skills/$skillName" -Body $skill | Out-Null
    Invoke-ArcIdentitySreAgentApi -Method Put -Path "/api/v2/extendedAgent/agents/$subagentName" -Body $subagent | Out-Null
    Invoke-ArcIdentitySreAgentApi -Method Put -Path "/api/v2/extendedAgent/incidentFilters/$incidentFilterName" -Body $incidentFilter | Out-Null
    Invoke-ArcIdentitySreAgentApi -Method Put -Path "/api/v2/extendedAgent/scheduledtasks/$weekdayReportName" -Body $weekdayReport | Out-Null
    Invoke-ArcIdentitySreAgentApi -Method Put -Path "/api/v2/extendedAgent/scheduledtasks/$weeklyCapacityReportName" -Body $weeklyCapacityReport | Out-Null

    $verifiedSkill = Invoke-ArcIdentitySreAgentApi -Method Get -Path "/api/v2/extendedAgent/skills/$skillName" -Body $null
    $verifiedSubagent = Invoke-ArcIdentitySreAgentApi -Method Get -Path "/api/v2/extendedAgent/agents/$subagentName" -Body $null
    $verifiedFilter = Invoke-ArcIdentitySreAgentApi -Method Get -Path "/api/v2/extendedAgent/incidentFilters/$incidentFilterName" -Body $null
    $verifiedWeekday = Invoke-ArcIdentitySreAgentApi -Method Get -Path "/api/v2/extendedAgent/scheduledtasks/$weekdayReportName" -Body $null
    $verifiedWeekly = Invoke-ArcIdentitySreAgentApi -Method Get -Path "/api/v2/extendedAgent/scheduledtasks/$weeklyCapacityReportName" -Body $null

    $verifiedFilterProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $verifiedFilter -PropertyName 'properties'
    if ((Get-ArcIdentityOptionalPropertyValue -InputObject $verifiedFilterProperties -PropertyName 'agentMode') -ne 'Review') {
        throw "Incident filter '$incidentFilterName' must stay in Review mode."
    }
    if ((Get-ArcIdentityOptionalPropertyValue -InputObject $verifiedFilterProperties -PropertyName 'handlingAgent') -ne $subagentName) {
        throw "Incident filter '$incidentFilterName' must be handled by '$subagentName'."
    }
    foreach ($verifiedTask in @($verifiedWeekday, $verifiedWeekly)) {
        $verifiedTaskProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $verifiedTask -PropertyName 'properties'
        if ((Get-ArcIdentityOptionalPropertyValue -InputObject $verifiedTaskProperties -PropertyName 'agentMode') -ne 'Review') {
            throw 'Every Arc fleet scheduled report must stay in Review mode.'
        }
    }
    $verifiedSkillProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $verifiedSkill -PropertyName 'properties'
    $verifiedSkillFiles = @(Get-ArcIdentityOptionalPropertyValue -InputObject $verifiedSkillProperties -PropertyName 'additionalFiles')
    if ($verifiedSkillFiles.Count -ne $skillAdditionalFilePaths.Count) {
        throw "Skill '$skillName' must expose exactly $($skillAdditionalFilePaths.Count) reviewed KQL assets."
    }
    $verifiedSubagentProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $verifiedSubagent -PropertyName 'properties'
    $verifiedSubagentSkills = @(Get-ArcIdentityOptionalPropertyValue -InputObject $verifiedSubagentProperties -PropertyName 'allowedSkills')
    if ($skillName -notin $verifiedSubagentSkills) {
        throw "Subagent '$subagentName' must be allowed to use skill '$skillName'."
    }

    Write-Host "Arc fleet observability SRE Agent configuration applied and verified on '$AgentName'."
    Write-Host "Incident filter '$incidentFilterName' now routes Sev2 '$($thresholds.AlertDisplayNamePrefix)' alerts to '$subagentName' in Review mode."
} finally {
    Disconnect-ArcIdentitySreAgentApi
}
