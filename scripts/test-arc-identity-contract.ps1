#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$requiredDisclaimer = 'Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.'

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,
        [Parameter(Mandatory)]
        [string] $Case
    )

    if (-not $Condition) {
        throw "$Case failed."
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [string] $Source,
        [Parameter(Mandatory)]
        [string] $Expected,
        [Parameter(Mandatory)]
        [string] $Case
    )

    if (-not $Source.Contains($Expected, [StringComparison]::Ordinal)) {
        throw "$Case failed. Missing '$Expected'."
    }
}

function Assert-NotMatches {
    param(
        [Parameter(Mandatory)]
        [string] $Source,
        [Parameter(Mandatory)]
        [string] $Pattern,
        [Parameter(Mandatory)]
        [string] $Case
    )

    if ($Source -match $Pattern) {
        throw "$Case failed. Disallowed pattern '$Pattern' was found."
    }
}

function ConvertTo-CanonicalJson {
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $members = foreach ($key in @($Value.Keys | Sort-Object)) {
            if ([string] $key -eq '_generator') {
                continue
            }
            $encodedKey = ConvertTo-Json -InputObject ([string] $key) -Compress
            "$encodedKey`:$(ConvertTo-CanonicalJson -Value $Value[$key])"
        }
        return "{$($members -join ',')}"
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = foreach ($item in $Value) {
            ConvertTo-CanonicalJson -Value $item
        }
        return "[$($items -join ',')]"
    }
    return ConvertTo-Json -InputObject $Value -Compress
}

$newScriptNames = @(
    'ArcIdentity.Common.ps1',
    'deploy-arc-identity.ps1',
    'verify-arc-identity.ps1',
    'configure-arc-identity-sre-agent.ps1',
    'start-arc-identity-incident.ps1',
    'recover-arc-identity-incident.ps1'
)
$scriptSources = @{}
foreach ($scriptName in $newScriptNames) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Case "Script exists: $scriptName"
    $tokens = $null
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref] $tokens,
        [ref] $parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "$scriptName has parser errors: $($parseErrors.Message -join '; ')"
    }
    $source = Get-Content -LiteralPath $scriptPath -Raw
    $scriptSources[$scriptName] = $source
    Assert-Contains -Source $source -Expected 'Set-StrictMode -Version Latest' -Case "$scriptName strict mode"
    Assert-Contains -Source $source -Expected '$ErrorActionPreference = ''Stop''' -Case "$scriptName stop-on-error"

    $remoteScriptStrings = $scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Value.Contains('Write-EventLog', [StringComparison]::Ordinal)
    }, $true)
    foreach ($remoteScriptString in $remoteScriptStrings) {
        $remoteTokens = $null
        $remoteErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $remoteScriptString.Value,
            [ref] $remoteTokens,
            [ref] $remoteErrors
        ) | Out-Null
        if ($remoteErrors.Count -gt 0) {
            throw "Embedded Run Command script in $scriptName has parser errors: $($remoteErrors.Message -join '; ')"
        }
        if ($IsWindows) {
            $remoteSourceBase64 = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($remoteScriptString.Value)
            )
            $windowsParserProbe = @"
`$remoteSource = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$remoteSourceBase64'))
`$tokens = `$null
`$errors = `$null
[System.Management.Automation.Language.Parser]::ParseInput(
    `$remoteSource,
    [ref] `$tokens,
    [ref] `$errors
) | Out-Null
if (`$errors.Count -gt 0) {
    [Console]::Error.WriteLine((`$errors.Message -join '; '))
    exit 1
}
"@
            $encodedParserProbe = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($windowsParserProbe)
            )
            & powershell.exe `
                -NoLogo `
                -NoProfile `
                -NonInteractive `
                -EncodedCommand $encodedParserProbe
            if ($LASTEXITCODE -ne 0) {
                throw "Embedded Run Command script in $scriptName is not valid Windows PowerShell 5.1."
            }
        }
    }
}

. "$PSScriptRoot\ArcIdentity.Common.ps1"
$testObject = '{"properties":{"value":"expected"}}' | ConvertFrom-Json
Assert-True `
    -Condition (
        (Get-ArcIdentityOptionalPropertyValue -InputObject $testObject -PropertyName 'missing') -eq $null
    ) `
    -Case 'Optional strict-mode property lookup'
Assert-True `
    -Condition (
        (Get-ArcIdentityFirstPropertyValue `
            -InputObjects @($testObject, $testObject.properties) `
            -PropertyNames @('missing', 'value')) -eq 'expected'
    ) `
    -Case 'First strict-mode property lookup'
Assert-True `
    -Condition (
        (Get-ArcIdentityMachineResourceId `
            -SubscriptionId 'sub' `
            -ResourceGroupName 'rg' `
            -MachineName 'machine') -eq
        '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.HybridCompute/machines/machine'
    ) `
    -Case 'Arc machine resource ID'
$wrappedItems = '{"value":[{"name":"one"},{"name":"two"}]}' | ConvertFrom-Json
$responseItems = @(Get-ArcIdentityResponseItems -Response $wrappedItems)
Assert-True -Condition ($responseItems.Count -eq 2) -Case 'Wrapped Azure list response'
Assert-True -Condition ($responseItems[1].name -eq 'two') -Case 'Wrapped Azure list item shape'

$orchestrationPath = Join-Path $repoRoot 'infra\arc-identity.bicep'
$modulePath = Join-Path $repoRoot 'infra\core\arc-identity-monitoring.bicep'
$orchestrationSource = Get-Content -LiteralPath $orchestrationPath -Raw
$moduleSource = Get-Content -LiteralPath $modulePath -Raw
Assert-Contains -Source $orchestrationSource -Expected "targetScope = 'subscription'" -Case 'Subscription orchestration scope'
Assert-Contains -Source $orchestrationSource -Expected 'scope: resourceGroup(arcResourceGroupName)' -Case 'Existing ArcBox RG module scope'
Assert-Contains -Source $moduleSource -Expected 'Microsoft.Insights/dataCollectionRules@2024-03-11' -Case 'Stable DCR API'
Assert-Contains -Source $moduleSource -Expected 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' -Case 'Stable DCRA API'
Assert-Contains -Source $moduleSource -Expected 'Microsoft.Insights/scheduledQueryRules@2023-12-01' -Case 'Stable scheduled query API'
Assert-Contains -Source $moduleSource -Expected 'Microsoft.HybridCompute/machines@2025-01-13'' existing' -Case 'Existing Arc machines'
Assert-Contains -Source $moduleSource -Expected "kind: 'Windows'" -Case 'Windows-only DCR'
Assert-Contains -Source $moduleSource -Expected "Provider[@Name=\'Mercadona.IdentityOps\']" -Case 'Dedicated event provider XPath'
Assert-Contains -Source $moduleSource -Expected "Provider[@Name!=\'Mercadona.IdentityOps\']" -Case 'No duplicate generic provider XPath'
Assert-NotMatches -Source $moduleSource -Pattern '(?i)\bperformanceCounters\b|Microsoft-Perf' -Case 'No duplicate performance ingestion'
Assert-Contains -Source $moduleSource -Expected 'InsightsMetrics' -Case 'Freshness reuses existing VM Insights data'
Assert-Contains -Source $moduleSource -Expected 'Namespace == "Processor" and Name == "UtilizationPercentage"' -Case 'Stable existing metric freshness signal'
Assert-Contains -Source $moduleSource -Expected "operator: 'GreaterThanOrEqual'" -Case 'Deterministic static alert threshold'
Assert-Contains -Source $moduleSource -Expected 'threshold: 8' -Case 'Bounded burst alert threshold'
Assert-Contains -Source $moduleSource -Expected '| project TimeGenerated, _ResourceId' -Case 'Burst alert returns one row per event'
Assert-Contains -Source $moduleSource -Expected '| project ResourceId, Signal' -Case 'Freshness alert returns one row per stale signal'
Assert-NotMatches -Source $moduleSource -Pattern '\|\s*summarize\s+(?:EventCount|MissingOrStaleSignals)=' -Case 'Count alerts do not count aggregate result rows'
Assert-Contains -Source $moduleSource -Expected 'datetime_utc_to_local(CurrentUtc, "Europe/Madrid")' -Case 'DST-aware Madrid startup window'
Assert-Contains -Source $moduleSource -Expected 'MadridMinuteOfDay >= 500' -Case 'Twenty-minute startup grace'
Assert-Contains -Source $moduleSource -Expected 'datetime_part("Hour", CurrentUtc) < 18' -Case 'Fixed UTC shutdown suppression'
Assert-Contains -Source $moduleSource -Expected "displayName: 'ArcBox IdentityOps synthetic AD FS token-failure burst'" -Case 'Identity alert title namespace'
Assert-Contains -Source $moduleSource -Expected "displayName: 'ArcBox IdentityOps heartbeat or data freshness loss'" -Case 'Freshness alert title namespace'
Assert-NotMatches -Source $moduleSource -Pattern "displayName:\s*'Mercadona IdentityOps" -Case 'No overlap with retail Mercadona alert filter'
Assert-NotMatches -Source $moduleSource -Pattern '\bCounterValue\b' -Case 'No performance-value alert threshold'
Assert-Contains -Source $moduleSource -Expected 'severity: 2' -Case 'Sev2 alerts'
Assert-Contains -Source $moduleSource -Expected 'autoMitigate: true' -Case 'Alert auto resolution'
Assert-Contains -Source $moduleSource -Expected 'actionGroupResourceId' -Case 'Existing action group parameter'
Assert-NotMatches -Source $moduleSource -Pattern '(?im)^\s*''?Security!' -Case 'No broad Security channel'
Assert-NotMatches -Source ($orchestrationSource + $moduleSource) `
    -Pattern '(?i)Microsoft\.Resources/resourceGroups|Microsoft\.HybridCompute/machines/extensions|Microsoft\.OperationalInsights/workspaces@|Microsoft\.Insights/actionGroups@' `
    -Case 'No Jumpstart RG, machine extension, workspace, or action group creation'

$compiledTemplateJson = & az bicep build --file $orchestrationPath --stdout
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $compiledTemplateJson)) {
    throw 'Arc identity Bicep build failed inside the contract test.'
}
$compiledTemplate = $compiledTemplateJson | ConvertFrom-Json -AsHashtable -Depth 100
Assert-True -Condition ($compiledTemplate['$schema'] -like '*subscriptionDeploymentTemplate.json#') -Case 'Compiled subscription template'
$generatedTemplatePath = Join-Path $repoRoot 'infra\arc-identity.json'
Assert-True -Condition (Test-Path -LiteralPath $generatedTemplatePath -PathType Leaf) -Case 'Generated ARM template exists'
$generatedTemplate = Get-Content -LiteralPath $generatedTemplatePath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 100
Assert-True `
    -Condition (
        (ConvertTo-CanonicalJson -Value $generatedTemplate) -ceq
        (ConvertTo-CanonicalJson -Value $compiledTemplate)
    ) `
    -Case 'Generated ARM template is synchronized with Bicep'
$deploymentResources = @($compiledTemplate['resources'])
Assert-True -Condition ($deploymentResources.Count -eq 1) -Case 'Single isolated resource-group deployment module'
Assert-True -Condition ($deploymentResources[0]['type'] -eq 'Microsoft.Resources/deployments') -Case 'Compiled orchestration uses nested deployment'
Assert-True -Condition ($deploymentResources[0]['properties']['mode'] -eq 'Incremental') -Case 'Incremental-only deployment mode'

$parameterPath = Join-Path $repoRoot 'infra\arc-identity.parameters.json'
$parameters = Get-Content -LiteralPath $parameterPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$targetMachines = @($parameters['parameters']['targetMachineNames']['value'])
Assert-True -Condition ($targetMachines.Count -eq 2) -Case 'Exactly two parameterized target machines'
Assert-True -Condition ('ArcBox-Win2K22' -in $targetMachines) -Case 'ArcBox-Win2K22 target'
Assert-True -Condition ('ArcBox-Win2K25' -in $targetMachines) -Case 'ArcBox-Win2K25 target'

$deploySource = $scriptSources['deploy-arc-identity.ps1']
Assert-Contains -Source $deploySource -Expected '[switch] $Apply' -Case 'Deployment explicit apply switch'
Assert-Contains -Source $deploySource -Expected 'deployment sub what-if' -Case 'Azure deployment what-if'
Assert-Contains -Source $deploySource -Expected 'if (-not $Apply)' -Case 'Deployment defaults to no change'
Assert-True `
    -Condition (
        $deploySource.IndexOf('deployment sub what-if', [StringComparison]::Ordinal) -lt
        $deploySource.IndexOf('deployment'', ''sub'', ''create', [StringComparison]::Ordinal)
    ) `
    -Case 'What-if precedes deployment create'
Assert-Contains -Source $deploySource -Expected 'refusing to overwrite' -Case 'Collision refusal'
Assert-Contains -Source $deploySource -Expected 'scheduledQueryRules?api-version=2023-12-01' -Case 'Alert collision preflight'
Assert-Contains -Source $deploySource -Expected 'MSVMI-ama-vmi-default-dcr' -Case 'Existing VM Insights association preflight'

$incidentSource = $scriptSources['start-arc-identity-incident.ps1']
$recoverySource = $scriptSources['recover-arc-identity-incident.ps1']
$commonSource = $scriptSources['ArcIdentity.Common.ps1']
foreach ($source in @($incidentSource, $recoverySource)) {
    Assert-Contains -Source $source -Expected "Mercadona.IdentityOps" -Case 'Dedicated synthetic event source'
    Assert-Contains -Source $source -Expected 'demoSynthetic = $true' -Case 'Synthetic JSON marker'
    Assert-Contains -Source $source -Expected 'correlationId = $correlationId' -Case 'Synthetic correlation ID'
    Assert-Contains -Source $source -Expected "'S-1-5-18'" -Case 'LocalSystem execution guard'
    Assert-Contains -Source $source -Expected 'Write-EventLog' -Case 'Application event write'
    Assert-NotMatches -Source $source -Pattern '(?i)Install-WindowsFeature|Set-AdfsProperties|New-ADUser|logon|auditpol|Clear-EventLog|wevtutil\s+cl|New-ScheduledTask|Register-ScheduledTask' -Case 'No identity attack, role install, log tampering, or persistent task'
    Assert-NotMatches -Source $source -Pattern '(?i)while\s*\(\s*\$true\s*\)|for\s*\(\s*;\s*;\s*\)' -Case 'No unbounded loop'
}
Assert-Contains -Source $incidentSource -Expected '[ValidateRange(8, 20)]' -Case 'Bounded event count parameter'
Assert-Contains -Source $incidentSource -Expected '$sequence -le $burstCount' -Case 'Bounded event write loop'
Assert-Contains -Source $incidentSource -Expected '$expectedEvents = $MachineNames.Count * $EventsPerMachine' -Case 'Exact ingestion count'
Assert-Contains -Source $recoverySource -Expected '$recoveryCount -gt 1' -Case 'Single recovery invariant'
Assert-Contains -Source $incidentSource -Expected '[DateTimeOffset]::ParseExact' -Case 'Correlation-scoped retry window'
Assert-Contains -Source $recoverySource -Expected '[DateTimeOffset]::ParseExact' -Case 'Recovery correlation retry window'
Assert-Contains -Source $incidentSource -Expected 'ForEach-Object {' -Case 'Streaming incident retry inspection'
Assert-Contains -Source $recoverySource -Expected 'ForEach-Object {' -Case 'Streaming recovery retry inspection'
Assert-NotMatches -Source ($incidentSource + $recoverySource) -Pattern '\$candidateEvents\s*=\s*@\(' -Case 'No materialized event-history collection'
Assert-NotMatches -Source ($incidentSource + $recoverySource) -Pattern 'ConvertFrom-Json\s+-AsHashtable|\?\?|\?\s*[^:\r\n]+\s*:|&&|\|\|' -Case 'Embedded Run Command remains Windows PowerShell 5.1 compatible'
Assert-Contains -Source $commonSource -Expected "'connectedmachine', 'run-command', 'delete'" -Case 'Run Command cleanup'
Assert-Contains -Source $commonSource -Expected "[ValidatePattern('^identityops-" -Case 'Dedicated Run Command name guard'
Assert-Contains -Source $commonSource -Expected '[switch] $AllowNotFound' -Case 'Non-destructive SRE resource preflight'
Assert-Contains -Source $commonSource -Expected "'--timeout-in-seconds', [string] `$TimeoutSeconds" -Case 'Bounded guest Run Command execution'
Assert-Contains -Source $commonSource -Expected "'--no-wait'" -Case 'Nonblocking Run Command control-plane operations'
Assert-Contains -Source $commonSource -Expected '$cleanupDeadline = (Get-Date).AddSeconds(120)' -Case 'Bounded Run Command cleanup'
Assert-True `
    -Condition (
        $commonSource.IndexOf('$deadline = (Get-Date).AddSeconds($TimeoutSeconds)', [StringComparison]::Ordinal) -lt
        $commonSource.IndexOf("'connectedmachine', 'run-command', 'create'", [StringComparison]::Ordinal)
    ) `
    -Case 'Run Command deadline starts before create'
if ($IsWindows) {
    $windowsPowerShellProbe = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$payload = '{"demoSynthetic":true,"correlationId":"SYNTH-ID-20260714T080000Z-ABCDEF12","eventType":"SyntheticAdfsTokenFailure"}' | ConvertFrom-Json
if ($payload.demoSynthetic -ne $true -or
    $payload.correlationId -ne 'SYNTH-ID-20260714T080000Z-ABCDEF12' -or
    $payload.eventType -ne 'SyntheticAdfsTokenFailure') {
    exit 1
}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('AsHashtable')) {
    exit 2
}
'@
    & powershell.exe -NoLogo -NoProfile -NonInteractive -Command $windowsPowerShellProbe
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Case 'Windows PowerShell 5.1 event payload compatibility'
}

$allNewSources = ($scriptSources.Values -join "`n") + "`n$orchestrationSource`n$moduleSource"
foreach ($destructivePattern in @(
        '(?i)az\s+group\s+delete',
        '(?i)connectedmachine'',\s*''delete',
        '(?i)extension'',\s*''delete',
        '(?i)Microsoft\.HybridCompute/machines/delete',
        '(?i)Remove-AzConnectedMachine',
        '(?i)Remove-EventLog',
        '(?i)mode\s*:\s*[''"]Complete[''"]'
    )) {
    Assert-NotMatches -Source $allNewSources -Pattern $destructivePattern -Case 'No destructive Jumpstart operation'
}

$configureSource = $scriptSources['configure-arc-identity-sre-agent.ps1']
foreach ($requiredContract in @(
        'identity-infrastructure-analyzer',
        'identity-infrastructure-operations',
        'identity-infrastructure-sev2',
        'identity-infrastructure-weekday-report',
        "titleContains = 'ArcBox IdentityOps'",
        "cronExpression = '30 7 * * 1-5'",
        "agentMode = 'Review'",
        'Microsoft Sentinel',
        'SOC',
        'demoSynthetic=true',
        '$readerRoleId = ''acdd72a7-3385-48ef-bd42-f606fba81ae7''',
        '$monitoringReaderRoleId = ''43d0d8ad-25c7-4714-9337-8ba259a9fe05''',
        '$logAnalyticsReaderRoleId = ''73c42c96-874c-492b-b04d-ab87d138a893'''
    )) {
    Assert-Contains -Source $configureSource -Expected ([string] $requiredContract) -Case 'SRE Agent identity contract'
}
Assert-NotMatches -Source $configureSource -Pattern '(?i)RunAzCliWriteCommands|\bOwner\b|\bContributor\b' -Case 'Read-only SRE Agent tools and roles'
Assert-Contains -Source $configureSource -Expected "-PropertyName 'mode') -ne 'Review'" -Case 'Review mode preflight'
Assert-Contains -Source $configureSource -Expected "-PropertyName 'accessLevel') -ne 'Low'" -Case 'Low access preflight'
Assert-Contains -Source $configureSource -Expected 'refusing to overwrite it' -Case 'SRE resource collision refusal'
Assert-Contains -Source $configureSource -Expected 'Perf table is expected' -Case 'SRE instructions preserve existing InsightsMetrics source'
$retailConfigureSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'configure-sre-agent.ps1') -Raw
Assert-Contains -Source $retailConfigureSource -Expected "titleContains = 'mercadona'" -Case 'Existing retail filter baseline'
Assert-NotMatches -Source $configureSource -Pattern "titleContains\s*=\s*'mercadona'" -Case 'Identity filter does not overlap retail namespace'
Assert-Contains -Source $scriptSources['verify-arc-identity.ps1'] -Expected '$freshnessLookbackMinutes = $MaximumIngestionAgeMinutes + 5' -Case 'Verification lookback follows accepted freshness threshold'
Assert-Contains -Source $scriptSources['verify-arc-identity.ps1'] -Expected 'MSVMI-ama-vmi-default-dcr' -Case 'Verification preserves existing VM Insights DCR'
Assert-Contains -Source $scriptSources['verify-arc-identity.ps1'] -Expected 'no duplicate performance-counter source' -Case 'Verification rejects duplicate counters'

$kqlDirectory = Join-Path $repoRoot 'kql\arc-identity'
$requiredKqlFiles = @(
    'fleet-heartbeat.kql',
    'data-freshness.kql',
    'synthetic-token-failure-burst.kql',
    'performance-correlation.kql',
    'extension-health.arg.kql',
    'change-tracking.kql'
)
foreach ($kqlFileName in $requiredKqlFiles) {
    $kqlPath = Join-Path $kqlDirectory $kqlFileName
    Assert-True -Condition (Test-Path -LiteralPath $kqlPath -PathType Leaf) -Case "KQL asset exists: $kqlFileName"
    $kql = Get-Content -LiteralPath $kqlPath -Raw
    Assert-Contains -Source $kql -Expected 'rg-arcbox-itpro-weu-002' -Case "$kqlFileName exact ArcBox scope"
    Assert-NotMatches -Source $kql -Pattern '(?i)\bUserName\b|\bAccountName\b|\bTargetUserName\b|\|\s*project\s+\*' -Case "$kqlFileName no user identity or wildcard projection"
    Assert-NotMatches -Source $kql -Pattern '(?im)\|\s*project[^\r\n]*(RenderedDescription|EventData|Message)' -Case "$kqlFileName no raw event message projection"
}
$syntheticKql = Get-Content -LiteralPath (Join-Path $kqlDirectory 'synthetic-token-failure-burst.kql') -Raw
Assert-Contains -Source $syntheticKql -Expected 'demoSynthetic' -Case 'Synthetic KQL marker'
Assert-Contains -Source $syntheticKql -Expected '| summarize' -Case 'Synthetic KQL aggregate'
$performanceKql = Get-Content -LiteralPath (Join-Path $kqlDirectory 'performance-correlation.kql') -Raw
Assert-Contains -Source $performanceKql -Expected '| summarize' -Case 'Performance KQL remains informational and aggregate'
Assert-Contains -Source $performanceKql -Expected 'InsightsMetrics' -Case 'Performance KQL reuses VM Insights'
Assert-Contains -Source $performanceKql -Expected 'UtilizationPercentage' -Case 'Performance KQL includes CPU'
Assert-Contains -Source $performanceKql -Expected 'AvailableMB' -Case 'Performance KQL includes available memory'
Assert-Contains -Source $performanceKql -Expected 'ReadLatencyMs' -Case 'Performance KQL includes disk latency'
Assert-Contains -Source $performanceKql -Expected 'FreeSpacePercentage' -Case 'Performance KQL includes disk free space'
Assert-Contains -Source $performanceKql -Expected 'ReadBytesPerSecond' -Case 'Performance KQL includes network'
Assert-NotMatches -Source $performanceKql -Pattern '\|\s*where\s+Val\s*(?:[<>]=?|==|!=)' -Case 'Performance KQL has no threshold predicate'
$freshnessKql = Get-Content -LiteralPath (Join-Path $kqlDirectory 'data-freshness.kql') -Raw
Assert-Contains -Source $freshnessKql -Expected '["Heartbeat", "InsightsMetrics"]' -Case 'Freshness requires existing continuous signals only'
Assert-NotMatches -Source $freshnessKql -Pattern '\bPerf\b' -Case 'Freshness does not query intentionally empty Perf'
Assert-NotMatches -Source $freshnessKql -Pattern 'Signal="Event"' -Case 'Sporadic Event data is not marked stale'
Assert-Contains -Source $freshnessKql -Expected 'datetime_utc_to_local(CurrentUtc, "Europe/Madrid")' -Case 'Operator freshness query observes DST'
Assert-Contains -Source $freshnessKql -Expected 'MadridMinuteOfDay >= 500' -Case 'Operator query observes startup grace'
Assert-Contains -Source $freshnessKql -Expected 'datetime_part("Hour", CurrentUtc) < 18' -Case 'Operator query observes UTC shutdown'

$excludedPathPattern = '[\\/](?:node_modules|build|bin|obj|\.git)[\\/]'
$jsonFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.json' |
    Where-Object { $_.FullName -notmatch $excludedPathPattern }
foreach ($jsonFile in $jsonFiles) {
    try {
        Get-Content -LiteralPath $jsonFile.FullName -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100 |
            Out-Null
    } catch {
        throw "JSON parse failed for '$($jsonFile.FullName)': $($_.Exception.Message)"
    }
}

$yamlFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
    Where-Object {
        $_.Extension -in @('.yml', '.yaml') -and
        $_.FullName -notmatch $excludedPathPattern
    }
foreach ($yamlFile in $yamlFiles) {
    & python -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' $yamlFile.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "YAML parse failed for '$($yamlFile.FullName)'."
    }
}

$newDocs = @(
    (Join-Path $repoRoot 'docs\arquitectura-identidad-arc.md')
    (Join-Path $repoRoot 'docs\runbooks\arc-identidad-operaciones.md')
    (Join-Path $repoRoot 'docs\guia-demo-identidad-arc.md')
)
$newFilePaths = @(
    $newScriptNames | ForEach-Object { Join-Path $PSScriptRoot $_ }
) + @(
    $orchestrationPath,
    $modulePath,
    $parameterPath,
    $generatedTemplatePath,
    (Join-Path $repoRoot 'README.md')
) + @(
    $requiredKqlFiles | ForEach-Object { Join-Path $kqlDirectory $_ }
) + $newDocs
$newContent = $newFilePaths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }
$newContentText = $newContent -join "`n"
Assert-NotMatches -Source $newContentText -Pattern '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----' -Case 'No private key'
Assert-NotMatches -Source $newContentText -Pattern '(?i)\b(?:ghp|github_pat|azd)_[A-Za-z0-9_]{20,}\b' -Case 'No access token'
Assert-NotMatches -Source $newContentText -Pattern '(?i)(?:clientSecret|password)\s*[:=]\s*[''"][^$][^''"]{8,}[''"]' -Case 'No embedded credential'
Assert-NotMatches -Source $newContentText -Pattern '(?i)[?&]sig=[A-Za-z0-9%/+_-]{12,}' -Case 'No SAS signature'

foreach ($docPath in $newDocs) {
    $doc = Get-Content -LiteralPath $docPath -Raw
    Assert-Contains -Source $doc -Expected $requiredDisclaimer -Case "Visible disclaimer: $docPath"
}
$documentationText = $newDocs |
    ForEach-Object { Get-Content -LiteralPath $_ -Raw } |
    Join-String -Separator "`n"
foreach ($documentedBaseline in @(
        'la-start-arcbox-client',
        'Romance Standard Time',
        'shutdown-computevm-ArcBox-Client',
        '18:00 UTC',
        '07:30 UTC',
        'InsightsMetrics',
        'cero receptores',
        'ninguna fila en `Event`, `SecurityEvent` o `Perf`',
        '4,38 % / 11,51 %',
        '9,71 % / 19,32 %',
        'no son umbrales de alerta',
        'Perf` permanece vacío por diseño',
        '174 000 filas',
        'No notifica al SRE Agent'
    )) {
    Assert-Contains -Source $documentationText -Expected $documentedBaseline -Case 'Audited ArcBox baseline documentation'
}
$madridTimeZoneId = if ($IsWindows) { 'Romance Standard Time' } else { 'Europe/Madrid' }
$madridTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById($madridTimeZoneId)
$winterReportTime = [TimeZoneInfo]::ConvertTime(
    [DateTimeOffset]::Parse('2026-01-15T07:30:00Z'),
    $madridTimeZone
)
$summerReportTime = [TimeZoneInfo]::ConvertTime(
    [DateTimeOffset]::Parse('2026-07-15T07:30:00Z'),
    $madridTimeZone
)
Assert-True `
    -Condition ($winterReportTime.Hour -eq 8 -and $winterReportTime.Minute -eq 30) `
    -Case 'Weekday report follows winter startup grace'
Assert-True `
    -Condition ($summerReportTime.Hour -eq 9 -and $summerReportTime.Minute -eq 30) `
    -Case 'Weekday report follows summer startup grace'

Write-Host 'Arc identity infrastructure contract passed.'
