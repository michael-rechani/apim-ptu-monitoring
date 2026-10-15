<#
.SYNOPSIS
    Exports request volume, throttling (429), errors, and latency per APIM subscription (and per
    API) to CSV, using APIM gateway logs in Log Analytics.

.DESCRIPTION
    Read-only. Queries the ApiManagementGatewayLogs table via `az monitor log-analytics query` and
    writes two CSVs:
      - summary-by-subscription.csv : totals for the whole period, per subscription and API
      - per-hour.csv                : the same measures per hour, to see when problems happened

    Requires the one-time setup in README.md ("Per-subscription health") to already be done: an
    APIM diagnostic setting sending GatewayLogs to a Log Analytics workspace, using the
    "Resource specific" destination table.

    Note: a request that fails before it reaches a subscription check (for example a missing or
    invalid subscription key) has no subscription and is reported as "(none)".

.PARAMETER WorkspaceId
    Workspace ID (GUID, also called Customer ID) of the Log Analytics workspace. Find it with:
        az monitor log-analytics workspace show --workspace-name <name> --resource-group <rg> --query customerId -o tsv

.PARAMETER Days
    How many days back to query. Default: 7.

.PARAMETER OutputFolder
    Where to write the CSVs. Default: .\subscription-health-output

.EXAMPLE
    .\Get-SubscriptionHealth.ps1 -WorkspaceId "11111111-2222-3333-4444-555555555555" -Days 7
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [int]$Days = 7,

    [string]$OutputFolder = ".\subscription-health-output"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder | Out-Null
}

# Measures shared by both queries. TotalTime is the gateway's end-to-end time in milliseconds.
$measures = @"
Requests = count(),
Success2xx = countif(ResponseCode between (200 .. 299)),
Throttled429 = countif(ResponseCode == 429),
ClientErrors4xx = countif(ResponseCode between (400 .. 499) and ResponseCode != 429),
ServerErrors5xx = countif(ResponseCode >= 500),
AvgLatencyMs = round(avg(TotalTime), 0),
P95LatencyMs = round(percentile(TotalTime, 95), 0)
"@

$common = @"
ApiManagementGatewayLogs
| where TimeGenerated > ago(${Days}d)
| extend SubscriptionId = iff(isempty(ApimSubscriptionId), '(none)', ApimSubscriptionId)
"@

$queries = [ordered]@{
    "summary-by-subscription.csv" = @{
        Columns = @("SubscriptionId", "ApiId", "Requests", "Success2xx", "Throttled429", "ThrottledPct", "ClientErrors4xx", "ServerErrors5xx", "ErrorPct", "AvgLatencyMs", "P95LatencyMs")
        Query   = @"
$common
| summarize $measures by SubscriptionId, ApiId
| extend ThrottledPct = round(100.0 * Throttled429 / Requests, 1), ErrorPct = round(100.0 * (ClientErrors4xx + ServerErrors5xx) / Requests, 1)
| order by Throttled429 desc, Requests desc
"@
    }
    "per-hour.csv" = @{
        Columns = @("TimeGenerated", "SubscriptionId", "ApiId", "Requests", "Success2xx", "Throttled429", "ClientErrors4xx", "ServerErrors5xx", "AvgLatencyMs", "P95LatencyMs")
        Query   = @"
$common
| summarize $measures by bin(TimeGenerated, 1h), SubscriptionId, ApiId
| order by TimeGenerated asc
"@
    }
}

foreach ($name in $queries.Keys) {
    # az.cmd on Windows truncates multi-line arguments at the first newline, so send one line.
    $query = ($queries[$name].Query -split "\r?\n" | Where-Object { $_.Trim() }) -join " "

    Write-Host "Querying Log Analytics for $name (last $Days day(s))..."
    $resultJson = az monitor log-analytics query --workspace $WorkspaceId --analytics-query $query --timespan "P${Days}D" -o json
    if ($LASTEXITCODE -ne 0) {
        throw "az monitor log-analytics query failed. Confirm -WorkspaceId is the workspace's Customer ID (GUID), that you have read access, and that the 'log-analytics' CLI extension is installed if prompted (az extension add -n log-analytics)."
    }

    $rows = @($resultJson | ConvertFrom-Json)
    if ($rows.Count -eq 0) {
        Write-Warning "No data returned. Check that: the APIM diagnostic setting sends GatewayLogs to this workspace with the 'Resource specific' destination table, requests have gone through APIM since it was enabled, and allow ~10 minutes for ingestion. See README.md for the full checklist."
        return
    }

    $path = Join-Path $OutputFolder $name
    # Pin column order (the CLI returns columns alphabetically) and drop bookkeeping such as TableName.
    $rows | Select-Object -Property $queries[$name].Columns | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Wrote $($rows.Count) rows to $path"
}
