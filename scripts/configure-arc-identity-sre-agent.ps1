#requires -Version 7.2
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

function Assert-ArcIdentityOwnedSreResource {
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

    $properties = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $ExistingResource `
        -PropertyName 'properties'
    $actualName = [string] (
        Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($ExistingResource, $properties) `
            -PropertyNames @('name')
    )
    $actualType = [string] (
        Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($ExistingResource, $properties) `
            -PropertyNames @('type')
    )
    $tags = @(
        Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($ExistingResource, $properties) `
            -PropertyNames @('tags')
    )
    if ((-not [string]::IsNullOrWhiteSpace($actualName) -and
            -not [string]::Equals($actualName, $ExpectedName, [StringComparison]::Ordinal)) -or
        (-not [string]::IsNullOrWhiteSpace($actualType) -and
            -not [string]::Equals($actualType, $ExpectedType, [StringComparison]::Ordinal)) -or
        'synthetic-identity' -notin $tags -or
        'azure-arc' -notin $tags) {
        throw "SRE Agent resource '$ExpectedName' already exists without the dedicated synthetic identity ownership contract; refusing to overwrite it."
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
    throw 'Azure SRE Agent must already be configured as Review/Low; this script will not broaden it.'
}
if (-not [string]::Equals(
        [string] (
            Get-ArcIdentityOptionalPropertyValue `
                -InputObject $actionConfiguration `
                -PropertyName 'identity'
        ),
        $sreIdentityResourceId,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Azure SRE Agent action identity is not the expected existing UAMI.'
}

$managedResources = [System.Collections.Generic.List[string]]::new()
$knowledgeGraphConfiguration = Get-ArcIdentityOptionalPropertyValue `
    -InputObject $agentProperties `
    -PropertyName 'knowledgeGraphConfiguration'
$existingManagedResources = Get-ArcIdentityOptionalPropertyValue `
    -InputObject $knowledgeGraphConfiguration `
    -PropertyName 'managedResources'
foreach ($managedResource in @($existingManagedResources)) {
    if ([string]::IsNullOrWhiteSpace([string] $managedResource)) {
        continue
    }
    if ($null -eq ($managedResources | Where-Object {
                [string]::Equals(
                    [string] $_,
                    [string] $managedResource,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } | Select-Object -First 1)) {
        $managedResources.Add([string] $managedResource)
    }
}
foreach ($requiredResource in @($sreResourceGroupId, $arcResourceGroupId)) {
    if ($null -eq ($managedResources | Where-Object {
                [string]::Equals(
                    [string] $_,
                    $requiredResource,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } | Select-Object -First 1)) {
        $managedResources.Add($requiredResource)
    }
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
        $candidateName = [string] (
            Get-ArcIdentityOptionalPropertyValue -InputObject $_ -PropertyName 'name'
        )
        [string]::Equals(
            [string] (($candidateName -split '/')[-1]),
            $connectorName,
            [StringComparison]::OrdinalIgnoreCase
        )
    } |
    Select-Object -First 1
if ($null -ne $existingConnector) {
    $existingConnectorProperties = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $existingConnector `
        -PropertyName 'properties'
    if ((Get-ArcIdentityOptionalPropertyValue `
                -InputObject $existingConnectorProperties `
                -PropertyName 'dataConnectorType') -ne 'LogAnalytics' -or
        -not [string]::Equals(
            [string] (
                Get-ArcIdentityOptionalPropertyValue `
                    -InputObject $existingConnectorProperties `
                    -PropertyName 'dataSource'
            ),
            $workspaceResourceId,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            [string] (
                Get-ArcIdentityOptionalPropertyValue `
                    -InputObject $existingConnectorProperties `
                    -PropertyName 'identity'
            ),
            $sreIdentityResourceId,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Connector '$connectorName' already exists with a different type, workspace, or identity; refusing to overwrite it."
    }
}

$sreExtensionResources = @(
    @{
        Name = 'identity-infrastructure-operations'
        Type = 'Skill'
        Path = '/api/v2/extendedAgent/skills/identity-infrastructure-operations'
    },
    @{
        Name = 'identity-infrastructure-analyzer'
        Type = 'ExtendedAgent'
        Path = '/api/v2/extendedAgent/agents/identity-infrastructure-analyzer'
    },
    @{
        Name = 'identity-infrastructure-sev2'
        Type = 'IncidentFilter'
        Path = '/api/v2/extendedAgent/incidentFilters/identity-infrastructure-sev2'
    },
    @{
        Name = 'identity-infrastructure-weekday-report'
        Type = 'ScheduledTask'
        Path = '/api/v2/extendedAgent/scheduledtasks/identity-infrastructure-weekday-report'
    }
)
try {
    $null = Connect-ArcIdentitySreAgentApi `
        -SubscriptionId $SubscriptionId `
        -AgentResourceId $agentResourceId `
        -ApiVersion $previewApiVersion
    foreach ($resourceContract in $sreExtensionResources) {
        $existingResource = Invoke-ArcIdentitySreAgentApi `
            -Method Get `
            -Path $resourceContract.Path `
            -Body $null `
            -AllowNotFound
        Assert-ArcIdentityOwnedSreResource `
            -ExistingResource $existingResource `
            -ExpectedName $resourceContract.Name `
            -ExpectedType $resourceContract.Type
    }
} finally {
    Disconnect-ArcIdentitySreAgentApi
}

Write-Host 'Planned additive SRE Agent configuration:'
Write-Host "- Reader and Monitoring Reader at $arcResourceGroupId"
Write-Host "- Log Analytics Reader at $workspaceResourceId"
Write-Host '- ArcBox LAW connector, identity-infrastructure subagent/skill, Sev2 filter, and weekday Review report'
Write-Host '- No Autonomous mode, High access, identity remediation, receiver, or existing connector replacement'
if (-not $Apply) {
    Write-Host 'No Azure configuration was changed. Rerun with -Apply after reviewing this plan.'
    return
}
if (-not $PSCmdlet.ShouldProcess(
        $agentResourceId,
        'Add exact-scope read roles and idempotent Arc identity SRE Agent configuration'
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

$knowledgeGraphPatch = @{
    properties = @{
        knowledgeGraphConfiguration = @{
            identity = $sreIdentityResourceId
            managedResources = $managedResources.ToArray()
        }
    }
} | ConvertTo-Json -Depth 10 -Compress
Invoke-ArcIdentityAzNoOutput `
    -Arguments @(
        'rest',
        '--method', 'patch',
        '--url', "https://management.azure.com${agentResourceId}?api-version=$previewApiVersion",
        '--headers', 'Content-Type=application/json',
        '--body', $knowledgeGraphPatch,
        '--output', 'none'
    ) `
    -FailureMessage 'Unable to add the ArcBox resource group to SRE Agent managed resources.'

$connectorBody = @{
    properties = @{
        dataConnectorType = 'LogAnalytics'
        dataSource = $workspaceResourceId
        extendedProperties = @{
            armResourceId = $workspaceResourceId
            resource = @{
                name = $WorkspaceName
            }
        }
        identity = $sreIdentityResourceId
    }
} | ConvertTo-Json -Depth 10 -Compress
if ($null -eq $existingConnector) {
    Invoke-ArcIdentityAzNoOutput `
        -Arguments @(
            'rest',
            '--method', 'put',
            '--url', "https://management.azure.com${agentResourceId}/connectors/${connectorName}?api-version=$previewApiVersion",
            '--headers', 'Content-Type=application/json',
            '--body', $connectorBody,
            '--output', 'none'
        ) `
        -FailureMessage 'Unable to configure the additive ArcBox Log Analytics connector.'
} else {
    Write-Host "Reusing existing exact-scope connector '$connectorName'."
}

$skill = @{
    name = 'identity-infrastructure-operations'
    type = 'Skill'
    tags = @('mercadona-demo', 'synthetic-identity', 'azure-arc')
    properties = @{
        name = 'identity-infrastructure-operations'
        description = 'Read-only Arc identity telemetry investigation using aggregate KQL and exact Azure resource scopes.'
        tools = @(
            'RunAzCliReadCommands',
            'QueryLogAnalyticsByWorkspaceId',
            'SearchMemory'
        )
        skillContent = @'
Use only the existing ArcBox workspace law-arcbox-demo-001 and Arc machines ArcBox-Win2K22 and ArcBox-Win2K25. Real signals are Azure Arc connectivity, Azure Monitor Agent health, Heartbeat, generic Perf counters, and filtered host System/Application events. Events from source Mercadona.IdentityOps with demoSynthetic=true and event IDs 4101/4102 are synthetic identity-service demonstrations, never evidence of genuine AD FS or domain-controller activity.

Use the aggregate-only queries under kql/arc-identity: fleet-heartbeat.kql, data-freshness.kql, synthetic-token-failure-burst.kql, performance-correlation.kql, extension-health.arg.kql, and change-tracking.kql. Change tracking is optional and must be reported as unavailable when the existing ArcBox environment does not provide its table; never enable it autonomously. The expected ArcBox operating window starts at 08:20 Europe/Madrid, after startup grace, and ends at the fixed 18:00 UTC auto-shutdown; Heartbeat or Perf gaps outside that window are expected and must not be treated as incidents. Default reports must not include user names, event-message samples, authentication material, or raw RenderedDescription values.

Do not perform autonomous identity or security remediation. Keep every recommendation under human review. If evidence indicates a true security incident rather than demoSynthetic=true telemetry, stop the demo workflow and hand off to the SOC and Microsoft Sentinel.
'@
        additionalFiles = @(
            'kql/arc-identity/fleet-heartbeat.kql',
            'kql/arc-identity/data-freshness.kql',
            'kql/arc-identity/synthetic-token-failure-burst.kql',
            'kql/arc-identity/performance-correlation.kql',
            'kql/arc-identity/extension-health.arg.kql',
            'kql/arc-identity/change-tracking.kql'
        )
    }
}

$subagent = @{
    name = 'identity-infrastructure-analyzer'
    type = 'ExtendedAgent'
    tags = @('mercadona-demo', 'synthetic-identity', 'azure-arc')
    properties = @{
        instructions = @'
Investigate only the additive Azure Arc identity-infrastructure demonstration in rg-arcbox-itpro-weu-002. Scope every query to law-arcbox-demo-001 and the exact resources ArcBox-Win2K22 and ArcBox-Win2K25. Distinguish real Arc/AMA/LAW transport and real generic host telemetry from the synthetic Mercadona.IdentityOps identity-service source. Never describe event IDs 4101 or 4102 as genuine AD FS or domain-controller events; they are valid only when demoSynthetic=true. Suppress expected Heartbeat and Perf gaps outside 08:20 Europe/Madrid through 18:00 UTC; this window accounts for the daily startup grace, DST, and fixed UTC auto-shutdown.

Use aggregate counts, freshness timestamps, percentiles, and machine-level status. Do not expose user names, event messages, authentication data, or raw message samples in default findings. Correlate Heartbeat, Perf, filtered Event data, extension state, and change tracking with the connected repository KQL assets.

Remain read-only. Never install AD DS or AD FS, alter authentication policy, modify Security logs, disable monitoring, restart identity services, or execute identity/security remediation. Recommendations require human review. Route suspected real security incidents to the SOC and Microsoft Sentinel.
'@
        handoffDescription = 'Investigates aggregate Azure Arc identity demo telemetry while preserving the real-versus-synthetic boundary and SOC handoff.'
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
        allowedSkills = @('identity-infrastructure-operations')
    }
}

$incidentFilter = @{
    name = 'identity-infrastructure-sev2'
    type = 'IncidentFilter'
    tags = @('mercadona-demo', 'synthetic-identity', 'azure-arc')
    properties = @{
        incidentPlatform = 'AzMonitor'
        isEnabled = $true
        priorities = @('Sev2')
        titleContains = 'ArcBox IdentityOps'
        handlingAgent = 'identity-infrastructure-analyzer'
        agentMode = 'Review'
        deepInvestigationEnabled = $true
        maxAutomatedInvestigationAttempts = 3
    }
}

$scheduledTask = @{
    name = 'identity-infrastructure-weekday-report'
    type = 'ScheduledTask'
    tags = @('mercadona-demo', 'synthetic-identity', 'azure-arc')
    properties = @{
        name = 'identity-infrastructure-weekday-report'
        description = 'Weekday aggregate operational report for the two ArcBox Windows identity-demo hosts.'
        cronExpression = '30 7 * * 1-5'
        agentPrompt = @'
Use the identity-infrastructure-analyzer and identity-infrastructure-operations skill to produce a weekday report for only ArcBox-Win2K22 and ArcBox-Win2K25 in law-arcbox-demo-001. This 07:30 UTC schedule is after the 08:20 Europe/Madrid startup grace in both CET and CEST. Summarize Arc connectivity, AMA/extension state, Heartbeat and Perf freshness, synthetic Mercadona.IdentityOps burst counts, host performance trends, and aggregate change-tracking counts only when that existing table is available; otherwise state that change tracking is not available and do not enable it. Do not classify expected gaps outside 08:20 Europe/Madrid through the fixed 18:00 UTC auto-shutdown as incidents. Clearly label real Arc/AMA/LAW plumbing and generic host telemetry as real, and Mercadona.IdentityOps events with demoSynthetic=true as synthetic. Do not include user names or event-message samples. Do not remediate. Put recommendations in Review and hand true security concerns to the SOC and Microsoft Sentinel.
'@
        agentMode = 'Review'
        isEnabled = $true
    }
}

try {
    $null = Connect-ArcIdentitySreAgentApi `
        -SubscriptionId $SubscriptionId `
        -AgentResourceId $agentResourceId `
        -ApiVersion $previewApiVersion
    Invoke-ArcIdentitySreAgentApi `
        -Method Put `
        -Path '/api/v2/extendedAgent/skills/identity-infrastructure-operations' `
        -Body $skill | Out-Null
    Invoke-ArcIdentitySreAgentApi `
        -Method Put `
        -Path '/api/v2/extendedAgent/agents/identity-infrastructure-analyzer' `
        -Body $subagent | Out-Null
    Invoke-ArcIdentitySreAgentApi `
        -Method Put `
        -Path '/api/v2/extendedAgent/incidentFilters/identity-infrastructure-sev2' `
        -Body $incidentFilter | Out-Null
    Invoke-ArcIdentitySreAgentApi `
        -Method Put `
        -Path '/api/v2/extendedAgent/scheduledtasks/identity-infrastructure-weekday-report' `
        -Body $scheduledTask | Out-Null

    $verifiedSubagent = Invoke-ArcIdentitySreAgentApi `
        -Method Get `
        -Path '/api/v2/extendedAgent/agents/identity-infrastructure-analyzer' `
        -Body $null
    $verifiedSkill = Invoke-ArcIdentitySreAgentApi `
        -Method Get `
        -Path '/api/v2/extendedAgent/skills/identity-infrastructure-operations' `
        -Body $null
    $verifiedFilter = Invoke-ArcIdentitySreAgentApi `
        -Method Get `
        -Path '/api/v2/extendedAgent/incidentFilters/identity-infrastructure-sev2' `
        -Body $null
    $verifiedTask = Invoke-ArcIdentitySreAgentApi `
        -Method Get `
        -Path '/api/v2/extendedAgent/scheduledtasks/identity-infrastructure-weekday-report' `
        -Body $null
    $verifiedFilterProperties = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $verifiedFilter `
        -PropertyName 'properties'
    $verifiedTaskProperties = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $verifiedTask `
        -PropertyName 'properties'
    if ($null -eq $verifiedSubagent -or
        $null -eq $verifiedSkill -or
        (Get-ArcIdentityFirstPropertyValue `
                -InputObjects @($verifiedFilterProperties, $verifiedFilter) `
                -PropertyNames @('agentMode')) -ne 'Review' -or
        (Get-ArcIdentityFirstPropertyValue `
                -InputObjects @($verifiedTaskProperties, $verifiedTask) `
                -PropertyNames @('agentMode')) -ne 'Review') {
        throw 'SRE Agent identity extension verification failed.'
    }
} finally {
    Disconnect-ArcIdentitySreAgentApi
}

$verifiedAgent = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'rest',
        '--method', 'get',
        '--url', "https://management.azure.com${agentResourceId}?api-version=$previewApiVersion",
        '--output', 'json'
    ) `
    -FailureMessage 'Unable to verify the final SRE Agent ARM configuration.'
$verifiedAgentProperties = Get-ArcIdentityOptionalPropertyValue `
    -InputObject $verifiedAgent `
    -PropertyName 'properties'
$verifiedActionConfiguration = Get-ArcIdentityOptionalPropertyValue `
    -InputObject $verifiedAgentProperties `
    -PropertyName 'actionConfiguration'
if ((Get-ArcIdentityOptionalPropertyValue `
            -InputObject $verifiedActionConfiguration `
            -PropertyName 'mode') -ne 'Review' -or
    (Get-ArcIdentityOptionalPropertyValue `
            -InputObject $verifiedActionConfiguration `
            -PropertyName 'accessLevel') -ne 'Low') {
    throw 'Final SRE Agent configuration did not preserve Review/Low.'
}

Write-Host 'Arc identity SRE Agent configuration verified: exact-scope readers, additive LAW connector, read-only subagent/skill, Sev2 Review filter, and weekday Review report.'
