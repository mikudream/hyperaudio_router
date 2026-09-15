# ============================================================
# build.ps1 - assemble the flashable Magisk / KernelSU module zip
# ============================================================
# IMPORTANT: this script is deliberately pure ASCII.
# Windows PowerShell 5.1 parses a BOM-less script using the system
# ANSI code page (GBK on zh-CN). Any non-ASCII literal here would be
# mangled and could hard-fail with a ParserError. Keeping the file
# ASCII-only makes it immune to code page and BOM problems entirely.
# The few Chinese literals needed for the output files are therefore
# built from code points via -join ([char]...).
#
# Layout:
#   assets/    text sources maintained by this project
#              module.prop / customize.sh / post-fs-data.sh / service.sh / system.prop
#              (system.prop base properties come from upstream HyperAudio)
#   webui/     this project's WebUI and on-device scripts
#   prebuilt/  upstream prebuilt artifacts, kept as-is (cannot be rebuilt):
#              hyper-audio / libaaudio_internal.so / libaaudio_internal_builder.so
#              config.toml / META-INF installer entry
#   CREDITS.md attribution (shipped inside the module)
#
# Build steps:
#   1) strip upstream author identifiers (whitelist app entry, a system.prop
#      comment, and the username in the Rust build path inside the binary)
#   2) normalize line endings and encoding (UTF-8 without BOM + LF)
#   3) three checks: no tuning payload / no device detection / no author marks
#   4) pack with .NET ZipFile so entry names use forward slashes
#      (Compress-Archive writes backslashes on Windows, which makes Android
#       extract files whose names literally contain a backslash)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File build.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$root  = $PSScriptRoot
$stage = Join-Path $root 'build'
$zip   = Join-Path $root 'hyperaudio_module.zip'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Write-Output "== 1. stage module tree =="
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

foreach ($f in @('module.prop','customize.sh','post-fs-data.sh','service.sh','system.prop')) {
  Copy-Item (Join-Path $root "assets\$f") $stage -Force
}
Copy-Item (Join-Path $root 'CREDITS.md') $stage -Force

New-Item -ItemType Directory -Force -Path (Join-Path $stage 'webroot') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'webui')   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'bin')     | Out-Null
Copy-Item (Join-Path $root 'webui\webroot\*') (Join-Path $stage 'webroot') -Force
foreach ($f in @('helper.sh'))          { Copy-Item (Join-Path $root "webui\$f") (Join-Path $stage 'webui') -Force }
foreach ($f in @('mode_switch.sh','start_daemon.sh','detect_tuning.sh','hyperaudio_init.sh')) {
  Copy-Item (Join-Path $root "webui\$f") (Join-Path $stage 'bin') -Force
}

Copy-Item (Join-Path $root 'prebuilt\hyper-audio') $stage -Force
Copy-Item (Join-Path $root 'prebuilt\config.toml') $stage -Force
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'system\lib64') | Out-Null
Copy-Item (Join-Path $root 'prebuilt\libaaudio_internal.so')         (Join-Path $stage 'system\lib64') -Force
Copy-Item (Join-Path $root 'prebuilt\libaaudio_internal_builder.so') (Join-Path $stage 'system\lib64') -Force
Copy-Item (Join-Path $root 'prebuilt\META-INF') $stage -Recurse -Force

Write-Output "== 2. strip upstream author identifiers =="
# assets/system.prop is already sanitized at the source, so no text edit is
# needed here. The binary path still has to be rewritten.
$cfg = Join-Path $stage 'config.toml'
$t = [System.IO.File]::ReadAllText($cfg, $utf8NoBom)
$t = [regex]::Replace($t, '(?m)^\s*"com\.hlmc\.phire",\r?\n', '')
[System.IO.File]::WriteAllText($cfg, $t, $utf8NoBom)

# equal-length byte replacement inside the Rust binary
$bin = Join-Path $stage 'hyper-audio'
$bytes = [System.IO.File]::ReadAllBytes($bin)
$from = [System.Text.Encoding]::ASCII.GetBytes('hlmc')
$to   = [System.Text.Encoding]::ASCII.GetBytes('user')
$n = 0
for ($i = 0; $i -le $bytes.Length - 4; $i++) {
  if ($bytes[$i] -eq $from[0] -and $bytes[$i+1] -eq $from[1] -and $bytes[$i+2] -eq $from[2] -and $bytes[$i+3] -eq $from[3]) {
    $bytes[$i] = $to[0]; $bytes[$i+1] = $to[1]; $bytes[$i+2] = $to[2]; $bytes[$i+3] = $to[3]; $n++
  }
}
[System.IO.File]::WriteAllBytes($bin, $bytes)
Write-Output "  binary: 'hlmc' -> 'user', $n occurrence(s), equal length"

Write-Output "== 3. normalize line endings and encoding =="
Get-ChildItem -Recurse -File $stage |
  Where-Object { $_.Extension -in '.sh','.prop','.toml','.md' -or $_.Name -eq 'update-binary' } |
  ForEach-Object {
    $t = [System.IO.File]::ReadAllText($_.FullName, $utf8NoBom) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($_.FullName, $t, $utf8NoBom)
  }

Write-Output "== 4. check A: no tuning payload =="
$forbidden = @('acdbdata','dax-default','mixer_paths','resourcemanager','audio_module_config_primary','audio_effects','sku_canoe')
foreach ($f in $forbidden) {
  $hit = Get-ChildItem -Recurse -File $stage | Where-Object { $_.Name -match $f }
  if ($hit) { Write-Output "!! forbidden payload file remains: $f"; exit 1 }
}
Write-Output "  pass"

Write-Output "== 5. check B: no device detection =="
$devicePats = 'popsicle|pandora|pudding|ro\.product\.device|ro\.product\.vendor\.device|ro\.build\.product|Mi17Audio|myron|1014E|1115X'
$hit2 = Get-ChildItem -Recurse -File $stage |
  Where-Object { $_.Extension -in '.sh','.prop','.toml' -or $_.Name -eq 'update-binary' } |
  Select-String -Pattern $devicePats -AllMatches
if ($hit2) { $hit2 | ForEach-Object { Write-Output ("   " + $_.Path + ":" + $_.LineNumber) }; exit 1 }
Write-Output "  pass"

Write-Output "== 6. check C: no upstream author marks (except CREDITS.md) =="
$authorPats = 'hlmc|HLMC|nakixii|Ray|Mi17Audio'
$hit3 = Get-ChildItem -Recurse -File $stage |
  Where-Object { $_.Name -ne 'CREDITS.md' } |
  Where-Object { $_.Extension -in '.sh','.prop','.toml','.md','.html','.js','.css' -or $_.Name -eq 'update-binary' } |
  Select-String -Pattern $authorPats -AllMatches
if ($hit3) { $hit3 | ForEach-Object { Write-Output ("   " + $_.Path + ":" + $_.LineNumber) }; exit 1 }
$binHit = ([regex]::Matches([System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($bin)), 'hlmc')).Count
if ($binHit -gt 0) { Write-Output "!! binary still contains $binHit x hlmc"; exit 1 }

# system.prop must carry the sanitized comment, not the upstream author one.
# Built from code points so this check stays ASCII-only text in this file.
$wantComment = '# ' + ([char]0x5B9E) + ([char]0x6D4B) + [char]0xFF1A
$spText = [System.IO.File]::ReadAllText((Join-Path $stage 'system.prop'), $utf8NoBom)
if ($spText.IndexOf($wantComment) -lt 0) {
  Write-Output "!! system.prop is missing the sanitized comment (expected a line starting with the measured-value note)"
  exit 1
}
Write-Output "  pass"

Write-Output "== 7. pack =="
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$zout = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in [System.IO.Directory]::EnumerateFiles($stage, '*', [System.IO.SearchOption]::AllDirectories)) {
  $rel = $f.Substring($stage.Length).TrimStart('\','/').Replace('\','/')
  $entry = $zout.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
  $es = $entry.Open(); $fs = [System.IO.File]::OpenRead($f); $fs.CopyTo($es); $fs.Dispose(); $es.Dispose()
}
$zout.Dispose()

$z = [System.IO.Compression.ZipFile]::OpenRead($zip)
Write-Output "entries: $($z.Entries.Count)"
$bad = @()
$z.Entries | Sort-Object FullName | ForEach-Object {
  Write-Output ("  {0,10}  {1}" -f $_.Length, $_.FullName)
  if ($_.FullName.Contains('\')) { $bad += $_.FullName }
}
$z.Dispose()
if ($bad.Count -gt 0) { Write-Output "!! entry name contains backslash"; exit 1 }
Write-Output ("output: {0}  ({1} bytes)" -f $zip, (Get-Item $zip).Length)
Write-Output ("sha256: " + (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower())
