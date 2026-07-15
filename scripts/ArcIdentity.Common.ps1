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

function Get-ArcIdentitySkillAdditionalFiles {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryRoot,
        [Parameter(Mandatory)]
        [ValidateCount(1, 100)]
        [string[]] $RelativePaths
    )

    try {
        $resolvedRepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    } catch {
        throw "Unable to resolve repository root '$RepositoryRoot': $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $resolvedRepositoryRoot -PathType Container)) {
        throw "Repository root '$resolvedRepositoryRoot' does not exist."
    }

    $pathComparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    $directorySeparators = [char[]] @(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $repositoryRootPrefix = $resolvedRepositoryRoot.TrimEnd($directorySeparators) +
        [System.IO.Path]::DirectorySeparatorChar
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

    foreach ($relativePath in $RelativePaths) {
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [System.IO.Path]::IsPathFullyQualified($relativePath)) {
            throw "Required SRE Agent skill file path '$relativePath' must be a nonblank repository-relative path."
        }

        try {
            $fileSystemRelativePath = $relativePath.Replace(
                [char] '/',
                [System.IO.Path]::DirectorySeparatorChar
            )
            $resolvedFilePath = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($resolvedRepositoryRoot, $fileSystemRelativePath)
            )
        } catch {
            throw "Unable to resolve required SRE Agent skill file '$relativePath': $($_.Exception.Message)"
        }
        if (-not $resolvedFilePath.StartsWith($repositoryRootPrefix, $pathComparison)) {
            throw "Required SRE Agent skill file '$relativePath' resolves outside the repository root."
        }
        if (-not (Test-Path -LiteralPath $resolvedFilePath -PathType Leaf)) {
            throw "Required SRE Agent skill file '$relativePath' does not exist."
        }

        try {
            $content = $strictUtf8.GetString(
                [System.IO.File]::ReadAllBytes($resolvedFilePath)
            )
        } catch {
            throw "Unable to read required SRE Agent skill file '$relativePath' as UTF-8 text: $($_.Exception.Message)"
        }
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw "Required SRE Agent skill file '$relativePath' is empty."
        }

        [ordered]@{
            filePath = $relativePath
            content = $content
        }
    }
}

function Assert-ArcIdentityLogAnalyticsConnector {
    param(
        [Parameter(Mandatory)]
        [object] $Connector,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedName,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedWorkspaceResourceId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedWorkspaceName,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedIdentity
    )

    $properties = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $Connector `
        -PropertyName 'properties'
    $extendedProperties = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $properties `
        -PropertyName 'extendedProperties'
    $resource = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $extendedProperties `
        -PropertyName 'resource'
    $mismatches = [System.Collections.Generic.List[string]]::new()

    $actualName = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $Connector `
        -PropertyName 'name'
    $actualLeafName = if ($actualName -is [string]) {
        (([string] $actualName).TrimEnd('/') -split '/')[-1]
    } else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($actualLeafName) -or
        -not [string]::Equals(
            $actualLeafName,
            $ExpectedName,
            [StringComparison]::Ordinal
        )) {
        $mismatches.Add('name')
    }

    $dataConnectorType = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $properties `
        -PropertyName 'dataConnectorType'
    if ($dataConnectorType -isnot [string] -or
        [string] $dataConnectorType -cne 'LogAnalytics') {
        $mismatches.Add('dataConnectorType')
    }

    $identity = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $properties `
        -PropertyName 'identity'
    if ($identity -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string] $identity) -or
        -not [string]::Equals(
            [string] $identity,
            $ExpectedIdentity,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        $mismatches.Add('identity')
    }

    $source = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $properties `
        -PropertyName 'source'
    if ($null -ne $source -and
        ($source -isnot [string] -or [string] $source -cne 'Agent')) {
        $mismatches.Add('source')
    }

    $provisioningState = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $properties `
        -PropertyName 'provisioningState'
    if ($null -ne $provisioningState -and
        ($provisioningState -isnot [string] -or
            [string] $provisioningState -cne 'Succeeded')) {
        $mismatches.Add('provisioningState')
    }

    $deploymentError = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $properties `
        -PropertyName 'deploymentError'
    if ($null -ne $deploymentError -and
        ($deploymentError -isnot [string] -or
            [string] $deploymentError -cne '')) {
        $mismatches.Add('deploymentError')
    }

    $dataSource = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $properties `
        -PropertyName 'dataSource'
    if ($null -ne $dataSource -and
        ($dataSource -isnot [string] -or
            (-not [string]::IsNullOrWhiteSpace([string] $dataSource) -and
                -not [string]::Equals(
                    [string] $dataSource,
                    $ExpectedWorkspaceResourceId,
                    [StringComparison]::OrdinalIgnoreCase
                )))) {
        $mismatches.Add('dataSource')
    }

    $armResourceId = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $extendedProperties `
        -PropertyName 'armResourceId'
    if ($null -ne $armResourceId -and
        ($armResourceId -isnot [string] -or
            (-not [string]::IsNullOrWhiteSpace([string] $armResourceId) -and
                -not [string]::Equals(
                    [string] $armResourceId,
                    $ExpectedWorkspaceResourceId,
                    [StringComparison]::OrdinalIgnoreCase
                )))) {
        $mismatches.Add('extendedProperties.armResourceId')
    }

    $resourceName = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $resource `
        -PropertyName 'name'
    if ($null -ne $resourceName -and
        ($resourceName -isnot [string] -or
            (-not [string]::IsNullOrWhiteSpace([string] $resourceName) -and
                -not [string]::Equals(
                    [string] $resourceName,
                    $ExpectedWorkspaceName,
                    [StringComparison]::OrdinalIgnoreCase
                )))) {
        $mismatches.Add('extendedProperties.resource.name')
    }

    if ($mismatches.Count -gt 0) {
        throw "Connector '$ExpectedName' has observable mismatch(es) in $($mismatches -join ', '); refusing to accept or overwrite it."
    }
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

    $bodyJson = ConvertTo-Json -InputObject ([ordered]@{
            query = $Query
        }) -Compress
    $bodyFile = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine(
            [System.IO.Path]::GetTempPath(),
            "arc-identity-log-query-$([Guid]::NewGuid().ToString('N')).json"
        )
    )
    try {
        [System.IO.File]::WriteAllText(
            $bodyFile,
            $bodyJson,
            [System.Text.UTF8Encoding]::new($false)
        )
        $bodyFileArgument = "@$bodyFile"
        $response = Invoke-ArcIdentityAzJson `
            -Arguments @(
                'rest',
                '--method', 'post',
                '--subscription', $SubscriptionId,
                '--url', "https://api.loganalytics.azure.com/v1/workspaces/$WorkspaceCustomerId/query",
                '--resource', 'https://api.loganalytics.io',
                '--headers', 'Content-Type=application/json',
                '--body', $bodyFileArgument,
                '--output', 'json'
            ) `
            -FailureMessage 'Unable to query the ArcBox Log Analytics workspace.'
    } finally {
        $bodyJson = $null
        if (Test-Path -LiteralPath $bodyFile -PathType Leaf) {
            Remove-Item -LiteralPath $bodyFile -Force
        }
    }

    $tablesProperty = $response.PSObject.Properties['tables']
    if ($null -eq $tablesProperty -or
        $tablesProperty.Value -isnot [array] -or
        $tablesProperty.Value.Count -ne 1) {
        throw 'Log Analytics query response must contain exactly one PrimaryResult table.'
    }
    $primaryTable = $tablesProperty.Value[0]
    $tableNameProperty = $primaryTable.PSObject.Properties['name']
    if ($null -eq $tableNameProperty -or
        $tableNameProperty.Value -isnot [string] -or
        $tableNameProperty.Value -cne 'PrimaryResult') {
        throw 'Log Analytics query response must contain exactly one PrimaryResult table.'
    }
    $columnsProperty = $primaryTable.PSObject.Properties['columns']
    $rowsProperty = $primaryTable.PSObject.Properties['rows']
    if ($null -eq $columnsProperty -or
        $columnsProperty.Value -isnot [array] -or
        $columnsProperty.Value.Count -eq 0 -or
        $null -eq $rowsProperty -or
        $rowsProperty.Value -isnot [array]) {
        throw 'Log Analytics PrimaryResult table must contain a nonempty columns array and a rows array.'
    }

    $columnNameSet = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $columnNames = [System.Collections.Generic.List[string]]::new()
    foreach ($column in $columnsProperty.Value) {
        $columnName = [string] (
            Get-ArcIdentityOptionalPropertyValue -InputObject $column -PropertyName 'name'
        )
        if ([string]::IsNullOrWhiteSpace($columnName)) {
            throw 'Log Analytics query response contained an unnamed column.'
        }
        if (-not $columnNameSet.Add($columnName)) {
            throw "Log Analytics query response contained duplicate column '$columnName'."
        }
        $columnNames.Add($columnName)
    }
    $queryRows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rowsProperty.Value) {
        if ($row -isnot [array]) {
            throw 'Log Analytics query response row must be an array.'
        }
        if ($row.Count -ne $columnNames.Count) {
            throw 'Log Analytics query response row did not match its column count.'
        }
        $rowProperties = [ordered]@{}
        for ($index = 0; $index -lt $columnNames.Count; $index++) {
            $columnName = $columnNames[$index]
            $rowProperties[$columnName] = $row[$index]
        }
        $queryRows.Add([pscustomobject] $rowProperties)
    }
    return $queryRows.ToArray()
}

function Get-ArcIdentitySyntheticTargetResources {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [ValidateCount(2, 2)]
        [string[]] $MachineNames
    )

    $allowedResourceIds = [ordered]@{
        'ArcBox-Win2K22' = '/subscriptions/5305e853-a63b-4b82-9a3f-6fde18c1a798/resourceGroups/rg-arcbox-itpro-weu-002/providers/Microsoft.HybridCompute/machines/ArcBox-Win2K22'
        'ArcBox-Win2K25' = '/subscriptions/5305e853-a63b-4b82-9a3f-6fde18c1a798/resourceGroups/rg-arcbox-itpro-weu-002/providers/Microsoft.HybridCompute/machines/ArcBox-Win2K25'
    }
    $allowedResourceIdSet = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($allowedResourceId in $allowedResourceIds.Values) {
        $null = $allowedResourceIdSet.Add([string] $allowedResourceId)
    }

    $requestedResourceIdSet = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($machineName in $MachineNames) {
        if ([string]::IsNullOrWhiteSpace($machineName)) {
            throw 'Synthetic target machine names must be nonblank.'
        }
        $requestedResourceId = Get-ArcIdentityMachineResourceId `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -MachineName $machineName
        if (-not $allowedResourceIdSet.Contains($requestedResourceId)) {
            throw "Synthetic target resource ID '$requestedResourceId' is not allowlisted."
        }
        if (-not $requestedResourceIdSet.Add($requestedResourceId)) {
            throw "Synthetic target resource ID '$requestedResourceId' was requested more than once."
        }
        $canonicalMachineName = @(
            $allowedResourceIds.Keys | Where-Object {
                [string]::Equals(
                    [string] $allowedResourceIds[$_],
                    $requestedResourceId,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
        )[0]
        $targets.Add([pscustomobject]@{
                MachineName = [string] $canonicalMachineName
                ResourceId = [string] $allowedResourceIds[$canonicalMachineName]
                NormalizedResourceId = ([string] $allowedResourceIds[$canonicalMachineName]).ToLowerInvariant()
            })
    }
    if ($requestedResourceIdSet.Count -ne $allowedResourceIdSet.Count) {
        throw 'Exactly the two allowlisted synthetic Arc machine resource IDs are required.'
    }
    return $targets.ToArray()
}

function ConvertTo-ArcIdentitySyntheticEventCountRows {
    param(
        [AllowNull()]
        [object[]] $Rows,
        [Parameter(Mandatory)]
        [ValidateCount(2, 2)]
        [string[]] $TargetResourceIds
    )

    $targetByNormalizedId = [System.Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($targetResourceId in $TargetResourceIds) {
        if ([string]::IsNullOrWhiteSpace($targetResourceId)) {
            throw 'Synthetic target resource IDs must be nonblank.'
        }
        if (-not $targetByNormalizedId.TryAdd(
                $targetResourceId.ToLowerInvariant(),
                $targetResourceId
            )) {
            throw "Synthetic target resource ID '$targetResourceId' was supplied more than once."
        }
    }

    $countByNormalizedId = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($row in @($Rows)) {
        if ($null -eq $row) {
            throw 'Log Analytics synthetic event count rows must not contain null entries.'
        }
        $resourceIdValue = Get-ArcIdentityOptionalPropertyValue `
            -InputObject $row `
            -PropertyName 'ResourceId'
        if ($resourceIdValue -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string] $resourceIdValue)) {
            throw 'Log Analytics synthetic event count row did not expose a nonblank ResourceId.'
        }
        $normalizedResourceId = ([string] $resourceIdValue).ToLowerInvariant()
        if (-not $targetByNormalizedId.ContainsKey($normalizedResourceId)) {
            throw "Log Analytics returned non-allowlisted synthetic resource ID '$resourceIdValue'."
        }
        if ($countByNormalizedId.ContainsKey($normalizedResourceId)) {
            throw "Log Analytics returned duplicate synthetic event count rows for '$resourceIdValue'."
        }

        $counts = [ordered]@{}
        foreach ($propertyName in @('IncidentCount', 'RecoveryCount')) {
            $countValue = Get-ArcIdentityOptionalPropertyValue `
                -InputObject $row `
                -PropertyName $propertyName
            $parsedCount = 0L
            if ($null -eq $countValue -or
                -not [long]::TryParse(
                    [string] $countValue,
                    [Globalization.NumberStyles]::Integer,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref] $parsedCount
                ) -or
                $parsedCount -lt 0) {
                throw "Log Analytics synthetic event count row for '$resourceIdValue' has invalid $propertyName."
            }
            $counts[$propertyName] = $parsedCount
        }
        $countByNormalizedId.Add(
            $normalizedResourceId,
            [pscustomobject]@{
                ResourceId = $targetByNormalizedId[$normalizedResourceId]
                NormalizedResourceId = $normalizedResourceId
                IncidentCount = [long] $counts.IncidentCount
                RecoveryCount = [long] $counts.RecoveryCount
            }
        )
    }

    $mappedRows = [System.Collections.Generic.List[object]]::new()
    foreach ($targetResourceId in $TargetResourceIds) {
        $normalizedResourceId = $targetResourceId.ToLowerInvariant()
        if ($countByNormalizedId.ContainsKey($normalizedResourceId)) {
            $mappedRows.Add($countByNormalizedId[$normalizedResourceId])
            continue
        }
        $mappedRows.Add([pscustomobject]@{
                ResourceId = $targetResourceId
                NormalizedResourceId = $normalizedResourceId
                IncidentCount = 0L
                RecoveryCount = 0L
            })
    }
    return $mappedRows.ToArray()
}

function Get-ArcIdentitySyntheticEventCountRows {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceCustomerId,
        [Parameter(Mandatory)]
        [ValidatePattern('^SYNTH-ID-[0-9]{8}T[0-9]{6}Z-[A-F0-9]{8}$')]
        [string] $CorrelationId,
        [Parameter(Mandatory)]
        [ValidateCount(2, 2)]
        [object[]] $TargetResources
    )

    $correlationTimestamp = [DateTimeOffset]::ParseExact(
        $CorrelationId.Substring(9, 16),
        "yyyyMMdd'T'HHmmss'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
    $correlationHourUtc = [DateTimeOffset]::new(
        $correlationTimestamp.Year,
        $correlationTimestamp.Month,
        $correlationTimestamp.Day,
        $correlationTimestamp.Hour,
        0,
        0,
        [TimeSpan]::Zero
    ).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
    $targetResourceIds = [System.Collections.Generic.List[string]]::new()
    $normalizedResourceIdLiterals = [System.Collections.Generic.List[string]]::new()
    foreach ($targetResource in $TargetResources) {
        $resourceId = Get-ArcIdentityOptionalPropertyValue `
            -InputObject $targetResource `
            -PropertyName 'ResourceId'
        $normalizedResourceId = Get-ArcIdentityOptionalPropertyValue `
            -InputObject $targetResource `
            -PropertyName 'NormalizedResourceId'
        if ($resourceId -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string] $resourceId) -or
            $normalizedResourceId -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string] $normalizedResourceId) -or
            -not [string]::Equals(
                ([string] $resourceId).ToLowerInvariant(),
                [string] $normalizedResourceId,
                [StringComparison]::Ordinal
            )) {
            throw 'Synthetic target resource mapping is missing an exact normalized resource ID.'
        }
        $targetResourceIds.Add([string] $resourceId)
        $normalizedResourceIdLiterals.Add("""$normalizedResourceId""")
    }
    $resourceIdList = $normalizedResourceIdLiterals -join ', '
    $query = @"
Event
| where TimeGenerated >= datetime($correlationHourUtc)
| where EventLog == "Application" and Source == "Mercadona.IdentityOps"
| where EventID in (4101, 4102)
| where tolower(_ResourceId) in ($resourceIdList)
| extend SyntheticPayload = parse_json(RenderedDescription)
| where tobool(SyntheticPayload.demoSynthetic) == true
| where tostring(SyntheticPayload.correlationId) == "$CorrelationId"
| where tostring(SyntheticPayload.scenario) == "adfs-token-failure-burst"
| where (EventID == 4101 and tostring(SyntheticPayload.eventType) == "SyntheticAdfsTokenFailure")
    or (EventID == 4102 and tostring(SyntheticPayload.eventType) == "SyntheticAdfsRecovery")
| summarize IncidentCount=countif(EventID == 4101), RecoveryCount=countif(EventID == 4102)
    by ResourceId=tolower(_ResourceId)
"@
    $rows = @(
        Invoke-ArcIdentityLogAnalyticsQuery `
            -SubscriptionId $SubscriptionId `
            -WorkspaceCustomerId $WorkspaceCustomerId `
            -Query $query
    )
    return @(
        ConvertTo-ArcIdentitySyntheticEventCountRows `
            -Rows $rows `
            -TargetResourceIds $targetResourceIds.ToArray()
    )
}

function Resolve-ArcIdentitySyntheticEventState {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Start', 'Recover')]
        [string] $Operation,
        [Parameter(Mandatory)]
        [int] $LocalIncidentCount,
        [Parameter(Mandatory)]
        [int] $LocalRecoveryCount,
        [Parameter(Mandatory)]
        [int] $AuthoritativeIncidentCount,
        [Parameter(Mandatory)]
        [int] $AuthoritativeRecoveryCount,
        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int] $IncidentBound,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CorrelationId
    )

    foreach ($count in @(
            $LocalIncidentCount,
            $LocalRecoveryCount,
            $AuthoritativeIncidentCount,
            $AuthoritativeRecoveryCount
        )) {
        if ($count -lt 0) {
            throw "Synthetic event counts for correlation '$CorrelationId' must not be negative."
        }
    }
    if ($Operation -eq 'Start') {
        if ($LocalIncidentCount -gt $IncidentBound) {
            throw "Local Application log has $LocalIncidentCount incident events for correlation '$CorrelationId', above the bounded count $IncidentBound."
        }
        if ($AuthoritativeIncidentCount -gt $IncidentBound) {
            throw "Log Analytics has $AuthoritativeIncidentCount incident events for correlation '$CorrelationId', above the bounded count $IncidentBound."
        }
        if ($LocalRecoveryCount -gt 0 -or $AuthoritativeRecoveryCount -gt 0) {
            throw "Correlation '$CorrelationId' already has a synthetic recovery event; refusing to reopen it."
        }
    } else {
        if ($AuthoritativeIncidentCount -eq 0) {
            throw "Log Analytics has no authoritative synthetic incident event for correlation '$CorrelationId'."
        }
        if ($LocalRecoveryCount -gt 1) {
            throw "Local Application log has more than one synthetic recovery event for correlation '$CorrelationId'."
        }
        if ($AuthoritativeRecoveryCount -gt 1) {
            throw "Log Analytics has more than one synthetic recovery event for correlation '$CorrelationId'."
        }
    }

    $existingIncidentCount = [Math]::Max(
        $LocalIncidentCount,
        $AuthoritativeIncidentCount
    )
    $existingRecoveryCount = [Math]::Max(
        $LocalRecoveryCount,
        $AuthoritativeRecoveryCount
    )
    $emitCount = if ($Operation -eq 'Start') {
        $IncidentBound - $existingIncidentCount
    } elseif ($existingRecoveryCount -eq 0) {
        1
    } else {
        0
    }
    return [pscustomobject]@{
        ExistingIncidentCount = $existingIncidentCount
        ExistingRecoveryCount = $existingRecoveryCount
        EmitCount = $emitCount
    }
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

function Format-ArcIdentitySreAgentApiError {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(100, 599)]
        [int] $StatusCode,
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ReasonPhrase,
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ResponseBody,
        [ValidateRange(1, 65536)]
        [int] $MaxResponseBodyBytes = 4096,
        [switch] $ResponseBodyReadFailed
    )

    $status = "HTTP $StatusCode"
    if (-not [string]::IsNullOrWhiteSpace($ReasonPhrase)) {
        $status += " ($($ReasonPhrase.Trim()))"
    }
    $prefix = "Azure SRE Agent data-plane request failed with $status."
    if ($ResponseBodyReadFailed) {
        return "$prefix Response body could not be read."
    }
    if ([string]::IsNullOrWhiteSpace($ResponseBody)) {
        return "$prefix Response body was empty."
    }

    $responseDetails = $ResponseBody.Trim()
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    if ($utf8.GetByteCount($responseDetails) -gt $MaxResponseBodyBytes) {
        $characters = $responseDetails.ToCharArray()
        $bytes = [byte[]]::new($MaxResponseBodyBytes)
        $charactersUsed = 0
        $bytesUsed = 0
        $completed = $false
        $utf8.GetEncoder().Convert(
            $characters,
            0,
            $characters.Length,
            $bytes,
            0,
            $bytes.Length,
            $true,
            [ref] $charactersUsed,
            [ref] $bytesUsed,
            [ref] $completed
        )
        $responseDetails = $utf8.GetString($bytes, 0, $bytesUsed) +
            " [truncated at $MaxResponseBodyBytes UTF-8 bytes]"
    }
    return "$prefix Response body: $responseDetails"
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
        $responseBody = $null
        $responseBodyReadError = $null
        if ($null -ne $response.Content) {
            try {
                $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            } catch {
                $responseBodyReadError = $_.Exception
            }
        }
        if (-not $response.IsSuccessStatusCode) {
            throw (Format-ArcIdentitySreAgentApiError `
                    -StatusCode ([int] $response.StatusCode) `
                    -ReasonPhrase $response.ReasonPhrase `
                    -ResponseBody $responseBody `
                    -ResponseBodyReadFailed:($null -ne $responseBodyReadError))
        }
        if ($null -ne $responseBodyReadError) {
            throw "Azure SRE Agent data-plane request returned HTTP $([int] $response.StatusCode), but its response body could not be read."
        }
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

    $machine = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'connectedmachine', 'show',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--name', $MachineName,
            '--output', 'json'
        ) `
        -FailureMessage "Unable to read Arc machine '$MachineName' before creating its Run Command."
    $machineResourceId = Get-ArcIdentityMachineResourceId `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -MachineName $MachineName
    $machineLocation = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $machine `
        -PropertyName 'location'
    if ([string]::IsNullOrWhiteSpace([string] $machineLocation)) {
        throw "Arc machine '$MachineName' must expose a nonblank location for Run Command creation."
    }

    $runCommandUrl = "https://management.azure.com${machineResourceId}/runCommands/${RunCommandName}?api-version=2025-01-13"
    $runCommandBody = [ordered]@{
        location = [string] $machineLocation
        properties = [ordered]@{
            source = [ordered]@{
                script = $ScriptText
            }
            timeoutInSeconds = $TimeoutSeconds
            asyncExecution = $false
        }
    }
    $commandError = $null
    $cleanupError = $null
    $result = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    try {
        Invoke-ArcIdentityArmRestWithJsonBody `
            -Method 'put' `
            -Url $runCommandUrl `
            -Headers @('Content-Type=application/json') `
            -Body $runCommandBody `
            -Output 'none' `
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
            $source = Get-ArcIdentityFirstPropertyValue `
                -InputObjects @($command, $properties) `
                -PropertyNames @('source')
            $persistedScript = Get-ArcIdentityOptionalPropertyValue `
                -InputObject $source `
                -PropertyName 'script'
            if ($null -eq $persistedScript -or
                -not [string]::Equals(
                    [string] $persistedScript,
                    $ScriptText,
                    [StringComparison]::Ordinal
                )) {
                throw "Run Command '$RunCommandName' on '$MachineName' did not preserve the exact requested script."
            }
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
