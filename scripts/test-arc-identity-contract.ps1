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
$retailConfigureSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'configure-sre-agent.ps1') -Raw
Assert-Contains -Source $retailConfigureSource -Expected "titleContains = 'mercadona'" -Case 'Existing retail filter baseline'
Assert-NotMatches -Source $configureSource -Pattern "titleContains\s*=\s*'mercadona'" -Case 'Identity filter does not overlap retail namespace'
$verifySource = $scriptSources['verify-arc-identity.ps1']
Assert-Contains -Source $verifySource -Expected '$freshnessLookbackMinutes = $MaximumIngestionAgeMinutes + 5' -Case 'Verification lookback follows accepted freshness threshold'
Assert-Contains -Source $verifySource -Expected 'MSVMI-ama-vmi-default-dcr' -Case 'Verification preserves existing VM Insights DCR'
Assert-Contains -Source $verifySource -Expected 'no duplicate performance-counter source' -Case 'Verification rejects duplicate counters'
Assert-Contains -Source $verifySource -Expected '$autoMitigate = Get-ArcIdentityOptionalPropertyValue' -Case 'Verification tolerates absent autoMitigate'
Assert-Contains -Source $verifySource -Expected '$null -ne $autoMitigate -and $autoMitigate -ne $true' -Case 'Verification rejects conflicting autoMitigate'
Assert-NotMatches -Source $verifySource -Pattern '\$properties\.autoMitigate' -Case 'Verification does not require autoMitigate response'
Assert-Contains -Source $verifySource -Expected "-ExpectedOverrideQueryTimeRange 'PT30M'" -Case 'Verification expects supported freshness override'

$kqlDirectory = Join-Path $repoRoot 'kql\arc-identity'
$requiredKqlFiles = @(
    'fleet-heartbeat.kql',
    'data-freshness.kql',
    'synthetic-token-failure-burst.kql',
    'performance-correlation.kql',
    'extension-health.arg.kql',
    'change-tracking.kql'
)
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
