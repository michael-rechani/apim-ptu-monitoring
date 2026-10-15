param(
  [Parameter(Mandatory)] [string]$ApimResourceId,
  [int]$Days = 7,
  [string]$OutDir = (Join-Path (Get-Location).Path 'apim-metrics-output'),
  [int]$ThrottleLimit = 4
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'common') 'MetricsExport.psm1') -Force
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Fill = $true: Total metrics, where a missing minute means zero (see Get-MetricSummary).
$gatewayCodes = "GatewayResponseCode eq '*' and BackendResponseCode eq '*' and LastErrorReason eq '*'"
$metrics = @(
  @{ Name = 'CpuPercent_Gateway';    Agg = 'Maximum'; Field = 'maximum'; Filter = $null;         Fill = $false; Label = '1-Gateway CPU (Max %)' }
  @{ Name = 'MemoryPercent_Gateway'; Agg = 'Maximum'; Field = 'maximum'; Filter = $null;         Fill = $false; Label = '2-Gateway Memory (Max %)' }
  @{ Name = 'Requests';            Agg = 'Total';   Field = 'total';   Filter = $gatewayCodes; Fill = $true;  Label = '3-Requests by Gateway/Backend code/ErrorReason (Sum per min)' }
  @{ Name = 'Duration';            Agg = 'Maximum'; Field = 'maximum'; Filter = $null;         Fill = $false; Label = '4-Gateway Duration (Max ms)' }
  @{ Name = 'BackendDuration';     Agg = 'Maximum'; Field = 'maximum'; Filter = $null;         Fill = $false; Label = '5-Backend Duration (Max ms)' }
  @{ Name = 'NetworkConnectivity'; Agg = 'Total';   Field = 'total';   Filter = $null;         Fill = $true;  Label = '6-Network Connectivity by dependency (Sum per min)' }
)

$rows = @(Get-MetricRows -ResourceId $ApimResourceId -Metrics $metrics -Days $Days -ThrottleLimit $ThrottleLimit)

$rows | Export-Csv (Join-Path $OutDir 'per-minute.csv') -NoTypeInformation

$summary = @(Get-MetricSummary -Rows $rows -Metrics $metrics -Days $Days)

foreach ($label in ($metrics.Label | Where-Object { $_ -notin $summary.Metric })) {
  Write-Warning "No data for '$label'."
}

$summary | Export-Csv (Join-Path $OutDir 'summary.csv') -NoTypeInformation
$summary | Format-Table -AutoSize
Write-Host "Output: $OutDir"
