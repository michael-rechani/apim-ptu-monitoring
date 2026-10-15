param(
  [Parameter(Mandatory)] [string]$ResourceId,
  [int]$Days = 14,
  [string]$OutDir = (Join-Path (Get-Location).Path 'ptu-metrics'),
  [int]$ThrottleLimit = 4
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path $PSScriptRoot 'common') 'MetricsExport.psm1') -Force
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Fill = $true: Total metrics, where a missing minute means zero (see Get-MetricSummary).
$byDeployment = "ModelDeploymentName eq '*'"
$metrics = @(
  @{ Name = 'AzureOpenAIProvisionedManagedUtilizationV2'; Agg = 'Maximum'; Field = 'maximum'; Filter = $byDeployment; Fill = $false; Label = '1-PTU Utilization V2 (Max %)' }
  @{ Name = 'AzureOpenAIRequests';                        Agg = 'Total';   Field = 'total';   Filter = $byDeployment; Fill = $true;  Label = '2-Requests (Sum per min)' }
  @{ Name = 'ProcessedPromptTokens';                      Agg = 'Total';   Field = 'total';   Filter = $byDeployment; Fill = $true;  Label = '3-Prompt Tokens (Sum per min)' }
  @{ Name = 'GeneratedTokens';                            Agg = 'Total';   Field = 'total';   Filter = $byDeployment; Fill = $true;  Label = '4-Completion Tokens (Sum per min)' }
  @{ Name = 'AzureOpenAIRequests';                        Agg = 'Total';   Field = 'total';   Filter = "$byDeployment and StatusCode eq '*' and IsSpillover eq '*'"; Fill = $true; Label = '5-Requests by StatusCode/IsSpillover (Sum per min)' }
  @{ Name = 'ActiveTokens';                               Agg = 'Total';   Field = 'total';   Filter = $byDeployment; Fill = $true;  Label = '6-Active Tokens (Sum per min)' }
)

$rows = @(Get-MetricRows -ResourceId $ResourceId -Metrics $metrics -Days $Days -PrimaryDimension 'ModelDeploymentName' -ThrottleLimit $ThrottleLimit)

$rows | Export-Csv (Join-Path $OutDir 'per-minute.csv') -NoTypeInformation

$summary = @(Get-MetricSummary -Rows $rows -Metrics $metrics -Days $Days)

foreach ($label in ($metrics.Label | Where-Object { $_ -notin $summary.Metric })) {
  Write-Warning "No data for '$label'. Utilization V2 and Active Tokens only report provisioned (PTU) deployments."
}

$summary | Export-Csv (Join-Path $OutDir 'summary.csv') -NoTypeInformation
$summary | Format-Table -AutoSize
Write-Host "Output: $OutDir"
