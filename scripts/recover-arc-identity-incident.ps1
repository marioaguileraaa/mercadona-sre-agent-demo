#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $SubscriptionId = '5305e853-a63b-4b82-9a3f-6fde18c1a798',
    [string] $TenantId = '9b1d3cd8-5db7-4564-905d-4d2eba7b66d5',
    [string] $ArcResourceGroupName = 'rg-arcbox-itpro-weu-002',
    [string] $Location = 'westeurope',
    [string] $WorkspaceName = 'law-arcbox-demo-001',
    [string[]] $MachineNames = @('ArcBox-Win2K22', 'ArcBox-Win2K25'),
    [Parameter(Mandatory)]
    [ValidatePattern('^SYNTH-ID-[0-9]{8}T[0-9]{6}Z-[A-F0-9]{8}$')]
    [string] $CorrelationId,
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
        "Emit one idempotent synthetic recovery event per Arc machine for correlationId=$CorrelationId"
    )) {
    return
}

$correlationIdLiteral = $CorrelationId | ConvertTo-Json -Compress
$remoteScriptTemplate = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($null -eq $identity.User -or $identity.User.Value -ne 'S-1-5-18') {
    throw 'The synthetic recovery event must be emitted by LocalSystem.'
}

$source = 'Mercadona.IdentityOps'
$logName = 'Application'
$correlationId = __CORRELATION_ID__
$incidentEventId = 4101
$recoveryEventId = 4102
$correlationStart = [DateTimeOffset]::ParseExact(
    $correlationId.Substring(9, 16),
    "yyyyMMdd'T'HHmmss'Z'",
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
).UtcDateTime.AddMinutes(-5)

if (-not [Diagnostics.EventLog]::SourceExists($source)) {
    throw "Synthetic event source '$source' does not exist. Start the bounded incident before recovery."
}
$registeredLog = [Diagnostics.EventLog]::LogNameFromSourceName($source, '.')
if ($registeredLog -ne $logName) {
    throw "Event source '$source' is registered to '$registeredLog', not '$logName'."
}

$incidentCount = 0
$recoveryCount = 0
try {
    Get-WinEvent -FilterHashtable @{
            LogName = $logName
            ProviderName = $source
            Id = @($incidentEventId, $recoveryEventId)
            StartTime = $correlationStart
        } -ErrorAction Stop |
        ForEach-Object {
            $candidateEvent = $_
            $existingPayload = $candidateEvent.Message | ConvertFrom-Json
            if ($existingPayload.demoSynthetic -eq $true -and
                $existingPayload.correlationId -eq $correlationId) {
                if ($candidateEvent.Id -eq $incidentEventId -and
                    $existingPayload.eventType -eq 'SyntheticAdfsTokenFailure') {
                    $incidentCount++
                }
                if ($candidateEvent.Id -eq $recoveryEventId -and
                    $existingPayload.eventType -eq 'SyntheticAdfsRecovery') {
                    $recoveryCount++
                }
            }
        }
} catch {
    if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
        throw
    }
}

if ($incidentCount -eq 0) {
    throw "No bounded synthetic incident events exist for correlation '$correlationId'."
}
if ($recoveryCount -gt 1) {
    throw "Correlation '$correlationId' has more than one recovery event."
}

if ($recoveryCount -eq 0) {
    $payload = [ordered]@{
        schemaVersion = 1
        demoSynthetic = $true
        correlationId = $correlationId
        scenario = 'adfs-token-failure-burst'
        eventType = 'SyntheticAdfsRecovery'
        priorSyntheticFailureEvents = $incidentCount
        machine = $env:COMPUTERNAME
        emittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        rootCauseClue = 'Synthetic identity dependency restored; no real identity service was changed.'
    } | ConvertTo-Json -Compress
    Write-EventLog `
        -LogName $logName `
        -Source $source `
        -EventId $recoveryEventId `
        -EntryType Information `
        -Message $payload
}

[ordered]@{
    demoSynthetic = $true
    correlationId = $correlationId
    eventId = $recoveryEventId
    priorSyntheticFailureEvents = $incidentCount
    recoveryAlreadyPresent = $recoveryCount -eq 1
} | ConvertTo-Json -Compress
'@
$remoteScript = $remoteScriptTemplate.Replace('__CORRELATION_ID__', $correlationIdLiteral)

foreach ($machineName in $MachineNames) {
    $machineSlug = ($machineName.ToLowerInvariant() -replace '[^a-z0-9]', '')
    $runCommandName = "identityops-r-$($machineSlug.Substring(0, [Math]::Min(12, $machineSlug.Length)))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $null = Invoke-ArcIdentityRunCommand `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $machineName `
        -RunCommandName $runCommandName `
        -ScriptText $remoteScript
    Write-Host "Synthetic recovery event completed on '$machineName'."
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
$verificationQuery = @"
Event
| where TimeGenerated >= ago(30m)
| where EventLog == "Application" and Source == "Mercadona.IdentityOps" and EventID == 4102
| where RenderedDescription contains '"demoSynthetic":true'
| where RenderedDescription contains "$correlationIdKql"
| summarize RecoveryEvents=count(), MachineCount=dcount(tolower(_ResourceId))
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
        [int] $rows[0].RecoveryEvents -eq $MachineNames.Count -and
        [int] $rows[0].MachineCount -eq $MachineNames.Count) {
        $ingested = $true
        break
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)
if (-not $ingested) {
    throw "Log Analytics did not expose exactly one recovery event per target machine within $IngestionTimeoutSeconds seconds."
}

Write-Host "Synthetic identity recovery verified. correlationId=$CorrelationId recoveryEvents=$($MachineNames.Count)"
