param(
  [Parameter(Mandatory=$true)][string]$Url,
  [int]$MaxChars = 60000,
  [string]$Grep = ""
)
$ErrorActionPreference = "Stop"
try {
  $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 40 -Headers @{ "User-Agent" = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"; "Accept-Language" = "en-US,en;q=0.9" }
} catch {
  "FETCH_ERROR: $($_.Exception.Message)"
  exit 0
}
$h = $r.Content
if ($h -is [byte[]]) { $h = [System.Text.Encoding]::UTF8.GetString($h) }
# remove script/style/nav/head blocks
$h = [regex]::Replace($h, '(?is)<(script|style|noscript|svg|head)[^>]*>.*?</\1>', ' ')
$h = [regex]::Replace($h, '(?is)<!--.*?-->', ' ')
# block-level -> newline
$h = [regex]::Replace($h, '(?i)</?(p|div|br|li|tr|h1|h2|h3|h4|h5|table|section|article|pre|code|ul|ol|td|th)[^>]*>', "`n")
$h = [regex]::Replace($h, '(?s)<[^>]+>', ' ')
$h = [System.Net.WebUtility]::HtmlDecode($h)
$h = [regex]::Replace($h, '[ \t\u00A0]+', ' ')
$h = [regex]::Replace($h, '(\r?\n\s*){2,}', "`n")
$h = $h.Trim()
if ($Grep -ne "") {
  $lines = $h -split "`n" | Where-Object { $_ -match $Grep }
  $out = ($lines -join "`n")
} else {
  $out = $h
}
if ($out.Length -gt $MaxChars) { $out = $out.Substring(0, $MaxChars) + "`n...[TRUNCATED]" }
"URL: $Url`nSTATUS: $($r.StatusCode)`n-----`n$out"
