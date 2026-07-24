#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $ResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $AgentName = 'sre-agent-mercadona-v1',
    [string] $RepositoryName = 'mercadona-sre-agent-demo',
    [string] $BackendAppName = 'ca-mercadona-retail-api'
)

. "$PSScriptRoot\AzureDemo.Common.ps1"

function Get-OptionalValue {
    param(
        [AllowNull()][object] $InputObject,
        [Parameter(Mandatory)][string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-AgentProperty {
    param(
        [AllowNull()][object] $InputObject,
        [Parameter(Mandatory)][string] $Name
    )

    $properties = Get-OptionalValue -InputObject $InputObject -Name 'properties'
    $value = Get-OptionalValue -InputObject $properties -Name $Name
    if ($null -ne $value) {
        return $value
    }
    return Get-OptionalValue -InputObject $InputObject -Name $Name
}

Assert-DemoAzureContext -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName

$agentResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/agents/$AgentName"
$backendResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/$BackendAppName"
$alertName = 'alert-mercadona-cart-5xx-sev3'
$alertResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/metricAlerts/$alertName"
$responsePlanName = 'mercadona-cart-5xx-sev3'

$agent = az rest `
    --method get `
    --url "https://management.azure.com${agentResourceId}?api-version=2025-05-01-preview" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read SRE Agent '$AgentName'."
}
if ($agent.properties.actionConfiguration.mode -ne 'Review' -or
    $agent.properties.actionConfiguration.accessLevel -ne 'Low' -or
    $agent.properties.incidentManagementConfiguration.type -ne 'AzMonitor') {
    throw 'SRE Agent must remain Review/Low with AzMonitor incident management.'
}

$alert = az rest `
    --method get `
    --url "https://management.azure.com${alertResourceId}?api-version=2018-03-01" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read metric alert '$alertName'."
}
$criterion = @($alert.properties.criteria.allOf)[0]
$statusDimension = @($criterion.dimensions | Where-Object { $_.name -eq 'statusCodeCategory' })[0]
if ($alert.properties.enabled -ne $true -or
    $alert.properties.severity -ne 3 -or
    $alert.properties.evaluationFrequency -ne 'PT1M' -or
    $alert.properties.windowSize -ne 'PT5M' -or
    @($alert.properties.scopes).Count -ne 1 -or
    $alert.properties.scopes[0] -ne $backendResourceId -or
    $criterion.metricName -ne 'Requests' -or
    $criterion.timeAggregation -ne 'Total' -or
    $criterion.operator -ne 'GreaterThan' -or
    [double]$criterion.threshold -ne 5 -or
    $null -eq $statusDimension -or
    @($statusDimension.values) -notcontains '5xx') {
    throw 'The retail alert is not the exact Requests 5xx >5 Sev3 PT1M/PT5M contract.'
}

foreach ($connectorName in @('log-analytics', 'application-insights')) {
    $connector = az rest `
        --method get `
        --url "https://management.azure.com${agentResourceId}/connectors/${connectorName}?api-version=2025-05-01-preview" `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or
        $connector.properties.identity -ne $agent.properties.actionConfiguration.identity -or
        $connector.properties.provisioningState -notin @('Succeeded', $null)) {
        throw "Connector '$connectorName' is not Ready with the SRE UAMI."
    }
}

$endpoint = Get-SreAgentEndpoint `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -AgentName $AgentName

$repository = Invoke-SreAgentRead -Endpoint $endpoint -Path "/api/v2/repos/$RepositoryName"
$repositoryStatus = Get-AgentProperty -InputObject $repository -Name 'cloneStatus'
if ($repositoryStatus -ne 'Ready') {
    throw "CodeRepo '$RepositoryName' is not Ready. Reported '$repositoryStatus'."
}
$domainsResponse = Invoke-SreAgentRead -Endpoint $endpoint -Path '/api/v2/github/domains'
$domains = if ($null -ne $domainsResponse.PSObject.Properties['values']) {
    @($domainsResponse.values)
} elseif ($null -ne $domainsResponse.PSObject.Properties['value']) {
    @($domainsResponse.value)
} elseif ($null -ne $domainsResponse.PSObject.Properties['domains']) {
    @($domainsResponse.domains)
} elseif ($null -ne $domainsResponse.PSObject.Properties['items']) {
    @($domainsResponse.items)
} else {
    @($domainsResponse)
}
$githubDomain = $domains | Where-Object {
    (Get-AgentProperty -InputObject $_ -Name 'name') -in @('github_com', 'github.com') -or
        (Get-AgentProperty -InputObject $_ -Name 'domain') -in @('github_com', 'github.com')
} | Select-Object -First 1
$githubDomainStatus = @(
    Get-AgentProperty -InputObject $githubDomain -Name 'connectionStatus'
    Get-AgentProperty -InputObject $githubDomain -Name 'status'
) | Where-Object { $null -ne $_ } | Select-Object -First 1
$githubDomainHealthy = Get-AgentProperty -InputObject $githubDomain -Name 'isHealthy'
if ($null -eq $githubDomain -or
    ($null -ne $githubDomainHealthy -and $githubDomainHealthy -ne $true) -or
    ($null -eq $githubDomainHealthy -and
     $null -ne $githubDomainStatus -and
     $githubDomainStatus -notin @('Connected', 'Ready', 'Authenticated', 'Succeeded'))) {
    Write-Host 'Manual step: Azure SRE Agent portal > Builder > Connectors > GitHub OAuth > Sign in, then rerun verification.'
    throw "INCOMPLETE: authenticated github_com domain is unavailable. Reported '$githubDomainStatus'."
}

$availableTools = Invoke-SreAgentRead -Endpoint $endpoint -Path '/api/v2/agent/tools'
$availableToolsJson = $availableTools | ConvertTo-Json -Depth 30 -Compress
$availableToolNames = @([regex]::Matches(
        $availableToolsJson,
        '"(?:name|toolName)"\s*:\s*"([^"]+)"',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    ) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$requiredGitHubCapabilities = [ordered]@{
    issue = '(?i)^(issue_write|CreateGithubIssue)$'
    branch = '(?i)^(create_branch|CreateGithubBranch|CreateBranch)$'
    contents = '(?i)^(push_files|PushGithubFiles|CommitGithubFiles|CreateGithubCommit|PushFiles)$'
    pullRequest = '(?i)^(create_pull_request|CreateGithubPullRequest|CreatePullRequest)$'
}
$selectedGitHubTools = [System.Collections.Generic.List[string]]::new()
$missingCapabilities = [System.Collections.Generic.List[string]]::new()
foreach ($capability in $requiredGitHubCapabilities.GetEnumerator()) {
    $matchingTool = $availableToolNames | Where-Object { $_ -match $capability.Value } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($matchingTool)) {
        $missingCapabilities.Add($capability.Key)
    } else {
        $selectedGitHubTools.Add($matchingTool)
    }
}
if ($missingCapabilities.Count -gt 0) {
    Write-Host 'Manual step: open Builder > Connectors > GitHub OAuth and reconnect with issue, contents and pull-request write access, then rerun verification.'
    throw "INCOMPLETE: GitHub tools did not expose required capabilities: $($missingCapabilities -join ', ')."
}

$handler = Invoke-SreAgentRead -Endpoint $endpoint -Path '/api/v2/extendedAgent/agents/incident-handler'
$handlerInstructions = [string](Get-AgentProperty -InputObject $handler -Name 'instructions')
$handlerTools = @(Get-AgentProperty -InputObject $handler -Name 'tools')
foreach ($requiredTool in @(
        'SearchMemory',
        'RunAzCliReadCommands',
        'RunAzCliWriteCommands',
        'QueryLogAnalyticsByWorkspaceId',
        'QueryAppInsightsByResourceId',
        'FindConnectedGitHubRepo'
    )) {
    if ($handlerTools -notcontains $requiredTool) {
        throw "incident-handler is missing required tool '$requiredTool'."
    }
}
foreach ($requiredGitHubTool in $selectedGitHubTools) {
    if ($handlerTools -notcontains $requiredGitHubTool) {
        throw "incident-handler is missing discovered GitHub tool '$requiredGitHubTool'."
    }
}
foreach ($requiredInstruction in @(
        'DEMO_CART_MEMORY_MB_PER_ADD=0',
        'DEMO_CART_MEMORY_FAILURE_MB=0',
        'create_pull_request',
        'Never merge',
        'Never execute this write until the operator explicitly approves'
    )) {
    if (-not $handlerInstructions.Contains($requiredInstruction, [StringComparison]::OrdinalIgnoreCase)) {
        throw "incident-handler is missing guardrail '$requiredInstruction'."
    }
}

$responsePlan = Invoke-SreAgentRead -Endpoint $endpoint -Path "/api/v2/extendedAgent/incidentFilters/$responsePlanName"
$planProperties = Get-OptionalValue -InputObject $responsePlan -Name 'properties'
if ($null -eq $planProperties) {
    $planProperties = $responsePlan
}
$azMonitorSettings = Get-OptionalValue -InputObject $planProperties -Name 'azMonitorFilterSettings'
if ((Get-OptionalValue -InputObject $planProperties -Name 'incidentPlatform') -ne 'AzMonitor' -or
    (Get-OptionalValue -InputObject $planProperties -Name 'agentMode') -ne 'Review' -or
    (Get-OptionalValue -InputObject $planProperties -Name 'handlingAgent') -ne 'incident-handler' -or
    (Get-OptionalValue -InputObject $planProperties -Name 'alertId') -ne $alertResourceId -or
    (Get-OptionalValue -InputObject $planProperties -Name 'titleContains') -ne $alertName -or
    @(Get-OptionalValue -InputObject $planProperties -Name 'priorities') -notcontains 'Sev3' -or
    (Get-OptionalValue -InputObject $azMonitorSettings -Name 'targetResourceType') -ne 'Microsoft.App/containerApps' -or
    (Get-OptionalValue -InputObject $azMonitorSettings -Name 'targetResource') -ne $backendResourceId) {
    throw 'The retail response plan is not exactly scoped by alertId, title, Sev3, resource type and backend resource.'
}

$plansResponse = Invoke-SreAgentRead -Endpoint $endpoint -Path '/api/v2/extendedAgent/incidentFilters'
$plans = if ($null -ne $plansResponse.PSObject.Properties['value']) {
    @($plansResponse.value)
} elseif ($null -ne $plansResponse.PSObject.Properties['items']) {
    @($plansResponse.items)
} else {
    @($plansResponse)
}
foreach ($forbiddenPlan in @('mercadona-cart-memory-sev2', 'quickstart_response_plan', 'quickstart_handler')) {
    if ($plans | Where-Object { (Get-AgentProperty -InputObject $_ -Name 'name') -eq $forbiddenPlan }) {
        throw "Competing response plan '$forbiddenPlan' is still present."
    }
}

$globalSettings = Invoke-SreAgentRead -Endpoint $endpoint -Path '/api/v2/agent/settings/global'
$permissions = Get-OptionalValue -InputObject $globalSettings -Name 'permissions'
$denies = @(Get-OptionalValue -InputObject $permissions -Name 'deny')
$asks = @(Get-OptionalValue -InputObject $permissions -Name 'ask')
foreach ($requiredDeny in @('*merge*', '*workflow*', '*deploy*')) {
    if ($denies -notcontains $requiredDeny) {
        throw "Global tool policy is missing deny '$requiredDeny'."
    }
}
foreach ($requiredAsk in @('RunAzCliWriteCommands') + @($selectedGitHubTools)) {
    if ($asks -notcontains $requiredAsk) {
        throw "Global tool policy is missing approval gate '$requiredAsk'."
    }
}

Write-Host 'SRE Agent verification passed: Review/Low, 5xx Sev3, exact response plan, Ready CodeRepo, connected GitHub issue/PR capabilities, and merge/workflow/deploy denies.'
