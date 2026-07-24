#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$preflightPath = Join-Path $PSScriptRoot 'SreAgent.GitHubPreflight.ps1'
. $preflightPath

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

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Action,
        [Parameter(Mandatory)]
        [string] $ExpectedPattern,
        [Parameter(Mandatory)]
        [string] $Case
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notlike $ExpectedPattern) {
            throw "$Case failed. Expected '$ExpectedPattern', got '$($_.Exception.Message)'."
        }
        return $_.Exception.Message
    }
    throw "$Case failed. Expected an exception."
}

function New-TestRepository {
    param(
        [Parameter(Mandatory)]
        [string] $Status,
        [AllowEmptyString()]
        [string] $Commit,
        [ValidateSet('lastCommitHash', 'commitId', 'commitHash')]
        [string] $CommitField = 'lastCommitHash',
        [string] $Url = 'https://github.com/marioaguileraaa/mercadona-sre-agent-demo',
        [string] $Branch = 'main',
        [switch] $Flat,
        [switch] $Wrapped
    )

    if ($Flat) {
        $repository = [ordered]@{
            name = 'mercadona-sre-agent-demo'
            type = 'GitHub'
            url = $Url
            branch = $Branch
            cloneStatus = $Status
        }
        if (-not [string]::IsNullOrWhiteSpace($Commit)) {
            $repository[$CommitField] = $Commit
        }
    } else {
        $properties = [ordered]@{
            type = 'GitHub'
            url = $Url
            branch = $Branch
            cloneStatus = $Status
        }
        if (-not [string]::IsNullOrWhiteSpace($Commit)) {
            $properties[$CommitField] = $Commit
        }
        $repository = [ordered]@{
            name = 'mercadona-sre-agent-demo'
            type = 'CodeRepo'
            properties = $properties
        }
    }
    $result = [pscustomobject] $repository
    if ($Wrapped) {
        return [pscustomobject]@{ value = $result }
    }
    return $result
}

function New-TestDomains {
    param(
        [string] $Status = 'Connected',
        [AllowNull()]
        [object] $IsHealthy = $true,
        [switch] $Wrapped
    )

    $properties = [ordered]@{
        domain = 'github.com'
        connectionStatus = $Status
    }
    if ($null -ne $IsHealthy) {
        $properties['isHealthy'] = $IsHealthy
    }
    $domain = [pscustomobject]@{ properties = [pscustomobject] $properties }
    if ($Wrapped) {
        return [pscustomobject]@{ data = [pscustomobject]@{ domains = @($domain) } }
    }
    return @($domain)
}

function New-TestTools {
    param(
        [Parameter(Mandatory)]
        [string[]] $Names,
        [switch] $Wrapped
    )

    $tools = @($Names | ForEach-Object { [pscustomobject]@{ toolName = $_ } })
    if ($Wrapped) {
        return [pscustomobject]@{
            data = [pscustomobject]@{
                tools = $tools
            }
        }
    }
    return $tools
}

$expectedCommit = ('a' * 40) -join ''
$staleCommit = ('b' * 40) -join ''
$repositoryName = 'mercadona-sre-agent-demo'
$repositoryUrl = 'https://github.com/marioaguileraaa/mercadona-sre-agent-demo'
$script:fakeNow = [DateTimeOffset]::Parse('2026-07-24T10:00:00Z')
$getFakeUtcNow = { $script:fakeNow }
$advanceFakeClock = {
    param([int] $Seconds)
    $script:fakeNow = $script:fakeNow.AddSeconds($Seconds)
}
$unexpectedRead = { throw 'Repository read should not have been called.' }

$flatReady = New-TestRepository -Status Ready -Commit $expectedCommit -Flat
$flatState = Wait-SreRepositoryReadyAtCommit `
    -InitialRepository $flatReady `
    -ReadRepository $unexpectedRead `
    -CreateRepository $null `
    -RequestSynchronization $null `
    -RepositoryName $repositoryName `
    -RepositoryUrl $repositoryUrl `
    -RepositoryBranch main `
    -ExpectedCommit $expectedCommit
Assert-Equal -Actual $flatState.Commit -Expected $expectedCommit -Case 'Flat Ready repository exact SHA'

$wrappedReady = New-TestRepository `
    -Status Ready `
    -Commit $expectedCommit.ToUpperInvariant() `
    -CommitField commitId `
    -Wrapped
$wrappedState = Wait-SreRepositoryReadyAtCommit `
    -InitialRepository $wrappedReady `
    -ReadRepository $unexpectedRead `
    -CreateRepository $null `
    -RequestSynchronization $null `
    -RepositoryName $repositoryName `
    -RepositoryUrl $repositoryUrl `
    -RepositoryBranch main `
    -ExpectedCommit $expectedCommit
Assert-Equal `
    -Actual $wrappedState.Commit `
    -Expected $expectedCommit.ToUpperInvariant() `
    -Case 'Wrapped repository commitId compatibility'

$script:syncCalls = 0
$script:syncReadQueue = [System.Collections.Generic.Queue[object]]::new()
$script:syncReadQueue.Enqueue((New-TestRepository -Status Syncing -Commit $staleCommit))
$script:syncReadQueue.Enqueue((New-TestRepository -Status Ready -Commit $expectedCommit))
$synchronizedState = Wait-SreRepositoryReadyAtCommit `
    -InitialRepository (New-TestRepository -Status Ready -Commit $staleCommit) `
    -ReadRepository { $script:syncReadQueue.Dequeue() } `
    -CreateRepository $null `
    -RequestSynchronization { $script:syncCalls++ } `
    -RepositoryName $repositoryName `
    -RepositoryUrl $repositoryUrl `
    -RepositoryBranch main `
    -ExpectedCommit $expectedCommit `
    -TimeoutSeconds 3 `
    -PollIntervalSeconds 1 `
    -Sleep $advanceFakeClock `
    -GetUtcNow $getFakeUtcNow
Assert-Equal -Actual $script:syncCalls -Expected 1 -Case 'Stale repository requests one supported sync'
Assert-Equal -Actual $synchronizedState.Commit -Expected $expectedCommit -Case 'Supported sync reaches exact SHA'

$staleFailure = Assert-ThrowsLike `
    -Action {
        Wait-SreRepositoryReadyAtCommit `
            -InitialRepository (New-TestRepository -Status Ready -Commit $staleCommit) `
            -ReadRepository $unexpectedRead `
            -CreateRepository $null `
            -RequestSynchronization $null `
            -RepositoryName $repositoryName `
            -RepositoryUrl $repositoryUrl `
            -RepositoryBranch main `
            -ExpectedCommit $expectedCommit
    } `
    -ExpectedPattern '*No supported repository synchronization endpoint is documented*Builder > Knowledge base > Add repository*' `
    -Case 'Stale repository without supported sync fails explicitly'
if ($staleFailure -notlike "*Expected full commit '$expectedCommit', reported '$staleCommit'*") {
    throw 'Stale repository failure did not report both full SHAs.'
}

Assert-ThrowsLike `
    -Action {
        Wait-SreRepositoryReadyAtCommit `
            -InitialRepository (New-TestRepository -Status Ready -Commit $staleCommit) `
            -ReadRepository $unexpectedRead `
            -CreateRepository $null `
            -RequestSynchronization { throw 'synthetic sync failure' } `
            -RepositoryName $repositoryName `
            -RepositoryUrl $repositoryUrl `
            -RepositoryBranch main `
            -ExpectedCommit $expectedCommit
    } `
    -ExpectedPattern '*synchronization request failed: synthetic sync failure' `
    -Case 'Failed supported sync is surfaced'

$script:pendingReadCalls = 0
$script:fakeNow = [DateTimeOffset]::Parse('2026-07-24T11:00:00Z')
Assert-ThrowsLike `
    -Action {
        Wait-SreRepositoryReadyAtCommit `
            -InitialRepository (New-TestRepository -Status Syncing -Commit $staleCommit) `
            -ReadRepository {
                $script:pendingReadCalls++
                New-TestRepository -Status Syncing -Commit $staleCommit
            } `
            -CreateRepository $null `
            -RequestSynchronization $null `
            -RepositoryName $repositoryName `
            -RepositoryUrl $repositoryUrl `
            -RepositoryBranch main `
            -ExpectedCommit $expectedCommit `
            -TimeoutSeconds 2 `
            -PollIntervalSeconds 1 `
            -Sleep $advanceFakeClock `
            -GetUtcNow $getFakeUtcNow
    } `
    -ExpectedPattern '*did not reach Ready at exact commit*within 2 seconds*' `
    -Case 'Repository indexing timeout fails'
Assert-Equal -Actual $script:pendingReadCalls -Expected 2 -Case 'Timeout waits through the full deadline'

$script:fakeNow = [DateTimeOffset]::Parse('2026-07-24T12:00:00Z')
Assert-ThrowsLike `
    -Action {
        Wait-SreRepositoryReadyAtCommit `
            -InitialRepository (New-TestRepository -Status Syncing -Commit $staleCommit) `
            -ReadRepository {
                $script:fakeNow = $script:fakeNow.AddSeconds(10)
                New-TestRepository -Status Ready -Commit $expectedCommit
            } `
            -CreateRepository $null `
            -RequestSynchronization $null `
            -RepositoryName $repositoryName `
            -RepositoryUrl $repositoryUrl `
            -RepositoryBranch main `
            -ExpectedCommit $expectedCommit `
            -TimeoutSeconds 2 `
            -PollIntervalSeconds 1 `
            -Sleep { param([int] $Seconds) } `
            -GetUtcNow $getFakeUtcNow
    } `
    -ExpectedPattern '*did not reach Ready at exact commit*within 2 seconds*' `
    -Case 'Ready result returned after deadline is rejected'

Assert-ThrowsLike `
    -Action {
        Wait-SreRepositoryReadyAtCommit `
            -InitialRepository (New-TestRepository -Status Failed -Commit $staleCommit) `
            -ReadRepository $unexpectedRead `
            -CreateRepository $null `
            -RequestSynchronization $null `
            -RepositoryName $repositoryName `
            -RepositoryUrl $repositoryUrl `
            -RepositoryBranch main `
            -ExpectedCommit $expectedCommit
    } `
    -ExpectedPattern "*indexing failed with cloneStatus 'Failed'*" `
    -Case 'Failed repository state fails'

Assert-ThrowsLike `
    -Action {
        Wait-SreRepositoryReadyAtCommit `
            -InitialRepository (New-TestRepository -Status Ready -Commit '') `
            -ReadRepository $unexpectedRead `
            -CreateRepository $null `
            -RequestSynchronization $null `
            -RepositoryName $repositoryName `
            -RepositoryUrl $repositoryUrl `
            -RepositoryBranch main `
            -ExpectedCommit $expectedCommit
    } `
    -ExpectedPattern '*Ready but did not expose lastCommitHash, commitId, or commitHash*' `
    -Case 'Ready repository missing SHA fails'

Assert-ThrowsLike `
    -Action {
        Wait-SreRepositoryReadyAtCommit `
            -InitialRepository (New-TestRepository -Status Ready -Commit 'abc123' -Flat) `
            -ReadRepository $unexpectedRead `
            -CreateRepository $null `
            -RequestSynchronization $null `
            -RepositoryName $repositoryName `
            -RepositoryUrl $repositoryUrl `
            -RepositoryBranch main `
            -ExpectedCommit $expectedCommit
    } `
    -ExpectedPattern '*reported a non-full commit SHA*' `
    -Case 'Abbreviated repository SHA fails'

foreach ($sourceMismatch in @(
        (New-TestRepository -Status Ready -Commit $expectedCommit -Url 'https://github.com/example/other'),
        (New-TestRepository -Status Ready -Commit $expectedCommit -Branch develop)
    )) {
    Assert-ThrowsLike `
        -Action {
            Wait-SreRepositoryReadyAtCommit `
                -InitialRepository $sourceMismatch `
                -ReadRepository $unexpectedRead `
                -CreateRepository $null `
                -RequestSynchronization $null `
                -RepositoryName $repositoryName `
                -RepositoryUrl $repositoryUrl `
                -RepositoryBranch main `
                -ExpectedCommit $expectedCommit
        } `
        -ExpectedPattern '*does not match the required URL*Refusing destructive replacement*' `
        -Case 'Repository source mismatch fails'
}

$snakeTools = New-TestTools -Names @(
    'issue_write',
    'create_branch',
    'push_files',
    'create_pull_request'
)
$snakeSelection = @(
    Assert-SreGithubWriteReadiness `
        -DomainsResponse (New-TestDomains) `
        -ToolsResponse $snakeTools
)
Assert-Equal -Actual $snakeSelection.Count -Expected 4 -Case 'Exact snake-case write tools pass'

$pascalTools = New-TestTools -Names @(
    'CreateGithubIssue',
    'UpdateGithubIssue',
    'CreateGithubBranch',
    'PushGithubFiles',
    'CreateGithubPullRequest'
) -Wrapped
$pascalSelection = @(
    Assert-SreGithubWriteReadiness `
        -DomainsResponse (New-TestDomains -IsHealthy $null -Wrapped) `
        -ToolsResponse $pascalTools
)
Assert-Equal -Actual $pascalSelection.Count -Expected 5 -Case 'Evidence-backed PascalCase write tools pass'

$script:mutationCalls = 0
$readOnlyFailure = Assert-ThrowsLike `
    -Action {
        Invoke-SreGithubRepositoryPreflight `
            -DomainsResponse (New-TestDomains -Wrapped) `
            -ToolsResponse (New-TestTools -Names @(
                    'FetchGithubIssue',
                    'FetchGithubIssues',
                    'FindConnectedGitHubRepo',
                    'ReadGithubContents',
                    'ListGithubPullRequests'
                ) -Wrapped) `
            -InitialRepository $flatReady `
            -ReadRepository { $script:mutationCalls++; $flatReady } `
            -CreateRepository { $script:mutationCalls++ } `
            -RequestSynchronization { $script:mutationCalls++ } `
            -RepositoryName $repositoryName `
            -RepositoryUrl $repositoryUrl `
            -RepositoryBranch main `
            -ExpectedCommit $expectedCommit
    } `
    -ExpectedPattern '*GitHub OAuth is healthy but exact write capabilities are missing*Read-only tools do not satisfy this preflight*reconnect/authorize permissions for issues, contents and pull requests*' `
    -Case 'Healthy OAuth with read-only tools fails before mutations'
Assert-Equal -Actual $script:mutationCalls -Expected 0 -Case 'No repository mutation before OAuth/tool preflight'
if ($readOnlyFailure -match '(?i)token|secret=|authorization:') {
    throw 'Read-only capability failure exposed secret-shaped output.'
}

Assert-ThrowsLike `
    -Action {
        Assert-SreGithubWriteReadiness `
            -DomainsResponse (New-TestDomains -Status '' -IsHealthy $null) `
            -ToolsResponse $snakeTools
    } `
    -ExpectedPattern "*GitHub OAuth domain 'github.com' is not healthy*Builder > Connectors > GitHub OAuth*" `
    -Case 'Domain without explicit health fails'

$syntheticSecret = 'synthetic-sensitive-value-never-log'
$secretBearingDomains = [pscustomobject]@{
    values = @(
        [pscustomobject]@{
            domain = 'github.com'
            status = 'Disconnected'
            accessToken = $syntheticSecret
        }
    )
}
$secretFailure = Assert-ThrowsLike `
    -Action {
        Assert-SreGithubWriteReadiness `
            -DomainsResponse $secretBearingDomains `
            -ToolsResponse ([pscustomobject]@{
                values = @(
                    [pscustomobject]@{
                        name = 'FetchGithubIssue'
                        secret = $syntheticSecret
                    }
                )
            })
    } `
    -ExpectedPattern '*GitHub OAuth domain*not healthy*' `
    -Case 'Secret-bearing failure remains sanitized'
if ($secretFailure.Contains($syntheticSecret, [StringComparison]::Ordinal)) {
    throw 'GitHub preflight failure logged a secret-bearing response value.'
}

Assert-ThrowsLike `
    -Action {
        Resolve-ExpectedRepositoryCommit `
            -ExpectedRepositoryCommit '932284c' `
            -RepositoryRoot (Split-Path $PSScriptRoot -Parent)
    } `
    -ExpectedPattern '*one full 40-character hexadecimal Git commit SHA*' `
    -Case 'Expected commit rejects abbreviated SHA'

$configureSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'configure-sre-agent.ps1') -Raw
$verifySource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-sre-agent.ps1') -Raw
$preflightSource = Get-Content -LiteralPath $preflightPath -Raw
$preflightCallIndex = $configureSource.IndexOf(
    '$githubRepositoryPreflight = Invoke-SreGithubRepositoryPreflight',
    [StringComparison]::Ordinal
)
foreach ($mutationMarker in @(
        "Invoke-AgentApi -Method Put -Path '/api/v2/agent/settings/global'",
        'Invoke-AgentApi -Method Put -Path "/api/v2/extendedAgent/agents/$incidentHandlerName"',
        'Invoke-AgentApi -Method Put -Path "/api/v2/extendedAgent/incidentFilters/$incidentFilterName"'
    )) {
    $mutationIndex = $configureSource.IndexOf($mutationMarker, [StringComparison]::Ordinal)
    if ($preflightCallIndex -lt 0 -or $mutationIndex -le $preflightCallIndex) {
        throw "Agent API mutation '$mutationMarker' is not gated behind the shared preflight."
    }
}
$limitMutationIndex = $configureSource.IndexOf('$limitPatch = @{', [StringComparison]::Ordinal)
if ($limitMutationIndex -le $preflightCallIndex) {
    throw 'Agent monthly limit mutation is not gated behind GitHub/repository preflight.'
}
if (-not $configureSource.Contains('-RequestSynchronization $null', [StringComparison]::Ordinal) -or
    $configureSource -match '(?i)/api/v2/repos/[^\s''"`]+/(sync|resync|refresh)') {
    throw 'Configure script invented or enabled an unsupported repository synchronization endpoint.'
}
$configureTokens = $null
$configureErrors = $null
$configureAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'configure-sre-agent.ps1'),
    [ref] $configureTokens,
    [ref] $configureErrors
)
if ($configureErrors.Count -gt 0) {
    throw "Configure parser errors: $($configureErrors.Message -join '; ')"
}
$repoDeleteCalls = @($configureAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-AgentApi' -and
                $node.Extent.Text -match '(?i)-Method\s+Delete' -and
                $node.Extent.Text -match '(?i)/api/v2/repos'
        }, $true))
if ($repoDeleteCalls.Count -gt 0) {
    throw 'Configure script can delete a CodeRepo automatically.'
}
if ($verifySource -match '(?is)(Invoke-AgentApi|Invoke-SreAgentWrite).+?/api/v2/repos') {
    throw 'Verifier can mutate a CodeRepo.'
}
foreach ($requiredField in @('lastCommitHash', 'commitId', 'commitHash')) {
    if (-not $preflightSource.Contains("'$requiredField'", [StringComparison]::Ordinal)) {
        throw "Repository commit compatibility field '$requiredField' is missing."
    }
}
if ($preflightSource -match '(?im)Write-(Host|Output|Verbose|Information|Warning|Debug|Error).*\$(token|secret|authorization)') {
    throw 'GitHub preflight can write secret-bearing variables.'
}

Write-Host 'SRE Agent GitHub OAuth and exact repository commit preflight contract passed.'
