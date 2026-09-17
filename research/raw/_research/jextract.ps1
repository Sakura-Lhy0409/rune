param([string]$In,[string]$Out)
function Walk($node, $acc) {
  if ($null -eq $node) { return }
  if ($node -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $node.PSObject.Properties) {
      if ($p.Name -eq "text" -and $p.Value -is [string]) { $acc.Add($p.Value) }
      elseif ($p.Name -eq "code" -and $p.Value -is [array]) { $acc.Add("[CODE] " + ($p.Value -join " | ")) }
      elseif ($p.Name -eq "title" -and $p.Value -is [string]) { $acc.Add("=== " + $p.Value) }
      else { Walk $p.Value $acc }
    }
  } elseif ($node -is [array]) { foreach ($i in $node) { Walk $i $acc } }
}
$acc = New-Object System.Collections.Generic.List[string]
$json = Get-Content -Raw -Path $In | ConvertFrom-Json
Walk $json $acc
$acc -join [char]10 | Set-Content -Path $Out -Encoding utf8
"OK $Out $((Get-Content $Out).Count) lines"
