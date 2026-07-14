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

if (-not $PSCmdlet.ShouldProcess(
        ($MachineNames -join ', '),
        "Emit at most $EventsPerMachine explicitly synthetic identity events per Arc machine with correlationId=$CorrelationId"
    )) {
    return
}

$correlationIdLiteral = $CorrelationId | ConvertTo-Json -Compress
$remoteScriptTemplate = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($null -eq $identity.User -or $identity.User.Value -ne 'S-1-5-18') {
    throw 'The synthetic event source must be configured by LocalSystem.'
}

$source = 'Mercadona.IdentityOps'
$logName = 'Application'
$correlationId = __CORRELATION_ID__
$burstCount = __BURST_COUNT__
$eventId = 4101
$correlationStart = [DateTimeOffset]::ParseExact(
    $correlationId.Substring(9, 16),
    "yyyyMMdd'T'HHmmss'Z'",
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
).UtcDateTime.AddMinutes(-5)

if (-not [Diagnostics.EventLog]::SourceExists($source)) {
    New-EventLog -LogName $logName -Source $source
}
$registeredLog = [Diagnostics.EventLog]::LogNameFromSourceName($source, '.')
if ($registeredLog -ne $logName) {
    throw "Event source '$source' is registered to '$registeredLog', not '$logName'."
}

$existingCount = 0
try {
    Get-WinEvent -FilterHashtable @{
            LogName = $logName
            ProviderName = $source
            Id = $eventId
            StartTime = $correlationStart
        } -ErrorAction Stop |
        ForEach-Object {
            $existingPayload = $_.Message | ConvertFrom-Json
            if ($existingPayload.demoSynthetic -eq $true -and
                $existingPayload.correlationId -eq $correlationId -and
                $existingPayload.eventType -eq 'SyntheticAdfsTokenFailure') {
                $existingCount++
            }
        }
} catch {
    if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
        throw
    }
}

if ($existingCount -gt $burstCount) {
    throw "Correlation '$correlationId' already has $existingCount events, above the requested bounded count $burstCount."
}

for ($sequence = $existingCount + 1; $sequence -le $burstCount; $sequence++) {
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
    preExisting = $existingCount
    emitted = $burstCount - $existingCount
} | ConvertTo-Json -Compress
'@
$remoteScript = $remoteScriptTemplate.
    Replace('__CORRELATION_ID__', $correlationIdLiteral).
    Replace('__BURST_COUNT__', [string] $EventsPerMachine)

foreach ($machineName in $MachineNames) {
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

$workspace = Invoke-ArcIdentityAzJson `
    -Arguments @(
        'monitor', 'log-analytics', 'workspace', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ArcResourceGroupName,
        '--workspace-name', $WorkspaceName,
        '--output', 'json'
    ) `
    -FailureMessage "Unable to read Log Analytics workspace '$WorkspaceName'."
$correlationIdKql = $CorrelationId.Replace("'", "''")
$expectedEvents = $MachineNames.Count * $EventsPerMachine
$verificationQuery = @"
Event
| where TimeGenerated >= ago(30m)
| where EventLog == "Application" and Source == "Mercadona.IdentityOps" and EventID == 4101
| where RenderedDescription contains '"demoSynthetic":true'
| where RenderedDescription contains "$correlationIdKql"
| summarize EventCount=count(), MachineCount=dcount(tolower(_ResourceId))
"@
$deadline = (Get-Date).AddSeconds($IngestionTimeoutSeconds)
$ingested = $false
do {
    $rows = @(
        Get-ArcIdentityResponseItems -Response (
            Invoke-ArcIdentityLogAnalyticsQuery `
                -SubscriptionId $SubscriptionId `
                -WorkspaceCustomerId ([string] $workspace.customerId) `
                -Query $verificationQuery
        ) -PropertyNames @('tables', 'value')
    )
    if ($rows.Count -eq 1 -and
        [int] $rows[0].EventCount -eq $expectedEvents -and
        [int] $rows[0].MachineCount -eq $MachineNames.Count) {
        $ingested = $true
        break
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)
if (-not $ingested) {
    throw "Log Analytics did not expose exactly $expectedEvents bounded synthetic events across both machines within $IngestionTimeoutSeconds seconds."
}

Write-Host "Synthetic identity incident verified. correlationId=$CorrelationId events=$expectedEvents"
Write-Host "Recover with: .\scripts\recover-arc-identity-incident.ps1 -CorrelationId '$CorrelationId'"
