#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repository = 'marioaguileraaa/mercadona-sre-agent-demo'
)

$title = '[SYNTHETIC] Mercadona cart memory working set exceeds 600 MiB'
$body = @'
## Synthetic incident

The fictional Mercadona-style retail demo shows rising `WorkingSetBytes` after valid cart additions while normal API responses continue. Structured logs use `DEMO_CART_MEMORY_RETENTION`.

## Safety

- Synthetic data only
- No real customer, financial, personal or operational data
- Review-mode investigation; mitigation requires approval
'@

if ($PSCmdlet.ShouldProcess($Repository, 'Create controlled synthetic incident issue')) {
    gh label create sre-investigate `
        --repo $Repository `
        --description 'Allow the SRE Agent to investigate a synthetic demo issue' `
        --color 0E8A16 `
        --force
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to ensure the sre-investigate label exists.'
    }

    gh issue create `
        --repo $Repository `
        --title $title `
        --body $body `
        --label sre-investigate
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to create the sample synthetic incident issue.'
    }
}
