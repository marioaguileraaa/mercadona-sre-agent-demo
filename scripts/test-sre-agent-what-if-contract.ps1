#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\SreAgent.WhatIf.ps1"

$fixture = Get-Content `
    -LiteralPath "$PSScriptRoot\fixtures\sre-agent-what-if.json" `
    -Raw |
    ConvertFrom-Json -Depth 100
$retailResourceGroupId = "/subscriptions/$($fixture.subscriptionId)/resourceGroups/$($fixture.retailResourceGroupName)"
$arcResourceGroupId = "/subscriptions/$($fixture.subscriptionId)/resourceGroups/$($fixture.arcResourceGroupName)"
$agentResourceId = "$retailResourceGroupId/providers/Microsoft.App/agents/$($fixture.agentName)"
$requiredManagedResources = @($retailResourceGroupId, $arcResourceGroupId)

$requiredCaseNames = @(
    'Arc machine Unsupported',
    'Arc role assignment Unsupported',
    'Arc role assignment potential Unsupported',
    'role assignment substring Unsupported',
    'role assignment mismatched type Unsupported',
    'Arc Modify only in potentialChanges',
    'Arc NoChange only in potentialChanges',
    'SRE NoChange only in potentialChanges',
    'SRE child Ignore only in potentialChanges',
    'SRE Arc delete only in potentialChanges',
    'SRE replacement only in potentialChanges',
    'malformed potentialChanges',
    'safe empty potentialChanges',
    'compatible null potentialChanges'
)
foreach ($requiredCaseName in $requiredCaseNames) {
    if ($requiredCaseName -notin @($fixture.cases.name)) {
        throw "Required dynamic what-if fixture '$requiredCaseName' was not found."
    }
}

foreach ($case in $fixture.cases) {
    $errorMessage = $null
    try {
        Assert-SreAgentWhatIfSafe `
            -WhatIf $case.whatIf `
            -AgentResourceId $agentResourceId `
            -ArcResourceGroupId $arcResourceGroupId `
            -RequiredManagedResourceIds $requiredManagedResources
    } catch {
        $errorMessage = $_.Exception.Message
    }

    if ($case.shouldPass -and $null -ne $errorMessage) {
        throw "What-if fixture '$($case.name)' should pass but failed: $errorMessage"
    }
    if (-not $case.shouldPass -and $null -eq $errorMessage) {
        throw "What-if fixture '$($case.name)' should fail but passed."
    }
}

$deployPath = Join-Path $PSScriptRoot 'deploy.ps1'
$deploySource = Get-Content -LiteralPath $deployPath -Raw
$tokens = $null
$parseErrors = $null
$deployAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $deployPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "deploy.ps1 has parser errors: $($parseErrors.Message -join '; ')"
}
$guardFunction = $deployAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-GuardedGroupDeployment'
    }, $true)
if ($null -eq $guardFunction) {
    throw 'deploy.ps1 did not define Invoke-GuardedGroupDeployment.'
}
$guardSource = $guardFunction.Extent.Text
foreach ($requiredFragment in @(
        'deployment'', ''group'', ''what-if',
        '--result-format'', ''FullResourcePayloads',
        'Assert-SreAgentWhatIfSafe',
        'deployment'', ''group'', ''create'
    )) {
    if (-not $guardSource.Contains($requiredFragment, [StringComparison]::Ordinal)) {
        throw "Guarded deployment did not preserve '$requiredFragment'."
    }
}
if ($guardSource.IndexOf(
        "deployment', 'group', 'what-if",
        [StringComparison]::Ordinal
    ) -gt $guardSource.IndexOf(
        'Assert-SreAgentWhatIfSafe',
        [StringComparison]::Ordinal
    ) -or
    $guardSource.IndexOf(
        'Assert-SreAgentWhatIfSafe',
        [StringComparison]::Ordinal
    ) -gt $guardSource.IndexOf(
        "deployment', 'group', 'create",
        [StringComparison]::Ordinal
    )) {
    throw 'Deployment what-if JSON must be asserted before create.'
}
$guardedDeploymentCalls = @(
    $deployAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-GuardedGroupDeployment'
        }, $true)
)
if ($guardedDeploymentCalls.Count -ne 2) {
    throw "deploy.ps1 must guard both deployments; found $($guardedDeploymentCalls.Count) calls."
}
foreach ($requiredFragment in @(
        '[string] $ArcResourceGroupName = ''rg-arcbox-itpro-weu-002''',
        'arcResourceGroupName=$ArcResourceGroupName'
    )) {
    if (-not $deploySource.Contains($requiredFragment, [StringComparison]::Ordinal)) {
        throw "deploy.ps1 did not preserve '$requiredFragment'."
    }
}

. ([scriptblock]::Create($guardFunction.Extent.Text))

$whatIfHelperPath = Join-Path $PSScriptRoot 'SreAgent.WhatIf.ps1'
$whatIfHelperErrors = $null
$whatIfHelperAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $whatIfHelperPath,
    [ref] $null,
    [ref] $whatIfHelperErrors
)
if ($whatIfHelperErrors.Count -gt 0) {
    throw "SreAgent.WhatIf.ps1 has parser errors: $($whatIfHelperErrors.Message -join '; ')"
}
$whatIfJsonFunction = $whatIfHelperAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-SreAgentWhatIfJson'
    }, $true)
if ($null -eq $whatIfJsonFunction) {
    throw 'SreAgent.WhatIf.ps1 did not define Invoke-SreAgentWhatIfJson.'
}
$nativePreferenceAssignment = $whatIfJsonFunction.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq 'PSNativeCommandUseErrorActionPreference' -and
            $node.Right.Extent.Text -eq '$false'
    }, $true)
if ($null -eq $nativePreferenceAssignment) {
    throw 'Invoke-SreAgentWhatIfJson must disable $PSNativeCommandUseErrorActionPreference locally.'
}
$whatIfNativeCall = $whatIfJsonFunction.Find({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'az'
    }, $true)
if ($null -eq $whatIfNativeCall) {
    throw 'Invoke-SreAgentWhatIfJson must invoke az.'
}
if ($nativePreferenceAssignment.Extent.StartOffset -gt $whatIfNativeCall.Extent.StartOffset) {
    throw '$PSNativeCommandUseErrorActionPreference must be disabled before az is invoked.'
}

$SubscriptionId = [string] $fixture.subscriptionId
$ResourceGroupName = [string] $fixture.retailResourceGroupName
$requiredManagedResourceIds = $requiredManagedResources

function Assert-WhatIfContract {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,
        [Parameter(Mandatory)]
        [string] $Case
    )

    if (-not $Condition) {
        throw "What-if guard contract case failed: $Case"
    }
}

function Get-FakeAzArgumentValue {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Arguments,
        [Parameter(Mandatory)]
        [string] $Name
    )

    for ($index = 0; $index -lt $Arguments.Count - 1; $index++) {
        if ($Arguments[$index] -ceq $Name) {
            return $Arguments[$index + 1]
        }
    }
    return $null
}

$script:fakeWhatIf = ($fixture.cases | Where-Object name -eq 'both scopes present').whatIf
$script:fakeAzMode = 'Json'
$script:fakeAzWhatIfArguments = [System.Collections.Generic.List[object]]::new()
$script:deploymentOperations = [System.Collections.Generic.List[string]]::new()
$script:prettyPrintStdout = @(
    'Note: The result may contain false positive predictions (noise).',
    'Resource and property changes are indicated with this symbol:',
    '  ~ Modify',
    '',
    'Resource changes: 1 to modify.'
)
$script:syntheticStderrToken = 'BCP081-synthetic-connector-warning'
function az {
    [string[]] $azArguments = @($args | ForEach-Object { [string] $_ })
    $operation = $azArguments[2]
    $script:deploymentOperations.Add($operation)
    $global:LASTEXITCODE = 0
    if ($operation -eq 'what-if') {
        $script:fakeAzWhatIfArguments.Add($azArguments)
        switch ($script:fakeAzMode) {
            'Json' {
                return $script:fakeWhatIf | ConvertTo-Json -Depth 100
            }
            'NoisyJson' {
                Write-Error $script:syntheticStderrToken -ErrorAction Continue
                return $script:fakeWhatIf | ConvertTo-Json -Depth 100
            }
            'NativeNoisyJson' {
                [System.IO.File]::WriteAllText(
                    $script:nativeNoisePayloadPath,
                    ($script:fakeWhatIf | ConvertTo-Json -Depth 100 -Compress),
                    [System.Text.UTF8Encoding]::new($false)
                )
                & pwsh -NoProfile -NonInteractive -File $script:nativeNoiseScriptPath
                return
            }
            'NativeFailure' {
                & pwsh -NoProfile -NonInteractive -File $script:nativeFailureScriptPath
                return
            }
            'PrettyPrint' {
                Write-Error $script:syntheticStderrToken -ErrorAction Continue
                return $script:prettyPrintStdout
            }
            'Failure' {
                Write-Error $script:syntheticStderrToken -ErrorAction Continue
                $global:LASTEXITCODE = 1
                return
            }
            default {
                throw "Unexpected fake what-if mode '$($script:fakeAzMode)'."
            }
        }
    }
    if ($operation -eq 'create') {
        return
    }
    throw "Unexpected fake Azure CLI operation '$operation'."
}

function Invoke-FakeGuardedDeployment {
    param(
        [Parameter(Mandatory)]
        [string] $Mode,
        [Parameter(Mandatory)]
        [string] $DeploymentName,
        [Parameter(Mandatory)]
        [string] $WhatIfFixtureName
    )

    $script:fakeAzMode = $Mode
    $script:fakeWhatIf = ($fixture.cases | Where-Object name -eq $WhatIfFixtureName).whatIf
    $script:fakeAzWhatIfArguments.Clear()
    $script:deploymentOperations.Clear()
    $errorMessage = $null
    $errorType = $null
    try {
        Invoke-GuardedGroupDeployment `
            -DeploymentName $DeploymentName `
            -TemplateParameters @('environmentName=fixture') `
            -FailureMessage 'Synthetic create failed.'
    } catch {
        $errorMessage = $_.Exception.Message
        $errorType = $_.Exception.GetType().FullName
    }

    return [pscustomobject]@{
        ErrorMessage = $errorMessage
        ErrorType = $errorType
        Operations = ($script:deploymentOperations -join ',')
        WhatIfArguments = @($script:fakeAzWhatIfArguments)
        LeakedTempFiles = @(
            Get-ChildItem -LiteralPath $tempProbeRoot -Force -ErrorAction SilentlyContinue
        ).Count
    }
}

$tempProbeRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "sre-what-if-contract-$([guid]::NewGuid().ToString('n'))"
$null = New-Item -ItemType Directory -Path $tempProbeRoot -Force
$nativeNoiseRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "sre-what-if-native-$([guid]::NewGuid().ToString('n'))"
$null = New-Item -ItemType Directory -Path $nativeNoiseRoot -Force
$script:nativeNoisePayloadPath = Join-Path $nativeNoiseRoot 'what-if.json'
$script:nativeNoiseScriptPath = Join-Path $nativeNoiseRoot 'emit-native-noise.ps1'
$script:nativeFailureScriptPath = Join-Path $nativeNoiseRoot 'emit-native-failure.ps1'
$script:nativeFailureExitCode = 7
$script:nativeFailureStdoutToken = 'native-pretty-print-not-json'
[System.IO.File]::WriteAllText(
    $script:nativeNoiseScriptPath,
    @"
[Console]::Error.WriteLine('$($script:syntheticStderrToken)')
[Console]::Out.Write([System.IO.File]::ReadAllText('$($script:nativeNoisePayloadPath)'))
"@,
    [System.Text.UTF8Encoding]::new($false)
)
[System.IO.File]::WriteAllText(
    $script:nativeFailureScriptPath,
    @"
[Console]::Error.WriteLine('$($script:syntheticStderrToken)')
[Console]::Out.Write('$($script:nativeFailureStdoutToken)')
exit $($script:nativeFailureExitCode)
"@,
    [System.Text.UTF8Encoding]::new($false)
)
$originalTempVariables = [ordered]@{
    TMP = $env:TMP
    TEMP = $env:TEMP
    TMPDIR = $env:TMPDIR
}
try {
    $env:TMP = $tempProbeRoot
    $env:TEMP = $tempProbeRoot
    $env:TMPDIR = $tempProbeRoot
    $tempRedirectionProbe = [System.IO.Path]::GetTempFileName()
    Assert-WhatIfContract `
        -Condition (
            $tempRedirectionProbe.StartsWith(
                $tempProbeRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) `
        -Case 'Temporary-file probe directory is authoritative'
    Remove-Item -LiteralPath $tempRedirectionProbe -Force

    $safeRun = Invoke-FakeGuardedDeployment `
        -Mode 'Json' `
        -DeploymentName 'safe-fixture' `
        -WhatIfFixtureName 'both scopes present'
    Assert-WhatIfContract `
        -Condition ($null -eq $safeRun.ErrorMessage) `
        -Case "Safe guarded deployment must succeed: $($safeRun.ErrorMessage)"
    Assert-WhatIfContract `
        -Condition ($safeRun.Operations -ceq 'what-if,create') `
        -Case 'Safe guarded deployment runs what-if before create'
    Assert-WhatIfContract `
        -Condition ($safeRun.WhatIfArguments.Count -eq 1) `
        -Case 'Safe guarded deployment issues exactly one what-if'
    $safeWhatIfArguments = [string[]] $safeRun.WhatIfArguments[0]
    Assert-WhatIfContract `
        -Condition ('--no-pretty-print' -cin $safeWhatIfArguments) `
        -Case 'What-if invocation requests raw JSON with --no-pretty-print'
    Assert-WhatIfContract `
        -Condition (
            (Get-FakeAzArgumentValue `
                    -Arguments $safeWhatIfArguments `
                    -Name '--result-format') -ceq 'FullResourcePayloads'
        ) `
        -Case 'What-if invocation requests FullResourcePayloads'
    Assert-WhatIfContract `
        -Condition (
            (Get-FakeAzArgumentValue `
                    -Arguments $safeWhatIfArguments `
                    -Name '--output') -ceq 'json'
        ) `
        -Case 'What-if invocation requests json output'
    Assert-WhatIfContract `
        -Condition ($safeRun.LeakedTempFiles -eq 0) `
        -Case 'Safe guarded deployment removes its temporary files'

    $noisyRun = Invoke-FakeGuardedDeployment `
        -Mode 'NoisyJson' `
        -DeploymentName 'noisy-fixture' `
        -WhatIfFixtureName 'both scopes present'
    Assert-WhatIfContract `
        -Condition ($null -eq $noisyRun.ErrorMessage) `
        -Case "Error-stream noise must not break what-if parsing: $($noisyRun.ErrorMessage)"
    Assert-WhatIfContract `
        -Condition ($noisyRun.Operations -ceq 'what-if,create') `
        -Case 'Error-stream noise still allows create after a safe what-if'
    Assert-WhatIfContract `
        -Condition ($noisyRun.LeakedTempFiles -eq 0) `
        -Case 'Noisy guarded deployment removes its temporary files'

    $nativeNoisyRun = Invoke-FakeGuardedDeployment `
        -Mode 'NativeNoisyJson' `
        -DeploymentName 'native-noisy-fixture' `
        -WhatIfFixtureName 'both scopes present'
    Assert-WhatIfContract `
        -Condition ($null -eq $nativeNoisyRun.ErrorMessage) `
        -Case "Native stderr noise must not contaminate parsed stdout: $($nativeNoisyRun.ErrorMessage)"
    Assert-WhatIfContract `
        -Condition ($nativeNoisyRun.Operations -ceq 'what-if,create') `
        -Case 'Native stderr noise still allows create after a safe what-if'
    Assert-WhatIfContract `
        -Condition ($nativeNoisyRun.LeakedTempFiles -eq 0) `
        -Case 'Native noisy guarded deployment removes its temporary files'

    $prettyRun = Invoke-FakeGuardedDeployment `
        -Mode 'PrettyPrint' `
        -DeploymentName 'pretty-fixture' `
        -WhatIfFixtureName 'both scopes present'
    Assert-WhatIfContract `
        -Condition ($null -ne $prettyRun.ErrorMessage) `
        -Case 'Pretty-printed what-if output must fail closed'
    Assert-WhatIfContract `
        -Condition ($prettyRun.Operations -ceq 'what-if') `
        -Case 'Pretty-printed what-if output must abort before create'
    Assert-WhatIfContract `
        -Condition (
            $prettyRun.ErrorMessage.Contains(
                'did not return valid JSON',
                [StringComparison]::Ordinal
            )
        ) `
        -Case 'Pretty-printed failure keeps the invalid JSON diagnosis'
    Assert-WhatIfContract `
        -Condition (
            $prettyRun.ErrorMessage.Contains('az stdout:', [StringComparison]::Ordinal) -and
            $prettyRun.ErrorMessage.Contains(
                'Resource changes: 1 to modify.',
                [StringComparison]::Ordinal
            )
        ) `
        -Case 'Pretty-printed failure reports the captured stdout excerpt'
    Assert-WhatIfContract `
        -Condition (
            $prettyRun.ErrorMessage.Contains('az stderr:', [StringComparison]::Ordinal) -and
            $prettyRun.ErrorMessage.Contains(
                $script:syntheticStderrToken,
                [StringComparison]::Ordinal
            )
        ) `
        -Case 'Pretty-printed failure reports the captured stderr excerpt'
    Assert-WhatIfContract `
        -Condition ($prettyRun.LeakedTempFiles -eq 0) `
        -Case 'Failed guarded deployment removes its temporary files'

    $exitCodeRun = Invoke-FakeGuardedDeployment `
        -Mode 'Failure' `
        -DeploymentName 'exit-code-fixture' `
        -WhatIfFixtureName 'both scopes present'
    Assert-WhatIfContract `
        -Condition (
            $null -ne $exitCodeRun.ErrorMessage -and
            $exitCodeRun.ErrorMessage.Contains(
                'with exit code 1',
                [StringComparison]::Ordinal
            ) -and
            $exitCodeRun.ErrorMessage.Contains(
                $script:syntheticStderrToken,
                [StringComparison]::Ordinal
            )
        ) `
        -Case 'Nonzero what-if exit code fails closed with diagnostics'
    Assert-WhatIfContract `
        -Condition ($exitCodeRun.Operations -ceq 'what-if') `
        -Case 'Nonzero what-if exit code aborts before create'
    Assert-WhatIfContract `
        -Condition ($exitCodeRun.LeakedTempFiles -eq 0) `
        -Case 'Failed what-if exit code removes its temporary files'

    $nativeFailurePreferenceExisted = $null -ne (
        Get-Variable -Name 'PSNativeCommandUseErrorActionPreference' -ErrorAction SilentlyContinue
    )
    $nativeFailurePreviousPreference = Get-Variable `
        -Name 'PSNativeCommandUseErrorActionPreference' `
        -ValueOnly `
        -ErrorAction SilentlyContinue
    try {
        $PSNativeCommandUseErrorActionPreference = $true
        $nativeFailureRun = Invoke-FakeGuardedDeployment `
            -Mode 'NativeFailure' `
            -DeploymentName 'native-exit-code-fixture' `
            -WhatIfFixtureName 'both scopes present'
        Assert-WhatIfContract `
            -Condition ($PSNativeCommandUseErrorActionPreference -eq $true) `
            -Case 'Guarded what-if keeps its native command preference override function scoped'
    } finally {
        if ($nativeFailurePreferenceExisted) {
            Set-Variable `
                -Name 'PSNativeCommandUseErrorActionPreference' `
                -Value $nativeFailurePreviousPreference
        } else {
            Remove-Variable `
                -Name 'PSNativeCommandUseErrorActionPreference' `
                -ErrorAction SilentlyContinue
        }
    }
    Assert-WhatIfContract `
        -Condition (
            $null -ne $nativeFailureRun.ErrorMessage -and
            $nativeFailureRun.ErrorMessage.Contains(
                "with exit code $($script:nativeFailureExitCode)",
                [StringComparison]::Ordinal
            ) -and
            $nativeFailureRun.ErrorMessage.Contains(
                $script:nativeFailureStdoutToken,
                [StringComparison]::Ordinal
            ) -and
            $nativeFailureRun.ErrorMessage.Contains(
                $script:syntheticStderrToken,
                [StringComparison]::Ordinal
            )
        ) `
        -Case 'Nonzero native what-if exit code reports the guard diagnostics under Stop preference'
    Assert-WhatIfContract `
        -Condition (
            $null -ne $nativeFailureRun.ErrorType -and
            -not $nativeFailureRun.ErrorType.Contains(
                'NativeCommandExitException',
                [StringComparison]::Ordinal
            ) -and
            -not $nativeFailureRun.ErrorType.Contains(
                'RemoteException',
                [StringComparison]::Ordinal
            )
        ) `
        -Case 'Nonzero native what-if exit code is not surfaced as a generic native command failure'
    Assert-WhatIfContract `
        -Condition ($nativeFailureRun.Operations -ceq 'what-if') `
        -Case 'Nonzero native what-if exit code aborts before create'
    Assert-WhatIfContract `
        -Condition ($nativeFailureRun.LeakedTempFiles -eq 0) `
        -Case 'Nonzero native what-if exit code removes its temporary files'

    $unsafeRun = Invoke-FakeGuardedDeployment `
        -Mode 'Json' `
        -DeploymentName 'unsafe-fixture' `
        -WhatIfFixtureName 'Arc scope Delete'
    Assert-WhatIfContract `
        -Condition ($null -ne $unsafeRun.ErrorMessage) `
        -Case 'Unsafe what-if must abort the guarded deployment'
    Assert-WhatIfContract `
        -Condition ($unsafeRun.Operations -ceq 'what-if') `
        -Case 'Unsafe guarded deployment aborts between what-if and create'
    Assert-WhatIfContract `
        -Condition ($unsafeRun.LeakedTempFiles -eq 0) `
        -Case 'Unsafe guarded deployment removes its temporary files'

    $script:deploymentOperations.Clear()
    $missingSwitchError = $null
    try {
        $null = Invoke-SreAgentWhatIfJson `
            -Arguments @(
                'deployment', 'group', 'what-if',
                '--result-format', 'FullResourcePayloads',
                '--output', 'json'
            ) `
            -DeploymentName 'missing-switch-fixture'
    } catch {
        $missingSwitchError = $_.Exception.Message
    }
    Assert-WhatIfContract `
        -Condition (
            $null -ne $missingSwitchError -and
            $missingSwitchError.Contains('--no-pretty-print', [StringComparison]::Ordinal)
        ) `
        -Case 'What-if capture refuses invocations without --no-pretty-print'
    Assert-WhatIfContract `
        -Condition ($script:deploymentOperations.Count -eq 0) `
        -Case 'What-if capture rejects unsafe invocations before calling Azure CLI'

    $boundedExcerpt = Format-SreAgentWhatIfStreamExcerpt `
        -Label 'az stdout' `
        -Content ('x' * 5000) `
        -MaxCharacters 2000
    Assert-WhatIfContract `
        -Condition (
            $boundedExcerpt.Contains(
                '[truncated at 2000 characters]',
                [StringComparison]::Ordinal
            ) -and
            $boundedExcerpt.Length -lt 2100
        ) `
        -Case 'Diagnostic excerpts stay bounded'

    $syntheticSensitiveValue = 'synthetic-sensitive-value-never-log'
    $redactedExcerpt = Format-SreAgentWhatIfStreamExcerpt `
        -Label 'az stdout' `
        -Content (
            '{ "connectionString": "InstrumentationKey=' +
            $syntheticSensitiveValue +
            ';IngestionEndpoint=https://eastus2.example.invalid/", "clientSecret": "' +
            $syntheticSensitiveValue +
            '", "resourceId": "/subscriptions/fixture/resourceGroups/fixture" }'
        )
    Assert-WhatIfContract `
        -Condition (
            -not $redactedExcerpt.Contains(
                $syntheticSensitiveValue,
                [StringComparison]::Ordinal
            )
        ) `
        -Case 'Diagnostic excerpts redact secret-shaped values'
    Assert-WhatIfContract `
        -Condition (
            $redactedExcerpt.Contains('[redacted]', [StringComparison]::Ordinal) -and
            $redactedExcerpt.Contains(
                '/subscriptions/fixture/resourceGroups/fixture',
                [StringComparison]::Ordinal
            )
        ) `
        -Case 'Diagnostic excerpts keep non-sensitive diagnosis context'
} finally {
    foreach ($tempVariableName in @($originalTempVariables.Keys)) {
        Set-Item `
            -LiteralPath "Env:\$tempVariableName" `
            -Value $originalTempVariables[$tempVariableName] `
            -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $tempProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $nativeNoiseRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$bicepSource = Get-Content -LiteralPath "$repoRoot\infra\main.bicep" -Raw
foreach ($requiredFragment in @(
        "param arcResourceGroupName string = 'rg-arcbox-itpro-weu-002'",
        "subscriptionResourceId('Microsoft.Resources/resourceGroups', arcResourceGroupName)",
        "managedResources: [`r`n        resourceGroup().id`r`n        arcResourceGroupId"
    )) {
    if (-not $bicepSource.Contains($requiredFragment, [StringComparison]::Ordinal)) {
        throw "main.bicep did not preserve '$requiredFragment'."
    }
}

$parameters = Get-Content -LiteralPath "$repoRoot\infra\main.parameters.json" -Raw |
    ConvertFrom-Json
if ($parameters.parameters.arcResourceGroupName.value -ne 'rg-arcbox-itpro-weu-002') {
    throw 'main.parameters.json did not preserve the safe Arc resource-group default.'
}

Write-Host 'SRE Agent what-if guard contract passed.'
