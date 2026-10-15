# apim-metrics

Gateway-side health for a **Standard v2** APIM instance fronting the PTU deployments, plus an optional PTU usage section pulled directly from the Foundry/Azure OpenAI resource. Standalone from the PTU workbook tooling in the repo root; uses only Azure Monitor platform metrics. Other tiers are not a target: the classic `Capacity` metric (Premium only) is intentionally not used.

## Contents

| File | Purpose |
|---|---|
| `apim-validation.workbook.json` | The workbook definition (single source of truth). Paste into the portal Advanced Editor or deploy with the Bicep file. |
| `apim-workbook.bicep` | Deploys the workbook as a shared `Microsoft.Insights/workbooks` resource, optionally preselecting an APIM instance and/or a Foundry/Azure OpenAI resource. |
| `Get-ApimMetrics.ps1` | Read-only CSV export (Peak/P99/P95/Avg) of APIM Gateway CPU and memory, Requests by gateway/backend response code/error reason, gateway Duration, BackendDuration, and Network Connectivity. Requires Monitoring Reader. |
| `CUSTOMER-GUIDE.md` | Short, non-technical deploy + how-to-read guide to hand to the customer. |
| `subscription-usage/` | Optional add-on: per-APIM-subscription health (429s, errors, latency) and token usage, since no platform metric supports a Subscription ID dimension. See its own README. |

## Workbook layout

Parameters: **APIM instance** (required, Resource Graph picker), **Foundry / Azure OpenAI resource** (optional - unlocks the PTU usage section), and **Time range** (1h, 4h, 12h, 24h, 3d, custom). Every chart uses 1-minute grain.

| Section | Chart | Aggregation | Split by | Resource |
|---|---|---|---|---|
| PTU usage *(shown only if the optional resource is set)* | Utilization V2 | Max | `ModelDeploymentName` | Foundry/Azure OpenAI |
| PTU usage | Active Tokens | Sum | `ModelDeploymentName` | Foundry/Azure OpenAI |
| PTU usage | Requests | Sum | `StatusCode` | Foundry/Azure OpenAI |
| PTU usage | Time to Response | Max | `ModelDeploymentName` | Foundry/Azure OpenAI |
| PTU usage | Tokens Per Second | Avg | `ModelDeploymentName` | Foundry/Azure OpenAI |
| Capacity | Gateway CPU % | Max | none | APIM |
| Capacity | Gateway memory % | Max | none | APIM |
| Traffic | Requests | Sum | `ApiId` | APIM |
| Reliability | Requests | Sum | `GatewayResponseCodeCategory` | APIM |
| Reliability | Requests | Sum | `BackendResponseCodeCategory` | APIM |
| Reliability | Requests | Sum | `LastErrorReason` | APIM |
| Connectivity | Network Connectivity | Sum | `ResourceType` | APIM |
| Latency | Duration | Max | `ApiId` | APIM |
| Latency | Backend Duration | Max | `ApiId` | APIM |

Drag across any chart to zoom every chart to that window; re-select the time range to reset. Each chart has an **Open in Metrics** button.

## Usage

### Option A - portal, nothing deployed

1. Azure portal > **Monitor** > **Workbooks** > **+ New**.
2. Toolbar **Advanced Editor** (`</>`), keep **Gallery Template**, replace the content with `apim-validation.workbook.json`, click **Apply**, then **Done Editing**.
3. Pick the APIM instance and time range; optionally pick the Foundry/Azure OpenAI resource to unlock the PTU usage section. Close without saving for a throwaway view, or **Save** to keep it.

### Option B - deploy with Bicep

```powershell
az login
$apimId = az apim show -n <apim> -g <rg> --query id -o tsv
$aoaiId = az cognitiveservices account show -n <foundry-or-openai-resource> -g <rg> --query id -o tsv

# Creates one Microsoft.Insights/workbooks resource in <rg>; both IDs are optional
az deployment group create -g <rg> --template-file apim-workbook.bicep --parameters apimResourceId=$apimId aoaiResourceId=$aoaiId
```

### Metrics export (read-only; requires Monitoring Reader)

```powershell
az login
$apimId = az apim show -n <apim> -g <rg> --query id -o tsv
.\Get-ApimMetrics.ps1 -ApimResourceId $apimId -Days 7
```

Output goes to `./apim-metrics-output` (`per-minute.csv`, `summary.csv`). Request-type metrics count minutes with no data as 0 in P99/P95/Avg; see the root README. Needs `../common/MetricsExport.psm1`. Do not commit production exports.

## Reading the results

- **Utilization V2** (PTU usage section) sustained at/near 100%: the PTU pool itself is exhausted - this is the metric APIM alone cannot show.
- **Time to Response** climbing while **Utilization V2** is still below 100%: the PTU is slowing down under load before it's technically exhausted - an early warning sign, not just a hard-cap alarm.
- **Tokens Per Second** dropping: generation throughput is degrading - correlate with Time to Response and Utilization V2 to see if it's contention-related.
- **Gateway CPU % / memory %** sustained high: APIM itself needs scaling.
- **Requests** with backend 429 or 5xx: the PTU/OpenAI side is throttling or failing. Correlate with Utilization V2 above (or the PTU workbook) to confirm it's PTU exhaustion and not something else.
- **Duration** well above **BackendDuration**: APIM policy overhead.

### Is it APIM throttling, or is it the PTU?

Compare the two Reliability charts rather than reading either in isolation:

- `GatewayResponseCodeCategory` shows 4xx (commonly a 429/403) **and** `BackendResponseCodeCategory` stays clean -> APIM itself rejected the call before it ever reached the backend (a `rate-limit-by-key` or `quota-by-key` policy, an invalid/expired subscription key, IP restriction, etc.). This is an APIM configuration/sizing issue, not PTU exhaustion.
- `BackendResponseCodeCategory` shows 429/5xx -> the PTU backend itself returned the error. This is PTU exhaustion/throttling or a backend outage - cross-check Utilization V2 (PTU usage section) to confirm.
- `LastErrorReason` adds the "why": values like `SubscriptionKeyInvalid` or a rate-limit/quota reason point at APIM-side rejection (confirmed live - see Testing below), while a backend-connection/timeout reason points at the PTU/backend. Exact string values aren't officially enumerated by Microsoft, so treat `LastErrorReason` as a drill-down next to the two response-code-category charts, not a standalone source of truth.

This workbook assumes each PTU has its own API/backend in APIM (one subscription's Product maps to exactly one API/PTU), so the `ApiId` split in Traffic/Latency is a direct per-PTU proxy. If that ever changes to one shared API with policy-based/dynamic backend selection, or to load-balanced backend pools across PTUs, `ApiId` stops distinguishing them and there's no other platform-metric dimension (`SubscriptionId`, `ProductId`, pool-member identity) to fall back on - that's a known gap, not something this workbook can expose without Application Insights (`emit-metric` policy) or diagnostic settings. See `subscription-usage/` for exactly that workaround.

## Limitations

- No platform metric exists for traffic per APIM subscription or per load-balanced backend pool member - only `ApiId` (works here because it's one API per PTU). See `subscription-usage/` for a per-subscription breakdown using an Application Insights policy instead.
- Standard v2 only: gateway load is read from `CpuPercent_Gateway` / `MemoryPercent_Gateway` (no dimensions). The classic `Capacity` metric (Premium) is not charted or exported.
- The PTU usage section only appears when the optional Foundry/Azure OpenAI resource parameter is set; `Get-ApimMetrics.ps1` is APIM-only and does not export it (use `Get-PtuMetrics.ps1` in the repo root for that).

## Testing performed

Validated end-to-end against a live, temporary Consumption-tier APIM instance (API -> httpbin.org backend, real traffic generated, then torn down):

- Every metric/dimension combination used by the workbook (`Requests` split by `ApiId`/`GatewayResponseCodeCategory`/`BackendResponseCodeCategory`/`LastErrorReason`, `Duration`/`BackendDuration` split by `ApiId`, `NetworkConnectivity` split by `ResourceType`, `CpuPercent_Gateway`, `MemoryPercent_Gateway`) resolved successfully against the real Azure Monitor API - no invalid-metric or invalid-dimension errors.
- A mix of backend 200/429/500 responses plus gateway-rejected calls (bad subscription key) confirmed the gateway-vs-backend diagnosis above: gateway-rejected calls showed up as `BackendResponseCodeCategory=None` (never reached the backend) and `LastErrorReason=SubscriptionKeyInvalid`, while simulated backend 429/500s showed up under `BackendResponseCodeCategory` with no `LastErrorReason` set.
- `CpuPercent_Gateway`, `MemoryPercent_Gateway`, and `NetworkConnectivity` all returned empty time series on the Consumption-tier test instance, which does not report them (they are v2-tier metrics).
- `AzureOpenAITimeToResponse` and `AzureOpenAITokenPerSecond` (category `Azure OpenAI - Latency`) were confirmed against a live Cognitive Services/Azure OpenAI test resource - both metric names resolve, `ModelDeploymentName` is a valid split dimension for each, and units are `MilliSeconds`/`Count` respectively as expected. Series were empty (no active inference traffic on the test resource at query time), same caveat as the other PTU usage charts below.
- The Bicep deployment was run against the live instance and confirmed to correctly preselect the APIM resource ID in the deployed workbook.
- Not yet checked on a Standard v2 instance with data (`CpuPercent_Gateway` / `MemoryPercent_Gateway` were never populated in testing), nor against a real PTU backend under load. The PTU usage section's metric names were verified against both Microsoft Learn's reference docs and a live (but idle) Azure OpenAI resource.
