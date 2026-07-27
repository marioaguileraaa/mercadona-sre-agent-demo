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
        [ValidateSet('latestCommit', 'lastCommitHash', 'commitId', 'commitHash')]
        [string] $CommitField = 'latestCommit',
        [string] $Url = 'https://github.com/marioaguileraaa/mercadona-sre-agent-demo',
        [AllowNull()]
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
            lastSuccessfulSync = '2026-07-24T08:13:44.8919155Z'
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
            lastSuccessfulSync = '2026-07-24T08:13:44.8919155Z'
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

function New-TestToolDescriptor {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [bool] $Enabled = $true,
        [string] $Source = 'mcp',
        [string] $Category = 'MCP',
        [switch] $OmitEnabledProperty
    )

    $descriptor = [ordered]@{
        name = $Name
        source = $Source
        mcpConnector = 'github'
        mcpConnectorDisplayName = 'github'
        defaultMode = 'ask'
    }
    if (-not $OmitEnabledProperty) {
        $descriptor['enabled'] = $Enabled
    }
    $descriptor['category'] = $Category
    $descriptor['schema'] = [pscustomobject]@{ type = 'object' }
    $descriptor['description'] = "Synthetic descriptor for $Name."
    return [pscustomobject] $descriptor
}

function New-TestToolCatalog {
    param(
        [string[]] $EnabledName = @(),
        [string[]] $DisabledName = @(),
        [switch] $OmitEnabledProperty
    )

    $descriptors = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $EnabledName) {
        $descriptors.Add((New-TestToolDescriptor `
                    -Name $name `
                    -Enabled $true `
                    -OmitEnabledProperty:$OmitEnabledProperty))
    }
    foreach ($name in $DisabledName) {
        $descriptors.Add((New-TestToolDescriptor -Name $name -Enabled $false))
    }
    return [pscustomobject]@{ data = @($descriptors) }
}

function Invoke-TestGit {
    param(
        [Parameter(Mandatory)]
        [string] $Root,
        [Parameter(Mandatory)]
        [string[]] $ArgumentList
    )

    $PSNativeCommandUseErrorActionPreference = $false
    $output = & git @(@('-C', $Root) + $ArgumentList) 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Test git '$($ArgumentList -join ' ')' failed with exit code $LASTEXITCODE."
    }
    return ([string]::Join("`n", @($output | ForEach-Object { [string] $_ }))).Trim()
}

function New-TestGitRepository {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sre-preflight-$([Guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Invoke-TestGit -Root $root -ArgumentList @('init', '--quiet', '--initial-branch', 'main') | Out-Null
    Invoke-TestGit -Root $root -ArgumentList @('config', 'user.name', 'SRE Contract Test') | Out-Null
    Invoke-TestGit -Root $root -ArgumentList @('config', 'user.email', 'sre-contract@example.invalid') | Out-Null
    Invoke-TestGit -Root $root -ArgumentList @('config', 'commit.gpgsign', 'false') | Out-Null
    return $root
}

function Add-TestCommit {
    param(
        [Parameter(Mandatory)]
        [string] $Root,
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $Message
    )

    $fullPath = Join-Path $Root $Path
    $parent = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Add-Content -LiteralPath $fullPath -Value $Message -Encoding utf8
    Invoke-TestGit -Root $Root -ArgumentList @('add', '--', $Path) | Out-Null
    Invoke-TestGit -Root $Root -ArgumentList @('commit', '--quiet', '-m', $Message) | Out-Null
    return (Invoke-TestGit -Root $Root -ArgumentList @('rev-parse', 'HEAD'))
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

$actualSnapshotShape = [pscustomobject]@{
    value = [pscustomobject]@{
        name = $repositoryName
        type = 'CodeRepo'
        properties = [pscustomobject]@{
            url = $repositoryUrl
            type = 'GitHub'
            branch = $null
            cloneStatus = 'Ready'
            latestCommit = $expectedCommit
            lastSuccessfulSync = '2026-07-24T08:13:44.8919155Z'
            scanStatus = 'NotStarted'
        }
    }
    nextLink = $null
}
$actualSnapshotState = Wait-SreRepositoryReadyAtCommit `
    -InitialRepository $actualSnapshotShape `
    -ReadRepository $unexpectedRead `
    -CreateRepository $null `
    -RequestSynchronization $null `
    -RepositoryName $repositoryName `
    -RepositoryUrl $repositoryUrl `
    -RepositoryBranch main `
    -ExpectedCommit $expectedCommit
Assert-Equal `
    -Actual $actualSnapshotState.Commit `
    -Expected $expectedCommit `
    -Case 'Actual value/properties/latestCommit response shape'
Assert-Equal `
    -Actual $actualSnapshotState.LastSuccessfulSync `
    -Expected '2026-07-24T08:13:44.8919155Z' `
    -Case 'Actual lastSuccessfulSync response field'

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
    -ExpectedPattern '*did not reach Ready at an acceptable commit for expected main commit*within 2 seconds*' `
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
    -ExpectedPattern '*did not reach Ready at an acceptable commit for expected main commit*within 2 seconds*' `
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
    -ExpectedPattern '*Ready but did not expose latestCommit, lastCommitHash, commitId, or commitHash*' `
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

$blankMainState = Wait-SreRepositoryReadyAtCommit `
    -InitialRepository (New-TestRepository -Status Ready -Commit $expectedCommit -Branch ' ') `
    -ReadRepository $unexpectedRead `
    -CreateRepository $null `
    -RequestSynchronization $null `
    -RepositoryName $repositoryName `
    -RepositoryUrl $repositoryUrl `
    -RepositoryBranch main `
    -ExpectedCommit $expectedCommit
Assert-Equal -Actual $blankMainState.Commit -Expected $expectedCommit -Case 'Blank branch defaults to main'

$missingBranchRepository = New-TestRepository -Status Ready -Commit $expectedCommit
$missingBranchRepository.properties.Remove('branch')
$missingMainState = Wait-SreRepositoryReadyAtCommit `
    -InitialRepository $missingBranchRepository `
    -ReadRepository $unexpectedRead `
    -CreateRepository $null `
    -RequestSynchronization $null `
    -RepositoryName $repositoryName `
    -RepositoryUrl $repositoryUrl `
    -RepositoryBranch main `
    -ExpectedCommit $expectedCommit
Assert-Equal -Actual $missingMainState.Commit -Expected $expectedCommit -Case 'Missing branch defaults to main'

foreach ($blankFeatureRepository in @(
        (New-TestRepository -Status Ready -Commit $expectedCommit -Branch ''),
        $missingBranchRepository
    )) {
    Assert-ThrowsLike `
        -Action {
            Wait-SreRepositoryReadyAtCommit `
                -InitialRepository $blankFeatureRepository `
                -ReadRepository $unexpectedRead `
                -CreateRepository $null `
                -RequestSynchronization $null `
                -RepositoryName $repositoryName `
                -RepositoryUrl $repositoryUrl `
                -RepositoryBranch feature `
                -ExpectedCommit $expectedCommit
        } `
        -ExpectedPattern '*does not match the required URL*Refusing destructive replacement*' `
        -Case 'Blank or missing branch does not default to feature'
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

$actualDomainShape = [pscustomobject]@{
    values = [pscustomobject]@{
        name = 'github.com'
        authType = 'OAuth'
        isHealthy = $true
        expiresOn = $null
        lastError = $null
        lastCheckedAt = '2026-07-24T10:38:43.1430677Z'
    }
}
$actualReadOnlyToolCatalog = @(
    'AskUserQuestion',
    'CreateDirectory',
    'CreateFile',
    'FileSearch',
    'FindConnectedGitHubRepo',
    'GrepSearch',
    'MultiReplaceStringInFile',
    'ReadFile',
    'ReplaceStringInFile',
    'RunAzCliReadCommands',
    'RunAzCliWriteCommands',
    'RunInTerminal',
    'ShowChangeDiffViewer',
    'Terminal'
)
Assert-ThrowsLike `
    -Action {
        Assert-SreGithubWriteReadiness `
            -DomainsResponse $actualDomainShape `
            -ToolsResponse $actualReadOnlyToolCatalog
    } `
    -ExpectedPattern '*GitHub OAuth is healthy but exact write capabilities are missing*' `
    -Case 'Actual healthy domain and read-only tool catalog fail closed'

$actualWriteToolCatalog = @(
    'issue_write',
    'create_branch',
    'push_files',
    'create_pull_request'
)
$actualWriteSelection = @(
    Assert-SreGithubWriteReadiness `
        -DomainsResponse $actualDomainShape `
        -ToolsResponse $actualWriteToolCatalog
)
Assert-Equal `
    -Actual $actualWriteSelection.Count `
    -Expected 4 `
    -Case 'Observed string-array write tool catalog passes'

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

# --- Tool catalog: current descriptor payload, legacy payloads, and fail-closed shapes ---

$realWriteToolName = @(
    'github_issue_write',
    'github_create_branch',
    'github_push_files',
    'github_create_pull_request'
)
$realCatalogSelection = @(
    Assert-SreGithubWriteReadiness `
        -DomainsResponse (New-TestDomains) `
        -ToolsResponse (New-TestToolCatalog -EnabledName $realWriteToolName)
)
Assert-Equal `
    -Actual $realCatalogSelection.Count `
    -Expected 4 `
    -Case 'Current data descriptor catalog with real names passes'
foreach ($expectedSelected in $realWriteToolName) {
    if ($realCatalogSelection -cnotcontains $expectedSelected) {
        throw "Descriptor catalog selection did not report the real tool '$expectedSelected'."
    }
}

$mixedRealCatalog = New-TestToolCatalog -EnabledName @(
    'github_get_file_contents',
    'github_search_code',
    'github_list_issues',
    'github_issue_read',
    'github_sub_issue_write',
    'github_pull_request_review_write',
    'github_issue_write',
    'github_create_branch',
    'github_create_or_update_file',
    'github_create_pull_request',
    'CreateFile',
    'RunInTerminal',
    'Terminal',
    'RunAzCliWriteCommands',
    'MultiReplaceStringInFile',
    'ReplaceStringInFile',
    'CreateDirectory'
)
$mixedRealSelection = @(
    Assert-SreGithubWriteReadiness `
        -DomainsResponse (New-TestDomains) `
        -ToolsResponse $mixedRealCatalog
)
Assert-Equal `
    -Actual $mixedRealSelection.Count `
    -Expected 4 `
    -Case 'Realistic mixed catalog selects only GitHub write tools'
if ($mixedRealSelection -cnotcontains 'github_create_or_update_file') {
    throw 'github_create_or_update_file was not accepted as the contents-write alternative.'
}

$legacyStringSelection = @(
    Assert-SreGithubWriteReadiness `
        -DomainsResponse (New-TestDomains) `
        -ToolsResponse $realWriteToolName
)
Assert-Equal `
    -Actual $legacyStringSelection.Count `
    -Expected 4 `
    -Case 'Legacy flat string array with real names passes'

$descriptorsWithoutEnabled = @(
    Assert-SreGithubWriteReadiness `
        -DomainsResponse (New-TestDomains) `
        -ToolsResponse (New-TestToolCatalog `
                -EnabledName $realWriteToolName `
                -OmitEnabledProperty)
)
Assert-Equal `
    -Actual $descriptorsWithoutEnabled.Count `
    -Expected 4 `
    -Case 'Descriptors without an enabled property are not invented as disabled'

foreach ($malformedCatalog in @(
        $null,
        @(),
        ([pscustomobject]@{}),
        ([pscustomobject]@{ data = @() }),
        ([pscustomobject]@{ data = @([pscustomobject]@{ category = 'MCP' }) })
    )) {
    Assert-ThrowsLike `
        -Action {
            Assert-SreGithubWriteReadiness `
                -DomainsResponse (New-TestDomains) `
                -ToolsResponse $malformedCatalog
        } `
        -ExpectedPattern '*agent tool catalog response was not recognized*Failing closed*' `
        -Case 'Malformed or empty tool catalog fails closed'
}

Assert-ThrowsLike `
    -Action {
        Assert-SreGithubWriteReadiness `
            -DomainsResponse (New-TestDomains) `
            -ToolsResponse (New-TestToolCatalog -EnabledName @(
                    'github_issue_write',
                    'github_create_branch',
                    'github_push_files'
                ))
    } `
    -ExpectedPattern '*write capabilities are missing*pullRequestCreate*' `
    -Case 'Absent pull-request-create capability fails'

$disabledFailure = Assert-ThrowsLike `
    -Action {
        Assert-SreGithubWriteReadiness `
            -DomainsResponse (New-TestDomains) `
            -ToolsResponse (New-TestToolCatalog `
                    -EnabledName @(
                        'github_create_branch',
                        'github_push_files',
                        'github_create_pull_request'
                    ) `
                    -DisabledName @('github_issue_write'))
    } `
    -ExpectedPattern '*write capabilities are missing*' `
    -Case 'Present but disabled capability fails'
if ($disabledFailure -notlike "*present but disabled: 'github_issue_write'*") {
    throw 'Disabled tool failure did not identify the disabled tool by name.'
}

Assert-ThrowsLike `
    -Action {
        Assert-SreGithubWriteReadiness `
            -DomainsResponse (New-TestDomains) `
            -ToolsResponse (New-TestToolCatalog -EnabledName @(
                    'CreateFile',
                    'RunInTerminal'
                ))
    } `
    -ExpectedPattern '*write capabilities are missing*Read-only tools do not satisfy this preflight*' `
    -Case 'Local-only tool catalog fails'

$substringFailure = Assert-ThrowsLike `
    -Action {
        Assert-SreGithubWriteReadiness `
            -DomainsResponse (New-TestDomains) `
            -ToolsResponse (New-TestToolCatalog -EnabledName @(
                    'github_sub_issue_write',
                    'github_create_branch',
                    'github_push_files',
                    'github_pull_request_review_write'
                ))
    } `
    -ExpectedPattern '*write capabilities are missing*' `
    -Case 'Substring-adjacent tool names never satisfy a capability'
foreach ($unsatisfiedCapability in @('issueCreate', 'issueUpdate', 'pullRequestCreate')) {
    if ($substringFailure -notlike "*$unsatisfiedCapability*") {
        throw "github_sub_issue_write or github_pull_request_review_write wrongly satisfied '$unsatisfiedCapability'."
    }
}

$caseFailure = Assert-ThrowsLike `
    -Action {
        Assert-SreGithubWriteReadiness `
            -DomainsResponse (New-TestDomains) `
            -ToolsResponse (New-TestToolCatalog -EnabledName @(
                    'GitHub_Issue_Write',
                    'GITHUB_CREATE_BRANCH',
                    'Github_Push_Files',
                    'GitHub_Create_Pull_Request'
                ))
    } `
    -ExpectedPattern '*write capabilities are missing*' `
    -Case 'Tool name comparison stays ordinal case-sensitive'
if ($caseFailure -notlike '*issueCreate*') {
    throw 'Case-shifted tool names were accepted for issueCreate.'
}

# --- Indexed commit acceptance over a deterministic temporary Git repository ---

$testRepositoryRoot = New-TestGitRepository
try {
    $apiCommit = Add-TestCommit `
        -Root $testRepositoryRoot `
        -Path 'MercadonaRetail.Api/Program.cs' `
        -Message 'Add synthetic retail API entry point'
    $frontendCommit = Add-TestCommit `
        -Root $testRepositoryRoot `
        -Path 'mercadona-retail-frontend/src/App.tsx' `
        -Message 'Add synthetic retail frontend shell'
    $docsCommit = Add-TestCommit `
        -Root $testRepositoryRoot `
        -Path 'docs/runbooks/cart-memory-pressure.md' `
        -Message 'Document the synthetic cart runbook'
    $mainCommit = Add-TestCommit `
        -Root $testRepositoryRoot `
        -Path 'scripts/configure-sre-agent.ps1' `
        -Message 'Harden the synthetic configure script'
    Invoke-TestGit -Root $testRepositoryRoot -ArgumentList @(
        'checkout', '--quiet', '-b', 'side', $apiCommit
    ) | Out-Null
    $sideCommit = Add-TestCommit `
        -Root $testRepositoryRoot `
        -Path 'docs/side-note.md' `
        -Message 'Add a synthetic side-branch note'
    Invoke-TestGit -Root $testRepositoryRoot -ArgumentList @('checkout', '--quiet', 'main') | Out-Null

    $identical = Test-SreIndexedCommitAcceptance `
        -IndexedCommit $mainCommit `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot
    Assert-Equal -Actual $identical.Accepted -Expected $true -Case 'Indexed commit equal to main is accepted'

    $ancestorWithoutAppChanges = Test-SreIndexedCommitAcceptance `
        -IndexedCommit $docsCommit `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot
    Assert-Equal `
        -Actual $ancestorWithoutAppChanges.Accepted `
        -Expected $true `
        -Case 'Ancestor with no missing application code is accepted'
    Assert-Equal `
        -Actual $ancestorWithoutAppChanges.ApplicationCodeCommit `
        -Expected $frontendCommit `
        -Case 'Accepted ancestor reports the latest application-code commit'

    $ancestorAtAppCommit = Test-SreIndexedCommitAcceptance `
        -IndexedCommit $frontendCommit `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot
    Assert-Equal `
        -Actual $ancestorAtAppCommit.Accepted `
        -Expected $true `
        -Case 'Indexed commit equal to the latest application-code commit is accepted'

    $staleApplicationCode = Test-SreIndexedCommitAcceptance `
        -IndexedCommit $apiCommit `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot
    Assert-Equal `
        -Actual $staleApplicationCode.Accepted `
        -Expected $false `
        -Case 'Ancestor predating the latest application-code commit is rejected'
    if ($staleApplicationCode.Reason -notlike "*predates the latest application-code commit '$frontendCommit'*" -or
        $staleApplicationCode.Reason -notlike "*reported '$apiCommit'*" -or
        $staleApplicationCode.Reason -notlike "*Expected full commit '$mainCommit'*") {
        throw "Stale application-code rejection did not report the exact condition and SHAs. Reported: $($staleApplicationCode.Reason)"
    }

    $missingCommit = Test-SreIndexedCommitAcceptance `
        -IndexedCommit (('f' * 40) -join '') `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot
    Assert-Equal `
        -Actual $missingCommit.Accepted `
        -Expected $false `
        -Case 'Indexed commit that does not exist locally is rejected'
    if ($missingCommit.Reason -notlike '*does not exist in the local repository*') {
        throw "Missing indexed commit rejection did not report the exact condition. Reported: $($missingCommit.Reason)"
    }

    $foreignBranchCommit = Test-SreIndexedCommitAcceptance `
        -IndexedCommit $sideCommit `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot
    Assert-Equal `
        -Actual $foreignBranchCommit.Accepted `
        -Expected $false `
        -Case 'Indexed commit outside the main line is rejected'
    if ($foreignBranchCommit.Reason -notlike '*not an ancestor of, or equal to, the expected main commit*') {
        throw "Foreign-branch rejection did not report the exact condition. Reported: $($foreignBranchCommit.Reason)"
    }

    foreach ($malformedIndexedCommit in @('932284c', '', 'not-a-sha', ($mainCommit + 'a'))) {
        $malformed = Test-SreIndexedCommitAcceptance `
            -IndexedCommit $malformedIndexedCommit `
            -ExpectedCommit $mainCommit `
            -RepositoryRoot $testRepositoryRoot
        Assert-Equal `
            -Actual $malformed.Accepted `
            -Expected $false `
            -Case 'Malformed or abbreviated indexed SHA is rejected'
        if ($malformed.Reason -notlike '*not one full 40-character hexadecimal Git commit SHA*') {
            throw "Malformed indexed SHA rejection did not report the exact condition. Reported: $($malformed.Reason)"
        }
    }

    $strictMismatch = Test-SreIndexedCommitAcceptance `
        -IndexedCommit $docsCommit `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot `
        -RequireExactMatch
    Assert-Equal `
        -Actual $strictMismatch.Accepted `
        -Expected $false `
        -Case 'Explicit -RequireExactRepositoryCommit keeps exact-match strictness'
    if ($strictMismatch.Reason -notlike '*-RequireExactRepositoryCommit was requested, so only an exact match is accepted*') {
        throw "Strict rejection did not report the exact condition. Reported: $($strictMismatch.Reason)"
    }

    $strictMatch = Test-SreIndexedCommitAcceptance `
        -IndexedCommit $mainCommit `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot `
        -RequireExactMatch
    Assert-Equal `
        -Actual $strictMatch.Accepted `
        -Expected $true `
        -Case 'Explicit -RequireExactRepositoryCommit still accepts the exact SHA'

    $apiOnlyPaths = Test-SreIndexedCommitAcceptance `
        -IndexedCommit $apiCommit `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot `
        -ApplicationCodePath @('MercadonaRetail.Api')
    Assert-Equal `
        -Actual $apiOnlyPaths.Accepted `
        -Expected $true `
        -Case 'Application code paths are an effective parameter'

    Assert-ThrowsLike `
        -Action {
            Test-SreIndexedCommitAcceptance `
                -IndexedCommit $docsCommit `
                -ExpectedCommit $mainCommit `
                -RepositoryRoot $testRepositoryRoot `
                -ApplicationCodePath @('MercadonaRetail.Absent')
        } `
        -ExpectedPattern '*could not be determined*fails closed*' `
        -Case 'Undeterminable application-code commit fails closed'

    Assert-ThrowsLike `
        -Action {
            Test-SreIndexedCommitAcceptance `
                -IndexedCommit $docsCommit `
                -ExpectedCommit $mainCommit `
                -RepositoryRoot (Join-Path $testRepositoryRoot 'absent-worktree')
        } `
        -ExpectedPattern '*cannot be validated*fails closed*' `
        -Case 'Missing local repository fails closed'

    $acceptedWaitState = Wait-SreRepositoryReadyAtCommit `
        -InitialRepository (New-TestRepository -Status Ready -Commit $docsCommit) `
        -ReadRepository $unexpectedRead `
        -CreateRepository $null `
        -RequestSynchronization $null `
        -RepositoryName $repositoryName `
        -RepositoryUrl $repositoryUrl `
        -RepositoryBranch main `
        -ExpectedCommit $mainCommit `
        -RepositoryRoot $testRepositoryRoot
    Assert-Equal `
        -Actual $acceptedWaitState.Commit `
        -Expected $docsCommit `
        -Case 'Wait accepts an ancestor that still contains all application code'

    $waitRejection = Assert-ThrowsLike `
        -Action {
            Wait-SreRepositoryReadyAtCommit `
                -InitialRepository (New-TestRepository -Status Ready -Commit $apiCommit) `
                -ReadRepository $unexpectedRead `
                -CreateRepository $null `
                -RequestSynchronization $null `
                -RepositoryName $repositoryName `
                -RepositoryUrl $repositoryUrl `
                -RepositoryBranch main `
                -ExpectedCommit $mainCommit `
                -RepositoryRoot $testRepositoryRoot
        } `
        -ExpectedPattern '*is stale*Builder > Knowledge base > Add repository*' `
        -Case 'Wait rejects an ancestor missing current application code'
    if ($waitRejection -notlike "*predates the latest application-code commit '$frontendCommit'*") {
        throw 'Wait rejection did not surface the precise acceptance failure.'
    }

    $strictWaitRejection = Assert-ThrowsLike `
        -Action {
            Wait-SreRepositoryReadyAtCommit `
                -InitialRepository (New-TestRepository -Status Ready -Commit $docsCommit) `
                -ReadRepository $unexpectedRead `
                -CreateRepository $null `
                -RequestSynchronization $null `
                -RepositoryName $repositoryName `
                -RepositoryUrl $repositoryUrl `
                -RepositoryBranch main `
                -ExpectedCommit $mainCommit `
                -RepositoryRoot $testRepositoryRoot `
                -RequireExactCommitMatch
        } `
        -ExpectedPattern '*is stale*' `
        -Case 'Wait honours explicit strict-commit callers'
    if ($strictWaitRejection -notlike '*only an exact match is accepted*') {
        throw 'Strict wait rejection did not surface the strict-mode condition.'
    }
} finally {
    Remove-Item -LiteralPath $testRepositoryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$verifySource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-sre-agent.ps1') -Raw
$configureSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'configure-sre-agent.ps1') -Raw
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
foreach ($requiredField in @('latestCommit', 'lastCommitHash', 'commitId', 'commitHash')) {
    if (-not $preflightSource.Contains("'$requiredField'", [StringComparison]::Ordinal)) {
        throw "Repository commit compatibility field '$requiredField' is missing."
    }
}
if ($preflightSource -match '(?im)Write-(Host|Output|Verbose|Information|Warning|Debug|Error).*\$(token|secret|authorization)') {
    throw 'GitHub preflight can write secret-bearing variables.'
}
function Get-TestBoundArgument {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst] $Command,
        [Parameter(Mandatory)]
        [string] $ParameterName
    )

    $elements = @($Command.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }
        if (-not [string]::Equals($element.ParameterName, $ParameterName, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($null -ne $element.Argument) {
            return $element.Argument.Extent.Text
        }
        if ($index + 1 -lt $elements.Count) {
            return $elements[$index + 1].Extent.Text
        }
        return ''
    }

    return $null
}

foreach ($callerScript in @('configure-sre-agent.ps1', 'verify-sre-agent.ps1')) {
    $callerPath = Join-Path $PSScriptRoot $callerScript
    $callerErrors = $null
    $callerAst = [System.Management.Automation.Language.Parser]::ParseFile($callerPath, [ref]$null, [ref]$callerErrors)
    if ($callerErrors -and $callerErrors.Count -gt 0) {
        throw "$callerScript does not parse."
    }

    $callerParameters = @($callerAst.ParamBlock.Parameters)
    $strictParameter = $callerParameters | Where-Object {
        $_.Name.VariablePath.UserPath -eq 'RequireExactRepositoryCommit'
    }
    if (-not $strictParameter) {
        throw "$callerScript does not expose an explicit -RequireExactRepositoryCommit parameter."
    }
    if ($strictParameter.StaticType -ne [switch]) {
        throw "$callerScript must expose -RequireExactRepositoryCommit as a switch, found '$($strictParameter.StaticType)'."
    }
    if (-not ($callerParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ExpectedRepositoryCommit' })) {
        throw "$callerScript no longer accepts -ExpectedRepositoryCommit, breaking existing callers."
    }

    $strictAssignments = $callerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Right.Extent.Text -match 'IsNullOrWhiteSpace\(\$ExpectedRepositoryCommit\)'
        }, $true)
    if (@($strictAssignments).Count -gt 0) {
        throw "$callerScript still derives strict commit matching from the presence of -ExpectedRepositoryCommit, which makes the lag-tolerant rule unreachable from the documented runbook."
    }

    $preflightCalls = @($callerAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                @('Invoke-SreGithubRepositoryPreflight', 'Wait-SreRepositoryReadyAtCommit') -contains $node.GetCommandName()
            }, $true))
    if ($preflightCalls.Count -lt 1) {
        throw "$callerScript does not call the shared repository preflight."
    }

    foreach ($preflightCall in $preflightCalls) {
        $callName = $preflightCall.GetCommandName()
        $callLine = $preflightCall.Extent.StartLineNumber

        $strictArgument = Get-TestBoundArgument -Command $preflightCall -ParameterName 'RequireExactCommitMatch'
        if ($null -eq $strictArgument) {
            throw "$callerScript line $callLine calls $callName without -RequireExactCommitMatch, so strict mode is silently lost."
        }
        if ($strictArgument -ne '$RequireExactRepositoryCommit') {
            throw "$callerScript line $callLine binds -RequireExactCommitMatch to '$strictArgument' instead of the explicit -RequireExactRepositoryCommit switch."
        }

        $rootArgument = Get-TestBoundArgument -Command $preflightCall -ParameterName 'RepositoryRoot'
        if ($null -eq $rootArgument) {
            throw "$callerScript line $callLine calls $callName without -RepositoryRoot, so commit ancestry cannot be evaluated."
        }
        if ($rootArgument -ne '$repoRoot') {
            throw "$callerScript line $callLine binds -RepositoryRoot to '$rootArgument' instead of the resolved repository root."
        }

        $expectedArgument = Get-TestBoundArgument -Command $preflightCall -ParameterName 'ExpectedCommit'
        if ($expectedArgument -ne '$expectedRepositoryCommit') {
            throw "$callerScript line $callLine binds -ExpectedCommit to '$expectedArgument' instead of the resolved expected commit."
        }
    }
}

$documentedRunbookFiles = @(
    'README.md',
    'docs/guia-demo-paso-a-paso.md',
    'docs/guion-demo-paridad-grubify.md',
    'docs/runbooks/cart-memory-pressure.md'
)
foreach ($documentedRunbookFile in $documentedRunbookFiles) {
    $documentedPath = Join-Path (Split-Path $PSScriptRoot -Parent) $documentedRunbookFile
    if (-not (Test-Path -LiteralPath $documentedPath)) {
        continue
    }
    $documentedText = Get-Content -Raw -LiteralPath $documentedPath
    if ($documentedText -match '(?m)^\s*[^#\r\n]*\.[\\/]scripts[\\/](configure|verify)-sre-agent\.ps1[^\r\n]*-RequireExactRepositoryCommit') {
        throw "$documentedRunbookFile documents -RequireExactRepositoryCommit, which would restore the exact-SHA block the lag-tolerant rule exists to remove."
    }
}

Write-Host 'SRE Agent GitHub write-capability and repository commit acceptance preflight contract passed.'
