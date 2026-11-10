#!/usr/bin/env bash
# Generate a Meson cross file for Android NDK dependency builds.
# The supplied prefix contains target libraries; the NDK supplies the Android
# platform headers and runtime libraries through its compiler defaults.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
API="${ANDROID_API:-28}"
PREFIX="${QEMU_ANDROID_SYSROOT:-}"
OUTPUT="${2:-$ROOT/.work/meson/android-$ABI.ini}"

# Resolve the Android target triple and Meson CPU identifiers.
case "$ABI" in
  arm64-v8a)
    TRIPLE="aarch64-linux-android"
    CPU_FAMILY="aarch64"
    CPU="aarch64"
    ;;
  x86_64)
    TRIPLE="x86_64-linux-android"
    CPU_FAMILY="x86_64"
    CPU="x86_64"
    ;;
  *)
    echo "ERROR: supported ABI values: arm64-v8a, x86_64" >&2
    exit 2
    ;;
esac

# Validate toolchain and dependency prefix before generating a cross file.
[[ -n "$NDK" && -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64" ]] || {
  echo "ERROR: set ANDROID_NDK_HOME to a Linux Android NDK installation" >&2
  exit 2
}
[[ "$API" =~ ^[0-9]+$ ]] && (( API >= 28 )) || {
  echo "ERROR: ANDROID_API must be an integer >= 28" >&2
  exit 2
}
[[ -n "$PREFIX" && -d "$PREFIX" ]] || {
  echo "ERROR: set QEMU_ANDROID_SYSROOT to the target dependency prefix" >&2
  exit 2
}
command -v pkg-config >/dev/null 2>&1 || {
  echo "ERROR: pkg-config is required on the build host" >&2
  exit 2
}

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$TOOLCHAIN/$TRIPLE$API-clang"
CXX="$TOOLCHAIN/$TRIPLE$API-clang++"
for tool in "$CC" "$CXX" "$TOOLCHAIN/llvm-ar" "$TOOLCHAIN/llvm-strip"; do
  [[ -x "$tool" ]] || {
    echo "ERROR: missing NDK tool: $tool" >&2
    exit 2
  }
done

# Keep only pkg-config metadata inside the ABI-specific dependency prefix.
PKG_CONFIG_DIRS=()
for directory in "$PREFIX/usr/lib/pkgconfig" "$PREFIX/usr/share/pkgconfig"; do
  [[ ! -d "$directory" ]] || PKG_CONFIG_DIRS+=("$directory")
done
[[ "${#PKG_CONFIG_DIRS[@]}" -gt 0 ]] || {
  echo "ERROR: no pkg-config directories found under $PREFIX/usr" >&2
  exit 2
}

# Python writes correctly escaped Meson strings, including paths with spaces.
mkdir -p "$(dirname "$OUTPUT")"
ANDROID_ABI="$ABI" ANDROID_TRIPLE="$TRIPLE" ANDROID_CPU_FAMILY="$CPU_FAMILY" \
ANDROID_CPU="$CPU" ANDROID_CC="$CC" ANDROID_CXX="$CXX" \
ANDROID_AR="$TOOLCHAIN/llvm-ar" ANDROID_STRIP="$TOOLCHAIN/llvm-strip" \
ANDROID_PKG_CONFIG="$(command -v pkg-config)" ANDROID_PREFIX="$PREFIX" \
ANDROID_PKG_CONFIG_DIRS="$(IFS=:; echo "${PKG_CONFIG_DIRS[*]}")" \
ANDROID_OUTPUT="$OUTPUT" python3 <<'PY'
# Python helper: emit a valid Meson machine file without unsafe shell quoting.
import json
import os
from pathlib import Path

def meson_string(value):
    # JSON string literals are compatible with Meson's quoted string syntax.
    return json.dumps(value)

pkg_dirs = os.environ["ANDROID_PKG_CONFIG_DIRS"].split(":")
lines = [
    "# Generated for Android NDK cross-compilation; do not edit by hand.",
    "[binaries]",
    f"c = {meson_string(os.environ['ANDROID_CC'])}",
    f"cpp = {meson_string(os.environ['ANDROID_CXX'])}",
    f"ar = {meson_string(os.environ['ANDROID_AR'])}",
    f"strip = {meson_string(os.environ['ANDROID_STRIP'])}",
    f"pkgconfig = {meson_string(os.environ['ANDROID_PKG_CONFIG'])}",
    "",
    "[host_machine]",
    "system = 'android'",
    f"cpu_family = {meson_string(os.environ['ANDROID_CPU_FAMILY'])}",
    f"cpu = {meson_string(os.environ['ANDROID_CPU'])}",
    "endian = 'little'",
    "",
    "[properties]",
    "needs_exe_wrapper = true",
    "pkg_config_libdir = [" + ", ".join(meson_string(p) for p in pkg_dirs) + "]",
    "",
    "[built-in options]",
    "default_library = 'static'",
    "",
]
Path(os.environ["ANDROID_OUTPUT"]).write_text("\n".join(lines), encoding="utf-8")
print(f"Generated Meson cross file for {os.environ['ANDROID_ABI']}: "
      f"{os.environ['ANDROID_OUTPUT']}")
PY

