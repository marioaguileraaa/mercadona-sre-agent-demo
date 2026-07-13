#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'configure-sre-agent.ps1'
$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "configure-sre-agent.ps1 has parser errors: $($parseErrors.Message -join '; ')"
}

$requiredFunctions = @('Get-OptionalPropertyValue', 'Get-FirstOptionalPropertyValue')
foreach ($functionName in $requiredFunctions) {
    $functionAst = $scriptAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) {
        throw "Required function '$functionName' was not found."
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object] $Actual,
        [AllowNull()]
        [object] $Expected,
        [Parameter(Mandatory)]
        [string] $Case
    )

    if ($Actual -ne $Expected) {
        throw "$Case failed. Expected '$Expected', got '$Actual'."
    }
}

function ConvertFrom-TestJson {
    param(
        [Parameter(Mandatory)]
        [string] $Json
    )

    return $Json | ConvertFrom-Json
}

$missingProperties = ConvertFrom-TestJson -Json '{}'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $missingProperties -PropertyNames @('name')) `
    -Expected $null `
    -Case 'Missing top-level name and properties'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $missingProperties -PropertyNames @('id', 'triggerId')) `
    -Expected $null `
    -Case 'Missing top-level ID and properties'

$nestedTrigger = ConvertFrom-TestJson -Json @'
{
  "properties": {
    "name": "mercadona-controlled-issue",
    "triggerId": "nested-trigger-id",
    "agentMode": "Review",
    "agent": "code-analyzer",
    "agentPrompt": "Nested prompt"
  }
}
'@
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $nestedTrigger -PropertyNames @('name')) `
    -Expected 'mercadona-controlled-issue' `
    -Case 'Nested trigger name'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $nestedTrigger -PropertyNames @('id', 'triggerId')) `
    -Expected 'nested-trigger-id' `
    -Case 'Nested triggerId when top-level ID is missing'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $nestedTrigger -PropertyNames @('agentMode')) `
    -Expected 'Review' `
    -Case 'Nested trigger mode'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $nestedTrigger -PropertyNames @('agent')) `
    -Expected 'code-analyzer' `
    -Case 'Nested trigger agent'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $nestedTrigger -PropertyNames @('agentPrompt')) `
    -Expected 'Nested prompt' `
    -Case 'Nested trigger prompt'

$nestedIdTrigger = ConvertFrom-TestJson -Json '{"properties":{"id":"nested-id"}}'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $nestedIdTrigger -PropertyNames @('id', 'triggerId')) `
    -Expected 'nested-id' `
    -Case 'Nested ID when top-level ID is missing'

$topLevelTrigger = ConvertFrom-TestJson -Json @'
{
  "name": "top-level-name",
  "id": "top-level-id",
  "triggerId": "top-level-trigger-id",
  "agentMode": "TopLevelMode",
  "agent": "top-level-agent",
  "agentPrompt": "Top-level prompt",
  "properties": {
    "name": "nested-name",
    "id": "nested-id",
    "triggerId": "nested-trigger-id",
    "agentMode": "NestedMode",
    "agent": "nested-agent",
    "agentPrompt": "Nested prompt"
  }
}
'@
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $topLevelTrigger -PropertyNames @('name')) `
    -Expected 'top-level-name' `
    -Case 'Top-level name precedence'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $topLevelTrigger -PropertyNames @('id', 'triggerId')) `
    -Expected 'top-level-id' `
    -Case 'Top-level ID precedence'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $topLevelTrigger -PropertyNames @('agentMode')) `
    -Expected 'TopLevelMode' `
    -Case 'Top-level trigger mode precedence'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $topLevelTrigger -PropertyNames @('agent')) `
    -Expected 'top-level-agent' `
    -Case 'Top-level trigger agent precedence'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $topLevelTrigger -PropertyNames @('agentPrompt')) `
    -Expected 'Top-level prompt' `
    -Case 'Top-level trigger prompt precedence'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $topLevelTrigger -PropertyNames @('agentMode') -PropertiesFirst) `
    -Expected 'NestedMode' `
    -Case 'Nested filter mode precedence'

$topLevelTriggerId = ConvertFrom-TestJson -Json '{"triggerId":"top-level-trigger-id"}'
Assert-Equal `
    -Actual (Get-FirstOptionalPropertyValue -InputObject $topLevelTriggerId -PropertyNames @('id', 'triggerId')) `
    -Expected 'top-level-trigger-id' `
    -Case 'Top-level triggerId fallback'

$source = Get-Content -LiteralPath $scriptPath -Raw
foreach ($expectedError in @(
        'Existing HTTP trigger did not expose an ID.',
        'HTTP trigger configuration did not return an ID.'
    )) {
    if (-not $source.Contains($expectedError, [StringComparison]::Ordinal)) {
        throw "Explicit missing-ID error was not preserved: '$expectedError'"
    }
}
if ($source -match '\?\?') {
    throw 'Direct null-coalescing property access remains in configure-sre-agent.ps1.'
}
if ($source -match '(?im)Write-(Host|Output|Verbose|Information|Warning|Debug|Error)[^\r\n]*\$(triggerBridgeCallbackUrl|triggerUrl)') {
    throw 'A trigger URL could be written to command output.'
}
foreach ($requiredContract in @(
        'rg-mercadona-sre-agent-v1',
        'sre-agent-mercadona-v1',
        'mercadona-controlled-issue',
        'logic-mercadona-sre-trigger-v1',
        'mercadona-cart-memory-sev2',
        'DEMO_CART_MEMORY_MB_PER_ADD',
        'WorkingSetBytes',
        'RetainedBytes',
        'code-analyzer',
        'monthlyAgentUnitLimit',
        'Bearer $accessToken'
    )) {
    if (-not $source.Contains($requiredContract, [StringComparison]::Ordinal)) {
        throw "Required Mercadona contract was not preserved: '$requiredContract'"
    }
}

Write-Host 'configure-sre-agent strict-mode response contract passed.'
