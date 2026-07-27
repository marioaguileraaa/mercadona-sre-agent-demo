function Get-SreDefaultApplicationCodePath {
    return @(
        'MercadonaRetail.Api',
        'MercadonaRetail.Web',
        'mercadona-retail-frontend'
    )
}

function Get-SrePreflightValue {
    param(
        [AllowNull()]
        [object] $InputObject,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string] $key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                return $InputObject[$key]
            }
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties |
        Where-Object { [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-SrePreflightProperty {
    param(
        [AllowNull()]
        [object] $InputObject,
        [Parameter(Mandatory)]
        [string[]] $Names
    )

    $properties = Get-SrePreflightValue -InputObject $InputObject -Name 'properties'
    foreach ($candidate in @($properties, $InputObject)) {
        foreach ($name in $Names) {
            $value = Get-SrePreflightValue -InputObject $candidate -Name $name
            if ($null -ne $value) {
                return $value
            }
        }
    }
    return $null
}

function Get-SrePreflightPropertyInfo {
    param(
        [AllowNull()]
        [object] $InputObject,
        [Parameter(Mandatory)]
        [string[]] $Names
    )

    $properties = Get-SrePreflightValue -InputObject $InputObject -Name 'properties'
    foreach ($candidate in @($properties, $InputObject)) {
        if ($null -eq $candidate) {
            continue
        }
        foreach ($name in $Names) {
            if ($candidate -is [System.Collections.IDictionary]) {
                foreach ($key in $candidate.Keys) {
                    if ([string]::Equals(
                            [string] $key,
                            $name,
                            [StringComparison]::OrdinalIgnoreCase
                        )) {
                        return [PSCustomObject]@{
                            Found = $true
                            Value = $candidate[$key]
                        }
                    }
                }
                continue
            }
            $property = $candidate.PSObject.Properties |
                Where-Object {
                    [string]::Equals($_.Name, $name, [StringComparison]::OrdinalIgnoreCase)
                } |
                Select-Object -First 1
            if ($null -ne $property) {
                return [PSCustomObject]@{
                    Found = $true
                    Value = $property.Value
                }
            }
        }
    }
    return [PSCustomObject]@{
        Found = $false
        Value = $null
    }
}

function Get-SrePreflightItems {
    param(
        [AllowNull()]
        [object] $Response,
        [Parameter(Mandatory)]
        [string[]] $WrapperNames
    )

    if ($null -eq $Response) {
        return @()
    }
    if ($Response -is [array]) {
        return @($Response)
    }

    $current = $Response
    for ($depth = 0; $depth -lt 3; $depth++) {
        $unwrapped = $null
        foreach ($wrapperName in $WrapperNames) {
            $candidate = Get-SrePreflightValue -InputObject $current -Name $wrapperName
            if ($null -ne $candidate) {
                $unwrapped = $candidate
                break
            }
        }
        if ($null -eq $unwrapped) {
            break
        }
        if ($unwrapped -is [array]) {
            return @($unwrapped)
        }
        $current = $unwrapped
    }
    return @($current)
}

function Get-SrePreflightBoolean {
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($Value -is [bool]) {
        return [bool] $Value
    }
    if ($Value -is [string]) {
        return [string]::Equals(([string] $Value).Trim(), 'true', [StringComparison]::OrdinalIgnoreCase)
    }
    return $false
}

function Invoke-SrePreflightGit {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,
        [Parameter(Mandatory)]
        [string[]] $ArgumentList
    )

    if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "git was not found on PATH, so the indexed CodeRepo commit cannot be validated against '$RepositoryRoot'. The preflight fails closed."
    }

    $PSNativeCommandUseErrorActionPreference = $false
    $arguments = @('-C', $RepositoryRoot) + $ArgumentList
    $output = & git @arguments 2>$null
    $exitCode = $LASTEXITCODE
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = ([string]::Join("`n", @($output | ForEach-Object { [string] $_ }))).Trim()
    }
}

function Assert-SrePreflightRepositoryRoot {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $result = Invoke-SrePreflightGit `
        -RepositoryRoot $RepositoryRoot `
        -ArgumentList @('rev-parse', '--git-dir')
    if ($result.ExitCode -ne 0) {
        throw "'$RepositoryRoot' is not a usable local Git repository (git rev-parse --git-dir exit code $($result.ExitCode)). The indexed CodeRepo commit cannot be validated, so the preflight fails closed."
    }
}

function Test-SrePreflightCommitExists {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,
        [Parameter(Mandatory)]
        [string] $Commit
    )

    $result = Invoke-SrePreflightGit `
        -RepositoryRoot $RepositoryRoot `
        -ArgumentList @('cat-file', '-e', "$Commit^{commit}")
    return $result.ExitCode -eq 0
}

function Test-SrePreflightAncestor {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,
        [Parameter(Mandatory)]
        [string] $Ancestor,
        [Parameter(Mandatory)]
        [string] $Descendant
    )

    $result = Invoke-SrePreflightGit `
        -RepositoryRoot $RepositoryRoot `
        -ArgumentList @('merge-base', '--is-ancestor', $Ancestor, $Descendant)
    if ($result.ExitCode -eq 0) {
        return $true
    }
    if ($result.ExitCode -eq 1) {
        return $false
    }
    throw "git merge-base --is-ancestor '$Ancestor' '$Descendant' failed with exit code $($result.ExitCode) in '$RepositoryRoot'. The indexed CodeRepo commit cannot be validated, so the preflight fails closed."
}

function Get-SreApplicationCodeCommit {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,
        [Parameter(Mandatory)]
        [string] $MainCommit,
        [Parameter(Mandatory)]
        [string[]] $ApplicationCodePath
    )

    $paths = @($ApplicationCodePath | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
    if ($paths.Count -eq 0) {
        throw 'ApplicationCodePath must contain at least one non-empty repository path.'
    }
    $result = Invoke-SrePreflightGit `
        -RepositoryRoot $RepositoryRoot `
        -ArgumentList (@('log', '-1', '--format=%H', $MainCommit, '--') + $paths)
    if ($result.ExitCode -ne 0) {
        throw "git log for application code paths '$($paths -join ', ')' at '$MainCommit' failed with exit code $($result.ExitCode) in '$RepositoryRoot'. The preflight fails closed."
    }
    $commit = ($result.Output -split "`n" | Select-Object -First 1)
    $commit = ([string] $commit).Trim()
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "The latest application-code commit for paths '$($paths -join ', ')' at '$MainCommit' could not be determined in '$RepositoryRoot'. The preflight fails closed."
    }
    return $commit
}

function Test-SreIndexedCommitAcceptance {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $IndexedCommit,
        [Parameter(Mandatory)]
        [string] $ExpectedCommit,
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,
        [string[]] $ApplicationCodePath = (Get-SreDefaultApplicationCodePath),
        [switch] $RequireExactMatch
    )

    $summary = "Expected full commit '$ExpectedCommit', reported '$IndexedCommit'"
    $rejected = {
        param([string] $Detail)
        [PSCustomObject]@{
            Accepted = $false
            Reason = "$summary; $Detail"
            ApplicationCodeCommit = ''
        }
    }

    if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'ExpectedCommit must be one full 40-character hexadecimal Git commit SHA.'
    }
    if ([string]::Equals($IndexedCommit, $ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{
            Accepted = $true
            Reason = ''
            ApplicationCodeCommit = ''
        }
    }
    if ($RequireExactMatch) {
        return & $rejected '-RequireExactRepositoryCommit was requested, so only an exact match is accepted.'
    }
    if ($IndexedCommit -notmatch '^[0-9a-fA-F]{40}$') {
        return & $rejected 'the indexed commit is not one full 40-character hexadecimal Git commit SHA.'
    }
    Assert-SrePreflightRepositoryRoot -RepositoryRoot $RepositoryRoot
    if (-not (Test-SrePreflightCommitExists -RepositoryRoot $RepositoryRoot -Commit $IndexedCommit)) {
        return & $rejected "the indexed commit does not exist in the local repository at '$RepositoryRoot'. Run 'git fetch origin' and retry."
    }
    if (-not (Test-SrePreflightCommitExists -RepositoryRoot $RepositoryRoot -Commit $ExpectedCommit)) {
        return & $rejected "the expected main commit does not exist in the local repository at '$RepositoryRoot'. Run 'git fetch origin main' and retry."
    }
    if (-not (Test-SrePreflightAncestor `
                -RepositoryRoot $RepositoryRoot `
                -Ancestor $IndexedCommit `
                -Descendant $ExpectedCommit)) {
        return & $rejected 'the indexed commit is not an ancestor of, or equal to, the expected main commit.'
    }

    $paths = @($ApplicationCodePath | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
    $applicationCodeCommit = Get-SreApplicationCodeCommit `
        -RepositoryRoot $RepositoryRoot `
        -MainCommit $ExpectedCommit `
        -ApplicationCodePath $paths
    if (-not (Test-SrePreflightAncestor `
                -RepositoryRoot $RepositoryRoot `
                -Ancestor $applicationCodeCommit `
                -Descendant $IndexedCommit)) {
        return & $rejected "the indexed commit predates the latest application-code commit '$applicationCodeCommit' for paths '$($paths -join ', ')'."
    }

    return [PSCustomObject]@{
        Accepted = $true
        Reason = ''
        ApplicationCodeCommit = $applicationCodeCommit
    }
}

function Resolve-ExpectedRepositoryCommit {
    param(
        [AllowEmptyString()]
        [string] $ExpectedRepositoryCommit,
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $commit = $ExpectedRepositoryCommit
    if ([string]::IsNullOrWhiteSpace($commit)) {
        $commit = git -C $RepositoryRoot rev-parse --verify 'refs/remotes/origin/main^{commit}' 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commit)) {
            throw "ExpectedRepositoryCommit was not supplied and refs/remotes/origin/main could not be resolved. Fetch origin/main or pass the full commit SHA explicitly."
        }
    }
    $commit = ([string] $commit).Trim()
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'ExpectedRepositoryCommit must be one full 40-character hexadecimal Git commit SHA.'
    }
    return $commit.ToLowerInvariant()
}

function Get-SreRepositoryState {
    param(
        [Parameter(Mandatory)]
        [object] $Repository
    )

    $items = Get-SrePreflightItems `
        -Response $Repository `
        -WrapperNames @('value', 'item', 'repository', 'repo', 'data')
    if ($items.Count -ne 1) {
        throw "CodeRepo detail response must contain exactly one repository. Reported '$($items.Count)'."
    }
    $item = $items[0]
    $branchInfo = Get-SrePreflightPropertyInfo -InputObject $item -Names @('branch')
    return [PSCustomObject]@{
        Name = [string](Get-SrePreflightProperty -InputObject $item -Names @('name'))
        Url = [string](Get-SrePreflightProperty -InputObject $item -Names @('url'))
        Branch = $branchInfo.Value
        BranchPresent = $branchInfo.Found
        Type = [string](Get-SrePreflightProperty -InputObject $item -Names @('type'))
        CloneStatus = [string](Get-SrePreflightProperty -InputObject $item -Names @('cloneStatus'))
        Commit = [string](Get-SrePreflightProperty -InputObject $item -Names @(
                'latestCommit',
                'lastCommitHash',
                'commitId',
                'commitHash'
            ))
        LastSuccessfulSync = [string](Get-SrePreflightProperty `
                -InputObject $item `
                -Names @('lastSuccessfulSync'))
    }
}

function Assert-SreRepositorySource {
    param(
        [Parameter(Mandatory)]
        [object] $State,
        [Parameter(Mandatory)]
        [string] $RepositoryName,
        [Parameter(Mandatory)]
        [string] $RepositoryUrl,
        [Parameter(Mandatory)]
        [string] $RepositoryBranch
    )

    $branchIsBlank = $State.BranchPresent -ne $true -or
        $null -eq $State.Branch -or
        ($State.Branch -is [string] -and
         [string]::IsNullOrWhiteSpace([string] $State.Branch))
    $branchMatches = (
        -not $branchIsBlank -and
        $State.Branch -is [string] -and
        [string]::Equals(
            [string] $State.Branch,
            $RepositoryBranch,
            [StringComparison]::Ordinal
        )
    ) -or (
        $branchIsBlank -and
        [string]::Equals($RepositoryBranch, 'main', [StringComparison]::Ordinal)
    )
    if (-not [string]::Equals($State.Name, $RepositoryName, [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            $State.Url.TrimEnd('/'),
            $RepositoryUrl.TrimEnd('/'),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $branchMatches -or
        -not [string]::Equals($State.Type, 'GitHub', [StringComparison]::OrdinalIgnoreCase)) {
        throw "CodeRepo '$RepositoryName' does not match the required URL '$RepositoryUrl', branch '$RepositoryBranch', and type 'GitHub'. Refusing destructive replacement."
    }
}

function Get-SreRepositoryRefreshManualStep {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryName
    )

    return "Manual step: Azure SRE Agent portal > Builder > Knowledge base > Add repository > remove the stale '$RepositoryName' row, confirm, then add the same repository again; wait for Ready and rerun configure/verify."
}

function Wait-SreRepositoryReadyAtCommit {
    param(
        [AllowNull()]
        [object] $InitialRepository,
        [Parameter(Mandatory)]
        [scriptblock] $ReadRepository,
        [AllowNull()]
        [scriptblock] $CreateRepository,
        [AllowNull()]
        [scriptblock] $RequestSynchronization,
        [Parameter(Mandatory)]
        [string] $RepositoryName,
        [Parameter(Mandatory)]
        [string] $RepositoryUrl,
        [Parameter(Mandatory)]
        [string] $RepositoryBranch,
        [Parameter(Mandatory)]
        [string] $ExpectedCommit,
        [string] $RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
        [string[]] $ApplicationCodePath = (Get-SreDefaultApplicationCodePath),
        [switch] $RequireExactCommitMatch,
        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 600,
        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 10,
        [scriptblock] $Sleep = { param([int] $Seconds) Start-Sleep -Seconds $Seconds },
        [scriptblock] $GetUtcNow = { [DateTimeOffset]::UtcNow }
    )

    if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'ExpectedCommit must be one full 40-character hexadecimal Git commit SHA.'
    }

    $deadline = (& $GetUtcNow).AddSeconds($TimeoutSeconds)
    $repository = $InitialRepository
    $repositoryReadAfterStart = $false
    if ($null -eq $repository) {
        if ($null -eq $CreateRepository) {
            throw "CodeRepo '$RepositoryName' is missing."
        }
        & $CreateRepository
        if ((& $GetUtcNow) -ge $deadline) {
            throw "CodeRepo '$RepositoryName' creation exceeded the $TimeoutSeconds-second readiness timeout."
        }
        $repository = & $ReadRepository
        $repositoryReadAfterStart = $true
    }

    $syncRequested = $false
    $state = $null
    $lastRejectionReason = ''
    while ($true) {
        if ($repositoryReadAfterStart -and (& $GetUtcNow) -ge $deadline) {
            break
        }
        $state = Get-SreRepositoryState -Repository $repository
        Assert-SreRepositorySource `
            -State $state `
            -RepositoryName $RepositoryName `
            -RepositoryUrl $RepositoryUrl `
            -RepositoryBranch $RepositoryBranch

        if ($state.CloneStatus -in @('Failed', 'Error', 'Canceled', 'Cancelled')) {
            throw "CodeRepo '$RepositoryName' indexing failed with cloneStatus '$($state.CloneStatus)'."
        }
        if ($state.CloneStatus -eq 'Ready') {
            if ([string]::IsNullOrWhiteSpace($state.Commit)) {
                throw "CodeRepo '$RepositoryName' is Ready but did not expose latestCommit, lastCommitHash, commitId, or commitHash."
            }
            if ($state.Commit -notmatch '^[0-9a-fA-F]{40}$') {
                throw "CodeRepo '$RepositoryName' reported a non-full commit SHA '$($state.Commit)'."
            }
            $acceptance = Test-SreIndexedCommitAcceptance `
                -IndexedCommit $state.Commit `
                -ExpectedCommit $ExpectedCommit `
                -RepositoryRoot $RepositoryRoot `
                -ApplicationCodePath $ApplicationCodePath `
                -RequireExactMatch:$RequireExactCommitMatch
            if ($acceptance.Accepted) {
                return $state
            }
            $lastRejectionReason = [string] $acceptance.Reason
            if (-not $syncRequested) {
                if ($null -eq $RequestSynchronization) {
                    $manualStep = Get-SreRepositoryRefreshManualStep -RepositoryName $RepositoryName
                    throw "CodeRepo '$RepositoryName' is stale. $lastRejectionReason Last successful sync '$($state.LastSuccessfulSync)'. No supported repository synchronization endpoint is documented. $manualStep"
                }
                try {
                    & $RequestSynchronization
                } catch {
                    throw "CodeRepo '$RepositoryName' synchronization request failed: $($_.Exception.Message)"
                }
                $syncRequested = $true
            }
        }

        $now = & $GetUtcNow
        if ($now -ge $deadline) {
            break
        }
        $remainingSeconds = [Math]::Ceiling(($deadline - $now).TotalSeconds)
        $sleepSeconds = [Math]::Min($PollIntervalSeconds, [int] $remainingSeconds)
        & $Sleep $sleepSeconds
        $repository = & $ReadRepository
        $repositoryReadAfterStart = $true
    }

    $lastState = if ($null -ne $repository) {
        Get-SreRepositoryState -Repository $repository
    } else {
        [PSCustomObject]@{
            CloneStatus = ''
            Commit = ''
        }
    }
    $rejectionSuffix = if ([string]::IsNullOrWhiteSpace($lastRejectionReason)) {
        ''
    } else {
        " $lastRejectionReason"
    }
    throw "CodeRepo '$RepositoryName' did not reach Ready at an acceptable commit for expected main commit '$ExpectedCommit' within $TimeoutSeconds seconds. Last cloneStatus '$($lastState.CloneStatus)', commit '$($lastState.Commit)'.$rejectionSuffix"
}

function Get-SreGithubOAuthManualStep {
    return 'Manual step: Azure SRE Agent portal > Builder > Connectors > GitHub OAuth > reconnect/authorize permissions for issues, contents and pull requests. If the GitHub MCP connector supplies the write tools, confirm in Builder > Connectors that the MCP connector is present and that every required tool is enabled.'
}

function Get-SreToolDescriptors {
    param(
        [AllowNull()]
        [object] $ToolsResponse
    )

    $items = Get-SrePreflightItems `
        -Response $ToolsResponse `
        -WrapperNames @('value', 'values', 'items', 'tools', 'data')
    $descriptors = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        if ($null -eq $item) {
            continue
        }
        if ($item -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $descriptors.Add([PSCustomObject]@{
                        Name = ([string] $item).Trim()
                        EnabledPresent = $false
                        Enabled = $true
                    })
            }
            continue
        }
        $nestedTools = Get-SrePreflightValue -InputObject $item -Name 'tools'
        if ($null -ne $nestedTools -and -not [object]::ReferenceEquals($nestedTools, $item)) {
            foreach ($nested in @(Get-SreToolDescriptors -ToolsResponse $nestedTools)) {
                $descriptors.Add($nested)
            }
        }
        $name = Get-SrePreflightProperty -InputObject $item -Names @('name', 'toolName')
        if ([string]::IsNullOrWhiteSpace([string] $name)) {
            continue
        }
        $enabledInfo = Get-SrePreflightPropertyInfo -InputObject $item -Names @('enabled')
        $enabled = if ($enabledInfo.Found) {
            Get-SrePreflightBoolean -Value $enabledInfo.Value
        } else {
            $true
        }
        $descriptors.Add([PSCustomObject]@{
                Name = ([string] $name).Trim()
                EnabledPresent = [bool] $enabledInfo.Found
                Enabled = [bool] $enabled
            })
    }
    return @($descriptors)
}

function Get-SreToolNames {
    param(
        [AllowNull()]
        [object] $ToolsResponse
    )

    return @(
        Get-SreToolDescriptors -ToolsResponse $ToolsResponse |
            ForEach-Object { $_.Name } |
            Select-Object -Unique
    )
}

function Get-SreRequiredGithubWriteCapability {
    return [ordered]@{
        issueCreate = @('github_issue_write', 'issue_write', 'CreateGithubIssue')
        issueUpdate = @('github_issue_write', 'issue_write', 'UpdateGithubIssue')
        branchCreate = @('github_create_branch', 'create_branch', 'CreateGithubBranch')
        contentsWrite = @(
            'github_push_files',
            'github_create_or_update_file',
            'push_files',
            'PushGithubFiles'
        )
        pullRequestCreate = @(
            'github_create_pull_request',
            'create_pull_request',
            'CreateGithubPullRequest'
        )
    }
}

function Assert-SreGithubWriteReadiness {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object] $DomainsResponse,
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object] $ToolsResponse
    )

    $domains = Get-SrePreflightItems `
        -Response $DomainsResponse `
        -WrapperNames @('value', 'values', 'domains', 'items', 'data')
    $githubDomain = $domains | Where-Object {
        $domainName = [string](Get-SrePreflightProperty -InputObject $_ -Names @(
                'name',
                'domain',
                'host'
            ))
        $domainName -in @('github.com', 'github_com')
    } | Select-Object -First 1
    $domainStatus = [string](Get-SrePreflightProperty -InputObject $githubDomain -Names @(
            'connectionStatus',
            'status'
        ))
    $domainHealthy = Get-SrePreflightProperty -InputObject $githubDomain -Names @('isHealthy')
    $healthyStatus = $domainStatus -in @(
        'Connected',
        'Ready',
        'Authenticated',
        'Succeeded',
        'Healthy'
    )
    $domainReady = $null -ne $githubDomain -and
        (($domainHealthy -eq $true -and [string]::IsNullOrWhiteSpace($domainStatus)) -or
         ($null -eq $domainHealthy -and $healthyStatus) -or
         ($domainHealthy -eq $true -and $healthyStatus))
    if (-not $domainReady) {
        $manualStep = Get-SreGithubOAuthManualStep
        throw "INCOMPLETE: GitHub OAuth domain 'github.com' is not healthy. Reported '$domainStatus'. $manualStep"
    }

    $toolDescriptors = @(Get-SreToolDescriptors -ToolsResponse $ToolsResponse)
    if ($toolDescriptors.Count -eq 0) {
        $manualStep = Get-SreGithubOAuthManualStep
        throw "INCOMPLETE: The agent tool catalog response was not recognized as either the current '{ data: [ { name, enabled } ] }' descriptor payload or a legacy flat array of tool names, so no tool could be read. Failing closed. $manualStep"
    }
    $enabledToolNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $disabledToolNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($descriptor in $toolDescriptors) {
        if ($descriptor.Enabled) {
            [void] $enabledToolNames.Add([string] $descriptor.Name)
        } else {
            [void] $disabledToolNames.Add([string] $descriptor.Name)
        }
    }

    $requiredCapabilities = Get-SreRequiredGithubWriteCapability
    $selectedTools = [System.Collections.Generic.List[string]]::new()
    $missingCapabilities = [System.Collections.Generic.List[string]]::new()
    foreach ($capability in $requiredCapabilities.GetEnumerator()) {
        $matchingTool = $capability.Value |
            Where-Object { $enabledToolNames.Contains([string] $_) } |
            Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace([string] $matchingTool)) {
            $selectedTools.Add([string] $matchingTool)
            continue
        }
        $disabledTool = $capability.Value |
            Where-Object { $disabledToolNames.Contains([string] $_) } |
            Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace([string] $disabledTool)) {
            $missingCapabilities.Add(
                "$($capability.Key) (present but disabled: '$disabledTool')"
            )
        } else {
            $missingCapabilities.Add(
                "$($capability.Key) (accepted: $($capability.Value -join ' | '))"
            )
        }
    }
    if ($missingCapabilities.Count -gt 0) {
        $manualStep = Get-SreGithubOAuthManualStep
        throw "INCOMPLETE: GitHub OAuth is healthy but exact write capabilities are missing: $($missingCapabilities -join '; '). Tool names are matched exactly and case-sensitively, and a disabled tool never counts. Read-only tools do not satisfy this preflight. $manualStep"
    }

    return @($selectedTools | Select-Object -Unique)
}

function Invoke-SreGithubRepositoryPreflight {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object] $DomainsResponse,
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object] $ToolsResponse,
        [AllowNull()]
        [object] $InitialRepository,
        [Parameter(Mandatory)]
        [scriptblock] $ReadRepository,
        [AllowNull()]
        [scriptblock] $CreateRepository,
        [AllowNull()]
        [scriptblock] $RequestSynchronization,
        [Parameter(Mandatory)]
        [string] $RepositoryName,
        [Parameter(Mandatory)]
        [string] $RepositoryUrl,
        [Parameter(Mandatory)]
        [string] $RepositoryBranch,
        [Parameter(Mandatory)]
        [string] $ExpectedCommit,
        [string] $RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
        [string[]] $ApplicationCodePath = (Get-SreDefaultApplicationCodePath),
        [switch] $RequireExactCommitMatch,
        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 600,
        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 10,
        [scriptblock] $Sleep = { param([int] $Seconds) Start-Sleep -Seconds $Seconds },
        [scriptblock] $GetUtcNow = { [DateTimeOffset]::UtcNow }
    )

    $selectedTools = @(
        Assert-SreGithubWriteReadiness `
            -DomainsResponse $DomainsResponse `
            -ToolsResponse $ToolsResponse
    )
    $repositoryState = Wait-SreRepositoryReadyAtCommit `
        -InitialRepository $InitialRepository `
        -ReadRepository $ReadRepository `
        -CreateRepository $CreateRepository `
        -RequestSynchronization $RequestSynchronization `
        -RepositoryName $RepositoryName `
        -RepositoryUrl $RepositoryUrl `
        -RepositoryBranch $RepositoryBranch `
        -ExpectedCommit $ExpectedCommit `
        -RepositoryRoot $RepositoryRoot `
        -ApplicationCodePath $ApplicationCodePath `
        -RequireExactCommitMatch:$RequireExactCommitMatch `
        -TimeoutSeconds $TimeoutSeconds `
        -PollIntervalSeconds $PollIntervalSeconds `
        -Sleep $Sleep `
        -GetUtcNow $GetUtcNow

    return [PSCustomObject]@{
        SelectedTools = $selectedTools
        Repository = $repositoryState
    }
}
