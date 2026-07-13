#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $ResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $AgentName = 'sre-agent-mercadona-v1',
    [string] $RepositoryUrl = 'https://github.com/marioaguileraaa/mercadona-sre-agent-demo',
    [string] $RepositoryName = 'mercadona-sre-agent-demo',
    [string] $GitHubRepository = 'marioaguileraaa/mercadona-sre-agent-demo',
    [ValidateRange(500, 1000000)]
    [int] $MonthlyAgentUnitLimit = 1000,
    [switch] $SetGitHubSecret
)

. "$PSScriptRoot\AzureDemo.Common.ps1"

$sreAdministratorRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'
$sreStandardUserRoleId = '2d84a65a-63b2-4343-bbb6-31105d857bc1'
$previewApiVersion = '2025-05-01-preview'
$triggerName = 'mercadona-controlled-issue'
$triggerBridgeName = 'logic-mercadona-sre-trigger-v1'
$triggerBridgeDeploymentName = 'mercadona-sre-trigger-bridge'
$agentResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/agents/$AgentName"
$agentArmUrl = "https://management.azure.com${agentResourceId}"

function ConvertFrom-Base64Url {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    $normalizedValue = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9_-]+$') {
            throw 'The JWT payload segment was not valid base64url.'
        }

        $normalizedValue = $Value.Replace('-', '+').Replace('_', '/')
        switch ($normalizedValue.Length % 4) {
            0 { break }
            2 { $normalizedValue += '==' }
            3 { $normalizedValue += '=' }
            default { throw 'The JWT payload segment had invalid base64url padding.' }
        }

        try {
            return [Convert]::FromBase64String($normalizedValue)
        } catch {
            throw 'The JWT payload segment was not valid base64url.'
        }
    } finally {
        $Value = $null
        $normalizedValue = $null
    }
}

function Get-ArmAccessTokenIdentity {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $AccessToken
    )

    $tokenParts = $null
    $payloadSegment = $null
    $payloadBytes = $null
    $payloadJson = $null
    $payload = $null
    $utf8 = $null
    $oidProperty = $null
    $tidProperty = $null
    $tenantId = $null
    try {
        if ([string]::IsNullOrWhiteSpace($AccessToken)) {
            throw 'The Azure Resource Manager access token was empty.'
        }

        $tokenParts = $AccessToken.Split('.')
        if ($tokenParts.Count -ne 3 -or [string]::IsNullOrWhiteSpace($tokenParts[1])) {
            throw 'The Azure Resource Manager access token was not a valid three-segment JWT.'
        }

        $payloadSegment = $tokenParts[1]
        $payloadBytes = ConvertFrom-Base64Url -Value $payloadSegment
        try {
            $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
            $payloadJson = $utf8.GetString($payloadBytes)
            $payload = $payloadJson | ConvertFrom-Json
        } catch {
            throw 'The Azure Resource Manager access token JWT payload was not valid UTF-8 JSON.'
        }

        if ($null -ne $payload) {
            $oidProperty = $payload.PSObject.Properties['oid']
        }
        if ($null -eq $oidProperty -or [string]::IsNullOrWhiteSpace([string] $oidProperty.Value)) {
            throw 'The Azure Resource Manager access token JWT payload did not contain a nonblank oid claim.'
        }

        $tidProperty = $payload.PSObject.Properties['tid']
        $tenantId = if ($null -ne $tidProperty -and
            -not [string]::IsNullOrWhiteSpace([string] $tidProperty.Value)) {
            [string] $tidProperty.Value
        } else {
            $null
        }

        return [PSCustomObject]@{
            Oid = [string] $oidProperty.Value
            Tid = $tenantId
        }
    } finally {
        if ($null -ne $payloadBytes) {
            [Array]::Clear($payloadBytes, 0, $payloadBytes.Length)
        }
        if ($null -ne $tokenParts) {
            [Array]::Clear($tokenParts, 0, $tokenParts.Length)
        }
        $AccessToken = $null
        $tokenParts = $null
        $payloadSegment = $null
        $payloadBytes = $null
        $payloadJson = $null
        $payload = $null
        $utf8 = $null
        $oidProperty = $null
        $tidProperty = $null
        $tenantId = $null
    }
}

Assert-DemoAzureContext -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName

$signedInUserId = az ad signed-in-user show --query id --output tsv 2>$null
if ($LASTEXITCODE -ne 0) {
    $signedInUserId = $null
}
if ([string]::IsNullOrWhiteSpace($signedInUserId)) {
    $armAccessToken = $null
    $armIdentity = $null
    $currentTenantId = $null
    try {
        $armAccessToken = az account get-access-token `
            --resource 'https://management.azure.com/' `
            --query accessToken `
            --output tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($armAccessToken)) {
            throw 'Microsoft Graph could not identify the signed-in user, and an Azure Resource Manager access token could not be acquired for the secure local oid fallback.'
        }

        $armIdentity = Get-ArmAccessTokenIdentity -AccessToken $armAccessToken
        $armAccessToken = $null
        $oidProperty = $armIdentity.PSObject.Properties['Oid']
        $signedInUserId = [string] $oidProperty.Value

        $currentTenantId = az account show --query tenantId --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentTenantId)) {
            $tidProperty = $armIdentity.PSObject.Properties['Tid']
            if ($null -eq $tidProperty -or [string]::IsNullOrWhiteSpace([string] $tidProperty.Value)) {
                throw 'The Azure Resource Manager access token JWT payload did not contain a nonblank tid claim required to verify the current subscription tenant.'
            }
            if (-not [string]::Equals(
                    [string] $tidProperty.Value,
                    $currentTenantId,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'The Azure Resource Manager access token tenant did not match the current subscription tenant.'
            }
        }
    } finally {
        $armAccessToken = $null
        $armIdentity = $null
        $currentTenantId = $null
        $oidProperty = $null
        $tidProperty = $null
    }
}
if ([string]::IsNullOrWhiteSpace($signedInUserId)) {
    throw 'Unable to determine the signed-in Azure user object ID from Microsoft Graph or the Azure Resource Manager access token oid claim.'
}

$existingAdminAssignments = az role assignment list `
    --assignee-object-id $signedInUserId `
    --scope $agentResourceId `
    --fill-principal-name false `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect SRE Agent Administrator assignments.'
}

$hasAdministratorRole = $existingAdminAssignments | Where-Object {
    $_.roleDefinitionId -match "/$sreAdministratorRoleId$"
}
if (-not $hasAdministratorRole) {
    az role assignment create `
        --assignee-object-id $signedInUserId `
        --assignee-principal-type User `
        --role $sreAdministratorRoleId `
        --scope $agentResourceId `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to grant the signed-in user SRE Agent Administrator at agent scope.'
    }
    Write-Host 'Granted the signed-in user SRE Agent Administrator at agent scope.'
} else {
    Write-Host 'Signed-in user already has SRE Agent Administrator at agent scope.'
}

$limitPatch = @{
    properties = @{
        monthlyAgentUnitLimit = $MonthlyAgentUnitLimit
    }
} | ConvertTo-Json -Depth 4 -Compress
az rest `
    --method patch `
    --url "${agentArmUrl}?api-version=$previewApiVersion" `
    --headers 'Content-Type=application/json' `
    --body $limitPatch `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to configure monthlyAgentUnitLimit through the control plane.'
}

$agent = az rest `
    --method get `
    --url "${agentArmUrl}?api-version=$previewApiVersion" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($agent.properties.agentEndpoint)) {
    throw 'The SRE Agent ARM resource did not expose an agentEndpoint.'
}

$endpoint = $agent.properties.agentEndpoint.TrimEnd('/')
$script:dataPlaneHeaders = $null
$script:agentHttpClient = $null

function Get-ResponseItems {
    param(
        [object] $Response,
        [string[]] $PropertyNames
    )

    if ($null -eq $Response) {
        return @()
    }
    if ($Response -is [array]) {
        return @($Response)
    }
    foreach ($propertyName in $PropertyNames) {
        $property = $Response.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            return @($property.Value)
        }
    }
    return @($Response)
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()]
        [object] $InputObject,
        [Parameter(Mandatory)]
        [string] $PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-FirstOptionalPropertyValue {
    param(
        [AllowNull()]
        [object] $InputObject,
        [Parameter(Mandatory)]
        [string[]] $PropertyNames,
        [switch] $PropertiesFirst
    )

    $properties = Get-OptionalPropertyValue -InputObject $InputObject -PropertyName 'properties'
    $candidateObjects = if ($PropertiesFirst) {
        @($properties, $InputObject)
    } else {
        @($InputObject, $properties)
    }

    foreach ($candidateObject in $candidateObjects) {
        foreach ($propertyName in $PropertyNames) {
            $value = Get-OptionalPropertyValue -InputObject $candidateObject -PropertyName $propertyName
            if ($null -ne $value) {
                return $value
            }
        }
    }
    return $null
}

function Invoke-AgentApi {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post', 'Put')]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Path,
        [object] $Body
    )

    if ($null -eq $script:agentHttpClient) {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $script:agentHttpClient = [System.Net.Http.HttpClient]::new($handler, $true)
    }

    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($Method.ToUpperInvariant()),
        "$endpoint$Path"
    )
    $response = $null
    try {
        foreach ($header in $script:dataPlaneHeaders.GetEnumerator()) {
            if ($header.Key -eq 'Content-Type') {
                continue
            }
            if (-not $request.Headers.TryAddWithoutValidation([string] $header.Key, [string] $header.Value)) {
                throw "Unable to add SRE Agent API request header '$($header.Key)'."
            }
        }
        if ($null -ne $Body) {
            $jsonBody = $Body | ConvertTo-Json -Depth 30
            $request.Content = [System.Net.Http.StringContent]::new(
                $jsonBody,
                [System.Text.Encoding]::UTF8,
                'application/json'
            )
        }

        $response = $script:agentHttpClient.Send($request)
        $response.EnsureSuccessStatusCode() | Out-Null
        if ($null -eq $response.Content) {
            return $null
        }
        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($responseBody)) {
            return $null
        }
        return $responseBody | ConvertFrom-Json
    } finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        $request.Dispose()
    }
}

$dataPlaneDeadline = (Get-Date).AddMinutes(10)
$lastDataPlaneError = $null
do {
    try {
        $accessToken = az account get-access-token `
            --resource 'https://azuresre.dev' `
            --query accessToken `
            --output tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
            throw 'Unable to acquire an Azure SRE Agent data-plane token.'
        }
        $script:dataPlaneHeaders = @{
            Authorization = "Bearer $accessToken"
            'Content-Type' = 'application/json'
        }
        Invoke-AgentApi -Method Get -Path '/api/v2/repos' -Body $null | Out-Null
        $lastDataPlaneError = $null
        break
    } catch {
        $lastDataPlaneError = $_
        Start-Sleep -Seconds 15
    }
} while ((Get-Date) -lt $dataPlaneDeadline)

if ($null -ne $lastDataPlaneError) {
    throw "SRE Agent Administrator propagation did not complete within ten minutes: $($lastDataPlaneError.Exception.Message)"
}

$domainsResponse = Invoke-AgentApi -Method Get -Path '/api/v2/github/domains' -Body $null
$domains = Get-ResponseItems -Response $domainsResponse -PropertyNames @('value', 'values', 'domains', 'items')
$githubDomain = $domains | Where-Object {
    $domainProperties = Get-OptionalPropertyValue -InputObject $_ -PropertyName 'properties'
    $domainName = @(
        Get-OptionalPropertyValue -InputObject $_ -PropertyName 'name'
        Get-OptionalPropertyValue -InputObject $_ -PropertyName 'domain'
        Get-OptionalPropertyValue -InputObject $domainProperties -PropertyName 'domain'
    ) | Where-Object { $null -ne $_ } | Select-Object -First 1
    $domainName -in @('github_com', 'github.com')
} | Select-Object -First 1
$githubDomainProperties = Get-OptionalPropertyValue -InputObject $githubDomain -PropertyName 'properties'
$githubDomainStatus = @(
    Get-OptionalPropertyValue -InputObject $githubDomainProperties -PropertyName 'status'
    Get-OptionalPropertyValue -InputObject $githubDomainProperties -PropertyName 'connectionStatus'
    Get-OptionalPropertyValue -InputObject $githubDomain -PropertyName 'status'
    Get-OptionalPropertyValue -InputObject $githubDomain -PropertyName 'connectionStatus'
) | Where-Object { $null -ne $_ } | Select-Object -First 1
$githubDomainIsHealthy = Get-OptionalPropertyValue -InputObject $githubDomain -PropertyName 'isHealthy'
$domainReady = if ($null -ne $githubDomainIsHealthy) {
    $githubDomainIsHealthy -eq $true
} else {
    $null -ne $githubDomain -and $githubDomainStatus -in @('Connected', 'Ready', 'Authenticated', 'Succeeded')
}

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_PAT)) {
    Invoke-AgentApi -Method Put -Path '/api/v2/github/domains/github_com' -Body @{
        AuthType = 'Pat'
        Pat = $env:GITHUB_PAT
    } | Out-Null
    Write-Host 'GitHub PAT submitted to Azure SRE Agent secure domain storage; it was not printed or written to repository/disk.'
    $domainReady = $true
} elseif (-not $domainReady) {
    $oauth = Invoke-AgentApi -Method Get -Path '/api/v2/github/oauth/config' -Body $null
    Write-Host 'INCOMPLETE: GitHub authentication is required before source indexing.'
    Write-Host 'Complete OAuth through the Azure SRE Agent portal, then rerun this script.'
    throw 'INCOMPLETE: no authenticated GitHub domain or GITHUB_PAT was available.'
} else {
    Write-Host "Using existing authenticated GitHub domain. Status=$githubDomainStatus"
}

$repositoryBody = @{
    name = $RepositoryName
    type = 'CodeRepo'
    properties = @{
        url = $RepositoryUrl
        type = 'GitHub'
        branch = 'main'
        description = 'Synthetic Mercadona-style retail reliability demo source'
    }
}
$repositoriesResponse = Invoke-AgentApi -Method Get -Path '/api/v2/repos' -Body $null
$repositories = Get-ResponseItems -Response $repositoriesResponse -PropertyNames @('value', 'values', 'repos', 'repositories', 'items')
$existingRepository = $repositories | Where-Object {
    $candidateProperties = Get-OptionalPropertyValue -InputObject $_ -PropertyName 'properties'
    $candidateName = @(
        Get-OptionalPropertyValue -InputObject $_ -PropertyName 'name'
        Get-OptionalPropertyValue -InputObject $candidateProperties -PropertyName 'name'
    ) | Where-Object { $null -ne $_ } | Select-Object -First 1
    $candidateName -eq $RepositoryName
} | Select-Object -First 1

if ($null -ne $existingRepository) {
    $existingRepository = Invoke-AgentApi -Method Get -Path "/api/v2/repos/$RepositoryName" -Body $null
}
$existingRepositoryProperties = Get-OptionalPropertyValue -InputObject $existingRepository -PropertyName 'properties'
$existingRepositoryUrl = @(
    Get-OptionalPropertyValue -InputObject $existingRepositoryProperties -PropertyName 'url'
    Get-OptionalPropertyValue -InputObject $existingRepository -PropertyName 'url'
) | Where-Object { $null -ne $_ } | Select-Object -First 1
$existingRepositoryBranch = @(
    Get-OptionalPropertyValue -InputObject $existingRepositoryProperties -PropertyName 'branch'
    Get-OptionalPropertyValue -InputObject $existingRepository -PropertyName 'branch'
) | Where-Object { $null -ne $_ } | Select-Object -First 1
$existingRepositoryType = @(
    Get-OptionalPropertyValue -InputObject $existingRepositoryProperties -PropertyName 'type'
    Get-OptionalPropertyValue -InputObject $existingRepository -PropertyName 'type'
) | Where-Object { $null -ne $_ } | Select-Object -First 1
$existingCloneStatus = @(
    Get-OptionalPropertyValue -InputObject $existingRepositoryProperties -PropertyName 'cloneStatus'
    Get-OptionalPropertyValue -InputObject $existingRepository -PropertyName 'cloneStatus'
) | Where-Object { $null -ne $_ } | Select-Object -First 1
$existingRepositoryBranchMatchesDesired = [string]::IsNullOrWhiteSpace($existingRepositoryBranch) `
    -or $existingRepositoryBranch -eq 'main'
$repositoryMatchesDesired = $null -ne $existingRepository `
    -and $existingRepositoryUrl -eq $RepositoryUrl `
    -and $existingRepositoryBranchMatchesDesired `
    -and $existingRepositoryType -eq 'GitHub'

if ($null -eq $existingRepository) {
    Invoke-AgentApi -Method Put -Path "/api/v2/repos/$RepositoryName" -Body $repositoryBody | Out-Null
    Write-Host "Created repository '$RepositoryName'."
} elseif (-not $repositoryMatchesDesired) {
    throw "Repository '$RepositoryName' already exists with a different URL, type, or branch. Refusing destructive replacement."
} elseif ($existingCloneStatus -eq 'Ready') {
    Write-Host "Reusing existing Ready repository '$RepositoryName'."
} else {
    Write-Host "Repository '$RepositoryName' already has the desired source configuration; waiting for cloneStatus '$existingCloneStatus' to complete."
}

$repoDeadline = (Get-Date).AddMinutes(10)
$cloneStatus = $null
do {
    $repoStatus = Invoke-AgentApi -Method Get -Path "/api/v2/repos/$RepositoryName" -Body $null
    $repoStatusProperties = Get-OptionalPropertyValue -InputObject $repoStatus -PropertyName 'properties'
    $cloneStatus = @(
        Get-OptionalPropertyValue -InputObject $repoStatusProperties -PropertyName 'cloneStatus'
        Get-OptionalPropertyValue -InputObject $repoStatus -PropertyName 'cloneStatus'
    ) | Where-Object { $null -ne $_ } | Select-Object -First 1
    if ($cloneStatus -eq 'Ready') {
        break
    }
    if ($cloneStatus -in @('Failed', 'Error', 'Canceled')) {
        throw "Repository indexing failed with cloneStatus '$cloneStatus'."
    }
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt $repoDeadline)
if ($cloneStatus -ne 'Ready') {
    throw "Repository cloneStatus did not reach Ready within ten minutes. Last status: '$cloneStatus'."
}

foreach ($connectorName in @('log-analytics', 'application-insights')) {
    $connector = az rest `
        --method get `
        --url "${agentArmUrl}/connectors/${connectorName}?api-version=$previewApiVersion" `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read ARM connector '$connectorName'."
    }
    if ($connector.properties.identity -ne $agent.properties.actionConfiguration.identity) {
        throw "ARM connector '$connectorName' is not using the SRE UAMI."
    }
    if ($connector.properties.provisioningState -notin @('Succeeded', $null)) {
        throw "ARM connector '$connectorName' provisioning state is '$($connector.properties.provisioningState)'."
    }
}

$codeAnalyzer = @{
    name = 'code-analyzer'
    type = 'ExtendedAgent'
    tags = @('mercadona-demo', 'synthetic-data')
    owner = ''
    properties = @{
        instructions = @'
Investigate only the fictional Mercadona-style retail reliability demo. Correlate Azure Container Apps WorkingSetBytes telemetry with structured DEMO_CART_MEMORY_RETENTION logs by CorrelationId, CartId, StoreId, ProductId, AllocationBytes, RetainedBytes, MaxRetainedBytes and RootCauseClue. Identify the active backend revision, inspect the connected main branch, and cite file:line evidence. Treat all stores, products, prices, carts, orders, correlation IDs and metrics as synthetic. In Review mode, propose only the reversible mitigation of setting DEMO_CART_MEMORY_MB_PER_ADD to 0, which creates a fresh revision and removes the retained process heap; never execute a write without explicit approval.
'@
        handoffDescription = 'Correlate working-set telemetry, retained-byte logs, active revision and repository source for the synthetic cart-memory demo.'
        handoffs = @()
        tools = @(
            'SearchMemory',
            'RunAzCliReadCommands',
            'RunAzCliWriteCommands',
            'GetAzCliHelp',
            'QueryLogAnalyticsByWorkspaceId',
            'ExecutePythonCode',
            'FindConnectedGitHubRepo'
        )
        mcpTools = @()
        allowParallelToolCalls = $true
        enableSkills = $true
    }
}
Invoke-AgentApi -Method Put -Path '/api/v2/extendedAgent/agents/code-analyzer' -Body $codeAnalyzer | Out-Null

$incidentFilter = @{
    name = 'mercadona-cart-memory-sev2'
    type = 'IncidentFilter'
    tags = @('mercadona-demo')
    properties = @{
        incidentPlatform = 'AzMonitor'
        isEnabled = $true
        priorities = @('Sev2')
        titleContains = 'mercadona'
        handlingAgent = 'code-analyzer'
        agentMode = 'Review'
        deepInvestigationEnabled = $true
        maxAutomatedInvestigationAttempts = 3
    }
}
Invoke-AgentApi -Method Put -Path '/api/v2/extendedAgent/incidentFilters/mercadona-cart-memory-sev2' -Body $incidentFilter | Out-Null

$triggerPayload = @{
    name = $triggerName
    description = 'Investigate a controlled synthetic incident from GitHub.'
    agentPrompt = 'Analyze the supplied synthetic cart-memory incident using WorkingSetBytes, retained-byte logs, the active revision and the connected repository. Return evidence and only the Review-mode mitigation proposal DEMO_CART_MEMORY_MB_PER_ADD=0.'
    agent = 'code-analyzer'
    agentMode = 'Review'
}
$triggerListResponse = Invoke-AgentApi -Method Get -Path '/api/v1/httptriggers' -Body $null
$triggers = Get-ResponseItems -Response $triggerListResponse -PropertyNames @('value', 'values', 'triggers', 'items')
$existingTrigger = $triggers | Where-Object {
    (Get-FirstOptionalPropertyValue -InputObject $_ -PropertyNames @('name')) -eq $triggerName
} | Select-Object -First 1

if ($null -ne $existingTrigger) {
    $triggerId = Get-FirstOptionalPropertyValue -InputObject $existingTrigger -PropertyNames @('id', 'triggerId')
    if ([string]::IsNullOrWhiteSpace($triggerId)) {
        throw 'Existing HTTP trigger did not expose an ID.'
    }
    $triggerPayload['id'] = $triggerId
    $trigger = Invoke-AgentApi -Method Put -Path "/api/v1/httptriggers/$triggerId" -Body $triggerPayload
} else {
    $trigger = Invoke-AgentApi -Method Post -Path '/api/v1/httptriggers/create' -Body $triggerPayload
    $triggerId = Get-FirstOptionalPropertyValue -InputObject $trigger -PropertyNames @('id', 'triggerId')
}
if ([string]::IsNullOrWhiteSpace($triggerId)) {
    throw 'HTTP trigger configuration did not return an ID.'
}

$configuredTriggersResponse = Invoke-AgentApi -Method Get -Path '/api/v1/httptriggers' -Body $null
$configuredTriggers = Get-ResponseItems -Response $configuredTriggersResponse -PropertyNames @('value', 'values', 'triggers', 'items')
$configuredTrigger = $configuredTriggers | Where-Object {
    $candidateId = Get-FirstOptionalPropertyValue -InputObject $_ -PropertyNames @('id', 'triggerId')
    $candidateId -eq $triggerId
} | Select-Object -First 1
if ($null -eq $configuredTrigger) {
    throw 'HTTP trigger verification failed before bridge deployment.'
}
$configuredTriggerProperties = Get-OptionalPropertyValue -InputObject $configuredTrigger -PropertyName 'properties'
$configuredTriggerMode = Get-FirstOptionalPropertyValue -InputObject $configuredTrigger -PropertyNames @('agentMode')
$configuredTriggerAgent = Get-FirstOptionalPropertyValue -InputObject $configuredTrigger -PropertyNames @('agent')
$configuredTriggerPrompt = Get-FirstOptionalPropertyValue -InputObject $configuredTrigger -PropertyNames @('agentPrompt')
if ($configuredTriggerMode -ne 'Review' -or
    $configuredTriggerAgent -ne 'code-analyzer' -or
    [string]::IsNullOrWhiteSpace($configuredTriggerPrompt)) {
    throw 'HTTP trigger verification did not preserve Review mode, code-analyzer, and agentPrompt.'
}

$triggerProperties = Get-OptionalPropertyValue -InputObject $trigger -PropertyName 'properties'
$existingTriggerProperties = Get-OptionalPropertyValue -InputObject $existingTrigger -PropertyName 'properties'
$triggerUrl = @(
    Get-OptionalPropertyValue -InputObject $trigger -PropertyName 'triggerUrl'
    Get-OptionalPropertyValue -InputObject $trigger -PropertyName 'webhookUrl'
    Get-OptionalPropertyValue -InputObject $triggerProperties -PropertyName 'triggerUrl'
    Get-OptionalPropertyValue -InputObject $triggerProperties -PropertyName 'webhookUrl'
    Get-OptionalPropertyValue -InputObject $configuredTrigger -PropertyName 'triggerUrl'
    Get-OptionalPropertyValue -InputObject $configuredTrigger -PropertyName 'webhookUrl'
    Get-OptionalPropertyValue -InputObject $configuredTriggerProperties -PropertyName 'triggerUrl'
    Get-OptionalPropertyValue -InputObject $configuredTriggerProperties -PropertyName 'webhookUrl'
    Get-OptionalPropertyValue -InputObject $existingTrigger -PropertyName 'triggerUrl'
    Get-OptionalPropertyValue -InputObject $existingTrigger -PropertyName 'webhookUrl'
    Get-OptionalPropertyValue -InputObject $existingTriggerProperties -PropertyName 'triggerUrl'
    Get-OptionalPropertyValue -InputObject $existingTriggerProperties -PropertyName 'webhookUrl'
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($triggerUrl)) {
    $triggerUrl = "$endpoint/api/v1/httptriggers/trigger/$triggerId"
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$triggerBridgeTemplate = Join-Path $repoRoot 'infra\trigger-bridge.bicep'
if (-not (Test-Path -LiteralPath $triggerBridgeTemplate -PathType Leaf)) {
    throw 'The Logic App trigger bridge Bicep module was not found.'
}
$bridgeLocation = Get-OptionalPropertyValue -InputObject $agent -PropertyName 'location'
if ([string]::IsNullOrWhiteSpace($bridgeLocation)) {
    throw 'The SRE Agent ARM resource did not expose a location for the trigger bridge.'
}
$null = az deployment group create `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $triggerBridgeDeploymentName `
    --template-file $triggerBridgeTemplate `
    --parameters `
        "location=$bridgeLocation" `
        "logicAppName=$triggerBridgeName" `
        "agentName=$AgentName" `
        "sreTriggerUrl=$triggerUrl" `
    --output none 2>&1
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to deploy the authenticated Logic App trigger bridge.'
}

$triggerBridgeResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$triggerBridgeName"
$triggerBridge = az rest `
    --method get `
    --url "https://management.azure.com${triggerBridgeResourceId}?api-version=2019-05-01" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to verify the Logic App trigger bridge.'
}
$triggerBridgeIdentity = Get-OptionalPropertyValue -InputObject $triggerBridge -PropertyName 'identity'
$triggerBridgePrincipalId = Get-OptionalPropertyValue -InputObject $triggerBridgeIdentity -PropertyName 'principalId'
$triggerBridgeProperties = Get-OptionalPropertyValue -InputObject $triggerBridge -PropertyName 'properties'
$triggerBridgeState = Get-OptionalPropertyValue -InputObject $triggerBridgeProperties -PropertyName 'state'
$triggerBridgeDefinition = Get-OptionalPropertyValue -InputObject $triggerBridgeProperties -PropertyName 'definition'
$triggerBridgeActions = Get-OptionalPropertyValue -InputObject $triggerBridgeDefinition -PropertyName 'actions'
$triggerBridgeForwardAction = Get-OptionalPropertyValue -InputObject $triggerBridgeActions -PropertyName 'forward_to_sre_agent'
$triggerBridgeForwardInputs = Get-OptionalPropertyValue -InputObject $triggerBridgeForwardAction -PropertyName 'inputs'
$triggerBridgeAuthentication = Get-OptionalPropertyValue -InputObject $triggerBridgeForwardInputs -PropertyName 'authentication'
$triggerBridgeAuthType = Get-OptionalPropertyValue -InputObject $triggerBridgeAuthentication -PropertyName 'type'
$triggerBridgeAudience = Get-OptionalPropertyValue -InputObject $triggerBridgeAuthentication -PropertyName 'audience'
$triggerBridgeResponseAction = Get-OptionalPropertyValue -InputObject $triggerBridgeActions -PropertyName 'respond_to_caller'
if ([string]::IsNullOrWhiteSpace($triggerBridgePrincipalId) -or
    $triggerBridgeState -ne 'Enabled' -or
    $triggerBridgeAuthType -ne 'ManagedServiceIdentity' -or
    $triggerBridgeAudience -ne 'https://azuresre.dev' -or
    $null -eq $triggerBridgeResponseAction) {
    throw 'The Logic App trigger bridge identity, authentication, response, or state verification failed.'
}

$bridgeRoleDeadline = (Get-Date).AddMinutes(5)
$bridgeHasStandardUserRole = $false
do {
    $bridgeRoleAssignments = az role assignment list `
        --assignee-object-id $triggerBridgePrincipalId `
        --scope $agentResourceId `
        --role $sreStandardUserRoleId `
        --fill-principal-name false `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the Logic App SRE Agent Standard User assignment.'
    }
    $bridgeHasStandardUserRole = $null -ne ($bridgeRoleAssignments | Where-Object {
        $_.roleDefinitionId -match "/$sreStandardUserRoleId$"
    } | Select-Object -First 1)
    if ($bridgeHasStandardUserRole) {
        break
    }
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt $bridgeRoleDeadline)
if (-not $bridgeHasStandardUserRole) {
    throw 'Logic App SRE Agent Standard User assignment did not propagate within five minutes.'
}

$triggerBridgeCallbackUrl = az rest `
    --method post `
    --url "https://management.azure.com${triggerBridgeResourceId}/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01" `
    --query value `
    --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($triggerBridgeCallbackUrl)) {
    throw 'Unable to obtain the Logic App trigger callback URL.'
}
$triggerBridgeCallbackUri = $null
if (-not [Uri]::TryCreate($triggerBridgeCallbackUrl, [UriKind]::Absolute, [ref] $triggerBridgeCallbackUri) -or
    $triggerBridgeCallbackUri.Scheme -ne 'https' -or
    $triggerBridgeCallbackUri.Query -notmatch '(^\?|&)sig=') {
    throw 'The Logic App trigger callback URL was invalid.'
}

if ($SetGitHubSecret) {
    $triggerBridgeCallbackUrl | gh secret set SRE_TRIGGER_URL --repo $GitHubRepository
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to set GitHub secret SRE_TRIGGER_URL.'
    }
    Write-Host "GitHub secret SRE_TRIGGER_URL set to the authenticated bridge callback for $GitHubRepository without printing the URL."
} else {
    throw 'INCOMPLETE: SRE_TRIGGER_URL was not set. Rerun with -SetGitHubSecret so the bridge callback is piped securely to GitHub without being printed.'
}
$triggerBridgeCallbackUrl = $null
$triggerBridgeCallbackUri = $null
$triggerUrl = $null

$verifiedAgent = az rest `
    --method get `
    --url "${agentArmUrl}?api-version=$previewApiVersion" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to verify final agent ARM configuration.'
}
if ($verifiedAgent.properties.incidentManagementConfiguration.type -ne 'AzMonitor') {
    throw 'Agent incidentManagementConfiguration is not AzMonitor.'
}
if ($verifiedAgent.properties.actionConfiguration.mode -ne 'Review' -or
    $verifiedAgent.properties.actionConfiguration.accessLevel -ne 'Low') {
    throw 'Agent must remain Review/Low.'
}
if ([int]$verifiedAgent.properties.monthlyAgentUnitLimit -ne $MonthlyAgentUnitLimit) {
    throw "monthlyAgentUnitLimit verification failed. Expected $MonthlyAgentUnitLimit."
}

$verifiedRepo = Invoke-AgentApi -Method Get -Path "/api/v2/repos/$RepositoryName" -Body $null
$verifiedRepoProperties = Get-OptionalPropertyValue -InputObject $verifiedRepo -PropertyName 'properties'
$verifiedCloneStatus = @(
    Get-OptionalPropertyValue -InputObject $verifiedRepoProperties -PropertyName 'cloneStatus'
    Get-OptionalPropertyValue -InputObject $verifiedRepo -PropertyName 'cloneStatus'
) | Where-Object { $null -ne $_ } | Select-Object -First 1
if ($verifiedCloneStatus -ne 'Ready') {
    throw 'Repository is not Ready after configuration.'
}
$verifiedSubagent = Invoke-AgentApi -Method Get -Path '/api/v2/extendedAgent/agents/code-analyzer' -Body $null
$verifiedFilter = Invoke-AgentApi -Method Get -Path '/api/v2/extendedAgent/incidentFilters/mercadona-cart-memory-sev2' -Body $null
$verifiedTriggersResponse = Invoke-AgentApi -Method Get -Path '/api/v1/httptriggers' -Body $null
$verifiedTriggers = Get-ResponseItems -Response $verifiedTriggersResponse -PropertyNames @('value', 'values', 'triggers', 'items')
$verifiedTrigger = $verifiedTriggers | Where-Object {
    (Get-FirstOptionalPropertyValue -InputObject $_ -PropertyNames @('id', 'triggerId')) -eq $triggerId
} | Select-Object -First 1
if ($null -eq $verifiedSubagent -or $null -eq $verifiedFilter -or $null -eq $verifiedTrigger) {
    throw 'Subagent, response plan, or HTTP trigger verification failed.'
}
$verifiedFilterMode = Get-FirstOptionalPropertyValue -InputObject $verifiedFilter -PropertyNames @('agentMode') -PropertiesFirst
if ($verifiedFilterMode -ne 'Review') {
    throw "Incident filter must remain in Review mode. Reported: '$verifiedFilterMode'."
}
$verifiedTriggerMode = Get-FirstOptionalPropertyValue -InputObject $verifiedTrigger -PropertyNames @('agentMode')
$verifiedTriggerAgent = Get-FirstOptionalPropertyValue -InputObject $verifiedTrigger -PropertyNames @('agent')
$verifiedTriggerPrompt = Get-FirstOptionalPropertyValue -InputObject $verifiedTrigger -PropertyNames @('agentPrompt')
if ($verifiedTriggerMode -ne 'Review' -or
    $verifiedTriggerAgent -ne 'code-analyzer' -or
    [string]::IsNullOrWhiteSpace($verifiedTriggerPrompt)) {
    throw 'HTTP trigger did not preserve agentMode=Review, agent=code-analyzer, and agentPrompt.'
}

$verifiedTriggerBridge = az rest `
    --method get `
    --url "https://management.azure.com${triggerBridgeResourceId}?api-version=2019-05-01" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to complete final Logic App trigger bridge verification.'
}
$verifiedTriggerBridgeIdentity = Get-OptionalPropertyValue -InputObject $verifiedTriggerBridge -PropertyName 'identity'
$verifiedTriggerBridgePrincipalId = Get-OptionalPropertyValue -InputObject $verifiedTriggerBridgeIdentity -PropertyName 'principalId'
$verifiedTriggerBridgeProperties = Get-OptionalPropertyValue -InputObject $verifiedTriggerBridge -PropertyName 'properties'
$verifiedTriggerBridgeState = Get-OptionalPropertyValue -InputObject $verifiedTriggerBridgeProperties -PropertyName 'state'
if ($verifiedTriggerBridgePrincipalId -ne $triggerBridgePrincipalId -or $verifiedTriggerBridgeState -ne 'Enabled') {
    throw 'Final Logic App trigger bridge identity or state verification failed.'
}

Write-Host "SRE Agent configuration verified: repo=Ready, connectors=UAMI, bridge=MSI/StandardUser, incident=AzMonitor, mode=Review, access=Low, monthlyLimit=$MonthlyAgentUnitLimit."
