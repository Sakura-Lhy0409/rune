param(
  [Parameter(Mandatory=$true)][string]$ListFile,
  [string]$OutDir = "D:\项目\ios平台agent\.research\pages"
)
$ErrorActionPreference = "Continue"
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$lines = Get-Content -LiteralPath $ListFile | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") }
$i = 0
foreach ($line in $lines) {
  $i++
  $parts = $line -split '\s*\|\s*', 2
  $url = $parts[0].Trim()
  $slug = if ($parts.Count -gt 1) { $parts[1].Trim() } else { "p$i" }
  $slug = ($slug -replace '[^A-Za-z0-9._-]', '_')
  $dest = Join-Path $OutDir "$slug.txt"
  if (Test-Path $dest) { "SKIP $slug (exists)"; continue }
  try {
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 45 -Headers @{ "User-Agent" = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"; "Accept" = "text/html,application/json,text/plain,*/*" }
    $h = $r.Content
    if ($h -is [byte[]]) { $h = [System.Text.Encoding]::UTF8.GetString($h) }
    $ct = "$($r.Headers['Content-Type'])"
    if ($ct -match 'json') {
      $txt = $h
    } elseif ($ct -match 'text/plain' -or $url -match 'raw\.githubusercontent|raw\.github') {
      $txt = $h
    } else {
      $h = [regex]::Replace($h, '(?is)<(script|style|noscript|svg|head|nav|footer)[^>]*>.*?</\1>', ' ')
      $h = [regex]::Replace($h, '(?is)<!--.*?-->', ' ')
      $h = [regex]::Replace($h, '(?i)</?(p|div|br|li|tr|h1|h2|h3|h4|h5|table|section|article|pre|ul|ol|td|th)[^>]*>', "`n")
      $h = [regex]::Replace($h, '(?s)<[^>]+>', ' ')
      $txt = [System.Net.WebUtility]::HtmlDecode($h)
    }
    $txt = [regex]::Replace($txt, '[ \t\u00A0]+', ' ')
    $txt = [regex]::Replace($txt, '(\r?\n\s*){3,}', "`n`n")
    Set-Content -LiteralPath $dest -Value $txt -Encoding UTF8
    "OK   $slug  status=$($r.StatusCode) bytes=$($txt.Length)  <- $url"
  } catch {
    "ERR  $slug  $($_.Exception.Message)  <- $url"
  }
}
