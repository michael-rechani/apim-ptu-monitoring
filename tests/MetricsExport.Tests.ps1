BeforeAll {
  Import-Module (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'common') 'MetricsExport.psm1') -Force
  # Stand-in so the module's `az` call can be mocked on machines without the Azure CLI.
  function global:az { }
}

AfterAll {
  Remove-Item function:global:az -ErrorAction SilentlyContinue
}

Describe 'Get-MetricSummary' {
  BeforeAll {
    $script:totalMetric = @{ Label = 'req'; Fill = $true }
    $script:maxMetric = @{ Label = 'util'; Fill = $false }
    function New-Row($Metric, $Value, $Deployment = 'd1') {
      [pscustomobject]@{ Metric = $Metric; Deployment = $Deployment; Dimensions = ''; TimeStampUtc = 't'; Value = [double]$Value }
    }
  }

  It 'counts missing minutes as zero for Total metrics' {
    # 1 day = 1440 minutes; only 2 had traffic (10 and 20)
    $rows = @((New-Row 'req' 10), (New-Row 'req' 20))
    $s = Get-MetricSummary -Rows $rows -Metrics @($totalMetric) -Days 1
    $s.Minutes | Should -Be 2
    $s.Peak | Should -Be 20
    $s.P95 | Should -Be 0
    $s.Avg | Should -Be ([math]::Round(30 / 1440, 2))
  }

  It 'does not fill Max-type metrics' {
    $rows = @((New-Row 'util' 50), (New-Row 'util' 100))
    $s = Get-MetricSummary -Rows $rows -Metrics @($maxMetric) -Days 1
    $s.Avg | Should -Be 75
    $s.P95 | Should -Be 100
    $s.Peak | Should -Be 100
  }

  It 'groups by deployment' {
    $rows = @((New-Row -Metric 'util' -Value 10 -Deployment 'a'), (New-Row -Metric 'util' -Value 90 -Deployment 'b'))
    $s = @(Get-MetricSummary -Rows $rows -Metrics @($maxMetric) -Days 1)
    $s.Count | Should -Be 2
    ($s | Where-Object Deployment -eq 'b').Peak | Should -Be 90
  }

  It 'omits the Deployment column when rows have none' {
    $rows = @([pscustomobject]@{ Metric = 'util'; Dimensions = ''; TimeStampUtc = 't'; Value = 5.0 })
    $s = Get-MetricSummary -Rows $rows -Metrics @($maxMetric) -Days 1
    $s.PSObject.Properties.Name | Should -Not -Contain 'Deployment'
  }

  It 'returns nothing for no rows' {
    @(Get-MetricSummary -Rows @() -Metrics @($maxMetric) -Days 1).Count | Should -Be 0
  }
}

Describe 'Get-MetricRows' {
  BeforeAll {
    $script:metrics = @(@{ Name = 'Requests'; Agg = 'Total'; Field = 'total'; Filter = "ModelDeploymentName eq '*'"; Fill = $true; Label = 'req' })
    $script:payload = @'
{"value":[{"timeseries":[{"metadatavalues":[{"name":{"value":"ModelDeploymentName"},"value":"gpt"},{"name":{"value":"StatusCode"},"value":"429"}],
"data":[{"timeStamp":"2026-01-01T00:00:00Z","total":3},{"timeStamp":"2026-01-01T00:01:00Z"}]}]}]}
'@
  }

  It 'flattens time series, splits the primary dimension and skips null points' {
    Mock az { $global:LASTEXITCODE = 0; $payload } -ModuleName MetricsExport
    $rows = @(Get-MetricRows -ResourceId '/x' -Metrics $metrics -Days 2 -PrimaryDimension 'ModelDeploymentName' -ThrottleLimit 1)
    $rows.Count | Should -Be 2   # one valid point per day, null point skipped
    $rows[0].Deployment | Should -Be 'gpt'
    $rows[0].Dimensions | Should -Be 'StatusCode=429'
    $rows[0].Value | Should -Be 3
  }

  It 'retries a failing call and succeeds' {
    $script:calls = 0
    Mock az {
      $script:calls++
      if ($script:calls -lt 2) { $global:LASTEXITCODE = 1; return }
      $global:LASTEXITCODE = 0; $payload
    } -ModuleName MetricsExport
    Mock Start-Sleep { } -ModuleName MetricsExport
    $rows = @(Get-MetricRows -ResourceId '/x' -Metrics $metrics -Days 1 -ThrottleLimit 1)
    $rows.Count | Should -Be 1
  }

  It 'throws after exhausting retries' {
    Mock az { $global:LASTEXITCODE = 1 } -ModuleName MetricsExport
    Mock Start-Sleep { } -ModuleName MetricsExport
    { Get-MetricRows -ResourceId '/x' -Metrics $metrics -Days 1 -ThrottleLimit 1 -Retries 2 } | Should -Throw '*after 2 attempts*'
  }
}
