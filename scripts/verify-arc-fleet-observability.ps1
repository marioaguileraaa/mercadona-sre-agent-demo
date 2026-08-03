#requires -Version 7.2
<#
    Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices,
    carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.

    Read-only end to end verification of the Arc fleet observability scenario: Arc machines, agent
    extensions, workbook, both Sev2 alert rules, the SRE Agent objects, RBAC and live telemetry.
    Run it right before the demo. It changes nothing.
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $TenantId = '9b1d3cd8-5db7-4564-905d-4d2eba7b66d5',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $SreResourceGroupName = 'rg-mercadona-sre-agent-v1',
    [string] $WorkspaceName = 'law-arcbox-demo-001',
    [string] $ActionGroupName = 'ag-mercadona-sre-demo',
    [string] $AgentName = 'sre-agent-mercadona-v1',
    [string] $SreIdentityName = 'id-mercadona-sre-v1',
    [switch] $SkipSreAgent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ArcIdentity.Common.ps1"
. "$PSScriptRoot\ArcFleet.Common.ps1"

$thresholds = Get-ArcFleetThresholdContract
$roleMap = @(Get-ArcFleetRoleMap)
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$previewApiVersion = '2025-05-01-preview'
$checks = [System.Collections.Generic.List[object]]::new()

function Add-ArcFleetCheck {
    param(
        [Parameter(Mandatory)] [string] $Area,
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail')] [string] $Result,
        [string] $Detail = ''
    )

    $checks.Add([pscustomobject]@{ Area = $Area; Check = $Check; Result = $Result; Detail = $Detail })
    $prefix = switch ($Result) { 'Pass' { '  [ok]  ' } 'Warn' { '  [warn]' } 'Fail' { '  [FAIL]' } }
    Write-Host "$prefix $Area / $Check$(if ($Detail) { " - $Detail" })"
}

Assert-ArcIdentityAzureContext `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupNames @($ArcResourceGroupName, $SreResourceGroupName)

Write-Host ''
Write-Host 'Arc machines and agent posture'
$expectedMachines = @($roleMap.MachineName)
$machineResourceIds = [System.Collections.Generic.List[string]]::new()
foreach ($expectedMachine in $expectedMachines) {
    $machine = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'connectedmachine', 'show',
            '--subscription', $SubscriptionId,
            '--resource-group', $ArcResourceGroupName,
            '--name', $expectedMachine,
            '--output', 'json'
        ) `
        -FailureMessage "Unable to read Arc machine '$expectedMachine'."
    $machineProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $machine -PropertyName 'properties'
    $status = [string] (Get-ArcIdentityFirstPropertyValue -InputObjects @($machine, $machineProperties) -PropertyNames @('status'))
    $agentVersion = [string] (Get-ArcIdentityFirstPropertyValue -InputObjects @($machine, $machineProperties) -PropertyNames @('agentVersion'))
    $machineResourceIds.Add(([string] $machine.id).ToLowerInvariant())
    Add-ArcFleetCheck -Area 'Arc' -Check "$expectedMachine connected" `
        -Result $(if ($status -eq 'Connected') { 'Pass' } else { 'Warn' }) `
        -Detail "status=$status agent=$agentVersion"
}

$extensions = @(
    Get-ArcIdentityResponseItems -Response (
        Invoke-ArcIdentityAzJson `
            -Arguments @(
                'resource', 'list',
                '--subscription', $SubscriptionId,
                '--resource-group', $ArcResourceGroupName,
                '--resource-type', 'Microsoft.HybridCompute/machines/extensions',
                '--output', 'json'
            ) `
            -FailureMessage 'Unable to list Arc machine extensions.'
    )
)
$amaExtensions = @($extensions | Where-Object { [string] $_.name -like '*AzureMonitor*Agent' })
$failedExtensions = @(
    $extensions | Where-Object {
        $extensionProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $_ -PropertyName 'properties'
        $state = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $extensionProperties -PropertyName 'provisioningState')
        -not [string]::IsNullOrWhiteSpace($state) -and $state -ne 'Succeeded'
    }
)
Add-ArcFleetCheck -Area 'Arc' -Check 'Azure Monitor Agent present' `
    -Result $(if ($amaExtensions.Count -ge $expectedMachines.Count) { 'Pass' } else { 'Warn' }) `
    -Detail "$($amaExtensions.Count) AMA extension(s) across $($extensions.Count) total"
Add-ArcFleetCheck -Area 'Arc' -Check 'Extensions not in Succeeded state' `
    -Result $(if ($failedExtensions.Count -eq 0) { 'Pass' } else { 'Warn' }) `
    -Detail $(
        if ($failedExtensions.Count -eq 0) {
            'all Succeeded'
        } else {
            "$($failedExtensions.Count) not Succeeded: $((@($failedExtensions.name)) -join ', ') - this is a genuine finding to show in the demo"
        }
    )

Write-Host ''
Write-Host 'Monitoring assets'
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
$workspaceCustomerId = [string] $workspace.customerId
Add-ArcFleetCheck -Area 'Monitor' -Check 'Log Analytics workspace' -Result 'Pass' `
    -Detail "$WorkspaceName retention=$($workspace.retentionInDays)d"

$actionGroup = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'monitor', 'action-group', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $SreResourceGroupName,
        '--name', $ActionGroupName,
        '--output', 'json'
    ) `
    -FailureMessage "Unable to read action group '$ActionGroupName'."
Add-ArcFleetCheck -Area 'Monitor' -Check 'Action group reachable' -Result 'Pass' -Detail ([string] $actionGroup.id)

$workbooks = @(
    Get-ArcIdentityResponseItems -Response (
        Invoke-ArcIdentityAzJson `
            -Arguments @(
                'resource', 'list',
                '--subscription', $SubscriptionId,
                '--resource-group', $ArcResourceGroupName,
                '--resource-type', 'Microsoft.Insights/workbooks',
                '--output', 'json'
            ) `
            -FailureMessage 'Unable to list workbooks.'
    )
)
$fleetWorkbook = $workbooks |
    Where-Object {
        $workbookTags = Get-ArcIdentityOptionalPropertyValue -InputObject $_ -PropertyName 'tags'
        $scenario = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $workbookTags -PropertyName 'scenario')
        $scenario -eq 'arc-fleet-observability'
    } |
    Select-Object -First 1
if ($null -eq $fleetWorkbook) {
    Add-ArcFleetCheck -Area 'Monitor' -Check 'Fleet workbook deployed' -Result 'Fail' `
        -Detail 'no workbook tagged scenario=arc-fleet-observability. Run deploy-arc-fleet-observability.ps1 -Apply.'
} else {
    # Workbook GET returns metadata only; serializedData requires canFetchContent=true.
    $workbookDetail = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'rest', '--method', 'get',
            '--url', ('https://management.azure.com{0}' -f ([string] $fleetWorkbook.id)),
            '--uri-parameters', 'api-version=2023-06-01', 'canFetchContent=true',
            '--output', 'json'
        ) `
        -FailureMessage 'Unable to read the fleet workbook.'
    $workbookProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $workbookDetail -PropertyName 'properties'
    $serializedData = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $workbookProperties -PropertyName 'serializedData')
    $displayName = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $workbookProperties -PropertyName 'displayName')
    Add-ArcFleetCheck -Area 'Monitor' -Check 'Fleet workbook deployed' -Result 'Pass' -Detail $displayName
    Add-ArcFleetCheck -Area 'Monitor' -Check 'Workbook content retrieved' `
        -Result $(if ($serializedData.Length -gt 0) { 'Pass' } else { 'Fail' }) `
        -Detail $(if ($serializedData.Length -gt 0) { "$($serializedData.Length) characters" } else { 'serializedData is empty, so the content checks below cannot be trusted' })
    Add-ArcFleetCheck -Area 'Monitor' -Check 'Workbook placeholders resolved' `
        -Result $(if ($serializedData.Length -gt 0 -and $serializedData -notmatch '__[A-Z_]+__') { 'Pass' } else { 'Fail' }) `
        -Detail $(if ($serializedData -notmatch '__[A-Z_]+__') { 'no unresolved token' } else { 'serializedData still contains a __PLACEHOLDER__' })
    Add-ArcFleetCheck -Area 'Monitor' -Check 'Workbook targets the ArcBox workspace' `
        -Result $(if ($serializedData.ToLowerInvariant().Contains($workspaceResourceId.ToLowerInvariant())) { 'Pass' } else { 'Fail' }) `
        -Detail $workspaceResourceId
    Add-ArcFleetCheck -Area 'Monitor' -Check 'Workbook carries the synthetic disclaimer' `
        -Result $(if ($serializedData -match 'Fictional technical SRE demo') { 'Pass' } else { 'Fail' })
}

$alertContracts = @(
    @{ Name = $thresholds.CpuAlertName; Threshold = $thresholds.CpuSaturationPercent; Metric = 'CPU' },
    @{ Name = $thresholds.MemoryAlertName; Threshold = $thresholds.MemoryPressurePercent; Metric = 'memory used' }
)
$alertRules = @(
    Get-ArcIdentityResponseItems -Response (
        Invoke-ArcIdentityAzJson `
            -Arguments @(
                'resource', 'list',
                '--subscription', $SubscriptionId,
                '--resource-group', $ArcResourceGroupName,
                '--resource-type', 'Microsoft.Insights/scheduledQueryRules',
                '--output', 'json'
            ) `
            -FailureMessage 'Unable to list scheduled query alert rules.'
    )
)
foreach ($alertContract in $alertContracts) {
    $alertSummary = $alertRules |
        Where-Object { [string]::Equals([string] $_.name, [string] $alertContract.Name, [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if ($null -eq $alertSummary) {
        Add-ArcFleetCheck -Area 'Alerts' -Check "$($alertContract.Name) exists" -Result 'Fail' `
            -Detail 'not found. Run deploy-arc-fleet-observability.ps1 -Apply.'
        continue
    }
    $alert = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'resource', 'show',
            '--ids', ([string] $alertSummary.id),
            '--api-version', '2023-03-15-preview',
            '--output', 'json'
        ) `
        -FailureMessage "Unable to read alert rule '$($alertContract.Name)'."
    $alertProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $alert -PropertyName 'properties'
    $severity = Get-ArcIdentityOptionalPropertyValue -InputObject $alertProperties -PropertyName 'severity'
    $enabled = Get-ArcIdentityOptionalPropertyValue -InputObject $alertProperties -PropertyName 'enabled'
    $windowSize = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $alertProperties -PropertyName 'windowSize')
    $evaluationFrequency = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $alertProperties -PropertyName 'evaluationFrequency')
    $displayName = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $alertProperties -PropertyName 'displayName')
    $criteria = Get-ArcIdentityOptionalPropertyValue -InputObject $alertProperties -PropertyName 'criteria'
    $allOf = @(Get-ArcIdentityOptionalPropertyValue -InputObject $criteria -PropertyName 'allOf')
    $query = if ($allOf.Count -gt 0) { [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $allOf[0] -PropertyName 'query') } else { '' }

    Add-ArcFleetCheck -Area 'Alerts' -Check "$($alertContract.Name) exists" -Result 'Pass' -Detail $displayName
    Add-ArcFleetCheck -Area 'Alerts' -Check "$($alertContract.Name) severity $($thresholds.Severity) and enabled" `
        -Result $(if ([int] $severity -eq $thresholds.Severity -and [bool] $enabled) { 'Pass' } else { 'Fail' }) `
        -Detail "severity=$severity enabled=$enabled"
    Add-ArcFleetCheck -Area 'Alerts' -Check "$($alertContract.Name) cadence" `
        -Result $(if ($windowSize -eq "PT$($thresholds.WindowMinutes)M" -and $evaluationFrequency -eq "PT$($thresholds.EvaluationFrequencyMinutes)M") { 'Pass' } else { 'Fail' }) `
        -Detail "window=$windowSize frequency=$evaluationFrequency"
    Add-ArcFleetCheck -Area 'Alerts' -Check "$($alertContract.Name) display name prefix" `
        -Result $(if ($displayName.StartsWith($thresholds.AlertDisplayNamePrefix, [StringComparison]::Ordinal)) { 'Pass' } else { 'Fail' }) `
        -Detail "must start with '$($thresholds.AlertDisplayNamePrefix)' so the SRE Agent incident filter matches"
    Add-ArcFleetCheck -Area 'Alerts' -Check "$($alertContract.Name) threshold $($alertContract.Threshold)% $($alertContract.Metric)" `
        -Result $(if ($query -match [regex]::Escape([string] $alertContract.Threshold) -and $query -match [regex]::Escape([string] $thresholds.MinimumBreachingSamples)) { 'Pass' } else { 'Fail' }) `
        -Detail "query must require >= $($thresholds.MinimumBreachingSamples) breaching samples"
}

Write-Host ''
Write-Host 'Live telemetry'
$machineIdList = (@($machineResourceIds) | ForEach-Object { "'$_'" }) -join ', '
$telemetryQuery = @"
let fleet = dynamic([$machineIdList]);
InsightsMetrics
| where TimeGenerated >= ago(60m)
| where tolower(_ResourceId) in (fleet)
| where (Namespace == 'Processor' and Name == 'UtilizationPercentage')
    or (Namespace == 'Memory' and Name == 'AvailableMB')
| summarize Samples = count(), Machines = dcount(_ResourceId), LastSampleUtc = max(TimeGenerated)
"@
$telemetryRows = @(
    Invoke-ArcIdentityLogAnalyticsQuery `
        -SubscriptionId $SubscriptionId `
        -WorkspaceCustomerId $workspaceCustomerId `
        -Query $telemetryQuery
)
if ($telemetryRows.Count -eq 1 -and [int] $telemetryRows[0].Samples -gt 0) {
    Add-ArcFleetCheck -Area 'Telemetry' -Check 'InsightsMetrics in the last hour' -Result 'Pass' `
        -Detail "$($telemetryRows[0].Samples) samples from $($telemetryRows[0].Machines) machine(s), last $($telemetryRows[0].LastSampleUtc)"
} else {
    Add-ArcFleetCheck -Area 'Telemetry' -Check 'InsightsMetrics in the last hour' -Result 'Warn' `
        -Detail 'no samples. Expected outside the daily ArcBox operating window; otherwise start the estate before the demo.'
}

foreach ($kqlFile in (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'kql\arc-fleet') -Filter '*.kql' | Sort-Object Name)) {
    $queryText = Get-ArcFleetKqlQuery -RepositoryRoot $repoRoot -FileName $kqlFile.Name
    Add-ArcFleetCheck -Area 'KQL' -Check $kqlFile.Name `
        -Result $(if ($queryText.Length -gt 0) { 'Pass' } else { 'Fail' }) `
        -Detail "$($queryText.Length) characters"
}

if (-not $SkipSreAgent) {
    Write-Host ''
    Write-Host 'Azure SRE Agent'
    $sreIdentity = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'identity', 'show',
            '--subscription', $SubscriptionId,
            '--resource-group', $SreResourceGroupName,
            '--name', $SreIdentityName,
            '--output', 'json'
        ) `
        -FailureMessage "Unable to read SRE managed identity '$SreIdentityName'."
    $srePrincipalId = [string] $sreIdentity.principalId
    $agentResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$SreResourceGroupName/providers/Microsoft.App/agents/$AgentName"

    $agent = Invoke-ArcIdentityAzJson `
        -Arguments @(
            'rest',
            '--method', 'get',
            '--url', "https://management.azure.com${agentResourceId}?api-version=$previewApiVersion",
            '--output', 'json'
        ) `
        -FailureMessage "Unable to read SRE Agent '$AgentName'."
    $agentProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $agent -PropertyName 'properties'
    $actionConfiguration = Get-ArcIdentityOptionalPropertyValue -InputObject $agentProperties -PropertyName 'actionConfiguration'
    $agentMode = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $actionConfiguration -PropertyName 'mode')
    $agentAccess = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $actionConfiguration -PropertyName 'accessLevel')
    Add-ArcFleetCheck -Area 'SRE Agent' -Check 'Review / Low posture' `
        -Result $(if ($agentMode -eq 'Review' -and $agentAccess -eq 'Low') { 'Pass' } else { 'Fail' }) `
        -Detail "mode=$agentMode accessLevel=$agentAccess"

    $roleAssignments = @(
        Get-ArcIdentityResponseItems -Response (
            Invoke-ArcIdentityAzJson `
                -Arguments @(
                    'role', 'assignment', 'list',
                    '--subscription', $SubscriptionId,
                    '--assignee', $srePrincipalId,
                    '--all',
                    '--output', 'json'
                ) `
                -FailureMessage 'Unable to list SRE identity role assignments.'
        )
    )
    foreach ($expectedRole in @('Reader', 'Monitoring Reader', 'Log Analytics Reader')) {
        $matched = @($roleAssignments | Where-Object { [string] $_.roleDefinitionName -eq $expectedRole })
        Add-ArcFleetCheck -Area 'SRE Agent' -Check "RBAC $expectedRole" `
            -Result $(if ($matched.Count -gt 0) { 'Pass' } else { 'Fail' }) `
            -Detail "$($matched.Count) assignment(s)"
    }

    $sreObjects = @(
        @{ Label = "skill arc-fleet-observability"; Path = '/api/v2/extendedAgent/skills/arc-fleet-observability' },
        @{ Label = "subagent arc-fleet-analyzer"; Path = '/api/v2/extendedAgent/agents/arc-fleet-analyzer' },
        @{ Label = "incident filter arc-fleet-performance-sev2"; Path = '/api/v2/extendedAgent/incidentFilters/arc-fleet-performance-sev2' },
        @{ Label = "scheduled task arc-fleet-weekday-health-report"; Path = '/api/v2/extendedAgent/scheduledtasks/arc-fleet-weekday-health-report' },
        @{ Label = "scheduled task arc-fleet-weekly-capacity-report"; Path = '/api/v2/extendedAgent/scheduledtasks/arc-fleet-weekly-capacity-report' }
    )
    try {
        $null = Connect-ArcIdentitySreAgentApi `
            -SubscriptionId $SubscriptionId `
            -AgentResourceId $agentResourceId `
            -ApiVersion $previewApiVersion
        foreach ($sreObject in $sreObjects) {
            $existing = Invoke-ArcIdentitySreAgentApi -Method Get -Path $sreObject.Path -Body $null -AllowNotFound
            if ($null -eq $existing) {
                Add-ArcFleetCheck -Area 'SRE Agent' -Check $sreObject.Label -Result 'Fail' `
                    -Detail 'not found. Run configure-arc-fleet-sre-agent.ps1 -Apply.'
                continue
            }
            $existingProperties = Get-ArcIdentityOptionalPropertyValue -InputObject $existing -PropertyName 'properties'
            $existingMode = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $existingProperties -PropertyName 'agentMode')
            if ([string]::IsNullOrWhiteSpace($existingMode)) {
                Add-ArcFleetCheck -Area 'SRE Agent' -Check $sreObject.Label -Result 'Pass'
            } else {
                Add-ArcFleetCheck -Area 'SRE Agent' -Check $sreObject.Label `
                    -Result $(if ($existingMode -eq 'Review') { 'Pass' } else { 'Fail' }) `
                    -Detail "agentMode=$existingMode"
            }
        }
    } finally {
        Disconnect-ArcIdentitySreAgentApi
    }
}

Write-Host ''
Write-Host 'Leftover pressure Run Command resources'
$limits = Get-ArcFleetPressureSafetyLimit
foreach ($allowedMachine in (Get-ArcFleetAllowedPressureMachine).Keys) {
    $leftovers = @(
        @(
            Get-ArcFleetRunCommandList `
                -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ArcResourceGroupName `
                -MachineName ([string] $allowedMachine)
        ) | Where-Object { [string] $_.name -like "$($limits.RunCommandNamePrefix)*" }
    )
    Add-ArcFleetCheck -Area 'Cleanup' -Check "$allowedMachine has no leftover $($limits.RunCommandNamePrefix)* run command" `
        -Result $(if ($leftovers.Count -eq 0) { 'Pass' } else { 'Warn' }) `
        -Detail $(if ($leftovers.Count -eq 0) { 'clean' } else { "$($leftovers.Count) leftover(s); run recover-arc-fleet-pressure.ps1 -Apply" })
}

Write-Host ''
$failCount = @($checks | Where-Object { $_.Result -eq 'Fail' }).Count
$warnCount = @($checks | Where-Object { $_.Result -eq 'Warn' }).Count
$passCount = @($checks | Where-Object { $_.Result -eq 'Pass' }).Count
Write-Host "Verification summary: $passCount pass, $warnCount warn, $failCount fail."
if ($failCount -gt 0) {
    $checks | Where-Object { $_.Result -eq 'Fail' } | Format-Table -AutoSize | Out-String | Write-Host
    throw "Arc fleet observability verification found $failCount blocking issue(s)."
}
Write-Host 'Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.'
