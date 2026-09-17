param([string]$Url,[string]$Out)
try {
  $r = Invoke-WebRequest -Uri $Url -TimeoutSec 40 -UserAgent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
  $h = $r.Content
  $h = [regex]::Replace($h, '(?is)<script.*?</script>', ' ')
  $h = [regex]::Replace($h, '(?is)<style.*?</style>', ' ')
  $h = [regex]::Replace($h, '(?is)<(br|/p|/div|/li|/h[1-6]|/tr|/section)>', "`n")
  $h = [regex]::Replace($h, '(?s)<[^>]+>', ' ')
  $h = [System.Net.WebUtility]::HtmlDecode($h)
  $h = [regex]::Replace($h, '[ \t]+', ' ')
  $h = [regex]::Replace($h, '(\r?\n\s*){2,}', "`n")
  Set-Content -Path $Out -Value $h -Encoding utf8
  "OK $Out $($h.Length)"
} catch { "ERR $Url : $($_.Exception.Message)" }
