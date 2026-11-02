param([string]$Zip)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$tmp = Join-Path $env:TEMP ("chk_" + [guid]::NewGuid().ToString('N'))
[System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $tmp)
$root = Join-Path $tmp 'webroot'
$script:missing = @()
$script:checked = 0

foreach ($f in (Get-ChildItem $root -Recurse -File -Include '*.html','*.js','*.css')) {
  $fileDir = Split-Path -Parent $f.FullName
  $rel = $f.FullName.Replace($tmp, '').Replace('\', '/')
  $txt = Get-Content $f.FullName -Raw -Encoding UTF8
  $refs = @()

  if ($f.Extension -eq '.html') {
    foreach ($m in [regex]::Matches($txt, '(?:src|href)="([^"]+)"')) { $refs += $m.Groups[1].Value }
  } elseif ($f.Extension -eq '.js') {
    foreach ($m in [regex]::Matches($txt, "['""](\./[^'""]+\.(?:js|css|json|png|svg))['""]")) { $refs += $m.Groups[1].Value }
  } else {
    foreach ($m in [regex]::Matches($txt, 'url\(\s*[''""]?([^)''""]+)')) { $refs += $m.Groups[1].Value }
  }

  foreach ($ref in $refs) {
    if ($ref -match '^(https?:|data:|#|mailto:|javascript:|/system|/data)') { continue }
    if ($ref.StartsWith('/')) { continue }
    $script:checked++
    $target = [System.IO.Path]::GetFullPath((Join-Path $fileDir $ref))
    if (-not (Test-Path $target)) {
      $script:missing += ("{0} -> {1}" -f $rel, $ref)
    }
  }
}

Write-Output ("  refs checked: " + $script:checked)
if ($script:missing.Count) {
  Write-Output "  MISSING:"
  $script:missing | Sort-Object -Unique | ForEach-Object { Write-Output ("     " + $_) }
} else {
  Write-Output "  no missing reference"
}
Remove-Item $tmp -Recurse -Force
