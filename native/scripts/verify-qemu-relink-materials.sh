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

# Keep the complete ABI sysroot. These are available relink inputs, not a claim
# that every archive is a direct argument of each final executable. Meson may
# express dependencies transitively or through generated linker response data.
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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Ask Ninja for each final target's command graph and verify that it contains
# the actual final-output link edge. Do not infer direct library linkage from
# text searches: static/transitive dependencies can be represented by Meson
# response files, linker groups, or intermediate target edges.
for target in qemu-system-aarch64 qemu-img; do
  if ! ninja -C "$BUILD_DIR" -t commands "$target" > "$tmp_dir/$target.commands"; then
    echo "ERROR: unable to extract Ninja commands for $target" >&2
    exit 1
  fi

  if ! grep -Eq -- "-o[[:space:]=]+([^[:space:]]*/)?$target([[:space:]]|$)" "$tmp_dir/$target.commands"; then
    echo "ERROR: Ninja command graph does not contain the final link output for $target" >&2
    exit 1
  fi
done

echo "Verified QEMU relink materials for $ABI"
echo "  object files: $object_count"
echo "  build metadata: build.ninja, compile_commands.json, Meson coredata"
echo "  final link commands: qemu-system-aarch64, qemu-img"
echo "  complete ABI dependency sysroot: $SYSROOT_LIB"
