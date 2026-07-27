#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $ResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $AgentName = 'sre-agent-mercadona-v1',
    [string] $RepositoryUrl = 'https://github.com/marioaguileraaa/mercadona-sre-agent-demo',
    [string] $RepositoryName = 'mercadona-sre-agent-demo',
    [string] $GitHubRepository = 'marioaguileraaa/mercadona-sre-agent-demo',
    [string] $ExpectedRepositoryCommit = '',
    [ValidateRange(500, 1000000)]
    [int] $MonthlyAgentUnitLimit = 1000,
    [switch] $SetGitHubSecret
)

. "$PSScriptRoot\AzureDemo.Common.ps1"
. "$PSScriptRoot\SreAgent.GitHubPreflight.ps1"

$sreAdministratorRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'
$sreStandardUserRoleId = '2d84a65a-63b2-4343-bbb6-31105d857bc1'
$previewApiVersion = '2025-05-01-preview'
$triggerName = 'mercadona-controlled-issue'
$triggerBridgeName = 'logic-mercadona-sre-trigger-v1'
$triggerBridgeDeploymentName = 'mercadona-sre-trigger-bridge'
$agentResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/agents/$AgentName"
$agentArmUrl = "https://management.azure.com${agentResourceId}"
$backendResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/ca-mercadona-retail-api"
$cartAlertName = 'alert-mercadona-cart-5xx-sev3'
$cartAlertResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/metricAlerts/$cartAlertName"
$incidentHandlerName = 'incident-handler'
$incidentFilterName = 'mercadona-cart-5xx-sev3'
$repoRoot = Split-Path $PSScriptRoot -Parent
$expectedRepositoryCommit = Resolve-ExpectedRepositoryCommit `
    -ExpectedRepositoryCommit $ExpectedRepositoryCommit `
    -RepositoryRoot $repoRoot

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
    $currentAccountJson = $null
    $currentAccount = $null
    $currentTenantId = $null
    $tenantIdProperty = $null
    $userTypeProperty = $null
    try {
        $currentAccountJson = az account show `
            --subscription $SubscriptionId `
            --query '{tenantId:tenantId,userType:user.type}' `
            --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentAccountJson)) {
            throw 'Microsoft Graph could not identify the signed-in user, and the target subscription Azure CLI account context could not be verified.'
        }
        try {
            $currentAccount = $currentAccountJson | ConvertFrom-Json
        } catch {
            throw 'The target subscription Azure CLI account context was not valid JSON.'
        }

        $tenantIdProperty = $currentAccount.PSObject.Properties['tenantId']
        if ($null -eq $tenantIdProperty -or
            [string]::IsNullOrWhiteSpace([string] $tenantIdProperty.Value)) {
            throw 'The target subscription Azure CLI account context did not expose a tenant ID.'
        }
        $currentTenantId = [string] $tenantIdProperty.Value

        $userTypeProperty = $currentAccount.PSObject.Properties['userType']
        if ($null -eq $userTypeProperty -or
            -not [string]::Equals(
                [string] $userTypeProperty.Value,
                'user',
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'The secure oid fallback requires an interactive user Azure CLI account for the target subscription.'
        }

        $armAccessToken = az account get-access-token `
            --subscription $SubscriptionId `
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

        $tidProperty = $armIdentity.PSObject.Properties['Tid']
        if ($null -eq $tidProperty -or [string]::IsNullOrWhiteSpace([string] $tidProperty.Value)) {
            throw 'The Azure Resource Manager access token JWT payload did not contain a nonblank tid claim required to verify the target subscription tenant.'
        }
        if (-not [string]::Equals(
                [string] $tidProperty.Value,
                $currentTenantId,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'The Azure Resource Manager access token tenant did not match the target subscription tenant.'
        }
    } finally {
        $armAccessToken = $null
        $armIdentity = $null
        $currentAccountJson = $null
        $currentAccount = $null
        $currentTenantId = $null
        $oidProperty = $null
        $tidProperty = $null
        $tenantIdProperty = $null
        $userTypeProperty = $null
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
    if ($InputObject -is [System.Collections.IDictionary] -and
        $InputObject.Contains($PropertyName)) {
        return $InputObject[$PropertyName]
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

function Disable-IncidentFilter {
    param(
        [Parameter(Mandatory)]
        [string] $FilterId,
        [Parameter(Mandatory)]
        [string] $Reason
    )

    $filterPath = "/api/v2/extendedAgent/incidentFilters/$FilterId"
    $existingFilter = Invoke-AgentApi -Method Get -Path $filterPath -Body $null
    $existingProperties = Get-OptionalPropertyValue -InputObject $existingFilter -PropertyName 'properties'
    $propertySource = if ($null -ne $existingProperties) {
        $existingProperties
    } else {
        $existingFilter
    }
    if ((Get-OptionalPropertyValue -InputObject $propertySource -PropertyName 'isEnabled') -eq $false) {
        Write-Host "IncidentFilter '$FilterId' is already disabled."
        return
    }

    $disabledProperties = $propertySource |
        ConvertTo-Json -Depth 30 |
        ConvertFrom-Json -AsHashtable
    if ($null -eq $existingProperties) {
        foreach ($metadataProperty in @(
                'id',
                'filterId',
                'name',
                'type',
                'tags',
                'owner',
                'createdAt',
                'updatedAt',
                'etag'
            )) {
            $disabledProperties.Remove($metadataProperty)
        }
    }
    $disabledProperties['isEnabled'] = $false

    $disabledFilter = [ordered]@{}
    foreach ($propertyName in @('name', 'type', 'tags', 'owner')) {
        $propertyValue = Get-OptionalPropertyValue -InputObject $existingFilter -PropertyName $propertyName
        if ($null -ne $propertyValue) {
            $disabledFilter[$propertyName] = $propertyValue
        }
    }
    if (-not $disabledFilter.Contains('name')) {
        $disabledFilter['name'] = $FilterId
    }
    if (-not $disabledFilter.Contains('type')) {
        $disabledFilter['type'] = 'IncidentFilter'
    }
    $disabledFilter['properties'] = $disabledProperties

    Invoke-AgentApi -Method Put -Path $filterPath -Body $disabledFilter | Out-Null
    Write-Warning "Disabled competing IncidentFilter '$FilterId' without deleting it: $Reason"
}

function Sync-RetailIncidentFilters {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $ConfiguredFilters
    )

    $legacyRetailFilterId = 'mercadona-cart-memory-sev2'
    $quickstartHandlerFilterId = 'quickstart_handler'
    $quickstartResponsePlanId = 'quickstart_response_plan'
    if (-not [string]::Equals(
            $quickstartResponsePlanId,
            'quickstart_response_plan',
            [StringComparison]::Ordinal
        )) {
        throw 'The approved disposable IncidentFilter ID must remain quickstart_response_plan.'
    }

    $legacyRetailFilterFound = $ConfiguredFilters | Where-Object {
        $candidateId = [string](Get-FirstOptionalPropertyValue `
                -InputObject $_ `
                -PropertyNames @('id', 'filterId', 'name'))
        [string]::Equals($candidateId, $legacyRetailFilterId, [StringComparison]::Ordinal)
    } | Select-Object -First 1
    if ($null -eq $legacyRetailFilterFound) {
        throw "Required legacy IncidentFilter '$legacyRetailFilterId' was not found for non-destructive migration."
    }

    foreach ($configuredFilter in $ConfiguredFilters) {
        $filterId = [string](Get-FirstOptionalPropertyValue `
                -InputObject $configuredFilter `
                -PropertyNames @('id', 'filterId', 'name'))
        if ([string]::IsNullOrWhiteSpace($filterId)) {
            continue
        }
        if ([string]::Equals($filterId, $legacyRetailFilterId, [StringComparison]::Ordinal)) {
            Disable-IncidentFilter `
                -FilterId $legacyRetailFilterId `
                -Reason 'routing is owned by mercadona-cart-5xx-sev3; legacy identity and history were preserved'
            continue
        }
        if ([string]::Equals($filterId, $quickstartHandlerFilterId, [StringComparison]::Ordinal)) {
            Disable-IncidentFilter `
                -FilterId $quickstartHandlerFilterId `
                -Reason 'the quickstart filter can compete with the exact retail alert routing'
            continue
        }
        if ([string]::Equals($filterId, $quickstartResponsePlanId, [StringComparison]::Ordinal)) {
            Invoke-AgentApi `
                -Method Delete `
                -Path '/api/v2/extendedAgent/incidentFilters/quickstart_response_plan' `
                -Body $null | Out-Null
            Write-Host "Removed exact disposable quickstart response plan '$filterId'."
        }
    }
}

function Invoke-AgentApi {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Delete', 'Get', 'Post', 'Put')]
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
$availableTools = Invoke-AgentApi -Method Get -Path '/api/v2/agent/tools' -Body $null

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
$readRepository = {
    Invoke-AgentApi -Method Get -Path "/api/v2/repos/$RepositoryName" -Body $null
}
$createRepository = if ($null -eq $existingRepository) {
    {
        Invoke-AgentApi `
            -Method Put `
            -Path "/api/v2/repos/$RepositoryName" `
            -Body $repositoryBody | Out-Null
        Write-Host "Created repository '$RepositoryName'."
    }
} else {
    $null
}
$githubRepositoryPreflight = Invoke-SreGithubRepositoryPreflight `
    -DomainsResponse $domainsResponse `
    -ToolsResponse $availableTools `
    -InitialRepository $existingRepository `
    -ReadRepository $readRepository `
    -CreateRepository $createRepository `
    -RequestSynchronization $null `
    -RepositoryName $RepositoryName `
    -RepositoryUrl $RepositoryUrl `
    -RepositoryBranch 'main' `
    -ExpectedCommit $expectedRepositoryCommit
$selectedGitHubTools = @($githubRepositoryPreflight.SelectedTools)
$repositoryState = $githubRepositoryPreflight.Repository
Write-Host "CodeRepo '$RepositoryName' is Ready at exact origin/main commit '$($repositoryState.Commit)'."

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

$globalSettings = Invoke-AgentApi -Method Get -Path '/api/v2/agent/settings/global' -Body $null
$globalPermissions = Get-OptionalPropertyValue -InputObject $globalSettings -PropertyName 'permissions'
$existingAllow = @(
    Get-OptionalPropertyValue -InputObject $globalPermissions -PropertyName 'allow'
) | Where-Object { $null -ne $_ } | ForEach-Object { @($_) }
if ($existingAllow -contains '*') {
    throw 'Global tool policy allows all tools and would bypass Review approval. Remove that broad allow before configuring the retail agent.'
}
$existingAsk = @(
    Get-OptionalPropertyValue -InputObject $globalPermissions -PropertyName 'ask'
) | Where-Object { $null -ne $_ } | ForEach-Object { @($_) }
$existingDeny = @(
    Get-OptionalPropertyValue -InputObject $globalPermissions -PropertyName 'deny'
) | Where-Object { $null -ne $_ } | ForEach-Object { @($_) }
$requiredAsk = @('RunAzCliWriteCommands') + @($selectedGitHubTools)
$requiredDeny = @(
    '*merge*',
    '*Merge*',
    '*workflow*',
    '*Workflow*',
    '*deploy*',
    '*Deploy*'
)
$toolPolicy = @{
    permissions = @{
        allow = @($existingAllow | Select-Object -Unique)
        ask = @($existingAsk + $requiredAsk | Select-Object -Unique)
        deny = @($existingDeny + $requiredDeny | Select-Object -Unique)
    }
}
Invoke-AgentApi -Method Put -Path '/api/v2/agent/settings/global' -Body $toolPolicy | Out-Null

$cartAlert = az rest `
    --method get `
    --url "https://management.azure.com${cartAlertResourceId}?api-version=2018-03-01" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or
    $cartAlert.properties.severity -ne 3 -or
    $cartAlert.properties.scopes.Count -ne 1 -or
    $cartAlert.properties.scopes[0] -ne $backendResourceId) {
    throw "Metric alert '$cartAlertName' is not Sev3 or is not scoped exclusively to the retail backend."
}

$incidentHandler = @{
    name = $incidentHandlerName
    type = 'ExtendedAgent'
    tags = @('mercadona-demo', 'synthetic-data', 'retail-incident')
    owner = ''
    properties = @{
        instructions = @'
Investigate only the fictional retail SRE demo in marioaguileraaa/mercadona-sre-agent-demo. Treat every store, product, price, cart, order, correlation ID and metric as synthetic.

First search memory, then correlate Azure Monitor Requests 5xx, Application Insights requests, Log Analytics console events and the active Container Apps revision. Use CorrelationId, CartId, StoreId, ProductId, Quantity, AllocationBytes, RetainedBytes, MaxRetainedBytes, ErrorCode and RootCauseClue. Inspect the connected Ready repository and cite exact file:line evidence. Identify the process-lifetime strong root in CartMemoryRetentionService as the synthetic leak only when evidence supports it.

Remain in Review mode. The only immediate mitigation you may propose is a controlled clean revision with DEMO_CART_MEMORY_MB_PER_ADD=0, DEMO_CART_MEMORY_FAILURE_MB=0 and DEMO_CART_MEMORY_MAX_MB=640. Explain that the new revision restarts the process and releases the retained heap. Never execute this write until the operator explicitly approves it. After approval, verify the healthy cart-to-tracking flow and that no new 5xx is produced.

Only after that approval, create a GitHub issue with Summary, Impact, Timeline, Evidence, Root Cause, Immediate Mitigation, Permanent Fix and Validation. Then create a branch, apply the smallest permanent code fix with tests, push the commit and open a pull request linked to the issue. Use only the exact authenticated GitHub write tools attached to this handler. Never use a token, gh CLI or direct GitHub REST call. Never merge a pull request, dispatch a workflow, deploy a revision from the PR or close the issue automatically. If any GitHub capability is unavailable, report INCOMPLETE with the minimal connector step and do not claim success.
'@
        handoffDescription = 'Investigate the synthetic retail cart 5xx incident, propose the reviewed clean-revision mitigation, and prepare an issue and unmerged PR after approval.'
        handoffs = @()
        tools = @(
            'SearchMemory',
            'RunAzCliReadCommands',
            'RunAzCliWriteCommands',
            'GetAzCliHelp',
            'QueryLogAnalyticsByWorkspaceId',
            'QueryAppInsightsByResourceId',
            'ExecutePythonCode',
            'FindConnectedGitHubRepo'
        ) + @($selectedGitHubTools)
        mcpTools = @()
        allowParallelToolCalls = $true
        enableSkills = $true
    }
}
Invoke-AgentApi -Method Put -Path "/api/v2/extendedAgent/agents/$incidentHandlerName" -Body $incidentHandler | Out-Null

$incidentFilter = @{
    name = $incidentFilterName
    type = 'IncidentFilter'
    tags = @('mercadona-demo')
    properties = @{
        incidentPlatform = 'AzMonitor'
        isEnabled = $true
        priorities = @('Sev3')
        alertId = $cartAlertResourceId
        titleContains = $cartAlertName
        azMonitorFilterSettings = @{
            targetResourceType = 'Microsoft.App/containerApps'
            targetResource = $backendResourceId
        }
        handlingAgent = $incidentHandlerName
        agentMode = 'Review'
        deepInvestigationEnabled = $true
        maxAutomatedInvestigationAttempts = 3
        mergeEnabled = $false
    }
}
Invoke-AgentApi -Method Put -Path "/api/v2/extendedAgent/incidentFilters/$incidentFilterName" -Body $incidentFilter | Out-Null

$configuredFiltersResponse = Invoke-AgentApi -Method Get -Path '/api/v2/extendedAgent/incidentFilters' -Body $null
$configuredFilters = Get-ResponseItems -Response $configuredFiltersResponse -PropertyNames @('value', 'values', 'incidentFilters', 'items')
Sync-RetailIncidentFilters -ConfiguredFilters @($configuredFilters)

$triggerPayload = @{
    name = $triggerName
    description = 'Investigate a controlled synthetic incident from GitHub.'
    agentPrompt = 'Analyze the supplied synthetic retail cart 5xx incident using Requests, Application Insights, retained-byte logs, the active revision and the connected repository. Return evidence and only the Review-mode clean-revision mitigation proposal with both demo memory variables set to 0.'
    agent = $incidentHandlerName
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
    $configuredTriggerAgent -ne $incidentHandlerName -or
    [string]::IsNullOrWhiteSpace($configuredTriggerPrompt)) {
    throw 'HTTP trigger verification did not preserve Review mode, incident-handler, and agentPrompt.'
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
$null = Wait-SreRepositoryReadyAtCommit `
    -InitialRepository $verifiedRepo `
    -ReadRepository $readRepository `
    -CreateRepository $null `
    -RequestSynchronization $null `
    -RepositoryName $RepositoryName `
    -RepositoryUrl $RepositoryUrl `
    -RepositoryBranch 'main' `
    -ExpectedCommit $expectedRepositoryCommit
$verifiedSubagent = Invoke-AgentApi -Method Get -Path "/api/v2/extendedAgent/agents/$incidentHandlerName" -Body $null
$verifiedFilter = Invoke-AgentApi -Method Get -Path "/api/v2/extendedAgent/incidentFilters/$incidentFilterName" -Body $null
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
    $verifiedTriggerAgent -ne $incidentHandlerName -or
    [string]::IsNullOrWhiteSpace($verifiedTriggerPrompt)) {
    throw 'HTTP trigger did not preserve agentMode=Review, agent=incident-handler, and agentPrompt.'
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

Write-Host "SRE Agent configuration verified: repo=Ready@$expectedRepositoryCommit, GitHub=OAuth/domain+issue-create/update+branch+contents+PR-create, handler=incident-handler, responsePlan=$incidentFilterName, bridge=MSI/StandardUser, incident=AzMonitor, mode=Review, access=Low, monthlyLimit=$MonthlyAgentUnitLimit."
