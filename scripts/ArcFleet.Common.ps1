Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices,
# carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.
#
# Additive helpers for the Azure Arc fleet observability scenario. This file is dot-sourced AFTER
# scripts/ArcIdentity.Common.ps1 and deliberately never redefines or mutates any ArcIdentity
# function, so the existing identity contract surface stays byte-for-byte intact.

foreach ($requiredFunction in @(
        'Invoke-ArcIdentityAzJson',
        'Invoke-ArcIdentityAzNoOutput',
        'Invoke-ArcIdentityArmRestWithJsonBody',
        'Get-ArcIdentityResponseItems',
        'Get-ArcIdentityOptionalPropertyValue',
        'Get-ArcIdentityFirstPropertyValue',
        'Get-ArcIdentityMachineResourceId'
    )) {
    if ($null -eq (Get-Command -Name $requiredFunction -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "ArcFleet.Common.ps1 requires '$requiredFunction'. Dot-source scripts/ArcIdentity.Common.ps1 first."
    }
}

function Get-ArcFleetRoleMap {
    <#
        Presentation-only role labels. These Arc machines do not run AD FS or AD DS; the map exists
        so the demo can narrate the customer's on-premises pattern without touching any resource.
    #>
    return @(
        [pscustomobject]@{ MachineName = 'ArcBox-Win2K22'; MachineKey = 'arcbox-win2k22'; DemoRole = 'adfs'; DemoHost = 'adfs-01'; DemoSite = 'site-a' }
        [pscustomobject]@{ MachineName = 'ArcBox-Win2K25'; MachineKey = 'arcbox-win2k25'; DemoRole = 'domain-controller'; DemoHost = 'dc-01'; DemoSite = 'site-a' }
        [pscustomobject]@{ MachineName = 'ArcBox-SQL'; MachineKey = 'arcbox-sql'; DemoRole = 'identity-sql'; DemoHost = 'sql-01'; DemoSite = 'site-b' }
        [pscustomobject]@{ MachineName = 'Arcbox-Ubuntu-01'; MachineKey = 'arcbox-ubuntu-01'; DemoRole = 'linux-edge'; DemoHost = 'edge-01'; DemoSite = 'site-b' }
        [pscustomobject]@{ MachineName = 'Arcbox-Ubuntu-02'; MachineKey = 'arcbox-ubuntu-02'; DemoRole = 'linux-edge'; DemoHost = 'edge-02'; DemoSite = 'site-b' }
    )
}

function Get-ArcFleetThresholdContract {
    <#
        Single source of truth shared by the Bicep parameters, the runbook, the workbook and the
        offline contract test. Derived from a real 7 day baseline in which neither rule fired once.
    #>
    return [pscustomobject]@{
        CpuSaturationPercent = 85
        MemoryPressurePercent = 80
        MinimumBreachingSamples = 8
        SampleIntervalSeconds = 60
        WindowMinutes = 15
        EvaluationFrequencyMinutes = 5
        Severity = 2
        AlertDisplayNamePrefix = 'ArcBox FleetOps'
        CpuAlertName = 'alert-arcbox-fleet-cpu-saturation'
        MemoryAlertName = 'alert-arcbox-fleet-memory-pressure'
    }
}

function Get-ArcFleetPressureSafetyLimit {
    <#
        Hard bounds for the controlled pressure injection. Every value is enforced twice: once by
        the local script that builds the payload and once by the remote payload itself.
    #>
    return [pscustomobject]@{
        MaximumMemoryMb = 2048
        DefaultMemoryMb = 1800
        MinimumAvailableMb = 700
        MemoryChunkMb = 64
        MinimumDurationSeconds = 300
        MaximumDurationSeconds = 900
        DefaultDurationSeconds = 840
        MinimumCpuDutyCyclePercent = 50
        MaximumCpuDutyCyclePercent = 100
        DefaultCpuDutyCyclePercent = 95
        MaximumCpuWorkerCount = 8
        RunCommandNamePrefix = 'perfops-'
        EventSource = 'Mercadona.FleetOps'
        StartEventId = 5101
        EndEventId = 5102
    }
}

function Get-ArcFleetAllowedPressureMachine {
    <#
        Only these two Windows Arc machines may ever receive pressure. ArcBox-SQL, both Ubuntu
        guests, the ArcBox host virtual machine and every other Jumpstart resource are excluded.
    #>
    return [ordered]@{
        'ArcBox-Win2K22' = '/subscriptions/5305e853-a63b-4b82-9a3f-6fde18c1a798/resourceGroups/rg-arcbox-itpro-weu-002/providers/Microsoft.HybridCompute/machines/ArcBox-Win2K22'
        'ArcBox-Win2K25' = '/subscriptions/5305e853-a63b-4b82-9a3f-6fde18c1a798/resourceGroups/rg-arcbox-itpro-weu-002/providers/Microsoft.HybridCompute/machines/ArcBox-Win2K25'
    }
}

function Resolve-ArcFleetAllowedMachineName {
    <#
        Returns the canonical allowlisted spelling so downstream calls, tags and Run Command names
        never depend on how the presenter typed the machine name.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $MachineName
    )

    if ([string]::IsNullOrWhiteSpace($MachineName)) {
        throw 'Pressure target machine names must be nonblank.'
    }
    $allowed = Get-ArcFleetAllowedPressureMachine
    foreach ($candidate in $allowed.Keys) {
        if ([string]::Equals([string] $candidate, $MachineName, [StringComparison]::OrdinalIgnoreCase)) {
            return [string] $candidate
        }
    }
    throw "Machine '$MachineName' is not allowlisted for pressure injection."
}

function New-ArcFleetCorrelationId {
    param(
        [datetime] $UtcNow = [datetime]::UtcNow
    )

    $timestamp = $UtcNow.ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'")
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    return "fleetops-$timestamp-$suffix"
}

function Assert-ArcFleetCorrelationId {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $CorrelationId
    )

    if ($CorrelationId -cnotmatch '^fleetops-\d{8}T\d{6}Z-[0-9a-f]{8}$') {
        throw "Correlation ID '$CorrelationId' must match 'fleetops-yyyyMMddTHHmmssZ-<8 hex>'."
    }
    $null = [DateTimeOffset]::ParseExact(
        $CorrelationId.Substring(9, 16),
        "yyyyMMdd'T'HHmmss'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
    return $CorrelationId
}

function Resolve-ArcFleetPressurePlan {
    <#
        Maps a demo profile onto the allowlisted machines. 'Split' is the default because it fires
        both Sev2 rules at once while halving the load placed on the shared ArcBox host.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Split', 'Both', 'Cpu', 'Memory')]
        [string] $PressureProfile,
        [Parameter(Mandatory)]
        [ValidateCount(1, 2)]
        [string[]] $MachineNames
    )

    $allowed = Get-ArcFleetAllowedPressureMachine
    $roleMap = @{}
    foreach ($role in Get-ArcFleetRoleMap) {
        $roleMap[$role.MachineName] = $role
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($requestedName in $MachineNames) {
        $machineName = Resolve-ArcFleetAllowedMachineName -MachineName $requestedName
        if (-not $seen.Add($machineName)) {
            throw "Machine '$machineName' was requested more than once."
        }
        if (-not $roleMap.ContainsKey($machineName)) {
            throw "Machine '$machineName' has no demo role mapping."
        }

        $mode = switch ($PressureProfile) {
            'Cpu' { 'Cpu' }
            'Memory' { 'Memory' }
            'Both' { 'Both' }
            'Split' {
                if ([string]::Equals($machineName, 'ArcBox-Win2K22', [StringComparison]::Ordinal)) {
                    'Memory'
                } else {
                    'Cpu'
                }
            }
        }

        $plan.Add([pscustomobject]@{
                MachineName = $machineName
                ResourceId = [string] $allowed[$machineName]
                Mode = $mode
                DemoRole = [string] $roleMap[$machineName].DemoRole
                DemoHost = [string] $roleMap[$machineName].DemoHost
            })
    }
    return $plan.ToArray()
}

function New-ArcFleetRunCommandName {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Cpu', 'Memory', 'Both')]
        [string] $Mode,
        [Parameter(Mandatory)]
        [string] $CorrelationId
    )

    $null = Assert-ArcFleetCorrelationId -CorrelationId $CorrelationId
    $name = ('perfops-{0}-{1}' -f $Mode.ToLowerInvariant(), $CorrelationId.Substring(9).Replace('T', '').Replace('Z', '')).ToLowerInvariant()
    if ($name -cnotmatch '^perfops-[a-z0-9-]{8,50}$') {
        throw "Generated Run Command name '$name' does not satisfy the required pattern."
    }
    return $name
}

function New-ArcFleetPressureScript {
    <#
        Builds the bounded remote payload. Pure function so the offline contract test can assert
        every safety property without touching Azure.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Cpu', 'Memory', 'Both')]
        [string] $Mode,
        [Parameter(Mandatory)]
        [string] $CorrelationId,
        [Parameter(Mandatory)]
        [int] $DurationSeconds,
        [Parameter(Mandatory)]
        [int] $MemoryMb,
        [Parameter(Mandatory)]
        [int] $MinimumAvailableMb,
        [Parameter(Mandatory)]
        [int] $CpuDutyCyclePercent,
        [int] $CpuWorkerCount = 0
    )

    $limits = Get-ArcFleetPressureSafetyLimit
    $null = Assert-ArcFleetCorrelationId -CorrelationId $CorrelationId

    if ($DurationSeconds -lt $limits.MinimumDurationSeconds -or
        $DurationSeconds -gt $limits.MaximumDurationSeconds) {
        throw "DurationSeconds must be between $($limits.MinimumDurationSeconds) and $($limits.MaximumDurationSeconds)."
    }
    if ($MemoryMb -lt 0 -or $MemoryMb -gt $limits.MaximumMemoryMb) {
        throw "MemoryMb must be between 0 and $($limits.MaximumMemoryMb)."
    }
    if ($MinimumAvailableMb -lt $limits.MinimumAvailableMb) {
        throw "MinimumAvailableMb must be at least $($limits.MinimumAvailableMb)."
    }
    if ($CpuDutyCyclePercent -lt $limits.MinimumCpuDutyCyclePercent -or
        $CpuDutyCyclePercent -gt $limits.MaximumCpuDutyCyclePercent) {
        throw "CpuDutyCyclePercent must be between $($limits.MinimumCpuDutyCyclePercent) and $($limits.MaximumCpuDutyCyclePercent)."
    }
    if ($CpuWorkerCount -lt 0 -or $CpuWorkerCount -gt $limits.MaximumCpuWorkerCount) {
        throw "CpuWorkerCount must be between 0 and $($limits.MaximumCpuWorkerCount)."
    }
    if (($Mode -eq 'Memory' -or $Mode -eq 'Both') -and $MemoryMb -le 0) {
        throw "Mode '$Mode' requires a positive MemoryMb."
    }

    $template = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fictional technical SRE demo. Bounded, self-terminating, non-persistent resource pressure.
# It creates no scheduled task, no service, no registry change beyond the Application event source
# already used by this demo repository, and it never reboots or reconfigures the machine.
$mode = '__MODE__'
$correlationId = '__CORRELATION_ID__'
$durationSeconds = __DURATION_SECONDS__
$requestedMemoryMb = __MEMORY_MB__
$minimumAvailableMb = __MINIMUM_AVAILABLE_MB__
$chunkMb = __CHUNK_MB__
$cpuDutyCyclePercent = __CPU_DUTY_CYCLE_PERCENT__
$requestedWorkerCount = __CPU_WORKER_COUNT__
$maximumMemoryMb = __MAXIMUM_MEMORY_MB__
$logName = 'Application'
$source = '__EVENT_SOURCE__'
$startEventId = __START_EVENT_ID__
$endEventId = __END_EVENT_ID__

if ($durationSeconds -lt __MINIMUM_DURATION_SECONDS__ -or $durationSeconds -gt __MAXIMUM_DURATION_SECONDS__) {
    throw "Duration is outside the approved demo range."
}
if ($requestedMemoryMb -lt 0 -or $requestedMemoryMb -gt $maximumMemoryMb) {
    throw "Requested memory is outside the approved demo range."
}
if ($minimumAvailableMb -lt __MINIMUM_AVAILABLE_FLOOR_MB__) {
    throw "The available memory floor is below the approved demo minimum."
}
if ($cpuDutyCyclePercent -lt __MINIMUM_DUTY_CYCLE_PERCENT__ -or $cpuDutyCyclePercent -gt 100) {
    throw "The CPU duty cycle is outside the approved demo range."
}

$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
$totalMemoryMb = [int] [math]::Round($operatingSystem.TotalVisibleMemorySize / 1024.0, 0)
$logicalProcessors = [int] $env:NUMBER_OF_PROCESSORS
if ($logicalProcessors -lt 1) { $logicalProcessors = 1 }
$workerCount = if ($requestedWorkerCount -le 0) { $logicalProcessors } else { [math]::Min($requestedWorkerCount, $logicalProcessors) }
$busyMilliseconds = [int] ($cpuDutyCyclePercent * 10)
$idleMilliseconds = 1000 - $busyMilliseconds

if (-not [Diagnostics.EventLog]::SourceExists($source)) {
    New-EventLog -LogName $logName -Source $source
}
$registeredLog = [Diagnostics.EventLog]::LogNameFromSourceName($source, '.')
if ($registeredLog -ne $logName) {
    throw "Event source '$source' is registered to '$registeredLog', not '$logName'."
}

function Get-AvailableMemoryMb {
    $snapshot = Get-CimInstance -ClassName Win32_OperatingSystem
    return [int] [math]::Round($snapshot.FreePhysicalMemory / 1024.0, 0)
}

$startedAtUtc = [DateTimeOffset]::UtcNow
$availableAtStartMb = Get-AvailableMemoryMb
Write-EventLog -LogName $logName -Source $source -EventId $startEventId -EntryType Warning -Message (
    [ordered]@{
        schemaVersion = 1
        demoSynthetic = $true
        correlationId = $correlationId
        scenario = 'arc-fleet-resource-pressure'
        eventType = 'SyntheticResourcePressureStarted'
        mode = $mode
        machine = $env:COMPUTERNAME
        totalMemoryMb = $totalMemoryMb
        availableMemoryMb = $availableAtStartMb
        requestedMemoryMb = $requestedMemoryMb
        minimumAvailableMb = $minimumAvailableMb
        cpuWorkerCount = $workerCount
        cpuDutyCyclePercent = $cpuDutyCyclePercent
        durationSeconds = $durationSeconds
        emittedAtUtc = $startedAtUtc.ToString('o')
        rootCauseClue = 'Fictional runaway identity worker process for demo only. No production workload is involved.'
    } | ConvertTo-Json -Compress
)

$process = [System.Diagnostics.Process]::GetCurrentProcess()
$originalPriority = $process.PriorityClass
$chunks = New-Object 'System.Collections.Generic.List[byte[]]'
$chunkBytes = $chunkMb * 1MB
$workers = New-Object 'System.Collections.Generic.List[object]'
$runspacePool = $null
$deadline = (Get-Date).AddSeconds($durationSeconds)
$peakAllocatedMb = 0
$minimumObservedAvailableMb = $availableAtStartMb
$releasedChunks = 0
$allocatesMemory = ($mode -eq 'Memory' -or $mode -eq 'Both')

function Add-PressureChunk {
    # Allocates and touches exactly one bounded chunk. Every caller has already checked both the
    # requested-total cap and the available-memory floor, so this never allocates unbounded memory.
    $chunk = New-Object byte[] $chunkBytes
    for ($offset = 0; $offset -lt $chunkBytes; $offset += 4096) { $chunk[$offset] = 1 }
    $chunks.Add($chunk)
}

try {
    $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal

    if ($allocatesMemory) {
        while ((Get-Date) -lt $deadline) {
            $allocatedMb = $chunks.Count * $chunkMb
            if (($allocatedMb + $chunkMb) -gt $requestedMemoryMb) { break }
            $availableMb = Get-AvailableMemoryMb
            if ($availableMb -lt $minimumObservedAvailableMb) { $minimumObservedAvailableMb = $availableMb }
            if (($availableMb - $chunkMb) -lt $minimumAvailableMb) { break }

            Add-PressureChunk
            $peakAllocatedMb = [math]::Max($peakAllocatedMb, $chunks.Count * $chunkMb)
        }
    }

    if (($mode -eq 'Cpu' -or $mode -eq 'Both') -and (Get-Date) -lt $deadline) {
        $workerScript = {
            param([long] $DeadlineTicks, [int] $BusyMilliseconds, [int] $IdleMilliseconds)
            $workerDeadline = [datetime]::new($DeadlineTicks, [System.DateTimeKind]::Local)
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $accumulator = 0.0
            while ([datetime]::Now -lt $workerDeadline) {
                $stopwatch.Restart()
                while ($stopwatch.ElapsedMilliseconds -lt $BusyMilliseconds) {
                    $accumulator += [math]::Sqrt([double] $stopwatch.ElapsedTicks)
                }
                if ($IdleMilliseconds -gt 0) { Start-Sleep -Milliseconds $IdleMilliseconds }
            }
            return $accumulator
        }
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $workerCount)
        $runspacePool.Open()
        for ($workerIndex = 0; $workerIndex -lt $workerCount; $workerIndex++) {
            $shell = [powershell]::Create()
            $shell.RunspacePool = $runspacePool
            $null = $shell.AddScript($workerScript).
                AddArgument($deadline.Ticks).
                AddArgument($busyMilliseconds).
                AddArgument($idleMilliseconds)
            $workers.Add([pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() })
        }
    }

    while ((Get-Date) -lt $deadline) {
        $availableMb = Get-AvailableMemoryMb
        if ($availableMb -lt $minimumObservedAvailableMb) { $minimumObservedAvailableMb = $availableMb }
        if ($availableMb -lt $minimumAvailableMb -and $chunks.Count -gt 0) {
            $chunks.RemoveAt($chunks.Count - 1)
            $releasedChunks++
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
        } elseif ($allocatesMemory -and
            ((($chunks.Count * $chunkMb) + $chunkMb) -le $requestedMemoryMb) -and
            (($availableMb - $chunkMb) -ge $minimumAvailableMb)) {
            # Closed loop top up. Keeps the pressure at the intended level for the whole window if
            # the guest reclaims pages, while never crossing the requested total or the floor.
            Add-PressureChunk
            $peakAllocatedMb = [math]::Max($peakAllocatedMb, $chunks.Count * $chunkMb)
        }
        Start-Sleep -Seconds 5
    }
} finally {
    foreach ($worker in $workers) {
        try { $null = $worker.Shell.EndInvoke($worker.Handle) } catch { }
        try { $worker.Shell.Dispose() } catch { }
    }
    if ($null -ne $runspacePool) {
        try { $runspacePool.Close() } catch { }
        try { $runspacePool.Dispose() } catch { }
    }
    $chunks.Clear()
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect()
    try { $process.PriorityClass = $originalPriority } catch { }

    $completedAtUtc = [DateTimeOffset]::UtcNow
    $availableAtEndMb = Get-AvailableMemoryMb
    Write-EventLog -LogName $logName -Source $source -EventId $endEventId -EntryType Warning -Message (
        [ordered]@{
            schemaVersion = 1
            demoSynthetic = $true
            correlationId = $correlationId
            scenario = 'arc-fleet-resource-pressure'
            eventType = 'SyntheticResourcePressureCompleted'
            mode = $mode
            machine = $env:COMPUTERNAME
            peakAllocatedMb = $peakAllocatedMb
            releasedChunks = $releasedChunks
            minimumObservedAvailableMb = $minimumObservedAvailableMb
            availableMemoryMb = $availableAtEndMb
            cpuWorkerCount = $workerCount
            elapsedSeconds = [int] ($completedAtUtc - $startedAtUtc).TotalSeconds
            emittedAtUtc = $completedAtUtc.ToString('o')
            rootCauseClue = 'Fictional runaway identity worker process was stopped by its own deadline.'
        } | ConvertTo-Json -Compress
    )
}

[ordered]@{
    demoSynthetic = $true
    correlationId = $correlationId
    mode = $mode
    machine = $env:COMPUTERNAME
    totalMemoryMb = $totalMemoryMb
    peakAllocatedMb = $peakAllocatedMb
    minimumObservedAvailableMb = $minimumObservedAvailableMb
    releasedChunks = $releasedChunks
    cpuWorkerCount = $workerCount
    cpuDutyCyclePercent = $cpuDutyCyclePercent
    durationSeconds = $durationSeconds
} | ConvertTo-Json -Compress
'@

    $replacements = [ordered]@{
        '__MODE__' = $Mode
        '__CORRELATION_ID__' = $CorrelationId
        '__DURATION_SECONDS__' = [string] $DurationSeconds
        '__MEMORY_MB__' = [string] $MemoryMb
        '__MINIMUM_AVAILABLE_MB__' = [string] $MinimumAvailableMb
        '__CHUNK_MB__' = [string] $limits.MemoryChunkMb
        '__CPU_DUTY_CYCLE_PERCENT__' = [string] $CpuDutyCyclePercent
        '__CPU_WORKER_COUNT__' = [string] $CpuWorkerCount
        '__MAXIMUM_MEMORY_MB__' = [string] $limits.MaximumMemoryMb
        '__EVENT_SOURCE__' = $limits.EventSource
        '__START_EVENT_ID__' = [string] $limits.StartEventId
        '__END_EVENT_ID__' = [string] $limits.EndEventId
        '__MINIMUM_DURATION_SECONDS__' = [string] $limits.MinimumDurationSeconds
        '__MAXIMUM_DURATION_SECONDS__' = [string] $limits.MaximumDurationSeconds
        '__MINIMUM_AVAILABLE_FLOOR_MB__' = [string] $limits.MinimumAvailableMb
        '__MINIMUM_DUTY_CYCLE_PERCENT__' = [string] $limits.MinimumCpuDutyCyclePercent
    }
    $script = $template
    foreach ($token in $replacements.Keys) {
        $script = $script.Replace($token, [string] $replacements[$token])
    }
    if ($script -match '__[A-Z_]+__') {
        throw 'The generated pressure script still contains an unresolved placeholder.'
    }
    return $script
}

function Get-ArcFleetPressureTargets {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [ValidateCount(1, 2)]
        [string[]] $MachineNames
    )

    $allowed = Get-ArcFleetAllowedPressureMachine
    $targets = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($requestedName in $MachineNames) {
        $machineName = Resolve-ArcFleetAllowedMachineName -MachineName $requestedName
        $requestedResourceId = Get-ArcIdentityMachineResourceId `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -MachineName $machineName
        if (-not [string]::Equals(
                [string] $allowed[$machineName],
                $requestedResourceId,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Resource ID '$requestedResourceId' does not match the allowlisted ID for '$machineName'."
        }
        if (-not $seen.Add($machineName)) {
            throw "Machine '$machineName' was requested more than once."
        }

        $machine = Invoke-ArcIdentityAzJson `
            -Arguments @(
                'connectedmachine', 'show',
                '--subscription', $SubscriptionId,
                '--resource-group', $ResourceGroupName,
                '--name', $machineName,
                '--output', 'json'
            ) `
            -FailureMessage "Unable to read Arc machine '$machineName'."
        $properties = Get-ArcIdentityOptionalPropertyValue -InputObject $machine -PropertyName 'properties'
        $status = Get-ArcIdentityFirstPropertyValue -InputObjects @($machine, $properties) -PropertyNames @('status')
        if ($status -ne 'Connected') {
            throw "Arc machine '$machineName' must be Connected before pressure is applied. Current status: '$status'."
        }
        $osType = Get-ArcIdentityFirstPropertyValue -InputObjects @($machine, $properties) -PropertyNames @('osType', 'osName')
        if ([string] $osType -notmatch '(?i)windows') {
            throw "Arc machine '$machineName' must report a Windows operating system. Current: '$osType'."
        }
        $location = Get-ArcIdentityOptionalPropertyValue -InputObject $machine -PropertyName 'location'
        if ([string]::IsNullOrWhiteSpace([string] $location)) {
            throw "Arc machine '$machineName' must expose a nonblank location."
        }

        $targets.Add([pscustomobject]@{
                MachineName = $machineName
                ResourceId = [string] $allowed[$machineName]
                NormalizedResourceId = ([string] $allowed[$machineName]).ToLowerInvariant()
                Location = [string] $location
            })
    }
    return $targets.ToArray()
}

function Get-ArcFleetRunCommandList {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $MachineName
    )

    return @(
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
}

function Get-ArcFleetRunCommand {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $MachineName,
        [Parameter(Mandatory)]
        [ValidatePattern('^perfops-[a-z0-9-]{8,50}$')]
        [string] $RunCommandName
    )

    return Invoke-ArcIdentityAzJson `
        -Arguments @(
            'connectedmachine', 'run-command', 'show',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--machine-name', $MachineName,
            '--name', $RunCommandName,
            '--output', 'json'
        ) `
        -FailureMessage "Unable to read Run Command '$RunCommandName' on '$MachineName'."
}

function Start-ArcFleetRunCommand {
    <#
        Creates one asynchronous, bounded Arc Run Command. Asynchronous execution is required so a
        14 minute demo payload never blocks the presenter's console, and so the recovery script can
        always reach the machine while the payload is still running.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $MachineName,
        [Parameter(Mandatory)]
        [string] $Location,
        [Parameter(Mandatory)]
        [ValidatePattern('^perfops-[a-z0-9-]{8,50}$')]
        [string] $RunCommandName,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ScriptText,
        [Parameter(Mandatory)]
        [ValidateRange(360, 1200)]
        [int] $TimeoutSeconds
    )

    $existing = @(Get-ArcFleetRunCommandList `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -MachineName $MachineName)
    if ($existing | Where-Object { $_.name -eq $RunCommandName }) {
        throw "Run Command '$RunCommandName' already exists on '$MachineName'; refusing to overwrite it."
    }

    $machineResourceId = Get-ArcIdentityMachineResourceId `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -MachineName $MachineName
    $url = "https://management.azure.com${machineResourceId}/runCommands/${RunCommandName}?api-version=2025-01-13"
    $body = [ordered]@{
        location = $Location
        tags = [ordered]@{
            purpose = 'sre-agent-demo'
            environment = 'demo'
            dataClassification = 'synthetic'
            scenario = 'arc-fleet-observability'
        }
        properties = [ordered]@{
            source = [ordered]@{
                script = $ScriptText
            }
            timeoutInSeconds = $TimeoutSeconds
            asyncExecution = $true
        }
    }
    Invoke-ArcIdentityArmRestWithJsonBody `
        -Method 'put' `
        -Url $url `
        -Headers @('Content-Type=application/json') `
        -Body $body `
        -Output 'none' `
        -FailureMessage "Unable to create Run Command '$RunCommandName' on '$MachineName'."
    return $RunCommandName
}

function Remove-ArcFleetRunCommand {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,
        [Parameter(Mandatory)]
        [string] $MachineName,
        [Parameter(Mandatory)]
        [ValidatePattern('^perfops-[a-z0-9-]{8,50}$')]
        [string] $RunCommandName
    )

    Invoke-ArcIdentityAzNoOutput `
        -Arguments @(
            'connectedmachine', 'run-command', 'delete',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--machine-name', $MachineName,
            '--name', $RunCommandName,
            '--yes'
        ) `
        -FailureMessage "Unable to delete Run Command '$RunCommandName' on '$MachineName'."
}

function Get-ArcFleetRunCommandOutcome {
    param(
        [AllowNull()]
        [object] $RunCommand
    )

    if ($null -eq $RunCommand) {
        return [pscustomobject]@{ ProvisioningState = 'Unknown'; ExecutionState = 'Unknown'; ExitCode = $null; Output = ''; Error = '' }
    }
    $properties = Get-ArcIdentityOptionalPropertyValue -InputObject $RunCommand -PropertyName 'properties'
    $provisioningState = [string] (Get-ArcIdentityFirstPropertyValue -InputObjects @($RunCommand, $properties) -PropertyNames @('provisioningState'))
    $instanceView = Get-ArcIdentityFirstPropertyValue -InputObjects @($RunCommand, $properties) -PropertyNames @('instanceView')
    $executionState = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $instanceView -PropertyName 'executionState')
    $exitCode = Get-ArcIdentityOptionalPropertyValue -InputObject $instanceView -PropertyName 'exitCode'
    $output = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $instanceView -PropertyName 'output')
    $errorText = [string] (Get-ArcIdentityOptionalPropertyValue -InputObject $instanceView -PropertyName 'error')

    return [pscustomobject]@{
        ProvisioningState = if ([string]::IsNullOrWhiteSpace($provisioningState)) { 'Unknown' } else { $provisioningState }
        ExecutionState = if ([string]::IsNullOrWhiteSpace($executionState)) { 'Unknown' } else { $executionState }
        ExitCode = $exitCode
        Output = $output
        Error = $errorText
    }
}

function Get-ArcFleetKqlQuery {
    <#
        Loads one of the reviewed, aggregate-only queries from kql/arc-fleet so scripts and the
        agent skill always execute exactly the text that was reviewed in the repository.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryRoot,
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9.-]+\.kql$')]
        [string] $FileName
    )

    $path = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($RepositoryRoot, 'kql', 'arc-fleet', $FileName)
    )
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Reviewed KQL asset '$FileName' was not found at '$path'."
    }
    $text = [System.IO.File]::ReadAllText($path)
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Reviewed KQL asset '$FileName' is empty."
    }
    return $text
}
