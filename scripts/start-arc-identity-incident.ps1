#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $TenantId = '9b1d3cd8-5db7-4564-905d-4d2eba7b66d5',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $Location = 'westeurope',
    [string] $WorkspaceName = 'law-arcbox-demo-001',
    [string[]] $MachineNames = @('ArcBox-Win2K22', 'ArcBox-Win2K25'),
    [ValidateRange(8, 20)]
    [int] $EventsPerMachine = 12,
    [ValidatePattern('^SYNTH-ID-[0-9]{8}T[0-9]{6}Z-[A-F0-9]{8}$')]
    [string] $CorrelationId = "SYNTH-ID-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant())",
    [ValidateRange(60, 1200)]
    [int] $IngestionTimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ArcIdentity.Common.ps1"

Assert-ArcIdentityAzureContext `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupNames @($ArcResourceGroupName)
$targetResources = @(
    Get-ArcIdentitySyntheticTargetResources `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineNames $MachineNames
)
$null = Get-ArcIdentityTargetMachines `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ArcResourceGroupName `
    -Location $Location `
    -MachineNames @($targetResources.MachineName)
foreach ($targetResource in $targetResources) {
    $null = Assert-ArcIdentityAmaExtension `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $targetResource.MachineName
}

if (-not $PSCmdlet.ShouldProcess(
        ($targetResources.MachineName -join ', '),
        "Emit at most $EventsPerMachine explicitly synthetic identity events per Arc machine with correlationId=$CorrelationId"
    )) {
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
$workspaceCustomerId = Get-ArcIdentityOptionalPropertyValue `
    -InputObject $workspace `
    -PropertyName 'customerId'
if ($workspaceCustomerId -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string] $workspaceCustomerId)) {
    throw "Workspace '$WorkspaceName' did not expose a customerId."
}

$correlationIdLiteral = $CorrelationId | ConvertTo-Json -Compress
$stateResolverDefinition = "function Resolve-ArcIdentitySyntheticEventState {`n$((Get-Command Resolve-ArcIdentitySyntheticEventState).Definition)`n}"
$remoteScriptTemplate = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

__STATE_RESOLVER__

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($null -eq $identity.User -or $identity.User.Value -ne 'S-1-5-18') {
    throw 'The synthetic event source must be configured by LocalSystem.'
}

$source = 'Mercadona.IdentityOps'
$logName = 'Application'
$correlationId = __CORRELATION_ID__
$burstCount = __BURST_COUNT__
$authoritativeIncidentCount = __AUTHORITATIVE_INCIDENT_COUNT__
$authoritativeRecoveryCount = __AUTHORITATIVE_RECOVERY_COUNT__
$eventId = 4101
$recoveryEventId = 4102
$correlationStart = [DateTimeOffset]::ParseExact(
    $correlationId.Substring(9, 16),
    "yyyyMMdd'T'HHmmss'Z'",
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
).UtcDateTime
$correlationStart = [datetime]::new(
    $correlationStart.Year,
    $correlationStart.Month,
    $correlationStart.Day,
    $correlationStart.Hour,
    0,
    0,
    [DateTimeKind]::Utc
)

if (-not [Diagnostics.EventLog]::SourceExists($source)) {
    New-EventLog -LogName $logName -Source $source
}
$registeredLog = [Diagnostics.EventLog]::LogNameFromSourceName($source, '.')
if ($registeredLog -ne $logName) {
    throw "Event source '$source' is registered to '$registeredLog', not '$logName'."
}

$localIncidentCount = 0
$localRecoveryCount = 0
try {
    Get-WinEvent -FilterHashtable @{
            LogName = $logName
            ProviderName = $source
            Id = @($eventId, $recoveryEventId)
            StartTime = $correlationStart
        } -ErrorAction Stop |
        ForEach-Object {
            $candidateEvent = $_
            $existingPayload = $candidateEvent.Message | ConvertFrom-Json
            if ($existingPayload.demoSynthetic -eq $true -and
                $existingPayload.correlationId -eq $correlationId -and
                $existingPayload.scenario -eq 'adfs-token-failure-burst') {
                if ($candidateEvent.Id -eq $eventId -and
                    $existingPayload.eventType -eq 'SyntheticAdfsTokenFailure') {
                    $localIncidentCount++
                }
                if ($candidateEvent.Id -eq $recoveryEventId -and
                    $existingPayload.eventType -eq 'SyntheticAdfsRecovery') {
                    $localRecoveryCount++
                }
            }
        }
} catch {
    if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
        throw
    }
}

$state = Resolve-ArcIdentitySyntheticEventState `
    -Operation Start `
    -LocalIncidentCount $localIncidentCount `
    -LocalRecoveryCount $localRecoveryCount `
    -AuthoritativeIncidentCount $authoritativeIncidentCount `
    -AuthoritativeRecoveryCount $authoritativeRecoveryCount `
    -IncidentBound $burstCount `
    -CorrelationId $correlationId

for (
    $sequence = $state.ExistingIncidentCount + 1
    $sequence -le $burstCount
    $sequence++
) {
    $payload = [ordered]@{
        schemaVersion = 1
        demoSynthetic = $true
        correlationId = $correlationId
        scenario = 'adfs-token-failure-burst'
        eventType = 'SyntheticAdfsTokenFailure'
        sequence = $sequence
        burstSize = $burstCount
        machine = $env:COMPUTERNAME
        emittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        rootCauseClue = 'Fictional token-validation dependency timeout for demo only.'
    } | ConvertTo-Json -Compress
    Write-EventLog `
        -LogName $logName `
        -Source $source `
        -EventId $eventId `
        -EntryType Warning `
        -Message $payload
}

[ordered]@{
    demoSynthetic = $true
    correlationId = $correlationId
    eventId = $eventId
    requested = $burstCount
    preExisting = $state.ExistingIncidentCount
    emitted = $state.EmitCount
} | ConvertTo-Json -Compress
'@

foreach ($targetResource in $targetResources) {
    $authoritativeRows = @(
        Get-ArcIdentitySyntheticEventCountRows `
            -SubscriptionId $SubscriptionId `
            -WorkspaceCustomerId $workspaceCustomerId `
            -CorrelationId $CorrelationId `
            -TargetResources $targetResources
    )
    $authoritativeCount = @(
        $authoritativeRows | Where-Object {
            [string]::Equals(
                [string] $_.NormalizedResourceId,
                [string] $targetResource.NormalizedResourceId,
                [StringComparison]::Ordinal
            )
        }
    )[0]
    $null = Resolve-ArcIdentitySyntheticEventState `
        -Operation Start `
        -LocalIncidentCount 0 `
        -LocalRecoveryCount 0 `
        -AuthoritativeIncidentCount ([int] $authoritativeCount.IncidentCount) `
        -AuthoritativeRecoveryCount ([int] $authoritativeCount.RecoveryCount) `
        -IncidentBound $EventsPerMachine `
        -CorrelationId $CorrelationId

    $remoteScript = $remoteScriptTemplate.
        Replace('__STATE_RESOLVER__', $stateResolverDefinition).
        Replace('__CORRELATION_ID__', $correlationIdLiteral).
        Replace('__BURST_COUNT__', [string] $EventsPerMachine).
        Replace('__AUTHORITATIVE_INCIDENT_COUNT__', [string] $authoritativeCount.IncidentCount).
        Replace('__AUTHORITATIVE_RECOVERY_COUNT__', [string] $authoritativeCount.RecoveryCount)
    $machineName = [string] $targetResource.MachineName
    $machineSlug = ($machineName.ToLowerInvariant() -replace '[^a-z0-9]', '')
    $runCommandName = "identityops-i-$($machineSlug.Substring(0, [Math]::Min(12, $machineSlug.Length)))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $null = Invoke-ArcIdentityRunCommand `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $machineName `
        -RunCommandName $runCommandName `
        -ScriptText $remoteScript
    Write-Host "Synthetic event burst completed on '$machineName'."
}

$expectedEvents = $targetResources.Count * $EventsPerMachine
$deadline = (Get-Date).AddSeconds($IngestionTimeoutSeconds)
$ingested = $false
do {
    $verificationRows = @(
        Get-ArcIdentitySyntheticEventCountRows `
            -SubscriptionId $SubscriptionId `
            -WorkspaceCustomerId $workspaceCustomerId `
            -CorrelationId $CorrelationId `
            -TargetResources $targetResources
    )
    if ($verificationRows | Where-Object {
            [int] $_.IncidentCount -gt $EventsPerMachine -or
            [int] $_.RecoveryCount -gt 0
        }) {
        throw "Log Analytics exceeded the bounded incident state or exposed a recovery for correlation '$CorrelationId'."
    }
    $exactRows = @(
        $verificationRows | Where-Object {
            [int] $_.IncidentCount -eq $EventsPerMachine -and
            [int] $_.RecoveryCount -eq 0
        }
    )
    if ($exactRows.Count -eq $targetResources.Count) {
        $ingested = $true
        break
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)
if (-not $ingested) {
    throw "Log Analytics did not expose exactly $expectedEvents bounded synthetic events across both machines within $IngestionTimeoutSeconds seconds."
}

Write-Host "Synthetic identity incident verified. correlationId=$CorrelationId events=$expectedEvents machines=$($targetResources.Count)"
Write-Host "Recover with: .\scripts\recover-arc-identity-incident.ps1 -CorrelationId '$CorrelationId'"
