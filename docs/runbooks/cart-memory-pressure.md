# Runbook: synthetic cart memory capacity incident

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

## Scope and emergency recovery

This runbook applies only to `ca-mercadona-retail-api` in subscription `5305e853-a63b-4b82-9a3f-6fde18c1a798` and resource group `rg-mercadona-sre-agent-v1`. The scenario is off by default, bounded at 640 MiB and limited to one backend replica.

```powershell
.\scripts\recover-incident.ps1
```

Recovery is idempotent. It sets `DEMO_CART_MEMORY_MB_PER_ADD=0`, `DEMO_CART_MEMORY_FAILURE_MB=0` and `DEMO_CART_MEMORY_MAX_MB=640`, then verifies cart, add, order and tracking. It never terminates local processes.

## Expected signal

| Property | Contract |
|---|---|
| Alert | `alert-mercadona-cart-5xx-sev3`, Sev3 |
| Metric | `Microsoft.App/containerApps` / `Requests` |
| Filter | `statusCodeCategory Include 5xx` |
| Aggregation / threshold | `Total > 5` |
| Window / frequency | `PT5M` / `PT1M` |
| Scope | exact backend resource ID |
| Workload | at most 80 sequential adds and five minutes |
| Stop condition | six confirmed HTTP 5xx |
| Memory | 10 MiB/add, controlled failure at 600 MiB, hard cap 640 MiB |

The service touches each page and keeps a process-lifetime strong root only after validating cart, product and quantity. The first 60 adds can retain 600 MiB. Later valid adds return HTTP 503 with `DEMO_CART_MEMORY_CAPACITY_EXHAUSTED`, no extra allocation and no cart mutation. With the failure threshold disabled, the 640 MiB cap still preserves successful responses.

## Preflight and start

```powershell
az account set --subscription 5305e853-a63b-4b82-9a3f-6fde18c1a798
.\scripts\verify-sre-agent.ps1
.\scripts\start-incident.ps1
```

The start script refuses to mutate unless:

- the exact Azure context and one healthy active revision are present;
- per-add and failure variables are both zero, and the cap is 640;
- the healthy add returns HTTP 200 with no allocation;
- no recent 5xx or already-Fired matching alert exists;
- the agent is Review/Low, the GitHub connector domain is authenticated, CodeRepo is Ready, GitHub exposes issue/branch/commit/PR tools, and the response plan is exact.

The finite injector preserves `X-Correlation-ID`, counts only actual HTTP 5xx, and stops at six 5xx, 80 requests or five minutes. Transport failures are not counted. It then verifies the platform metric, exact Fired alert, and a new agent thread. If the preview thread API does not expose response-plan metadata, it reports the one manual portal check rather than claiming an association.

`start-incident.ps1` never runs recovery.

## Investigation evidence

Retained memory and controlled failures:

```kusto
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == "ca-mercadona-retail-api"
| where Log_s has_any ("DEMO_CART_MEMORY_RETENTION", "DEMO_CART_MEMORY_CAPACITY_EXHAUSTED")
| project TimeGenerated, RevisionName_s, Log_s
| order by TimeGenerated desc
```

One synthetic correlation:

```kusto
let correlation = "SYNTH-CART5XX-REPLACE";
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == "ca-mercadona-retail-api"
| where Log_s has correlation
| project TimeGenerated, RevisionName_s, Log_s
```

Application Insights requests:

```kusto
requests
| where cloud_RoleName == "ca-mercadona-retail-api" or name contains "/api/carts/"
| where resultCode startswith "5"
| project timestamp, name, resultCode, operation_Id, success
| order by timestamp desc
```

Platform signal:

```powershell
$resourceId = "/subscriptions/5305e853-a63b-4b82-9a3f-6fde18c1a798/resourceGroups/rg-mercadona-sre-agent-v1/providers/Microsoft.App/containerApps/ca-mercadona-retail-api"
az monitor metrics list `
  --resource $resourceId `
  --metric Requests `
  --aggregation Total `
  --filter "statusCodeCategory eq '5xx'" `
  --interval PT1M
```

Evidence should converge on the same revision and correlation IDs, 10,485,760-byte allocations up to 600 MiB, then 503 responses with zero allocation. Source evidence is the singleton strong-root collection in `CartMemoryRetentionService`.

## SRE Agent approval and GitHub boundary

`incident-handler` and `mercadona-cart-5xx-sev3` stay in Review. The response plan is constrained by exact alert ID, title, Sev3 and backend resource. Known quickstart plans are removed; Arc filters are not modified.

The only immediate mitigation is:

```text
Create a clean revision with:
DEMO_CART_MEMORY_MB_PER_ADD=0
DEMO_CART_MEMORY_FAILURE_MB=0
DEMO_CART_MEMORY_MAX_MB=640
```

A human must approve before the Azure write. After approval and healthy-flow verification, the agent can create a synthetic issue, branch, commit and pull request through the authenticated GitHub connector tools. It must not merge, dispatch workflows, deploy the PR or close the issue automatically. Global tool policy asks before writes and denies merge/workflow/deploy tools.

If GitHub OAuth or a required capability is missing, configuration and verification stop with `INCOMPLETE`. Complete only **Azure SRE Agent portal > Builder > Connectors > GitHub OAuth > Sign in**, enable issue/contents/pull-request writes, and rerun. Never paste tokens into source or output.

## GitHub bridge fallback

Normal routing is Azure Monitor -> exact response plan -> `incident-handler`. The secure Logic App fallback remains available for a title beginning `[SYNTHETIC]` plus label `sre-investigate`, or a manual ID beginning `SYNTH-`. It uses only `SRE_TRIGGER_URL`, managed identity to the protected trigger and HTTP 202 verification. It does not bypass Review.

## Recovery and reset

```powershell
.\scripts\recover-incident.ps1
```

Expected outcome:

1. one healthy active revision;
2. both injection/failure variables at zero;
3. cart/add/order/tracking succeeds;
4. `AllocationBytes=0`;
5. no new 5xx;
6. the exact alert resolves, or the script emits a latency warning.

Do not inject another incident while the exact alert remains Fired.

## Troubleshooting

| Problem | Safe response |
|---|---|
| Context or baseline guard fails | Stop; correct the exact subscription/resource group or recover |
| Revision is unhealthy | Do not generate load; inspect revision events and logs |
| Fewer than six 5xx | Recover; verify threshold variables and do not increase limits |
| Metric or alert is delayed | Keep the finite run stopped; do not launch a second injector |
| Thread is missing | Verify the exact response plan and wait; recover before retrying |
| OAuth/capability is incomplete | Perform the single portal OAuth/capability step and rerun configuration |
| Agent proposes another mutation | Reject it; only the clean revision with variables at zero is allowed |
| Agent proposes merge/deploy | Reject it and inspect global tool policy |
