<#
.SYNOPSIS
    Shared helpers for the Azure Monitor metrics export scripts (Get-PtuMetrics.ps1 and
    apim-metrics\Get-ApimMetrics.ps1).
#>

# Runs `az monitor metrics list` with retries. Kept as a string so the same code can run inside
# ForEach-Object -Parallel runspaces, which cannot see functions from this module.
$script:WorkerSource = @'
param($Item)
$raw = ''
$err = ''
$ok = $false
for ($attempt = 1; $attempt -le $Item.Retries; $attempt++) {
  # Keep stderr (CLI warnings) out of the JSON on stdout.
  $all = & az @($Item.AzArgs) 2>&1
  $raw = ($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-String)
  $err = ($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Out-String)
  if ($LASTEXITCODE -eq 0) { $ok = $true; break }
  if ($attempt -lt $Item.Retries) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)) }
}
[pscustomobject]@{ Index = $Item.Index; Ok = $ok; Raw = $raw; Err = $err }
'@

function Get-MetricRows {
  <#
  .SYNOPSIS
      Pulls 1-minute metric data one day at a time and returns flat per-minute rows.
  .PARAMETER Metrics
      Hashtables with Name, Agg (Azure aggregation), Field (JSON field), Filter (or $null), Label.
  .PARAMETER PrimaryDimension
      Optional dimension (for example ModelDeploymentName) returned as a separate Deployment
      property instead of being folded into Dimensions.
  .PARAMETER ThrottleLimit
      Concurrent az calls. Runs in parallel only on PowerShell 7+; otherwise sequential.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string]$ResourceId,
    [Parameter(Mandatory)] [hashtable[]]$Metrics,
    [Parameter(Mandatory)] [int]$Days,
    [string]$PrimaryDimension,
    [int]$ThrottleLimit = 4,
    [int]$Retries = 3
  )

  $now = (Get-Date).ToUniversalTime()
  $end = $now.AddSeconds(-$now.Second).AddMilliseconds(-$now.Millisecond)

  $items = [System.Collections.Generic.List[object]]::new()
  foreach ($m in $Metrics) {
    for ($d = $Days; $d -gt 0; $d--) {
      $s = $end.AddDays(-$d)
      $e = $s.AddDays(1)
      $azArgs = @('monitor', 'metrics', 'list', '--resource', $ResourceId,
        '--metrics', $m.Name, '--aggregation', $m.Agg, '--interval', 'PT1M',
        '--start-time', $s.ToString('yyyy-MM-ddTHH:mm:ssZ'), '--end-time', $e.ToString('yyyy-MM-ddTHH:mm:ssZ'),
        '-o', 'json')
      if ($m.Filter) { $azArgs += @('--filter', $m.Filter) }
      $items.Add([pscustomobject]@{
          Index = $items.Count; Metric = $m; Label = "$($m.Name) $($s.ToString('yyyy-MM-dd'))"
          AzArgs = $azArgs; Retries = $Retries
        })
    }
  }

  $source = $script:WorkerSource
  if ($PSVersionTable.PSVersion.Major -ge 7 -and $ThrottleLimit -gt 1) {
    Write-Host "Querying $($items.Count) metric/day windows ($ThrottleLimit in parallel)..."
    $results = $items | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
      & ([scriptblock]::Create($using:source)) $_
    }
  }
  else {
    $results = foreach ($item in $items) {
      Write-Host "Querying $($item.Label)"
      & ([scriptblock]::Create($source)) $item
    }
  }

  foreach ($r in ($results | Sort-Object Index)) {
    $item = $items[$r.Index]
    if (-not $r.Ok) { throw "az monitor metrics list failed for $($item.Label) after $Retries attempts: $($r.Err)" }
    $m = $item.Metric
    $json = $r.Raw | ConvertFrom-Json
    foreach ($ts in $json.value[0].timeseries) {
      $dep = $null
      $others = @($ts.metadatavalues)
      if ($PrimaryDimension) {
        $dep = ($others | Where-Object { $_.name.value -ieq $PrimaryDimension }).value
        $others = @($others | Where-Object { $_.name.value -ine $PrimaryDimension })
      }
      $dims = (@($others | ForEach-Object { "$($_.name.value)=$($_.value)" }) -join '; ')
      foreach ($p in $ts.data) {
        $v = $p.($m.Field)
        if ($null -eq $v) { continue }
        $row = [ordered]@{ Metric = $m.Label }
        if ($PrimaryDimension) { $row.Deployment = $dep }
        $row.Dimensions = $dims
        $row.TimeStampUtc = $p.timeStamp
        $row.Value = [double]$v
        [pscustomobject]$row
      }
    }
  }
}

function Get-MetricSummary {
  <#
  .SYNOPSIS
      Peak/P99/P95/Avg per metric (and deployment/dimension group).
  .DESCRIPTION
      Azure Monitor omits minutes with no data. For metrics flagged Fill = $true (Total
      aggregations: requests, tokens) those minutes are real zeros, so they are counted as 0 in
      Avg and the percentiles. Without that, quiet periods would be dropped and Avg/P95 would be
      overstated. Max-type metrics (utilization, durations) are not filled: no data means no
      measurement, not zero. Minutes is the number of minutes that actually had data.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Rows,
    [Parameter(Mandatory)] [hashtable[]]$Metrics,
    [Parameter(Mandatory)] [int]$Days
  )

  $windowMinutes = $Days * 1440
  $fillByLabel = @{}
  foreach ($m in $Metrics) { $fillByLabel[$m.Label] = [bool]$m.Fill }
  $hasDeployment = $Rows.Count -gt 0 -and ($Rows[0].PSObject.Properties.Name -contains 'Deployment')

  $groupProps = if ($hasDeployment) { @('Metric', 'Deployment', 'Dimensions') } else { @('Metric', 'Dimensions') }

  $Rows | Group-Object -Property $groupProps | ForEach-Object {
    $dataMinutes = $_.Group.Count
    $vals = [System.Collections.Generic.List[double]]::new([double[]]$_.Group.Value)
    if ($fillByLabel[$_.Group[0].Metric] -and $dataMinutes -lt $windowMinutes) {
      $vals.AddRange([double[]]::new($windowMinutes - $dataMinutes))
    }
    $vals.Sort()
    $n = $vals.Count
    $out = [ordered]@{ Metric = $_.Group[0].Metric }
    if ($hasDeployment) { $out.Deployment = $_.Group[0].Deployment }
    $out.Dimensions = $_.Group[0].Dimensions
    $out.Minutes = $dataMinutes
    $out.Peak = $vals[$n - 1]
    $out.P99 = $vals[[math]::Ceiling(0.99 * $n) - 1]
    $out.P95 = $vals[[math]::Ceiling(0.95 * $n) - 1]
    $out.Avg = [math]::Round(($vals | Measure-Object -Average).Average, 2)
    [pscustomobject]$out
  } | Sort-Object -Property $groupProps
}

Export-ModuleMember -Function Get-MetricRows, Get-MetricSummary
