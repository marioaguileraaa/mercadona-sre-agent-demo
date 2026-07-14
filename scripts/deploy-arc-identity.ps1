#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $TenantId = '9b1d3cd8-5db7-4564-905d-4d2eba7b66d5',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $SreResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $Location = 'westeurope',
    [string] $WorkspaceName = 'law-arcbox-demo-001',
    [string] $ActionGroupName = 'ag-mercadona-sre-demo',
    [string[]] $MachineNames = @('ArcBox-Win2K22', 'ArcBox-Win2K25'),
    [string] $DataCollectionRuleName = 'dcr-arcbox-identity-ops',
    [string] $AssociationName = 'assoc-arcbox-identity-ops',
    [string] $ExistingVmInsightsDataCollectionRuleName = 'MSVMI-ama-vmi-default-dcr',
    [string] $TokenFailureAlertName = 'alert-arcbox-identity-token-failure-burst',
    [string] $DataFreshnessAlertName = 'alert-arcbox-identity-data-freshness',
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ArcIdentity.Common.ps1"

Assert-ArcIdentityAzureContext `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupNames @($ArcResourceGroupName, $SreResourceGroupName)

$null = Get-ArcIdentityTargetMachines `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ArcResourceGroupName `
    -Location $Location `
    -MachineNames $MachineNames
foreach ($machineName in $MachineNames) {
    $null = Assert-ArcIdentityAmaExtension `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $machineName
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

$dedicatedDcrResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$DataCollectionRuleName"
$dcrList = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'rest',
        '--method', 'get',
        '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName/providers/Microsoft.Insights/dataCollectionRules?api-version=2024-03-11",
        '--output', 'json'
    ) `
    -FailureMessage "Unable to list DCRs in '$ArcResourceGroupName'."
$existingDcr = @(Get-ArcIdentityResponseItems -Response $dcrList) |
    Where-Object { $_.name -eq $DataCollectionRuleName } |
    Select-Object -First 1
if ($null -ne $existingDcr) {
    $existingDcrTags = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $existingDcr `
        -PropertyName 'tags'
    if ((Get-ArcIdentityOptionalPropertyValue `
                -InputObject $existingDcrTags `
                -PropertyName 'scenario') -ne 'synthetic-identity-arc' -or
        (Get-ArcIdentityOptionalPropertyValue `
                -InputObject $existingDcrTags `
                -PropertyName 'dataClassification') -ne 'synthetic') {
        throw "DCR '$DataCollectionRuleName' exists without the dedicated synthetic identity tags; refusing to overwrite it."
    }
}

$alertList = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'rest',
        '--method', 'get',
        '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName/providers/Microsoft.Insights/scheduledQueryRules?api-version=2023-12-01",
        '--output', 'json'
    ) `
    -FailureMessage "Unable to list scheduled-query alerts in '$ArcResourceGroupName'."
foreach ($alertName in @($TokenFailureAlertName, $DataFreshnessAlertName)) {
    $existingAlert = @(Get-ArcIdentityResponseItems -Response $alertList) |
        Where-Object { $_.name -eq $alertName } |
        Select-Object -First 1
    if ($null -eq $existingAlert) {
        continue
    }

    $existingAlertTags = Get-ArcIdentityOptionalPropertyValue `
        -InputObject $existingAlert `
        -PropertyName 'tags'
    if ((Get-ArcIdentityOptionalPropertyValue `
                -InputObject $existingAlertTags `
                -PropertyName 'scenario') -ne 'synthetic-identity-arc' -or
        (Get-ArcIdentityOptionalPropertyValue `
                -InputObject $existingAlertTags `
                -PropertyName 'dataClassification') -ne 'synthetic') {
        throw "Alert '$alertName' exists without the dedicated synthetic identity tags; refusing to overwrite it."
    }
}

$allMachines = @(
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
foreach ($machine in $allMachines) {
    $machineName = [string] $machine.name
    $associations = @(Get-ArcIdentityDcrAssociations `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ArcResourceGroupName `
            -MachineName $machineName)
    $dedicatedAssociations = @(
        $associations | Where-Object {
            $_.name -eq $AssociationName -or
            [string]::Equals(
                [string] $_.properties.dataCollectionRuleId,
                $dedicatedDcrResourceId,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    )
    if ($machineName -in $MachineNames) {
        $vmInsightsAssociations = @(
            $associations | Where-Object {
                $associationProperties = Get-ArcIdentityOptionalPropertyValue `
                    -InputObject $_ `
                    -PropertyName 'properties'
                $associatedDcrId = [string] (
                    Get-ArcIdentityOptionalPropertyValue `
                        -InputObject $associationProperties `
                        -PropertyName 'dataCollectionRuleId'
                )
                $associatedDcrId.EndsWith(
                    "/$ExistingVmInsightsDataCollectionRuleName",
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
        )
        if ($vmInsightsAssociations.Count -ne 1) {
            throw "Target '$machineName' must retain exactly one association to existing VM Insights DCR '$ExistingVmInsightsDataCollectionRuleName'."
        }
        foreach ($association in $dedicatedAssociations) {
            if ($association.name -ne $AssociationName -or
                -not [string]::Equals(
                    [string] $association.properties.dataCollectionRuleId,
                    $dedicatedDcrResourceId,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "A conflicting dedicated DCR association exists on '$machineName'; refusing to overwrite it."
            }
        }
    } elseif ($dedicatedAssociations.Count -gt 0) {
        throw "The dedicated DCR or association name is already attached to non-target Arc machine '$machineName'."
    }
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$templateFile = Join-Path $repoRoot 'infra\arc-identity.bicep'
if (-not (Test-Path -LiteralPath $templateFile -PathType Leaf)) {
    throw 'The Arc identity Bicep orchestration file was not found.'
}

$deploymentParameterFile = [System.IO.Path]::GetTempFileName()
try {
    $deploymentParameters = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            arcResourceGroupName = @{
                value = $ArcResourceGroupName
            }
            location = @{
                value = $Location
            }
            workspaceResourceId = @{
                value = $workspaceResourceId
            }
            actionGroupResourceId = @{
                value = $actionGroupResourceId
            }
            targetMachineNames = @{
                value = @($MachineNames)
            }
            dataCollectionRuleName = @{
                value = $DataCollectionRuleName
            }
            dataCollectionRuleAssociationName = @{
                value = $AssociationName
            }
            tokenFailureAlertName = @{
                value = $TokenFailureAlertName
            }
            dataFreshnessAlertName = @{
                value = $DataFreshnessAlertName
            }
        }
    }
    $deploymentParametersJson = $deploymentParameters | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText(
        $deploymentParameterFile,
        $deploymentParametersJson,
        [System.Text.UTF8Encoding]::new($false)
    )
    $deploymentParameterFileArgument = "@$([System.IO.Path]::GetFullPath($deploymentParameterFile))"
    $whatIfName = "arc-identity-whatif-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))"

    & az deployment sub what-if `
        --subscription $SubscriptionId `
        --location $Location `
        --name $whatIfName `
        --template-file $templateFile `
        --parameters $deploymentParameterFileArgument `
        --result-format FullResourcePayloads
    if ($LASTEXITCODE -ne 0) {
        throw 'Arc identity subscription deployment what-if failed.'
    }

    if (-not $Apply) {
        Write-Host 'What-if completed. No Azure resources were changed. Rerun with -Apply after reviewing the result.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess(
            "$SubscriptionId/$ArcResourceGroupName",
            'Create or update only the dedicated Arc identity DCR, two associations, and two alert rules'
        )) {
        return
    }

    $deploymentName = "arc-identity-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))"
    $createArguments = @(
        'deployment', 'sub', 'create',
        '--subscription', $SubscriptionId,
        '--location', $Location,
        '--name', $deploymentName,
        '--template-file', $templateFile,
        '--parameters', $deploymentParameterFileArgument,
        '--output', 'json'
    )
    $deployment = Invoke-ArcIdentityAzJson `
        -Arguments $createArguments `
        -FailureMessage 'Arc identity subscription deployment failed.'
    if ($deployment.properties.provisioningState -ne 'Succeeded') {
        throw "Arc identity deployment finished as '$($deployment.properties.provisioningState)'."
    }

    Write-Host "Additive Arc identity infrastructure deployed as '$deploymentName'."
    Write-Host 'Run configure-arc-identity-sre-agent.ps1 and then verify-arc-identity.ps1.'
} finally {
    if (Test-Path -LiteralPath $deploymentParameterFile -PathType Leaf) {
        Remove-Item -LiteralPath $deploymentParameterFile -Force
    }
}
