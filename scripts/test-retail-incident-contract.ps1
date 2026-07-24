#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$paths = @(
    "$PSScriptRoot\AzureDemo.Common.ps1",
    "$PSScriptRoot\start-incident.ps1",
    "$PSScriptRoot\recover-incident.ps1",
    "$PSScriptRoot\verify-sre-agent.ps1",
    "$PSScriptRoot\configure-sre-agent.ps1"
)
foreach ($path in $paths) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count -gt 0) {
        throw "$path has parser errors: $($errors.Message -join '; ')"
    }
}

$start = Get-Content -LiteralPath "$PSScriptRoot\start-incident.ps1" -Raw
$recover = Get-Content -LiteralPath "$PSScriptRoot\recover-incident.ps1" -Raw
$verify = Get-Content -LiteralPath "$PSScriptRoot\verify-sre-agent.ps1" -Raw
$configure = Get-Content -LiteralPath "$PSScriptRoot\configure-sre-agent.ps1" -Raw
$common = Get-Content -LiteralPath "$PSScriptRoot\AzureDemo.Common.ps1" -Raw
$bicep = Get-Content -LiteralPath "$repoRoot\infra\main.bicep" -Raw

foreach ($required in @(
        '[ValidateRange(6, 200)]',
        '$MaxRequests = 80',
        '$LoadTimeoutSeconds = 300',
        '$required5xx = 6',
        '$fiveXxCount -lt $required5xx',
        'DEMO_CART_MEMORY_MB_PER_ADD = ''10''',
        'DEMO_CART_MEMORY_MAX_MB = ''640''',
        'DEMO_CART_MEMORY_FAILURE_MB = ''600''',
        'DEMO_CART_MEMORY_CAPACITY_EXHAUSTED',
        'Get-ContainerAppRequest5xxTotal',
        'Get-FiredContainerAppAlert',
        'Get-SreAgentThreads',
        'verify-sre-agent.ps1',
        '/api/orders',
        '/tracking',
        '[DateTimeOffset]::MinValue'
    )) {
    if (-not $start.Contains($required, [StringComparison]::Ordinal)) {
        throw "Finite incident contract is missing '$required'."
    }
}
if ($start -match '(?i)recover-incident\.ps1\s*&|&\s*.+recover-incident|Start-Job|Start-Process|while\s*\(\s*\$true\s*\)') {
    throw 'Start incident contains automatic recovery, a spawned process, or an unbounded loop.'
}
if ($start -match '(?i)Stop-Process|taskkill|Stop-Job') {
    throw 'Start incident can terminate a process or job.'
}

foreach ($required in @(
        'DEMO_CART_MEMORY_MB_PER_ADD = ''0''',
        'DEMO_CART_MEMORY_MAX_MB = ''640''',
        'DEMO_CART_MEMORY_FAILURE_MB = ''0''',
        '-VariableName ''DEMO_CART_MEMORY_MAX_MB''',
        '[DateTimeOffset]::MinValue',
        'Memory injection and controlled failure were already disabled',
        'Recovery verified'
    )) {
    if (-not $recover.Contains($required, [StringComparison]::Ordinal)) {
        throw "Idempotent recovery contract is missing '$required'."
    }
}
if (($start + $recover) -match '(?i)Stop-Process\s+-Name|taskkill\s+/IM') {
    throw 'Lifecycle scripts can kill unrelated processes by name.'
}

foreach ($required in @(
        "metricName: 'Requests'",
        "timeAggregation: 'Total'",
        "threshold: 5",
        "severity: 3",
        "evaluationFrequency: 'PT1M'",
        "windowSize: 'PT5M'",
        "name: 'statusCodeCategory'",
        "'5xx'",
        'maxReplicas: 1',
        "name: 'DEMO_CART_MEMORY_FAILURE_MB'",
        "value: '0'"
    )) {
    if (-not $bicep.Contains($required, [StringComparison]::Ordinal)) {
        throw "Bicep 5xx alert contract is missing '$required'."
    }
}
if ($bicep.Contains("metricName: 'WorkingSetBytes'", [StringComparison]::Ordinal)) {
    throw 'The retail primary alert still uses WorkingSetBytes.'
}

foreach ($required in @(
        'Review/Low',
        'CodeRepo',
        'GitHub OAuth',
        '/api/v2/github/domains',
        '/api/v2/agent/tools',
        'issue_write',
        'create_branch',
        'push_files',
        'create_pull_request',
        'quickstart_response_plan',
        'alertId',
        'targetResource',
        'incident-handler'
    )) {
    if (-not ($verify + $configure).Contains($required, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SRE verification/configuration contract is missing '$required'."
    }
}
foreach ($forbidden in @('merge_pull_request', 'run_workflow', 'workflow_dispatch')) {
    if (($verify + $configure) -match "(?i)['`"]$([regex]::Escape($forbidden))['`"]") {
        throw "A forbidden GitHub capability '$forbidden' was granted explicitly."
    }
}
if (-not $common.Contains("--filter `"statusCodeCategory eq '5xx'`"", [StringComparison]::Ordinal)) {
    throw 'The common metric helper does not filter Requests to 5xx.'
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Action,
        [Parameter(Mandatory)]
        [string] $ExpectedMessage,
        [Parameter(Mandatory)]
        [string] $Case
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -ne $ExpectedMessage) {
            throw "$Case failed. Expected error '$ExpectedMessage', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "$Case failed. Expected an exception."
}

$verifyPath = "$PSScriptRoot\verify-sre-agent.ps1"
$verifyTokens = $null
$verifyErrors = $null
$verifyAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $verifyPath,
    [ref] $verifyTokens,
    [ref] $verifyErrors
)
foreach ($functionName in @(
        'Get-OptionalValue',
        'Get-AgentProperty',
        'Get-IncidentFilterId',
        'Assert-RetailIncidentFilterMigration'
    )) {
    $functionAst = $verifyAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) {
        throw "Retail verifier function '$functionName' was not found."
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$disabledLegacyFilter = [pscustomobject]@{
    id = 'mercadona-cart-memory-sev2'
    properties = [pscustomobject]@{ isEnabled = $false }
}
$disabledQuickstartHandler = [pscustomobject]@{
    id = 'quickstart_handler'
    properties = [pscustomobject]@{ isEnabled = $false }
}
$enabledQuickstartHandler = [pscustomobject]@{
    id = 'quickstart_handler'
    properties = [pscustomobject]@{ isEnabled = $true }
}
$enabledLegacyFilter = [pscustomobject]@{
    id = 'mercadona-cart-memory-sev2'
    properties = [pscustomobject]@{ isEnabled = $true }
}

Assert-RetailIncidentFilterMigration -Plans @($disabledLegacyFilter)
Assert-RetailIncidentFilterMigration -Plans @(
    $disabledLegacyFilter,
    $disabledQuickstartHandler
)
Assert-Throws `
    -Action { Assert-RetailIncidentFilterMigration -Plans @() } `
    -ExpectedMessage "Required migrated IncidentFilter 'mercadona-cart-memory-sev2' is missing." `
    -Case 'Verifier rejects missing migrated legacy filter'
Assert-Throws `
    -Action { Assert-RetailIncidentFilterMigration -Plans @($enabledLegacyFilter) } `
    -ExpectedMessage "Migrated IncidentFilter 'mercadona-cart-memory-sev2' must be disabled." `
    -Case 'Verifier rejects enabled migrated legacy filter'
Assert-Throws `
    -Action {
        Assert-RetailIncidentFilterMigration -Plans @(
            $disabledLegacyFilter,
            $enabledQuickstartHandler
        )
    } `
    -ExpectedMessage "Optional competing IncidentFilter 'quickstart_handler' must be disabled when present." `
    -Case 'Verifier rejects enabled optional quickstart handler'

Write-Host 'Safe retail incident contract passed.'
