#requires -Version 7.2
<#
    Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices,
    carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.

    Deploys only the additive Arc fleet observability resources: one Azure Monitor workbook and two
    Sev2 log alert rules. It never creates, edits or deletes an Arc machine, an extension, a data
    collection rule, an association, the workspace, the action group or any Jumpstart resource.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $TenantId = '9b1d3cd8-5db7-4564-905d-4d2eba7b66d5',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $SreResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $Location = 'westeurope',
    [string] $WorkspaceName = 'law-arcbox-demo-001',
    [string] $ActionGroupName = 'ag-mercadona-sre-demo',
    [ValidateCount(2, 12)]
    [string[]] $FleetMachineNames = @(
        'ArcBox-Win2K22',
        'ArcBox-Win2K25',
        'ArcBox-SQL',
        'Arcbox-Ubuntu-01',
        'Arcbox-Ubuntu-02'
    ),
    [string] $WorkbookDisplayName = 'ArcBox FleetOps - Azure Arc fleet observability',
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ArcIdentity.Common.ps1"
. "$PSScriptRoot\ArcFleet.Common.ps1"

$thresholds = Get-ArcFleetThresholdContract

Assert-ArcIdentityAzureContext `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupNames @($ArcResourceGroupName, $SreResourceGroupName)

$fleetMachines = @(
    Get-ArcIdentityResponseItems -Response (
        Invoke-ArcIdentityAzJson `
            -Arguments @(
                'connectedmachine', 'list',
                '--subscription', $SubscriptionId,
                '--resource-group', $ArcResourceGroupName,
                '--output', 'json'
            ) `
            -FailureMessage "Unable to list Arc machines in '$ArcResourceGroupName'."
    )
)
foreach ($machineName in $FleetMachineNames) {
    $machine = $fleetMachines | Where-Object {
        [string]::Equals([string] $_.name, $machineName, [StringComparison]::Ordinal)
    } | Select-Object -First 1
    if ($null -eq $machine) {
        throw "Expected Arc machine '$machineName' was not found in '$ArcResourceGroupName'."
    }
    $properties = Get-ArcIdentityOptionalPropertyValue -InputObject $machine -PropertyName 'properties'
    $status = Get-ArcIdentityFirstPropertyValue -InputObjects @($machine, $properties) -PropertyNames @('status')
    if ($status -ne 'Connected') {
        Write-Warning "Arc machine '$machineName' is '$status'. The workbook still renders, but it will show no fresh telemetry for that server."
    }
}

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
$expectedWorkspaceResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"
if (-not [string]::Equals(
        $workspaceResourceId,
        $expectedWorkspaceResourceId,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Workspace resource ID mismatch. Expected '$expectedWorkspaceResourceId', got '$workspaceResourceId'."
}

$actionGroup = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'monitor', 'action-group', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $SreResourceGroupName,
        '--name', $ActionGroupName,
        '--output', 'json'
    ) `
    -FailureMessage "Unable to read action group '$ActionGroupName'."
$actionGroupResourceId = [string] $actionGroup.id
$expectedActionGroupResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$SreResourceGroupName/providers/Microsoft.Insights/actionGroups/$ActionGroupName"
if (-not [string]::Equals(
        $actionGroupResourceId,
        $expectedActionGroupResourceId,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Action group resource ID mismatch. Expected '$expectedActionGroupResourceId', got '$actionGroupResourceId'."
}

$alertList = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'rest',
        '--method', 'get',
        '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName/providers/Microsoft.Insights/scheduledQueryRules?api-version=2023-12-01",
        '--output', 'json'
    ) `
    -FailureMessage "Unable to list scheduled-query alerts in '$ArcResourceGroupName'."
foreach ($alertName in @($thresholds.CpuAlertName, $thresholds.MemoryAlertName)) {
    $existingAlert = @(Get-ArcIdentityResponseItems -Response $alertList) |
        Where-Object { $_.name -eq $alertName } |
        Select-Object -First 1
    if ($null -eq $existingAlert) {
        continue
    }
    $existingAlertTags = Get-ArcIdentityOptionalPropertyValue -InputObject $existingAlert -PropertyName 'tags'
    if ((Get-ArcIdentityOptionalPropertyValue -InputObject $existingAlertTags -PropertyName 'scenario') -ne 'arc-fleet-observability' -or
        (Get-ArcIdentityOptionalPropertyValue -InputObject $existingAlertTags -PropertyName 'dataClassification') -ne 'synthetic') {
        throw "Alert '$alertName' exists without the dedicated Arc fleet observability tags; refusing to overwrite it."
    }
}

$workbookName = $null
$workbookResources = @(
    Get-ArcIdentityResponseItems -Response (
        Invoke-ArcIdentityAzJson `
            -Arguments @(
                'resource', 'list',
                '--subscription', $SubscriptionId,
                '--resource-group', $ArcResourceGroupName,
                '--resource-type', 'Microsoft.Insights/workbooks',
                '--output', 'json'
            ) `
            -FailureMessage "Unable to list workbooks in '$ArcResourceGroupName'."
    )
)
foreach ($workbookResource in $workbookResources) {
    $workbook = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'resource', 'show',
            '--subscription', $SubscriptionId,
            '--ids', [string] $workbookResource.id,
            '--api-version', '2023-06-01',
            '--query', '{name:name,tags:tags,displayName:properties.displayName}',
            '--output', 'json'
        ) `
        -FailureMessage "Unable to read workbook '$([string] $workbookResource.id)'."
    $displayName = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $workbook -PropertyName 'displayName')
    if (-not [string]::Equals($displayName, $WorkbookDisplayName, [StringComparison]::Ordinal)) {
        continue
    }
    $workbookTags = Get-ArcIdentityOptionalPropertyValue -InputObject $workbook -PropertyName 'tags'
    if ((Get-ArcIdentityOptionalPropertyValue -InputObject $workbookTags -PropertyName 'scenario') -ne 'arc-fleet-observability') {
        throw "A workbook named '$WorkbookDisplayName' already exists without the dedicated Arc fleet observability tags; refusing to overwrite it."
    }
    $workbookName = [string] $workbook.name
}
if ($null -ne $workbookName) {
    Write-Host "Existing owned workbook '$workbookName' will be updated in place."
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$templateFile = Join-Path $repoRoot 'infra\arc-fleet-observability.bicep'
if (-not (Test-Path -LiteralPath $templateFile -PathType Leaf)) {
    throw 'The Arc fleet observability Bicep orchestration file was not found.'
}
$workbookFile = Join-Path $repoRoot 'infra\workbooks\arc-fleet-observability.workbook.json'
if (-not (Test-Path -LiteralPath $workbookFile -PathType Leaf)) {
    throw 'The Arc fleet observability workbook payload was not found.'
}
$workbookJson = [System.IO.File]::ReadAllText($workbookFile)
$null = $workbookJson | ConvertFrom-Json
foreach ($requiredPlaceholder in @('__WORKSPACE_RESOURCE_ID__', '__SUBSCRIPTION_RESOURCE_ID__')) {
    if (-not $workbookJson.Contains($requiredPlaceholder, [StringComparison]::Ordinal)) {
        throw "The workbook payload must contain the '$requiredPlaceholder' placeholder."
    }
}

$deploymentParameterFile = [System.IO.Path]::GetTempFileName()
try {
    $deploymentParameters = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            arcResourceGroupName = @{ value = $ArcResourceGroupName }
            location = @{ value = $Location }
            workspaceResourceId = @{ value = $workspaceResourceId }
            actionGroupResourceId = @{ value = $actionGroupResourceId }
            fleetMachineNames = @{ value = @($FleetMachineNames) }
            cpuSaturationAlertName = @{ value = $thresholds.CpuAlertName }
            memoryPressureAlertName = @{ value = $thresholds.MemoryAlertName }
            workbookDisplayName = @{ value = $WorkbookDisplayName }
            cpuSaturationPercent = @{ value = $thresholds.CpuSaturationPercent }
            memoryPressurePercent = @{ value = $thresholds.MemoryPressurePercent }
            minimumBreachingSamples = @{ value = $thresholds.MinimumBreachingSamples }
        }
    }
    [System.IO.File]::WriteAllText(
        $deploymentParameterFile,
        ($deploymentParameters | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )
    $deploymentParameterFileArgument = "@$([System.IO.Path]::GetFullPath($deploymentParameterFile))"
    $whatIfName = "arc-fleet-whatif-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))"

    & az deployment sub what-if `
        --subscription $SubscriptionId `
        --location $Location `
        --name $whatIfName `
        --template-file $templateFile `
        --parameters $deploymentParameterFileArgument `
        --result-format ResourceIdOnly
    if ($LASTEXITCODE -ne 0) {
        throw 'Arc fleet observability subscription deployment what-if failed.'
    }

    if (-not $Apply) {
        Write-Host 'What-if completed. No Azure resources were changed. Rerun with -Apply after reviewing the result.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess(
            "$SubscriptionId/$ArcResourceGroupName",
            'Create or update only the dedicated Arc fleet workbook and the two fleet alert rules'
        )) {
        return
    }

    $deploymentName = "arc-fleet-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))"
    $deployment = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'deployment', 'sub', 'create',
            '--subscription', $SubscriptionId,
            '--location', $Location,
            '--name', $deploymentName,
            '--template-file', $templateFile,
            '--parameters', $deploymentParameterFileArgument,
            '--output', 'json'
        ) `
        -FailureMessage 'Arc fleet observability subscription deployment failed.'
    if ($deployment.properties.provisioningState -ne 'Succeeded') {
        throw "Arc fleet observability deployment finished as '$($deployment.properties.provisioningState)'."
    }

    $outputs = Get-ArcIdentityOptionalPropertyValue -InputObject $deployment.properties -PropertyName 'outputs'
    $deployedWorkbookId = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject (
            Get-ArcIdentityOptionalPropertyValue -InputObject $outputs -PropertyName 'workbookId'
        ) -PropertyName 'value')

    Write-Host "Additive Arc fleet observability infrastructure deployed as '$deploymentName'."
    Write-Host "Workbook: $deployedWorkbookId"
    Write-Host 'Run configure-arc-fleet-sre-agent.ps1 and then verify-arc-fleet-observability.ps1.'
} finally {
    if (Test-Path -LiteralPath $deploymentParameterFile -PathType Leaf) {
        Remove-Item -LiteralPath $deploymentParameterFile -Force
    }
}
