#requires -Version 7.2
<#
    Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices,
    carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.

    Removes every 'perfops-*' Run Command left by start-arc-fleet-pressure.ps1 and confirms in Log
    Analytics that CPU and memory returned to their documented baseline. Safe to run repeatedly and
    safe to run while a payload is still executing: the payload always frees its own memory first.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $TenantId = '9b1d3cd8-5db7-4564-905d-4d2eba7b66d5',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $WorkspaceName = 'law-arcbox-demo-001',
    [ValidateCount(1, 2)]
    [string[]] $MachineNames = @('ArcBox-Win2K22', 'ArcBox-Win2K25'),
    [string] $CorrelationId = '',
    [ValidateRange(0, 1200)]
    [int] $WaitForCompletionSeconds = 0,
    [switch] $SkipRecoveryCheck,
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ArcIdentity.Common.ps1"
. "$PSScriptRoot\ArcFleet.Common.ps1"

$limits = Get-ArcFleetPressureSafetyLimit
$thresholds = Get-ArcFleetThresholdContract
if (-not [string]::IsNullOrWhiteSpace($CorrelationId)) {
    $null = Assert-ArcFleetCorrelationId -CorrelationId $CorrelationId
    $correlationSuffix = $CorrelationId.Substring(9).Replace('T', '').Replace('Z', '').ToLowerInvariant()
} else {
    $correlationSuffix = ''
}

Assert-ArcIdentityAzureContext `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupNames @($ArcResourceGroupName)

$resolvedMachineNames = @($MachineNames | ForEach-Object { Resolve-ArcFleetAllowedMachineName -MachineName $_ })

function Get-ArcFleetPendingRunCommand {
    param(
        [Parameter(Mandatory)]
        [string[]] $ResolvedMachineNames
    )

    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($machineName in $ResolvedMachineNames) {
        $runCommands = @(
            Get-ArcFleetRunCommandList `
                -SubscriptionId $SubscriptionId `
                -ResourceGroupName $ArcResourceGroupName `
                -MachineName $machineName
        )
        foreach ($runCommand in $runCommands) {
            $name = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $runCommand -PropertyName 'name')
            if ($name -cnotmatch '^perfops-[a-z0-9-]{8,50}$') {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($correlationSuffix) -and -not $name.EndsWith($correlationSuffix, [StringComparison]::Ordinal)) {
                continue
            }
            $outcome = Get-ArcFleetRunCommandOutcome -RunCommand $runCommand
            $pending.Add([pscustomobject]@{
                    MachineName = $machineName
                    RunCommandName = $name
                    ProvisioningState = $outcome.ProvisioningState
                    ExecutionState = $outcome.ExecutionState
                    ExitCode = $outcome.ExitCode
                    Output = $outcome.Output
                    Error = $outcome.Error
                })
        }
    }
    return $pending.ToArray()
}

$pendingRunCommands = @(Get-ArcFleetPendingRunCommand -ResolvedMachineNames $resolvedMachineNames)

if ($pendingRunCommands.Count -eq 0) {
    Write-Host "No '$($limits.RunCommandNamePrefix)*' Run Command resources are present on $($resolvedMachineNames -join ', ')."
} else {
    Write-Host "Found $($pendingRunCommands.Count) '$($limits.RunCommandNamePrefix)*' Run Command resource(s):"
    foreach ($pending in $pendingRunCommands) {
        Write-Host ("  {0} / {1}: provisioning {2}, execution {3}, exit {4}" -f `
            $pending.MachineName, $pending.RunCommandName, $pending.ProvisioningState, $pending.ExecutionState, $pending.ExitCode)
    }
}

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Nothing was deleted. Rerun with -Apply to remove these Run Command resources and verify recovery.'
    return
}
if ($pendingRunCommands.Count -gt 0 -and -not $PSCmdlet.ShouldProcess(
        ($resolvedMachineNames -join ', '),
        "Delete $($pendingRunCommands.Count) bounded pressure Run Command resource(s) and verify recovery"
    )) {
    return
}

if ($WaitForCompletionSeconds -gt 0 -and $pendingRunCommands.Count -gt 0) {
    $waitDeadline = [DateTimeOffset]::UtcNow.AddSeconds($WaitForCompletionSeconds)
    while ([DateTimeOffset]::UtcNow -lt $waitDeadline) {
        $stillRunning = @(
            Get-ArcFleetPendingRunCommand -ResolvedMachineNames $resolvedMachineNames |
                Where-Object { $_.ExecutionState -in @('Running', 'Pending', 'Unknown') }
        )
        if ($stillRunning.Count -eq 0) {
            break
        }
        Write-Host "Waiting for $($stillRunning.Count) payload(s) to self-terminate..."
        Start-Sleep -Seconds 20
    }
    $pendingRunCommands = @(Get-ArcFleetPendingRunCommand -ResolvedMachineNames $resolvedMachineNames)
}

foreach ($pending in $pendingRunCommands) {
    if ($pending.ExecutionState -in @('Running', 'Pending')) {
        Write-Warning "Run Command '$($pending.RunCommandName)' on '$($pending.MachineName)' is still $($pending.ExecutionState). Deleting the resource stops it from being tracked; the payload frees its own memory and restores priority in a finally block and self-terminates at its hard deadline."
    }
    if (-not [string]::IsNullOrWhiteSpace($pending.Output)) {
        Write-Host "Payload output from '$($pending.MachineName)':"
        Write-Host $pending.Output.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($pending.Error)) {
        Write-Warning "Payload error stream from '$($pending.MachineName)': $($pending.Error.Trim())"
    }
    Remove-ArcFleetRunCommand `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $pending.MachineName `
        -RunCommandName $pending.RunCommandName
    Write-Host "Deleted '$($pending.RunCommandName)' from '$($pending.MachineName)'."
}

$remaining = @(Get-ArcFleetPendingRunCommand -ResolvedMachineNames $resolvedMachineNames)
if ($remaining.Count -gt 0) {
    throw "Cleanup incomplete: $($remaining.Count) '$($limits.RunCommandNamePrefix)*' Run Command resource(s) still exist."
}
Write-Host "Cleanup complete: no '$($limits.RunCommandNamePrefix)*' Run Command resources remain."

if ($SkipRecoveryCheck) {
    return
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

$allowed = Get-ArcFleetAllowedPressureMachine
$machineIdList = (@($resolvedMachineNames | ForEach-Object { "'" + ([string] $allowed[$_]).ToLowerInvariant() + "'" })) -join ', '
$recoveryQuery = @"
let fleet = dynamic([$machineIdList]);
let cpu = InsightsMetrics
    | where TimeGenerated >= ago(10m)
    | where tolower(_ResourceId) in (fleet)
    | where Namespace == 'Processor' and Name == 'UtilizationPercentage'
    | summarize CpuAvgPercent = round(avg(Val), 1), CpuMaxPercent = round(max(Val), 1), CpuSamples = count()
        by MachineId = tolower(_ResourceId);
let mem = InsightsMetrics
    | where TimeGenerated >= ago(10m)
    | where tolower(_ResourceId) in (fleet)
    | where Namespace == 'Memory' and Name == 'AvailableMB'
    | extend TotalMemoryMb = todouble(parse_json(Tags)['vm.azm.ms/memorySizeMB'])
    | where isnotnull(TotalMemoryMb) and TotalMemoryMb > 0
    | extend MemoryUsedPercent = 100.0 * (TotalMemoryMb - Val) / TotalMemoryMb
    | summarize MemoryAvgPercent = round(avg(MemoryUsedPercent), 1), MemoryMaxPercent = round(max(MemoryUsedPercent), 1),
        MinAvailableMb = round(min(Val), 0), MemorySamples = count()
        by MachineId = tolower(_ResourceId);
cpu
| join kind=fullouter mem on MachineId
| project Machine = tostring(split(coalesce(MachineId, MachineId1), '/')[-1]),
    CpuAvgPercent, CpuMaxPercent, CpuSamples, MemoryAvgPercent, MemoryMaxPercent, MinAvailableMb, MemorySamples
| order by Machine asc
"@
$recoveryRows = @(
    Invoke-ArcIdentityLogAnalyticsQuery `
        -SubscriptionId $SubscriptionId `
        -WorkspaceCustomerId $workspaceCustomerId `
        -Query $recoveryQuery
)

Write-Host ''
Write-Host 'Post-cleanup 10 minute telemetry:'
if ($recoveryRows.Count -eq 0) {
    Write-Warning 'No InsightsMetrics samples were returned for the last 10 minutes. If the ArcBox estate was shut down this is expected; otherwise rerun this check in a few minutes.'
    return
}
$recoveryRows | Format-Table -AutoSize | Out-String | Write-Host

$stillHot = @(
    $recoveryRows | Where-Object {
        ($null -ne $_.CpuAvgPercent -and [double] $_.CpuAvgPercent -ge $thresholds.CpuSaturationPercent) -or
        ($null -ne $_.MemoryAvgPercent -and [double] $_.MemoryAvgPercent -ge $thresholds.MemoryPressurePercent)
    }
)
if ($stillHot.Count -gt 0) {
    Write-Warning "The 10 minute average is still at or above the alert thresholds on: $(($stillHot.Machine) -join ', '). The window still contains pressure samples; recheck in about 10 minutes before closing the demo."
} else {
    Write-Host "Recovery confirmed: the 10 minute averages are below $($thresholds.CpuSaturationPercent)% CPU and $($thresholds.MemoryPressurePercent)% memory used on every target."
}
Write-Host 'Both Sev2 rules auto-resolve after 15 minutes without breaching samples.'
