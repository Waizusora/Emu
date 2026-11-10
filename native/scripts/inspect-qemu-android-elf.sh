#!/usr/bin/env bash
# Inspect Android QEMU executables before they are uploaded or packaged.
# This is a structural ELF check; it does not replace on-device execution tests.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"
BUILD_ROOT="${QEMU_BUILD_ROOT:-$ROOT/.work/qemu-build}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"

case "$ABI" in
  arm64-v8a)
    TRIPLE="aarch64-linux-android"
    EXPECTED_MACHINE="AArch64"
    ;;
  x86_64)
    TRIPLE="x86_64-linux-android"
    EXPECTED_MACHINE="Advanced Micro Devices X86-64"
    ;;
  *)
    echo "ERROR: supported ABI values: arm64-v8a, x86_64" >&2
    exit 2
    ;;
esac

READELF="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
PATCHELF="$(command -v patchelf || true)"
[[ -n "$PATCHELF" ]] || {
  echo "ERROR: patchelf is required to remove Meson build-tree RUNPATH entries" >&2
  exit 2
}
[[ -x "$READELF" ]] || {
  echo "ERROR: Android NDK llvm-readelf not found: $READELF" >&2
  exit 2
}

BUILD_DIR="$BUILD_ROOT/$ABI"
for name in qemu-system-aarch64 qemu-img; do
  binary="$BUILD_DIR/$name"
  [[ -s "$binary" && -x "$binary" ]] || {
    echo "ERROR: missing executable: $binary" >&2
    exit 1
  }

  machine="$("$READELF" --file-header "$binary" | awk -F: '/Machine:/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }')"
  [[ "$machine" == "$EXPECTED_MACHINE" ]] || {
    echo "ERROR: $name has ELF machine '$machine'; expected '$EXPECTED_MACHINE'" >&2
    exit 1
  }

  # Android 64-bit executables must use Android's system linker, not a host loader.
  interpreter="$("$READELF" --program-headers --wide "$binary" | sed -n 's/.*Requesting program interpreter: \([^]]*\)\].*/\1/p' | head -n 1)"
  if [[ "$interpreter" != "/system/bin/linker64" ]]; then
    echo "ERROR: unexpected ELF interpreter for $name: '${interpreter:-missing}'" >&2
    exit 1
  fi

  # Meson embeds the temporary sysroot path in build-tree executables so
  # they can run on the CI host. Remove that build-only path before upload.
  # patchelf edits only ELF dynamic metadata; it does not change machine code.
  "$PATCHELF" --remove-rpath "$binary"

  dynamic="$("$READELF" --dynamic --wide "$binary")"
  if grep -Eq '\((RPATH|RUNPATH)\)' <<< "$dynamic"; then
    echo "ERROR: $name contains an RPATH/RUNPATH that may reference build-host paths" >&2
    grep -E '\((RPATH|RUNPATH)\)' <<< "$dynamic" >&2
    exit 1
  fi

  echo "===== Android ELF inspection: $ABI / $name ====="
  echo "ELF machine: $machine"
  echo "ELF interpreter: $interpreter"
  echo "DT_NEEDED shared libraries:"
  needed="$(sed -n 's/.*(NEEDED).*Shared library: \([^]]*\)\].*/\1/p' <<< "$dynamic")"
  if [[ -n "$needed" ]]; then
    while IFS= read -r library; do
      [[ -n "$library" ]] && echo "  - $library"
    done <<< "$needed"
  else
    echo "  (none; statically linked executable)"
  fi
  echo "RPATH/RUNPATH: absent"
done

echo "Android ELF structural inspection passed for ABI: $ABI"
