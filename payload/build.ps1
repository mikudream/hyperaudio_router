# Build the unified Zygisk payload.
# Requires Android NDK r27 (clang). Set ANDROID_NDK_HOME or pass -Ndk.
param([string]$Ndk = $env:ANDROID_NDK_HOME)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $Ndk) {
    $hyp = Split-Path $repo -Parent
    $Ndk = Join-Path $hyp 'tooling\android-ndk-r27c'
}
$clang = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android24-clang++.cmd'
$strip = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe'
if (-not (Test-Path $clang)) { throw "NDK clang not found: $clang" }

$tmp = Join-Path $PSScriptRoot 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TMP = $tmp
$env:TEMP = $tmp
$out = Join-Path $repo 'zygisk\arm64-v8a.so'
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null

& $clang -shared -fPIC -O2 -std=c++17 -fno-exceptions -fno-rtti -static-libstdc++ -Wall `
    "-I$(Join-Path $PSScriptRoot 'include')" -o $out (Join-Path $PSScriptRoot 'src\main.cpp') -llog -ldl
if ($LASTEXITCODE -ne 0) { throw "compile failed: $LASTEXITCODE" }
& $strip "--strip-unneeded" $out
Write-Output ("payload: {0} ({1:N0} bytes)" -f $out, (Get-Item $out).Length)
