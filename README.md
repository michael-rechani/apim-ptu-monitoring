# ptu-apim-monitoring

PTU validation tooling for Azure OpenAI / Foundry deployments, built only on Azure Monitor platform metrics (no diagnostic settings or Log Analytics required).

## Contents

| File | Purpose |
|---|---|
| `ptu-validation.workbook.json` | The workbook definition (single source of truth). Paste into the portal Advanced Editor or deploy with the Bicep file. |
| `ptu-workbook.bicep` | Deploys the workbook as a shared `Microsoft.Insights/workbooks` resource, optionally preselecting a resource. |
| `Get-PtuMetrics.ps1` | Read-only CSV export of the same metrics via `az monitor metrics list`, with Peak/P99/P95/Avg per deployment (and per status code / spillover). |
| `common/MetricsExport.psm1` | Shared query/summary code used by `Get-PtuMetrics.ps1` and `apim-metrics/Get-ApimMetrics.ps1`. Keep the `common` folder next to the scripts when copying them. |
| `apim-metrics/` | Companion APIM gateway workbook and exports. See its [README](apim-metrics/README.md). |
| `tests/`, `.github/workflows/ci.yml` | Pester tests, PSScriptAnalyzer, and Bicep build run on every PR. |

## Workbook layout

Parameters: **Foundry / Azure OpenAI resource** (Resource Graph picker, all subscriptions you can read) and **Time range** (1h, 4h, 12h, 24h, 3d, custom). Every chart uses 1-minute grain, so Sum values equal per-minute requests/tokens (RPM/TPM).

| Section | Chart | Aggregation | Split by |
|---|---|---|---|
| Capacity | Provisioned-managed Utilization V2 | Max | `ModelDeploymentName` |
| Capacity | Active Tokens | Sum | `ModelDeploymentName` |
| Demand | Azure OpenAI Requests | Sum | `ModelDeploymentName` |
| Demand | Processed Prompt Tokens | Sum | `ModelDeploymentName` |
| Demand | Generated Completion Tokens | Sum | `ModelDeploymentName` |
| Throttling and spillover | Azure OpenAI Requests | Sum | `StatusCode` |
| Throttling and spillover | Azure OpenAI Requests | Sum | `IsSpillover` |

Drag across any chart to zoom every chart to that window; re-select the time range to reset. Each chart has an **Open in Metrics** button.

## Usage

### Option A - portal, nothing deployed

1. Azure portal > **Monitor** > **Workbooks** > **+ New**.
2. Toolbar **Advanced Editor** (`</>`), keep **Gallery Template**, replace the content with `ptu-validation.workbook.json`, click **Apply**, then **Done Editing**.
3. Pick the resource and time range. Close without saving for a throwaway view, or **Save** to keep it.

### Option B - deploy with Bicep

```powershell
az login
$id = az cognitiveservices account show -n <resource> -g <rg> --query id -o tsv

# Creates one Microsoft.Insights/workbooks resource in <rg>; openAiResourceId is optional
az deployment group create -g <rg> --template-file ptu-workbook.bicep --parameters openAiResourceId=$id
```

### Metrics export (read-only; requires Monitoring Reader)

```powershell
.\Get-PtuMetrics.ps1 -ResourceId $id -Days 14
```

Queries run 4 at a time on PowerShell 7+ (including Cloud Shell); change with `-ThrottleLimit`, or use `-ThrottleLimit 1` for sequential. Failed calls are retried 3 times. For request/token metrics, minutes with no data count as 0 in P99/P95/Avg (`Minutes` is the number of minutes that had data); utilization is not filled, since no data means no measurement.

### Development

```powershell
Invoke-Pester -Path tests -CI
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

The Bicep templates preselect a resource by replacing `"id": "p-resource",` in the workbook JSON, and expose a `resourcePreselected` output that is `false` if that did not happen. The tests fail if the anchor is edited away.

## Notes

- Utilization V2 and Active Tokens only report provisioned (PTU) deployments; they stay empty for Standard / GlobalStandard.
- Completion tokens consume more PTU capacity than prompt tokens; include both when sizing.
- Active Tokens excludes cached tokens.
- 429s and `IsSpillover = true` are unmet PTU demand; add them on top of observed utilization when sizing.
- The metrics API returns 1-minute data for 7 days, but workbook charts render blank above roughly 3 days of 1-minute points (tested: 3 days renders, 7 days does not). Use a Custom range to step through longer periods, or the export script for week-long percentiles.
- Utilization V2 cannot be exported through diagnostic settings; read it here, in Metrics Explorer or with the export script.
- Customer / agent-level usage requires APIM token metrics in Application Insights (not included).
- Output defaults to `./ptu-metrics` under the current directory (works in Azure Cloud Shell). Do not commit production metric exports.

## Validation

Tested live in the Azure portal against a GlobalStandard test deployment: all charts load, deployment / status code (200, 429) / spillover splits populate, 1-minute peaks are preserved at 24h and 3d, and drag-to-zoom rescopes all charts. PTU-only charts could not be exercised with data because no PTU deployment was used.
