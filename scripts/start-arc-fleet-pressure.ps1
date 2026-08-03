#requires -Version 7.2
<#
    Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices,
    carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.

    Starts one bounded, self-terminating CPU and/or memory pressure payload on the allowlisted
    ArcBox Windows machines so the Sev2 fleet alerts fire and Azure SRE Agent can investigate.
    The payload always frees everything on any exit path and installs no persistence.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $TenantId = '9b1d3cd8-5db7-4564-905d-4d2eba7b66d5',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $WorkspaceName = 'law-arcbox-demo-001',
    [ValidateCount(1, 2)]
    [string[]] $MachineNames = @('ArcBox-Win2K22', 'ArcBox-Win2K25'),
    [ValidateSet('Split', 'Both', 'Cpu', 'Memory')]
    [string] $PressureProfile = 'Split',
    [int] $DurationSeconds = 0,
    [int] $MemoryMb = 0,
    [int] $CpuDutyCyclePercent = 0,
    [ValidateRange(1, 8)]
    [int] $CpuWorkerCount = 2,
    [string] $CorrelationId = '',
    [switch] $SkipBaselineCheck,
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ArcIdentity.Common.ps1"
. "$PSScriptRoot\ArcFleet.Common.ps1"

$limits = Get-ArcFleetPressureSafetyLimit
$thresholds = Get-ArcFleetThresholdContract

if ($DurationSeconds -eq 0) { $DurationSeconds = $limits.DefaultDurationSeconds }
if ($MemoryMb -eq 0) { $MemoryMb = $limits.DefaultMemoryMb }
if ($CpuDutyCyclePercent -eq 0) { $CpuDutyCyclePercent = $limits.DefaultCpuDutyCyclePercent }
if ([string]::IsNullOrWhiteSpace($CorrelationId)) { $CorrelationId = New-ArcFleetCorrelationId }
$null = Assert-ArcFleetCorrelationId -CorrelationId $CorrelationId

if ($DurationSeconds -lt $limits.MinimumDurationSeconds -or $DurationSeconds -gt $limits.MaximumDurationSeconds) {
    throw "DurationSeconds must be between $($limits.MinimumDurationSeconds) and $($limits.MaximumDurationSeconds)."
}
if ($MemoryMb -lt $limits.MemoryChunkMb -or $MemoryMb -gt $limits.MaximumMemoryMb) {
    throw "MemoryMb must be between $($limits.MemoryChunkMb) and $($limits.MaximumMemoryMb)."
}
if ($CpuDutyCyclePercent -lt $limits.MinimumCpuDutyCyclePercent -or $CpuDutyCyclePercent -gt $limits.MaximumCpuDutyCyclePercent) {
    throw "CpuDutyCyclePercent must be between $($limits.MinimumCpuDutyCyclePercent) and $($limits.MaximumCpuDutyCyclePercent)."
}
if ($CpuWorkerCount -gt $limits.MaximumCpuWorkerCount) {
    throw "CpuWorkerCount must not exceed $($limits.MaximumCpuWorkerCount)."
}

Assert-ArcIdentityAzureContext `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupNames @($ArcResourceGroupName)

$plan = @(Resolve-ArcFleetPressurePlan -PressureProfile $PressureProfile -MachineNames $MachineNames)
$targets = @(
    Get-ArcFleetPressureTargets `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineNames @($plan.MachineName)
)
$targetByName = @{}
foreach ($target in $targets) { $targetByName[$target.MachineName] = $target }

foreach ($planItem in $plan) {
    $null = Assert-ArcIdentityAmaExtension `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $planItem.MachineName
    $existingRunCommands = @(
        @(
            Get-ArcFleetRunCommandList `
                -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ArcResourceGroupName `
                -MachineName $planItem.MachineName
        ) | Where-Object { [string] $_.name -like "$($limits.RunCommandNamePrefix)*" }
    )
    if ($existingRunCommands.Count -gt 0) {
        throw "Machine '$($planItem.MachineName)' still has $($existingRunCommands.Count) '$($limits.RunCommandNamePrefix)*' Run Command resource(s). Run recover-arc-fleet-pressure.ps1 before starting a new run."
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
$workspaceCustomerId = [string] $workspace.customerId
if ([string]::IsNullOrWhiteSpace($workspaceCustomerId)) {
    throw "Workspace '$WorkspaceName' did not expose a customer ID."
}

if (-not $SkipBaselineCheck) {
    $machineIdList = (@($targets.NormalizedResourceId) | ForEach-Object { "'$_'" }) -join ', '
    $baselineQuery = @"
let fleet = dynamic([$machineIdList]);
InsightsMetrics
| where TimeGenerated >= ago(20m)
| where tolower(_ResourceId) in (fleet)
| where (Namespace == 'Processor' and Name == 'UtilizationPercentage')
    or (Namespace == 'Memory' and Name == 'AvailableMB')
| extend MachineId = tolower(_ResourceId)
| summarize Samples = count(), LastSampleUtc = max(TimeGenerated) by MachineId, Namespace
| order by MachineId asc, Namespace asc
"@
    $baselineRows = @(
        Invoke-ArcIdentityLogAnalyticsQuery `
            -SubscriptionId $SubscriptionId `
            -WorkspaceCustomerId $workspaceCustomerId `
            -Query $baselineQuery
    )
    if ($baselineRows.Count -eq 0) {
        throw "No InsightsMetrics samples arrived in the last 20 minutes for the target machines. Confirm the ArcBox estate is running before injecting pressure, or rerun with -SkipBaselineCheck."
    }
    Write-Host 'Pre-run telemetry freshness:'
    foreach ($baselineRow in $baselineRows) {
        Write-Host ("  {0} {1}: {2} samples, last {3}" -f `
            (($baselineRow.MachineId -split '/')[-1]), $baselineRow.Namespace, $baselineRow.Samples, $baselineRow.LastSampleUtc)
    }
}

$deadlineUtc = [DateTimeOffset]::UtcNow.AddSeconds($DurationSeconds)
$expectedAlertUtc = [DateTimeOffset]::UtcNow.AddMinutes($thresholds.WindowMinutes + 4)

Write-Host ''
Write-Host "Planned bounded pressure injection (correlationId=$CorrelationId):"
foreach ($planItem in $plan) {
    $planTarget = $targetByName[$planItem.MachineName]
    $runCommandName = New-ArcFleetRunCommandName -Mode $planItem.Mode -CorrelationId $CorrelationId
    Write-Host ("  {0} ({1} / {2}) -> mode {3}, run command '{4}', location {5}" -f `
        $planItem.MachineName, $planItem.DemoRole, $planItem.DemoHost, $planItem.Mode, $runCommandName, $planTarget.Location)
}
Write-Host "  Duration $DurationSeconds s, memory up to $MemoryMb MB with a $($limits.MinimumAvailableMb) MB available floor, CPU $CpuWorkerCount worker(s) at $CpuDutyCyclePercent% duty"
Write-Host "  Self-terminates by $($deadlineUtc.ToString('u')); Sev2 alerts expected from about $($expectedAlertUtc.ToString('u'))"
Write-Host '  No persistence, no reboot, no service change, no registry change; every allocation is freed in a finally block'

if (-not $Apply) {
    Write-Host ''
    Write-Host 'No pressure was applied. Rerun with -Apply after reviewing this plan.'
    return
}
if (-not $PSCmdlet.ShouldProcess(
        ($plan.MachineName -join ', '),
        "Start bounded $PressureProfile pressure for $DurationSeconds seconds with correlationId=$CorrelationId"
    )) {
    return
}

$started = [System.Collections.Generic.List[object]]::new()
foreach ($planItem in $plan) {
    $planTarget = $targetByName[$planItem.MachineName]
    $runCommandName = New-ArcFleetRunCommandName -Mode $planItem.Mode -CorrelationId $CorrelationId
    $scriptText = New-ArcFleetPressureScript `
        -Mode $planItem.Mode `
        -CorrelationId $CorrelationId `
        -DurationSeconds $DurationSeconds `
        -MemoryMb $MemoryMb `
        -MinimumAvailableMb $limits.MinimumAvailableMb `
        -CpuDutyCyclePercent $CpuDutyCyclePercent `
        -CpuWorkerCount $CpuWorkerCount
    $null = Start-ArcFleetRunCommand `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $planItem.MachineName `
        -Location $planTarget.Location `
        -RunCommandName $runCommandName `
        -ScriptText $scriptText `
        -TimeoutSeconds ($DurationSeconds + 240)
    $started.Add([pscustomobject]@{
            MachineName = $planItem.MachineName
            DemoRole = $planItem.DemoRole
            Mode = $planItem.Mode
            RunCommandName = $runCommandName
        })
    Write-Host "Started '$runCommandName' on '$($planItem.MachineName)' in $($planItem.Mode) mode."
}

Write-Host ''
Write-Host 'Pressure is running asynchronously. Suggested demo sequence:'
Write-Host "  1. Open the workbook and watch the 15 minute pressure snapshot panel."
Write-Host "  2. Expect '$($thresholds.CpuAlertName)' and/or '$($thresholds.MemoryAlertName)' around $($expectedAlertUtc.ToString('u'))."
Write-Host "  3. Azure SRE Agent picks up the Sev2 '$($thresholds.AlertDisplayNamePrefix)' incident in Review mode."
Write-Host "  4. Always finish with: ./scripts/recover-arc-fleet-pressure.ps1 -CorrelationId $CorrelationId -Apply"
Write-Host ''
$started | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "CorrelationId: $CorrelationId"
