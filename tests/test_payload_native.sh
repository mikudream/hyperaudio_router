#!/system/bin/sh
# Validate the native policy and source-level wiring without a device.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC=$ROOT/payload/src/main.cpp
POL=$ROOT/payload/include/native_policy.hpp
ck() { grep -F "$1" "$2" >/dev/null || { echo "FAIL: $1"; exit 1; }; }
ck '0xa4,0x3d,0xdc,0x03,0x29,0x1a,0x3e,0x68' "$SRC"
ck '0xdf,0x59,0x35,0x09,0x99,0x0d,0xf2,0x5f' "$SRC"
ck 'kFlagsOffset = 0x3c0' "$SRC"
ck 'kCompareSlot = 0xc558' "$SRC"
ck 'R_AARCH64_JUMP_SLOT' "$SRC"
ck 'mprotect(tramp, pagesize, restore)' "$SRC"
ck 'file_lists_package' "$SRC"
ck 'property_lists_package' "$SRC"
ck 'ha.%s.%d.%zu' "$POL"
ck 'whitelist_override' "$POL"
ck 'mprotect(tramp, pagesize, restore)' "$SRC"
ck 'mprotect(text, pagesize, writable)' "$SRC"

HOST_CXX=${HOST_CXX:-}
if [ -z "$HOST_CXX" ]; then
  for candidate in \
    /d/DSH/Tools/toolchains/zig-x86_64-windows-0.16.0/zig.exe \
    /d/DSH/Tools/toolchains/zig-x86_64-linux-0.16.0/zig \
    zig; do
    if command -v "$candidate" >/dev/null 2>&1; then HOST_CXX=$candidate; break; fi
  done
fi
if [ -z "$HOST_CXX" ]; then
  printf '%s\n' 'payload native host tests: SKIP (set HOST_CXX or install shared Zig)'
else
  BUILD_ROOT=$ROOT/build
  mkdir -p "$BUILD_ROOT"
  TMP_NATIVE=$(mktemp -d "$BUILD_ROOT/test-payload-native.XXXXXX")
  mkdir -p "$TMP_NATIVE/zig-cache" "$TMP_NATIVE/zig-local"
  trap 'rm -rf "$TMP_NATIVE"' EXIT HUP INT TERM
  TMP_HOST=$TMP_NATIVE
  if command -v cygpath >/dev/null 2>&1; then TMP_HOST=$(cygpath -w "$TMP_NATIVE"); fi
  export TMPDIR=$TMP_NATIVE
  export TMP=$TMP_HOST TEMP=$TMP_HOST
  export ZIG_GLOBAL_CACHE_DIR=$TMP_HOST/zig-cache
  export ZIG_LOCAL_CACHE_DIR=$TMP_HOST/zig-local
  case "$(basename "$HOST_CXX")" in
    zig|zig.exe) "$HOST_CXX" c++ -std=c++17 -w -fno-sanitize=all \
      -I"$ROOT/payload/include" "$ROOT/tests/test_payload_native.cpp" -o "$TMP_NATIVE/test_payload_native" ;;
    *) "$HOST_CXX" -std=c++17 -Wall -Wextra -Werror -I"$ROOT/payload/include" \
      "$ROOT/tests/test_payload_native.cpp" -o "$TMP_NATIVE/test_payload_native" ;;
  esac
  "$TMP_NATIVE/test_payload_native"
fi
printf '%s\n' 'payload native static checks: PASS'
