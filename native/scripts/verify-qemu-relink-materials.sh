#!/usr/bin/env bash
# Verify that a QEMU build artifact retains the inputs needed for relinking.
# This is a structural check, not a legal-compliance determination.

set -euo pipefail

ABI="${1:?Usage: verify-qemu-relink-materials.sh <arm64-v8a|x86_64>}"
case "$ABI" in
  arm64-v8a|x86_64) ;;
  *)
    echo "ERROR: unsupported Android ABI: $ABI" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="${QEMU_BUILD_ROOT:-$ROOT/.work/qemu-build}"
SYSROOT_ROOT="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
BUILD_DIR="$BUILD_ROOT/$ABI"
SYSROOT_LIB="$SYSROOT_ROOT/usr/lib"

for path in \
  "$BUILD_DIR/build.ninja" \
  "$BUILD_DIR/compile_commands.json" \
  "$BUILD_DIR/meson-private/coredata.dat" \
  "$BUILD_DIR/qemu-system-aarch64" \
  "$BUILD_DIR/qemu-img" \
  "$BUILD_DIR/qemu-system-aarch64.p/system_main.c.o" \
  "$BUILD_DIR/qemu-img.p/qemu-img.c.o"; do
  [[ -s "$path" ]] || {
    echo "ERROR: required QEMU relink input is missing or empty: $path" >&2
    exit 1
  }
done

for binary in "$BUILD_DIR/qemu-system-aarch64" "$BUILD_DIR/qemu-img"; do
  [[ -x "$binary" ]] || {
    echo "ERROR: QEMU output is not executable: $binary" >&2
    exit 1
  }
done

object_count="$(find "$BUILD_DIR" -type f -name '*.o' -size +0c | wc -l | tr -d ' ')"
if (( object_count < 1000 )); then
  echo "ERROR: expected at least 1000 retained QEMU object files; found $object_count" >&2
  exit 1
fi

for library in \
  libffi.a \
  libgio-2.0.a \
  libglib-2.0.a \
  libgmodule-2.0.a \
  libgobject-2.0.a \
  libintl.a \
  libpcre2-8.a \
  libpixman-1.a \
  libz.so; do
  [[ -s "$SYSROOT_LIB/$library" ]] || {
    echo "ERROR: relink dependency is missing from ABI sysroot: $SYSROOT_LIB/$library" >&2
    exit 1
  }
done

for target in qemu-system-aarch64 qemu-img; do
  grep -Fq "build $target:" "$BUILD_DIR/build.ninja" || {
    echo "ERROR: Ninja metadata does not define target $target" >&2
    exit 1
  }
done

# Ensure the build metadata records the ABI-specific libraries needed by
# QEMU's static GLib/Pixman stack and the shared zlib dependency.
for library in \
  libffi.a \
  libgio-2.0.a \
  libglib-2.0.a \
  libgmodule-2.0.a \
  libgobject-2.0.a \
  libintl.a \
  libpcre2-8.a \
  libpixman-1.a \
  libz.so; do
  grep -Fq "$SYSROOT_LIB/$library" "$BUILD_DIR/build.ninja" || {
    echo "ERROR: Ninja link metadata does not reference $library" >&2
    exit 1
  }
done

echo "Verified QEMU relink materials for $ABI"
echo "  object files: $object_count"
echo "  build metadata: build.ninja, compile_commands.json, Meson coredata"
echo "  dependency sysroot: $SYSROOT_LIB"
