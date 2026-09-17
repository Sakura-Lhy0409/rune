param([string]$Path)
function Walk($node, $out) {
  if ($null -eq $node) { return }
  if ($node -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $node.PSObject.Properties) {
      if ($p.Name -eq "text" -and $p.Value -is [string]) { $out.Add($p.Value) }
      elseif ($p.Name -eq "code" -and $p.Value -is [array]) { $out.Add("[CODE] " + ($p.Value -join " | ")) }
      elseif ($p.Name -eq "title" -and $p.Value -is [string]) { $out.Add("=== " + $p.Value) }
      else { Walk $p.Value $out }
    }
  } elseif ($node -is [array]) { foreach ($i in $node) { Walk $i $out } }
}
$out = New-Object System.Collections.Generic.List[string]
$json = Get-Content -Raw -Path $Path | ConvertFrom-Json
Walk $json $out
$out -join [char]10
