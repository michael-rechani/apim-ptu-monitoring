BeforeDiscovery {
  $root = Split-Path $PSScriptRoot -Parent
  $script:workbooks = @(
    @{ Path = Join-Path $root 'ptu-validation.workbook.json'; Anchors = @('"id": "p-resource",') }
    @{ Path = Join-Path (Join-Path $root 'apim-metrics') 'apim-validation.workbook.json'; Anchors = @('"id": "p-resource",', '"id": "p-aoai-resource",') }
  )
}

Describe 'Workbook <Path>' -ForEach $workbooks {
  It 'is valid JSON' {
    { Get-Content $Path -Raw | ConvertFrom-Json } | Should -Not -Throw
  }

  # The Bicep templates preselect resources by string-replacing these exact strings.
  It 'contains each Bicep anchor exactly once' {
    $text = Get-Content $Path -Raw
    foreach ($a in $Anchors) {
      ([regex]::Matches($text, [regex]::Escape($a))).Count | Should -Be 1 -Because "Bicep anchors on $a"
    }
  }
}
