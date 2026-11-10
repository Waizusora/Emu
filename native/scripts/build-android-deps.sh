#!/usr/bin/env bash
# Build the currently supported third-party Android dependency stages.
# GLib and Pixman are separate future stages; this script reports that limit.

set -euo pipefail

# Resolve repository root and target ABI once for the dependency chain.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"

# Share one isolated sysroot among libraries built for the selected ABI.
export QEMU_ANDROID_SYSROOT="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
mkdir -p "$QEMU_ANDROID_SYSROOT"

# Build the foundational compression and GLib prerequisite libraries.
bash "$ROOT/native/scripts/build-zlib-android.sh" "$ABI"
bash "$ROOT/native/scripts/build-libffi-android.sh" "$ABI"
bash "$ROOT/native/scripts/build-pcre2-android.sh" "$ABI"

# Generate the Meson cross file after the initial pkg-config metadata exists.
bash "$ROOT/native/scripts/create-android-meson-cross-file.sh" "$ABI"

# GLib consumes zlib, libffi, and PCRE2; Pixman is built independently.
bash "$ROOT/native/scripts/build-glib-android.sh" "$ABI"
bash "$ROOT/native/scripts/build-pixman-android.sh" "$ABI"

# Verify all QEMU's required target pkg-config modules before declaring success.
export QEMU_PKG_CONFIG_LIBDIR="$QEMU_ANDROID_SYSROOT/usr/lib/pkgconfig:$QEMU_ANDROID_SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$QEMU_ANDROID_SYSROOT"
export PKG_CONFIG_LIBDIR="$QEMU_PKG_CONFIG_LIBDIR"
for module in glib-2.0 pixman-1; do
  pkg-config --exists "$module" || {
    echo "ERROR: required QEMU target module '$module' is missing" >&2
    exit 1
  }
done

echo "Completed dependency builds for $ABI."
echo "QEMU_PKG_CONFIG_LIBDIR=$QEMU_PKG_CONFIG_LIBDIR"
