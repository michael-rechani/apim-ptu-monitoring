<#
.SYNOPSIS
    Exports Azure OpenAI token usage per APIM subscription (and per API) to CSV, using the custom
    metrics emitted by the llm-emit-token-metric policy.

.DESCRIPTION
    Read-only. Queries Application Insights custom metrics (Total Tokens / Prompt Tokens /
    Completion Tokens) via `az monitor app-insights query`, grouped by hour, Subscription ID, and
    API ID, and writes the results to CSV.

    Requires the one-time setup in README.md to already be done: Application Insights connected to
    APIM, custom metrics with dimensions enabled, Enable-ApimAppInsightsMetrics.ps1 run once, and
    the llm-emit-token-metric-policy.xml snippet deployed.

.PARAMETER AppInsightsId
    Application ID (GUID) or resource name of the Application Insights instance. If you pass a
    name instead of a GUID, also pass -ResourceGroup.

    Find the Application ID with:
        az monitor app-insights component show --app <name> --resource-group <rg> --query appId -o tsv

.PARAMETER ResourceGroup
    Resource group of the Application Insights instance. Only needed when -AppInsightsId is a
    name rather than a GUID.

.PARAMETER Days
    How many days back to query. Default: 7.

.PARAMETER OutputFolder
    Where to write the CSVs. Default: .\subscription-usage-output

.EXAMPLE
    .\Get-SubscriptionUsage.ps1 -AppInsightsId "11111111-2222-3333-4444-555555555555" -Days 7

.EXAMPLE
    .\Get-SubscriptionUsage.ps1 -AppInsightsId contoso-appinsights -ResourceGroup contoso-rg -Days 30
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppInsightsId,

    [string]$ResourceGroup,

    [int]$Days = 7,

    [string]$OutputFolder = ".\subscription-usage-output"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder | Out-Null
}

$appArgs = @("--apps", $AppInsightsId)
if ($ResourceGroup) { $appArgs += @("--resource-group", $ResourceGroup) }

$query = @"
customMetrics
| where timestamp > ago(${Days}d)
| where name in ('Total Tokens', 'Prompt Tokens', 'Completion Tokens')
| extend SubscriptionId = tostring(customDimensions['Subscription ID'])
| extend ApiId = tostring(customDimensions['API ID'])
| summarize TokenCount = sum(value) by bin(timestamp, 1h), MetricName = name, SubscriptionId, ApiId
| order by timestamp asc
"@
# az.cmd on Windows truncates multi-line arguments at the first newline, so send one line.
$query = ($query -split "\r?\n" | Where-Object { $_.Trim() }) -join " "

Write-Host "Querying Application Insights (last $Days day(s))..."
$resultJson = az monitor app-insights query @appArgs --analytics-query $query --offset "${Days}d" -o json
if ($LASTEXITCODE -ne 0) {
    throw "az monitor app-insights query failed. Confirm -AppInsightsId/-ResourceGroup are correct and that the 'application-insights' CLI extension is installed (az extension add -n application-insights)."
}
$result = $resultJson | ConvertFrom-Json

$table = $result.tables[0]
$columns = $table.columns.name
$rows = $table.rows

if (-not $rows -or $rows.Count -eq 0) {
    Write-Warning "No data returned. Check that: the llm-emit-token-metric policy is deployed and has received traffic, custom metrics with dimensions is enabled on the Application Insights resource, and 'metrics: true' is set (run Enable-ApimAppInsightsMetrics.ps1). See README.md for the full checklist."
    return
}

$objects = foreach ($row in $rows) {
    $obj = [ordered]@{}
    for ($i = 0; $i -lt $columns.Count; $i++) { $obj[$columns[$i]] = $row[$i] }
    [pscustomobject]$obj
}

$perHourPath = Join-Path $OutputFolder "per-hour.csv"
$objects | Export-Csv -Path $perHourPath -NoTypeInformation

$summaryPath = Join-Path $OutputFolder "summary-by-subscription.csv"
$objects |
    Group-Object SubscriptionId, ApiId, MetricName |
    ForEach-Object {
        [pscustomobject]@{
            SubscriptionId = $_.Group[0].SubscriptionId
            ApiId          = $_.Group[0].ApiId
            MetricName     = $_.Group[0].MetricName
            TokenCount     = ($_.Group | Measure-Object -Property TokenCount -Sum).Sum
        }
    } |
    Sort-Object SubscriptionId, ApiId, MetricName |
    Export-Csv -Path $summaryPath -NoTypeInformation

Write-Host "Wrote $($objects.Count) rows to $perHourPath"
Write-Host "Wrote subscription summary to $summaryPath"
