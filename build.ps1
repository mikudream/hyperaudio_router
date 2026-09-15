<#
.SYNOPSIS
  构建「音频模式切换器」模块包（hyperaudio）

.DESCRIPTION
  从本仓库的源码部分 + 上游预编译产物，组装出可刷入的 Magisk / KernelSU 模块 zip。

  仓库分工：
    assets/   本项目维护的文本源码
              module.prop / customize.sh / post-fs-data.sh / service.sh / system.prop
              （system.prop 的基础属性源自上游 HyperAudio，本项目在此基础上增补）
    webui/    本项目的 WebUI 与设备端脚本
    prebuilt/ 上游预编译产物（无法从源码重建，按原样保留）：
              hyper-audio / libaaudio_internal.so / libaaudio_internal_builder.so
              config.toml / META-INF 安装入口
    CREDITS.md 来源与致谢（随包分发）

  构建时自动完成：
    1) 移除原作者个人标识：白名单中的作者自有 App 条目、system.prop 的作者签名注释、
       hyper-audio 二进制内 Rust 编译期路径中的用户名（等长替换）
    2) 规范化换行与编码（UTF-8 无 BOM + LF）
    3) 三项校验：无调音载荷 / 无机型判断 / 除 CREDITS.md 外无原作者标识
    4) 用 .NET ZipFile 写入正斜杠路径
       （PowerShell 的 Compress-Archive 在 Windows 上会写成反斜杠，导致安卓解压出畸形文件名）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File build.ps1
#>
$ErrorActionPreference = 'Stop'

$root  = $PSScriptRoot
$stage = Join-Path $root 'build'
$zip   = Join-Path $root 'hyperaudio_module.zip'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Write-Output "== 1. 组装模块目录 =="
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
foreach ($f in @('mode_switch.sh','start_daemon.sh','hyperaudio_init.sh')) {
  Copy-Item (Join-Path $root "webui\$f") (Join-Path $stage 'bin') -Force
}

Copy-Item (Join-Path $root 'prebuilt\hyper-audio') $stage -Force
Copy-Item (Join-Path $root 'prebuilt\config.toml') $stage -Force
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'system\lib64') | Out-Null
Copy-Item (Join-Path $root 'prebuilt\libaaudio_internal.so')         (Join-Path $stage 'system\lib64') -Force
Copy-Item (Join-Path $root 'prebuilt\libaaudio_internal_builder.so') (Join-Path $stage 'system\lib64') -Force
Copy-Item (Join-Path $root 'prebuilt\META-INF') $stage -Recurse -Force

Write-Output "== 2. 移除原作者个人标识 =="
$sp = Join-Path $stage 'system.prop'
$t = [System.IO.File]::ReadAllText($sp, $utf8NoBom)
$t = $t.Replace('# HLMC: 1 会爆音; Ray: 3 音质最好', '# 实测：1 会爆音；3 音质最好')
[System.IO.File]::WriteAllText($sp, $t, $utf8NoBom)

$cfg = Join-Path $stage 'config.toml'
$t = [System.IO.File]::ReadAllText($cfg, $utf8NoBom)
$t = [regex]::Replace($t, '(?m)^\s*"com\.hlmc\.phire",\r?\n', '')
[System.IO.File]::WriteAllText($cfg, $t, $utf8NoBom)

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
Write-Output "  二进制：'hlmc' -> 'user' 共 $n 处（等长替换）"

Write-Output "== 3. 规范化换行与编码 =="
Get-ChildItem -Recurse -File $stage |
  Where-Object { $_.Extension -in '.sh','.prop','.toml','.md' -or $_.Name -eq 'update-binary' } |
  ForEach-Object {
    $t = [System.IO.File]::ReadAllText($_.FullName, $utf8NoBom) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($_.FullName, $t, $utf8NoBom)
  }

Write-Output "== 4. 校验 A：不得含调音载荷 =="
$forbidden = @('acdbdata','dax-default','mixer_paths','resourcemanager','audio_module_config_primary','audio_effects','sku_canoe')
foreach ($f in $forbidden) {
  $hit = Get-ChildItem -Recurse -File $stage | Where-Object { $_.Name -match $f }
  if ($hit) { Write-Output "!! 残留调音文件: $f"; exit 1 }
}
Write-Output "  通过"

Write-Output "== 5. 校验 B：不得含机型判断 =="
$devicePats = 'popsicle|pandora|pudding|ro\.product\.device|ro\.product\.vendor\.device|ro\.build\.product|Mi17Audio|myron|1014E|1115X'
$hit2 = Get-ChildItem -Recurse -File $stage |
  Where-Object { $_.Extension -in '.sh','.prop','.toml' -or $_.Name -eq 'update-binary' } |
  Select-String -Pattern $devicePats -AllMatches
if ($hit2) { $hit2 | ForEach-Object { Write-Output ("   " + $_.Path + ":" + $_.LineNumber) }; exit 1 }
Write-Output "  通过"

Write-Output "== 6. 校验 C：除 CREDITS.md 外不得含原作者标识 =="
$authorPats = 'hlmc|HLMC|nakixii|Ray|Mi17Audio'
$hit3 = Get-ChildItem -Recurse -File $stage |
  Where-Object { $_.Name -ne 'CREDITS.md' } |
  Where-Object { $_.Extension -in '.sh','.prop','.toml','.md','.html','.js','.css' -or $_.Name -eq 'update-binary' } |
  Select-String -Pattern $authorPats -AllMatches
if ($hit3) { $hit3 | ForEach-Object { Write-Output ("   " + $_.Path + ":" + $_.LineNumber) }; exit 1 }
$binHit = ([regex]::Matches([System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($bin)), 'hlmc')).Count
if ($binHit -gt 0) { Write-Output "!! 二进制仍有 $binHit 处 hlmc"; exit 1 }
Write-Output "  通过"

Write-Output "== 7. 打包 =="
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
Write-Output "包内 $($z.Entries.Count) 项："
$bad = @()
$z.Entries | Sort-Object FullName | ForEach-Object {
  Write-Output ("  {0,10}  {1}" -f $_.Length, $_.FullName)
  if ($_.FullName.Contains('\')) { $bad += $_.FullName }
}
$z.Dispose()
if ($bad.Count -gt 0) { Write-Output "!! 含反斜杠路径"; exit 1 }
Write-Output ("输出: {0}  ({1} 字节)" -f $zip, (Get-Item $zip).Length)
Write-Output ("sha256: " + (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower())
