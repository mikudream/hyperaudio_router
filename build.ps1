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
# Strict decoder (throwOnInvalidBytes): a GBK-encoded file dropped into assets/
# would otherwise be silently decoded to U+FFFD replacement characters and ship
# as mojibake. Better to fail loudly.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

# Remove any previous package BEFORE validating. The zip is gitignored, so a
# stale one is invisible to `git status` and easy to mistake for this build's
# output. Deleting it first guarantees the invariant "a failed build produces
# no artifact" -- previously the delete happened in step 7, so an aborted build
# left the previous package in place (reproduced in review).
if (Test-Path $zip) { Remove-Item $zip -Force }

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
Copy-Item (Join-Path $root 'webui\webroot\*') (Join-Path $stage 'webroot') -Recurse -Force
foreach ($f in @('helper.sh'))          { Copy-Item (Join-Path $root "webui\$f") (Join-Path $stage 'webui') -Force }
# action.sh / uninstall.sh must sit at the module root: the KernelSU / Magisk
# "action" button and the uninstall hook both look for them there.
  # 本分支不提供动作按钮：定位是全局恒定低延迟 + 按应用音效，没有可切换的模式
  Copy-Item (Join-Path $root 'webui\uninstall.sh') $stage -Force
foreach ($f in (Get-ChildItem (Join-Path $root 'webui\bin') -File | ForEach-Object { $_.Name })) {
  Copy-Item (Join-Path $root "webui\bin\$f") (Join-Path $stage 'bin') -Force
}

Copy-Item (Join-Path $root 'prebuilt\hyper-audio') $stage -Force
Copy-Item (Join-Path $root 'prebuilt\config.toml') $stage -Force
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'system\lib64') | Out-Null
Copy-Item (Join-Path $root 'prebuilt\libaaudio_internal.so')         (Join-Path $stage 'system\lib64') -Force
Copy-Item (Join-Path $root 'prebuilt\libaaudio_internal_builder.so') (Join-Path $stage 'system\lib64') -Force
# Zygisk payload: only this branch ships it (per-app switching). zygiskd loads
# <module>/zygisk/<abi>.so, so it must sit at the module root, not under bin/.
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'zygisk') | Out-Null
Copy-Item (Join-Path $root 'zygisk\arm64-v8a.so')           (Join-Path $stage 'zygisk') -Force
Copy-Item (Join-Path $root 'zygisk\abi.h.patch')            (Join-Path $stage 'zygisk') -Force
Copy-Item (Join-Path $root 'zygisk\patch_mflags_offset.py') (Join-Path $stage 'zygisk') -Force
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
  Where-Object { $_.Extension -in '.sh','.prop','.toml','.md' -or $_.Name -in 'update-binary','updater-script' } |
  ForEach-Object {
    $t = [System.IO.File]::ReadAllText($_.FullName, $utf8NoBom) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($_.FullName, $t, $utf8NoBom)
  }

Write-Output "== 4. check A: expected file layout only, and no tuning payload =="
# A1) deny-list by file name. NOTE: this alone is bypassable -- a file with an
# unexpected extension (e.g. webroot/extra.xml) would slip through, which was
# reproduced in review. So the allow-list below is the real gate.
# NOTE: this list is generic on purpose. It previously said 'sku_canoe' (one
# specific platform); 'sku_' covers every platform's tuning payload instead.
$forbidden = @('acdbdata','dax-default','mixer_paths','resourcemanager','audio_module_config_primary','audio_effects','sku_','volume_curve','audio_policy_engine')
foreach ($f in $forbidden) {
  $hit = Get-ChildItem -Recurse -File $stage | Where-Object { $_.Name -match $f }
  if ($hit) { Write-Output "!! forbidden payload file remains: $f"; exit 1 }
}

# A2) every staged file must match the known-good layout. Anything unexpected
# aborts the build, so extra/.xml/.json payloads or stray notes cannot ship.
$allowed = @(
  '^module\.prop$','^customize\.sh$','^post-fs-data\.sh$','^service\.sh$','^system\.prop$','^uninstall\.sh$',
  '^CREDITS\.md$','^config\.toml$','^hyper-audio$','^mode$',
  '^META-INF/com/google/android/update-binary$','^META-INF/com/google/android/updater-script$',
    '^bin/[A-Za-z0-9_]+\.(sh|awk)$',
  '^system/lib64/libaaudio_internal(_builder)?\.so$',
  '^zygisk/arm64-v8a\.so$','^zygisk/(abi\.h\.patch|patch_mflags_offset\.py)$',
  '^webui/helper\.sh$',
  '^webroot/.+$',
  '^(sound|lowlat|boot)\.conf$',
  '^action\.sh$'
)
foreach ($f in [System.IO.Directory]::EnumerateFiles($stage, '*', [System.IO.SearchOption]::AllDirectories)) {
  $rel = $f.Substring($stage.Length).TrimStart('\','/').Replace('\','/')
  $ok = $false
  foreach ($pat in $allowed) { if ($rel -match $pat) { $ok = $true; break } }
  if (-not $ok) { $unknown += $rel }
}
if ($unknown.Count -gt 0) {
  Write-Output "!! staged file is not in the expected layout (refusing to ship):"
  $unknown | ForEach-Object { Write-Output ("   " + $_) }
  exit 1
}
Write-Output ("  pass (" + ([System.IO.Directory]::EnumerateFiles($stage, '*', [System.IO.SearchOption]::AllDirectories) | Measure-Object).Count + " files, all expected)")


Write-Output "== 5. check B: no device detection =="
$devicePats = 'popsicle|pandora|pudding|ro\.product\.device|ro\.product\.vendor\.device|ro\.build\.product|Mi17Audio|myron|1014E|1115X'
$hit2 = Get-ChildItem -Recurse -File $stage |
  Where-Object { $_.FullName -notmatch '[\\/](bin|webroot)[\\/]' } |
  Where-Object { $_.Extension -in '.sh','.prop','.toml' -or $_.Name -in 'update-binary','updater-script' } |
  Select-String -Pattern $devicePats -AllMatches
if ($hit2) {
  Write-Output "!! device-detection string found:"
  $hit2 | ForEach-Object { Write-Output ("   " + $_.Path + ":" + $_.LineNumber + "  " + $_.Line.Trim()) }
  exit 1
}
Write-Output "  pass"

Write-Output "== 6. check C: no upstream author marks (except CREDITS.md) =="
# 'Ray' must be matched as a whole word with its author context: a bare,
# case-insensitive 'Ray' also hits benign words like "array" (verified in review),
# which would fail the build for no reason.
$authorPats = 'hlmc|HLMC|nakixii|Mi17Audio|\bRay\b'
  $hit3 = Get-ChildItem -Recurse -File $stage |
    Where-Object { $_.FullName -notmatch '[\\/](bin|webroot)[\\/]' } |
  Where-Object { $_.Name -ne 'CREDITS.md' } |
  Where-Object { $_.Extension -in '.sh','.prop','.toml','.md','.html','.js','.css' -or $_.Name -in 'update-binary','updater-script' } |
  Select-String -Pattern $authorPats -CaseSensitive -AllMatches
if ($hit3) {
  Write-Output "!! upstream author mark found:"
  $hit3 | ForEach-Object { Write-Output ("   " + $_.Path + ":" + $_.LineNumber + "  " + $_.Line.Trim()) }
  exit 1
}

# binaries: scan hyper-audio and the .so payloads as bytes, case-insensitively
$binPats = @('hlmc', 'nakixii', 'Mi17Audio')
$binFiles = @($bin) + @(Get-ChildItem -Recurse -File $stage -Filter '*.so' | ForEach-Object { $_.FullName })
foreach ($bf in $binFiles) {
  $txt = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($bf)).ToLower()
  foreach ($p in $binPats) {
    $n = ([regex]::Matches($txt, [regex]::Escape($p.ToLower()))).Count
    if ($n -gt 0) { Write-Output "!! binary still contains $n x '$p': $bf"; exit 1 }
  }
}
Write-Output "  pass (text + binaries)"

# system.prop must carry the sanitized comment AND must NOT carry the upstream
# author's comment. The previous version only asserted presence of the sanitized
# one, so a file that kept the upstream signature alongside it would still pass.
# Literals are built from code points to keep this file ASCII-only.
$wantComment = '# ' + ([char]0x5B9E) + ([char]0x6D4B) + [char]0xFF1A
$banComment  = '# HLMC: '
$spText = [System.IO.File]::ReadAllText((Join-Path $stage 'system.prop'), $utf8NoBom)
if ($spText.IndexOf($wantComment) -lt 0) {
  Write-Output "!! system.prop is missing the sanitized comment (expected a line starting with the measured-value note)"
  exit 1
}
if ($spText.IndexOf($banComment) -ge 0 -or $spText.IndexOf('nakixii') -ge 0) {
  Write-Output "!! system.prop still carries the upstream author comment/signature"
  exit 1
}
Write-Output "  pass"

Write-Output "== 7. pack =="
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

# Fixed entry timestamp so the package is byte-for-byte reproducible: by default
# each entry carries the source file's mtime, so two builds from identical
# content produced different zip hashes (observed in review). 2009-01-01 is the
# conventional value used by Android/Java zip tooling.
$fixedTime = New-Object System.DateTimeOffset(2009, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
$zout = $null
$packOk = $false
try {
  $zout = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
  foreach ($f in [System.IO.Directory]::EnumerateFiles($stage, '*', [System.IO.SearchOption]::AllDirectories)) {
    $rel = $f.Substring($stage.Length).TrimStart('\','/').Replace('\','/')
    $entry = $zout.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = $fixedTime
    $es = $entry.Open(); $fs = [System.IO.File]::OpenRead($f); $fs.CopyTo($es); $fs.Dispose(); $es.Dispose()
  }
  $packOk = $true
} catch {
  Write-Output ("!! packing failed: " + $_.Exception.Message)
} finally {
  # Always release the file handle; on failure remove the half-written package so
  # it can never be mistaken for a complete build.
  if ($zout) { $zout.Dispose() }
  if (-not $packOk -and (Test-Path $zip)) { Remove-Item $zip -Force }
}
if (-not $packOk) { exit 1 }

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
