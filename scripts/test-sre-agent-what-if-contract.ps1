#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\SreAgent.WhatIf.ps1"

$fixture = Get-Content `
    -LiteralPath "$PSScriptRoot\fixtures\sre-agent-what-if.json" `
    -Raw |
    ConvertFrom-Json -Depth 100
$retailResourceGroupId = "/subscriptions/$($fixture.subscriptionId)/resourceGroups/$($fixture.retailResourceGroupName)"
$arcResourceGroupId = "/subscriptions/$($fixture.subscriptionId)/resourceGroups/$($fixture.arcResourceGroupName)"
$agentResourceId = "$retailResourceGroupId/providers/Microsoft.App/agents/$($fixture.agentName)"
$requiredManagedResources = @($retailResourceGroupId, $arcResourceGroupId)

foreach ($case in $fixture.cases) {
    $errorMessage = $null
    try {
        Assert-SreAgentWhatIfSafe `
            -WhatIf $case.whatIf `
            -AgentResourceId $agentResourceId `
            -ArcResourceGroupId $arcResourceGroupId `
            -RequiredManagedResourceIds $requiredManagedResources
    } catch {
        $errorMessage = $_.Exception.Message
    }

    if ($case.shouldPass -and $null -ne $errorMessage) {
        throw "What-if fixture '$($case.name)' should pass but failed: $errorMessage"
    }
    if (-not $case.shouldPass -and $null -eq $errorMessage) {
        throw "What-if fixture '$($case.name)' should fail but passed."
    }
}

$deployPath = Join-Path $PSScriptRoot 'deploy.ps1'
$deploySource = Get-Content -LiteralPath $deployPath -Raw
$tokens = $null
$parseErrors = $null
$deployAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $deployPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "deploy.ps1 has parser errors: $($parseErrors.Message -join '; ')"
}
$guardFunction = $deployAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-GuardedGroupDeployment'
    }, $true)
if ($null -eq $guardFunction) {
    throw 'deploy.ps1 did not define Invoke-GuardedGroupDeployment.'
}
$guardSource = $guardFunction.Extent.Text
foreach ($requiredFragment in @(
        'deployment'', ''group'', ''what-if',
        '--result-format'', ''FullResourcePayloads',
        'Assert-SreAgentWhatIfSafe',
        'deployment'', ''group'', ''create'
    )) {
    if (-not $guardSource.Contains($requiredFragment, [StringComparison]::Ordinal)) {
        throw "Guarded deployment did not preserve '$requiredFragment'."
    }
}
if ($guardSource.IndexOf(
        "deployment', 'group', 'what-if",
        [StringComparison]::Ordinal
    ) -gt $guardSource.IndexOf(
        'Assert-SreAgentWhatIfSafe',
        [StringComparison]::Ordinal
    ) -or
    $guardSource.IndexOf(
        'Assert-SreAgentWhatIfSafe',
        [StringComparison]::Ordinal
    ) -gt $guardSource.IndexOf(
        "deployment', 'group', 'create",
        [StringComparison]::Ordinal
    )) {
    throw 'Deployment what-if JSON must be asserted before create.'
}
$guardedDeploymentCalls = @(
    $deployAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-GuardedGroupDeployment'
        }, $true)
)
if ($guardedDeploymentCalls.Count -ne 2) {
    throw "deploy.ps1 must guard both deployments; found $($guardedDeploymentCalls.Count) calls."
}
foreach ($requiredFragment in @(
        '[string] $ArcResourceGroupName = ''rg-arcbox-itpro-weu-002''',
        'arcResourceGroupName=$ArcResourceGroupName'
    )) {
    if (-not $deploySource.Contains($requiredFragment, [StringComparison]::Ordinal)) {
        throw "deploy.ps1 did not preserve '$requiredFragment'."
    }
}

. ([scriptblock]::Create($guardFunction.Extent.Text))
$SubscriptionId = [string] $fixture.subscriptionId
$ResourceGroupName = [string] $fixture.retailResourceGroupName
$requiredManagedResourceIds = $requiredManagedResources
$script:fakeWhatIf = ($fixture.cases | Where-Object name -eq 'both scopes present').whatIf
$script:deploymentOperations = [System.Collections.Generic.List[string]]::new()
function az {
    [string[]] $azArguments = @($args | ForEach-Object { [string] $_ })
    $operation = $azArguments[2]
    $script:deploymentOperations.Add($operation)
    $global:LASTEXITCODE = 0
    if ($operation -eq 'what-if') {
        return $script:fakeWhatIf | ConvertTo-Json -Depth 100
    }
    if ($operation -eq 'create') {
        return
    }
    throw "Unexpected fake Azure CLI operation '$operation'."
}

Invoke-GuardedGroupDeployment `
    -DeploymentName 'safe-fixture' `
    -TemplateParameters @('environmentName=fixture') `
    -FailureMessage 'Synthetic create failed.'
if (($script:deploymentOperations -join ',') -ne 'what-if,create') {
    throw 'Safe guarded deployment did not run what-if before create.'
}

$script:fakeWhatIf = ($fixture.cases | Where-Object name -eq 'Arc scope Delete').whatIf
$script:deploymentOperations.Clear()
$unsafeError = $null
try {
    Invoke-GuardedGroupDeployment `
        -DeploymentName 'unsafe-fixture' `
        -TemplateParameters @('environmentName=fixture') `
        -FailureMessage 'Synthetic create failed.'
} catch {
    $unsafeError = $_.Exception.Message
}
if ($null -eq $unsafeError -or
    ($script:deploymentOperations -join ',') -ne 'what-if') {
    throw 'Unsafe guarded deployment did not abort between what-if and create.'
}

$bicepSource = Get-Content -LiteralPath "$repoRoot\infra\main.bicep" -Raw
foreach ($requiredFragment in @(
        "param arcResourceGroupName string = 'rg-arcbox-itpro-weu-002'",
        "subscriptionResourceId('Microsoft.Resources/resourceGroups', arcResourceGroupName)",
        "managedResources: [`r`n        resourceGroup().id`r`n        arcResourceGroupId"
    )) {
    if (-not $bicepSource.Contains($requiredFragment, [StringComparison]::Ordinal)) {
        throw "main.bicep did not preserve '$requiredFragment'."
    }
}

$parameters = Get-Content -LiteralPath "$repoRoot\infra\main.parameters.json" -Raw |
    ConvertFrom-Json
if ($parameters.parameters.arcResourceGroupName.value -ne 'rg-arcbox-itpro-weu-002') {
    throw 'main.parameters.json did not preserve the safe Arc resource-group default.'
}

Write-Host 'SRE Agent what-if guard contract passed.'
