#requires -Version 7.2
<#
    Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices,
    carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.

    Fully offline contract test for the Arc fleet observability scenario. It touches no Azure API
    and asserts that thresholds, safety limits, the workbook, the Bicep templates, the KQL assets
    and the generated pressure payload all agree with each other.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$failures = [System.Collections.Generic.List[string]]::new()
$assertions = 0

function Assert-True {
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Condition,
        [Parameter(Mandatory)] [string] $Because
    )

    $script:assertions++
    if (-not $Condition) {
        $script:failures.Add($Because)
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)] [scriptblock] $Script,
        [Parameter(Mandatory)] [string] $Because
    )

    $script:assertions++
    try {
        & $Script | Out-Null
        $script:failures.Add("$Because (no exception was thrown)")
    } catch {
        # Expected refusal.
    }
}

# ---------------------------------------------------------------------------------------------
# 1. Every new file parses.
# ---------------------------------------------------------------------------------------------
$scriptPaths = @(
    "$PSScriptRoot\ArcFleet.Common.ps1",
    "$PSScriptRoot\deploy-arc-fleet-observability.ps1",
    "$PSScriptRoot\configure-arc-fleet-sre-agent.ps1",
    "$PSScriptRoot\start-arc-fleet-pressure.ps1",
    "$PSScriptRoot\recover-arc-fleet-pressure.ps1",
    "$PSScriptRoot\verify-arc-fleet-observability.ps1"
)
foreach ($scriptPath in $scriptPaths) {
    Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Because "Missing script '$scriptPath'."
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True -Condition ($errors.Count -eq 0) -Because "Script '$scriptPath' has parser errors: $((@($errors) | ForEach-Object { $_.Message }) -join '; ')"
}

. "$PSScriptRoot\ArcIdentity.Common.ps1"
. "$PSScriptRoot\ArcFleet.Common.ps1"

$thresholds = Get-ArcFleetThresholdContract
$limits = Get-ArcFleetPressureSafetyLimit
$roleMap = @(Get-ArcFleetRoleMap)
$allowedMachines = Get-ArcFleetAllowedPressureMachine

# ---------------------------------------------------------------------------------------------
# 2. Threshold contract is internally consistent and matches the real baseline rationale.
# ---------------------------------------------------------------------------------------------
Assert-True -Condition ($thresholds.CpuSaturationPercent -eq 85) -Because 'CPU saturation threshold must stay at 85 percent.'
Assert-True -Condition ($thresholds.MemoryPressurePercent -eq 80) -Because 'Memory pressure threshold must stay at 80 percent.'
Assert-True -Condition ($thresholds.MinimumBreachingSamples -eq 8) -Because 'Both rules must require 8 breaching samples.'
Assert-True -Condition ($thresholds.SampleIntervalSeconds -eq 60) -Because 'InsightsMetrics sampling is 60 seconds.'
Assert-True -Condition ($thresholds.WindowMinutes -eq 15) -Because 'The evaluation window must stay at 15 minutes.'
Assert-True -Condition ($thresholds.EvaluationFrequencyMinutes -eq 5) -Because 'The evaluation frequency must stay at 5 minutes.'
Assert-True -Condition ($thresholds.Severity -eq 2) -Because 'Both fleet rules must stay Sev2 so the SRE Agent stays in Review.'
Assert-True -Condition ($thresholds.AlertDisplayNamePrefix -eq 'ArcBox FleetOps') -Because 'The display-name prefix drives the SRE Agent incident filter.'
Assert-True -Condition (
    $thresholds.MinimumBreachingSamples * $thresholds.SampleIntervalSeconds -le $thresholds.WindowMinutes * 60
) -Because 'The required breaching samples must fit inside the evaluation window.'
Assert-True -Condition (
    $thresholds.MinimumBreachingSamples * $thresholds.SampleIntervalSeconds -ge ($thresholds.WindowMinutes * 60) / 2
) -Because 'The rules must demand sustained pressure, not a single peak.'

# ---------------------------------------------------------------------------------------------
# 3. Safety limits are bounded and the allowlist stays exactly the two Windows hosts.
# ---------------------------------------------------------------------------------------------
Assert-True -Condition ($limits.MaximumMemoryMb -le 2048) -Because 'The pressure payload must never be allowed to request more than 2048 MB.'
Assert-True -Condition ($limits.DefaultMemoryMb -le $limits.MaximumMemoryMb) -Because 'The default memory request must not exceed the hard maximum.'
Assert-True -Condition ($limits.MinimumAvailableMb -ge 512) -Because 'The available-memory floor must keep the guest responsive.'
Assert-True -Condition ($limits.MaximumDurationSeconds -le 900) -Because 'The payload must never be allowed to run longer than 15 minutes.'
Assert-True -Condition ($limits.DefaultDurationSeconds -le $limits.MaximumDurationSeconds) -Because 'The default duration must not exceed the hard maximum.'
Assert-True -Condition ($limits.DefaultDurationSeconds -ge $limits.MinimumDurationSeconds) -Because 'The default duration must not undercut the hard minimum.'
Assert-True -Condition ($limits.DefaultDurationSeconds -ge (($thresholds.MinimumBreachingSamples + 2) * $thresholds.SampleIntervalSeconds)) -Because 'The default duration must produce more breaching samples than the rules require, with margin for ingestion.'
Assert-True -Condition ($limits.DefaultDurationSeconds -lt ($thresholds.WindowMinutes * 60)) -Because 'The default duration must stay inside a single evaluation window so the payload self-terminates before a second window opens.'
Assert-True -Condition ($limits.MaximumCpuWorkerCount -le 8) -Because 'The payload must never start more than 8 CPU workers.'
Assert-True -Condition ($limits.RunCommandNamePrefix -eq 'perfops-') -Because 'The recovery script matches Run Commands on the perfops- prefix.'
Assert-True -Condition ($limits.EventSource -eq 'Mercadona.FleetOps') -Because 'The synthetic marker event source must stay Mercadona.FleetOps.'
Assert-True -Condition ($limits.StartEventId -eq 5101 -and $limits.EndEventId -eq 5102) -Because 'Fleet event IDs must not collide with the identity scenario 4101/4102.'

Assert-True -Condition ($allowedMachines.Count -eq 2) -Because 'Exactly two machines may receive pressure.'
Assert-True -Condition ($allowedMachines.Contains('ArcBox-Win2K22') -and $allowedMachines.Contains('ArcBox-Win2K25')) -Because 'Only the two ArcBox Windows guests are allowlisted.'
foreach ($forbidden in @('ArcBox-SQL', 'Arcbox-Ubuntu-01', 'Arcbox-Ubuntu-02', 'ArcBox-Client', 'ArcBox-Win2K19')) {
    Assert-Throws -Script { Resolve-ArcFleetAllowedMachineName -MachineName $forbidden }.GetNewClosure() `
        -Because "Machine '$forbidden' must be refused for pressure injection."
}
Assert-Throws -Script { Resolve-ArcFleetAllowedMachineName -MachineName '' } -Because 'A blank machine name must be refused.'

# The demo role map is presentation-only and must never be applied as Azure tags.
Assert-True -Condition ($roleMap.Count -eq 5) -Because 'The demo role map must cover all five Arc machines.'
foreach ($roleEntry in $roleMap) {
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($roleEntry.DemoRole)) -Because 'Every mapped machine needs a demo role.'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($roleEntry.DemoHost)) -Because 'Every mapped machine needs a fictional host name.'
}

# ---------------------------------------------------------------------------------------------
# 4. Correlation IDs, plans and Run Command names.
# ---------------------------------------------------------------------------------------------
$correlationId = New-ArcFleetCorrelationId -UtcNow ([datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc))
Assert-True -Condition ($correlationId -cmatch '^fleetops-20260102T030405Z-[0-9a-f]{8}$') -Because "Correlation ID '$correlationId' must follow the documented format."
Assert-True -Condition ((Assert-ArcFleetCorrelationId -CorrelationId $correlationId) -eq $correlationId) -Because 'A valid correlation ID must round-trip.'
foreach ($badCorrelationId in @('', 'fleetops-', 'SYNTH-ID-20260102T030405Z-ABCDEF12', 'fleetops-20260102T030405Z-ABCDEF12', 'fleetops-20261302T030405Z-abcdef12')) {
    Assert-Throws -Script { Assert-ArcFleetCorrelationId -CorrelationId $badCorrelationId }.GetNewClosure() `
        -Because "Correlation ID '$badCorrelationId' must be refused."
}

$splitPlan = @(Resolve-ArcFleetPressurePlan -PressureProfile 'Split' -MachineNames @('ArcBox-Win2K22', 'ArcBox-Win2K25'))
Assert-True -Condition ($splitPlan.Count -eq 2) -Because 'The Split profile must cover both allowlisted machines.'
Assert-True -Condition (($splitPlan | Where-Object { $_.MachineName -eq 'ArcBox-Win2K22' }).Mode -eq 'Memory') -Because 'Split must put memory pressure on ArcBox-Win2K22.'
Assert-True -Condition (($splitPlan | Where-Object { $_.MachineName -eq 'ArcBox-Win2K25' }).Mode -eq 'Cpu') -Because 'Split must put CPU pressure on ArcBox-Win2K25.'
Assert-True -Condition (@($splitPlan.Mode | Sort-Object -Unique).Count -eq 2) -Because 'Split must fire both Sev2 rules at once.'
Assert-Throws -Script { Resolve-ArcFleetPressurePlan -PressureProfile 'Split' -MachineNames @('ArcBox-Win2K22', 'arcbox-win2k22') } `
    -Because 'A duplicated machine must be refused regardless of casing.'
Assert-Throws -Script { Resolve-ArcFleetPressurePlan -PressureProfile 'Nuclear' -MachineNames @('ArcBox-Win2K22') } `
    -Because 'An unknown pressure profile must be refused.'

$runCommandName = New-ArcFleetRunCommandName -Mode 'Memory' -CorrelationId $correlationId
Assert-True -Condition ($runCommandName -cmatch '^perfops-[a-z0-9-]{8,50}$') -Because "Run Command name '$runCommandName' must satisfy the safety pattern."
Assert-True -Condition ($runCommandName.StartsWith($limits.RunCommandNamePrefix, [StringComparison]::Ordinal)) -Because 'Run Command names must carry the perfops- prefix so cleanup finds them.'

# ---------------------------------------------------------------------------------------------
# 5. The generated remote payload is bounded, self-terminating and non-persistent.
# ---------------------------------------------------------------------------------------------
foreach ($mode in @('Cpu', 'Memory', 'Both')) {
    $payload = New-ArcFleetPressureScript `
        -Mode $mode `
        -CorrelationId $correlationId `
        -DurationSeconds $limits.DefaultDurationSeconds `
        -MemoryMb $limits.DefaultMemoryMb `
        -MinimumAvailableMb $limits.MinimumAvailableMb `
        -CpuDutyCyclePercent $limits.DefaultCpuDutyCyclePercent `
        -CpuWorkerCount 2

    $payloadTokens = $null
    $payloadErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($payload, [ref]$payloadTokens, [ref]$payloadErrors) | Out-Null
    Assert-True -Condition ($payloadErrors.Count -eq 0) -Because "The generated $mode payload must parse: $((@($payloadErrors) | ForEach-Object { $_.Message }) -join '; ')"
    Assert-True -Condition ($payload -notmatch '__[A-Z_]+__') -Because "The generated $mode payload must not contain an unresolved placeholder."

    foreach ($requiredFragment in @(
            "Set-StrictMode -Version Latest",
            "`$ErrorActionPreference = 'Stop'",
            "`$deadline = (Get-Date).AddSeconds(`$durationSeconds)",
            '} finally {',
            '$chunks.Clear()',
            '$process.PriorityClass = $originalPriority',
            'demoSynthetic = $true',
            "correlationId = `$correlationId",
            'BelowNormal',
            'Invoke-CimMethod -ClassName Win32_Process -MethodName Create',
            'Stop-Process -Id $workerProcessId',
            'while (DateTime.UtcNow.Ticks < deadlineTicks)',
            'rootCauseClue'
        )) {
        Assert-True -Condition $payload.Contains($requiredFragment, [StringComparison]::Ordinal) `
            -Because "The generated $mode payload must contain '$requiredFragment'."
    }

    foreach ($forbiddenFragment in @(
            'Restart-Computer',
            'Stop-Computer',
            'shutdown',
            'New-ScheduledTask',
            'Register-ScheduledTask',
            'schtasks',
            'New-Service',
            'Set-Service',
            'Stop-Service',
            'Set-ItemProperty',
            'New-ItemProperty',
            'Set-ExecutionPolicy',
            'Invoke-WebRequest',
            'Invoke-RestMethod',
            'Start-BitsTransfer',
            'DownloadString',
            'Remove-Item',
            'Set-MpPreference',
            'while ($true)',
            'while (1)',
            'ConvertTo-SecureString',
            'Add-LocalGroupMember',
            'net user',
            'netsh'
        )) {
        Assert-True -Condition (-not $payload.Contains($forbiddenFragment, [StringComparison]::OrdinalIgnoreCase)) `
            -Because "The generated $mode payload must not contain '$forbiddenFragment'."
    }

    # Every loop is bounded by the same deadline computed from the validated duration.
    $unboundedLoops = [regex]::Matches($payload, '(?m)^\s*(while|do)\b(?!.*(deadline|Deadline|ElapsedMilliseconds|\$offset))')
    Assert-True -Condition ($unboundedLoops.Count -eq 0) -Because "The generated $mode payload must not contain a loop without a bound."
    Assert-True -Condition ($payload.Contains('$requestedMemoryMb', [StringComparison]::Ordinal)) -Because "The generated $mode payload must cap allocation by the requested total."
    Assert-True -Condition ($payload.Contains('$minimumAvailableMb', [StringComparison]::Ordinal)) -Because "The generated $mode payload must enforce the available-memory floor."
    Assert-True -Condition ($payload.Contains("-gt `$requestedMemoryMb) { break }", [StringComparison]::Ordinal)) -Because "The generated $mode payload must break out of allocation once the requested total is reached."
    Assert-True -Condition ($payload.Contains("-lt `$minimumAvailableMb) { break }", [StringComparison]::Ordinal)) -Because "The generated $mode payload must break out of allocation before crossing the floor."

    $finallyIndex = $payload.IndexOf('} finally {', [StringComparison]::Ordinal)
    $clearIndex = $payload.IndexOf('$chunks.Clear()', [StringComparison]::Ordinal)
    Assert-True -Condition ($finallyIndex -gt 0 -and $clearIndex -gt $finallyIndex) -Because "The generated $mode payload must free its memory inside the finally block."

    # CPU workers run outside the Run Command job object, so they must be stopped in the finally
    # block and must also carry a deadline of their own in case the parent is killed abruptly.
    $stopWorkerIndex = $payload.IndexOf('Stop-Process -Id $workerProcessId', [StringComparison]::Ordinal)
    Assert-True -Condition ($stopWorkerIndex -gt $finallyIndex) -Because "The generated $mode payload must stop every CPU worker process inside the finally block."
    Assert-True -Condition ($payload.Contains('AddSeconds(' + "' + `$WorkerSeconds + '" + ').Ticks', [StringComparison]::Ordinal)) `
        -Because "The generated $mode payload must give every CPU worker its own hard deadline."
    Assert-True -Condition ($payload.Contains('$remainingSeconds -gt 0', [StringComparison]::Ordinal)) `
        -Because "The generated $mode payload must never start a CPU worker once the window has elapsed."
    Assert-True -Condition (-not $payload.Contains('runspacefactory', [StringComparison]::OrdinalIgnoreCase)) `
        -Because "The generated $mode payload must not use in-process runspaces, which the Run Command job object throttles."
}

# Refusals in the payload generator.
Assert-Throws -Script { New-ArcFleetPressureScript -Mode 'Memory' -CorrelationId $correlationId -DurationSeconds ($limits.MaximumDurationSeconds + 1) -MemoryMb 1024 -MinimumAvailableMb $limits.MinimumAvailableMb -CpuDutyCyclePercent 95 -CpuWorkerCount 2 } `
    -Because 'A duration above the maximum must be refused.'
Assert-Throws -Script { New-ArcFleetPressureScript -Mode 'Memory' -CorrelationId $correlationId -DurationSeconds ($limits.MinimumDurationSeconds - 1) -MemoryMb 1024 -MinimumAvailableMb $limits.MinimumAvailableMb -CpuDutyCyclePercent 95 -CpuWorkerCount 2 } `
    -Because 'A duration below the minimum must be refused.'
Assert-Throws -Script { New-ArcFleetPressureScript -Mode 'Memory' -CorrelationId $correlationId -DurationSeconds 840 -MemoryMb ($limits.MaximumMemoryMb + 1) -MinimumAvailableMb $limits.MinimumAvailableMb -CpuDutyCyclePercent 95 -CpuWorkerCount 2 } `
    -Because 'A memory request above the maximum must be refused.'
Assert-Throws -Script { New-ArcFleetPressureScript -Mode 'Memory' -CorrelationId $correlationId -DurationSeconds 840 -MemoryMb 0 -MinimumAvailableMb $limits.MinimumAvailableMb -CpuDutyCyclePercent 95 -CpuWorkerCount 2 } `
    -Because 'Memory mode with a zero request must be refused.'
Assert-Throws -Script { New-ArcFleetPressureScript -Mode 'Memory' -CorrelationId $correlationId -DurationSeconds 840 -MemoryMb 1024 -MinimumAvailableMb ($limits.MinimumAvailableMb - 1) -CpuDutyCyclePercent 95 -CpuWorkerCount 2 } `
    -Because 'A floor below the approved minimum must be refused.'
Assert-Throws -Script { New-ArcFleetPressureScript -Mode 'Cpu' -CorrelationId $correlationId -DurationSeconds 840 -MemoryMb 0 -MinimumAvailableMb $limits.MinimumAvailableMb -CpuDutyCyclePercent ($limits.MinimumCpuDutyCyclePercent - 1) -CpuWorkerCount 2 } `
    -Because 'A duty cycle below the approved minimum must be refused.'
Assert-Throws -Script { New-ArcFleetPressureScript -Mode 'Cpu' -CorrelationId $correlationId -DurationSeconds 840 -MemoryMb 0 -MinimumAvailableMb $limits.MinimumAvailableMb -CpuDutyCyclePercent 95 -CpuWorkerCount ($limits.MaximumCpuWorkerCount + 1) } `
    -Because 'More workers than the approved maximum must be refused.'

# ---------------------------------------------------------------------------------------------
# 6. KQL assets are present, non-empty and aggregate-only.
# ---------------------------------------------------------------------------------------------
$expectedKqlFiles = @(
    'fleet-inventory.arg.kql',
    'agent-extension-health.arg.kql',
    'fleet-heartbeat-freshness.kql',
    'cpu-saturation.kql',
    'memory-pressure.kql',
    'disk-capacity.kql',
    'fleet-performance-summary.kql',
    'resource-pressure-timeline.kql',
    'change-inventory.kql',
    'capacity-trend.kql'
)
$kqlDirectory = Join-Path $repoRoot 'kql\arc-fleet'
$actualKqlFiles = @(Get-ChildItem -LiteralPath $kqlDirectory -Filter '*.kql' | Select-Object -ExpandProperty Name)
Assert-True -Condition ($actualKqlFiles.Count -eq $expectedKqlFiles.Count) -Because "kql\arc-fleet must contain exactly $($expectedKqlFiles.Count) reviewed queries, found $($actualKqlFiles.Count)."
foreach ($expectedKqlFile in $expectedKqlFiles) {
    Assert-True -Condition ($expectedKqlFile -in $actualKqlFiles) -Because "Reviewed KQL asset '$expectedKqlFile' is missing."
    $queryText = Get-ArcFleetKqlQuery -RepositoryRoot $repoRoot -FileName $expectedKqlFile
    Assert-True -Condition ($queryText.Trim().Length -gt 0) -Because "Reviewed KQL asset '$expectedKqlFile' must not be empty."
    Assert-True -Condition ($queryText -match '(?m)^//') -Because "Reviewed KQL asset '$expectedKqlFile' must start with an explanatory comment."
    foreach ($forbiddenKqlFragment in @('RenderedDescription', 'ParameterXml', 'EventData', 'AccountName', 'SubjectUserName', 'TargetUserName')) {
        Assert-True -Condition (-not $queryText.Contains($forbiddenKqlFragment, [StringComparison]::OrdinalIgnoreCase)) `
            -Because "Reviewed KQL asset '$expectedKqlFile' must not project '$forbiddenKqlFragment'."
    }
    if ($expectedKqlFile -notlike '*.arg.kql') {
        Assert-True -Condition ($queryText -match '(?i)\|\s*summarize|\|\s*make-series|\|\s*count') `
            -Because "Reviewed KQL asset '$expectedKqlFile' must aggregate rather than dump raw records."
    }
}
$diskQuery = Get-ArcFleetKqlQuery -RepositoryRoot $repoRoot -FileName 'disk-capacity.kql'
Assert-True -Condition ($diskQuery.Contains('/snap/', [StringComparison]::Ordinal)) -Because 'The disk query must exclude Linux read-only pseudo-mounts.'
$cpuQuery = Get-ArcFleetKqlQuery -RepositoryRoot $repoRoot -FileName 'cpu-saturation.kql'
Assert-True -Condition ($cpuQuery.Contains([string] $thresholds.CpuSaturationPercent, [StringComparison]::Ordinal)) -Because 'The CPU query must use the contracted 85 percent threshold.'
$memoryQuery = Get-ArcFleetKqlQuery -RepositoryRoot $repoRoot -FileName 'memory-pressure.kql'
Assert-True -Condition ($memoryQuery.Contains([string] $thresholds.MemoryPressurePercent, [StringComparison]::Ordinal)) -Because 'The memory query must use the contracted 80 percent threshold.'
Assert-True -Condition ($memoryQuery.Contains('vm.azm.ms/memorySizeMB', [StringComparison]::Ordinal)) -Because 'Memory used percentage must be derived from the InsightsMetrics memory-size tag.'

# ---------------------------------------------------------------------------------------------
# 7. The workbook JSON is valid, parameterised and carries the disclaimer.
# ---------------------------------------------------------------------------------------------
$workbookPath = Join-Path $repoRoot 'infra\workbooks\arc-fleet-observability.workbook.json'
Assert-True -Condition (Test-Path -LiteralPath $workbookPath -PathType Leaf) -Because 'The fleet workbook JSON must exist.'
$workbookText = [System.IO.File]::ReadAllText($workbookPath)
$workbook = $null
try {
    $workbook = $workbookText | ConvertFrom-Json -Depth 100
} catch {
    $failures.Add("The fleet workbook JSON does not parse: $($_.Exception.Message)")
}
if ($null -ne $workbook) {
    $workbookItems = @($workbook.items)
    Assert-True -Condition ($workbookItems.Count -ge 20) -Because "The fleet workbook must contain at least 20 items, found $($workbookItems.Count)."
    $queryItems = @($workbookItems | Where-Object { $_.type -eq 3 })
    Assert-True -Condition ($queryItems.Count -ge 12) -Because "The fleet workbook must contain at least 12 query panels, found $($queryItems.Count)."
    Assert-True -Condition ($workbookText.Contains('Fictional technical SRE demo', [StringComparison]::Ordinal)) -Because 'The fleet workbook must carry the synthetic-demo disclaimer.'
    Assert-True -Condition ($workbookText.Contains('__WORKSPACE_RESOURCE_ID__', [StringComparison]::Ordinal)) -Because 'The fleet workbook must keep the workspace placeholder so Bicep can substitute it.'
    Assert-True -Condition ($workbookText.Contains('__SUBSCRIPTION_RESOURCE_ID__', [StringComparison]::Ordinal)) -Because 'The fleet workbook must keep the subscription placeholder so Bicep can substitute it.'
    foreach ($hardCodedSecret in @('SharedKey', 'password', 'ClientSecret', 'AccountKey')) {
        Assert-True -Condition (-not $workbookText.Contains($hardCodedSecret, [StringComparison]::OrdinalIgnoreCase)) `
            -Because "The fleet workbook must not contain '$hardCodedSecret'."
    }
}

# ---------------------------------------------------------------------------------------------
# 8. Bicep defaults and parameters agree with the threshold contract.
# ---------------------------------------------------------------------------------------------
$moduleBicep = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'infra\core\arc-fleet-monitoring.bicep'))
$orchestratorBicep = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'infra\arc-fleet-observability.bicep'))
$parametersText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'infra\arc-fleet-observability.parameters.json'))
$parameters = $null
try {
    $parameters = $parametersText | ConvertFrom-Json -Depth 50
} catch {
    $failures.Add("The fleet parameters file does not parse: $($_.Exception.Message)")
}

Assert-True -Condition ($orchestratorBicep.Contains($thresholds.CpuAlertName, [StringComparison]::Ordinal)) -Because 'The orchestrator must default to the contracted CPU alert name.'
Assert-True -Condition ($orchestratorBicep.Contains($thresholds.MemoryAlertName, [StringComparison]::Ordinal)) -Because 'The orchestrator must default to the contracted memory alert name.'
Assert-True -Condition ($moduleBicep.Contains('cpuSaturationAlertName', [StringComparison]::Ordinal)) -Because 'The module must accept the CPU alert name as a parameter.'
Assert-True -Condition ($moduleBicep.Contains('memoryPressureAlertName', [StringComparison]::Ordinal)) -Because 'The module must accept the memory alert name as a parameter.'
Assert-True -Condition ($moduleBicep.Contains($thresholds.AlertDisplayNamePrefix, [StringComparison]::Ordinal)) -Because 'The module must prefix both display names so the incident filter matches.'
Assert-True -Condition ($moduleBicep.Contains("severity: $($thresholds.Severity)", [StringComparison]::Ordinal)) -Because 'Both rules must be Sev2 in the module.'
Assert-True -Condition ($moduleBicep.Contains("windowSize: 'PT$($thresholds.WindowMinutes)M'", [StringComparison]::Ordinal)) -Because 'The module must use the contracted 15 minute window.'
Assert-True -Condition ($moduleBicep.Contains("evaluationFrequency: 'PT$($thresholds.EvaluationFrequencyMinutes)M'", [StringComparison]::Ordinal)) -Because 'The module must use the contracted 5 minute evaluation frequency.'
Assert-True -Condition ($moduleBicep.Contains('autoResolved: true', [StringComparison]::Ordinal)) -Because 'Both rules must auto-resolve so the demo cleans itself up.'
Assert-True -Condition ($moduleBicep.Contains('arc-fleet-observability', [StringComparison]::Ordinal)) -Because 'Deployed resources must be tagged with the scenario for ownership checks.'
Assert-True -Condition ($moduleBicep.Contains('dataClassification', [StringComparison]::Ordinal)) -Because 'Deployed resources must be tagged as synthetic.'
Assert-True -Condition ($orchestratorBicep.Contains("targetScope = 'subscription'", [StringComparison]::Ordinal)) -Because 'The orchestrator must deploy at subscription scope.'
Assert-True -Condition ($orchestratorBicep.Contains("= $($thresholds.CpuSaturationPercent)", [StringComparison]::Ordinal)) -Because 'The orchestrator default CPU threshold must match the contract.'
Assert-True -Condition ($orchestratorBicep.Contains("= $($thresholds.MemoryPressurePercent)", [StringComparison]::Ordinal)) -Because 'The orchestrator default memory threshold must match the contract.'

if ($null -ne $parameters) {
    $parameterValues = $parameters.parameters
    Assert-True -Condition ([int] $parameterValues.cpuSaturationPercent.value -eq $thresholds.CpuSaturationPercent) -Because 'The parameters file CPU threshold must match the contract.'
    Assert-True -Condition ([int] $parameterValues.memoryPressurePercent.value -eq $thresholds.MemoryPressurePercent) -Because 'The parameters file memory threshold must match the contract.'
    Assert-True -Condition ([int] $parameterValues.minimumBreachingSamples.value -eq $thresholds.MinimumBreachingSamples) -Because 'The parameters file breaching-sample count must match the contract.'
    $parameterMachineNames = @($parameterValues.fleetMachineNames.value)
    Assert-True -Condition ($parameterMachineNames.Count -eq $roleMap.Count) -Because "The parameters file must list all $($roleMap.Count) fleet machines."
    foreach ($roleEntry in $roleMap) {
        $matchedParameterName = @(
            $parameterMachineNames | Where-Object {
                [string]::Equals([string] $_, [string] $roleEntry.MachineName, [StringComparison]::OrdinalIgnoreCase)
            }
        )
        Assert-True -Condition ($matchedParameterName.Count -eq 1) `
            -Because "The parameters file must list exactly one machine matching the role-map key '$($roleEntry.MachineName)'."
    }
    Assert-True -Condition ([string] $parameterValues.cpuSaturationAlertName.value -eq $thresholds.CpuAlertName) -Because 'The parameters file CPU alert name must match the contract.'
    Assert-True -Condition ([string] $parameterValues.memoryPressureAlertName.value -eq $thresholds.MemoryAlertName) -Because 'The parameters file memory alert name must match the contract.'
    Assert-True -Condition (([string] $parameterValues.workbookDisplayName.value).StartsWith($thresholds.AlertDisplayNamePrefix, [StringComparison]::Ordinal)) -Because 'The workbook display name must carry the FleetOps prefix.'
    Assert-True -Condition (([string] $parameterValues.workspaceResourceId.value).Contains('/providers/Microsoft.OperationalInsights/workspaces/', [StringComparison]::OrdinalIgnoreCase)) -Because 'The parameters file must point at a Log Analytics workspace.'
    Assert-True -Condition (([string] $parameterValues.actionGroupResourceId.value).Contains('/providers/Microsoft.Insights/actionGroups/', [StringComparison]::OrdinalIgnoreCase)) -Because 'The parameters file must reuse an existing action group.'
}

# ---------------------------------------------------------------------------------------------
# 9. Scripts stay non-destructive, gated and free of secrets.
# ---------------------------------------------------------------------------------------------
$deployText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'deploy-arc-fleet-observability.ps1'))
$configureText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'configure-arc-fleet-sre-agent.ps1'))
$startText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'start-arc-fleet-pressure.ps1'))
$recoverText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'recover-arc-fleet-pressure.ps1'))
$verifyText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'verify-arc-fleet-observability.ps1'))
$commonText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ArcFleet.Common.ps1'))

foreach ($gatedScript in @(
        @{ Name = 'deploy-arc-fleet-observability.ps1'; Text = $deployText },
        @{ Name = 'configure-arc-fleet-sre-agent.ps1'; Text = $configureText },
        @{ Name = 'start-arc-fleet-pressure.ps1'; Text = $startText },
        @{ Name = 'recover-arc-fleet-pressure.ps1'; Text = $recoverText }
    )) {
    Assert-True -Condition ($gatedScript.Text.Contains('[switch] $Apply', [StringComparison]::Ordinal)) -Because "$($gatedScript.Name) must be gated behind -Apply."
    Assert-True -Condition ($gatedScript.Text.Contains('SupportsShouldProcess', [StringComparison]::Ordinal)) -Because "$($gatedScript.Name) must support ShouldProcess."
    Assert-True -Condition ($gatedScript.Text.Contains('$PSCmdlet.ShouldProcess', [StringComparison]::Ordinal)) -Because "$($gatedScript.Name) must call ShouldProcess before changing anything."
    Assert-True -Condition ($gatedScript.Text.Contains('Assert-ArcIdentityAzureContext', [StringComparison]::Ordinal)) -Because "$($gatedScript.Name) must assert the exact Azure context first."
}
foreach ($scriptText in @($deployText, $configureText, $startText, $recoverText, $verifyText, $commonText)) {
    Assert-True -Condition ($scriptText.Contains("Set-StrictMode -Version Latest", [StringComparison]::Ordinal)) -Because 'Every Arc fleet script must run under strict mode.'
}
Assert-True -Condition ($verifyText -notmatch '(?m)\[switch\]\s*\$Apply') -Because 'The verification script must stay read-only and must not offer -Apply.'
foreach ($destructiveVerb in @('az group delete', 'az resource delete', 'Remove-AzResourceGroup', 'az vm delete', 'az connectedmachine delete', 'az monitor log-analytics workspace delete')) {
    foreach ($scriptText in @($deployText, $configureText, $startText, $recoverText, $verifyText, $commonText)) {
        Assert-True -Condition (-not $scriptText.Contains($destructiveVerb, [StringComparison]::OrdinalIgnoreCase)) `
            -Because "No Arc fleet script may contain '$destructiveVerb'."
    }
}
Assert-True -Condition ($deployText.Contains('what-if', [StringComparison]::OrdinalIgnoreCase)) -Because 'The deploy script must run what-if before applying.'
Assert-True -Condition ($configureText.Contains("'Review'", [StringComparison]::Ordinal)) -Because 'The configure script must keep the SRE Agent objects in Review mode.'
Assert-True -Condition ($configureText.Contains('must already be configured as Review/Low', [StringComparison]::Ordinal)) -Because 'The configure script must refuse to broaden the SRE Agent posture.'
Assert-True -Condition (-not $configureText.Contains("'Autonomous'", [StringComparison]::Ordinal)) -Because 'The configure script must never request Autonomous mode.'
Assert-True -Condition (-not $configureText.Contains("accessLevel = 'High'", [StringComparison]::Ordinal)) -Because 'The configure script must never request High access.'
foreach ($readOnlyTool in @('RunAzCliReadCommands', 'QueryLogAnalyticsByWorkspaceId', 'SearchMemory', 'GetAzCliHelp', 'FindConnectedGitHubRepo')) {
    Assert-True -Condition ($configureText.Contains($readOnlyTool, [StringComparison]::Ordinal)) -Because "The configure script must grant the read-only tool '$readOnlyTool'."
}
foreach ($writeTool in @('RunAzCliWriteCommands', 'ExecuteAzCli', 'RestartResource', 'ScaleResource', 'ApplyRemediation')) {
    Assert-True -Condition (-not $configureText.Contains($writeTool, [StringComparison]::Ordinal)) -Because "The configure script must not grant the write tool '$writeTool'."
}
Assert-True -Condition ($recoverText.Contains('Remove-ArcFleetRunCommand', [StringComparison]::Ordinal)) -Because 'The recovery script must delete the pressure Run Commands.'
Assert-True -Condition ($startText.Contains('recover-arc-fleet-pressure.ps1', [StringComparison]::Ordinal)) -Because 'The start script must point the presenter at the recovery script.'

$secretPattern = '(?i)(password\s*=\s*["''][^"'']{4,}|SharedAccessKey|AccountKey\s*=|client_secret|-----BEGIN [A-Z ]*PRIVATE KEY-----|Bearer\s+eyJ)'
foreach ($secretCandidate in @(
        @{ Name = 'deploy-arc-fleet-observability.ps1'; Text = $deployText },
        @{ Name = 'configure-arc-fleet-sre-agent.ps1'; Text = $configureText },
        @{ Name = 'start-arc-fleet-pressure.ps1'; Text = $startText },
        @{ Name = 'recover-arc-fleet-pressure.ps1'; Text = $recoverText },
        @{ Name = 'verify-arc-fleet-observability.ps1'; Text = $verifyText },
        @{ Name = 'ArcFleet.Common.ps1'; Text = $commonText },
        @{ Name = 'arc-fleet-observability.workbook.json'; Text = $workbookText },
        @{ Name = 'arc-fleet-monitoring.bicep'; Text = $moduleBicep },
        @{ Name = 'arc-fleet-observability.bicep'; Text = $orchestratorBicep }
    )) {
    Assert-True -Condition ($secretCandidate.Text -notmatch $secretPattern) -Because "$($secretCandidate.Name) must not contain anything that looks like a secret."
}

# ---------------------------------------------------------------------------------------------
# 10. Documentation carries the mandatory disclaimer and stays in sync with the thresholds.
# ---------------------------------------------------------------------------------------------
$documentPaths = @(
    (Join-Path $repoRoot 'docs\arquitectura-arc-fleet-observability.md'),
    (Join-Path $repoRoot 'docs\guia-demo-arc-fleet-60min.md'),
    (Join-Path $repoRoot 'docs\runbooks\arc-fleet-saturacion-recursos.md')
)
foreach ($documentPath in $documentPaths) {
    Assert-True -Condition (Test-Path -LiteralPath $documentPath -PathType Leaf) -Because "Documentation file '$documentPath' must exist."
    if (Test-Path -LiteralPath $documentPath -PathType Leaf) {
        $documentText = [System.IO.File]::ReadAllText($documentPath)
        Assert-True -Condition ($documentText.Contains('Fictional technical SRE demo. Not an official Mercadona system.', [StringComparison]::Ordinal)) `
            -Because "Documentation file '$documentPath' must carry the mandatory disclaimer."
        Assert-True -Condition ($documentText.Contains([string] $thresholds.CpuSaturationPercent, [StringComparison]::Ordinal)) `
            -Because "Documentation file '$documentPath' must state the CPU threshold."
        Assert-True -Condition ($documentText.Contains([string] $thresholds.MemoryPressurePercent, [StringComparison]::Ordinal)) `
            -Because "Documentation file '$documentPath' must state the memory threshold."
    }
}

# ---------------------------------------------------------------------------------------------
Write-Host ''
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "  [FAIL] $failure"
    }
    throw "Arc fleet contract test failed $($failures.Count) of $assertions assertion(s)."
}
Write-Host "Arc fleet contract test passed all $assertions assertion(s)."
Write-Host 'Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.'
