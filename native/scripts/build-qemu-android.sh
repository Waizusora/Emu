#!/usr/bin/env bash
# Cross-build QEMU 9.2.0 for Android using the Android NDK.
# This script requires an ABI-matched dependency sysroot; it never substitutes
# host Linux libraries for Android libraries.

set -euo pipefail

# Resolve paths relative to the repository so the script works from any cwd.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_DIR="${QEMU_SOURCE_DIR:-$ROOT/.work/qemu}"
BUILD_ROOT="${QEMU_BUILD_ROOT:-$ROOT/.work/qemu-build}"
ABI="${1:-arm64-v8a}"
API="${ANDROID_API:-28}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
SYSROOT="${QEMU_ANDROID_SYSROOT:-}"
PKG_CONFIG_LIBDIR_OVERRIDE="${QEMU_PKG_CONFIG_LIBDIR:-}"

# Map Android ABI names to NDK compiler target prefixes.
case "$ABI" in
  arm64-v8a)
    TRIPLE="aarch64-linux-android"
    ;;
  x86_64)
    TRIPLE="x86_64-linux-android"
    ;;
  *)
    echo "ERROR: supported ABI values: arm64-v8a, x86_64" >&2
    exit 2
    ;;
esac

# Validate source, NDK, API level, and the cross-compiled dependency sysroot.
[[ -x "$SOURCE_DIR/configure" ]] || {
  echo "ERROR: QEMU source missing; run bash native/scripts/fetch-qemu.sh first" >&2
  exit 2
}
[[ "$API" =~ ^[0-9]+$ ]] && (( API >= 28 )) || {
  echo "ERROR: ANDROID_API must be an integer >= 28" >&2
  exit 2
}
[[ -n "$NDK" && -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64" ]] || {
  echo "ERROR: set ANDROID_NDK_HOME to a Linux Android NDK installation" >&2
  exit 2
}
[[ -n "$SYSROOT" && -d "$SYSROOT" ]] || {
  echo "ERROR: set QEMU_ANDROID_SYSROOT to the ABI-specific Android dependency sysroot" >&2
  exit 2
}
[[ -n "$PKG_CONFIG_LIBDIR_OVERRIDE" ]] || {
  echo "ERROR: set QEMU_PKG_CONFIG_LIBDIR to the sysroot's target .pc directories" >&2
  exit 2
}
command -v pkg-config >/dev/null 2>&1 || {
  echo "ERROR: pkg-config is required on the build host" >&2
  exit 2
}
command -v ninja >/dev/null 2>&1 || {
  echo "ERROR: Ninja is required on the build host" >&2
  exit 2
}

# Select NDK compilers and binutils for the requested Android ABI.
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$TOOLCHAIN/$TRIPLE$API-clang"
CXX="$TOOLCHAIN/$TRIPLE$API-clang++"
AR="$TOOLCHAIN/llvm-ar"
RANLIB="$TOOLCHAIN/llvm-ranlib"
for tool in "$CC" "$CXX" "$AR" "$RANLIB"; do
  [[ -x "$tool" ]] || {
    echo "ERROR: missing NDK tool: $tool" >&2
    exit 2
  }
done

# Restrict pkg-config to Android target metadata. This prevents accidentally
# linking GLib or Pixman from the Linux build host into an Android binary.
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR_OVERRIDE"
export PKG_CONFIG_ALLOW_CROSS=1
export CC CXX AR RANLIB
export CFLAGS="${CFLAGS:--O2 -fPIC}"
export CXXFLAGS="${CXXFLAGS:--O2 -fPIC}"

# QEMU's system emulator requires GLib and Pixman. Refuse to configure when
# either dependency is absent instead of producing a misleading partial build.
for dependency in glib-2.0 pixman-1; do
  if ! pkg-config --exists "$dependency"; then
    echo "ERROR: target dependency '$dependency' not found via QEMU_PKG_CONFIG_LIBDIR" >&2
    exit 2
  fi
done

# Keep each ABI in a separate build directory to avoid mixing object files.
BUILD_DIR="$BUILD_ROOT/$ABI"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cat <<INFO
QEMU source: $SOURCE_DIR
Android ABI: $ABI ($TRIPLE), API $API
Dependency sysroot: $SYSROOT
Build directory: $BUILD_DIR

This cross-build is experimental. A successful build does not prove that the
runtime loads or boots correctly on a physical Android device.
INFO

# Configure the AArch64 system emulator with TCG. The NDK cross-prefix marks
# this as a cross-build; host-cc remains the native compiler for build tools.
"$SOURCE_DIR/configure" \
  --prefix="$BUILD_DIR/install" \
  --target-list=aarch64-softmmu \
  --cross-prefix="$TOOLCHAIN/$TRIPLE-" \
  --cc="$CC" \
  --cxx="$CXX" \
  --host-cc="${HOST_CC:-cc}" \
  --extra-cflags="-I$SYSROOT/usr/include" \
  --extra-ldflags="-L$SYSROOT/usr/lib" \
  --enable-tcg \
  --disable-kvm \
  --disable-werror \
  --disable-download \
  --disable-docs \
  --disable-gtk \
  --disable-sdl \
  --disable-vnc \
  --disable-curses \
  --disable-opengl \
  --disable-virglrenderer \
  --disable-spice \
  --disable-xen \
  --disable-cap-ng \
  --disable-seccomp \
  --disable-selinux \
  --disable-libnfs \
  --disable-libiscsi \
  --disable-rbd \
  --disable-usb-redir

# Build only the deliverables needed by the app. qemu-img is kept separate
# from the emulator binary so it can be packaged and tested independently.
ninja -C "$BUILD_DIR" qemu-system-aarch64 qemu-img

echo "QEMU binaries built under: $BUILD_DIR"
echo "Next: inspect ELF dependencies and run device-level smoke tests before packaging."
