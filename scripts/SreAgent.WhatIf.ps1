#requires -Version 7.2

Set-StrictMode -Version Latest

function Get-SreAgentWhatIfProperty {
    param(
        [AllowNull()]
        [object] $InputObject,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return [pscustomobject]@{ Found = $false; Value = $null }
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return [pscustomobject]@{ Found = $true; Value = $InputObject[$Name] }
        }
        return [pscustomobject]@{ Found = $false; Value = $null }
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return [pscustomobject]@{ Found = $false; Value = $null }
    }
    return [pscustomobject]@{ Found = $true; Value = $property.Value }
}

function ConvertTo-SreAgentNormalizedResourceId {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceId
    )

    return $ResourceId.Trim().TrimEnd('/').ToLowerInvariant()
}

function Get-SreAgentManagedResourcesState {
    param(
        [AllowNull()]
        [object] $AgentPayload
    )

    $properties = Get-SreAgentWhatIfProperty -InputObject $AgentPayload -Name 'properties'
    if (-not $properties.Found) {
        return [pscustomobject]@{ Found = $false; Values = @() }
    }
    $knowledgeGraph = Get-SreAgentWhatIfProperty `
        -InputObject $properties.Value `
        -Name 'knowledgeGraphConfiguration'
    if (-not $knowledgeGraph.Found) {
        return [pscustomobject]@{ Found = $false; Values = @() }
    }
    $managedResources = Get-SreAgentWhatIfProperty `
        -InputObject $knowledgeGraph.Value `
        -Name 'managedResources'
    if (-not $managedResources.Found) {
        return [pscustomobject]@{ Found = $false; Values = @() }
    }

    return [pscustomobject]@{
        Found = $true
        Values = @($managedResources.Value)
    }
}

function Assert-SreAgentManagedResourcesPresent {
    param(
        [AllowNull()]
        [object[]] $ManagedResources,
        [Parameter(Mandatory)]
        [ValidateCount(1, 100)]
        [string[]] $RequiredManagedResourceIds,
        [Parameter(Mandatory)]
        [string] $Context
    )

    $actual = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($managedResource in @($ManagedResources)) {
        if (-not [string]::IsNullOrWhiteSpace([string] $managedResource)) {
            $null = $actual.Add(
                (ConvertTo-SreAgentNormalizedResourceId -ResourceId ([string] $managedResource))
            )
        }
    }

    $missing = foreach ($requiredResourceId in $RequiredManagedResourceIds) {
        $normalizedRequiredId = ConvertTo-SreAgentNormalizedResourceId `
            -ResourceId $requiredResourceId
        if (-not $actual.Contains($normalizedRequiredId)) {
            $requiredResourceId
        }
    }
    if (@($missing).Count -gt 0) {
        throw "$Context would remove required SRE Agent managed resource IDs: $(@($missing) -join ', ')."
    }
}

function Get-SreAgentWhatIfDeltaNodes {
    param(
        [AllowNull()]
        [object[]] $Nodes,
        [string] $ParentPath = ''
    )

    foreach ($node in @($Nodes)) {
        if ($null -eq $node) {
            continue
        }
        $pathState = Get-SreAgentWhatIfProperty -InputObject $node -Name 'path'
        $path = if ($pathState.Found) { [string] $pathState.Value } else { '' }
        $fullPath = if ([string]::IsNullOrWhiteSpace($ParentPath) -or
            $path -match '^properties\.') {
            $path
        } elseif ([string]::IsNullOrWhiteSpace($path)) {
            $ParentPath
        } else {
            "$ParentPath.$path"
        }

        [pscustomobject]@{
            Node = $node
            FullPath = $fullPath
            ParentPath = $ParentPath
        }

        $children = Get-SreAgentWhatIfProperty -InputObject $node -Name 'children'
        if ($children.Found -and $null -ne $children.Value) {
            Get-SreAgentWhatIfDeltaNodes -Nodes @($children.Value) -ParentPath $fullPath
        }
    }
}

function Assert-SreAgentManagedResourceDeltaSafe {
    param(
        [AllowNull()]
        [object[]] $Delta,
        [Parameter(Mandatory)]
        [string[]] $RequiredManagedResourceIds
    )

    $knowledgeGraphPath = 'properties.knowledgeGraphConfiguration'
    $managedResourcesPath = 'properties.knowledgeGraphConfiguration.managedResources'
    $normalizedRequiredIds = @(
        $RequiredManagedResourceIds |
            ForEach-Object { ConvertTo-SreAgentNormalizedResourceId -ResourceId $_ }
    )

    foreach ($entry in @(Get-SreAgentWhatIfDeltaNodes -Nodes $Delta)) {
        $node = $entry.Node
        $changeTypeState = Get-SreAgentWhatIfProperty `
            -InputObject $node `
            -Name 'propertyChangeType'
        $propertyChangeType = if ($changeTypeState.Found) {
            [string] $changeTypeState.Value
        } else {
            ''
        }
        $isKnowledgeGraphNode = [string]::Equals(
            $entry.FullPath,
            $knowledgeGraphPath,
            [StringComparison]::OrdinalIgnoreCase
        )
        $isManagedResourcesNode = [string]::Equals(
            $entry.FullPath,
            $managedResourcesPath,
            [StringComparison]::OrdinalIgnoreCase
        )
        $isManagedResourcesChild = $entry.FullPath.StartsWith(
            "$managedResourcesPath.",
            [StringComparison]::OrdinalIgnoreCase
        )
        if (-not $isKnowledgeGraphNode -and
            -not $isManagedResourcesNode -and
            -not $isManagedResourcesChild) {
            continue
        }

        $before = Get-SreAgentWhatIfProperty -InputObject $node -Name 'before'
        $after = Get-SreAgentWhatIfProperty -InputObject $node -Name 'after'
        if ($isKnowledgeGraphNode -and $propertyChangeType -eq 'Delete') {
            throw 'Deployment what-if would delete the SRE Agent knowledgeGraphConfiguration property.'
        }
        if ($isKnowledgeGraphNode -and
            $propertyChangeType -in @('Create', 'Modify') -and
            $after.Found) {
            $managedResources = Get-SreAgentWhatIfProperty `
                -InputObject $after.Value `
                -Name 'managedResources'
            if (-not $managedResources.Found) {
                throw 'Deployment what-if knowledgeGraphConfiguration replacement did not contain managedResources.'
            }
            Assert-SreAgentManagedResourcesPresent `
                -ManagedResources @($managedResources.Value) `
                -RequiredManagedResourceIds $RequiredManagedResourceIds `
                -Context 'Deployment what-if knowledgeGraphConfiguration replacement'
        }
        if ($isManagedResourcesNode -and $propertyChangeType -eq 'Delete') {
            throw 'Deployment what-if would delete the SRE Agent managedResources property.'
        }
        if ($isManagedResourcesNode -and
            $propertyChangeType -in @('Create', 'Modify') -and
            $after.Found) {
            Assert-SreAgentManagedResourcesPresent `
                -ManagedResources @($after.Value) `
                -RequiredManagedResourceIds $RequiredManagedResourceIds `
                -Context 'Deployment what-if managedResources replacement'
        }
        if ($propertyChangeType -in @('Delete', 'Modify') -and
            $before.Found -and
            $null -ne $before.Value -and
            ($before.Value -is [string] -or
                $before.Value -isnot [System.Collections.IEnumerable])) {
            $normalizedBefore = ConvertTo-SreAgentNormalizedResourceId `
                -ResourceId ([string] $before.Value)
            $normalizedAfter = if ($after.Found -and
                -not [string]::IsNullOrWhiteSpace([string] $after.Value)) {
                ConvertTo-SreAgentNormalizedResourceId -ResourceId ([string] $after.Value)
            } else {
                ''
            }
            if ($normalizedBefore -in $normalizedRequiredIds -and
                $normalizedAfter -ne $normalizedBefore) {
                throw "Deployment what-if would remove required SRE Agent managed resource ID '$($before.Value)'."
            }
        }
    }
}

function Test-SreAgentUnsupportedRoleAssignment {
    param(
        [Parameter(Mandatory)]
        [object] $Change,
        [Parameter(Mandatory)]
        [string] $ResourceId,
        [Parameter(Mandatory)]
        [string] $ChangeType
    )

    if (-not [string]::Equals(
            $ChangeType,
            'Unsupported',
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $ResourceId -notmatch '(?i)/providers/Microsoft\.Authorization/roleAssignments/[^/]+$') {
        return $false
    }

    $expectedType = 'Microsoft.Authorization/roleAssignments'
    $payloads = [System.Collections.Generic.List[object]]::new()
    $payloads.Add($Change)
    foreach ($propertyName in @('before', 'after')) {
        $payloadState = Get-SreAgentWhatIfProperty `
            -InputObject $Change `
            -Name $propertyName
        if ($payloadState.Found -and $null -ne $payloadState.Value) {
            $payloads.Add($payloadState.Value)
        }
    }
    foreach ($payload in $payloads) {
        $typeState = Get-SreAgentWhatIfProperty -InputObject $payload -Name 'type'
        if ($typeState.Found -and
            (-not [string]::Equals(
                    [string] $typeState.Value,
                    $expectedType,
                    [StringComparison]::OrdinalIgnoreCase
                ))) {
            return $false
        }
    }

    return $true
}

function Assert-SreAgentWhatIfChangeSafe {
    param(
        [Parameter(Mandatory)]
        [object] $Change,
        [Parameter(Mandatory)]
        [bool] $IsPotential,
        [Parameter(Mandatory)]
        [string] $AgentResourceId,
        [Parameter(Mandatory)]
        [string] $ArcResourceGroupId,
        [Parameter(Mandatory)]
        [string[]] $RequiredManagedResourceIds
    )

    $resourceIdState = Get-SreAgentWhatIfProperty -InputObject $Change -Name 'resourceId'
    $changeTypeState = Get-SreAgentWhatIfProperty -InputObject $Change -Name 'changeType'
    $resourceId = if ($resourceIdState.Found) { [string] $resourceIdState.Value } else { '' }
    $changeType = if ($changeTypeState.Found) { [string] $changeTypeState.Value } else { '' }
    $changeKind = if ($IsPotential) { 'potential change' } else { 'change' }
    if ([string]::IsNullOrWhiteSpace($resourceId) -or
        [string]::IsNullOrWhiteSpace($changeType)) {
        throw "Deployment what-if $changeKind did not contain nonblank resourceId and changeType values."
    }

    $normalizedResourceId = ConvertTo-SreAgentNormalizedResourceId -ResourceId $resourceId
    $normalizedAgentResourceId = ConvertTo-SreAgentNormalizedResourceId `
        -ResourceId $AgentResourceId
    $normalizedArcResourceGroupId = ConvertTo-SreAgentNormalizedResourceId `
        -ResourceId $ArcResourceGroupId
    $isAgent = $normalizedResourceId -eq $normalizedAgentResourceId
    $isAgentChild = $normalizedResourceId.StartsWith(
        "$normalizedAgentResourceId/",
        [StringComparison]::OrdinalIgnoreCase
    )
    $isArcScope = $normalizedResourceId -eq $normalizedArcResourceGroupId -or
        $normalizedResourceId.StartsWith(
            "$normalizedArcResourceGroupId/",
            [StringComparison]::OrdinalIgnoreCase
        )
    $isAllowedUnsupportedRoleAssignment = Test-SreAgentUnsupportedRoleAssignment `
        -Change $Change `
        -ResourceId $resourceId `
        -ChangeType $changeType

    if ($isAllowedUnsupportedRoleAssignment) {
        return
    }
    if ($isArcScope -and
        ($IsPotential -or
            $changeType -in @('Create', 'Delete', 'Deploy', 'Modify', 'Unsupported'))) {
        throw "Deployment what-if contains unexpected Arc-scope $changeType for '$resourceId'."
    }
    if ($IsPotential -and $isAgentChild) {
        throw "Deployment what-if contains unexpected SRE Agent child potential change $changeType for '$resourceId'."
    }
    if (-not $isAgent) {
        return
    }
    if ($changeType -eq 'Delete') {
        throw "Deployment what-if would delete SRE Agent '$AgentResourceId'."
    }
    if ($changeType -eq 'Unsupported') {
        throw "Deployment what-if could not evaluate SRE Agent '$AgentResourceId'."
    }
    if ($changeType -notin @('Create', 'Deploy', 'Modify')) {
        if ($IsPotential) {
            throw "Deployment what-if contains unsupported SRE Agent potential change type '$changeType'."
        }
        return
    }

    $afterState = Get-SreAgentWhatIfProperty -InputObject $Change -Name 'after'
    if ($afterState.Found -and $null -ne $afterState.Value) {
        $managedResources = Get-SreAgentManagedResourcesState `
            -AgentPayload $afterState.Value
        if (-not $managedResources.Found) {
            throw 'Deployment what-if SRE Agent payload did not contain managedResources.'
        }
        Assert-SreAgentManagedResourcesPresent `
            -ManagedResources $managedResources.Values `
            -RequiredManagedResourceIds $RequiredManagedResourceIds `
            -Context 'Deployment what-if SRE Agent payload'
    } elseif ($changeType -in @('Create', 'Deploy')) {
        throw 'Deployment what-if did not expose the created SRE Agent payload.'
    }

    $deltaState = Get-SreAgentWhatIfProperty -InputObject $Change -Name 'delta'
    if ($deltaState.Found -and $null -ne $deltaState.Value) {
        if ($deltaState.Value -isnot [System.Collections.IList]) {
            throw "Deployment what-if SRE Agent $changeKind delta was not an array."
        }
        Assert-SreAgentManagedResourceDeltaSafe `
            -Delta @($deltaState.Value) `
            -RequiredManagedResourceIds $RequiredManagedResourceIds
    } elseif ($IsPotential -and
        (-not $afterState.Found -or $null -eq $afterState.Value)) {
        throw 'Deployment what-if SRE Agent potential change did not expose an after payload or delta.'
    }
}

function Format-SreAgentWhatIfStreamExcerpt {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Label,
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Content,
        [ValidateRange(1, 65536)]
        [int] $MaxCharacters = 2000
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return "$Label was empty."
    }

    $excerpt = $Content.Trim()
    $isTruncated = $excerpt.Length -gt $MaxCharacters
    if ($isTruncated) {
        $excerpt = $excerpt.Substring(0, $MaxCharacters)
    }
    $excerpt = [regex]::Replace(
        $excerpt,
        '(?i)(instrumentationkey|accountkey|sharedaccesskey|primarykey|secondarykey|password|pwd|clientsecret|client_secret|apikey|api_key|accesstoken|access_token|refreshtoken|token|secret|sig)("?\s*[=:]\s*"?)[^"\s,;&}]+',
        '$1$2[redacted]'
    )
    $excerpt = [regex]::Replace($excerpt, '\s+', ' ').Trim()
    if ($excerpt.Length -gt $MaxCharacters) {
        $excerpt = $excerpt.Substring(0, $MaxCharacters)
        $isTruncated = $true
    }
    if ($isTruncated) {
        $excerpt += " [truncated at $MaxCharacters characters]"
    }
    return "${Label}: $excerpt"
}

function Invoke-SreAgentWhatIfJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateCount(1, 200)]
        [string[]] $Arguments,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DeploymentName,
        [ValidateRange(1, 65536)]
        [int] $MaxExcerptCharacters = 2000
    )

    foreach ($requiredArgument in @('what-if', '--no-pretty-print')) {
        if ($requiredArgument -notin $Arguments) {
            throw "Deployment what-if for '$DeploymentName' must be invoked with '$requiredArgument'."
        }
    }

    $standardErrorPath = [System.IO.Path]::GetTempFileName()
    try {
        # Keep the explicit exit-code check below reachable. Under
        # $ErrorActionPreference 'Stop', PowerShell 7.4+ turns a nonzero native exit code
        # into a terminating NativeCommandExitException when
        # $PSNativeCommandUseErrorActionPreference is enabled, and Windows PowerShell turns
        # native stderr output into a terminating NativeCommandError. Either one would
        # bypass the diagnostic excerpts below. Both overrides are function-scoped.
        $PSNativeCommandUseErrorActionPreference = $false
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $standardOutput = & az @Arguments 2> $standardErrorPath
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $standardOutputText = @(
            @($standardOutput) | ForEach-Object { [string] $_ }
        ) -join [Environment]::NewLine
        $standardErrorText = ''
        if (Test-Path -LiteralPath $standardErrorPath -PathType Leaf) {
            $standardErrorText = [string] (
                Get-Content -LiteralPath $standardErrorPath -Raw -ErrorAction SilentlyContinue
            )
        }
        $formatDiagnostic = {
            @(
                (Format-SreAgentWhatIfStreamExcerpt `
                        -Label 'az stdout' `
                        -Content $standardOutputText `
                        -MaxCharacters $MaxExcerptCharacters),
                (Format-SreAgentWhatIfStreamExcerpt `
                        -Label 'az stderr' `
                        -Content $standardErrorText `
                        -MaxCharacters $MaxExcerptCharacters)
            ) -join ' '
        }

        if ($exitCode -ne 0) {
            throw "Deployment what-if failed for '$DeploymentName' with exit code $exitCode. $(& $formatDiagnostic)"
        }

        $whatIf = $null
        $parseError = ''
        if (-not [string]::IsNullOrWhiteSpace($standardOutputText)) {
            try {
                $whatIf = $standardOutputText | ConvertFrom-Json -Depth 100
            } catch {
                $parseError = " Parse error: $($_.Exception.Message)"
            }
        }
        if ($null -eq $whatIf -or
            $whatIf -is [string] -or
            $whatIf -is [System.ValueType]) {
            throw "Deployment what-if for '$DeploymentName' did not return valid JSON.$parseError $(& $formatDiagnostic)"
        }

        return $whatIf
    } finally {
        if (Test-Path -LiteralPath $standardErrorPath -PathType Leaf) {
            Remove-Item -LiteralPath $standardErrorPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-SreAgentWhatIfSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $WhatIf,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AgentResourceId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ArcResourceGroupId,
        [Parameter(Mandatory)]
        [ValidateCount(2, 100)]
        [string[]] $RequiredManagedResourceIds
    )

    $propertiesState = Get-SreAgentWhatIfProperty -InputObject $WhatIf -Name 'properties'
    $containers = [System.Collections.Generic.List[object]]::new()
    $containers.Add([pscustomobject]@{ Name = 'root'; Value = $WhatIf })
    if ($propertiesState.Found -and $null -ne $propertiesState.Value) {
        $containers.Add([pscustomobject]@{
                Name = 'properties'
                Value = $propertiesState.Value
            })
    }

    $changeCollections = [System.Collections.Generic.List[object]]::new()
    foreach ($container in $containers) {
        foreach ($collectionName in @('changes', 'potentialChanges')) {
            $collectionState = Get-SreAgentWhatIfProperty `
                -InputObject $container.Value `
                -Name $collectionName
            if (-not $collectionState.Found) {
                continue
            }
            if ($null -eq $collectionState.Value -and
                $collectionName -eq 'potentialChanges') {
                continue
            }
            if ($null -eq $collectionState.Value -or
                $collectionState.Value -isnot [System.Collections.IList]) {
                throw "Deployment what-if $($container.Name).$collectionName was not an array."
            }
            $changeCollections.Add([pscustomobject]@{
                    Name = "$($container.Name).$collectionName"
                    IsPotential = $collectionName -eq 'potentialChanges'
                    Value = $collectionState.Value
                })
        }
    }
    if (-not ($changeCollections | Where-Object { -not $_.IsPotential })) {
        throw 'Deployment what-if JSON did not contain a changes array.'
    }

    foreach ($collection in $changeCollections) {
        foreach ($change in @($collection.Value)) {
            if ($null -eq $change -or
                $change -is [string] -or
                $change -is [System.ValueType]) {
                throw "Deployment what-if $($collection.Name) contained a malformed entry."
            }
            Assert-SreAgentWhatIfChangeSafe `
                -Change $change `
                -IsPotential $collection.IsPotential `
                -AgentResourceId $AgentResourceId `
                -ArcResourceGroupId $ArcResourceGroupId `
                -RequiredManagedResourceIds $RequiredManagedResourceIds
        }
    }
}
