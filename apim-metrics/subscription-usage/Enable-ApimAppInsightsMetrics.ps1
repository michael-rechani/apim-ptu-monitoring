<#
.SYNOPSIS
    One-time setup step: turns on custom metrics ("metrics": true) on the API Management ->
    Application Insights diagnostic, so the llm-emit-token-metric policy actually emits
    queryable data.

.DESCRIPTION
    The Azure portal has no UI toggle for this one property - it can only be set via the ARM REST
    API, which is why this script exists. Everything else in the setup checklist is done in the
    portal - see README.md in this folder.

    Prerequisite: Application Insights logging ("Diagnostics Logs") must already be enabled on the
    API(s) you want to track (APIs > All APIs or a single API > Settings > Diagnostics Logs).
    That is what creates the "applicationinsights" diagnostic this script updates.

    Scope matters: a diagnostic set on a single API overrides the one on "All APIs". Run this with
    no -ApiId if you enabled logging on All APIs, or pass -ApiId for each API where you enabled
    logging individually (use both if you did both).

    The script reads the existing diagnostic, changes only the "metrics" property, and writes it
    back - sampling, verbosity, and logger settings are left as-is. Safe to re-run.

    Requires the Azure CLI (az), logged in (az login), with write access on the API Management
    instance (e.g. API Management Service Contributor).

.PARAMETER ApimResourceId
    Full ARM resource ID of the API Management instance:
    /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<name>

    Find it with:
        az apim show --name <apim-name> --resource-group <rg> --query id -o tsv

.PARAMETER ApiId
    Optional. One or more API IDs (the API's "Name" in APIM, not its display name) whose own
    diagnostic should be updated. Omit to update the All APIs diagnostic.

.PARAMETER DiagnosticId
    Name of the diagnostic entity. Defaults to "applicationinsights", which is what the portal
    names it.

.EXAMPLE
    # Logging was enabled on All APIs
    .\Enable-ApimAppInsightsMetrics.ps1 -ApimResourceId "/subscriptions/.../service/contoso-apim"

.EXAMPLE
    # Logging was enabled on two individual APIs
    .\Enable-ApimAppInsightsMetrics.ps1 -ApimResourceId "/subscriptions/.../service/contoso-apim" -ApiId ptu-eastus, ptu-westus
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApimResourceId,

    [string[]]$ApiId,

    [string]$DiagnosticId = "applicationinsights",

    [string]$ApiVersion = "2022-08-01"
)

$ErrorActionPreference = "Stop"

function Enable-Metrics {
    param([string]$ScopePath, [string]$Label)

    $uri = "https://management.azure.com$ScopePath/diagnostics/$DiagnosticId" + "?api-version=$ApiVersion"

    Write-Host "[$Label] Reading current diagnostic settings..."
    $raw = az rest --only-show-errors --method get --uri $uri 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "[$Label] Could not read diagnostic '$DiagnosticId'. Enable Application Insights logging first (APIM > APIs > $Label > Settings > Diagnostics Logs > Enable, pick your Application Insights logger, Save), then re-run. Azure CLI said:`n$raw"
    }
    $current = $raw | ConvertFrom-Json

    if ($current.properties.metrics -eq $true) {
        Write-Host "[$Label] Custom metrics already enabled. Nothing to do."
        return
    }

    $current.properties | Add-Member -NotePropertyName metrics -NotePropertyValue $true -Force

    $bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "apim-diagnostic-$(Get-Random).json"
    $json = @{ properties = $current.properties } | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($bodyPath, $json, (New-Object System.Text.UTF8Encoding $false))

    try {
        Write-Host "[$Label] Enabling custom metrics..."
        az rest --only-show-errors --method put --uri $uri --body "@$bodyPath" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "[$Label] Update failed." }
        Write-Host "[$Label] Done."
    }
    finally {
        Remove-Item $bodyPath -ErrorAction SilentlyContinue
    }
}

if ($ApiId) {
    foreach ($id in $ApiId) {
        Enable-Metrics -ScopePath "$ApimResourceId/apis/$id" -Label "API '$id'"
    }
}
else {
    Enable-Metrics -ScopePath $ApimResourceId -Label "All APIs"
}

Write-Host "Custom metrics are enabled. Data appears once the llm-emit-token-metric policy is deployed and traffic flows (allow a few minutes)."
