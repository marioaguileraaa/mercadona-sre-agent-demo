#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'configure-sre-agent.ps1'
$preflightPath = Join-Path $PSScriptRoot 'SreAgent.GitHubPreflight.ps1'
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
    'Format-AgentApiFailure',
    'New-RetailIncidentFilterPayload',
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
$preflightSource = Get-Content -LiteralPath $preflightPath -Raw
$combinedSource = $source + $preflightSource
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
        'maxAutomatedInvestigationAttempts',
        'New-RetailIncidentFilterPayload',
        'Format-AgentApiFailure',
        'DEMO_CART_MEMORY_MB_PER_ADD',
        'DEMO_CART_MEMORY_FAILURE_MB',
        'Requests 5xx',
        'RetainedBytes',
        'Never merge',
        'monthlyAgentUnitLimit',
        'Bearer $accessToken'
    )) {
    if (-not $combinedSource.Contains($requiredContract, [StringComparison]::Ordinal)) {
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
    $source -notmatch 'maxAutomatedInvestigationAttempts\s*=\s*3') {
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

foreach ($constantName in @('cartAlertName', 'incidentFilterName', 'incidentHandlerName')) {
    $constantAssignments = @($scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq $constantName
    }, $true))
    Assert-Equal `
        -Actual $constantAssignments.Count `
        -Expected 1 `
        -Case "Constant `$$constantName is assigned exactly once and cannot drift"
    if ($constantAssignments[0].Right.Extent.Text -notmatch "^'[^']+'$") {
        throw "Constant '`$$constantName' must be a single-quoted literal in configure-sre-agent.ps1."
    }
    . ([scriptblock]::Create($constantAssignments[0].Extent.Text))
}

$incidentFilterReferences = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.VariablePath.UserPath -eq 'incidentFilter'
}, $true))
Assert-Equal `
    -Actual $incidentFilterReferences.Count `
    -Expected 2 `
    -Case 'The retail IncidentFilter payload is only assigned and then sent, never mutated'
$incidentFilterAssignments = @($scriptAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'incidentFilter'
}, $true))
Assert-Equal `
    -Actual $incidentFilterAssignments.Count `
    -Expected 1 `
    -Case 'The retail IncidentFilter payload has a single assignment'
Assert-Equal `
    -Actual $incidentFilterAssignments[0].Right.Extent.Text `
    -Expected 'New-RetailIncidentFilterPayload' `
    -Case 'The retail IncidentFilter payload comes from the guarded builder'
$incidentFilterPutCalls = @($commandAsts | Where-Object {
        $_.GetCommandName() -eq 'Invoke-AgentApi' -and
        $_.Extent.Text -match '(?i)-Method\s+Put' -and
        $_.Extent.Text -match 'incidentFilters/\$incidentFilterName'
    })
Assert-Equal `
    -Actual $incidentFilterPutCalls.Count `
    -Expected 1 `
    -Case 'The retail IncidentFilter is written exactly once'
if ($incidentFilterPutCalls[0].Extent.Text -notmatch '-Body\s+\$incidentFilter(?![A-Za-z0-9_])') {
    throw 'The retail IncidentFilter PUT does not send the guarded builder payload.'
}

$bicepSource = Get-Content -LiteralPath (
    Join-Path (Split-Path $PSScriptRoot -Parent) 'infra\main.bicep'
) -Raw
$bicepAlertMatch = [regex]::Match(
    $bicepSource,
    "(?m)^resource\s+\w+\s+'Microsoft\.Insights/metricAlerts@[^']+'\s*=\s*\{\s*\r?\n\s*name:\s*'(?<name>[^']+)'"
)
if (-not $bicepAlertMatch.Success) {
    throw 'infra/main.bicep does not declare a Microsoft.Insights/metricAlerts resource with a literal name.'
}
Assert-Equal `
    -Actual $cartAlertName `
    -Expected $bicepAlertMatch.Groups['name'].Value `
    -Case 'Retail alert constant matches the deployed Bicep alert rule name'

$verifySource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-sre-agent.ps1') -Raw
$verifyAlertMatch = [regex]::Match($verifySource, "(?m)^\`$alertName\s*=\s*'(?<name>[^']+)'")
if (-not $verifyAlertMatch.Success) {
    throw 'verify-sre-agent.ps1 does not declare a literal $alertName constant.'
}
Assert-Equal `
    -Actual $verifyAlertMatch.Groups['name'].Value `
    -Expected $cartAlertName `
    -Case 'Verifier alert constant cannot drift from the configurator'

$retailFilterPayload = New-RetailIncidentFilterPayload
Assert-Equal `
    -Actual ((@($retailFilterPayload.Keys) | Sort-Object) -join ',') `
    -Expected 'name,properties,tags,type' `
    -Case 'Retail IncidentFilter root uses the proven field set'
Assert-Equal `
    -Actual ((@($retailFilterPayload.properties.Keys) | Sort-Object) -join ',') `
    -Expected (
        'agentMode,handlingAgent,incidentPlatform,' +
        'isEnabled,maxAutomatedInvestigationAttempts,priorities,titleContains'
    ) `
    -Case 'Retail IncidentFilter properties use the proven field set'
Assert-Equal -Actual $retailFilterPayload.name -Expected $incidentFilterName -Case 'Retail IncidentFilter name'
Assert-Equal -Actual $retailFilterPayload.type -Expected 'IncidentFilter' -Case 'Retail IncidentFilter type'
Assert-Equal `
    -Actual (@($retailFilterPayload.tags) -join ',') `
    -Expected 'mercadona-demo' `
    -Case 'Retail IncidentFilter tags'
Assert-Equal `
    -Actual $retailFilterPayload.properties.titleContains `
    -Expected $cartAlertName `
    -Case 'Retail IncidentFilter title scope is the exact deployed alert rule name'
Assert-Equal `
    -Actual $retailFilterPayload.properties.handlingAgent `
    -Expected $incidentHandlerName `
    -Case 'Retail IncidentFilter handling agent'
Assert-Equal -Actual $retailFilterPayload.properties.agentMode -Expected 'Review' -Case 'Retail IncidentFilter Review mode'
Assert-Equal -Actual $retailFilterPayload.properties.incidentPlatform -Expected 'AzMonitor' -Case 'Retail IncidentFilter platform'
Assert-Equal -Actual $retailFilterPayload.properties.isEnabled -Expected $true -Case 'Retail IncidentFilter enabled'
Assert-Equal `
    -Actual $retailFilterPayload.properties.maxAutomatedInvestigationAttempts `
    -Expected 3 `
    -Case 'Retail IncidentFilter bounded investigation attempts'
Assert-Equal `
    -Actual (@($retailFilterPayload.properties.priorities) -join ',') `
    -Expected 'Sev3' `
    -Case 'Retail IncidentFilter Sev3 priority'

$rejectedFilterProperties = @('alertId', 'azMonitorFilterSettings', 'mergeEnabled', 'deepInvestigationEnabled')
$retailFilterJson = $retailFilterPayload | ConvertTo-Json -Depth 30
$retailFilterFromJson = $retailFilterJson | ConvertFrom-Json
foreach ($rejectedProperty in $rejectedFilterProperties) {
    if ($null -ne $retailFilterFromJson.properties.PSObject.Properties[$rejectedProperty]) {
        throw "The serialized retail IncidentFilter must not contain '$rejectedProperty'."
    }
    if ($retailFilterJson -match "(?i)`"$([regex]::Escape($rejectedProperty))`"\s*:") {
        throw "The serialized retail IncidentFilter must not send '$rejectedProperty'."
    }
}
Assert-Equal `
    -Actual $retailFilterFromJson.properties.titleContains `
    -Expected $cartAlertName `
    -Case 'Serialized retail IncidentFilter keeps the exact alert-rule title scope'

$payloadFunctionAst = $scriptAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'New-RetailIncidentFilterPayload'
}, $true)
$payloadAnchor = '        titleContains = $cartAlertName'
if (-not $payloadFunctionAst.Extent.Text.Contains($payloadAnchor, [StringComparison]::Ordinal)) {
    throw 'The retail IncidentFilter payload no longer exposes the expected titleContains anchor.'
}
$rejectedFilterInjections = @(
    @{ Name = 'alertId'; Statement = "        alertId = '/subscriptions/synthetic/metricAlerts/synthetic'" },
    @{ Name = 'azMonitorFilterSettings'; Statement = "        azMonitorFilterSettings = @{ targetResource = 'synthetic' }" },
    @{ Name = 'mergeEnabled'; Statement = '        mergeEnabled = $false' },
    @{ Name = 'deepInvestigationEnabled'; Statement = '        deepInvestigationEnabled = $true' }
)
foreach ($rejectedInjection in $rejectedFilterInjections) {
    $mutatedPayloadSource = $payloadFunctionAst.Extent.Text.
        Replace(
            'function New-RetailIncidentFilterPayload {',
            'function New-MutatedRetailIncidentFilterPayload {'
        ).
        Replace(
            $payloadAnchor,
            ($payloadAnchor + [Environment]::NewLine + $rejectedInjection.Statement)
        )
    . ([scriptblock]::Create($mutatedPayloadSource))
    Assert-Throws `
        -Action { New-MutatedRetailIncidentFilterPayload } `
        -ExpectedMessage (
            "The retail IncidentFilter payload must not send '$($rejectedInjection.Name)'; " +
            'the Azure SRE Agent API rejects that shape with HTTP 400.'
        ) `
        -Case "Reintroducing $($rejectedInjection.Name) fails the retail IncidentFilter payload"
}

$driftedPayloadSource = $payloadFunctionAst.Extent.Text.
    Replace(
        'function New-RetailIncidentFilterPayload {',
        'function New-DriftedRetailIncidentFilterPayload {'
    ).
    Replace($payloadAnchor, "        titleContains = 'mercadona'")
. ([scriptblock]::Create($driftedPayloadSource))
Assert-Throws `
    -Action { New-DriftedRetailIncidentFilterPayload } `
    -ExpectedMessage 'The retail IncidentFilter must stay scoped to the exact deployed retail alert rule name.' `
    -Case 'Broadening the retail IncidentFilter title scope is rejected'

if ($null -eq ('MercadonaAgentApiContractHttpMessageHandler' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class MercadonaAgentApiContractHttpMessageHandler : HttpMessageHandler
{
    private readonly HttpStatusCode statusCode;
    private readonly string reasonPhrase;
    private readonly string responseBody;

    public int RequestCount { get; private set; }
    public string LastAuthorization { get; private set; }
    public string LastRequestBody { get; private set; }

    public MercadonaAgentApiContractHttpMessageHandler(
        int statusCode,
        string reasonPhrase,
        string responseBody)
    {
        this.statusCode = (HttpStatusCode)statusCode;
        this.reasonPhrase = reasonPhrase;
        this.responseBody = responseBody;
    }

    private HttpResponseMessage CreateResponse(HttpRequestMessage request)
    {
        RequestCount++;
        LastAuthorization = request.Headers.Contains("Authorization")
            ? string.Join(",", request.Headers.GetValues("Authorization"))
            : null;
        LastRequestBody = request.Content == null
            ? null
            : request.Content.ReadAsStringAsync().GetAwaiter().GetResult();
        var response = new HttpResponseMessage(statusCode)
        {
            ReasonPhrase = reasonPhrase
        };
        if (responseBody != null)
        {
            response.Content = new StringContent(responseBody, Encoding.UTF8, "application/json");
        }
        return response;
    }

    protected override HttpResponseMessage Send(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        return CreateResponse(request);
    }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        return Task.FromResult(CreateResponse(request));
    }
}
'@
}

$agentApiFunctionAst = $scriptAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-AgentApi'
}, $true)
if ($null -eq $agentApiFunctionAst) {
    throw "Required function 'Invoke-AgentApi' was not found."
}
if ($agentApiFunctionAst.Extent.Text -match '\.EnsureSuccessStatusCode\(') {
    throw 'Invoke-AgentApi still discards the failure response body through EnsureSuccessStatusCode.'
}
. ([scriptblock]::Create($agentApiFunctionAst.Extent.Text.Replace(
    'function Invoke-AgentApi {',
    'function Invoke-AgentApiUnderTest {'
)))

$endpoint = 'https://sre-agent.invalid'

function Invoke-AgentApiResponseProbe {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Delete', 'Get', 'Post', 'Put')]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [int] $StatusCode,
        [Parameter(Mandatory)]
        [string] $ReasonPhrase,
        [AllowNull()]
        [string] $ResponseBody
    )

    $credentialMarker = 'CREDENTIAL_MUST_NOT_BE_ECHOED'
    $requestBodyMarker = 'REQUEST_BODY_MUST_NOT_BE_ECHOED'
    $handlerType = 'MercadonaAgentApiContractHttpMessageHandler' -as [type]
    $handler = [Activator]::CreateInstance(
        $handlerType,
        @($StatusCode, $ReasonPhrase, $ResponseBody)
    )
    $script:agentHttpClient = [System.Net.Http.HttpClient]::new($handler, $true)
    $script:dataPlaneHeaders = @{
        Authorization = "Bearer $credentialMarker"
        'Content-Type' = 'application/json'
    }

    $result = $null
    $errorMessage = $null
    try {
        $result = Invoke-AgentApiUnderTest `
            -Method $Method `
            -Path $Path `
            -Body @{ marker = $requestBodyMarker }
    } catch {
        $errorMessage = $_.Exception.Message
    } finally {
        $script:agentHttpClient.Dispose()
        $script:agentHttpClient = $null
        $script:dataPlaneHeaders = $null
    }

    return [pscustomobject]@{
        Result = $result
        ErrorMessage = $errorMessage
        RequestCount = $handler.RequestCount
        LastAuthorization = $handler.LastAuthorization
        LastRequestBody = $handler.LastRequestBody
        CredentialMarker = $credentialMarker
        RequestBodyMarker = $requestBodyMarker
    }
}

$validationResponseBody = '{"errors":{"properties.alertId":["The alertId field is not supported."],' +
    '"properties.azMonitorFilterSettings":["The azMonitorFilterSettings field is not supported."]},' +
    '"title":"One or more validation errors occurred.","status":400}'
$badRequestProbe = Invoke-AgentApiResponseProbe `
    -Method Put `
    -Path '/api/v2/extendedAgent/incidentFilters/mercadona-cart-5xx-sev3' `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody $validationResponseBody
Assert-Equal -Actual $badRequestProbe.RequestCount -Expected 1 -Case 'Bad Request probe sends exactly one request'
Assert-Equal -Actual $badRequestProbe.Result -Expected $null -Case 'A non-2xx response is never treated as success'
foreach ($expectedFragment in @(
        'PUT',
        '/api/v2/extendedAgent/incidentFilters/mercadona-cart-5xx-sev3',
        'HTTP 400 (Bad Request)',
        'The alertId field is not supported.',
        'The azMonitorFilterSettings field is not supported.'
    )) {
    if (-not $badRequestProbe.ErrorMessage.Contains($expectedFragment, [StringComparison]::Ordinal)) {
        throw "The HTTP 400 failure did not report '$expectedFragment'."
    }
}
if ($badRequestProbe.ErrorMessage.Contains($badRequestProbe.CredentialMarker, [StringComparison]::Ordinal) -or
    $badRequestProbe.ErrorMessage.Contains($badRequestProbe.RequestBodyMarker, [StringComparison]::Ordinal)) {
    throw 'The HTTP 400 failure echoed the authorization header or the request body.'
}
if (-not $badRequestProbe.LastAuthorization.Contains($badRequestProbe.CredentialMarker, [StringComparison]::Ordinal) -or
    -not $badRequestProbe.LastRequestBody.Contains($badRequestProbe.RequestBodyMarker, [StringComparison]::Ordinal)) {
    throw 'The data-plane probe did not actually send the private authorization and request-body markers.'
}

$emptyBodyProbe = Invoke-AgentApiResponseProbe `
    -Method Get `
    -Path '/api/v2/repos' `
    -StatusCode 500 `
    -ReasonPhrase 'Internal Server Error' `
    -ResponseBody ' '
Assert-Equal `
    -Actual $emptyBodyProbe.ErrorMessage `
    -Expected (
        'Azure SRE Agent data-plane request GET /api/v2/repos failed with ' +
        'HTTP 500 (Internal Server Error). Response body was empty.'
    ) `
    -Case 'An empty failure body still reports method, path and status'

$redirectProbe = Invoke-AgentApiResponseProbe `
    -Method Post `
    -Path '/api/v1/httptriggers/create' `
    -StatusCode 302 `
    -ReasonPhrase 'Found' `
    -ResponseBody ''
Assert-Equal -Actual $redirectProbe.Result -Expected $null -Case 'A redirect is never treated as success'
if (-not $redirectProbe.ErrorMessage.Contains('HTTP 302 (Found)', [StringComparison]::Ordinal)) {
    throw 'A non-2xx redirect did not fail closed with its status.'
}

$successProbe = Invoke-AgentApiResponseProbe `
    -Method Get `
    -Path '/api/v2/extendedAgent/incidentFilters/mercadona-cart-5xx-sev3' `
    -StatusCode 200 `
    -ReasonPhrase 'OK' `
    -ResponseBody '{"name":"mercadona-cart-5xx-sev3","properties":{"titleContains":"alert-mercadona-cart-5xx-sev3"}}'
Assert-Equal -Actual $successProbe.ErrorMessage -Expected $null -Case 'A 2xx response does not throw'
Assert-Equal `
    -Actual $successProbe.Result.properties.titleContains `
    -Expected 'alert-mercadona-cart-5xx-sev3' `
    -Case 'A 2xx response is still deserialized'

$emptySuccessProbe = Invoke-AgentApiResponseProbe `
    -Method Delete `
    -Path '/api/v2/extendedAgent/incidentFilters/quickstart_response_plan' `
    -StatusCode 204 `
    -ReasonPhrase 'No Content' `
    -ResponseBody ''
Assert-Equal -Actual $emptySuccessProbe.ErrorMessage -Expected $null -Case 'An empty 2xx response does not throw'
Assert-Equal -Actual $emptySuccessProbe.Result -Expected $null -Case 'An empty 2xx response returns null'

$boundedFailure = Format-AgentApiFailure `
    -Method 'Put' `
    -Path '/api/v2/extendedAgent/incidentFilters/mercadona-cart-5xx-sev3' `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody ('x' * 5000) `
    -MaxCharacters 128
if (-not $boundedFailure.Contains(('x' * 128), [StringComparison]::Ordinal) -or
    $boundedFailure.Contains(('x' * 129), [StringComparison]::Ordinal) -or
    -not $boundedFailure.Contains('[truncated at 128 characters]', [StringComparison]::Ordinal)) {
    throw 'The data-plane failure body was not bounded to the requested character budget.'
}

$defaultBoundedFailure = Format-AgentApiFailure `
    -Method 'Put' `
    -Path '/api/v2/extendedAgent/incidentFilters/mercadona-cart-5xx-sev3' `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody ('y' * 9000)
if (-not $defaultBoundedFailure.Contains('[truncated at 2000 characters]', [StringComparison]::Ordinal) -or
    $defaultBoundedFailure.Contains(('y' * 2001), [StringComparison]::Ordinal)) {
    throw 'The default data-plane failure body budget is not 2000 characters.'
}

$redactedFailure = Format-AgentApiFailure `
    -Method 'Post' `
    -Path '/api/v1/httptriggers/create' `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody '{"detail":"rejected","accessToken":"SYNTHETIC MUST BE REDACTED","clientSecret":"SYNTHETIC,MUST&BE;REDACTED","sig":"SYNTHETIC MUST BE REDACTED"}'
if ($redactedFailure.Contains('SYNTHETIC', [StringComparison]::Ordinal) -or
    $redactedFailure.Contains('MUST', [StringComparison]::Ordinal) -or
    $redactedFailure.Contains('REDACTED', [StringComparison]::Ordinal)) {
    throw 'The data-plane failure body leaked part of a quoted credential value.'
}
foreach ($redactedField in @('accessToken', 'clientSecret', 'sig')) {
    if (-not $redactedFailure.Contains("$redactedField`":`"[redacted]`"", [StringComparison]::Ordinal)) {
        throw "The data-plane failure body did not redact the whole quoted '$redactedField' value."
    }
}
if (-not $redactedFailure.Contains('rejected', [StringComparison]::Ordinal)) {
    throw 'Redaction removed the diagnostic detail that makes the failure actionable.'
}

$unquotedRedactedFailure = Format-AgentApiFailure `
    -Method 'Post' `
    -Path '/api/v1/httptriggers/create' `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody 'refreshToken=SYNTHETICVALUE&api_key=SYNTHETICVALUE'
if ($unquotedRedactedFailure.Contains('SYNTHETICVALUE', [StringComparison]::Ordinal)) {
    throw 'The data-plane failure body did not redact delimiter-bounded credential values.'
}

$truncatedCredentialFailure = Format-AgentApiFailure `
    -Method 'Post' `
    -Path '/api/v1/httptriggers/create' `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody '{"clientSecret":"SYNTHETICVALUE","detail":"rejected"}' `
    -MaxCharacters 25
if ($truncatedCredentialFailure.Contains('SYNTHETIC', [StringComparison]::Ordinal)) {
    throw 'A credential cut short by truncation was not redacted.'
}

$surrogateFailure = Format-AgentApiFailure `
    -Method 'Put' `
    -Path '/api/v2/extendedAgent/incidentFilters/mercadona-cart-5xx-sev3' `
    -StatusCode 400 `
    -ReasonPhrase 'Bad Request' `
    -ResponseBody (('a' * 127) + [char]::ConvertFromUtf32(0x1F600) + ('b' * 200)) `
    -MaxCharacters 128
if (@($surrogateFailure.ToCharArray() | Where-Object { [char]::IsSurrogate($_) }).Count -ne 0) {
    throw 'Bounding the data-plane failure body split a surrogate pair.'
}
try {
    $null = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($surrogateFailure)
} catch {
    throw 'The bounded data-plane failure body is not valid UTF-16 and cannot be encoded.'
}
if (-not $surrogateFailure.Contains('[truncated at 128 characters]', [StringComparison]::Ordinal)) {
    throw 'The surrogate-safe bound did not report truncation.'
}

$unreadableFailure = Format-AgentApiFailure `
    -Method 'Get' `
    -Path '/api/v2/agent/tools' `
    -StatusCode 502 `
    -ReasonPhrase 'Bad Gateway' `
    -ResponseBody $null `
    -ResponseBodyReadFailed
Assert-Equal `
    -Actual $unreadableFailure `
    -Expected (
        'Azure SRE Agent data-plane request GET /api/v2/agent/tools failed with ' +
        'HTTP 502 (Bad Gateway). Response body could not be read.'
    ) `
    -Case 'An unreadable failure body still fails closed with method, path and status'

Write-Host 'configure-sre-agent strict-mode response contract passed.'
