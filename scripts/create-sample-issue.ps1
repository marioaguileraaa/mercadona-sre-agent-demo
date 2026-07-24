#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repository = 'marioaguileraaa/mercadona-sre-agent-demo'
)

$title = '[SYNTHETIC] Retail cart API returns controlled memory-capacity 503 responses'
$body = @'
## Synthetic incident

Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.

The fictional retail demo shows six HTTP 503 responses after valid cart additions reach the controlled 600 MiB threshold. Structured logs use `DEMO_CART_MEMORY_RETENTION` and `DEMO_CART_MEMORY_CAPACITY_EXHAUSTED`; the platform signal is `Requests` filtered to `statusCodeCategory=5xx`.

## Safety

- Synthetic data only
- No real customer, financial, personal or operational data
- Review-mode investigation; mitigation requires approval
- No automatic merge or deployment
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
