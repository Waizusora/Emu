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

# Retain the complete ABI sysroot for relinking. Not every archive must appear
# as a direct argument: some static dependencies are consumed transitively.
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

# Check each output's own Ninja command graph. Match both -lNAME and archive
# filenames; linkers commonly receive a sysroot -L path plus -lNAME rather than
# an absolute path to each archive. Only assert direct QEMU target dependencies.
for target in qemu-system-aarch64 qemu-img; do
  if ! ninja -C "$BUILD_DIR" -t commands "$target" > "$tmp_dir/$target.commands"; then
    echo "ERROR: unable to extract Ninja commands for $target" >&2
    exit 1
  fi

  commands="$tmp_dir/$target.commands"
  for library in glib-2.0 pcre2-8; do
    if ! grep -Eq -- "(-l${library}([[:space:]]|$)|lib${library}\\.a([[:space:]]|$))" "$commands"; then
      echo "ERROR: $target link command graph does not reference $library" >&2
      exit 1
    fi
  done

  if ! grep -Eq -- '(-lz([[:space:]]|$)|libz\.so([[:space:]]|$))' "$commands"; then
    echo "ERROR: $target link command graph does not reference zlib" >&2
    exit 1
  fi

  if [[ "$target" == "qemu-system-aarch64" ]]; then
    if ! grep -Eq -- '(-lpixman-1([[:space:]]|$)|libpixman-1\.a([[:space:]]|$))' "$commands"; then
      echo "ERROR: $target link command graph does not reference Pixman" >&2
      exit 1
    fi
  elif grep -Eq -- '(-lpixman-1([[:space:]]|$)|libpixman-1\.a([[:space:]]|$))' "$commands"; then
    echo "ERROR: qemu-img unexpectedly links Pixman; review the dependency manifest" >&2
    exit 1
  fi
done

echo "Verified QEMU relink materials for $ABI"
echo "  object files: $object_count"
echo "  build metadata: build.ninja, compile_commands.json, Meson coredata"
echo "  target link commands: qemu-system-aarch64, qemu-img"
echo "  complete ABI dependency sysroot: $SYSROOT_LIB"
