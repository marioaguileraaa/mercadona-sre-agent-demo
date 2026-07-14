Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ArcIdentitySreEndpoint = $null
$script:ArcIdentitySreHeaders = $null
$script:ArcIdentitySreHttpClient = $null

function Get-ArcIdentityOptionalPropertyValue {
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

function Get-ArcIdentityFirstPropertyValue {
    param(
        [AllowNull()]
        [object[]] $InputObjects,
        [Parameter(Mandatory)]
        [string[]] $PropertyNames
    )

    foreach ($inputObject in $InputObjects) {
        foreach ($propertyName in $PropertyNames) {
            $value = Get-ArcIdentityOptionalPropertyValue `
                -InputObject $inputObject `
                -PropertyName $propertyName
            if ($null -ne $value) {
                return $value
            }
        }
    }
    return $null
}

function Get-ArcIdentityResponseItems {
    param(
        [AllowNull()]
        [object] $Response,
        [string[]] $PropertyNames = @('value', 'items')
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

function Get-ArcIdentityKnowledgeGraphConfigurationPlan {
    param(
        [AllowNull()]
        [object] $ExistingConfiguration,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedIdentity,
        [Parameter(Mandatory)]
        [ValidateCount(1, 100)]
        [string[]] $RequiredManagedResources
    )

    $existingIdentity = [string] (
        Get-ArcIdentityOptionalPropertyValue `
            -InputObject $ExistingConfiguration `
            -PropertyName 'identity'
    )
    $existingManagedResources = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $ExistingConfiguration `
        -PropertyName 'managedResources'
    $existingResourceSet = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $desiredResourceSet = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $desiredManagedResources = [System.Collections.Generic.List[string]]::new()

    foreach ($managedResource in @($existingManagedResources)) {
        $resourceId = [string] $managedResource
        if ([string]::IsNullOrWhiteSpace($resourceId)) {
            continue
        }
        $null = $existingResourceSet.Add($resourceId)
        if ($desiredResourceSet.Add($resourceId)) {
            $desiredManagedResources.Add($resourceId)
        }
    }
    foreach ($requiredResource in $RequiredManagedResources) {
        if ([string]::IsNullOrWhiteSpace($requiredResource)) {
            throw 'Required SRE Agent managed resource IDs must be nonblank.'
        }
        if ($desiredResourceSet.Add($requiredResource)) {
            $desiredManagedResources.Add($requiredResource)
        }
    }

    $identityMatches = [string]::Equals(
        $existingIdentity,
        $ExpectedIdentity,
        [StringComparison]::OrdinalIgnoreCase
    )
    $managedResourceSetsMatch = $existingResourceSet.SetEquals($desiredResourceSet)
    return [pscustomobject]@{
        RequiresPatch = -not ($identityMatches -and $managedResourceSetsMatch)
        Identity = $ExpectedIdentity
        ManagedResources = $desiredManagedResources.ToArray()
    }
}

function Invoke-ArcIdentityAzJson {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,
        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    $json = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
    if ([string]::IsNullOrWhiteSpace([string] $json)) {
        throw "$FailureMessage Azure CLI returned an empty response."
    }
    try {
        return $json | ConvertFrom-Json -Depth 100
    } catch {
        throw "$FailureMessage Azure CLI did not return valid JSON."
    }
}

function Wait-ArcIdentitySreAgentProvisioningSucceeded {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AgentResourceId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ApiVersion,
        [ValidateRange(0, 86400)]
        [int] $TimeoutSeconds = 600,
        [ValidateRange(0, 3600)]
        [int] $PollIntervalSeconds = 10
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $terminalStates = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($terminalState in @('Failed', 'Canceled', 'Cancelled', 'Error')) {
        $null = $terminalStates.Add($terminalState)
    }

    $lastObservedState = '<not observed>'
    $isFirstCheck = $true
    while ($true) {
        if (-not $isFirstCheck -and
            $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "Azure SRE Agent did not reach provisioning state 'Succeeded' within $TimeoutSeconds seconds. Last observed state: '$lastObservedState'."
        }
        $isFirstCheck = $false

        $agent = Invoke-ArcIdentityAzJson `
            -Arguments @(
                'rest',
                '--method', 'get',
                '--subscription', $SubscriptionId,
                '--url', "https://management.azure.com${AgentResourceId}?api-version=$ApiVersion",
                '--output', 'json'
            ) `
            -FailureMessage 'Unable to read the Azure SRE Agent provisioning state.'
        $properties = Get-ArcIdentityOptionalPropertyValue `
            -InputObject $agent `
            -PropertyName 'properties'
        $stateValue = Get-ArcIdentityOptionalPropertyValue `
            -InputObject $properties `
            -PropertyName 'provisioningState'
        if ($stateValue -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string] $stateValue)) {
            $lastObservedState = if ($null -eq $stateValue) {
                '<missing>'
            } elseif ([string]::IsNullOrWhiteSpace([string] $stateValue)) {
                '<blank>'
            } else {
                [string] $stateValue
            }
            throw "Azure SRE Agent provisioning state was missing or invalid. Last observed state: '$lastObservedState'."
        }

        $lastObservedState = ([string] $stateValue).Trim()
        if ([string]::Equals(
                $lastObservedState,
                'Succeeded',
                [StringComparison]::OrdinalIgnoreCase
            )) {
            return $agent
        }
        if ($terminalStates.Contains($lastObservedState)) {
            throw "Azure SRE Agent provisioning reached terminal state '$lastObservedState'."
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "Azure SRE Agent did not reach provisioning state 'Succeeded' within $TimeoutSeconds seconds. Last observed state: '$lastObservedState'."
        }

        $remainingMilliseconds = [Math]::Max(
            0,
            ($TimeoutSeconds * 1000) - $stopwatch.Elapsed.TotalMilliseconds
        )
        $sleepMilliseconds = [int] [Math]::Min(
            $PollIntervalSeconds * 1000,
            $remainingMilliseconds
        )
        if ($sleepMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $sleepMilliseconds
        }
    }
}

function Invoke-ArcIdentityAzNoOutput {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,
        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Invoke-ArcIdentityArmRestWithJsonBody {
    param(
        [Parameter(Mandatory)]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Url,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Body,
        [string[]] $Headers = @('Content-Type=application/json'),
        [string] $Output = 'none',
        [ValidateRange(1, 100)]
        [int] $JsonDepth = 100,
        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    if ($Body -is [string]) {
        $bodyJson = [string] $Body
        if (-not (Test-Json -Json $bodyJson -ErrorAction SilentlyContinue)) {
            throw 'The ARM REST request body must be valid JSON.'
        }
    } else {
        $bodyJson = ConvertTo-Json -InputObject $Body -Depth $JsonDepth -Compress
    }

    $bodyFile = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine(
            [System.IO.Path]::GetTempPath(),
            "arc-identity-arm-rest-$([Guid]::NewGuid().ToString('N')).json"
        )
    )
    try {
        [System.IO.File]::WriteAllText(
            $bodyFile,
            $bodyJson,
            [System.Text.UTF8Encoding]::new($false)
        )
        $bodyFileArgument = "@$bodyFile"
        $azArguments = @(
            'rest',
            '--method', $Method,
            '--url', $Url
        )
        if ($Headers.Count -gt 0) {
            $azArguments += '--headers'
            $azArguments += $Headers
        }
        $azArguments += @(
            '--body', $bodyFileArgument,
            '--output', $Output
        )
        Invoke-ArcIdentityAzNoOutput `
            -Arguments $azArguments `
            -FailureMessage $FailureMessage
    } finally {
        $bodyJson = $null
        if (Test-Path -LiteralPath $bodyFile -PathType Leaf) {
            Remove-Item -LiteralPath $bodyFile -Force
        }
    }
}

function Assert-ArcIdentityAzureContext {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $TenantId,
        [Parameter(Mandatory)]
        [string[]] $ResourceGroupNames
    )

    if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required.'
    }

    $account = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'account', 'show',
            '--subscription', $SubscriptionId,
            '--query', '{id:id,tenantId:tenantId,name:name}',
            '--output', 'json'
        ) `
        -FailureMessage 'Unable to read the Azure CLI account context.'
    if (-not [string]::Equals(
            [string] $account.id,
            $SubscriptionId,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Azure CLI must target subscription '$SubscriptionId'. Current: '$($account.id)'."
    }
    if (-not [string]::Equals(
            [string] $account.tenantId,
            $TenantId,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Azure CLI must target tenant '$TenantId'. Current: '$($account.tenantId)'."
    }

    foreach ($resourceGroupName in $ResourceGroupNames) {
        $resourceGroup = Invoke-ArcIdentityAzJson `
            -Arguments @(
                'group', 'show',
                '--subscription', $SubscriptionId,
                '--name', $resourceGroupName,
                '--output', 'json'
            ) `
            -FailureMessage "Expected resource group '$resourceGroupName' is not accessible."
        if (-not [string]::Equals(
                [string] $resourceGroup.name,
                $resourceGroupName,
                [StringComparison]::Ordinal
            )) {
            throw "Resource group name mismatch. Expected '$resourceGroupName', got '$($resourceGroup.name)'."
        }
    }

    Write-Host "Safeguard passed: $($account.name) / $SubscriptionId / $TenantId"
}

function Get-ArcIdentityMachineResourceId {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $MachineName
    )

    return "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$MachineName"
}

function Get-ArcIdentityTargetMachines {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $Location,
        [Parameter(Mandatory)]
        [string[]] $MachineNames
    )

    if ($MachineNames.Count -ne 2 -or
        ($MachineNames | Select-Object -Unique).Count -ne 2) {
        throw 'Exactly two unique target Arc machine names are required.'
    }

    $machines = @(
        Get-ArcIdentityResponseItems -Response (
            Invoke-ArcIdentityAzJson `
                -Arguments @(
                    'connectedmachine', 'list',
                    '--subscription', $SubscriptionId,
                    '--resource-group', $ResourceGroupName,
                    '--output', 'json'
                ) `
                -FailureMessage "Unable to list Arc machines in '$ResourceGroupName'."
        )
    )
    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($machineName in $MachineNames) {
        $machine = $machines | Where-Object {
            [string]::Equals(
                [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $_ -PropertyName 'name'),
                $machineName,
                [StringComparison]::Ordinal
            )
        } | Select-Object -First 1
        if ($null -eq $machine) {
            throw "Expected Arc machine '$machineName' was not found in '$ResourceGroupName'."
        }

        $properties = Get-ArcIdentityOptionalPropertyValue -InputObject $machine -PropertyName 'properties'
        $status = Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($machine, $properties) `
            -PropertyNames @('status')
        if ($status -ne 'Connected') {
            throw "Arc machine '$machineName' must be Connected. Current status: '$status'."
        }

        $machineLocation = Get-ArcIdentityOptionalPropertyValue -InputObject $machine -PropertyName 'location'
        if (-not [string]::Equals(
                [string] $machineLocation,
                $Location,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Arc machine '$machineName' must be in '$Location'. Current location: '$machineLocation'."
        }

        $osType = Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($machine, $properties) `
            -PropertyNames @('osType', 'osName')
        if ([string] $osType -notmatch '(?i)windows') {
            throw "Arc machine '$machineName' must report a Windows operating system. Current: '$osType'."
        }
        $targets.Add($machine)
    }
    return $targets.ToArray()
}

function Assert-ArcIdentityAmaExtension {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $MachineName
    )

    $extension = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'connectedmachine', 'extension', 'show',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--machine-name', $MachineName,
            '--name', 'AzureMonitorWindowsAgent',
            '--output', 'json'
        ) `
        -FailureMessage "AzureMonitorWindowsAgent is not readable on '$MachineName'."
    $properties = Get-ArcIdentityOptionalPropertyValue -InputObject $extension -PropertyName 'properties'
    $provisioningState = Get-ArcIdentityFirstPropertyValue `
        -InputObjects @($extension, $properties) `
        -PropertyNames @('provisioningState')
    if ($provisioningState -ne 'Succeeded') {
        throw "AzureMonitorWindowsAgent on '$MachineName' is not Succeeded. Current: '$provisioningState'."
    }
    return $extension
}

function Get-ArcIdentityDcrAssociations {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $MachineName
    )

    $machineResourceId = Get-ArcIdentityMachineResourceId `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -MachineName $MachineName
    $response = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'rest',
            '--method', 'get',
            '--url', "https://management.azure.com${machineResourceId}/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2024-03-11",
            '--output', 'json'
        ) `
        -FailureMessage "Unable to list DCR associations on '$MachineName'."
    return @(Get-ArcIdentityResponseItems -Response $response)
}

function Invoke-ArcIdentityLogAnalyticsQuery {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $WorkspaceCustomerId,
        [Parameter(Mandatory)]
        [string] $Query
    )

    return Invoke-ArcIdentityAzJson `
        -Arguments @(
            'monitor', 'log-analytics', 'query',
            '--subscription', $SubscriptionId,
            '--workspace', $WorkspaceCustomerId,
            '--analytics-query', $Query,
            '--timespan', 'P1D',
            '--output', 'json'
        ) `
        -FailureMessage 'Unable to query the ArcBox Log Analytics workspace.'
}

function Test-ArcIdentityRoleAssignment {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $PrincipalId,
        [Parameter(Mandatory)]
        [string] $RoleDefinitionId,
        [Parameter(Mandatory)]
        [string] $Scope
    )

    $assignments = @(
        Get-ArcIdentityResponseItems -Response (
            Invoke-ArcIdentityAzJson `
                -Arguments @(
                    'role', 'assignment', 'list',
                    '--subscription', $SubscriptionId,
                    '--assignee-object-id', $PrincipalId,
                    '--scope', $Scope,
                    '--role', $RoleDefinitionId,
                    '--fill-principal-name', 'false',
                    '--output', 'json'
                ) `
                -FailureMessage "Unable to inspect role '$RoleDefinitionId' at '$Scope'."
        )
    )
    return $null -ne ($assignments | Where-Object {
            [string] $_.roleDefinitionId -match "/$([Regex]::Escape($RoleDefinitionId))$"
        } | Select-Object -First 1)
}

function Ensure-ArcIdentityRoleAssignment {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $PrincipalId,
        [Parameter(Mandatory)]
        [string] $RoleDefinitionId,
        [Parameter(Mandatory)]
        [string] $Scope
    )

    if (Test-ArcIdentityRoleAssignment `
            -SubscriptionId $SubscriptionId `
            -PrincipalId $PrincipalId `
            -RoleDefinitionId $RoleDefinitionId `
            -Scope $Scope) {
        Write-Host "Role '$RoleDefinitionId' already exists at the exact required scope."
        return
    }

    Invoke-ArcIdentityAzNoOutput `
        -Arguments @(
            'role', 'assignment', 'create',
            '--subscription', $SubscriptionId,
            '--assignee-object-id', $PrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $RoleDefinitionId,
            '--scope', $Scope,
            '--output', 'none'
        ) `
        -FailureMessage "Unable to assign role '$RoleDefinitionId' at '$Scope'."
    Write-Host "Assigned role '$RoleDefinitionId' at the exact required scope."
}

function Connect-ArcIdentitySreAgentApi {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $AgentResourceId,
        [string] $ApiVersion = '2025-05-01-preview'
    )

    Disconnect-ArcIdentitySreAgentApi
    $agent = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'rest',
            '--method', 'get',
            '--url', "https://management.azure.com${AgentResourceId}?api-version=$ApiVersion",
            '--output', 'json'
        ) `
        -FailureMessage 'Unable to read the Azure SRE Agent ARM resource.'
    $properties = Get-ArcIdentityOptionalPropertyValue -InputObject $agent -PropertyName 'properties'
    $endpoint = Get-ArcIdentityOptionalPropertyValue -InputObject $properties -PropertyName 'agentEndpoint'
    if ([string]::IsNullOrWhiteSpace([string] $endpoint)) {
        throw 'The Azure SRE Agent ARM resource did not expose an agentEndpoint.'
    }

    $token = & az account get-access-token `
        --subscription $SubscriptionId `
        --resource 'https://azuresre.dev' `
        --query accessToken `
        --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Unable to acquire an Azure SRE Agent data-plane token.'
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $script:ArcIdentitySreHttpClient = [System.Net.Http.HttpClient]::new($handler, $true)
    $script:ArcIdentitySreEndpoint = ([string] $endpoint).TrimEnd('/')
    $script:ArcIdentitySreHeaders = @{
        Authorization = "Bearer $token"
    }
    $token = $null
    return $agent
}

function Invoke-ArcIdentitySreAgentApi {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Put')]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Path,
        [AllowNull()]
        [object] $Body,
        [switch] $AllowNotFound
    )

    if ($null -eq $script:ArcIdentitySreHttpClient -or
        [string]::IsNullOrWhiteSpace([string] $script:ArcIdentitySreEndpoint) -or
        $null -eq $script:ArcIdentitySreHeaders) {
        throw 'Connect-ArcIdentitySreAgentApi must be called before the SRE Agent data plane.'
    }

    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($Method.ToUpperInvariant()),
        "$($script:ArcIdentitySreEndpoint)$Path"
    )
    $response = $null
    try {
        foreach ($header in $script:ArcIdentitySreHeaders.GetEnumerator()) {
            if (-not $request.Headers.TryAddWithoutValidation([string] $header.Key, [string] $header.Value)) {
                throw "Unable to add SRE Agent API request header '$($header.Key)'."
            }
        }
        if ($null -ne $Body) {
            $request.Content = [System.Net.Http.StringContent]::new(
                ($Body | ConvertTo-Json -Depth 30),
                [System.Text.Encoding]::UTF8,
                'application/json'
            )
        }

        $response = $script:ArcIdentitySreHttpClient.Send($request)
        if ($AllowNotFound -and
            $response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
            return $null
        }
        $response.EnsureSuccessStatusCode() | Out-Null
        if ($null -eq $response.Content) {
            return $null
        }
        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($responseBody)) {
            return $null
        }
        return $responseBody | ConvertFrom-Json -Depth 100
    } finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        $request.Dispose()
    }
}

function Disconnect-ArcIdentitySreAgentApi {
    if ($null -ne $script:ArcIdentitySreHttpClient) {
        $script:ArcIdentitySreHttpClient.Dispose()
    }
    $script:ArcIdentitySreEndpoint = $null
    $script:ArcIdentitySreHeaders = $null
    $script:ArcIdentitySreHttpClient = $null
}

function Invoke-ArcIdentityRunCommand {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $MachineName,
        [Parameter(Mandatory)]
        [ValidatePattern('^identityops-[a-z0-9-]{8,50}$')]
        [string] $RunCommandName,
        [Parameter(Mandatory)]
        [string] $ScriptText,
        [ValidateRange(60, 900)]
        [int] $TimeoutSeconds = 300
    )

    $existingCommands = @(
        Get-ArcIdentityResponseItems -Response (
            Invoke-ArcIdentityAzJson `
                -Arguments @(
                    'connectedmachine', 'run-command', 'list',
                    '--subscription', $SubscriptionId,
                    '--resource-group', $ResourceGroupName,
                    '--machine-name', $MachineName,
                    '--output', 'json'
                ) `
                -FailureMessage "Unable to list Run Command resources on '$MachineName'."
        )
    )
    if ($existingCommands | Where-Object { $_.name -eq $RunCommandName }) {
        throw "Run Command '$RunCommandName' already exists on '$MachineName'; refusing to overwrite it."
    }

    $commandError = $null
    $cleanupError = $null
    $result = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    try {
        Invoke-ArcIdentityAzNoOutput `
            -Arguments @(
                'connectedmachine', 'run-command', 'create',
                '--subscription', $SubscriptionId,
                '--resource-group', $ResourceGroupName,
                '--machine-name', $MachineName,
                '--name', $RunCommandName,
                '--script', $ScriptText,
                '--timeout-in-seconds', [string] $TimeoutSeconds,
                '--no-wait',
                '--output', 'none'
            ) `
            -FailureMessage "Unable to create Run Command '$RunCommandName' on '$MachineName'."

        do {
            $commandsDuringRun = @(
                Get-ArcIdentityResponseItems -Response (
                    Invoke-ArcIdentityAzJson `
                        -Arguments @(
                            'connectedmachine', 'run-command', 'list',
                            '--subscription', $SubscriptionId,
                            '--resource-group', $ResourceGroupName,
                            '--machine-name', $MachineName,
                            '--output', 'json'
                        ) `
                        -FailureMessage "Unable to list Run Command resources while '$RunCommandName' executes on '$MachineName'."
                )
            )
            if ($null -eq ($commandsDuringRun | Where-Object {
                        $_.name -eq $RunCommandName
                    } | Select-Object -First 1)) {
                Start-Sleep -Seconds 2
                continue
            }

            $command = Invoke-ArcIdentityAzJson `
                -Arguments @(
                    'connectedmachine', 'run-command', 'show',
                    '--subscription', $SubscriptionId,
                    '--resource-group', $ResourceGroupName,
                    '--machine-name', $MachineName,
                    '--name', $RunCommandName,
                    '--output', 'json'
                ) `
                -FailureMessage "Unable to read Run Command '$RunCommandName' on '$MachineName'."
            $properties = Get-ArcIdentityOptionalPropertyValue -InputObject $command -PropertyName 'properties'
            $instanceView = Get-ArcIdentityFirstPropertyValue `
                -InputObjects @($command, $properties) `
                -PropertyNames @('instanceView')
            $executionState = Get-ArcIdentityFirstPropertyValue `
                -InputObjects @($command, $properties, $instanceView) `
                -PropertyNames @('instanceViewExecutionState', 'executionState')
            $exitCode = Get-ArcIdentityFirstPropertyValue `
                -InputObjects @($command, $properties, $instanceView) `
                -PropertyNames @('instanceViewExitCode', 'exitCode')

            if ($executionState -in @('Succeeded', 'Failed', 'TimedOut', 'Canceled')) {
                if ($executionState -ne 'Succeeded' -or
                    ($null -ne $exitCode -and [int] $exitCode -ne 0)) {
                    throw "Run Command '$RunCommandName' on '$MachineName' finished as '$executionState' with exit code '$exitCode'."
                }
                $result = $command
                break
            }
            Start-Sleep -Seconds 5
        } while ((Get-Date) -lt $deadline)

        if ($null -eq $result) {
            throw "Run Command '$RunCommandName' on '$MachineName' did not finish within $TimeoutSeconds seconds."
        }
    } catch {
        $commandError = $_
    } finally {
        try {
            $commandsAfterRun = @(
                Get-ArcIdentityResponseItems -Response (
                    Invoke-ArcIdentityAzJson `
                        -Arguments @(
                            'connectedmachine', 'run-command', 'list',
                            '--subscription', $SubscriptionId,
                            '--resource-group', $ResourceGroupName,
                            '--machine-name', $MachineName,
                            '--output', 'json'
                        ) `
                        -FailureMessage "Unable to list Run Command resources during cleanup on '$MachineName'."
                )
            )
            if ($commandsAfterRun | Where-Object { $_.name -eq $RunCommandName }) {
                Invoke-ArcIdentityAzNoOutput `
                    -Arguments @(
                        'connectedmachine', 'run-command', 'delete',
                        '--subscription', $SubscriptionId,
                        '--resource-group', $ResourceGroupName,
                        '--machine-name', $MachineName,
                        '--name', $RunCommandName,
                        '--yes',
                        '--no-wait',
                        '--output', 'none'
                    ) `
                    -FailureMessage "Unable to remove dedicated Run Command '$RunCommandName' from '$MachineName'."

                $cleanupDeadline = (Get-Date).AddSeconds(120)
                $commandStillExists = $true
                do {
                    $remainingCommands = @(
                        Get-ArcIdentityResponseItems -Response (
                            Invoke-ArcIdentityAzJson `
                                -Arguments @(
                                    'connectedmachine', 'run-command', 'list',
                                    '--subscription', $SubscriptionId,
                                    '--resource-group', $ResourceGroupName,
                                    '--machine-name', $MachineName,
                                    '--output', 'json'
                                ) `
                                -FailureMessage "Unable to verify Run Command cleanup on '$MachineName'."
                        )
                    )
                    $commandStillExists = $null -ne ($remainingCommands | Where-Object {
                            $_.name -eq $RunCommandName
                        } | Select-Object -First 1)
                    if (-not $commandStillExists) {
                        break
                    }
                    Start-Sleep -Seconds 2
                } while ((Get-Date) -lt $cleanupDeadline)
                if ($commandStillExists) {
                    throw "Dedicated Run Command '$RunCommandName' still exists on '$MachineName' after the bounded cleanup wait."
                }
            }
        } catch {
            $cleanupError = $_
        }
    }

    if ($null -ne $commandError -and $null -ne $cleanupError) {
        throw "$($commandError.Exception.Message) Cleanup also failed: $($cleanupError.Exception.Message)"
    }
    if ($null -ne $commandError) {
        throw $commandError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
    return $result
}
