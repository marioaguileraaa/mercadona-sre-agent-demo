# Runbook: synthetic cart memory pressure

> **Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.**

## Scope and safety

This runbook applies only to `ca-mercadona-retail-api` in subscription `5305e853-a63b-4b82-9a3f-6fde18c1a798` and resource group `rg-mercadona-sre-agent-v1`. Never reuse these commands against another context. The scenario is off by default, bounded at 640 MiB, and isolated to the backend process.

**Emergency recovery:**

```powershell
.\scripts\recover-incident.ps1
```

## Expected signal

- Alert: `alert-mercadona-cart-memory`, Sev2.
- Metric: `Microsoft.App/containerApps` / `WorkingSetBytes`.
- Aggregation: `Maximum`.
- Threshold: greater than `629145600` bytes.
- Window/frequency: `PT5M` / `PT1M`.
- Backend replicas: minimum 1, maximum 1.
- Triggering workload: 64 valid sequential adds at exactly 10 MiB per add.
- Process cap: 640 MiB retained bytes.

The 600 MiB threshold gives the alert a 40 MiB margin before the retention cap. Before each demo, record a healthy baseline with retention disabled. Do not proceed if the baseline approaches the threshold.

## Start and observe

```powershell
az account set --subscription 5305e853-a63b-4b82-9a3f-6fde18c1a798
.\scripts\start-incident.ps1
```

The script checks the pre-created resource group, enables `DEMO_CART_MEMORY_MB_PER_ADD=10`, waits for a **new** healthy revision, creates one cart, performs exactly 64 successful adds within five minutes, and polls the platform metric until it exceeds 600 MiB. It has bounded request and metric deadlines.

Expected API behavior remains healthy. Each response includes a synthetic correlation ID. Invalid carts/products and invalid quantities never allocate.

## Investigate

Find the active revision:

```powershell
az containerapp revision list `
  --subscription 5305e853-a63b-4b82-9a3f-6fde18c1a798 `
  --resource-group rg-mercadona-sre-agent-v1 `
  --name ca-mercadona-retail-api `
  --query "[?properties.active].{Name:name,Health:properties.healthState,Running:properties.runningState,Created:properties.createdTime}" `
  --output table
```

Inspect retained-byte events:

```kusto
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == "ca-mercadona-retail-api"
| where Log_s has "DEMO_CART_MEMORY_RETENTION"
| project TimeGenerated, RevisionName_s, Log_s
| order by TimeGenerated desc
```

Correlate one operation:

```kusto
let correlation = "CORR-REPLACE-WITH-SYNTHETIC-ID";
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == "ca-mercadona-retail-api"
| where Log_s has correlation
| project TimeGenerated, RevisionName_s, Log_s
```

Measure event progression by revision:

```kusto
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == "ca-mercadona-retail-api"
| where Log_s has "RetainedBytes"
| summarize RetentionEvents=count() by RevisionName_s, bin(TimeGenerated, 1m)
| order by TimeGenerated desc
```

Query the metric:

```powershell
$resourceId = "/subscriptions/5305e853-a63b-4b82-9a3f-6fde18c1a798/resourceGroups/rg-mercadona-sre-agent-v1/providers/Microsoft.App/containerApps/ca-mercadona-retail-api"
az monitor metrics list `
  --resource $resourceId `
  --metric WorkingSetBytes `
  --aggregation Maximum `
  --interval PT1M `
  --output table
```

Evidence should converge on:

1. Valid add responses remain HTTP 200.
2. Logs report 10,485,760 allocated bytes until the cap.
3. `RetainedBytes` rises monotonically in one active revision.
4. Source shows a singleton strong-root collection with no eviction.
5. `WorkingSetBytes` rises past the threshold.

## SRE Agent approval boundary

The SRE Agent and `mercadona-cart-memory-sev2` filter are `Review`. `code-analyzer` can use read tools and connected source to investigate. It may propose only:

```text
DEMO_CART_MEMORY_MB_PER_ADD=0
```

The proposal must create a fresh backend revision and must not alter replica limits, threshold, cap, identities, or source. A human must explicitly approve any write.

## GitHub bridge fallback

Normal path: Azure Monitor alert -> Azure SRE Agent AzMonitor incident filter. The referenced action group intentionally has zero receivers and does not notify the agent.

If alert ingestion is too slow for a live demo, run **SRE Agent controlled investigation** manually with an identifier beginning `SYNTH-`, or label an `[SYNTHETIC]` issue with exactly `sre-investigate`. The workflow sends jq-generated JSON to the signed Logic App callback and accepts only `202`, `success=true`, and nonempty `threadId`.

The bridge forwards the original body to the protected trigger with managed identity. Do not add Azure login, OIDC, a bearer header, extra secrets, redirects, retries, callback outputs, or a public trigger.

## Recover and verify

```powershell
.\scripts\recover-incident.ps1
```

Expected outcome:

- a new healthy revision;
- `DEMO_CART_MEMORY_MB_PER_ADD=0`;
- valid cart/add/order/tracking;
- `AllocationBytes=0`;
- a below-threshold metric sample, or an explicit safe warning if ingestion has not produced one yet.

If the script cannot obtain a metric sample but the fresh revision and healthy flow pass, leave the incident disabled and continue monitoring. Never re-enable it while troubleshooting.

## Costs, cleanup, and reset

Charges can accrue for Container Apps, ACR, Log Analytics, Application Insights, Azure Monitor, Logic Apps, and Azure SRE Agent units. Keep the run short.

Reset checklist:

1. Run recovery.
2. Confirm one active healthy backend revision.
3. Confirm the memory-per-add variable is zero.
4. Confirm the metric returns below 600 MiB and the alert resolves.
5. Close synthetic issues and agent threads.
6. Remove `SRE_TRIGGER_URL` before retirement.
7. Delete only dedicated demo resources after owner approval.

## Troubleshooting

| Problem | Safe response |
|---|---|
| Context guard fails | Stop; sign into the exact subscription and verify the pre-created resource group |
| New revision is unhealthy | Keep the previous revision, inspect revision events/logs, do not generate load |
| Adds fail | Stop the run; the scenario requires normal responses |
| Cap is reached below metric threshold | Recover, validate baseline and platform metric ingestion before another run |
| Alert is delayed | Use the manual `SYNTH-` workflow fallback, then recover |
| Agent proposes another mutation | Reject it; only the zero-value environment change is allowed |
| Bridge returns 502 | Inspect downstream agent availability and exact-scope role; do not expose trigger URLs |
