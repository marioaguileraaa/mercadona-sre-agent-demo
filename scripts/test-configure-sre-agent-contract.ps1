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

$requiredFunctions = @(
    'ConvertFrom-Base64Url',
    'Get-ArmAccessTokenIdentity',
    'Get-OptionalPropertyValue',
    'Get-FirstOptionalPropertyValue',
    'Disable-IncidentFilter',
    'Sync-RetailIncidentFilters'
)
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

function ConvertTo-TestBase64Url {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)).
        TrimEnd('=').
        Replace('+', '-').
        Replace('/', '_')
}

function New-TestJwt {
    param(
        [Parameter(Mandatory)]
        [string] $PayloadJson
    )

    $header = ConvertTo-TestBase64Url -Value '{"alg":"none"}'
    $payload = ConvertTo-TestBase64Url -Value $PayloadJson
    return "$header.$payload.synthetic-signature"
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

$base64UrlBytes = ConvertFrom-Base64Url -Value '-_8'
Assert-Equal `
    -Actual ([Convert]::ToHexString($base64UrlBytes)) `
    -Expected 'FBFF' `
    -Case 'Base64url alphabet normalization and padding'

$syntheticOid = '11111111-2222-3333-4444-555555555555'
$syntheticTenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$identity = Get-ArmAccessTokenIdentity -AccessToken (
    New-TestJwt -PayloadJson "{`"oid`":`"$syntheticOid`",`"tid`":`"$syntheticTenantId`"}"
)
Assert-Equal -Actual $identity.Oid -Expected $syntheticOid -Case 'JWT oid claim decoding'
Assert-Equal -Actual $identity.Tid -Expected $syntheticTenantId -Case 'JWT tid claim decoding'

$identityWithoutTenant = Get-ArmAccessTokenIdentity -AccessToken (
    New-TestJwt -PayloadJson "{`"oid`":`"$syntheticOid`"}"
)
Assert-Equal -Actual $identityWithoutTenant.Oid -Expected $syntheticOid -Case 'JWT oid without optional tid'
Assert-Equal -Actual $identityWithoutTenant.Tid -Expected $null -Case 'Missing optional tid under strict mode'

Assert-Throws `
    -Action { Get-ArmAccessTokenIdentity -AccessToken '' } `
    -ExpectedMessage 'The Azure Resource Manager access token was empty.' `
    -Case 'Empty ARM token'
Assert-Throws `
    -Action { Get-ArmAccessTokenIdentity -AccessToken 'not-a-jwt' } `
    -ExpectedMessage 'The Azure Resource Manager access token was not a valid three-segment JWT.' `
    -Case 'Invalid JWT structure'
Assert-Throws `
    -Action { Get-ArmAccessTokenIdentity -AccessToken 'header..signature' } `
    -ExpectedMessage 'The Azure Resource Manager access token was not a valid three-segment JWT.' `
    -Case 'Missing JWT payload'
Assert-Throws `
    -Action { Get-ArmAccessTokenIdentity -AccessToken 'header.*.signature' } `
    -ExpectedMessage 'The JWT payload segment was not valid base64url.' `
    -Case 'Invalid JWT payload base64url'
Assert-Throws `
    -Action { Get-ArmAccessTokenIdentity -AccessToken 'header.bm90LWpzb24.signature' } `
    -ExpectedMessage 'The Azure Resource Manager access token JWT payload was not valid UTF-8 JSON.' `
    -Case 'Invalid JWT payload JSON'
Assert-Throws `
    -Action { Get-ArmAccessTokenIdentity -AccessToken (New-TestJwt -PayloadJson '{}') } `
    -ExpectedMessage 'The Azure Resource Manager access token JWT payload did not contain a nonblank oid claim.' `
    -Case 'Missing JWT oid'
Assert-Throws `
    -Action { Get-ArmAccessTokenIdentity -AccessToken (New-TestJwt -PayloadJson 'null') } `
    -ExpectedMessage 'The Azure Resource Manager access token JWT payload did not contain a nonblank oid claim.' `
    -Case 'Null JWT payload under strict mode'
Assert-Throws `
    -Action { Get-ArmAccessTokenIdentity -AccessToken (New-TestJwt -PayloadJson '{"oid":" "}') } `
    -ExpectedMessage 'The Azure Resource Manager access token JWT payload did not contain a nonblank oid claim.' `
    -Case 'Blank JWT oid'

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
    "agent": "incident-handler",
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
    -Expected 'incident-handler' `
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
$sensitiveVariablePattern = '(?i)\$(?:[A-Za-z]+:)?[A-Za-z0-9_]*(?:accessToken|token|payload)[A-Za-z0-9_]*'
$disallowedSensitiveCommands = @(
    'Set-Content',
    'Add-Content',
    'Out-File',
    'Export-Clixml',
    'Export-Csv',
    'Tee-Object'
)
$commandAsts = $scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true)
foreach ($commandAst in $commandAsts) {
    $commandName = $commandAst.GetCommandName()
    $writesOutput = $null -ne $commandName -and $commandName -like 'Write-*'
    $persistsContent = $commandName -in $disallowedSensitiveCommands
    if (($writesOutput -or $persistsContent) -and
        $commandAst.Extent.Text -match $sensitiveVariablePattern) {
        throw "Sensitive token or payload material was sent to '$commandName'."
    }
}
if ($source -notmatch '(?s)function Get-ArmAccessTokenIdentity.*?finally\s*\{.*?\$AccessToken\s*=\s*\$null.*?\$payload\s*=\s*\$null') {
    throw 'ARM access token and decoded payload variables were not cleared in the identity helper finally block.'
}
if ($source -notmatch 'az ad signed-in-user show --query id --output tsv 2>\$null') {
    throw 'The primary Graph signed-in-user lookup or stderr suppression was not preserved.'
}
if (-not $source.Contains('az account get-access-token', [StringComparison]::Ordinal) -or
    -not $source.Contains('--subscription $SubscriptionId', [StringComparison]::Ordinal) -or
    -not $source.Contains("--resource 'https://management.azure.com/'", [StringComparison]::Ordinal) -or
    -not $source.Contains('--query accessToken', [StringComparison]::Ordinal)) {
    throw 'The subscription-scoped ARM access token fallback contract was not found.'
}
if (-not $source.Contains('az account show', [StringComparison]::Ordinal) -or
    -not $source.Contains("--query '{tenantId:tenantId,userType:user.type}'", [StringComparison]::Ordinal) -or
    -not $source.Contains("'user'", [StringComparison]::Ordinal) -or
    -not $source.Contains('[StringComparison]::OrdinalIgnoreCase', [StringComparison]::Ordinal)) {
    throw 'The fallback Azure CLI account user and tenant validation contract was not found.'
}
foreach ($expectedError in @(
        'Existing HTTP trigger did not expose an ID.',
        'HTTP trigger configuration did not return an ID.',
        'The Azure Resource Manager access token JWT payload did not contain a nonblank oid claim.',
        'The secure oid fallback requires an interactive user Azure CLI account for the target subscription.',
        'The Azure Resource Manager access token JWT payload did not contain a nonblank tid claim required to verify the target subscription tenant.',
        'The Azure Resource Manager access token tenant did not match the target subscription tenant.'
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
        'mercadona-cart-5xx-sev3',
        'alert-mercadona-cart-5xx-sev3',
        'incident-handler',
        '/api/v2/github/domains',
        '/api/v2/agent/tools',
        'issue_write',
        'create_branch',
        'push_files',
        'create_pull_request',
        'QueryAppInsightsByResourceId',
        'titleContains',
        'azMonitorFilterSettings',
        'targetResource',
        'DEMO_CART_MEMORY_MB_PER_ADD',
        'DEMO_CART_MEMORY_FAILURE_MB',
        'Requests 5xx',
        'RetainedBytes',
        'Never merge',
        'monthlyAgentUnitLimit',
        'Bearer $accessToken'
    )) {
    if (-not $source.Contains($requiredContract, [StringComparison]::Ordinal)) {
        throw "Required Mercadona contract was not preserved: '$requiredContract'"
    }
}
if ($source.Contains('/api/v2/extendedAgent/connectors/github', [StringComparison]::Ordinal)) {
    throw 'The deprecated GitHubOAuth connector API must not be used.'
}
if (-not $source.Contains('Authorization = "Bearer $accessToken"', [StringComparison]::Ordinal)) {
    throw 'SRE Agent configuration does not use the acquired bearer token.'
}
if ($source.Contains('Authorization = "******"', [StringComparison]::Ordinal)) {
    throw 'SRE Agent configuration uses a masked placeholder instead of the acquired bearer token.'
}
if ($source -notmatch "priorities\s*=\s*@\('Sev3'\)" -or
    $source -notmatch "agentMode\s*=\s*'Review'" -or
    $source -notmatch 'mergeEnabled\s*=\s*\$false') {
    throw 'Sev3 Review response-plan guardrails were not found.'
}
if (-not $source.Contains(
        "-Path '/api/v2/extendedAgent/incidentFilters/quickstart_response_plan'",
        [StringComparison]::Ordinal
    ) -or
    -not $source.Contains(
        "`$quickstartResponsePlanId = 'quickstart_response_plan'",
        [StringComparison]::Ordinal
    ) -or
    $source -notmatch '(?s)\[string\]::Equals\(\s*\$quickstartResponsePlanId,\s*''quickstart_response_plan'',\s*\[StringComparison\]::Ordinal\s*\)') {
    throw 'The exact quickstart_response_plan deletion guard was not found.'
}

$deleteCalls = @($commandAsts | Where-Object {
        $_.GetCommandName() -eq 'Invoke-AgentApi' -and
        $_.Extent.Text -match '(?i)-Method\s+Delete'
    })
Assert-Equal `
    -Actual $deleteCalls.Count `
    -Expected 1 `
    -Case 'Only one IncidentFilter delete call exists'
if ($deleteCalls[0].Extent.Text -notmatch "/incidentFilters/quickstart_response_plan'") {
    throw 'The only IncidentFilter delete does not target the exact approved quickstart_response_plan ID.'
}
if ($source -match '(?s)-Method\s+Delete.*?(mercadona-cart-memory-sev2|quickstart_handler)') {
    throw 'A preserved IncidentFilter can still be deleted.'
}

$syncFunctionAst = $scriptAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Sync-RetailIncidentFilters'
}, $true)
$mutatedSyncSource = $syncFunctionAst.Extent.Text.
    Replace(
        'function Sync-RetailIncidentFilters {',
        'function Invoke-MutatedRetailIncidentFilterSync {'
    ).
    Replace(
        '$quickstartResponsePlanId = ''quickstart_response_plan''',
        '$quickstartResponsePlanId = ''unexpected_response_plan'''
    )
. ([scriptblock]::Create($mutatedSyncSource))
Assert-Throws `
    -Action { Invoke-MutatedRetailIncidentFilterSync -ConfiguredFilters @() } `
    -ExpectedMessage 'The approved disposable IncidentFilter ID must remain quickstart_response_plan.' `
    -Case 'Mutated disposable filter constant is rejected before cleanup'

function New-TestIncidentFilter {
    param(
        [Parameter(Mandatory)]
        [string] $Id,
        [Parameter(Mandatory)]
        [bool] $IsEnabled,
        [string] $HandlingAgent = 'synthetic-handler',
        [switch] $Flat
    )

    if ($Flat) {
        return [pscustomobject]@{
            id = $Id
            name = $Id
            type = 'IncidentFilter'
            tags = @('synthetic-contract')
            owner = 'synthetic-owner'
            isEnabled = $IsEnabled
            handlingAgent = $HandlingAgent
            historyMarker = "history-$Id"
        }
    }
    return [pscustomobject]@{
        id = $Id
        name = $Id
        type = 'IncidentFilter'
        tags = @('synthetic-contract')
        owner = 'synthetic-owner'
        properties = [pscustomobject]@{
            isEnabled = $IsEnabled
            handlingAgent = $HandlingAgent
            historyMarker = "history-$Id"
        }
    }
}

$script:fakeIncidentFilters = [System.Collections.Generic.Dictionary[string, object]]::new(
    [StringComparer]::Ordinal
)
$script:fakeIncidentFilters['mercadona-cart-5xx-sev3'] = New-TestIncidentFilter `
    -Id 'mercadona-cart-5xx-sev3' `
    -IsEnabled $true `
    -HandlingAgent 'incident-handler'
$script:fakeIncidentFilters['mercadona-cart-memory-sev2'] = New-TestIncidentFilter `
    -Id 'mercadona-cart-memory-sev2' `
    -IsEnabled $true `
    -Flat
$script:fakeIncidentFilters['quickstart_handler'] = New-TestIncidentFilter `
    -Id 'quickstart_handler' `
    -IsEnabled $true
$script:fakeIncidentFilters['quickstart_response_plan'] = New-TestIncidentFilter `
    -Id 'quickstart_response_plan' `
    -IsEnabled $true
$script:fakeIncidentFilters['Quickstart_response_plan'] = New-TestIncidentFilter `
    -Id 'Quickstart_response_plan' `
    -IsEnabled $true
$script:fakeIncidentFilters['identity-infrastructure-sev2'] = New-TestIncidentFilter `
    -Id 'identity-infrastructure-sev2' `
    -IsEnabled $true `
    -HandlingAgent 'identity-infrastructure-analyzer'
$script:fakeIncidentFilterCalls = [System.Collections.Generic.List[object]]::new()

function Invoke-AgentApi {
    param(
        [Parameter(Mandatory)]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Path,
        [AllowNull()]
        [object] $Body
    )

    $filterId = $Path.Substring($Path.LastIndexOf('/') + 1)
    $script:fakeIncidentFilterCalls.Add([pscustomobject]@{
            Method = $Method
            Path = $Path
            Body = $Body
        })
    switch ($Method) {
        'Get' {
            if (-not $script:fakeIncidentFilters.ContainsKey($filterId)) {
                throw "Fake IncidentFilter '$filterId' was not found."
            }
            return $script:fakeIncidentFilters[$filterId]
        }
        'Put' {
            $script:fakeIncidentFilters[$filterId] = [pscustomobject] $Body
            return $script:fakeIncidentFilters[$filterId]
        }
        'Delete' {
            $script:fakeIncidentFilters.Remove($filterId)
            return $null
        }
        default {
            throw "Unexpected fake IncidentFilter API method '$Method'."
        }
    }
}

Sync-RetailIncidentFilters -ConfiguredFilters @($script:fakeIncidentFilters.Values)
Sync-RetailIncidentFilters -ConfiguredFilters @($script:fakeIncidentFilters.Values)

$deleteFilterCalls = @($script:fakeIncidentFilterCalls | Where-Object { $_.Method -eq 'Delete' })
Assert-Equal `
    -Actual $deleteFilterCalls.Count `
    -Expected 1 `
    -Case 'Idempotent cleanup delete count'
Assert-Equal `
    -Actual $deleteFilterCalls[0].Path `
    -Expected '/api/v2/extendedAgent/incidentFilters/quickstart_response_plan' `
    -Case 'Exact disposable response plan deletion'
foreach ($preservedFilterId in @(
        'mercadona-cart-memory-sev2',
        'quickstart_handler',
        'identity-infrastructure-sev2'
    )) {
    $preservedDeletes = @($deleteFilterCalls | Where-Object {
            $_.Path -eq "/api/v2/extendedAgent/incidentFilters/$preservedFilterId"
        })
    Assert-Equal `
        -Actual $preservedDeletes.Count `
        -Expected 0 `
        -Case "No delete for preserved IncidentFilter $preservedFilterId"
}
Assert-Equal `
    -Actual $script:fakeIncidentFilters['mercadona-cart-memory-sev2'].properties.isEnabled `
    -Expected $false `
    -Case 'Legacy retail filter disabled'
Assert-Equal `
    -Actual $script:fakeIncidentFilters['quickstart_handler'].properties.isEnabled `
    -Expected $false `
    -Case 'Competing quickstart handler disabled'
Assert-Equal `
    -Actual $script:fakeIncidentFilters['identity-infrastructure-sev2'].properties.isEnabled `
    -Expected $true `
    -Case 'Arc filter remains enabled'
Assert-Equal `
    -Actual $script:fakeIncidentFilters['identity-infrastructure-sev2'].properties.historyMarker `
    -Expected 'history-identity-infrastructure-sev2' `
    -Case 'Arc filter remains intact'
Assert-Equal `
    -Actual $script:fakeIncidentFilters['Quickstart_response_plan'].properties.isEnabled `
    -Expected $true `
    -Case 'Case-variant quickstart filter remains intact'
Assert-Equal `
    -Actual $script:fakeIncidentFilters['mercadona-cart-memory-sev2'].properties.historyMarker `
    -Expected 'history-mercadona-cart-memory-sev2' `
    -Case 'Legacy filter payload is preserved'

$enabledRetailRoutes = @(
    @(
        'mercadona-cart-5xx-sev3',
        'mercadona-cart-memory-sev2',
        'quickstart_handler'
    ) | Where-Object {
        $script:fakeIncidentFilters.ContainsKey($_) -and
        $script:fakeIncidentFilters[$_].properties.isEnabled -eq $true
    }
)
Assert-Equal `
    -Actual $enabledRetailRoutes.Count `
    -Expected 1 `
    -Case 'Exactly one retail routing filter remains enabled'

$preservedPutCalls = @($script:fakeIncidentFilterCalls | Where-Object {
        $_.Method -eq 'Put' -and
        $_.Path -in @(
            '/api/v2/extendedAgent/incidentFilters/mercadona-cart-memory-sev2',
            '/api/v2/extendedAgent/incidentFilters/quickstart_handler'
        )
    })
Assert-Equal `
    -Actual $preservedPutCalls.Count `
    -Expected 2 `
    -Case 'Repeated reconciliation does not rewrite disabled filters'
foreach ($putCall in $preservedPutCalls) {
    Assert-Equal `
        -Actual $putCall.Body.type `
        -Expected 'IncidentFilter' `
        -Case "PUT preserves type for $($putCall.Path)"
    Assert-Equal `
        -Actual $putCall.Body.properties.isEnabled `
        -Expected $false `
        -Case "PUT disables $($putCall.Path)"
}

$null = $script:fakeIncidentFilters.Remove('quickstart_handler')
Sync-RetailIncidentFilters -ConfiguredFilters @($script:fakeIncidentFilters.Values)
$null = $script:fakeIncidentFilters.Remove('mercadona-cart-memory-sev2')
$script:fakeIncidentFilters['quickstart_response_plan'] = New-TestIncidentFilter `
    -Id 'quickstart_response_plan' `
    -IsEnabled $true
$callsBeforeMissingLegacyProbe = $script:fakeIncidentFilterCalls.Count
Assert-Throws `
    -Action {
        Sync-RetailIncidentFilters -ConfiguredFilters @($script:fakeIncidentFilters.Values)
    } `
    -ExpectedMessage "Required legacy IncidentFilter 'mercadona-cart-memory-sev2' was not found for non-destructive migration." `
    -Case 'Missing legacy IncidentFilter fails reconciliation'
Assert-Equal `
    -Actual $script:fakeIncidentFilterCalls.Count `
    -Expected $callsBeforeMissingLegacyProbe `
    -Case 'Missing legacy filter fails before any API mutation'
Assert-Equal `
    -Actual $script:fakeIncidentFilters.ContainsKey('quickstart_response_plan') `
    -Expected $true `
    -Case 'Missing legacy filter preserves disposable plan until reconciliation can proceed'

Write-Host 'configure-sre-agent strict-mode response contract passed.'
