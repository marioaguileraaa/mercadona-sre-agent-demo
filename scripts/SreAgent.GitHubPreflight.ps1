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
    return [PSCustomObject]@{
        Name = [string](Get-SrePreflightProperty -InputObject $item -Names @('name'))
        Url = [string](Get-SrePreflightProperty -InputObject $item -Names @('url'))
        Branch = [string](Get-SrePreflightProperty -InputObject $item -Names @('branch'))
        Type = [string](Get-SrePreflightProperty -InputObject $item -Names @('type'))
        CloneStatus = [string](Get-SrePreflightProperty -InputObject $item -Names @('cloneStatus'))
        Commit = [string](Get-SrePreflightProperty -InputObject $item -Names @(
                'lastCommitHash',
                'commitId',
                'commitHash'
            ))
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

    if (-not [string]::Equals($State.Name, $RepositoryName, [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            $State.Url.TrimEnd('/'),
            $RepositoryUrl.TrimEnd('/'),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals($State.Branch, $RepositoryBranch, [StringComparison]::Ordinal) -or
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
                throw "CodeRepo '$RepositoryName' is Ready but did not expose lastCommitHash, commitId, or commitHash."
            }
            if ($state.Commit -notmatch '^[0-9a-fA-F]{40}$') {
                throw "CodeRepo '$RepositoryName' reported a non-full commit SHA '$($state.Commit)'."
            }
            if ([string]::Equals($state.Commit, $ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) {
                return $state
            }
            if (-not $syncRequested) {
                if ($null -eq $RequestSynchronization) {
                    $manualStep = Get-SreRepositoryRefreshManualStep -RepositoryName $RepositoryName
                    throw "CodeRepo '$RepositoryName' is stale. Expected full commit '$ExpectedCommit', reported '$($state.Commit)'. No supported repository synchronization endpoint is documented. $manualStep"
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
    throw "CodeRepo '$RepositoryName' did not reach Ready at exact commit '$ExpectedCommit' within $TimeoutSeconds seconds. Last cloneStatus '$($lastState.CloneStatus)', commit '$($lastState.Commit)'."
}

function Get-SreGithubOAuthManualStep {
    return 'Manual step: Azure SRE Agent portal > Builder > Connectors > GitHub OAuth > reconnect/authorize permissions for issues, contents and pull requests.'
}

function Get-SreToolNames {
    param(
        [AllowNull()]
        [object] $ToolsResponse
    )

    $items = Get-SrePreflightItems `
        -Response $ToolsResponse `
        -WrapperNames @('value', 'values', 'items', 'tools', 'data')
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) {
        $nestedTools = Get-SrePreflightValue -InputObject $item -Name 'tools'
        if ($null -ne $nestedTools -and $nestedTools -ne $item) {
            foreach ($nestedName in Get-SreToolNames -ToolsResponse $nestedTools) {
                $names.Add($nestedName)
            }
        }
        $name = Get-SrePreflightProperty -InputObject $item -Names @('name', 'toolName')
        if (-not [string]::IsNullOrWhiteSpace([string] $name)) {
            $names.Add([string] $name)
        }
    }
    return @($names | Select-Object -Unique)
}

function Assert-SreGithubWriteReadiness {
    param(
        [Parameter(Mandatory)]
        [object] $DomainsResponse,
        [Parameter(Mandatory)]
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

    $toolNames = @(Get-SreToolNames -ToolsResponse $ToolsResponse)
    $requiredCapabilities = [ordered]@{
        issueCreate = @('issue_write', 'CreateGithubIssue')
        issueUpdate = @('issue_write', 'UpdateGithubIssue')
        branchCreate = @('create_branch', 'CreateGithubBranch')
        contentsWrite = @('push_files', 'PushGithubFiles')
        pullRequestCreate = @('create_pull_request', 'CreateGithubPullRequest')
    }
    $selectedTools = [System.Collections.Generic.List[string]]::new()
    $missingCapabilities = [System.Collections.Generic.List[string]]::new()
    foreach ($capability in $requiredCapabilities.GetEnumerator()) {
        $matchingTool = $capability.Value | Where-Object { $toolNames -ccontains $_ } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace([string] $matchingTool)) {
            $missingCapabilities.Add($capability.Key)
        } else {
            $selectedTools.Add([string] $matchingTool)
        }
    }
    if ($missingCapabilities.Count -gt 0) {
        $manualStep = Get-SreGithubOAuthManualStep
        throw "INCOMPLETE: GitHub OAuth is healthy but exact write capabilities are missing: $($missingCapabilities -join ', '). Read-only tools do not satisfy this preflight. $manualStep"
    }

    return @($selectedTools | Select-Object -Unique)
}

function Invoke-SreGithubRepositoryPreflight {
    param(
        [Parameter(Mandatory)]
        [object] $DomainsResponse,
        [Parameter(Mandatory)]
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
        -TimeoutSeconds $TimeoutSeconds `
        -PollIntervalSeconds $PollIntervalSeconds `
        -Sleep $Sleep `
        -GetUtcNow $GetUtcNow

    return [PSCustomObject]@{
        SelectedTools = $selectedTools
        Repository = $repositoryState
    }
}
