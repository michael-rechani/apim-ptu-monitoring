# Per-Subscription Metrics for APIM

Platform metrics can't be split by APIM subscription. Use the two exports below.

| I want to see | Use | Setup |
|---|---|---|
| 429s, errors, latency per subscription | [Part 1](#part-1---429s-errors-latency-per-subscription) | Diagnostic setting (portal only) |
| Token usage per subscription | [Part 2](#part-2---token-usage-per-subscription) | APIM policy + Application Insights |

Requires Azure CLI (`az`) and PowerShell. Run `az login`, then run the commands below from this folder.

---

## Part 1 - 429s, errors, latency per subscription

**Tested on APIM Basic v2.** Standard v2 uses the same platform and is the supported tier. On the Consumption tier, gateway logs did not arrive in testing.

### Setup (once)

1. APIM > **Monitoring** > **Diagnostic settings** > **+ Add diagnostic setting**.
2. Check **Logs related to ApiManagement Gateway**.
3. Check **Send to Log Analytics workspace** and pick a workspace.
4. Set **Destination table** to **Resource specific**.
5. **Save**.

Data starts flowing from this point. The first rows can take 15 minutes to 2 hours to appear.

### Export

```powershell
az extension add -n log-analytics
$ws = az monitor log-analytics workspace show --workspace-name <workspace> -g <rg> --query customerId -o tsv
.\Get-SubscriptionHealth.ps1 -WorkspaceId $ws -Days 7
```

Output is in `.\subscription-health-output\`:

- `summary-by-subscription.csv` - per subscription and API. Most-throttled first.
- `per-hour.csv` - the same per hour.

Columns: `Requests`, `Success2xx`, `Throttled429`, `ClientErrors4xx` (excludes 429), `ServerErrors5xx`, `AvgLatencyMs`, `P95LatencyMs`, `ThrottledPct`, `ErrorPct`.

`(none)` = rejected before a subscription was identified (for example, a bad key).

---

## Part 2 - Token usage per subscription

Counts tokens from successful responses. Requests that fail (429, 5xx) return no tokens and are not counted.

### Setup (once)

1. APIM > **Monitoring** > **Application Insights** > **+ Add**. Select your resource.
2. APIM > **APIs** > **All APIs** > **Settings** > **Diagnostics Logs**. Check **Enable**, choose that logger, **Save**.
3. Application Insights resource > **Usage and estimated costs** > **Custom metrics (Preview)** > **With dimensions** > **OK**.
4. Run once:

   ```powershell
   $apimId = az apim show --name <apim> --resource-group <rg> --query id -o tsv
   .\Enable-ApimAppInsightsMetrics.ps1 -ApimResourceId $apimId
   ```

   If you enabled logging on individual APIs in step 2, add `-ApiId <api-id>, <api-id>`.
5. APIM > **APIs** > **All APIs** > **Inbound processing** > **Policies** (code view). Paste the contents of `llm-emit-token-metric-policy.xml` inside `<inbound>`. All APIs has no `<base />`; at API level, paste after `<base />`.

Streaming clients must send `stream_options: {"include_usage": true}`.

Data appears about 10 minutes after traffic.

### Export

```powershell
az extension add -n application-insights
$appId = az monitor app-insights component show --app <name> -g <rg> --query appId -o tsv
.\Get-SubscriptionUsage.ps1 -AppInsightsId $appId -Days 7
```

Output is in `.\subscription-usage-output\`:

- `summary-by-subscription.csv` - totals per subscription, API, and metric.
- `per-hour.csv` - the same per hour.

`SubscriptionId` is the subscription's name in APIM. Don't add Total, Prompt, and Completion together; Total already includes the other two.

---

## Limits

- Part 2 shows consumption, not PTU saturation. Use the workbook's **Utilization V2** for that.
- Part 2 drops new values silently past 100 values per dimension or 1,000 active series per namespace.
- Gateway logs and custom metrics with dimensions add Azure Monitor costs.
